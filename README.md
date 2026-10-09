# Database Maintenance Automation

PowerShell scripts for SQL Server backup maintenance.

## Upload-BackupsToS3.ps1

Uploads SQL Server backup files to Amazon S3, keeping the local folder structure:

```
C:\SQLSERVER\DATABASE_BACKUPS\<Server>\<Database>\<Full|Diff|Log>\file.bak
  -> s3://<Bucket>/<Prefix>/<Server>/<Database>/<Full|Diff|Log>/file.bak
```

- Large files are split into parts that upload in parallel (AWS CLI multipart), and several files upload at once.
- Files already in S3 with the same size are skipped, so reruns are cheap.
- Files still being written by SQL Server, or modified in the last few minutes, are skipped.
- Each upload is verified against the object size in S3; failed files are retried.
- Exits with code 1 if any file fails, so SQL Agent / Task Scheduler report the failure.

### Requirements

- Windows PowerShell 5.1 or PowerShell 7
- [AWS CLI v2](https://awscli.amazonaws.com/AWSCLIV2.msi)

### Configuration

All settings are in [config/S3BackupUpload.psd1](config/S3BackupUpload.psd1): bucket, region, prefix,
credentials, databases, storage class per backup type and throughput settings.

Credential modes (`Credentials.Mode`):

| Mode | Use when |
|---|---|
| `InstanceProfile` | Running on EC2 with an IAM role attached (recommended, no stored secrets) |
| `Profile` | Running locally with a named AWS CLI profile / `aws login` session |
| `AccessKey` | An access key is unavoidable; store it encrypted with `Set-S3UploadCredential.ps1` |

Never put access keys in the config file. For local runs, copy the config to
`config/S3BackupUpload.local.psd1` (git-ignored) and set `Mode = 'Profile'`.

### Running

```powershell
# Dry run: list what would be uploaded
.\Upload-BackupsToS3.ps1 -WhatIf

# Upload everything in the config
.\Upload-BackupsToS3.ps1

# One database / one backup type, with a different config
.\Upload-BackupsToS3.ps1 -ConfigPath .\config\S3BackupUpload.local.psd1 -Database CultiveraMarket -BackupType Log
```

Logs are written to `Logging.LogDirectory` (default `C:\SQLSERVER\Scripts\S3Upload\logs`), one file per run,
and are removed after `Logging.RetainLogDays`.

### Minimum IAM permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::s2s-backups" },
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::s2s-backups/*" }
  ]
}
```
