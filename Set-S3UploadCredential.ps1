#Requires -Version 5.1
<#
.SYNOPSIS
    Stores an AWS access key for Upload-BackupsToS3.ps1, encrypted with Windows DPAPI.

.DESCRIPTION
    Only needed when Credentials.Mode = 'AccessKey'. On EC2, attach an IAM role to the
    instance and use Mode = 'InstanceProfile' instead; then no key is stored at all.

    The file can only be decrypted by the same Windows account on the same machine, so run
    this while logged on as the account that runs the upload job (e.g. the SQL Agent
    service account or the scheduled task's account).

.EXAMPLE
    .\Set-S3UploadCredential.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'config\s3-credential.xml')
)

$ErrorActionPreference = 'Stop'

$credential = Get-Credential -Message 'User name = AWS Access Key ID, Password = AWS Secret Access Key'
if (-not $credential.UserName -or $credential.Password.Length -eq 0) { throw 'Access key ID and secret are both required.' }

$credential | Export-Clixml -LiteralPath $Path

# Restrict the file to the current user, SYSTEM and Administrators.
$acl = Get-Acl -LiteralPath $Path
$acl.SetAccessRuleProtection($true, $false)
foreach ($identity in [Security.Principal.WindowsIdentity]::GetCurrent().Name, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
}
Set-Acl -LiteralPath $Path -AclObject $acl

Write-Host "Saved encrypted credential for $([Security.Principal.WindowsIdentity]::GetCurrent().Name) to $Path"
