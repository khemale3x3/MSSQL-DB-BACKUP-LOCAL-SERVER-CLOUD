# Author: Khem @le
# Title: SQL Server Backup Script
# Script to perform full, diff and audit backup of SQL Server databases
# This script can also send the backup details to a remote SQL Server database
# Accepts positional arguments: full, diff or audit

# Usage: sqlbackup.ps1 [full|diff|audit]

# THINGS TO MAKE SURE BEFORE USING THIS SCRIPT

# 1. All the spaces, underscores and dashes in database names will be removed on backup directory name and backup file name
# 2. All directory paths should be specified as absolute paths without trailing slashes
# 3. User should specify backup type while calling the script, otherwise full backup will be performed
# 4. The name of the audit backup should follow the pattern: Audit<DBNAME>. DBNAME should have no spaces, dashes or underscores
# 5. The audit folder location should be specified under audit backup settings
# 6. To upload backups to google drive, this script uses 'gdrive' tool which needs to be installed and confiugured before running this script
    # It is available at: https://github.com/glotlabs/gdrive
    # Step 1: Download executable from releases section
    # Step 2: Put executable file somewhere and add that location to system path
    # Step 4: Follow provided guide on readme file to generate OAuth credentials and add an account
# 7. 7Zip Powershell module must be installed to compress backups - Run: Install-Module -Name 7Zip4Powershell

# List of Databases and respective S3 buckets
# If S3 bucket sync is not required, set an empty string in place of bucket path
$DATABASES = @{
    "[DATABASENAME]" = "S3 full path" #DBNAME , S3 full path
}

# Common Settings
$MSSQL_USER = "DB Backup user" #backup user name
$MSSQL_PASS = "DB Password" #backup user password
$MSSQL_HOST = "DB NAME" #db name
$MSSQL_PORT = ""
$SYNC_TO_S3 = $true
$SYNC_TO_GDRIVE = $false
$SEND_LOGS = $true

# Date variables
$DATE = Get-Date -Format "yyyy_MM_dd"
$TIMESTAMP = Get-Date -Format "yyyy_MM_dd_HH_mm_ss"

# Default backup type
$TYPE = "full"

# Set backup type
if ($args.Length -gt 0) {
    switch ($args[0]) {
        "diff" { $TYPE = "diff"; break }
        "full" { $TYPE = "full"; break }
        "audit" { $TYPE = "audit"; break }
        default {
            Write-Host "Invalid backup type. Accepted values are 'full', 'diff' and 'audit'."
            exit
        }
    }
}

if ($TYPE -eq "full") {
    # Full backup settings
    $RETENTION_DAYS = "6"
    $BACKUP_BASE_DIR = "LOCAL BACKUP DIR" #local db backup directory path
    $LOG_BASE_DIR = "DLOCAL BACKUP LOG DIR"  # local backup log dir path
}
elseif ($TYPE -eq "audit") {
    # Audit backup settings
    $RETENTION_DAYS = "6"
    $AUDIT_BASE_FOLDER="AUDIT DIR"
    $BACKUP_BASE_DIR = "AUDIT DIR FULL NAME AND PATH"
    $LOG_BASE_DIR = "AUDIT LOG DIR"
}
else {
    # Differential backup settings
    $RETENTION_DAYS = "1"
    $BACKUP_BASE_DIR = "DIFFERENTIAL BACKUP DIR"
    $LOG_BASE_DIR = "DIFFERENTIAL BACKUP LOG DIR"
}

# Create base backup and log directories
New-Item -ItemType Directory -Path $BACKUP_BASE_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $LOG_BASE_DIR -Force | Out-Null

# Functions to insert backup details to a remote database
function Send-ToDatabase([string]$Name, [string]$FileName, [string]$FileSize, [string]$Type, [string]$Status, [string]$S3Path, [string]$Message) {
    if ($SEND_LOGS){
        # Remote database configurations - to send database backup records
        $MSSQL_REMOTE_HOST = "000.00.00.000" #Host ip
        $MSSQL_REMOTE_PORT = 55451  #port
        $MSSQL_REMOTE_USER = "Usr_Backuprecord" #username
        $MSSQL_REMOTE_PASS = "PASSWORD" #password
        $MSSQL_REMOTE_DB = "BACKUP_RECORDS" #DB name
        $MSSQL_REMOTE_TABLE = "LOCALBACKUP_RECORDS" #DB table name

        $QUERY = "SET QUOTED_IDENTIFIER ON; INSERT INTO $MSSQL_REMOTE_TABLE(NAME, FILE_NAME, FILE_SIZE, TYPE, STATUS, S3_PATH, MESSAGE) VALUES ('$Name', '$FileName', '$FileSize', '$Type', '$Status', '$S3Path', '$Message')"
        sqlcmd -S $MSSQL_REMOTE_HOST,$MSSQL_REMOTE_PORT -U $MSSQL_REMOTE_USER -P $MSSQL_REMOTE_PASS -d $MSSQL_REMOTE_DB -Q $QUERY | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_backup_record.log"

        # Check exit status and add logs
        if (!$?){
            "## $TIMESTAMP $DB Error: Could not send backup records to remote database. Please check your remote database configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_backup_record.log"
        }
        else{
            "## $TIMESTAMP $DB Backup details sent to remote database." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_backup_record.log"
        }
    }
}

# Check if server port is available and create connection string
if($MSSQL_PORT -ne ""){
    $MSSQL_CONN_STRING = "$MSSQL_HOST,$MSSQL_PORT"
}
else{
    $MSSQL_CONN_STRING = $MSSQL_HOST
}

# Perform backups
if ($TYPE -eq "full"){
    foreach ($DB in $DATABASES.Keys) {
        # Get clean db name (replaces _, - and space with nothing)
        $CLEAN_DB_NAME = $DB -replace "[ _-]"
        # Set backup directory
        $BACKUP_DIR = $BACKUP_BASE_DIR + "/" + "$CLEAN_DB_NAME/$DATE"
        # Set file name
        $FILE_NAME = "$CLEAN_DB_NAME" + "_FULL_" + $TIMESTAMP
        # Get S3 bucket name
        $S3_BUCKET_NAME = $DATABASES[$DB]
        # Create backup directory
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not create a backup directory." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "FULL" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not create a backup directory."
            continue
        }
        # Get full backup directory path
        $BACKUP_DIR = Convert-Path $BACKUP_DIR
        # Backup database
        sqlcmd -S $MSSQL_CONN_STRING -U $MSSQL_USER -P $MSSQL_PASS -Q "BACKUP DATABASE [$DB] TO DISK = N'$BACKUP_DIR/$FILE_NAME.bak' WITH NOFORMAT, NOINIT, SKIP, NOREWIND, STATS=10" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not perform a database backup. Please check your database and server configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "FULL" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not perform a database backup. Please check your database and server configurations."
            continue
        }
        Compress-7Zip -Path "$BACKUP_DIR/$FILE_NAME.bak" -ArchiveFileName "$FILE_NAME.zip" -OutputPath "$BACKUP_DIR" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not perform a database backup. Please check your database and server configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "FULL" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not perform a database backup. Please check your database and server configurations."
            continue
        }
        Remove-Item "$BACKUP_DIR/$FILE_NAME.bak" | Out-Null
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not perform a database backup. Please check your database and server configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "FULL" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not perform a database backup. Please check your database and server configurations."
            continue
        }
        # Sync to S3
        if ($S3_BUCKET_NAME -ne "" -and $SYNC_TO_S3) {
            aws s3 sync $BACKUP_DIR "s3://$S3_BUCKET_NAME" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
            # Check exit status
            if (!$?){
                # Add log
                "## $TIMESTAMP $DB Error: Could not upload backups to S3. Please check your AWS CLI and S3 bucket configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
                # Send to database
                Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "FULL" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not upload backups to S3. Please check your AWS CLI and S3 bucket configurations."
                continue
            }
        }
        # Sync to Google Drive
        if ($SYNC_TO_GDRIVE) {
            # Check if full backups folder exists
            $DRIVE_BACKUP_FOLDER = gdrive files list --query "name = 'FullSQLBackups'" --field-separator "#_#_#" --skip-header
            # Check exit status
            if (!$?){
                # Add log
                "## $TIMESTAMP $DB Error: Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
                # Send to database
                Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "FULL" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations."
                continue
            }
            # Check if folder exists in google drive
            if($null -eq $DRIVE_BACKUP_FOLDER){
                $DRIVE_BACKUP_FOLDER = gdrive files mkdir --print-only-id 'FullSQLBackups'
            }
            else {
                $DRIVE_BACKUP_FOLDER = $DRIVE_BACKUP_FOLDER.Split("#_#_#")[0]
            }
            gdrive files upload "$BACKUP_DIR/$FILE_NAME.zip" --parent $DRIVE_BACKUP_FOLDER  | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
            # Check exit status
            if (!$?){
                # Add log
                "## $TIMESTAMP $DB Error: Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
                # Send to database
                Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "FULL" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations."
                continue
            }
        }
        # Add log
        "## $TIMESTAMP FULL BACKUP SUCCESSFUL FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        # Remove old files
        Get-ChildItem $BACKUP_BASE_DIR/$CLEAN_DB_NAME | Where-Object {
            $_.LastWriteTime -lt (Get-Date).AddDays(-$RETENTION_DAYS)
        } | Remove-Item -Recurse -Force
        # Get backup file size
        $BACKUP_SIZE = [Math]::Round(((Get-ChildItem $BACKUP_DIR/$FILE_NAME.zip).Length/1MB),2)
        # Call function to send backup details to database
        Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize $BACKUP_SIZE"M" -Type "FULL" -Status "SUCCESS" -S3Path $S3_BUCKET_NAME -Message "Full backup successful for $DB."
    }
    # Remove old log texts
    Get-Content -Tail 4500 -Path "$LOG_BASE_DIR/mssql_full_backup.log" | Set-Content -Path "$LOG_BASE_DIR/tempfull.log"
    Move-Item -Path "$LOG_BASE_DIR/tempfull.log" -Destination "$LOG_BASE_DIR/mssql_full_backup.log" -Force
}
elseif ($TYPE -eq "audit") {
    foreach ($DB in $DATABASES.Keys) {
        # Check if audit exists
        $AUDIT_FOLDER = $AUDIT_BASE_FOLDER
        if (Test-Path $AUDIT_FOLDER) {
            # Get clean db name (replaces _, - and space with nothing)
            $CLEAN_DB_NAME = $DB -replace "[ _-]"
            # Set backup directory
            $BACKUP_DIR = $BACKUP_BASE_DIR + "/" + "$CLEAN_DB_NAME/$DATE"
            # Set file name
            $FILE_NAME = "$CLEAN_DB_NAME" + "_AUDIT_" + $TIMESTAMP
            # Get S3 bucket name
            $S3_BUCKET_NAME = $DATABASES[$DB]
            # Create backup directory
            New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
            # Check exit status
            if (!$?){
                # Add log
                "## $TIMESTAMP $DB Error: Could not create a backup directory." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
                # Send to database
                Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "AUDIT" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not create a backup directory."
                continue
            }
            # Get full backup directory path
            $BACKUP_DIR = Convert-Path $BACKUP_DIR
            # Zip and move audit folder
            Compress-7Zip -Path ($AUDIT_BASE_FOLDER) -ArchiveFileName "$FILE_NAME.zip" -OutputPath "$BACKUP_DIR" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
            # Sync to S3
            if ($S3_BUCKET_NAME -ne "" -and $SYNC_TO_S3) {
                aws s3 sync $BACKUP_DIR "s3://$S3_BUCKET_NAME" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
                # Check exit status
                if (!$?){
                    # Add log
                    "## $TIMESTAMP $DB Error: Could not upload backups to S3. Please check your AWS CLI and S3 bucket configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
                    # Send to database
                    Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "AUDIT" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not upload backups to S3. Please check your AWS CLI and S3 bucket configurations."
                    continue
                }
            }
            # Sync to Google Drive
            if ($SYNC_TO_GDRIVE) {
                # Check if full backups folder exists
                $DRIVE_BACKUP_FOLDER = gdrive files list --query "name = 'AuditSQLBackups'" --field-separator "#_#_#" --skip-header
                # Check exit status
                if (!$?){
                    # Add log
                    "## $TIMESTAMP $DB Error: Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
                    # Send to database
                    Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "AUDIT" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations."
                    continue
                }
                # Check if folder exists in google drive
                if($null -eq $DRIVE_BACKUP_FOLDER){
                    $DRIVE_BACKUP_FOLDER = gdrive files mkdir --print-only-id 'AuditSQLBackups'
                }
                else {
                    $DRIVE_BACKUP_FOLDER = $DRIVE_BACKUP_FOLDER.Split("#_#_#")[0]
                }
                gdrive files upload "$BACKUP_DIR/$FILE_NAME.zip" --parent $DRIVE_BACKUP_FOLDER  | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
                # Check exit status
                if (!$?){
                    # Add log
                    "## $TIMESTAMP $DB Error: Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
                    # Send to database
                    Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "AUDIT" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not upload backups to Google Drive. Please check your Google Drive and gdrive tool configurations."
                    continue
                }
            }
            # Add log
            "## $TIMESTAMP AUDIT BACKUP SUCCESSFUL FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
            # Remove old files
            Get-ChildItem $BACKUP_BASE_DIR/$CLEAN_DB_NAME | Where-Object { 
                $_.LastWriteTime -lt (Get-Date).AddDays(-$RETENTION_DAYS) 
            } | Remove-Item -Recurse -Force
            # Get backup file size
            $BACKUP_SIZE = [Math]::Round(((Get-ChildItem $BACKUP_DIR/$FILE_NAME.zip).Length/1MB),2)
            # Call function to send backup details to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize $BACKUP_SIZE"M" -Type "AUDIT" -Status "SUCCESS" -S3Path $S3_BUCKET_NAME -Message "Audit backup successful for $DB."
        } else {
            "## $TIMESTAMP NO DATABASE AUDIT FOUND FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
        }
    }
    # Remove old log texts
    Get-Content -Tail 4500 -Path "$LOG_BASE_DIR/mssql_audit_backup.log" | Set-Content -Path "$LOG_BASE_DIR/tempaudit.log"
    Move-Item -Path "$LOG_BASE_DIR/tempaudit.log" -Destination "$LOG_BASE_DIR/mssql_audit_backup.log" -Force
}
else {
    foreach ($DB in $DATABASES.Keys) {
        # Get clean db name (replaces _, - and space with nothing)
        $CLEAN_DB_NAME = $DB -replace "[ _-]"
        # Set backup directory
        $BACKUP_DIR = $BACKUP_BASE_DIR + "/" + "$CLEAN_DB_NAME/$DATE"
        # Set file name
        $FILE_NAME = "$CLEAN_DB_NAME" + "_DIFF_" + $TIMESTAMP
        # Get S3 bucket name
        $S3_BUCKET_NAME = $DATABASES[$DB]
        # Create backup directory
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not create a backup directory." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "DIFF" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not create a backup directory."
            continue
        }
        # Get full backup directory path
        $BACKUP_DIR = Convert-Path $BACKUP_DIR
        # Backup Database
        sqlcmd -S $MSSQL_CONN_STRING -U $MSSQL_USER -P $MSSQL_PASS -Q "BACKUP DATABASE [$DB] TO DISK = N'$BACKUP_DIR/$FILE_NAME.bak' WITH DIFFERENTIAL, NOFORMAT, NOINIT, SKIP, NOREWIND, STATS=10" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not perform a database backup. Please check your database and server configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "DIFF" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not perform a database backup. Please check your database and server configurations."
            continue
        }
        Compress-7Zip -Path "$BACKUP_DIR/$FILE_NAME.bak" -ArchiveFileName "$FILE_NAME.zip" -OutputPath "$BACKUP_DIR" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not perform a database backup. Please check your database and server configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "DIFF" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not perform a database backup. Please check your database and server configurations."
            continue
        }
        Remove-Item "$BACKUP_DIR/$FILE_NAME.bak" | Out-Null
        # Check exit status
        if (!$?){
            # Add log
            "## $TIMESTAMP $DB Error: Could not perform a database backup. Please check your database and server configurations." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
            # Send to database
            Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize "0" -Type "DIFF" -Status "FAIL" -S3Path $S3_BUCKET_NAME -Message "Could not perform a database backup. Please check your database and server configurations."
            continue
        }
        # Add log
        "## $TIMESTAMP DIFFERENTIAL BACKUP SUCCESSFUL FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
        # Remove old files
        Get-ChildItem $BACKUP_BASE_DIR/$CLEAN_DB_NAME | Where-Object { 
            $_.LastWriteTime -lt (Get-Date).AddDays(-$RETENTION_DAYS) 
        } | Remove-Item -Recurse -Force
        # Get backup file size
        # $BACKUP_SIZE = [Math]::Round(((Get-ChildItem $BACKUP_DIR/$FILE_NAME.zip).Length/1MB),2)
        # Call function to send backup details to database
        # Send-ToDatabase -Name $DB -FileName $FILE_NAME -FileSize $BACKUP_SIZE"M" -Type "DIFF" -Status "SUCCESS" -S3Path $S3_BUCKET_NAME -Message "Differential backup successful for $DB."
    }
    # Remove old log texts
    Get-Content -Tail 4500 -Path "$LOG_BASE_DIR/mssql_diff_backup.log" | Set-Content -Path "$LOG_BASE_DIR/tempdiff.log"
    Move-Item -Path "$LOG_BASE_DIR/tempdiff.log" -Destination "$LOG_BASE_DIR/mssql_diff_backup.log" -Force
}