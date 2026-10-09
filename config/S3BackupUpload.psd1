@{
    # =====================================================================
    # S3 destination
    # The local folder tree below Source.RootPath is mirrored in S3, e.g.
    #   C:\SQLSERVER\DATABASE_BACKUPS\SERVERNAME\CultiveraMarket\Full\x.bak
    #   -> s3://<Bucket>/<Prefix>/SERVERNAME/CultiveraMarket/Full/x.bak
    # Prefix = '' puts the tree at the root of the bucket.
    # Note: s2s-backups has a lifecycle rule that deletes every object after 400 days.
    # =====================================================================
    S3 = @{
        Bucket               = 's2s-backups'
        Region               = 'us-east-1'
        Prefix               = ''

        # Optional: AWS account ID that must own the bucket (protects against
        # uploading to a look-alike bucket in another account). '' = not checked.
        ExpectedBucketOwner  = ''

        # 'AES256' (SSE-S3) or 'aws:kms' (SSE-KMS). '' = bucket default.
        ServerSideEncryption = 'AES256'
        KmsKeyId             = ''          # only used with 'aws:kms'; '' = AWS managed key

        # Storage class per backup folder. 'Default' is used for any other folder
        # (e.g. FULL_COPY_ONLY). STANDARD_IA has a 30-day minimum and a 128 KB
        # minimum billable size, so small/short-lived log backups stay STANDARD.
        StorageClass         = @{
            FULL    = 'STANDARD_IA'
            DIFF    = 'STANDARD_IA'
            LOG     = 'STANDARD'
            Default = 'STANDARD'
        }

        # End-to-end integrity check computed by the CLI and verified by S3.
        # CRC32C | CRC32 | SHA256 | SHA1 | '' (none)
        ChecksumAlgorithm    = 'CRC32C'
    }

    # =====================================================================
    # Credentials
    #   InstanceProfile : use the IAM role attached to this EC2 instance.
    #                     RECOMMENDED - no secrets stored on the server.
    #   Profile         : use a named profile from the run-as account's
    #                     %USERPROFILE%\.aws\credentials file.
    #   AccessKey       : access key stored DPAPI-encrypted in AccessKeyFile.
    #                     Create it with Set-S3UploadCredential.ps1 while logged
    #                     on as the account that will run the upload job.
    # Never put a plain-text secret key in this file.
    # =====================================================================
    Credentials = @{
        Mode          = 'InstanceProfile'
        ProfileName   = ''
        AccessKeyFile = 's3-credential.xml'   # relative paths resolve from this config folder
    }

    # =====================================================================
    # Source backup files
    # =====================================================================
    Source = @{
        RootPath          = 'C:\SQLSERVER\DATABASE_BACKUPS'
        ServerFolder      = 'EC2AMAZ-JR5ORIO'   # '' = use $env:COMPUTERNAME
        BackupTypes       = @('FULL', 'DIFF', 'LOG')
        FileExtensions    = @('.bak', '.trn')

        # Databases to upload (wildcards allowed, e.g. 'S2S_PR_*'). @('*') = all.
        Databases         = @(
            'CultiveraMarket'
            'S2S_PR_731_ROLLING_FARMS'
            'S2S_PR_63_FORBIDDEN_FARMS'
            'S2S_PR_105_SEATTLES_PRIVATE_RESERVE'
            'S2S_PR_88_PHAT_N_STICKY'
            'S2S_RT_10941_LOCAL_ROOTS_MARIJUANA'
            'S2S_RT_10942_LOCAL_ROOTS_MARIJUANA'
            'S2S_PR_118_FIVE_O_2'
            'S2S_PR_613_SATURN_GROUP'
            'S2S_PR_78_CANNASEURS_CHOICE'
            'S2S_PR_567_LIFTED_CANNABIS'
        )
        ExcludeDatabases  = @()

        # Skip files modified in the last N minutes (backup may still be writing).
        MinFileAgeMinutes = 5
        # Ignore files older than N days. 0 = no limit.
        MaxFileAgeDays    = 0
    }

    # =====================================================================
    # Throughput tuning
    # Total parallel S3 requests ~= MaxConcurrentFiles * MaxConcurrentRequestsPerFile.
    # Start here and raise it if the instance's network bandwidth is not saturated.
    # =====================================================================
    Performance = @{
        MaxConcurrentFiles           = 4
        MaxConcurrentRequestsPerFile = 16
        MultipartThresholdMB         = 64
        MultipartChunkSizeMB         = 64     # keep file size / chunk size under 10,000 parts
        MaxBandwidth                 = ''     # per file, e.g. '50MB/s'. '' = unlimited
        FileRetryCount               = 2      # whole-file retries after the CLI's own retries
    }

    # =====================================================================
    # Logging
    # =====================================================================
    Logging = @{
        LogDirectory  = 'C:\SQLSERVER\Scripts\S3Upload\logs'
        RetainLogDays = 30
    }

    # Full path to aws.exe. '' = auto-detect (PATH, then the default install folder).
    AwsCliPath = ''
}
