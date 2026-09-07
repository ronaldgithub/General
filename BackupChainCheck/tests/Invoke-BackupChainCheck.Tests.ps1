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

Describe 'Test-DatabaseMatch' {
    It 'matches everything against *' {
        Test-DatabaseMatch -Name 'AnyDb' -Pattern '*' | Should Be $true
    }
    It 'matches an exact name' {
        Test-DatabaseMatch -Name 'StackOverflow2010' -Pattern @('StackOverflow2010') | Should Be $true
    }
    It 'honours wildcards and a pattern list' {
        Test-DatabaseMatch -Name 'JDE_PRODUCTION' -Pattern @('ODS', 'JDE_*') | Should Be $true
    }
    It 'returns $false when nothing matches' {
        Test-DatabaseMatch -Name 'Sales' -Pattern @('Finance', 'HR*') | Should Be $false
    }
}

Describe 'ConvertFrom-AgentTime' {
    It 'decodes HHMMSS to HH:mm' {
        ConvertFrom-AgentTime 180000 | Should Be '18:00'
        ConvertFrom-AgentTime 123000 | Should Be '12:30'
        ConvertFrom-AgentTime 0 | Should Be '00:00'
    }
}

Describe 'ConvertTo-ScheduleInterval' {
    It 'reads a daily-at-a-time schedule as 24h' {
        $r = ConvertTo-ScheduleInterval -FreqType 4 -FreqInterval 1 -FreqSubdayType 1 -FreqSubdayInterval 0 -ActiveStartTime 180000
        $r.IntervalHours | Should Be 24
        $r.Text | Should Be 'daily at 18:00'
    }
    It 'reads an hourly sub-day schedule as 1h' {
        $r = ConvertTo-ScheduleInterval -FreqType 4 -FreqInterval 1 -FreqSubdayType 8 -FreqSubdayInterval 1
        $r.IntervalHours | Should Be 1
        $r.Text | Should Be 'every 1 hour'
    }
    It 'reads an every-15-minutes schedule as 0.25h' {
        $r = ConvertTo-ScheduleInterval -FreqType 4 -FreqInterval 1 -FreqSubdayType 4 -FreqSubdayInterval 15
        $r.IntervalHours | Should Be 0.25
    }
    It 'averages a weekly schedule with two days a week' {
        # freq_interval bitmask: Sunday(1) + Wednesday(8) = 9
        $r = ConvertTo-ScheduleInterval -FreqType 8 -FreqInterval 9 -FreqSubdayType 1 -FreqSubdayInterval 0 -FreqRecurrenceFactor 1 -ActiveStartTime 20000
        $r.IntervalHours | Should Be 84
    }
    It 'returns $null hours for a one-time schedule' {
        $r = ConvertTo-ScheduleInterval -FreqType 1 -FreqInterval 0 -FreqSubdayType 1 -FreqSubdayInterval 0
        $r.IntervalHours | Should Be $null
    }
}

Describe 'Get-RunSummary' {
    $model = @{
        'DB1' = @{
            FULL = ([ordered]@{ CleanupHours = 72; IntervalHours = 24; NumberOfFiles = 1; CleanupMode = 'AFTER_BACKUP'; Source = @() })
            DIFF = ([ordered]@{ CleanupHours = 48; IntervalHours = 24; NumberOfFiles = 1; CleanupMode = 'AFTER_BACKUP'; Source = @() })
            LOG  = ([ordered]@{ CleanupHours = $null; IntervalHours = 1; NumberOfFiles = 1; CleanupMode = 'AFTER_BACKUP'; Source = @() })
        }
    }
    $logical = @(
        [pscustomobject]@{ Database = 'DB1'; BackupType = 'FULL' },
        [pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG' },
        [pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG' }
    )
    $findings = @(
        [pscustomobject]@{ Severity = 'Error' },
        [pscustomobject]@{ Severity = 'Warning' }
    )
    $line = Get-RunSummary -Now ([datetime]'2026-09-07 10:20:00') -Logical $logical -Model $model -Finding $findings -LsnStatus 'valid'

    It 'leads with the LSN status column, then the tool name and run time' {
        ($line -like 'LSN valid  |  BackupChainCheck 2026-09-07 10:20*') | Should Be $true
    }
    It 'defaults the LSN status to n/a' {
        ((Get-RunSummary -Now ([datetime]'2026-09-07 10:20:00') -Model $model) -like 'LSN n/a *') | Should Be $true
    }
    It 'shows the single database as the scope' {
        ($line -like '*  DB1  *') | Should Be $true
    }
    It 'shows @CleanupTime per type, ? when unknown' {
        ($line -like '*@CleanupTime F/D/L 72/48/?h*') | Should Be $true
    }
    It 'shows the file counts per type' {
        ($line -like '*files F/D/L 1/0/2*') | Should Be $true
    }
    It 'shows the finding tally' {
        ($line -like '*1E 1W 0I') | Should Be $true
    }
    It 'summarises many databases as a count with a cleanup range' {
        $m2 = @{
            'A' = @{ FULL = ([ordered]@{ CleanupHours = 48 }); DIFF = ([ordered]@{ CleanupHours = $null }); LOG = ([ordered]@{ CleanupHours = $null }) }
            'B' = @{ FULL = ([ordered]@{ CleanupHours = 168 }); DIFF = ([ordered]@{ CleanupHours = $null }); LOG = ([ordered]@{ CleanupHours = $null }) }
        }
        $l2 = Get-RunSummary -Now ([datetime]'2026-09-07 10:20:00') -Model $m2
        ($l2 -like '*2 databases*') | Should Be $true
        ($l2 -like '*F/D/L 48-168/?/?h*') | Should Be $true
    }
}

Describe 'Get-DataSizeText' {
    It 'formats bytes / KB / MB / GB' {
        Get-DataSizeText 512 | Should Be '512 B'
        Get-DataSizeText 4096 | Should Be '4 KB'
        Get-DataSizeText (5 * 1MB) | Should Be '5.0 MB'
        Get-DataSizeText (3 * 1GB) | Should Be '3.0 GB'
    }
}

Describe 'Get-BackupAdvice' {
    function New-Slot { param($C, $I) [ordered]@{ CleanupHours = $C; IntervalHours = $I; NumberOfFiles = 1; CleanupMode = 'AFTER_BACKUP'; Source = @() } }
    function New-Lb {
        param($Db, $Type, $AgeHours, $Bytes = 1GB, $Ts = ([datetime]'2026-09-07 06:00'))
        [pscustomobject]@{ Database = $Db; BackupType = $Type; Timestamp = [datetime]$Ts; AgeHours = $AgeHours
            IsCopyOnly = $false; FileCount = 1; SizeBytes = [double]$Bytes; Paths = @("x_$Db`_$Type`_$AgeHours.bak") }
    }

    It 'flags a DIFF kept longer than the FULL retention' {
        $m = @{ 'DB1' = @{ FULL = (New-Slot 48 24); DIFF = (New-Slot 168 24); LOG = (New-Slot 48 1) } }
        $a = @(Get-BackupAdvice -Model $m) -join "`n"
        ($a -like '*DIFF is kept 2d 0h 00m but FULL only 2d 0h 00m*') | Should Be $false   # sanity: not equal
        ($a -like '*DIFF is kept*7d*FULL only*2d*') | Should Be $true
        ($a -like '*daily FULL you barely need DIFFs*') | Should Be $true
    }

    It 'flags a LOG retention shorter than FULL' {
        $m = @{ 'DB1' = @{ FULL = (New-Slot 168 24); DIFF = (New-Slot 48 24); LOG = (New-Slot 48 1) } }
        (@(Get-BackupAdvice -Model $m) -join "`n" -like "*LOG is kept*shorter than FULL*") | Should Be $true
    }

    It 'flags a thin FULL copy count (weekly full, short retention)' {
        $m = @{ 'DB1' = @{ FULL = (New-Slot 168 168); DIFF = (New-Slot 48 24); LOG = (New-Slot 168 1) } }
        (@(Get-BackupAdvice -Model $m) -join "`n" -like "*only ~2 full copies ever exist*") | Should Be $true
    }

    It 'estimates wasted space from files past their retention window' {
        $m = @{ 'DB1' = @{ FULL = (New-Slot 48 24); DIFF = (New-Slot 48 24); LOG = (New-Slot 48 1) } }
        $lb = @(
            (New-Lb 'DB1' 'FULL' 10  (2GB)),   # in window
            (New-Lb 'DB1' 'FULL' 300 (2GB))    # 300h old, way past 48+24 -> wasted
        )
        $a = @(Get-BackupAdvice -Model $m -LogicalBackup $lb) -join "`n"
        ($a -like '*~2.0 GB in 1 backup file*past @CleanupTime*') | Should Be $true
    }

    It 'groups identical settings into one block' {
        $m = @{
            'A' = @{ FULL = (New-Slot 168 24); DIFF = (New-Slot 48 24); LOG = (New-Slot 48 1) }
            'B' = @{ FULL = (New-Slot 168 24); DIFF = (New-Slot 48 24); LOG = (New-Slot 48 1) }
        }
        (@(Get-BackupAdvice -Model $m) -join "`n" -like "*All 2 databases:*") | Should Be $true
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

Describe 'ConvertTo-LsnDecimal' {
    It 'keeps a 25-digit LSN lossless (no double rounding)' {
        ConvertTo-LsnDecimal '9999999999999999999999999' |
            Should Be ([decimal]'9999999999999999999999999')
    }
    It 'returns $null for DBNull' {
        ConvertTo-LsnDecimal ([System.DBNull]::Value) | Should Be $null
    }
    It 'returns $null for $null' {
        ConvertTo-LsnDecimal $null | Should Be $null
    }
}

Describe 'ConvertTo-NullableBool' {
    It 'treats DBNull as $false' {
        ConvertTo-NullableBool ([System.DBNull]::Value) | Should Be $false
    }
    It 'passes a real bit through' {
        ConvertTo-NullableBool 1 | Should Be $true
    }
}

Describe 'Group-BackupSetRow' {
    function New-BackupRowLike {
        param(
            [int]$SetId, [string]$Type = 'D', [string]$Db = 'DB1',
            [string]$Device = 'E:\b\DB1\FULL\DB1_FULL_20260907_083848.bak',
            $DiffBaseLsn = ([System.DBNull]::Value),
            $FinishDate = ([datetime]'2026-09-07 08:39:00'),
            $BackupSize = ([decimal]1258291200),           # 1200 MB
            $CompressedSize = ([decimal]314572800)
        )
        [pscustomobject]@{
            backup_set_id            = $SetId
            database_name            = $Db
            server_name              = 'WIN10'
            type                     = $Type
            backup_start_date        = [datetime]'2026-09-07 08:38:48'
            backup_finish_date       = $FinishDate
            backup_size              = $BackupSize
            compressed_backup_size   = $CompressedSize
            first_lsn                = [decimal]'661000017516200011'
            last_lsn                 = [decimal]'661000017516900001'
            checkpoint_lsn           = [decimal]'661000012988400040'
            database_backup_lsn      = [decimal]'661000012988400040'
            differential_base_lsn    = $DiffBaseLsn
            first_recovery_fork_guid = 'AAAAAAAA-0000-0000-0000-000000000001'
            last_recovery_fork_guid  = 'AAAAAAAA-0000-0000-0000-000000000001'
            is_copy_only             = $false
            is_damaged               = $false
            has_backup_checksums     = $true
            begins_log_chain         = $false
            recovery_model           = 'FULL'
            user_name                = 'NT SERVICE\SQLSERVERAGENT'
            software_name            = 'Microsoft SQL Server'
            physical_device_name     = $Device
            family_sequence_number   = 1
        }
    }

    It 'maps D/I/L to FULL/DIFF/LOG' {
        (Group-BackupSetRow -Row @(New-BackupRowLike -SetId 1 -Type 'D')).BackupType | Should Be 'FULL'
        (Group-BackupSetRow -Row @(New-BackupRowLike -SetId 2 -Type 'I')).BackupType | Should Be 'DIFF'
        (Group-BackupSetRow -Row @(New-BackupRowLike -SetId 3 -Type 'L')).BackupType | Should Be 'LOG'
    }

    It 'skips backup types other than D/I/L' {
        Group-BackupSetRow -Row @(New-BackupRowLike -SetId 4 -Type 'F') | Should Be $null
    }

    It 'collapses striped media families into one record with all device paths' {
        $rows = @(
            (New-BackupRowLike -SetId 10 -Device 'E:\b\DB1_1.bak'),
            (New-BackupRowLike -SetId 10 -Device 'E:\b\DB1_2.bak')
        )
        $rec = @(Group-BackupSetRow -Row $rows)
        $rec.Count | Should Be 1
        $rec[0].DeviceCount | Should Be 2
    }

    It 'exposes LSNs as decimal, DBNull differential base as $null' {
        $rec = Group-BackupSetRow -Row @(New-BackupRowLike -SetId 20 -Type 'L')
        $rec.FirstLsn | Should Be ([decimal]'661000017516200011')
        $rec.DifferentialBaseLsn | Should Be $null
    }

    It 'falls back to the start time when finish date is null' {
        $rec = Group-BackupSetRow -Row @(New-BackupRowLike -SetId 30 -FinishDate ([System.DBNull]::Value))
        $rec.FinishTime | Should Be ([datetime]'2026-09-07 08:38:48')
    }

    It 'computes SpeedMBps from backup_size over the run time' {
        # 1200 MB over 12 s (08:38:48 -> 08:39:00) = 100 MB/s
        $rec = Group-BackupSetRow -Row @(New-BackupRowLike -SetId 40 -Type 'D')
        $rec.SpeedMBps | Should Be 100
    }

    It 'leaves SpeedMBps null for a sub-second backup' {
        $rec = Group-BackupSetRow -Row @(New-BackupRowLike -SetId 41 -Type 'L' -FinishDate ([datetime]'2026-09-07 08:38:48'))
        $rec.SpeedMBps | Should Be $null
    }
}

Describe 'Test-LsnChain' {
    function New-Hist {
        param($Db, $Type, $Ts, $First, $Last, $Fork = 'F1', [switch]$Damaged, [switch]$Copy, $DiffBase, $Device)
        [pscustomobject]@{
            Instance            = 'I1'
            Database            = $Db
            BackupType          = $Type
            Timestamp           = [datetime]$Ts
            FinishTime          = [datetime]$Ts
            FirstLsn            = if ($null -eq $First) { $null } else { [decimal]$First }
            LastLsn             = if ($null -eq $Last) { $null } else { [decimal]$Last }
            DifferentialBaseLsn = if ($null -eq $DiffBase) { $null } else { [decimal]$DiffBase }
            ForkGuid            = $Fork
            IsDamaged           = [bool]$Damaged
            IsCopyOnly          = [bool]$Copy
            DevicePaths         = if ($null -eq $Device) { @() } else { @($Device) }
        }
    }
    function New-DiskLb {
        param($Db, $Type, $Ts, $Path)
        [pscustomobject]@{ Database = $Db; BackupType = $Type; Timestamp = [datetime]$Ts; Paths = @($Path) }
    }

    It 'reports a contiguous log chain as valid (time gaps do not matter)' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-01 09:00' 100 200),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:46' 200 350),   # 6-day time gap, LSN contiguous
            (New-Hist 'DB1' 'LOG' '2026-09-07 09:00' 350 400)
        )
        (Test-LsnChain -History $h).Status | Should Be 'valid'
    }

    It 'reports a broken log chain as error when first_lsn jumps past the previous last_lsn' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 100 200),
            (New-Hist 'DB1' 'LOG' '2026-09-07 09:00' 275 400)    # 200 -> 275 : a log is missing
        )
        $r = Test-LsnChain -History $h
        $r.Status | Should Be 'error'
        (@($r.Findings | Where-Object { $_.Finding -like 'LSN log chain is broken*' }).Count) | Should Be 1
    }

    It 'flags a recovery fork change mid-chain' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 100 200 'FORK-A'),
            (New-Hist 'DB1' 'LOG' '2026-09-07 09:00' 200 300 'FORK-B')
        )
        (Test-LsnChain -History $h).Status | Should Be 'error'
    }

    It 'flags a damaged backup' {
        $h = @(
            (New-Hist 'DB1' 'FULL' '2026-09-07 06:00' 10 20 'F1' -Damaged),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 100 200),
            (New-Hist 'DB1' 'LOG' '2026-09-07 09:00' 200 300)
        )
        (Test-LsnChain -History $h).Status | Should Be 'error'
    }

    It 'ignores copy-only log backups in the chain sequence' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 100 200),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:30' 100 999 'F1' -Copy),  # copy-only, off to the side
            (New-Hist 'DB1' 'LOG' '2026-09-07 09:00' 200 300)
        )
        (Test-LsnChain -History $h).Status | Should Be 'valid'
    }

    It 'returns n/a when there is nothing to check' {
        (Test-LsnChain -History @()).Status | Should Be 'n/a'
        (Test-LsnChain -History @((New-Hist 'DB1' 'LOG' '2026-09-07 09:00' 100 200))).Status | Should Be 'n/a'
    }

    It 'warns (not errors) when a DIFF base full is missing from the window' {
        $h = @(
            (New-Hist 'DB1' 'FULL' '2026-09-07 06:00' 500 510),
            (New-Hist 'DB1' 'DIFF' '2026-09-07 07:00' 520 525 'F1' -DiffBase 999)
        )
        $r = Test-LsnChain -History $h
        $r.Status | Should Be 'valid'
        (@($r.Findings | Where-Object { $_.Severity -eq 'Warning' }).Count) | Should Be 1
    }

    It 'errors on a hole in the on-disk chain (a recorded LOG whose file was deleted)' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-07 07:00' 100 200 'F1' -Device 'E:\b\DB1\LOG\l1.trn'),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 200 300 'F1' -Device 'E:\b\DB1\LOG\l2.trn'),   # file deleted
            (New-Hist 'DB1' 'LOG' '2026-09-07 09:00' 300 400 'F1' -Device 'E:\b\DB1\LOG\l3.trn')
        )
        $disk = @(
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 07:00' 'E:\b\DB1\LOG\l1.trn'),
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 09:00' 'E:\b\DB1\LOG\l3.trn')
        )
        $r = Test-LsnChain -History $h -LogicalBackup $disk
        $r.Status | Should Be 'error'
        (@($r.Findings | Where-Object { $_.Finding -like 'Restore chain has a hole*' }).Count) | Should Be 1
    }

    It 'stays valid when every recorded LOG inside the on-disk range is present' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-07 07:00' 100 200 'F1' -Device 'E:\b\DB1\LOG\l1.trn'),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 200 300 'F1' -Device 'E:\b\DB1\LOG\l2.trn')
        )
        $disk = @(
            (New-DiskLb 'DB1' 'FULL' '2026-09-07 06:00' 'E:\b\DB1\FULL\f1.bak'),
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 07:00' 'E:\b\DB1\LOG\l1.trn'),
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 08:00' 'E:\b\DB1\LOG\l2.trn')
        )
        (Test-LsnChain -History $h -LogicalBackup $disk).Status | Should Be 'valid'
    }

    It 'does not flag an old LOG below the on-disk chain range (retention aged it off)' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-01 07:00' 100 200 'F1' -Device 'E:\b\DB1\LOG\old.trn'),   # aged off disk
            (New-Hist 'DB1' 'LOG' '2026-09-07 07:00' 200 300 'F1' -Device 'E:\b\DB1\LOG\l1.trn'),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 300 400 'F1' -Device 'E:\b\DB1\LOG\l2.trn')
        )
        $disk = @(
            (New-DiskLb 'DB1' 'FULL' '2026-09-07 06:00' 'E:\b\DB1\FULL\f1.bak'),
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 07:00' 'E:\b\DB1\LOG\l1.trn'),
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 08:00' 'E:\b\DB1\LOG\l2.trn')
        )
        (Test-LsnChain -History $h -LogicalBackup $disk).Status | Should Be 'valid'
    }

    It 'errors when the chain has no FULL backup file on disk to restore first' {
        $h = @(
            (New-Hist 'DB1' 'FULL' '2026-09-07 06:00' 10 20 'F1' -Device 'E:\b\DB1\FULL\f1.bak'),   # in msdb, file gone
            (New-Hist 'DB1' 'LOG' '2026-09-07 07:00' 100 200 'F1' -Device 'E:\b\DB1\LOG\l1.trn'),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 200 300 'F1' -Device 'E:\b\DB1\LOG\l2.trn')
        )
        $disk = @(
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 07:00' 'E:\b\DB1\LOG\l1.trn'),
            (New-DiskLb 'DB1' 'LOG' '2026-09-07 08:00' 'E:\b\DB1\LOG\l2.trn')
        )
        $r = Test-LsnChain -History $h -LogicalBackup $disk
        $r.Status | Should Be 'error'
        (@($r.Findings | Where-Object { $_.Finding -like 'No FULL backup on disk*' }).Count) | Should Be 1
    }

    It 'does not raise the no-FULL error without an on-disk view' {
        $h = @(
            (New-Hist 'DB1' 'LOG' '2026-09-07 07:00' 100 200),
            (New-Hist 'DB1' 'LOG' '2026-09-07 08:00' 200 300)
        )
        (Test-LsnChain -History $h).Status | Should Be 'valid'
    }
}

Describe 'Get-RestorePlan' {
    function New-PlanRec {
        param(
            $Db = 'DB1', $Type, $Ts, $First, $Last, $DiffBase, $Fork = 'F1',
            [bool]$OnDisk = $true, $Path
        )
        $p = if ($null -ne $Path) { $Path } else { "E:\b\DB1\$Type\$Type-$($Ts -replace '[: -]','').bak" }
        [pscustomobject]@{
            Instance            = 'I1'; Database = $Db; BackupType = $Type
            Timestamp           = [datetime]$Ts; FinishTime = [datetime]$Ts
            FirstLsn            = if ($null -eq $First) { $null } else { [decimal]$First }
            LastLsn             = if ($null -eq $Last) { $null } else { [decimal]$Last }
            DifferentialBaseLsn = if ($null -eq $DiffBase) { $null } else { [decimal]$DiffBase }
            ForkGuid            = $Fork
            IsCopyOnly          = $false
            OnDisk              = $OnDisk
            MatchedPath         = if ($OnDisk) { $p } else { $null }
            DevicePaths         = @($p)
        }
    }

    It 'builds FULL -> newest matching DIFF -> contiguous LOGs to the newest' {
        $h = @(
            (New-PlanRec -Type 'FULL' -Ts '2026-09-07 06:00' -First 100 -Last 110),
            (New-PlanRec -Type 'DIFF' -Ts '2026-09-07 09:00' -First 150 -Last 160 -DiffBase 100),
            (New-PlanRec -Type 'DIFF' -Ts '2026-09-07 12:00' -First 200 -Last 210 -DiffBase 100),
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 13:00' -First 205 -Last 300),
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 14:00' -First 300 -Last 400)
        )
        $plan = @(Get-RestorePlan -History $h)
        $plan.Count | Should Be 1
        $plan[0].StepCount | Should Be 4
        $plan[0].Steps[0].BackupType | Should Be 'FULL'
        $plan[0].Steps[1].BackupType | Should Be 'DIFF'
        ('{0:yyyy-MM-dd HH:mm}' -f $plan[0].Steps[1].Timestamp) | Should Be '2026-09-07 12:00'
        $plan[0].Steps[3].BackupType | Should Be 'LOG'
        $plan[0].Complete | Should Be $true
        ('{0:yyyy-MM-dd HH:mm}' -f $plan[0].RecoverableTo) | Should Be '2026-09-07 14:00'
    }

    It 'emits a T-SQL RESTORE script for a complete plan' {
        $h = @(
            (New-PlanRec -Type 'FULL' -Ts '2026-09-07 06:00' -First 100 -Last 110 -Path 'E:\b\DB1\FULL\f.bak'),
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 13:00' -First 105 -Last 300 -Path 'E:\b\DB1\LOG\l1.trn')
        )
        $s = (Get-RestorePlan -History $h)[0].RestoreScript
        $s | Should Match "RESTORE DATABASE \[DB1\] FROM DISK = N'E:\\b\\DB1\\FULL\\f\.bak' WITH NORECOVERY;"
        $s | Should Match "RESTORE LOG \[DB1\] FROM DISK = N'E:\\b\\DB1\\LOG\\l1\.trn' WITH NORECOVERY;"
        $s | Should Match 'RESTORE DATABASE \[DB1\] WITH RECOVERY;'
    }

    It 'reports no plan (and no script) when no FULL is on disk' {
        $h = @(
            (New-PlanRec -Type 'FULL' -Ts '2026-09-07 06:00' -First 100 -Last 110 -OnDisk $false),
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 13:00' -First 105 -Last 300)
        )
        $plan = @(Get-RestorePlan -History $h)
        $plan[0].StepCount | Should Be 0
        $plan[0].Complete | Should Be $false
        $plan[0].Reason | Should Match 'No FULL'
        $plan[0].RestoreScript | Should Be ''
    }

    It 'stops the chain at a missing LOG file, marks it partial, and leaves the script NORECOVERY' {
        $h = @(
            (New-PlanRec -Type 'FULL' -Ts '2026-09-07 06:00' -First 100 -Last 110),
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 13:00' -First 105 -Last 300 -Path 'E:\b\DB1\LOG\l1.trn'),
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 14:00' -First 300 -Last 400 -OnDisk $false -Path 'E:\b\DB1\LOG\l2.trn'),
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 15:00' -First 400 -Last 500 -Path 'E:\b\DB1\LOG\l3.trn')
        )
        $plan = @(Get-RestorePlan -History $h)
        $plan[0].StepCount | Should Be 2   # FULL + l1 only
        $plan[0].Complete | Should Be $false
        $plan[0].Reason | Should Match 'l2\.trn'
        $plan[0].RestoreScript | Should Match 'chain incomplete'
        $plan[0].RestoreScript | Should Not Match 'RESTORE DATABASE \[DB1\] WITH RECOVERY;'
    }

    It 'ignores a DIFF whose base is not the chosen FULL' {
        $h = @(
            (New-PlanRec -Type 'FULL' -Ts '2026-09-07 06:00' -First 500 -Last 510),
            (New-PlanRec -Type 'DIFF' -Ts '2026-09-07 09:00' -First 300 -Last 320 -DiffBase 100),  # old base
            (New-PlanRec -Type 'LOG'  -Ts '2026-09-07 13:00' -First 505 -Last 600)
        )
        $plan = @(Get-RestorePlan -History $h)
        @($plan[0].Steps | Where-Object { $_.BackupType -eq 'DIFF' }).Count | Should Be 0
        $plan[0].StepCount | Should Be 2
    }
}

Describe 'Join-BackupSetToFile' {
    It 'matches on device path and flags a missing file' {
        $h = @(
            [pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG'; Timestamp = [datetime]'2026-09-07 07:00'; DevicePaths = @('E:\b\l1.trn') },
            [pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG'; Timestamp = [datetime]'2026-09-07 08:00'; DevicePaths = @('E:\b\l2.trn') }
        )
        $disk = @([pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG'; Timestamp = [datetime]'2026-09-07 07:00'; Paths = @('E:\b\l1.trn') })
        $r = @(Join-BackupSetToFile -History $h -LogicalBackup $disk)
        $r[0].OnDisk | Should Be $true
        $r[1].OnDisk | Should Be $false
    }
    It 'falls back to database + type + timestamp when the path differs' {
        $h = @([pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG'; Timestamp = [datetime]'2026-09-07 07:00:30'; DevicePaths = @('E:\local\l1.trn') })
        $disk = @([pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG'; Timestamp = [datetime]'2026-09-07 07:00:00'; Paths = @('\\nas\share\l1.trn') })
        (@(Join-BackupSetToFile -History $h -LogicalBackup $disk))[0].OnDisk | Should Be $true
    }
}

Describe 'Get-BackupPrediction' {
    function New-ModelSlot {
        param($Cleanup, $Interval, $Files = 1, $Mode = 'AFTER_BACKUP')
        [ordered]@{
            CleanupHours = $Cleanup; IntervalHours = $Interval
            NumberOfFiles = $Files; CleanupMode = $Mode; Source = @()
        }
    }
    function New-Lb {
        param($Db, $Type, $Ts, $FileCount = 1)
        [pscustomobject]@{
            Instance = 'I1'; Database = $Db; BackupType = $Type
            Timestamp = [datetime]$Ts; FileCount = $FileCount; IsCopyOnly = $false
        }
    }

    $now = [datetime]'2026-09-07 09:00:00'
    $model = @{
        'DB1' = @{
            FULL = (New-ModelSlot 48 24)
            DIFF = (New-ModelSlot $null $null)
            LOG  = (New-ModelSlot 6 1 2)
        }
    }
    $logical = @(
        (New-Lb 'DB1' 'LOG' '2026-09-07 09:00:00' 2),
        (New-Lb 'DB1' 'LOG' '2026-09-07 08:00:00' 2),
        (New-Lb 'DB1' 'LOG' '2026-09-07 06:00:00' 1),   # present but only 1 of 2 stripes
        (New-Lb 'DB1' 'FULL' '2026-09-06 09:00:00' 1)
    )
    $history = @(
        [pscustomobject]@{ Database = 'DB1'; BackupType = 'FULL'; SpeedMBps = 120.0 },
        [pscustomobject]@{ Database = 'DB1'; BackupType = 'FULL'; SpeedMBps = 100.0 },
        [pscustomobject]@{ Database = 'DB1'; BackupType = 'FULL'; SpeedMBps = 140.0 },
        [pscustomobject]@{ Database = 'DB1'; BackupType = 'LOG';  SpeedMBps = $null }
    )
    $pred = @(Get-BackupPrediction -LogicalBackup $logical -Model $model -History $history -Now $now)
    $log = $pred | Where-Object { $_.BackupType -eq 'LOG' }
    $full = $pred | Where-Object { $_.BackupType -eq 'FULL' }
    $diff = $pred | Where-Object { $_.BackupType -eq 'DIFF' }

    It 'projects one slot per interval across the retention window' {
        # cleanup 6h + interval 1h = 7h horizon => slots at 09:00 .. 02:00
        $log.ExpectedCount | Should Be 8
    }
    It 'counts slots that have a matching file' {
        $log.PresentCount | Should Be 2
    }
    It 'flags a slot whose file is missing stripe members as partial' {
        $log.PartialCount | Should Be 1
    }
    It 'lists the missing slot timestamps newest first' {
        $log.MissingCount | Should Be 5
        $log.MissingSlots[0] | Should Be ([datetime]'2026-09-07 07:00:00')
    }
    It 'uses the newest backup as the schedule phase for FULL' {
        $full.PresentCount | Should Be 1
        $full.MissingCount | Should Be 3
    }
    It 'marks a type with unknown retention as not predictable' {
        $diff.Predictable | Should Be $false
        $diff.ExpectedCount | Should Be $null
    }
    It 'carries the median msdb throughput as SpeedMBps' {
        $full.SpeedMBps | Should Be 120
    }
    It 'leaves SpeedMBps null when history has no timed backups for the type' {
        $log.SpeedMBps | Should Be $null
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
