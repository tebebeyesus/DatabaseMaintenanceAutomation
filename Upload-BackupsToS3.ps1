#Requires -Version 5.1
<#
.SYNOPSIS
    Uploads SQL Server backup files (FULL / DIFF / LOG) to Amazon S3.

.DESCRIPTION
    Scans <RootPath>\<ServerFolder>\<Database>\<BackupType>\ for backup files, skips files that
    are still being written or already exist in S3 with the same size, then uploads the rest
    with AWS CLI v2. Each file is uploaded as a parallel multipart upload, and several files
    are uploaded at the same time. Every upload is verified against the object size in S3.

    All settings live in config\S3BackupUpload.psd1.

.PARAMETER ConfigPath
    Path to the .psd1 configuration file.

.PARAMETER Database
    Overrides the Databases list in the config (wildcards allowed).

.PARAMETER BackupType
    Overrides the BackupTypes list in the config, e.g. -BackupType LOG.

.EXAMPLE
    .\Upload-BackupsToS3.ps1 -WhatIf
    Lists what would be uploaded without uploading anything.

.EXAMPLE
    .\Upload-BackupsToS3.ps1 -Database CultiveraMarket -BackupType FULL
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\S3BackupUpload.psd1'),
    [string[]]$Database,
    [string[]]$BackupType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Resolve-ConfigRelativePath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path (Split-Path -Parent $script:ResolvedConfigPath) $Path
}

function Assert-Config($Config) {
    if (-not $Config.S3.Bucket -or $Config.S3.Bucket -eq 'your-sql-backup-bucket') { throw 'S3.Bucket is not set in the config file.' }
    if (-not $Config.S3.Region) { throw 'S3.Region is not set in the config file.' }
    if ($Config.Credentials.Mode -notin 'InstanceProfile', 'Profile', 'AccessKey') {
        throw "Credentials.Mode '$($Config.Credentials.Mode)' is invalid. Use InstanceProfile, Profile or AccessKey."
    }
    if ($Config.Credentials.Mode -eq 'Profile' -and -not $Config.Credentials.ProfileName) { throw 'Credentials.ProfileName is required when Mode = Profile.' }
    if ($Config.S3.ServerSideEncryption -and $Config.S3.ServerSideEncryption -notin 'AES256', 'aws:kms') {
        throw "S3.ServerSideEncryption must be 'AES256', 'aws:kms' or ''."
    }
    if (-not (Test-Path -LiteralPath $Config.Source.RootPath)) { throw "Source.RootPath '$($Config.Source.RootPath)' does not exist." }
    if ($Config.Performance.MaxConcurrentFiles -lt 1) { throw 'Performance.MaxConcurrentFiles must be at least 1.' }
}

function Resolve-AwsCli([string]$Configured) {
    if ($Configured) {
        if (Test-Path -LiteralPath $Configured) { return $Configured }
        throw "AWS CLI not found at AwsCliPath '$Configured'."
    }
    $cmd = Get-Command aws.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'
    if (Test-Path -LiteralPath $default) { return $default }
    throw 'AWS CLI v2 not found. Install it from https://awscli.amazonaws.com/AWSCLIV2.msi or set AwsCliPath in the config.'
}

# Runs aws.exe synchronously and returns stdout. Throws with stderr text on a non-zero exit code.
function Invoke-Aws([string[]]$Arguments) {
    # Windows PowerShell turns native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $output = & $script:AwsCli @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        # Native stderr lines arrive as ErrorRecords; the original text is in TargetObject.
        $stderr = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { if ($_.TargetObject -is [string]) { $_.TargetObject } else { "$_" } } |
            Where-Object { $_ -and $_.Trim() }) -join ' '
        throw "aws $($Arguments[0]) $($Arguments[1]) failed (exit $exitCode): $stderr"
    }
    return $stdout
}

# Quotes one argument for a Windows command line (CommandLineToArgvW rules).
function ConvertTo-ProcessArgument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# Returns AWS config file lines with the s3 transfer block placed in the given profile
# section, replacing any s3 block that section already had. Other content is kept as-is.
function Merge-AwsS3Settings([string[]]$Existing, [string]$Header, [string[]]$S3Block) {
    $out = [System.Collections.Generic.List[string]]::new()
    $inTarget = $false
    $skippingS3 = $false
    $found = $false
    foreach ($line in $Existing) {
        if ($line -match '^\s*\[') {
            $inTarget = ($line.Trim() -eq $Header)
            $skippingS3 = $false
            $out.Add($line)
            if ($inTarget) { $found = $true; $out.AddRange($S3Block) }
            continue
        }
        if ($inTarget) {
            if ($line -match '^s3\s*=') { $skippingS3 = $true; continue }
            if ($skippingS3 -and $line -match '^\s+\S') { continue }
            $skippingS3 = $false
        }
        $out.Add($line)
    }
    if (-not $found) { $out.Add($Header); $out.AddRange($S3Block) }
    return $out
}

$script:AwsEnvNames = 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_PROFILE', 'AWS_DEFAULT_PROFILE',
    'AWS_SHARED_CREDENTIALS_FILE', 'AWS_CONFIG_FILE', 'AWS_REGION', 'AWS_DEFAULT_REGION', 'AWS_RETRY_MODE', 'AWS_MAX_ATTEMPTS'

# Puts back the caller's AWS environment variables (matters when run from an interactive session).
function Restore-AwsEnvironment {
    if (-not $script:SavedAwsEnv) { return }
    foreach ($name in $script:AwsEnvNames) {
        if ($null -ne $script:SavedAwsEnv[$name]) { Set-Item -Path "Env:$name" -Value $script:SavedAwsEnv[$name] }
        else { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
    }
}

# Sets up credentials for the selected mode and points the AWS CLI at a generated config
# file holding the multipart settings. Only this process and its child aws.exe processes
# see these environment variables; Restore-AwsEnvironment undoes them at the end.
function Initialize-AwsEnvironment($Config, [string]$WorkDir) {
    $cred = $Config.Credentials
    $perf = $Config.Performance

    $script:SavedAwsEnv = @{}
    foreach ($name in $script:AwsEnvNames) { $script:SavedAwsEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
    $userConfig = if ($script:SavedAwsEnv['AWS_CONFIG_FILE']) { $script:SavedAwsEnv['AWS_CONFIG_FILE'] } else { Join-Path $HOME '.aws\config' }

    foreach ($name in $script:AwsEnvNames) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
    $env:AWS_REGION = $Config.S3.Region
    $env:AWS_RETRY_MODE = 'adaptive'
    $env:AWS_MAX_ATTEMPTS = '10'

    $section = '[default]'
    $baseConfig = @()
    switch ($cred.Mode) {
        'InstanceProfile' {
            # Empty credentials file so a stray ~/.aws/credentials can't take priority over the instance role.
            $emptyCreds = Join-Path $WorkDir 'credentials'
            Set-Content -Path $emptyCreds -Value '' -Encoding ASCII
            $env:AWS_SHARED_CREDENTIALS_FILE = $emptyCreds
        }
        'Profile' {
            if ($cred.ProfileName -ne 'default') { $section = "[profile $($cred.ProfileName)]" }
            $env:AWS_PROFILE = $cred.ProfileName
            # Keep the user's own config (SSO / aws login / role settings live there).
            if (Test-Path -LiteralPath $userConfig) { $baseConfig = @(Get-Content -LiteralPath $userConfig) }
        }
        'AccessKey' {
            $keyFile = Resolve-ConfigRelativePath $cred.AccessKeyFile
            if (-not (Test-Path -LiteralPath $keyFile)) { throw "Credential file '$keyFile' not found. Create it with Set-S3UploadCredential.ps1." }
            try { $stored = Import-Clixml -LiteralPath $keyFile }
            catch { throw "Could not decrypt '$keyFile'. It must be created by the same Windows account, on the same machine, that runs this script. $_" }
            $env:AWS_ACCESS_KEY_ID = $stored.UserName
            $env:AWS_SECRET_ACCESS_KEY = $stored.GetNetworkCredential().Password
        }
    }

    $s3Block = @(
        's3 ='
        "  max_concurrent_requests = $($perf.MaxConcurrentRequestsPerFile)"
        '  max_queue_size = 10000'
        "  multipart_threshold = $($perf.MultipartThresholdMB)MB"
        "  multipart_chunksize = $($perf.MultipartChunkSizeMB)MB"
    )
    if ($perf.MaxBandwidth) { $s3Block += "  max_bandwidth = $($perf.MaxBandwidth)" }

    $awsConfig = Join-Path $WorkDir 'config'
    Set-Content -Path $awsConfig -Value (Merge-AwsS3Settings $baseConfig $section $s3Block) -Encoding ASCII
    $env:AWS_CONFIG_FILE = $awsConfig
}

# Returns an ordinal (case-sensitive) map of S3 key -> size for everything under a prefix.
function Get-S3ObjectIndex([string]$Prefix) {
    $index = [System.Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
    $cliArgs = @('s3api', 'list-objects-v2', '--bucket', $script:Bucket, '--prefix', $Prefix,
                 '--query', 'Contents[].{Key:Key,Size:Size}', '--output', 'json') + $script:OwnerArgs
    $json = Invoke-Aws $cliArgs
    if ($json -and $json.Trim() -ne 'null') {
        foreach ($obj in ($json | ConvertFrom-Json)) { $index[$obj.Key] = [int64]$obj.Size }
    }
    return $index
}

# True when no other process has the file open for writing (i.e. the backup is finished).
function Test-FileReady([IO.FileInfo]$File) {
    try {
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $stream.Dispose()
        return $true
    }
    catch [IO.IOException] {
        # 0x20 = sharing violation, 0x21 = lock violation: SQL Server still has the file open.
        if (($_.Exception.HResult -band 0xFFFF) -in 0x20, 0x21) { return $false }
        Write-Log "Cannot read $($File.FullName); skipping. $($_.Exception.Message)" 'WARN'
        return $false
    }
    catch {
        Write-Log "Cannot read $($File.FullName); skipping. $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Get-UploadCandidates($Config, [string[]]$DatabaseFilter, [string[]]$TypeFilter) {
    $src = $Config.Source
    $serverFolder = if ($src.ServerFolder) { $src.ServerFolder } else { $env:COMPUTERNAME }
    $serverPath = Join-Path $src.RootPath $serverFolder
    if (-not (Test-Path -LiteralPath $serverPath)) { throw "Server backup folder '$serverPath' does not exist." }

    # Use the folder name exactly as it is on disk so the S3 keys mirror the local tree.
    $serverDir = Get-ChildItem -LiteralPath $src.RootPath -Directory | Where-Object { $_.Name -eq $serverFolder } | Select-Object -First 1
    $serverFolder = $serverDir.Name
    $serverPath = $serverDir.FullName
    $prefix = ($Config.S3.Prefix -replace '\\', '/').Trim('/')
    $extensions = @($src.FileExtensions | ForEach-Object { $_.ToLowerInvariant() })
    $newestAllowed = (Get-Date).AddMinutes(-[int]$src.MinFileAgeMinutes)
    $oldestAllowed = if ([int]$src.MaxFileAgeDays -gt 0) { (Get-Date).AddDays(-[int]$src.MaxFileAgeDays) } else { [datetime]::MinValue }

    $dbDirs = Get-ChildItem -LiteralPath $serverPath -Directory | Where-Object {
        $name = $_.Name
        ($DatabaseFilter | Where-Object { $name -like $_ }) -and
        -not ($src.ExcludeDatabases | Where-Object { $name -like $_ })
    }

    $missing = @($DatabaseFilter | Where-Object { $_ -notmatch '[\*\?\[]' -and $_ -notin $dbDirs.Name })
    foreach ($m in $missing) { Write-Log "Database folder not found: $serverPath\$m" 'WARN' }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $skippedExisting = 0
    $skippedBusy = 0

    foreach ($dbDir in $dbDirs) {
        $dbPrefix = (@($prefix, $serverFolder, $dbDir.Name) | Where-Object { $_ }) -join '/'
        $existing = Get-S3ObjectIndex "$dbPrefix/"

        $typeDirs = Get-ChildItem -LiteralPath $dbDir.FullName -Directory | Where-Object { $_.Name -in $TypeFilter }
        foreach ($typeDir in $typeDirs) {
            $storageClass = $Config.S3.StorageClass[$typeDir.Name.ToUpperInvariant()]
            if (-not $storageClass) { $storageClass = $Config.S3.StorageClass['Default'] }
            if (-not $storageClass) { $storageClass = 'STANDARD' }

            $files = Get-ChildItem -LiteralPath $typeDir.FullName -File -Recurse | Where-Object {
                $_.Extension.ToLowerInvariant() -in $extensions -and $_.LastWriteTime -ge $oldestAllowed
            }
            foreach ($file in $files) {
                # Key = <Prefix>/<Server>/<Database>/ + the file's path below the database folder,
                # so any subfolders (Full\2026\10\x.bak) are kept as-is in S3.
                $relativePath = $file.FullName.Substring($dbDir.FullName.Length).TrimStart('\') -replace '\\', '/'
                $key = "$dbPrefix/$relativePath"
                if ($existing.ContainsKey($key)) {
                    if ($existing[$key] -eq $file.Length) { $skippedExisting++; continue }
                    Write-Log "Size mismatch in S3 for $key (local $($file.Length), S3 $($existing[$key])); re-uploading." 'WARN'
                }
                if ($file.LastWriteTime -gt $newestAllowed -or -not (Test-FileReady $file)) { $skippedBusy++; continue }

                $candidates.Add([pscustomobject]@{
                    File         = $file
                    Key          = $key
                    StorageClass = $storageClass
                    Attempts     = 0
                    Process      = $null
                    StdErrFile   = $null
                    StdOutFile   = $null
                    StartTime    = $null
                })
            }
        }
    }

    Write-Log ("Scan complete: {0} database folder(s), {1} file(s) to upload, {2} already in S3, {3} still being written / too new." -f
        @($dbDirs).Count, $candidates.Count, $skippedExisting, $skippedBusy)
    return , $candidates
}

function Start-Upload($Job, $Config, [string]$WorkDir) {
    $s3 = $Config.S3
    $cliArgs = @('s3', 'cp', $Job.File.FullName, "s3://$($script:Bucket)/$($Job.Key)",
                 '--storage-class', $Job.StorageClass, '--no-progress', '--only-show-errors')
    if ($s3.ServerSideEncryption) { $cliArgs += @('--sse', $s3.ServerSideEncryption) }
    if ($s3.ServerSideEncryption -eq 'aws:kms' -and $s3.KmsKeyId) { $cliArgs += @('--sse-kms-key-id', $s3.KmsKeyId) }
    if ($s3.ChecksumAlgorithm) { $cliArgs += @('--checksum-algorithm', $s3.ChecksumAlgorithm) }
    $cliArgs += $script:OwnerArgs

    $id = [guid]::NewGuid().ToString('N')
    $Job.StdOutFile = Join-Path $WorkDir "$id.out"
    $Job.StdErrFile = Join-Path $WorkDir "$id.err"
    $Job.Attempts++
    $Job.StartTime = Get-Date

    $argLine = ($cliArgs | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    $proc = Start-Process -FilePath $script:AwsCli -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $Job.StdOutFile -RedirectStandardError $Job.StdErrFile
    $null = $proc.Handle   # caching the handle keeps ExitCode readable after exit
    $Job.Process = $proc
    Write-Log ("Uploading {0} ({1}) -> {2} [attempt {3}]" -f $Job.File.Name, (Format-Size $Job.File.Length), $Job.StorageClass, $Job.Attempts)
}

function Test-UploadedObject($Job) {
    $cliArgs = @('s3api', 'head-object', '--bucket', $script:Bucket, '--key', $Job.Key,
                 '--query', 'ContentLength', '--output', 'text') + $script:OwnerArgs
    $remoteSize = [int64]((Invoke-Aws $cliArgs).Trim())
    if ($remoteSize -ne $Job.File.Length) { throw "S3 object is $remoteSize bytes, local file is $($Job.File.Length) bytes." }
}

function Invoke-UploadQueue($Candidates, $Config, [string]$WorkDir) {
    $maxFiles = [int]$Config.Performance.MaxConcurrentFiles
    $maxAttempts = 1 + [int]$Config.Performance.FileRetryCount

    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($c in ($Candidates | Sort-Object { $_.File.LastWriteTime })) { $pending.Enqueue($c) }
    $script:Running = [System.Collections.Generic.List[object]]::new()
    $result = [pscustomobject]@{ Uploaded = 0; Bytes = [int64]0; Failed = [System.Collections.Generic.List[string]]::new() }

    while ($pending.Count -gt 0 -or $script:Running.Count -gt 0) {
        while ($script:Running.Count -lt $maxFiles -and $pending.Count -gt 0) {
            $job = $pending.Dequeue()
            Start-Upload $job $Config $WorkDir
            $script:Running.Add($job)
        }

        Start-Sleep -Milliseconds 500

        foreach ($job in @($script:Running)) {
            if (-not $job.Process.HasExited) { continue }
            [void]$script:Running.Remove($job)

            $errorText = $null
            if ($job.Process.ExitCode -ne 0) {
                $errorText = "aws s3 cp exit code $($job.Process.ExitCode)"
                if (Test-Path -LiteralPath $job.StdErrFile) {
                    $stderr = (Get-Content -LiteralPath $job.StdErrFile -Raw)
                    if ($stderr) { $errorText += ": " + $stderr.Trim() }
                }
            }
            else {
                try { Test-UploadedObject $job } catch { $errorText = "Verification failed: $_" }
            }
            Remove-Item -LiteralPath $job.StdOutFile, $job.StdErrFile -ErrorAction SilentlyContinue

            if (-not $errorText) {
                $seconds = [math]::Max(((Get-Date) - $job.StartTime).TotalSeconds, 0.001)
                $result.Uploaded++
                $result.Bytes += $job.File.Length
                Write-Log ("Uploaded {0} in {1:N0}s ({2:N1} MB/s)" -f $job.Key, $seconds, ($job.File.Length / 1MB / $seconds))
            }
            elseif ($job.Attempts -lt $maxAttempts) {
                Write-Log "Upload failed for $($job.Key), will retry. $errorText" 'WARN'
                $pending.Enqueue($job)
            }
            else {
                Write-Log "Upload FAILED for $($job.Key) after $($job.Attempts) attempt(s). $errorText" 'ERROR'
                $result.Failed.Add($job.Key)
            }
        }
    }
    return $result
}

#endregion

#region Main

# -WhatIf only controls the upload step; logging and temp files must still work in a dry run.
$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

$script:ResolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -LiteralPath $script:ResolvedConfigPath

$logDir = $config.Logging.LogDirectory
if (-not $logDir) { $logDir = Join-Path $PSScriptRoot 'logs' }
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:LogFile = Join-Path $logDir ("S3Upload_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$mutex = New-Object System.Threading.Mutex($false, 'Global\SqlBackupS3Upload')
$hasLock = $false
try { $hasLock = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $hasLock = $true }   # previous run crashed; lock is ours now
if (-not $hasLock) {
    Write-Log 'Another upload run is already in progress. Exiting.' 'WARN'
    $mutex.Dispose()
    exit 0
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("S3Upload_{0}" -f $PID)
$exitCode = 0
$script:Running = $null
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

try {
    Assert-Config $config
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    $script:AwsCli = Resolve-AwsCli $config.AwsCliPath
    $version = Invoke-Aws @('--version')
    if ($version -notmatch 'aws-cli/2\.') { throw "AWS CLI v2 is required; found: $version" }

    $script:Bucket = $config.S3.Bucket
    $script:OwnerArgs = @()
    if ($config.S3.ExpectedBucketOwner) { $script:OwnerArgs = @('--expected-bucket-owner', $config.S3.ExpectedBucketOwner) }

    Initialize-AwsEnvironment $config $workDir

    $dbFilter = if ($Database) { $Database } else { @($config.Source.Databases) }
    $typeFilter = if ($BackupType) { $BackupType } else { @($config.Source.BackupTypes) }

    Write-Log ("Starting upload to s3://{0}/{1} ({2}) using {3}; auth mode {4}" -f
        $script:Bucket, $config.S3.Prefix, $config.S3.Region, $version.Trim(), $config.Credentials.Mode)

    $candidates = Get-UploadCandidates $config $dbFilter $typeFilter

    if ($candidates.Count -eq 0) {
        Write-Log 'Nothing to upload.'
    }
    elseif ($dryRun) {
        foreach ($c in $candidates) { Write-Log ("[WhatIf] {0} -> s3://{1}/{2} ({3})" -f $c.File.FullName, $script:Bucket, $c.Key, $c.StorageClass) }
        Write-Log ("[WhatIf] {0} file(s), {1} total." -f $candidates.Count, (Format-Size (($candidates | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum)))
    }
    else {
        $result = Invoke-UploadQueue $candidates $config $workDir
        $seconds = [math]::Max($stopwatch.Elapsed.TotalSeconds, 0.001)
        Write-Log ("Finished: {0} uploaded ({1}, {2:N1} MB/s overall), {3} failed, elapsed {4:hh\:mm\:ss}." -f
            $result.Uploaded, (Format-Size $result.Bytes), ($result.Bytes / 1MB / $seconds), $result.Failed.Count, $stopwatch.Elapsed)
        if ($result.Failed.Count -gt 0) { $exitCode = 1 }
    }
}
catch {
    Write-Log "Run failed: $_" 'ERROR'
    $exitCode = 1
}
finally {
    # If the script is stopped mid-run, don't leave orphaned uploads behind.
    if ($script:Running) {
        foreach ($job in $script:Running) {
            if ($job.Process -and -not $job.Process.HasExited) { $job.Process.Kill() }
        }
    }
    Restore-AwsEnvironment
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $logDir -Filter 'S3Upload_*.log' -File |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$config.Logging.RetainLogDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

exit $exitCode

#endregion
