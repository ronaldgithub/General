#Requires -Version 5.1
<#
    Pester tests for the pure functions in Invoke-BackupChainCheck.ps1.
    Written for Pester 3.4 (ships in the box on Windows) - also runs on 4.x/5.x.

    Run:  Invoke-Pester -Path .\tests
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-BackupChainCheck.ps1'

# Dot-source for its functions; -BackupPath satisfies the mandatory parameter,
# the script returns before doing any work when InvocationName is '.'.
. $scriptPath -BackupPath $env:TEMP

function New-FileInfoLike {
    param([string]$FullName)
    # A stand-in with the members ConvertFrom-OlaBackupFile touches.
    $dir = Split-Path $FullName -Parent
    [pscustomobject]@{
        Name             = Split-Path $FullName -Leaf
        DirectoryName    = $dir
        FullName         = $FullName
        Length           = 1024
        LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
    }
}

Describe 'Get-DurationText' {
    It 'formats sub-day spans as hours and minutes' {
        Get-DurationText 4.5 | Should Be '4h 30m'
    }
    It 'formats multi-day spans with a day component' {
        Get-DurationText 50 | Should Be '2d 2h 00m'
    }
}

Describe 'Get-Median' {
    It 'returns the middle value for an odd count' {
        Get-Median -Value @(1, 5, 2) | Should Be 2
    }
    It 'averages the two middle values for an even count' {
        Get-Median -Value @(1, 2, 3, 4) | Should Be 2.5
    }
    It 'returns $null for an empty set' {
        Get-Median -Value @() | Should Be $null
    }
}

Describe 'ConvertFrom-OlaBackupFile - standard directory layout' {
    $file = New-FileInfoLike 'D:\Backup\SQL01$PROD\AdventureWorks\FULL\SQL01$PROD_AdventureWorks_FULL_20260906_060000.bak'
    $r = ConvertFrom-OlaBackupFile -File $file

    It 'reads the backup type from the parent folder' { $r.BackupType | Should Be 'FULL' }
    It 'reads the database from the grandparent folder'  { $r.Database | Should Be 'AdventureWorks' }
    It 'reads the instance from the great-grandparent'   { $r.Instance | Should Be 'SQL01$PROD' }
    It 'parses the timestamp from the file name' {
        $r.Timestamp | Should Be ([datetime]'2026-09-06 06:00:00')
    }
    It 'defaults FileNumber to 1 when not striped' { $r.FileNumber | Should Be 1 }
    It 'is not flagged copy-only' { $r.IsCopyOnly | Should Be $false }
}

Describe 'ConvertFrom-OlaBackupFile - tokens and striping' {
    It 'detects COPY_ONLY' {
        $f = New-FileInfoLike 'D:\B\SQL01\DB1\FULL\SQL01_DB1_FULL_COPY_ONLY_20260906_060000.bak'
        (ConvertFrom-OlaBackupFile -File $f).IsCopyOnly | Should Be $true
    }
    It 'detects the stripe file number' {
        $f = New-FileInfoLike 'D:\B\SQL01\DB1\LOG\SQL01_DB1_LOG_20260906_060000_3.trn'
        (ConvertFrom-OlaBackupFile -File $f).FileNumber | Should Be 3
    }
    It 'parses a database name that contains underscores (from the folder)' {
        $f = New-FileInfoLike 'D:\B\SQL01\My_App_DB\DIFF\SQL01_My_App_DB_DIFF_20260906_060000.bak'
        (ConvertFrom-OlaBackupFile -File $f).Database | Should Be 'My_App_DB'
    }
    It 'returns $null for a non-backup file' {
        $f = New-FileInfoLike 'D:\B\notes.txt'
        ConvertFrom-OlaBackupFile -File $f | Should Be $null
    }
}

Describe 'Group-LogicalBackup - striping collapses to one logical backup' {
    $mk = {
        param($ts, $n)
        [pscustomobject]@{
            Instance = 'SQL01'; Database = 'DB1'; BackupType = 'FULL'
            Timestamp = [datetime]$ts; AgeHours = 1; FileNumber = $n
            IsCopyOnly = $false; IsPartial = $false
            Path = "x_$n.bak"; LengthBytes = 1; LastWriteUtc = [datetime]$ts
        }
    }
    $records = @( (& $mk '2026-09-06 06:00:00' 1), (& $mk '2026-09-06 06:00:00' 2) )
    $logical = @(Group-LogicalBackup -Record $records)

    It 'produces a single logical backup' { $logical.Count | Should Be 1 }
    It 'records the physical file count' { $logical[0].FileCount | Should Be 2 }
}
