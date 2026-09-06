#Requires -Version 5.1
<#
.SYNOPSIS
    Reconciles Ola Hallengren backup retention (@CleanupTime) and cadence against
    the backup files actually present on disk, and reports recovery-coverage gaps.

.DESCRIPTION
    BackupChainCheck is READ-ONLY. It never writes to SQL Server and never deletes
    or modifies a backup file.

    It compares three things that are normally never compared:

      1. Retention - @CleanupTime (hours) per database + backup type, taken from the
         DatabaseBackup Agent job steps (-SqlInstance), a config file (-ConfigPath),
         or parameters (-FullCleanupTimeHours / -DiffCleanupTimeHours /
         -LogCleanupTimeHours).
      2. Cadence   - how often each backup type runs. Inferred from the spacing of
         the files on disk, or supplied via -FullIntervalHours / -DiffIntervalHours
         / -LogIntervalHours.
      3. Reality   - the FULL / DIFF / LOG files present under -BackupPath.

    Expected surviving files per (database, type):

        floor(CleanupTimeHours / IntervalHours) + 1        (x NumberOfFiles if striped)

    Findings are emitted as objects on the pipeline and printed as a table. Use
    -ReportPath for a standalone HTML report and -FailOnGap for monitoring exit codes.

.PARAMETER BackupPath
    One or more root folders to scan. The standard Ola layout is expected:
        <BackupPath>\<SERVER$INSTANCE>\<Database>\<FULL|DIFF|LOG>\<file>
    Files that do not sit in that structure are parsed from the file name instead.

.PARAMETER SqlInstance
    Optional. SQL Server instance to read DatabaseBackup job configuration and
    database metadata from (msdb + master, read-only). Windows auth unless
    -SqlCredential is supplied.

.PARAMETER SqlCredential
    Optional PSCredential for SQL authentication against -SqlInstance.

.PARAMETER SolutionDatabase
    Database where Ola Hallengren's objects (dbo.CommandLog) are installed.
    Default 'master'. Only used together with -SqlInstance, to read run history
    and detect failed backup runs.

.PARAMETER HistoryHours
    How far back to read dbo.CommandLog. Default 336 (14 days).

.PARAMETER ConfigPath
    Optional path to a JSON file describing expected retention / cadence when not
    connecting to SQL. Shape:

        {
          "defaults": {
            "FullCleanupTimeHours": 72, "DiffCleanupTimeHours": 48, "LogCleanupTimeHours": 48,
            "FullIntervalHours": 24,    "DiffIntervalHours": 24,    "LogIntervalHours": 1
          },
          "databases": {
            "Finance": { "LogCleanupTimeHours": 24 }
          }
        }

.PARAMETER FullCleanupTimeHours
.PARAMETER DiffCleanupTimeHours
.PARAMETER LogCleanupTimeHours
    Global retention overrides (highest precedence).

.PARAMETER FullIntervalHours
.PARAMETER DiffIntervalHours
.PARAMETER LogIntervalHours
    Global cadence overrides. When omitted, cadence is inferred from file spacing.

.PARAMETER GapToleranceFactor
    A chain gap is flagged when the spacing between two consecutive backups exceeds
    IntervalHours * this factor. Default 1.5.

.PARAMETER IncludeCopyOnly
    Include *_COPY_ONLY files in the analysis. Off by default (they are not governed
    by @CleanupTime and do not participate in the restore chain).

.PARAMETER ReportPath
    Optional path for a standalone HTML report.

.PARAMETER FailOnGap
    Set the exit code: 1 if any Error finding, 2 if only Warnings, 0 otherwise.

.PARAMETER Quiet
    Suppress the console table (the pipeline objects are still returned).

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -SqlInstance SQL01 -BackupPath \\nas01\sqlbackup

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -BackupPath D:\Backup -ConfigPath .\expectations.json -ReportPath .\report.html

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -BackupPath D:\Backup -FullCleanupTimeHours 48 -FullIntervalHours 24 -FailOnGap

.NOTES
    Windows PowerShell 5.1. No external modules required.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$BackupPath,

    [string]$SqlInstance,

    [System.Management.Automation.PSCredential]$SqlCredential,

    [string]$SolutionDatabase = 'master',

    [double]$HistoryHours = 336,

    [string]$ConfigPath,

    [double]$FullCleanupTimeHours,
    [double]$DiffCleanupTimeHours,
    [double]$LogCleanupTimeHours,

    [double]$FullIntervalHours,
    [double]$DiffIntervalHours,
    [double]$LogIntervalHours,

    [double]$GapToleranceFactor = 1.5,

    [switch]$IncludeCopyOnly,

    [string]$ReportPath,

    [switch]$FailOnGap,

    [switch]$Quiet
)

# StrictMode 1.0 (uninitialised-variable checking) rather than 2.0+: this script
# leans on PowerShell's scalar/collection unification (.Count on a single object,
# member enumeration over a possibly-empty result), which 2.0+ turns into errors.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:BackupTypes = @('FULL', 'DIFF', 'LOG')
$script:Now = Get-Date

#region Helpers -----------------------------------------------------------------

function New-Finding {
    param(
        [string]$Instance = '',
        [string]$Database = '',
        [ValidateSet('FULL', 'DIFF', 'LOG', '')]
        [string]$BackupType = '',
        [ValidateSet('Error', 'Warning', 'Info')]
        [string]$Severity,
        [string]$Finding,
        [object]$Expected = $null,
        [object]$Found = $null,
        [string]$Detail = ''
    )
    [pscustomobject]@{
        Instance   = $Instance
        Database   = $Database
        BackupType = $BackupType
        Severity   = $Severity
        Finding    = $Finding
        Expected   = $Expected
        Found      = $Found
        Detail     = $Detail
    }
}

function Get-DurationText {
    param([double]$Hours)
    $ts = [timespan]::FromHours($Hours)
    if ($ts.TotalHours -ge 24) {
        return ('{0}d {1}h {2:00}m' -f [int]$ts.Days, $ts.Hours, $ts.Minutes)
    }
    return ('{0}h {1:00}m' -f [int]$ts.Hours, $ts.Minutes)
}

function Get-Median {
    param([double[]]$Value)
    if (-not $Value -or $Value.Count -eq 0) { return $null }
    $sorted = @($Value | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2
}

function ConvertFrom-OlaBackupFile {
    <#
        Turns a FileInfo into a parsed record, or $null if it is not recognisable
        as an Ola backup file. Directory structure is trusted first; the file name
        is the fallback.
    #>
    # Not typed [System.IO.FileInfo] so tests can pass a lightweight stand-in;
    # only .Name, .DirectoryName, .FullName, .Length and .LastWriteTimeUtc are used.
    param($File)

    $name = $File.Name
    $parent = Split-Path -Path $File.DirectoryName -Leaf
    $grandParent = Split-Path -Path (Split-Path -Path $File.DirectoryName -Parent) -Leaf
    $greatGrandParent = ''
    $ggpPath = Split-Path -Path (Split-Path -Path $File.DirectoryName -Parent) -Parent
    if ($ggpPath) { $greatGrandParent = Split-Path -Path $ggpPath -Leaf }

    # Timestamp: _yyyyMMdd_HHmmss somewhere in the name.
    $tsMatch = [regex]::Match($name, '_(?<d>\d{8})_(?<t>\d{6})(?:_(?<n>\d+))?\.(?<ext>bak|trn|dif)$', 'IgnoreCase')
    if (-not $tsMatch.Success) { return $null }

    $stamp = $null
    try {
        $stamp = [datetime]::ParseExact(
            ($tsMatch.Groups['d'].Value + $tsMatch.Groups['t'].Value),
            'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch { return $null }

    $fileNumber = 1
    if ($tsMatch.Groups['n'].Success) { $fileNumber = [int]$tsMatch.Groups['n'].Value }

    $isCopyOnly = $name -match '_COPY_ONLY_'
    $isPartial = $name -match '_PARTIAL_'

    $type = $null
    $database = $null
    $instance = $null

    if ($script:BackupTypes -contains $parent.ToUpperInvariant()) {
        # Standard layout: ...\<instance>\<db>\<TYPE>\file
        $type = $parent.ToUpperInvariant()
        $database = $grandParent
        $instance = $greatGrandParent
    }
    else {
        # Fallback: parse the file name. Anchor on the type token.
        $nameMatch = [regex]::Match(
            $name,
            '^(?<prefix>.+?)_(?<db>.+)_(?<type>FULL|DIFF|LOG)(?:_PARTIAL)?(?:_COPY_ONLY)?_\d{8}_\d{6}',
            'IgnoreCase')
        if (-not $nameMatch.Success) { return $null }
        $type = $nameMatch.Groups['type'].Value.ToUpperInvariant()
        $database = $nameMatch.Groups['db'].Value
        $instance = $nameMatch.Groups['prefix'].Value
    }

    if (-not $type -or -not $database) { return $null }

    [pscustomobject]@{
        Instance     = $instance
        Database     = $database
        BackupType   = $type
        Timestamp    = $stamp
        AgeHours     = [math]::Round(($script:Now - $stamp).TotalHours, 2)
        FileNumber   = $fileNumber
        IsCopyOnly   = [bool]$isCopyOnly
        IsPartial    = [bool]$isPartial
        Path         = $File.FullName
        LengthBytes  = $File.Length
        LastWriteUtc = $File.LastWriteTimeUtc
    }
}

function Get-BackupFileInventory {
    param([string[]]$Root)

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Root) {
        if (-not (Test-Path -LiteralPath $r)) {
            Write-Warning "Backup path not found, skipping: $r"
            continue
        }
        $files = Get-ChildItem -LiteralPath $r -Recurse -File -Include '*.bak', '*.trn', '*.dif' -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $parsed = ConvertFrom-OlaBackupFile -File $f
            if ($null -ne $parsed) { $records.Add($parsed) }
            else { Write-Verbose "Unrecognised file skipped: $($f.FullName)" }
        }
    }
    return $records
}

function Group-LogicalBackup {
    <#
        Collapses striped physical files into one logical backup keyed by
        Database + BackupType + Timestamp (to the second).
    #>
    param([object[]]$Record)

    $logical = New-Object System.Collections.Generic.List[object]
    $groups = $Record | Group-Object -Property {
        '{0}|{1}|{2:yyyyMMddHHmmss}' -f $_.Database, $_.BackupType, $_.Timestamp
    }
    foreach ($g in $groups) {
        $first = $g.Group[0]
        $logical.Add([pscustomobject]@{
                Instance   = $first.Instance
                Database   = $first.Database
                BackupType = $first.BackupType
                Timestamp  = $first.Timestamp
                AgeHours   = $first.AgeHours
                IsCopyOnly = [bool]($g.Group | Where-Object { $_.IsCopyOnly })
                IsPartial  = [bool]($g.Group | Where-Object { $_.IsPartial })
                FileCount  = $g.Count
                Paths      = @($g.Group.Path)
            })
    }
    return ($logical | Sort-Object Database, BackupType, Timestamp)
}

#endregion

#region SQL (optional, read-only) ---------------------------------------------

function Invoke-SqlQuery {
    param(
        [string]$Instance,
        [string]$Database,
        [string]$Query,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSec = 30
    )

    $builder = "Server=$Instance;Database=$Database;Application Name=BackupChainCheck;Connect Timeout=10;"
    if ($Credential) {
        $builder += "User ID=$($Credential.UserName);Password=$($Credential.GetNetworkCredential().Password);"
    }
    else {
        $builder += 'Integrated Security=SSPI;'
    }

    $conn = New-Object System.Data.SqlClient.SqlConnection $builder
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSec
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $table = New-Object System.Data.DataTable
        [void]$adapter.Fill($table)
        return , $table
    }
    finally {
        $conn.Dispose()
    }
}

function Get-OlaJobConfig {
    <#
        Parses @CleanupTime / @CleanupMode / @NumberOfFiles / @BackupType /
        @Databases / @Directory out of the DatabaseBackup Agent job steps.
    #>
    param(
        [string]$Instance,
        [System.Management.Automation.PSCredential]$Credential
    )

    $q = @"
SELECT j.name AS JobName, s.step_name AS StepName, s.command AS Command
FROM msdb.dbo.sysjobsteps AS s
JOIN msdb.dbo.sysjobs     AS j ON j.job_id = s.job_id
WHERE s.command LIKE '%DatabaseBackup%'
"@
    $rows = Invoke-SqlQuery -Instance $Instance -Database 'msdb' -Query $q -Credential $Credential

    $configs = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows.Rows) {
        $cmd = [string]$row.Command

        $cleanupMatch = [regex]::Match($cmd, '@CleanupTime\s*=\s*(?<v>NULL|\d+)', 'IgnoreCase')
        $typeMatch = [regex]::Match($cmd, "@BackupType\s*=\s*N?'(?<v>FULL|DIFF|LOG)'", 'IgnoreCase')
        $dbMatch = [regex]::Match($cmd, "@Databases\s*=\s*N?'(?<v>[^']+)'", 'IgnoreCase')
        $modeMatch = [regex]::Match($cmd, "@CleanupMode\s*=\s*N?'(?<v>AFTER_BACKUP|BEFORE_BACKUP)'", 'IgnoreCase')
        $numMatch = [regex]::Match($cmd, '@NumberOfFiles\s*=\s*(?<v>\d+)', 'IgnoreCase')
        $dirMatch = [regex]::Match($cmd, "@Directory\s*=\s*N?'(?<v>[^']+)'", 'IgnoreCase')

        if (-not $typeMatch.Success) { continue }

        $cleanupHours = $null
        if ($cleanupMatch.Success -and $cleanupMatch.Groups['v'].Value -match '^\d+$') {
            $cleanupHours = [double]$cleanupMatch.Groups['v'].Value
        }

        $configs.Add([pscustomobject]@{
                JobName      = [string]$row.JobName
                Scope        = if ($dbMatch.Success) { $dbMatch.Groups['v'].Value } else { 'UNKNOWN' }
                BackupType   = $typeMatch.Groups['v'].Value.ToUpperInvariant()
                CleanupHours = $cleanupHours
                CleanupMode  = if ($modeMatch.Success) { $modeMatch.Groups['v'].Value.ToUpperInvariant() } else { 'AFTER_BACKUP' }
                NumberOfFiles = if ($numMatch.Success) { [int]$numMatch.Groups['v'].Value } else { 1 }
                Directory    = if ($dirMatch.Success) { $dirMatch.Groups['v'].Value } else { $null }
            })
    }
    return $configs
}

function Get-OlaCommandLog {
    <#
        Reads recent BACKUP_DATABASE / BACKUP_LOG rows from <SolutionDatabase>.dbo.CommandLog
        (populated when the jobs run with @LogToTable = 'Y'). This is Ola's own
        record of every run, including failures - richer than msdb.dbo.backupset.
        Returns $null if the table is not present.
    #>
    param(
        [string]$Instance,
        [string]$Database,
        [double]$SinceHours,
        [System.Management.Automation.PSCredential]$Credential
    )

    $q = @"
IF OBJECT_ID('dbo.CommandLog', 'U') IS NULL
BEGIN
    SELECT CAST(NULL AS sysname) AS DatabaseName WHERE 1 = 0
END
ELSE
BEGIN
    SELECT DatabaseName,
           CommandType,
           CASE WHEN Command LIKE '%WITH DIFFERENTIAL%' OR Command LIKE '%DIFFERENTIAL,%' THEN 1 ELSE 0 END AS IsDifferential,
           StartTime,
           EndTime,
           ErrorNumber,
           ErrorMessage
    FROM dbo.CommandLog
    WHERE CommandType IN ('BACKUP_DATABASE', 'BACKUP_LOG')
      AND StartTime >= DATEADD(HOUR, -CAST($([int][math]::Ceiling($SinceHours)) AS int), SYSDATETIME())
    ORDER BY StartTime
END
"@
    $rows = Invoke-SqlQuery -Instance $Instance -Database $Database -Query $q -Credential $Credential
    if ($rows.Columns.Count -eq 1 -and $rows.Rows.Count -eq 0) { return $null }

    $log = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows.Rows) {
        $type = if ([int]$row.IsDifferential -eq 1) { 'DIFF' }
        elseif ([string]$row.CommandType -eq 'BACKUP_LOG') { 'LOG' }
        else { 'FULL' }
        $log.Add([pscustomobject]@{
                Database    = [string]$row.DatabaseName
                BackupType  = $type
                StartTime   = [datetime]$row.StartTime
                EndTime     = if ($row.EndTime -is [DBNull]) { $null } else { [datetime]$row.EndTime }
                ErrorNumber = if ($row.ErrorNumber -is [DBNull]) { 0 } else { [int]$row.ErrorNumber }
                ErrorMessage = if ($row.ErrorMessage -is [DBNull]) { '' } else { [string]$row.ErrorMessage }
            })
    }
    # -NoEnumerate so an empty result still returns a (0-count) collection, not $null,
    # keeping it distinct from the "table not present" case above.
    return Write-Output -NoEnumerate $log
}

function Get-SqlDatabaseInfo {
    param(
        [string]$Instance,
        [System.Management.Automation.PSCredential]$Credential
    )
    $q = @"
SELECT d.name AS DatabaseName, d.recovery_model_desc AS RecoveryModel, d.state_desc AS State,
       (SELECT MAX(b.backup_finish_date) FROM msdb.dbo.backupset b
        WHERE b.database_name = d.name AND b.type = 'D') AS LastFull,
       (SELECT MAX(b.backup_finish_date) FROM msdb.dbo.backupset b
        WHERE b.database_name = d.name AND b.type = 'L') AS LastLog
FROM sys.databases AS d
WHERE d.database_id <> 2   -- tempdb
"@
    $rows = Invoke-SqlQuery -Instance $Instance -Database 'master' -Query $q -Credential $Credential
    $info = @{}
    foreach ($row in $rows.Rows) {
        $info[[string]$row.DatabaseName] = [pscustomobject]@{
            RecoveryModel = [string]$row.RecoveryModel
            State         = [string]$row.State
            LastFull      = if ($row.LastFull -is [DBNull]) { $null } else { [datetime]$row.LastFull }
            LastLog       = if ($row.LastLog -is [DBNull]) { $null } else { [datetime]$row.LastLog }
        }
    }
    return $info
}

function Expand-DatabaseScope {
    <#
        Resolves an Ola @Databases token to concrete database names using the
        SQL database inventory. Supports USER_DATABASES, SYSTEM_DATABASES,
        ALL_DATABASES, explicit comma lists, and '-name' exclusions. Wildcards
        are treated literally-ish via -like.
    #>
    param(
        [string]$Scope,
        [hashtable]$DatabaseInfo
    )
    $system = @('master', 'model', 'msdb')
    $all = $DatabaseInfo.Keys
    $result = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $excludes = New-Object System.Collections.Generic.List[string]

    foreach ($tokenRaw in ($Scope -split ',')) {
        $token = $tokenRaw.Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        $isExclude = $token.StartsWith('-')
        if ($isExclude) { $token = $token.Substring(1).Trim() }

        $matched = switch -Regex ($token) {
            '^(USER_DATABASES)$' { $all | Where-Object { $system -notcontains $_ } }
            '^(SYSTEM_DATABASES)$' { $system | Where-Object { $all -contains $_ } }
            '^(ALL_DATABASES)$' { $all }
            default { $all | Where-Object { $_ -like $token } }
        }

        if ($isExclude) { $matched | ForEach-Object { [void]$excludes.Add($_) } }
        else { $matched | ForEach-Object { [void]$result.Add($_) } }
    }

    foreach ($e in $excludes) { [void]$result.Remove($e) }
    return @($result)
}

#endregion

#region Expectation model -----------------------------------------------------

function Get-ExpectationModel {
    <#
        Produces $model[$database][$type] = @{ CleanupHours; IntervalHours;
        NumberOfFiles; CleanupMode; Source } by layering, lowest precedence first:
        inferred interval  ->  config defaults  ->  SQL job config  ->
        config per-db  ->  command-line overrides.
    #>
    param(
        [object[]]$LogicalBackup = @(),
        [object]$JobConfig,
        [hashtable]$DatabaseInfo,
        [object]$CommandLog,
        [pscustomobject]$Config,
        [hashtable]$Override
    )

    $databases = @($LogicalBackup.Database | Sort-Object -Unique)
    if ($DatabaseInfo) {
        $databases = @($databases + $DatabaseInfo.Keys | Sort-Object -Unique)
    }

    $model = @{}
    foreach ($db in $databases) {
        $model[$db] = @{}
        foreach ($type in $script:BackupTypes) {
            $model[$db][$type] = [ordered]@{
                CleanupHours  = $null
                IntervalHours = $null
                NumberOfFiles = 1
                CleanupMode   = 'AFTER_BACKUP'
                Source        = @()
            }
        }
    }

    # 1. Inferred interval from file spacing (median gap between consecutive backups).
    foreach ($grp in ($LogicalBackup | Where-Object { -not $_.IsCopyOnly } |
            Group-Object Database, BackupType)) {
        $items = @($grp.Group | Sort-Object Timestamp)
        if ($items.Count -lt 2) { continue }
        $gaps = for ($i = 1; $i -lt $items.Count; $i++) {
            ($items[$i].Timestamp - $items[$i - 1].Timestamp).TotalHours
        }
        $median = Get-Median -Value ([double[]]$gaps)
        $db = $items[0].Database
        $type = $items[0].BackupType
        if ($model.ContainsKey($db) -and $null -ne $median -and $median -gt 0) {
            $model[$db][$type].IntervalHours = [math]::Round($median, 2)
            $model[$db][$type].Source += 'interval:inferred'
        }
    }

    # 1b. Interval from dbo.CommandLog successful runs (more authoritative than files).
    if ($CommandLog) {
        foreach ($grp in ($CommandLog | Where-Object { $_.ErrorNumber -eq 0 } |
                Group-Object Database, BackupType)) {
            $times = @($grp.Group | Sort-Object StartTime | Select-Object -ExpandProperty StartTime)
            if ($times.Count -lt 2) { continue }
            $gaps = for ($i = 1; $i -lt $times.Count; $i++) {
                ($times[$i] - $times[$i - 1]).TotalHours
            }
            $median = Get-Median -Value ([double[]]$gaps)
            $db = $grp.Group[0].Database
            $type = $grp.Group[0].BackupType
            if ($model.ContainsKey($db) -and $null -ne $median -and $median -gt 0) {
                $model[$db][$type].IntervalHours = [math]::Round($median, 2)
                $model[$db][$type].Source += 'interval:commandlog'
            }
        }
    }

    # 2. Config file defaults.
    if ($Config -and $Config.PSObject.Properties['defaults']) {
        $d = $Config.defaults
        foreach ($db in $model.Keys) {
            foreach ($type in $script:BackupTypes) {
                $cleanKey = "$($type.Substring(0,1))$($type.Substring(1).ToLower())CleanupTimeHours"
                $intKey = "$($type.Substring(0,1))$($type.Substring(1).ToLower())IntervalHours"
                if ($d.PSObject.Properties[$cleanKey] -and $null -ne $d.$cleanKey) {
                    $model[$db][$type].CleanupHours = [double]$d.$cleanKey
                    $model[$db][$type].Source += 'cleanup:config-default'
                }
                if ($d.PSObject.Properties[$intKey] -and $null -ne $d.$intKey) {
                    $model[$db][$type].IntervalHours = [double]$d.$intKey
                    $model[$db][$type].Source += 'interval:config-default'
                }
            }
        }
    }

    # 3. SQL job config (expanded per database).
    if ($JobConfig -and $DatabaseInfo) {
        foreach ($jc in $JobConfig) {
            $targets = Expand-DatabaseScope -Scope $jc.Scope -DatabaseInfo $DatabaseInfo
            foreach ($db in $targets) {
                if (-not $model.ContainsKey($db)) { continue }
                $slot = $model[$db][$jc.BackupType]
                if ($null -ne $jc.CleanupHours) {
                    $slot.CleanupHours = $jc.CleanupHours
                    $slot.Source += "cleanup:job($($jc.JobName))"
                }
                $slot.NumberOfFiles = $jc.NumberOfFiles
                $slot.CleanupMode = $jc.CleanupMode
            }
        }
    }

    # 4. Config file per-database overrides.
    if ($Config -and $Config.PSObject.Properties['databases'] -and $Config.databases) {
        foreach ($dbProp in $Config.databases.PSObject.Properties) {
            $db = $dbProp.Name
            if (-not $model.ContainsKey($db)) { $model[$db] = @{}; foreach ($t in $script:BackupTypes) { $model[$db][$t] = [ordered]@{ CleanupHours = $null; IntervalHours = $null; NumberOfFiles = 1; CleanupMode = 'AFTER_BACKUP'; Source = @() } } }
            foreach ($type in $script:BackupTypes) {
                $cleanKey = "$($type.Substring(0,1))$($type.Substring(1).ToLower())CleanupTimeHours"
                $intKey = "$($type.Substring(0,1))$($type.Substring(1).ToLower())IntervalHours"
                if ($dbProp.Value.PSObject.Properties[$cleanKey] -and $null -ne $dbProp.Value.$cleanKey) {
                    $model[$db][$type].CleanupHours = [double]$dbProp.Value.$cleanKey
                    $model[$db][$type].Source += 'cleanup:config-db'
                }
                if ($dbProp.Value.PSObject.Properties[$intKey] -and $null -ne $dbProp.Value.$intKey) {
                    $model[$db][$type].IntervalHours = [double]$dbProp.Value.$intKey
                    $model[$db][$type].Source += 'interval:config-db'
                }
            }
        }
    }

    # 5. Command-line overrides (highest precedence).
    foreach ($db in $model.Keys) {
        foreach ($type in $script:BackupTypes) {
            if ($Override.ContainsKey("$type-Cleanup") -and $null -ne $Override["$type-Cleanup"]) {
                $model[$db][$type].CleanupHours = [double]$Override["$type-Cleanup"]
                $model[$db][$type].Source += 'cleanup:parameter'
            }
            if ($Override.ContainsKey("$type-Interval") -and $null -ne $Override["$type-Interval"]) {
                $model[$db][$type].IntervalHours = [double]$Override["$type-Interval"]
                $model[$db][$type].Source += 'interval:parameter'
            }
        }
    }

    return $model
}

#endregion

#region Checks ---------------------------------------------------------------

function Test-BackupChain {
    param(
        [object[]]$LogicalBackup = @(),
        [hashtable]$Model,
        [hashtable]$DatabaseInfo,
        [object]$CommandLog,
        [double]$ToleranceFactor
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $instanceLabel = if ($LogicalBackup.Count -gt 0) { $LogicalBackup[0].Instance } else { '' }

    $byDb = $LogicalBackup | Group-Object Database

    foreach ($dbGrp in $byDb) {
        $db = $dbGrp.Name
        $dbTypeSlots = if ($Model.ContainsKey($db)) { $Model[$db] } else { $null }

        # How long has ANY backup been taken for this database? Used to tell
        # "short history" apart from "older backups are missing".
        $dbOldestAge = ($dbGrp.Group | Measure-Object -Property AgeHours -Maximum).Maximum

        foreach ($type in $script:BackupTypes) {
            $items = @($dbGrp.Group | Where-Object { $_.BackupType -eq $type } | Sort-Object Timestamp)
            $slot = if ($dbTypeSlots) { $dbTypeSlots[$type] } else { $null }

            $cleanup = if ($slot) { $slot.CleanupHours } else { $null }
            $interval = if ($slot) { $slot.IntervalHours } else { $null }
            $numFiles = if ($slot) { $slot.NumberOfFiles } else { 1 }

            # --- Count gap -------------------------------------------------
            if ($items.Count -gt 0 -and $null -ne $cleanup -and $null -ne $interval -and $interval -gt 0) {
                $withinRetention = @($items | Where-Object { $_.AgeHours -le ($cleanup + $interval) })
                $found = $withinRetention.Count

                # The retained-copy count oscillates between floor(C/I) and floor(C/I)+1
                # as the newest backup ages. floor(C/I) is the guaranteed minimum.
                $minSteady = [math]::Max(1, [int][math]::Floor($cleanup / $interval))

                # Steady state = old files are actually being aged out, i.e. this
                # database has been backed up for at least (C - I) hours.
                $steadyState = $dbOldestAge -ge ($cleanup - $interval)

                if ($steadyState) {
                    if ($found -lt $minSteady) {
                        $sev = if ($found -le 1) { 'Error' } else { 'Warning' }
                        $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity $sev `
                                    -Finding 'Fewer backups present than retention + cadence guarantee' `
                                    -Expected "$minSteady-$($minSteady + 1)" -Found $found `
                                    -Detail ("CleanupTime={0}h, interval~{1}h. Failed/missing runs, or files deleted outside Ola's cleanup." -f $cleanup, $interval)))
                    }
                }
                else {
                    # Not enough history to be sure. Expect only what the observed
                    # span for this type can account for: (oldest-newest)/interval + 1.
                    $typeOldest = ($items | Measure-Object -Property AgeHours -Maximum).Maximum
                    $typeNewest = ($items | Measure-Object -Property AgeHours -Minimum).Minimum
                    $spanExpect = [int][math]::Round(($typeOldest - $typeNewest) / $interval) + 1
                    $expectFromHistory = [math]::Min($minSteady + 1, $spanExpect)

                    if ($found -lt $expectFromHistory) {
                        $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Warning' `
                                    -Finding 'Fewer backups present than cadence implies (short history)' `
                                    -Expected $expectFromHistory -Found $found `
                                    -Detail ("CleanupTime={0}h, interval~{1}h, only ~{2}h of history for this database - young setup or missing runs." -f $cleanup, $interval, [int]$dbOldestAge)))
                    }
                    elseif ($found -le 1) {
                        $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Info' `
                                    -Finding ("Only {0} {1} backup present - cannot confirm retention health" -f $found, $type) `
                                    -Found $found `
                                    -Detail 'Too little history on disk to tell a new setup from missing backups. Run with -SqlInstance to use job schedule and dbo.CommandLog.'))
                    }
                }
            }
            elseif ($items.Count -gt 0 -and $null -eq $cleanup) {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Info' `
                            -Finding 'Retention unknown - count gap not evaluated' -Found $items.Count `
                            -Detail 'Supply -SqlInstance, -ConfigPath, or -*CleanupTimeHours to enable this check.'))
            }

            # --- Stale / orphan files -----------------------------------
            if ($items.Count -gt 0 -and $null -ne $cleanup) {
                $stale = @($items | Where-Object { $_.AgeHours -gt ($cleanup * 2) })
                if ($stale.Count -gt 0) {
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Warning' `
                                -Finding 'Files far older than CleanupTime still present' `
                                -Expected "<= $cleanup h old" -Found ("{0} file(s), oldest {1} h" -f $stale.Count, [int]($stale[0].AgeHours)) `
                                -Detail 'Ola cleanup may be failing (permissions, striped-file mismatch), or these are past failures never rolled off.'))
                }
            }

            # --- Striping completeness ---------------------------------
            # Use @NumberOfFiles when known; otherwise fall back to the widest
            # stripe count actually seen for this (database, type).
            $expectFiles = $numFiles
            if ($items.Count -gt 0) {
                $observedMax = ($items | Measure-Object -Property FileCount -Maximum).Maximum
                if ($observedMax -gt $expectFiles) { $expectFiles = $observedMax }
            }
            if ($expectFiles -gt 1) {
                $incomplete = @($items | Where-Object { $_.FileCount -lt $expectFiles })
                if ($incomplete.Count -gt 0) {
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Error' `
                                -Finding 'Striped backup is missing member files' `
                                -Expected "$expectFiles files/backup" -Found ("{0} backup(s) short" -f $incomplete.Count) `
                                -Detail ("e.g. {0:yyyy-MM-dd HH:mm} has {1} of {2} stripe files - the backup is unrestorable." -f $incomplete[0].Timestamp, $incomplete[0].FileCount, $expectFiles)))
                }
            }

            # --- Chain gaps (LOG especially, DIFF too) -----------------
            # All gaps for a (database, type) roll up into ONE finding so a badly
            # tuned interval or a long outage does not flood the report.
            if ($type -ne 'FULL' -and $items.Count -ge 2 -and $null -ne $interval -and $interval -gt 0) {
                $threshold = $interval * $ToleranceFactor
                $gaps = New-Object System.Collections.Generic.List[object]
                for ($i = 1; $i -lt $items.Count; $i++) {
                    $gap = ($items[$i].Timestamp - $items[$i - 1].Timestamp).TotalHours
                    if ($gap -gt $threshold) {
                        $gaps.Add([pscustomobject]@{ Hours = $gap; From = $items[$i - 1].Timestamp; To = $items[$i].Timestamp })
                    }
                }
                if ($gaps.Count -gt 0) {
                    $worst = $gaps | Sort-Object Hours -Descending | Select-Object -First 1
                    $totalMissing = ($gaps | ForEach-Object { [int][math]::Round($_.Hours / $interval) - 1 } | Measure-Object -Sum).Sum
                    $findingText = if ($gaps.Count -eq 1) {
                        "{0} chain gap of {1}" -f $type, (Get-DurationText $worst.Hours)
                    }
                    else {
                        "{0} chain has {1} gaps (worst {2})" -f $type, $gaps.Count, (Get-DurationText $worst.Hours)
                    }
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Error' `
                                -Finding $findingText `
                                -Expected ("<= {0} between backups" -f (Get-DurationText $threshold)) `
                                -Found ("~{0} backup(s) missing" -f [math]::Max($gaps.Count, $totalMissing)) `
                                -Detail ("Worst gap {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm}. Point-in-time recovery is broken across each gap." -f $worst.From, $worst.To)))
                }
            }

            # --- No recent backup ------------------------------------
            if ($items.Count -gt 0 -and $null -ne $interval -and $interval -gt 0) {
                $newestAge = $items[-1].AgeHours
                if ($newestAge -gt ($interval * $ToleranceFactor)) {
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Warning' `
                                -Finding 'Newest backup is older than one interval' `
                                -Expected ("<= {0} h" -f [math]::Round($interval * $ToleranceFactor, 1)) -Found ("{0} h" -f $newestAge) `
                                -Detail ("Last {0}: {1:yyyy-MM-dd HH:mm}." -f $type, $items[-1].Timestamp)))
                }
            }
        }

        # --- Roll-forward coverage: every retained FULL/DIFF has a LOG at/after it
        $fullItems = @($dbGrp.Group | Where-Object { $_.BackupType -eq 'FULL' } | Sort-Object Timestamp)
        $logItems = @($dbGrp.Group | Where-Object { $_.BackupType -eq 'LOG' } | Sort-Object Timestamp)
        if ($fullItems.Count -gt 0 -and $logItems.Count -gt 0) {
            $oldestFull = $fullItems[0]
            $oldestLog = $logItems[0]
            if ($oldestLog.Timestamp -gt $oldestFull.Timestamp.AddHours(2)) {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'LOG' -Severity 'Warning' `
                            -Finding 'Oldest FULL has no log coverage from its start' `
                            -Expected ("LOG on/before {0:yyyy-MM-dd HH:mm}" -f $oldestFull.Timestamp) `
                            -Found ("oldest LOG {0:yyyy-MM-dd HH:mm}" -f $oldestLog.Timestamp) `
                            -Detail 'That FULL cannot be rolled forward - LOG retention is shorter than FULL retention, or early logs were lost.'))
            }
        }

        # --- Recovery-model mismatch (needs SQL) ---------------------
        if ($DatabaseInfo -and $DatabaseInfo.ContainsKey($db)) {
            $rm = $DatabaseInfo[$db].RecoveryModel
            $hasLog = $logItems.Count -gt 0
            if (($rm -eq 'FULL' -or $rm -eq 'BULK_LOGGED') -and -not $hasLog) {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'LOG' -Severity 'Warning' `
                            -Finding "Recovery model is $rm but no LOG backups found" `
                            -Detail 'Transaction log will grow unbounded and point-in-time recovery is not possible.'))
            }
            if ($rm -eq 'SIMPLE' -and $hasLog) {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'LOG' -Severity 'Info' `
                            -Finding 'LOG backups present for a SIMPLE recovery database' `
                            -Detail 'These cannot be used for point-in-time restore; check the job scope.'))
            }
        }
    }

    # --- Retention consistency (per database) ----------------------
    foreach ($db in ($Model.Keys | Sort-Object)) {
        $full = $Model[$db]['FULL']
        $diff = $Model[$db]['DIFF']
        $log = $Model[$db]['LOG']

        if ($null -ne $log.CleanupHours -and $null -ne $full.CleanupHours -and $log.CleanupHours -lt $full.CleanupHours) {
            $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'LOG' -Severity 'Warning' `
                        -Finding 'LOG retention is shorter than FULL retention' `
                        -Expected ("LOG CleanupTime >= {0}h" -f $full.CleanupHours) -Found ("{0}h" -f $log.CleanupHours) `
                        -Detail 'Your oldest retained FULL backups have no continuous log chain and cannot be rolled forward.'))
        }
        if ($null -ne $diff.CleanupHours -and $null -ne $full.CleanupHours -and $diff.CleanupHours -gt $full.CleanupHours) {
            $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'DIFF' -Severity 'Warning' `
                        -Finding 'DIFF retention is longer than FULL retention' `
                        -Expected ("DIFF CleanupTime <= {0}h" -f $full.CleanupHours) -Found ("{0}h" -f $diff.CleanupHours) `
                        -Detail 'Differentials may outlive their base full, becoming unrestorable.'))
        }
        foreach ($type in $script:BackupTypes) {
            $slot = $Model[$db][$type]
            if ($null -ne $slot.CleanupHours -and $null -ne $slot.IntervalHours -and $slot.IntervalHours -gt 0) {
                if ($slot.CleanupHours -lt $slot.IntervalHours) {
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Error' `
                                -Finding 'CleanupTime is shorter than the backup interval' `
                                -Expected ("CleanupTime >= {0}h" -f $slot.IntervalHours) -Found ("{0}h" -f $slot.CleanupHours) `
                                -Detail ('With CleanupMode={0} a failed run can leave zero valid {1} backups.' -f $slot.CleanupMode, $type)))
                }
                elseif ([math]::Abs(($slot.CleanupHours % $slot.IntervalHours)) -gt 0.01) {
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Info' `
                                -Finding 'CleanupTime is not a whole multiple of the interval' `
                                -Expected 'multiple of interval' -Found ("{0}h / {1}h" -f $slot.CleanupHours, $slot.IntervalHours) `
                                -Detail 'The number of retained copies will oscillate between runs.'))
                }
            }
            if ($null -ne $slot.CleanupHours -and $slot.CleanupMode -eq 'BEFORE_BACKUP') {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $type -Severity 'Warning' `
                            -Finding 'CleanupMode is BEFORE_BACKUP' `
                            -Detail 'Old files are deleted before the new backup runs; a failure then leaves you with fewer or no copies.'))
            }
        }
    }

    # --- Coverage: online DB with no backup files at all ----------
    if ($DatabaseInfo) {
        $seen = @($LogicalBackup.Database | Sort-Object -Unique)
        foreach ($db in ($DatabaseInfo.Keys | Sort-Object)) {
            $di = $DatabaseInfo[$db]
            if ($di.State -ne 'ONLINE') { continue }
            if ($db -eq 'tempdb') { continue }
            if ($seen -notcontains $db) {
                $lastFullText = if ($di.LastFull) { $di.LastFull.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -Severity 'Error' `
                            -Finding 'Database is ONLINE but no backup files were found under the scanned paths' `
                            -Detail ("Recovery model {0}. Last full in msdb history: {1}." -f $di.RecoveryModel, $lastFullText)))
            }
        }
    }

    # --- Failed runs recorded in dbo.CommandLog -------------------
    if ($CommandLog) {
        foreach ($grp in ($CommandLog | Where-Object { $_.ErrorNumber -ne 0 } |
                Group-Object Database, BackupType)) {
            $g = @($grp.Group | Sort-Object StartTime)
            $last = $g[-1]
            $findings.Add((New-Finding -Instance $instanceLabel -Database $g[0].Database -BackupType $g[0].BackupType -Severity 'Error' `
                        -Finding ("{0} backup run(s) failed" -f $g.Count) `
                        -Expected 'ErrorNumber = 0' -Found ("last failure {0:yyyy-MM-dd HH:mm}" -f $last.StartTime) `
                        -Detail ("Error {0}: {1}" -f $last.ErrorNumber, ($last.ErrorMessage -replace '\s+', ' ').Trim())))
        }

        # Successful run in CommandLog but no matching file on disk (± 1 h).
        $fileStamps = @{}
        foreach ($lb in $LogicalBackup) {
            $fileStamps["$($lb.Database)|$($lb.BackupType)"] += @($lb.Timestamp)
        }
        foreach ($grp in ($CommandLog | Where-Object { $_.ErrorNumber -eq 0 } |
                Group-Object Database, BackupType)) {
            $key = "$($grp.Group[0].Database)|$($grp.Group[0].BackupType)"
            $stamps = if ($fileStamps.ContainsKey($key)) { $fileStamps[$key] } else { @() }
            $missing = @($grp.Group | Where-Object {
                    $runTime = $_.StartTime
                    -not ($stamps | Where-Object { [math]::Abs(($_ - $runTime).TotalHours) -le 1 })
                })
            # Only care about runs still inside the retention window.
            $slot = if ($Model.ContainsKey($grp.Group[0].Database)) { $Model[$grp.Group[0].Database][$grp.Group[0].BackupType] } else { $null }
            $cleanup = if ($slot) { $slot.CleanupHours } else { $null }
            if ($null -ne $cleanup) {
                $missing = @($missing | Where-Object { ($script:Now - $_.StartTime).TotalHours -le $cleanup })
            }
            if ($missing.Count -gt 0) {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $grp.Group[0].Database -BackupType $grp.Group[0].BackupType -Severity 'Warning' `
                            -Finding 'CommandLog shows successful runs with no matching file on disk' `
                            -Found ("{0} run(s), e.g. {1:yyyy-MM-dd HH:mm}" -f $missing.Count, $missing[0].StartTime) `
                            -Detail 'The backup succeeded but the file is gone (cleaned early, moved, or -BackupPath points somewhere else).'))
            }
        }
    }

    return $findings
}

#endregion

#region HTML report --------------------------------------------------------

function Write-HtmlReport {
    param(
        [object[]]$Finding,
        [string]$Path,
        [string[]]$ScannedPath
    )

    function _enc([object]$v) {
        if ($null -eq $v) { return '' }
        return [System.Security.SecurityElement]::Escape([string]$v)
    }

    $rows = ($Finding | Sort-Object @{ E = { @('Error', 'Warning', 'Info').IndexOf($_.Severity) } }, Database, BackupType |
        ForEach-Object {
            $cls = $_.Severity.ToLower()
            "<tr class='$cls'><td>$(_enc $_.Severity)</td><td>$(_enc $_.Database)</td><td>$(_enc $_.BackupType)</td><td>$(_enc $_.Finding)</td><td>$(_enc $_.Expected)</td><td>$(_enc $_.Found)</td><td>$(_enc $_.Detail)</td></tr>"
        }) -join "`n"

    $counts = @($Finding | Group-Object Severity | ForEach-Object { "$($_.Name): $($_.Count)" })
    $scanned = _enc ($ScannedPath -join '; ')
    $countsText = _enc ($counts -join ' / ')

    $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>BackupChainCheck report</title>
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1a1a1a; }
 h1 { font-size: 18px; } .meta { color: #555; font-size: 12px; margin-bottom: 16px; }
 table { border-collapse: collapse; width: 100%; font-size: 13px; }
 th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
 th { background: #f3f3f3; }
 tr.error td { background: #fde8e8; } tr.warning td { background: #fff6e5; } tr.info td { background: #eef4ff; }
</style></head><body>
<h1>BackupChainCheck report</h1>
<div class="meta">
 Generated $($script:Now.ToString('yyyy-MM-dd HH:mm:ss')) &middot;
 Scanned: $scanned &middot;
 $countsText
</div>
<table>
<thead><tr><th>Severity</th><th>Database</th><th>Type</th><th>Finding</th><th>Expected</th><th>Found</th><th>Detail</th></tr></thead>
<tbody>
$rows
</tbody></table>
</body></html>
"@

    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
    Write-Verbose "HTML report written to $Path"
}

#endregion

#region Main ---------------------------------------------------------------

# Dot-sourced (e.g. by the Pester tests) just to reach the functions above:
# skip the analysis run.
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Verbose "BackupChainCheck starting - $($script:Now.ToString('s'))"

$config = $null
if ($ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

$records = @(Get-BackupFileInventory -Root $BackupPath)
Write-Verbose "Parsed $($records.Count) physical backup file(s)."

if (-not $IncludeCopyOnly) {
    $records = @($records | Where-Object { -not $_.IsCopyOnly })
}

$logical = @(Group-LogicalBackup -Record $records)
Write-Verbose "Grouped into $($logical.Count) logical backup(s)."

$jobConfig = $null
$dbInfo = $null
$commandLog = $null
if ($SqlInstance) {
    try {
        $jobConfig = @(Get-OlaJobConfig -Instance $SqlInstance -Credential $SqlCredential)
        $dbInfo = Get-SqlDatabaseInfo -Instance $SqlInstance -Credential $SqlCredential
        Write-Verbose "Read $($jobConfig.Count) DatabaseBackup job step(s) and $($dbInfo.Count) database(s) from $SqlInstance."
    }
    catch {
        Write-Warning "Could not read configuration from $SqlInstance : $($_.Exception.Message)"
    }
    try {
        $commandLog = Get-OlaCommandLog -Instance $SqlInstance -Database $SolutionDatabase -SinceHours $HistoryHours -Credential $SqlCredential
        if ($null -eq $commandLog) {
            Write-Warning "dbo.CommandLog not found in [$SolutionDatabase] on $SqlInstance - pass -SolutionDatabase if the Maintenance Solution lives elsewhere."
        }
        else {
            $commandLog = @($commandLog)
            Write-Verbose "Read $($commandLog.Count) CommandLog backup row(s) from [$SolutionDatabase]."
        }
    }
    catch {
        Write-Warning "Could not read dbo.CommandLog from [$SolutionDatabase] on $SqlInstance : $($_.Exception.Message)"
    }
}

$override = @{
    'FULL-Cleanup' = if ($PSBoundParameters.ContainsKey('FullCleanupTimeHours')) { $FullCleanupTimeHours } else { $null }
    'DIFF-Cleanup' = if ($PSBoundParameters.ContainsKey('DiffCleanupTimeHours')) { $DiffCleanupTimeHours } else { $null }
    'LOG-Cleanup'  = if ($PSBoundParameters.ContainsKey('LogCleanupTimeHours')) { $LogCleanupTimeHours } else { $null }
    'FULL-Interval' = if ($PSBoundParameters.ContainsKey('FullIntervalHours')) { $FullIntervalHours } else { $null }
    'DIFF-Interval' = if ($PSBoundParameters.ContainsKey('DiffIntervalHours')) { $DiffIntervalHours } else { $null }
    'LOG-Interval'  = if ($PSBoundParameters.ContainsKey('LogIntervalHours')) { $LogIntervalHours } else { $null }
}

$model = Get-ExpectationModel -LogicalBackup $logical -JobConfig $jobConfig -DatabaseInfo $dbInfo -CommandLog $commandLog -Config $config -Override $override

# Directory-mismatch note.
if ($jobConfig) {
    foreach ($jc in ($jobConfig | Where-Object { $_.Directory })) {
        foreach ($d in ($jc.Directory -split ',')) {
            $dt = $d.Trim()
            if ($dt -and -not ($BackupPath | Where-Object { $dt -like "$_*" -or $_ -like "$dt*" })) {
                Write-Warning "Job '$($jc.JobName)' targets '$dt' which is not among the scanned -BackupPath roots."
            }
        }
    }
}

if ($logical.Count -eq 0) {
    Write-Warning 'No recognisable Ola Hallengren backup files were found under the supplied path(s).'
}

$findings = Test-BackupChain -LogicalBackup $logical -Model $model -DatabaseInfo $dbInfo -CommandLog $commandLog -ToleranceFactor $GapToleranceFactor

$sorted = $findings | Sort-Object @{ E = { @('Error', 'Warning', 'Info').IndexOf($_.Severity) } }, Database, BackupType, Finding

if (-not $Quiet) {
    if ($sorted) {
        $sorted | Format-Table Severity, Database, BackupType, Finding, Expected, Found -AutoSize | Out-Host
        Write-Host ''
        $sorted | Group-Object Severity | ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.Name, $_.Count) }
    }
    else {
        Write-Host 'No findings - retention, cadence and files on disk are consistent.' -ForegroundColor Green
    }
}

if ($ReportPath) {
    Write-HtmlReport -Finding $sorted -Path $ReportPath -ScannedPath $BackupPath
    if (-not $Quiet) { Write-Host "HTML report: $ReportPath" }
}

# Emit objects on the pipeline.
$sorted

if ($FailOnGap) {
    $hasError = @($findings | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0
    $hasWarn = @($findings | Where-Object { $_.Severity -eq 'Warning' }).Count -gt 0
    if ($hasError) { exit 1 }
    elseif ($hasWarn) { exit 2 }
    else { exit 0 }
}

#endregion
