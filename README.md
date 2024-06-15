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
