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

.PARAMETER Database
    One or more database-name wildcard patterns to limit the analysis (and the
    findings) to. Default '*' - every database. Matching is -like, e.g.
    -Database StackOverflow2010  or  -Database 'JDE_*','ODS'. A single
    comma-separated string is also accepted (Ola's @Databases style):
    -Database 'StackOverflow2010,StackOverflow2013' is split into two patterns.

.PARAMETER SqlInstance
    Optional. One or more SQL Server instances to read DatabaseBackup job
    configuration and database metadata from (msdb + master, read-only). Windows
    auth unless -SqlCredential is supplied. Accepts -SqlInstance A,B or a single
    'A,B' string. With more than one instance the analysis runs once per server:
    every -BackupPath root is scanned once and each server is reconciled against
    the files whose parsed <SERVER$INSTANCE> folder matches it. Output is a
    per-server block; -FailOnGap returns the worst exit code across all servers.

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

.PARAMETER IncludeOfflineDatabases
    With -SqlInstance, the analysis is restricted to databases that currently
    exist and are ONLINE in sys.databases; backups on disk / in dbo.CommandLog for
    databases that were dropped or renamed (e.g. a stale '_ODS') are ignored. Set
    this switch to analyse every database that has backups, online or not.

.PARAMETER ReportPath
    Optional path for a standalone HTML report.

.PARAMETER FailOnGap
    Set the exit code: 1 if any Error finding, 2 if only Warnings, 0 otherwise.

.PARAMETER Predict
    Instead of returning findings, project the set of backups that SHOULD be on
    disk right now for every in-scope (database, backup type) - one slot every
    IntervalHours, back to age CleanupHours + IntervalHours - and match each slot
    to an actual file. Prints a present/expected matrix plus the list of missing
    slots, and emits one BackupChainCheck.Prediction object per (database, type)
    on the pipeline (each with a .Slots breakdown). The findings table still
    prints to the host; -FailOnGap still uses the findings.

.PARAMETER Graph
    Draw an ASCII timeline of each database's backup chain - one row per
    (database, type) with '|' for a backup present, 'X' for one recorded in msdb
    whose file is gone, and inline markers where the chain has an idle gap, an
    LSN break or a recovery-fork change. Console only; the pipeline is unchanged.

.PARAMETER RestorePlan
    Print, per database, the shortest sequence of backup FILES ON DISK that forms
    a valid LSN chain to the latest recoverable point (newest FULL -> newest
    matching DIFF -> contiguous LOGs), together with the T-SQL RESTORE script,
    and emit one BackupChainCheck.RestorePlan object per database (with a .Steps
    array and a .RestoreScript string) on the pipeline instead of the findings.
    Needs -SqlInstance for the LSNs.

.PARAMETER Advice
    Print a short plain-language review of the retention / cadence design at the
    top of the output - e.g. a DIFF @CleanupTime longer than the FULL one, a LOG
    retention shorter than FULL, a single-copy FULL - plus an approximate figure
    for backup files on disk that are past @CleanupTime or have no restore base.
    Grouped so an ALL_DATABASES job is stated once. Console only.

.PARAMETER JustLSN
    Print ONE run-summary line PER in-scope database and nothing else - no findings
    breakdown, no -Advice / -Predict / -Graph / -RestorePlan console output, and
    job/path warnings are silenced (unless -WarningAction is set). Each line is led
    with the server and database as a greppable key and carries that database's
    own LSN verdict, @CleanupTime, file counts and finding tally:

        WIN10  StackOverflow2010  |  LSN valid  |  BackupChainCheck 2026-09-08 16:44  |  @CleanupTime F/D/L 24/24/24h  |  files F/D/L 2/1/2  |  clean
        WIN10  StackOverflow2013  |  LSN error  |  BackupChainCheck 2026-09-08 16:44  |  @CleanupTime F/D/L 24/24/24h  |  files F/D/L 1/0/3  |  1E 2W 0I

    The server name is -SqlInstance, else the instance parsed from the backup file
    tree, else this host's name. Nothing is emitted on the pipeline - the lines
    are the entire output; -FailOnGap still sets the exit code. Ignored when
    combined with -Quiet.

.PARAMETER Quiet
    Suppress the console table (the pipeline objects are still returned).

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -SqlInstance SQL01 -BackupPath \\nas01\sqlbackup

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -BackupPath D:\Backup -ConfigPath .\expectations.json -ReportPath .\report.html

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -BackupPath D:\Backup -FullCleanupTimeHours 48 -FullIntervalHours 24 -FailOnGap

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -SqlInstance WIN10 -BackupPath E:\backups\WIN10 -Database StackOverflow2010

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -SqlInstance WIN10 -BackupPath E:\backups\WIN10 -Database StackOverflow2010 -Predict

.EXAMPLE
    .\Invoke-BackupChainCheck.ps1 -SqlInstance WIN10 -BackupPath E:\backups\WIN10 -Database StackOverflow2010 -RestorePlan

.NOTES
    Windows PowerShell 5.1. No external modules required.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$BackupPath,

    [string[]]$Database = '*',

    [string[]]$SqlInstance,

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

    [switch]$IncludeOfflineDatabases,

    [string]$ReportPath,

    [switch]$FailOnGap,

    [switch]$Predict,

    [switch]$Graph,

    [switch]$RestorePlan,

    [switch]$Advice,

    [switch]$JustLSN,

    [switch]$Quiet
)

# StrictMode 1.0 (uninitialised-variable checking) rather than 2.0+: this script
# leans on PowerShell's scalar/collection unification (.Count on a single object,
# member enumeration over a possibly-empty result), which 2.0+ turns into errors.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:BackupTypes = @('FULL', 'DIFF', 'LOG')
$script:Now = Get-Date

# Default table views for the emitted objects (findings, predictions), so a bare
# run prints a grid rather than a per-object property list. Optional - the script
# works without it, just less pretty.
if ($PSScriptRoot) {
    $script:FormatFile = Join-Path $PSScriptRoot 'BackupChainCheck.Format.ps1xml'
    if (Test-Path -LiteralPath $script:FormatFile) {
        try { Update-FormatData -PrependPath $script:FormatFile }
        catch { Write-Verbose "Could not load $script:FormatFile : $($_.Exception.Message)" }
    }
}

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
        PSTypeName = 'BackupChainCheck.Finding'
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

function Test-DatabaseMatch {
    <#
        True if $Name matches any of the -like wildcard patterns in $Pattern.
        '*' (the default -Database value) matches everything.
    #>
    param(
        [string]$Name,
        [string[]]$Pattern
    )
    foreach ($p in $Pattern) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Test-InstanceMatch {
    <#
        True when an Ola backup folder's parsed instance token ($FileInstance -
        'SERVER' or 'SERVER$INSTANCE', possibly an FQDN) names the same SQL Server
        instance as a -SqlInstance value ('SERVER', 'SERVER\INSTANCE',
        'host.domain\INSTANCE', 'SERVER,1433'). The host is compared
        case-insensitively on its leftmost label; a default instance is spelled
        'MSSQLSERVER' or left blank on either side.
    #>
    param([string]$FileInstance, [string]$SqlInstance)
    if ([string]::IsNullOrWhiteSpace($FileInstance) -or [string]::IsNullOrWhiteSpace($SqlInstance)) { return $false }

    $sqlParts = $SqlInstance -split '\\', 2
    $sqlHost = (($sqlParts[0]) -split '[,.]')[0].Trim()
    $sqlInst = if ($sqlParts.Count -gt 1) { $sqlParts[1].Trim() } else { '' }
    if ($sqlInst -eq 'MSSQLSERVER') { $sqlInst = '' }

    $fileParts = $FileInstance -split '\$', 2
    $fileHost = (($fileParts[0]) -split '\.')[0].Trim()
    $fileInst = if ($fileParts.Count -gt 1) { $fileParts[1].Trim() } else { '' }
    if ($fileInst -eq 'MSSQLSERVER') { $fileInst = '' }

    if ($sqlHost -ne $fileHost) { return $false }   # string -eq is case-insensitive
    return ($sqlInst -eq $fileInst)
}

function ConvertFrom-AgentTime {
    <# SQL Agent stores times of day as the integer HHMMSS (e.g. 180000 = 18:00). #>
    param([int]$Hhmmss)
    $h = [math]::Floor($Hhmmss / 10000)
    $m = [math]::Floor(($Hhmmss % 10000) / 100)
    return ('{0:00}:{1:00}' -f $h, $m)
}

function ConvertTo-ScheduleInterval {
    <#
        Turns the msdb.dbo.sysschedules frequency columns into an approximate
        interval in hours plus a human-readable text. Returns
        @{ IntervalHours = <double|$null>; Text = <string> }.

        Sub-day recurrence (freq_subday_type 2/4/8 = every N sec/min/hour) is the
        effective cadence. Otherwise the run happens once per active period and
        the wrapper frequency (daily / weekly / monthly) sets the spacing.
        Weekly/monthly with several occurrences is averaged - flagged as approx.
    #>
    param(
        [int]$FreqType,
        [int]$FreqInterval,
        [int]$FreqSubdayType,
        [int]$FreqSubdayInterval,
        [int]$FreqRecurrenceFactor = 0,
        [int]$ActiveStartTime = 0
    )

    if ($FreqSubdayType -eq 2 -or $FreqSubdayType -eq 4 -or $FreqSubdayType -eq 8) {
        $n = [math]::Max(1, $FreqSubdayInterval)
        $unitHours = switch ($FreqSubdayType) { 2 { 1.0 / 3600 } 4 { 1.0 / 60 } 8 { 1.0 } }
        $unit = switch ($FreqSubdayType) { 2 { 'second' } 4 { 'minute' } 8 { 'hour' } }
        $plural = if ($n -ne 1) { 's' } else { '' }
        return @{ IntervalHours = [math]::Round($n * $unitHours, 4); Text = ('every {0} {1}{2}' -f $n, $unit, $plural) }
    }

    $at = ConvertFrom-AgentTime $ActiveStartTime
    switch ($FreqType) {
        1 { return @{ IntervalHours = $null; Text = 'one time only' } }
        4 {
            $days = [math]::Max(1, $FreqInterval)
            $text = if ($days -eq 1) { "daily at $at" } else { "every $days days at $at" }
            return @{ IntervalHours = 24.0 * $days; Text = $text }
        }
        8 {
            $dayCount = 0
            foreach ($bit in 1, 2, 4, 8, 16, 32, 64) { if ($FreqInterval -band $bit) { $dayCount++ } }
            if ($dayCount -lt 1) { $dayCount = 1 }
            $weeks = [math]::Max(1, $FreqRecurrenceFactor)
            return @{ IntervalHours = [math]::Round((168.0 * $weeks) / $dayCount, 2); Text = ("weekly x{0}, {1} day(s)/week at {2} (approx)" -f $weeks, $dayCount, $at) }
        }
        16 { return @{ IntervalHours = 730.0; Text = "monthly at $at (approx)" } }
        32 { return @{ IntervalHours = 730.0; Text = "monthly relative at $at (approx)" } }
        default { return @{ IntervalHours = $null; Text = "freq_type=$FreqType (not interpreted)" } }
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

function Get-DataSizeText {
    param([double]$Bytes)
    if ($Bytes -lt 1KB) { return ('{0} B' -f [int]$Bytes) }
    if ($Bytes -lt 1MB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -lt 1TB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    return ('{0:N2} TB' -f ($Bytes / 1TB))
}

function Get-Median {
    param([double[]]$Value)
    if (-not $Value -or $Value.Count -eq 0) { return $null }
    $sorted = @($Value | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2
}

function Get-RunSummary {
    <#
        A single one-line header: run time, scope, @CleanupTime per type (a range
        when it differs across the scoped databases, '?' when unknown), the count
        of FULL / DIFF / LOG files present, and the finding tally.

        -InstancePrefix (the -JustLSN form) leads the line with
        '<server>  <scope>  |  ' and drops the standalone scope field so the name
        is not repeated - a greppable key for a monitoring probe.
    #>
    param(
        [datetime]$Now,
        [object[]]$Logical = @(),
        [hashtable]$Model,
        [object[]]$Finding = @(),
        [string]$LsnStatus = 'n/a',
        [string]$InstancePrefix
    )

    [string[]]$dbs = @()
    if ($Model) { [string[]]$dbs = @($Model.Keys) }
    if ($dbs.Count -gt 1) { [array]::Sort($dbs) }

    $scope = if ($dbs.Count -eq 1) { $dbs[0] } elseif ($dbs.Count -gt 1) { "$($dbs.Count) databases" } else { 'no databases' }

    $fc = @{ FULL = 0; DIFF = 0; LOG = 0 }
    foreach ($lb in $Logical) { if ($fc.ContainsKey($lb.BackupType)) { $fc[$lb.BackupType]++ } }

    $ret = @()
    foreach ($t in $script:BackupTypes) {
        $min = $null
        $max = $null
        foreach ($d in $dbs) {
            $c = $Model[$d][$t].CleanupHours
            if ($null -eq $c) { continue }
            $c = [double]$c
            if ($null -eq $min -or $c -lt $min) { $min = $c }
            if ($null -eq $max -or $c -gt $max) { $max = $c }
        }
        if ($null -eq $min) { $ret += '?' }
        elseif ($min -eq $max) { $ret += "$min" }
        else { $ret += "$min-$max" }
    }

    $e = @($Finding | Where-Object { $_.Severity -eq 'Error' }).Count
    $w = @($Finding | Where-Object { $_.Severity -eq 'Warning' }).Count
    $i = @($Finding | Where-Object { $_.Severity -eq 'Info' }).Count
    $tally = if (($e + $w + $i) -eq 0) { 'clean' } else { '{0}E {1}W {2}I' -f $e, $w, $i }

    if ($InstancePrefix) {
        return ('{0}  {1}  |  LSN {2}  |  BackupChainCheck {3:yyyy-MM-dd HH:mm}  |  @CleanupTime F/D/L {4}/{5}/{6}h  |  files F/D/L {7}/{8}/{9}  |  {10}' -f `
                $InstancePrefix, $scope, $LsnStatus, $Now, $ret[0], $ret[1], $ret[2], $fc['FULL'], $fc['DIFF'], $fc['LOG'], $tally)
    }

    return ('LSN {0}  |  BackupChainCheck {1:yyyy-MM-dd HH:mm}  |  {2}  |  @CleanupTime F/D/L {3}/{4}/{5}h  |  files F/D/L {6}/{7}/{8}  |  {9}' -f `
            $LsnStatus, $Now, $scope, $ret[0], $ret[1], $ret[2], $fc['FULL'], $fc['DIFF'], $fc['LOG'], $tally)
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
        Instance + Database + BackupType + Timestamp (to the second). Instance is
        part of the key so two servers running a same-named database on the same
        schedule do not merge into one logical backup in a multi-instance scan.
    #>
    param([object[]]$Record)

    $logical = New-Object System.Collections.Generic.List[object]
    $groups = $Record | Group-Object -Property {
        '{0}|{1}|{2}|{3:yyyyMMddHHmmss}' -f $_.Instance, $_.Database, $_.BackupType, $_.Timestamp
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
                SizeBytes  = [double](($g.Group | Measure-Object -Property LengthBytes -Sum).Sum)
                Paths      = @($g.Group.Path)
            })
    }
    return ($logical | Sort-Object Instance, Database, BackupType, Timestamp)
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

function Get-OlaJobSchedule {
    <#
        Reads the SQL Agent schedule(s) attached to each DatabaseBackup job and
        turns them into an intended cadence per (backup type, database scope).
        This is the schedule the README calls "how often each backup type is
        scheduled to run" - authoritative for what SHOULD be on disk, more so
        than inferring cadence from file spacing. Read-only.
    #>
    param(
        [string]$Instance,
        [System.Management.Automation.PSCredential]$Credential
    )

    $q = @"
SELECT j.name AS JobName, j.enabled AS JobEnabled, s.command AS Command,
       sch.name AS ScheduleName, sch.enabled AS ScheduleEnabled,
       sch.freq_type, sch.freq_interval, sch.freq_subday_type, sch.freq_subday_interval,
       sch.freq_recurrence_factor, sch.active_start_time,
       CASE WHEN js.next_run_date > 0
            THEN msdb.dbo.agent_datetime(js.next_run_date, js.next_run_time)
            ELSE NULL END AS NextRun
FROM msdb.dbo.sysjobsteps    AS s
JOIN msdb.dbo.sysjobs        AS j   ON j.job_id = s.job_id
JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules   AS sch ON sch.schedule_id = js.schedule_id
WHERE s.command LIKE '%DatabaseBackup%'
"@
    $rows = Invoke-SqlQuery -Instance $Instance -Database 'msdb' -Query $q -Credential $Credential

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows.Rows) {
        $cmd = [string]$row.Command
        $typeMatch = [regex]::Match($cmd, "@BackupType\s*=\s*N?'(?<v>FULL|DIFF|LOG)'", 'IgnoreCase')
        $dbMatch = [regex]::Match($cmd, "@Databases\s*=\s*N?'(?<v>[^']+)'", 'IgnoreCase')
        if (-not $typeMatch.Success) { continue }

        $sched = ConvertTo-ScheduleInterval `
            -FreqType ([int]$row.freq_type) `
            -FreqInterval ([int]$row.freq_interval) `
            -FreqSubdayType ([int]$row.freq_subday_type) `
            -FreqSubdayInterval ([int]$row.freq_subday_interval) `
            -FreqRecurrenceFactor ([int]$row.freq_recurrence_factor) `
            -ActiveStartTime ([int]$row.active_start_time)

        $out.Add([pscustomobject]@{
                JobName       = [string]$row.JobName
                JobEnabled    = ([int]$row.JobEnabled -eq 1)
                ScheduleName  = [string]$row.ScheduleName
                Enabled       = ([int]$row.ScheduleEnabled -eq 1)
                BackupType    = $typeMatch.Groups['v'].Value.ToUpperInvariant()
                Scope         = if ($dbMatch.Success) { $dbMatch.Groups['v'].Value } else { 'UNKNOWN' }
                IntervalHours = $sched.IntervalHours
                ScheduleText  = $sched.Text
                NextRun       = if ($row.NextRun -is [DBNull]) { $null } else { [datetime]$row.NextRun }
            })
    }
    return $out
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
    # Return an array (comma-wrapped so an empty result survives the pipeline as a
    # 0-count array rather than $null - that stays distinct from the "table not
    # present" case above, which returns $null explicitly). A List[object] pushed
    # through Write-Output -NoEnumerate trips an ETS binder bug ("Argument types
    # do not match") in the caller's @(...), so hand back a plain array.
    return , $log.ToArray()
}

function ConvertTo-LsnDecimal {
    <#
        backupset LSN columns are numeric(25,0); ADO.NET hands them back as
        [decimal], which holds 25 digits without loss. DBNull -> $null.
        Never cast an LSN to [double] - that rounds away the low-order digits
        the chain check compares.
    #>
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    return [decimal]$Value
}

function ConvertTo-NullableBool {
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $false }
    return [bool]$Value
}

function Group-BackupSetRow {
    <#
        Collapses the (backupset x backupmediafamily) rows returned by
        Get-BackupSetHistory into one record per logical backup (one
        backup_set_id), gathering its stripe device paths. Rows whose type is
        not D / I / L are skipped.

        Takes plain objects (not typed [System.Data.DataRow]) so the tests can
        pass lightweight stand-ins; only the msdb column names are read.
    #>
    param([object[]]$Row = @())

    $typeMap = @{ 'D' = 'FULL'; 'I' = 'DIFF'; 'L' = 'LOG' }
    $out = New-Object System.Collections.Generic.List[object]

    foreach ($g in ($Row | Group-Object -Property { [string]$_.backup_set_id })) {
        $r = $g.Group[0]
        $t = [string]$r.type
        if (-not $typeMap.ContainsKey($t)) { continue }

        $paths = @($g.Group |
            Where-Object { $null -ne $_.physical_device_name -and -not ($_.physical_device_name -is [System.DBNull]) } |
            ForEach-Object { [string]$_.physical_device_name } |
            Sort-Object -Unique)

        $start = [datetime]$r.backup_start_date
        $finish = if ($null -eq $r.backup_finish_date -or $r.backup_finish_date -is [System.DBNull]) {
            $start
        }
        else {
            [datetime]$r.backup_finish_date
        }

        # Throughput: backup_size (logical bytes processed) over the wall-clock run
        # time. $null unless we have a size and at least a 1-second duration.
        $backupSize = if ($null -eq $r.backup_size -or $r.backup_size -is [System.DBNull]) { $null } else { [decimal]$r.backup_size }
        $compressedSize = if ($null -eq $r.compressed_backup_size -or $r.compressed_backup_size -is [System.DBNull]) { $null } else { [decimal]$r.compressed_backup_size }
        $durationSeconds = [math]::Round(($finish - $start).TotalSeconds, 1)
        $speedMBps = $null
        if ($null -ne $backupSize -and $durationSeconds -ge 1) {
            $speedMBps = [math]::Round(([double]$backupSize / 1MB) / $durationSeconds, 1)
        }

        $out.Add([pscustomobject]@{
                Instance            = [string]$r.server_name
                Database            = [string]$r.database_name
                BackupType          = $typeMap[$t]
                Timestamp           = $start
                FinishTime          = $finish
                AgeHours            = [math]::Round(($script:Now - $start).TotalHours, 2)
                DurationSeconds     = $durationSeconds
                BackupSizeBytes     = $backupSize
                CompressedSizeBytes = $compressedSize
                SpeedMBps           = $speedMBps
                FirstLsn            = ConvertTo-LsnDecimal $r.first_lsn
                LastLsn             = ConvertTo-LsnDecimal $r.last_lsn
                CheckpointLsn       = ConvertTo-LsnDecimal $r.checkpoint_lsn
                DatabaseBackupLsn   = ConvertTo-LsnDecimal $r.database_backup_lsn
                DifferentialBaseLsn = ConvertTo-LsnDecimal $r.differential_base_lsn
                FirstForkGuid       = if ($null -eq $r.first_recovery_fork_guid -or $r.first_recovery_fork_guid -is [System.DBNull]) { $null } else { [string]$r.first_recovery_fork_guid }
                ForkGuid            = if ($null -eq $r.last_recovery_fork_guid -or $r.last_recovery_fork_guid -is [System.DBNull]) { $null } else { [string]$r.last_recovery_fork_guid }
                IsCopyOnly          = ConvertTo-NullableBool $r.is_copy_only
                IsDamaged           = ConvertTo-NullableBool $r.is_damaged
                HasChecksums        = ConvertTo-NullableBool $r.has_backup_checksums
                BeginsLogChain      = ConvertTo-NullableBool $r.begins_log_chain
                RecoveryModel       = [string]$r.recovery_model
                BackupSetId         = [int]$r.backup_set_id
                RunBy               = [string]$r.user_name
                Software            = if ($null -eq $r.software_name -or $r.software_name -is [System.DBNull]) { '' } else { [string]$r.software_name }
                DeviceCount         = $paths.Count
                DevicePaths         = $paths
            })
    }

    return ($out | Sort-Object Database, BackupType, Timestamp, BackupSetId)
}

function Get-BackupSetHistory {
    <#
        Reads msdb backup history (backupset + backupmediafamily + backupmediaset)
        for FULL / DIFF / LOG backups started within the last -SinceHours, and
        returns one record per logical backup with its LSN chain fields and
        stripe device paths. Read-only. Non-mirror media families only.
    #>
    param(
        [string]$Instance,
        [double]$SinceHours,
        [System.Management.Automation.PSCredential]$Credential
    )

    $hours = [int][math]::Ceiling($SinceHours)
    $q = @"
SELECT bs.backup_set_id, bs.database_name, bs.server_name, bs.type,
       bs.backup_start_date, bs.backup_finish_date,
       bs.backup_size, bs.compressed_backup_size,
       bs.first_lsn, bs.last_lsn, bs.checkpoint_lsn, bs.database_backup_lsn,
       bs.differential_base_lsn,
       bs.first_recovery_fork_guid, bs.last_recovery_fork_guid,
       bs.is_copy_only, bs.is_damaged, bs.has_backup_checksums, bs.begins_log_chain,
       bs.recovery_model, bs.user_name,
       ms.software_name,
       mf.physical_device_name, mf.family_sequence_number
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediaset AS ms ON ms.media_set_id = bs.media_set_id
JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
WHERE bs.type IN ('D', 'I', 'L')
  AND mf.mirror = 0
  AND bs.backup_start_date >= DATEADD(HOUR, -$hours, SYSDATETIME())
ORDER BY bs.database_name, bs.backup_start_date, bs.backup_set_id
"@
    $rows = Invoke-SqlQuery -Instance $Instance -Database 'msdb' -Query $q -Credential $Credential
    return Group-BackupSetRow -Row $rows.Rows
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
        NumberOfFiles; CleanupMode; ScheduleText; NextRun; Source } by layering,
        lowest precedence first: inferred interval (files) -> CommandLog cadence
        -> SQL Agent schedule -> config defaults -> SQL job config -> config
        per-db -> command-line overrides.
    #>
    param(
        [object[]]$LogicalBackup = @(),
        [object]$JobConfig,
        [object]$JobSchedule,
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
                ScheduleText  = $null
                NextRun       = $null
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

    # 1c. SQL Agent schedule - the intended cadence. Beats file/CommandLog
    #     inference; still loses to a config file, job-level or -parameter value.
    if ($JobSchedule -and $DatabaseInfo) {
        foreach ($sch in ($JobSchedule | Where-Object { $_.Enabled -and $_.JobEnabled -and $null -ne $_.IntervalHours })) {
            $targets = Expand-DatabaseScope -Scope $sch.Scope -DatabaseInfo $DatabaseInfo
            foreach ($db in $targets) {
                if (-not $model.ContainsKey($db)) { continue }
                $slot = $model[$db][$sch.BackupType]
                $slot.IntervalHours = $sch.IntervalHours
                $slot.ScheduleText = $sch.ScheduleText
                $slot.NextRun = $sch.NextRun
                $slot.Source += 'interval:schedule'
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
            if (-not $model.ContainsKey($db)) { $model[$db] = @{}; foreach ($t in $script:BackupTypes) { $model[$db][$t] = [ordered]@{ CleanupHours = $null; IntervalHours = $null; NumberOfFiles = 1; CleanupMode = 'AFTER_BACKUP'; ScheduleText = $null; NextRun = $null; Source = @() } } }
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
                                -Expected "<= $cleanup h old" -Found ("{0} file(s), oldest {1:yyyy-MM-dd HH:mm} ({2} h)" -f $stale.Count, $stale[0].Timestamp, [int]($stale[0].AgeHours)) `
                                -Detail ("Ola only deletes {0} files older than CleanupTime right after a SUCCESSFUL scheduled DatabaseBackup {0} run (CleanupMode={1}). So: the scheduled job has not run or not succeeded since, the backup was taken outside Ola (no cleanup), it is a COPY_ONLY file (never governed by @CleanupTime), a different @Directory, or cleanup has no delete permission." -f $type, $(if ($slot) { $slot.CleanupMode } else { 'AFTER_BACKUP' }))))
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

function Join-BackupSetToFile {
    <#
        Decides, for each msdb history record, whether its backup file is present
        among the on-disk logical backups. Match on device path first (same box),
        then on Database + BackupType + Timestamp within a few minutes (covers a
        moved / UNC path). Adds .OnDisk and .MatchedPath to each record in place
        and returns the collection.
    #>
    param(
        [object[]]$History = @(),
        [object[]]$LogicalBackup = @(),
        [double]$ToleranceMinutes = 3
    )

    $diskPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($lb in $LogicalBackup) {
        foreach ($p in @($lb.Paths)) {
            if ($p) { [void]$diskPaths.Add((([string]$p) -replace '/', '\')) }
        }
    }

    foreach ($h in $History) {
        $onDisk = $false
        $matched = $null

        foreach ($dp in @($h.DevicePaths)) {
            if (-not $dp) { continue }
            if ($diskPaths.Contains((([string]$dp) -replace '/', '\'))) { $onDisk = $true; $matched = $dp; break }
        }
        if (-not $onDisk) {
            foreach ($lb in $LogicalBackup) {
                if ($lb.Database -ne $h.Database -or $lb.BackupType -ne $h.BackupType) { continue }
                if ([math]::Abs(($lb.Timestamp - $h.Timestamp).TotalMinutes) -le $ToleranceMinutes) {
                    $onDisk = $true
                    $matched = @($lb.Paths)[0]
                    break
                }
            }
        }

        $h | Add-Member -NotePropertyName OnDisk -NotePropertyValue $onDisk -Force
        $h | Add-Member -NotePropertyName MatchedPath -NotePropertyValue $matched -Force
    }
    return $History
}

function Test-LsnChain {
    <#
        Validates LSN continuity of the LOG backup chain per database, from msdb
        history: each non-copy-only LOG backup's first_lsn must equal the previous
        one's last_lsn, on a single recovery fork. Also flags damaged backups,
        differentials whose base FULL is not in the history window, and - when
        -LogicalBackup is supplied - a hole in the on-disk chain (a LOG that msdb
        records, between the oldest and newest LOG that ARE on disk, whose own
        .trn file is gone) and a chain with no FULL backup file left on disk to
        restore first.

        Time gaps are NOT a chain break - a database can sit idle for days with an
        intact chain. That is what separates this from the file-spacing check in
        Test-BackupChain.

        Returns [pscustomobject]@{ Status = 'valid' | 'error' | 'n/a'; Findings }.
    #>
    param(
        [object[]]$History = @(),
        [object[]]$LogicalBackup = @(),
        [hashtable]$DatabaseInfo
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $checked = $false
    $instanceLabel = if ($History.Count -gt 0) { $History[0].Instance } else { '' }

    $checkDisk = $LogicalBackup.Count -gt 0
    if ($checkDisk) { $null = Join-BackupSetToFile -History $History -LogicalBackup $LogicalBackup }

    foreach ($grp in ($History | Group-Object Database)) {
        $db = $grp.Name
        $recs = @($grp.Group)

        foreach ($d in ($recs | Where-Object { $_.IsDamaged })) {
            $checked = $true
            $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType $d.BackupType -Severity 'Error' `
                        -Finding 'Backup is marked damaged in msdb (is_damaged = 1)' `
                        -Found ('{0:yyyy-MM-dd HH:mm}' -f $d.Timestamp) `
                        -Detail 'RESTORE would fail on this backup - the LSN chain cannot pass through it.'))
        }

        $logs = @($recs |
            Where-Object { $_.BackupType -eq 'LOG' -and -not $_.IsCopyOnly -and $null -ne $_.FirstLsn -and $null -ne $_.LastLsn } |
            Sort-Object FirstLsn)
        if ($logs.Count -ge 2) {
            $checked = $true
            $gapCount = 0
            $forkCount = 0
            $firstBreak = $null
            for ($i = 1; $i -lt $logs.Count; $i++) {
                $prev = $logs[$i - 1]
                $cur = $logs[$i]
                if ($prev.ForkGuid -and $cur.ForkGuid -and $prev.ForkGuid -ne $cur.ForkGuid) {
                    $forkCount++
                    if (-not $firstBreak) { $firstBreak = $prev }
                }
                elseif ($cur.FirstLsn -gt $prev.LastLsn) {
                    $gapCount++
                    if (-not $firstBreak) { $firstBreak = $prev }
                }
            }
            if ($gapCount -gt 0) {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'LOG' -Severity 'Error' `
                            -Finding ('LSN log chain is broken ({0} gap(s))' -f $gapCount) `
                            -Expected 'each LOG first_lsn = previous LOG last_lsn' `
                            -Found ('first break after {0:yyyy-MM-dd HH:mm}' -f $firstBreak.Timestamp) `
                            -Detail 'A LOG backup between two retained ones is missing from msdb (taken by another job/tool, or the database left and re-entered FULL recovery). Point-in-time recovery cannot cross the break.'))
            }
            if ($forkCount -gt 0) {
                $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'LOG' -Severity 'Error' `
                            -Finding ('LSN recovery fork changed mid-chain ({0}x)' -f $forkCount) `
                            -Found ('first change after {0:yyyy-MM-dd HH:mm}' -f $firstBreak.Timestamp) `
                            -Detail 'A RESTORE ... WITH RECOVERY or point-in-time restore happened on this database - backups from before the fork cannot roll forward past it.'))
            }
        }

        # A hole in the on-disk chain: a LOG that msdb records, sitting between the
        # oldest and newest LOG that ARE on disk, whose own file is gone. That is a
        # break you would only discover at restore time - the LSNs still line up.
        if ($checkDisk) {
            $diskLogs = @($logs | Where-Object { $_.OnDisk } | Sort-Object Timestamp)
            if ($diskLogs.Count -ge 1) {
                $lo = $diskLogs[0].Timestamp
                $hi = $diskLogs[$diskLogs.Count - 1].Timestamp
                $holes = @($logs | Where-Object { -not $_.OnDisk -and $_.Timestamp -ge $lo -and $_.Timestamp -le $hi } | Sort-Object Timestamp)
                if ($holes.Count -gt 0) {
                    $checked = $true
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'LOG' -Severity 'Error' `
                                -Finding ('Restore chain has a hole - {0} LOG file(s) inside the on-disk chain are missing from disk' -f $holes.Count) `
                                -Expected 'every LOG between the oldest and newest on-disk LOG still on disk' `
                                -Found ('e.g. {0:yyyy-MM-dd HH:mm} recorded in msdb, file not found' -f $holes[0].Timestamp) `
                                -Detail 'The LSN chain is intact in msdb but the .trn file is gone (deleted, or aged off while surrounding logs were kept). Point-in-time recovery cannot cross the hole - you can only roll forward to the last LOG whose file exists before it.'))
                }
            }
        }

        # An intact LSN chain is only worth anything if it can be restored, and a
        # restore starts by restoring a FULL. If this database has a LOG or DIFF
        # chain in the window but no FULL backup FILE on disk, the chain has no
        # base - nothing rolls forward - so the verdict is 'error', not 'valid'.
        if ($checkDisk) {
            $hasChain = $logs.Count -ge 1 -or @($recs | Where-Object { $_.BackupType -eq 'DIFF' -and -not $_.IsCopyOnly }).Count -gt 0
            if ($hasChain) {
                $fullOnDisk = @($LogicalBackup | Where-Object { $_.Database -eq $db -and $_.BackupType -eq 'FULL' -and -not $_.IsCopyOnly })
                if ($fullOnDisk.Count -eq 0) {
                    $checked = $true
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'FULL' -Severity 'Error' `
                                -Finding 'No FULL backup on disk - the log/diff chain has no base to restore' `
                                -Expected 'at least one FULL backup file on disk' `
                                -Found '0 FULL file(s)' `
                                -Detail 'msdb records a continuous LSN chain, but every FULL backup file is gone from the scanned path(s). A point-in-time restore begins by restoring a FULL; without one the DIFF / LOG backups cannot be applied to anything.'))
                }
            }
        }

        $fulls = @($recs | Where-Object { $_.BackupType -eq 'FULL' -and -not $_.IsCopyOnly -and $null -ne $_.FirstLsn })
        if ($fulls.Count -gt 0) {
            foreach ($diff in ($recs | Where-Object { $_.BackupType -eq 'DIFF' -and -not $_.IsCopyOnly -and $null -ne $_.DifferentialBaseLsn })) {
                $checked = $true
                $baseFound = $false
                foreach ($f in $fulls) { if ($f.FirstLsn -eq $diff.DifferentialBaseLsn) { $baseFound = $true; break } }
                if (-not $baseFound) {
                    $findings.Add((New-Finding -Instance $instanceLabel -Database $db -BackupType 'DIFF' -Severity 'Warning' `
                                -Finding 'DIFF base FULL is not in the history window' `
                                -Found ('DIFF {0:yyyy-MM-dd HH:mm}' -f $diff.Timestamp) `
                                -Detail 'The full this differential is based on is older than -HistoryHours or is gone. The DIFF only restores if that base full still exists.'))
                }
            }
        }
    }

    $status = if (-not $checked) { 'n/a' }
    elseif (@($findings | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0) { 'error' }
    else { 'valid' }

    return [pscustomobject]@{ Status = $status; Findings = $findings.ToArray() }
}

function Get-RestorePlan {
    <#
        Builds, per database, the shortest sequence of backup FILES ON DISK that
        forms a valid LSN chain to the latest recoverable point: the newest FULL
        on disk, then the newest DIFF on disk whose differential_base_lsn matches
        that FULL, then every contiguous LOG on disk from there to the newest.

        Needs msdb history (the LSNs live there, not in the file names) annotated
        with .OnDisk / .MatchedPath by Join-BackupSetToFile. Pure - reads nothing.

        Emits one BackupChainCheck.RestorePlan per database, each carrying a
        .Steps array of BackupChainCheck.RestoreStep records (Order, BackupType,
        Timestamp, Path, Paths, FirstLsn, LastLsn) and a .RestoreScript string of
        the T-SQL RESTORE statements. RecoverableTo is the finish time of the
        last step; Complete is $true when the plan reaches the newest backup on
        disk.
    #>
    param(
        [object[]]$History = @(),
        [datetime]$Now = $script:Now
    )

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($grp in ($History | Group-Object Database)) {
        $db = $grp.Name
        $recs = @($grp.Group | Where-Object { -not $_.IsCopyOnly })
        $instance = if ($recs.Count -gt 0) { $recs[0].Instance } else { '' }

        # The file(s) to RESTORE FROM: msdb's recorded device paths (covers a
        # striped backup's members), unless the match said the file moved, in
        # which case the on-disk MatchedPath is all we can trust.
        $pathsOf = {
            param($r)
            $dp = @(@($r.DevicePaths) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $mp = if ($r.PSObject.Properties['MatchedPath'] -and $r.MatchedPath) { [string]$r.MatchedPath } else { $null }
            if ($mp -and ($dp -notcontains $mp)) { return @($mp) }
            if ($dp.Count -gt 0) { return $dp }
            if ($mp) { return @($mp) }
            return @()
        }
        $pathOf = { param($r) $p = @(& $pathsOf $r); if ($p.Count -gt 0) { $p[0] } else { '' } }

        $onDiskAll = @($recs | Where-Object { $_.PSObject.Properties['OnDisk'] -and $_.OnDisk })
        $newestOnDisk = if ($onDiskAll.Count -gt 0) { @($onDiskAll | Sort-Object Timestamp)[-1] } else { $null }

        $fulls = @($onDiskAll | Where-Object { $_.BackupType -eq 'FULL' -and $null -ne $_.FirstLsn } | Sort-Object Timestamp)
        if ($fulls.Count -eq 0) {
            $out.Add([pscustomobject]@{
                    PSTypeName    = 'BackupChainCheck.RestorePlan'
                    Instance      = $instance
                    Database      = $db
                    Complete      = $false
                    RecoverableTo = $null
                    StepCount     = 0
                    Steps         = @()
                    RestoreScript = ''
                    Reason        = 'No FULL backup file on disk - nothing to restore from.'
                })
            continue
        }

        $base = $fulls[-1]
        $steps = New-Object System.Collections.Generic.List[object]
        $order = 1
        $steps.Add([pscustomobject]@{
                PSTypeName = 'BackupChainCheck.RestoreStep'
                Order      = $order; Database = $db; BackupType = 'FULL'
                Timestamp  = $base.Timestamp; FinishTime = $base.FinishTime
                FirstLsn   = $base.FirstLsn; LastLsn = $base.LastLsn
                Path       = (& $pathOf $base); Paths = (& $pathsOf $base)
            })

        $anchor = $base.LastLsn
        $anchorFork = $base.ForkGuid

        $diffs = @($onDiskAll |
            Where-Object { $_.BackupType -eq 'DIFF' -and $null -ne $_.DifferentialBaseLsn -and $_.DifferentialBaseLsn -eq $base.FirstLsn } |
            Sort-Object Timestamp)
        if ($diffs.Count -gt 0) {
            $diff = $diffs[-1]
            $order++
            $steps.Add([pscustomobject]@{
                    PSTypeName = 'BackupChainCheck.RestoreStep'
                    Order      = $order; Database = $db; BackupType = 'DIFF'
                    Timestamp  = $diff.Timestamp; FinishTime = $diff.FinishTime
                    FirstLsn   = $diff.FirstLsn; LastLsn = $diff.LastLsn
                    Path       = (& $pathOf $diff); Paths = (& $pathsOf $diff)
                })
            if ($null -ne $diff.LastLsn) { $anchor = $diff.LastLsn }
            if ($diff.ForkGuid) { $anchorFork = $diff.ForkGuid }
        }

        # LOG chain: start at the first on-disk LOG that carries the anchor LSN
        # forward, then walk contiguous (first_lsn = previous last_lsn, same fork,
        # file present) to the newest.
        $logsAll = @($recs | Where-Object { $_.BackupType -eq 'LOG' -and $null -ne $_.FirstLsn -and $null -ne $_.LastLsn } | Sort-Object FirstLsn)
        $newestLog = if ($logsAll.Count -gt 0) { @($logsAll | Sort-Object Timestamp)[-1] } else { $null }

        $chainBroke = $false
        $missingNext = $null
        if ($null -ne $anchor) {
            $cursor = $anchor
            $curFork = $anchorFork
            while ($true) {
                $next = $null
                foreach ($l in $logsAll) {
                    if ($l.FirstLsn -le $cursor -and $l.LastLsn -gt $cursor) { $next = $l; break }
                }
                if ($null -eq $next) { break }   # nothing extends the chain - we are current
                if (-not ($next.PSObject.Properties['OnDisk'] -and $next.OnDisk)) {
                    $chainBroke = $true
                    $missingNext = $next
                    break
                }
                if ($curFork -and $next.ForkGuid -and $curFork -ne $next.ForkGuid) { $chainBroke = $true; break }
                $order++
                $steps.Add([pscustomobject]@{
                        PSTypeName = 'BackupChainCheck.RestoreStep'
                        Order      = $order; Database = $db; BackupType = 'LOG'
                        Timestamp  = $next.Timestamp; FinishTime = $next.FinishTime
                        FirstLsn   = $next.FirstLsn; LastLsn = $next.LastLsn
                        Path       = (& $pathOf $next); Paths = (& $pathsOf $next)
                    })
                $cursor = $next.LastLsn
                if ($next.ForkGuid) { $curFork = $next.ForkGuid }
            }
        }

        $last = $steps[$steps.Count - 1]
        $complete = -not $chainBroke -and (
            $null -eq $newestOnDisk -or
            ($last.Timestamp -ge $newestOnDisk.Timestamp) -or
            ($null -ne $newestLog -and $last.BackupType -eq 'LOG' -and $last.Timestamp -ge $newestLog.Timestamp)
        )

        $reason = if ($chainBroke -and $missingNext) {
            'LOG chain stops - next log ({0}) is recorded in msdb but its file is gone.' -f (Split-Path -Path (& $pathOf $missingNext) -Leaf)
        }
        elseif ($chainBroke) { 'LOG chain stops - a recovery-fork change or gap on disk.' }
        elseif (-not $complete) { 'Plan is valid but a newer backup on disk was not reachable from this chain.' }
        else { '' }

        # T-SQL: every restore NORECOVERY, then a trailing WITH RECOVERY when the
        # chain is complete. Paths on a different server may need WITH MOVE.
        $dbEsc = $db -replace ']', ']]'
        $sql = New-Object System.Collections.Generic.List[string]
        $sql.Add(('-- {0}  ->  recoverable to {1:yyyy-MM-dd HH:mm:ss}{2}' -f $db, $last.FinishTime, $(if ($complete) { '' } else { '  (chain incomplete)' })))
        foreach ($s in $steps) {
            $verb = if ($s.BackupType -eq 'LOG') { 'RESTORE LOG' } else { 'RESTORE DATABASE' }
            $disks = @(@($s.Paths) | ForEach-Object { "DISK = N'{0}'" -f ($_ -replace "'", "''") }) -join ', '
            $sql.Add(('{0} [{1}] FROM {2} WITH NORECOVERY;' -f $verb, $dbEsc, $disks))
        }
        if ($complete) { $sql.Add(('RESTORE DATABASE [{0}] WITH RECOVERY;' -f $dbEsc)) }
        else { $sql.Add('-- chain incomplete - stay NORECOVERY and add the missing backups, or RESTORE DATABASE [...] WITH RECOVERY to stop here.') }

        $out.Add([pscustomobject]@{
                PSTypeName    = 'BackupChainCheck.RestorePlan'
                Instance      = $instance
                Database      = $db
                Complete      = [bool]$complete
                RecoverableTo = $last.FinishTime
                StepCount     = $steps.Count
                Steps         = $steps.ToArray()
                RestoreScript = ($sql -join [Environment]::NewLine)
                Reason        = $reason
            })
    }

    return $out
}

function Write-RestorePlan {
    param([object[]]$Plan = @())

    Write-Host ''
    Write-Host 'Restore chain on disk  (-RestorePlan)'
    if (-not $Plan -or $Plan.Count -eq 0) {
        Write-Host '  Nothing to plan - no msdb history for the scoped database(s).'
        return
    }

    foreach ($p in $Plan) {
        Write-Host ''
        Write-Host ("{0}" -f $p.Database) -ForegroundColor Cyan
        if ($p.StepCount -eq 0) {
            Write-Host "  $($p.Reason)" -ForegroundColor Red
            continue
        }
        foreach ($s in $p.Steps) {
            Write-Host ('  {0,2}. {1,-4} {2:yyyy-MM-dd HH:mm:ss}  {3}' -f $s.Order, $s.BackupType, $s.Timestamp, (Split-Path -Path $s.Path -Leaf))
        }
        $tag = if ($p.Complete) { 'current' } else { 'PARTIAL' }
        $color = if ($p.Complete) { 'Green' } else { 'DarkYellow' }
        Write-Host ('  -> {0} step(s), recoverable to {1:yyyy-MM-dd HH:mm:ss}  [{2}]' -f $p.StepCount, $p.RecoverableTo, $tag) -ForegroundColor $color
        if ($p.Reason) { Write-Host "     $($p.Reason)" -ForegroundColor DarkYellow }
        if ($p.RestoreScript) {
            Write-Host ''
            foreach ($line in ($p.RestoreScript -split "`r?`n")) { Write-Host "    $line" -ForegroundColor DarkGray }
        }
    }
}

function Get-BackupPrediction {
    <#
        For every (database, backup type) in $Model with a known retention and
        interval, projects the backups that SHOULD be on disk now: one slot every
        IntervalHours, walking back from the current schedule phase to age
        CleanupHours + IntervalHours (the same window Test-BackupChain treats as
        "still retained"). Each slot is matched to an actual backup within half an
        interval. Emits one BackupChainCheck.Prediction record per (database,
        type), carrying a .Slots array. Pure projection - reads nothing.
    #>
    param(
        [object[]]$LogicalBackup = @(),
        [hashtable]$Model,
        [object[]]$History = @(),
        [double]$ToleranceFactor = 1.5,
        [datetime]$Now = $script:Now
    )

    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Model) { return $out }

    $byKey = @{}
    foreach ($lb in ($LogicalBackup | Where-Object { -not $_.IsCopyOnly })) {
        $k = '{0}|{1}' -f $lb.Database, $lb.BackupType
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = New-Object System.Collections.Generic.List[object] }
        $byKey[$k].Add($lb)
    }

    # Median write throughput per (database, type) from msdb history - the backups
    # that recorded a size and a run time long enough to divide by.
    $speedByKey = @{}
    foreach ($h in ($History | Where-Object { $_.BackupType -and $null -ne $_.SpeedMBps })) {
        $k = '{0}|{1}' -f $h.Database, $h.BackupType
        if (-not $speedByKey.ContainsKey($k)) { $speedByKey[$k] = New-Object System.Collections.Generic.List[double] }
        $speedByKey[$k].Add([double]$h.SpeedMBps)
    }

    foreach ($db in ($Model.Keys | Sort-Object)) {
        foreach ($type in $script:BackupTypes) {
            $slot = $Model[$db][$type]

            $actuals = @()
            if ($byKey.ContainsKey("$db|$type")) { $actuals = @($byKey["$db|$type"] | Sort-Object Timestamp) }
            $instance = if ($actuals.Count -gt 0) { $actuals[0].Instance } else { '' }

            $cleanup = $slot.CleanupHours
            $interval = $slot.IntervalHours
            $stripes = if ($slot.NumberOfFiles -and $slot.NumberOfFiles -gt 1) { [int]$slot.NumberOfFiles } else { 1 }

            $intervalSource = ''
            foreach ($src in @($slot.Source)) { if ($src -like 'interval:*') { $intervalSource = $src.Substring(9) } }

            $speedMBps = $null
            if ($speedByKey.ContainsKey("$db|$type")) {
                $speedMBps = Get-Median -Value ([double[]]$speedByKey["$db|$type"])
                if ($null -ne $speedMBps) { $speedMBps = [math]::Round($speedMBps, 1) }
            }

            if ($null -eq $cleanup -or $null -eq $interval -or $interval -le 0) {
                $out.Add([pscustomobject]@{
                        PSTypeName       = 'BackupChainCheck.Prediction'
                        Instance         = $instance
                        Database         = $db
                        BackupType       = $type
                        Predictable      = $false
                        IntervalHours    = $interval
                        IntervalSource   = $intervalSource
                        CleanupHours     = $cleanup
                        CleanupMode      = $slot.CleanupMode
                        Schedule         = $slot.ScheduleText
                        NextScheduledRun = $slot.NextRun
                        SpeedMBps        = $speedMBps
                        Stripes          = $stripes
                        ExpectedCount    = $null
                        PresentCount     = $actuals.Count
                        PartialCount     = 0
                        MissingCount     = $null
                        OffScheduleCount = 0
                        NewestExpected   = $null
                        OldestExpected   = $null
                        MissingSlots     = @()
                        OffScheduleTimes = @()
                        Slots            = @()
                        Reason           = if ($actuals.Count -eq 0) { 'no retention/interval known and no files present' } else { 'retention or interval unknown - supply -SqlInstance, -ConfigPath or -*IntervalHours' }
                    })
                continue
            }

            $horizon = $cleanup + $interval
            $tol = $interval / 2.0

            # Schedule phase for the slot grid: prefer the job's next scheduled run
            # (walk it back to the newest slot at or before now); otherwise fall
            # back to the newest actual backup, else now.
            if ($slot.NextRun) {
                $anchor = $slot.NextRun
                while ($anchor -gt $Now) { $anchor = $anchor.AddHours(-$interval) }
            }
            else {
                $anchor = if ($actuals.Count -gt 0) { $actuals[$actuals.Count - 1].Timestamp } else { $Now }
                while ($anchor.AddHours($interval) -le $Now) { $anchor = $anchor.AddHours($interval) }
            }

            # Match each slot to the closest not-yet-claimed actual within half an
            # interval, walking newest slot first.
            $used = New-Object System.Collections.Generic.HashSet[int]
            $slots = New-Object System.Collections.Generic.List[object]
            $t = $anchor
            $idx = 0
            while ((($Now - $t).TotalHours) -le $horizon) {
                $idx++
                $bestI = -1
                $bestDiff = [double]::MaxValue
                for ($ai = 0; $ai -lt $actuals.Count; $ai++) {
                    if ($used.Contains($ai)) { continue }
                    $diff = [math]::Abs((($actuals[$ai].Timestamp) - $t).TotalHours)
                    if ($diff -le $tol -and $diff -lt $bestDiff) { $bestDiff = $diff; $bestI = $ai }
                }

                $status = 'missing'
                $fileCount = 0
                $actualTime = $null
                if ($bestI -ge 0) {
                    [void]$used.Add($bestI)
                    $m = $actuals[$bestI]
                    $fileCount = [int]$m.FileCount
                    $actualTime = $m.Timestamp
                    $status = if ($fileCount -lt $stripes) { 'partial' } else { 'present' }
                }
                $slots.Add([pscustomobject]@{
                        Index     = $idx
                        Expected  = $t
                        AgeHours  = [math]::Round(($Now - $t).TotalHours, 2)
                        Status    = $status
                        FileCount = $fileCount
                        Actual    = $actualTime
                    })
                $t = $t.AddHours(-$interval)
                if ($idx -ge 100000) { break }   # guard against an absurd Cleanup/Interval ratio
            }

            $slotsArr = @($slots | Sort-Object Expected -Descending)

            $presentCount = 0
            $partialCount = 0
            $missingSlots = New-Object System.Collections.Generic.List[datetime]
            foreach ($s in $slotsArr) {
                switch ($s.Status) {
                    'present' { $presentCount++ }
                    'partial' { $partialCount++ }
                    'missing' { $missingSlots.Add($s.Expected) }
                }
            }

            # Actuals inside the retention window that no slot claimed = off-schedule extras.
            $offSchedule = New-Object System.Collections.Generic.List[datetime]
            for ($ai = 0; $ai -lt $actuals.Count; $ai++) {
                if ($used.Contains($ai)) { continue }
                if ((($Now - $actuals[$ai].Timestamp).TotalHours) -gt $horizon) { continue }
                $offSchedule.Add($actuals[$ai].Timestamp)
            }

            $out.Add([pscustomobject]@{
                    PSTypeName       = 'BackupChainCheck.Prediction'
                    Instance         = $instance
                    Database         = $db
                    BackupType       = $type
                    Predictable      = $true
                    IntervalHours    = $interval
                    IntervalSource   = $intervalSource
                    CleanupHours     = $cleanup
                    CleanupMode      = $slot.CleanupMode
                    Schedule         = $slot.ScheduleText
                    NextScheduledRun = $slot.NextRun
                    SpeedMBps        = $speedMBps
                    Stripes          = $stripes
                    ExpectedCount    = $slotsArr.Count
                    PresentCount     = $presentCount
                    PartialCount     = $partialCount
                    MissingCount     = $missingSlots.Count
                    OffScheduleCount = $offSchedule.Count
                    NewestExpected   = if ($slotsArr.Count -gt 0) { $slotsArr[0].Expected } else { $null }
                    OldestExpected   = if ($slotsArr.Count -gt 0) { $slotsArr[$slotsArr.Count - 1].Expected } else { $null }
                    MissingSlots     = $missingSlots.ToArray()
                    OffScheduleTimes = $offSchedule.ToArray()
                    Slots            = $slotsArr
                    Reason           = ''
                })
        }
    }
    return $out
}

function Write-PredictionMatrix {
    param(
        [object[]]$Prediction = @(),
        [object[]]$LogicalBackup = @()
    )

    if (-not $Prediction -or $Prediction.Count -eq 0) {
        Write-Host 'No predictions - no database in scope has a known retention and interval.'
        return
    }

    $cell = {
        param($p)
        if (-not $p) { return '.' }
        if (-not $p.Predictable) { return '?' }
        $s = '{0}/{1}' -f $p.PresentCount, $p.ExpectedCount
        if ($p.PartialCount -gt 0) { $s += ' +{0}p' -f $p.PartialCount }
        return $s
    }

    # Total size on disk of every (non-copy-only) backup file the scan saw, per
    # database - FULL + DIFF + LOG together.
    $sizeByDb = @{}
    foreach ($lb in ($LogicalBackup | Where-Object { -not $_.IsCopyOnly })) {
        if (-not $sizeByDb.ContainsKey($lb.Database)) { $sizeByDb[$lb.Database] = 0.0 }
        $sizeByDb[$lb.Database] += [double]$lb.SizeBytes
    }

    $rows = foreach ($db in ($Prediction | ForEach-Object { $_.Database } | Sort-Object -Unique)) {
        $f = $Prediction | Where-Object { $_.Database -eq $db -and $_.BackupType -eq 'FULL' } | Select-Object -First 1
        $d = $Prediction | Where-Object { $_.Database -eq $db -and $_.BackupType -eq 'DIFF' } | Select-Object -First 1
        $l = $Prediction | Where-Object { $_.Database -eq $db -and $_.BackupType -eq 'LOG' } | Select-Object -First 1
        [pscustomobject]@{
            Database = $db
            Size     = if ($sizeByDb.ContainsKey($db)) { Get-DataSizeText $sizeByDb[$db] } else { '-' }
            FULL     = & $cell $f
            DIFF     = & $cell $d
            LOG      = & $cell $l
        }
    }

    Write-Host ''
    Write-Host 'Predicted backups on disk now  -  present / expected   (-Predict)'
    $rows | Format-Table -AutoSize | Out-Host
    Write-Host '  Size     = total on disk of all FULL + DIFF + LOG files for the database'
    Write-Host '  expected = floor(Cleanup / Interval) + 1 slots inside the retention window'
    Write-Host '  present  = projected slot has a matching file      ? = retention or interval unknown'
    Write-Host '  +Np      = N slots present but missing stripe members       . = backup type not in use'
    Write-Host ''

    $ordered = $Prediction |
        Where-Object { $_.Predictable -and ($_.MissingCount -gt 0 -or $_.PartialCount -gt 0 -or $_.OffScheduleCount -gt 0) } |
        Sort-Object Database, @{ E = { [array]::IndexOf($script:BackupTypes, $_.BackupType) } }

    foreach ($p in $ordered) {
        $cadence = if ($p.Schedule) { "schedule: $($p.Schedule)" } elseif ($p.IntervalSource) { "source: $($p.IntervalSource)" } else { 'source: inferred' }
        $speedText = if ($null -ne $p.SpeedMBps) { ', ~{0:N1} MB/s' -f $p.SpeedMBps } else { '' }
        Write-Host ('{0} / {1}  -  interval {2} ({3}), retention {4} ({5}), {6} file(s)/backup{7}' -f `
                $p.Database, $p.BackupType, (Get-DurationText $p.IntervalHours), $cadence, (Get-DurationText $p.CleanupHours), $p.CleanupMode, $p.Stripes, $speedText)
        Write-Host ('   expected {0}, present {1}, partial {2}, missing {3}, off-schedule {4}' -f `
                $p.ExpectedCount, $p.PresentCount, $p.PartialCount, $p.MissingCount, $p.OffScheduleCount)
        if ($p.NextScheduledRun) {
            Write-Host ('   next scheduled run: {0:yyyy-MM-dd HH:mm}' -f $p.NextScheduledRun)
        }
        if ($p.MissingCount -gt 0) {
            $show = @($p.MissingSlots | Select-Object -First 12 | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm') })
            $more = $p.MissingCount - $show.Count
            $line = '   missing slots: ' + ($show -join ', ')
            if ($more -gt 0) { $line += " (+$more more)" }
            Write-Host $line
        }
        if ($p.OffScheduleCount -gt 0) {
            $show = @($p.OffScheduleTimes | Select-Object -First 6 | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm') })
            Write-Host ('   off-schedule files: ' + ($show -join ', '))
        }
        Write-Host ''
    }
}

function Get-BackupAdvice {
    <#
        Plain-language advice about the retention / cadence design, grouped so an
        ALL_DATABASES job is stated once, plus an approximate figure for backup
        files on disk that are past @CleanupTime or have no restore base.
        Returns [string[]] - printed at the top of the output under -Advice.
    #>
    param(
        [hashtable]$Model,
        [object[]]$LogicalBackup = @(),
        [hashtable]$DatabaseInfo
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not $Model -or $Model.Keys.Count -eq 0) { return $lines.ToArray() }

    $sigGroups = @{}
    foreach ($db in $Model.Keys) {
        $f = $Model[$db]['FULL']; $d = $Model[$db]['DIFF']; $l = $Model[$db]['LOG']
        $sig = '{0}|{1}|{2}|{3}|{4}|{5}' -f $f.CleanupHours, $f.IntervalHours, $d.CleanupHours, $d.IntervalHours, $l.CleanupHours, $l.IntervalHours
        if (-not $sigGroups.ContainsKey($sig)) { $sigGroups[$sig] = New-Object System.Collections.Generic.List[string] }
        $sigGroups[$sig].Add($db)
    }
    $totalDbs = $Model.Keys.Count

    foreach ($sig in $sigGroups.Keys) {
        $dbs = @($sigGroups[$sig] | Sort-Object)
        $f = $Model[$dbs[0]]['FULL']; $d = $Model[$dbs[0]]['DIFF']; $l = $Model[$dbs[0]]['LOG']
        $scope = if ($dbs.Count -eq 1) { $dbs[0] }
        elseif ($dbs.Count -eq $totalDbs) { "All $($dbs.Count) databases" }
        else { "$($dbs.Count) databases (e.g. $($dbs[0]))" }

        $fDaily = $f.IntervalHours -and $f.IntervalHours -ge 12 -and $f.IntervalHours -le 30
        $g = New-Object System.Collections.Generic.List[string]

        if ($null -ne $d.CleanupHours -and $null -ne $f.CleanupHours -and $d.CleanupHours -gt $f.CleanupHours) {
            $g.Add(("DIFF is kept {0} but FULL only {1}. A differential restores only on its base FULL, so DIFFs older than {1} have no base on disk and cannot be restored{2}. Set DIFF @CleanupTime to {1} to match FULL." -f `
                    (Get-DurationText $d.CleanupHours), (Get-DurationText $f.CleanupHours), $(if ($fDaily) { ' - and with a daily FULL you barely need DIFFs at all' } else { '' })))
        }

        if ($null -ne $l.CleanupHours -and $null -ne $f.CleanupHours -and $l.CleanupHours -lt $f.CleanupHours) {
            $g.Add(("LOG is kept {0}, shorter than FULL's {1}. Continuous point-in-time restore only reaches back {0}; the oldest ~{2} of FULL backups cannot be rolled forward. Match LOG @CleanupTime to {1}." -f `
                    (Get-DurationText $l.CleanupHours), (Get-DurationText $f.CleanupHours), (Get-DurationText ($f.CleanupHours - $l.CleanupHours))))
        }

        foreach ($t in $script:BackupTypes) {
            $s = $Model[$dbs[0]][$t]
            if ($null -ne $s.CleanupHours -and $s.IntervalHours -and $s.IntervalHours -gt 0 -and $s.CleanupHours -lt $s.IntervalHours) {
                $g.Add(("{0} @CleanupTime ({1}) is below the {2} run cadence - one failed run can leave zero {0} backups." -f `
                            $t, (Get-DurationText $s.CleanupHours), (Get-DurationText $s.IntervalHours)))
            }
        }

        if ($null -ne $f.CleanupHours -and $f.IntervalHours -and $f.IntervalHours -gt 30) {
            $kept = [math]::Floor($f.CleanupHours / $f.IntervalHours) + 1
            if ($kept -le 2) {
                $g.Add(("FULL runs every {0} and is kept {1} - only ~{2} full copies ever exist. One corrupt full and your fallback is {0} or more of log replay. Raise FULL @CleanupTime (e.g. to {3})." -f `
                            (Get-DurationText $f.IntervalHours), (Get-DurationText $f.CleanupHours), $kept, (Get-DurationText ($f.IntervalHours * 3))))
            }
        }

        if ($g.Count -gt 0) {
            $lines.Add("${scope}:")
            foreach ($x in $g) { $lines.Add("  - $x") }
        }
    }

    # Approximate wasted / unusable space: files past their retention window, plus
    # differentials with no base FULL on disk. Each file counted once.
    $wastedBytes = 0.0
    $wastedFiles = 0
    $counted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($lb in ($LogicalBackup | Where-Object { -not $_.IsCopyOnly })) {
        $key = if (@($lb.Paths).Count -gt 0) { [string]@($lb.Paths)[0] } else { '{0}|{1}|{2}' -f $lb.Database, $lb.BackupType, $lb.Timestamp }
        $wasted = $false

        $slot = if ($Model.ContainsKey($lb.Database)) { $Model[$lb.Database][$lb.BackupType] } else { $null }
        if ($slot -and $null -ne $slot.CleanupHours) {
            $limit = $slot.CleanupHours + $(if ($slot.IntervalHours) { $slot.IntervalHours } else { 0 })
            if ($lb.AgeHours -gt $limit) { $wasted = $true }
        }

        if (-not $wasted -and $lb.BackupType -eq 'DIFF') {
            $base = @($LogicalBackup | Where-Object {
                    $_.Database -eq $lb.Database -and $_.BackupType -eq 'FULL' -and -not $_.IsCopyOnly -and $_.Timestamp -le $lb.Timestamp
                })
            if ($base.Count -eq 0) { $wasted = $true }
        }

        if ($wasted -and $counted.Add($key)) {
            $sz = if ($lb.PSObject.Properties['SizeBytes'] -and $lb.SizeBytes) { [double]$lb.SizeBytes } else { 0 }
            $wastedBytes += $sz
            $wastedFiles += $lb.FileCount
        }
    }

    if ($wastedFiles -gt 0) {
        $lines.Add('')
        $lines.Add(("~{0} in {1} backup file(s) on disk is past @CleanupTime or has no restore base - mostly cleanup not running (failed / stopped jobs) or orphaned differentials. A healthy schedule rolls this off automatically." -f `
                (Get-DataSizeText $wastedBytes), $wastedFiles))
    }

    return $lines.ToArray()
}

function Write-ChainGraph {
    <#
        ASCII timeline of each database's backup chain, one row per (database,
        type): 'o' for a backup present, 'X' for one recorded in msdb whose file
        is gone, and inline gap markers - ~~[dur]~~ for an idle stretch,
        //gap// for an LSN break, //fork// for a recovery-fork change. Uses msdb
        history (with on-disk status) when available, otherwise the files alone.
    #>
    param(
        [object[]]$History = @(),
        [object[]]$LogicalBackup = @(),
        [hashtable]$Model,
        [datetime]$Now = $script:Now,
        [double]$ToleranceFactor = 1.5
    )

    $histByDb = @{}
    foreach ($h in $History) {
        if (-not $histByDb.ContainsKey($h.Database)) { $histByDb[$h.Database] = New-Object System.Collections.Generic.List[object] }
        $histByDb[$h.Database].Add($h)
    }
    $fileByDb = @{}
    foreach ($lb in $LogicalBackup) {
        if (-not $fileByDb.ContainsKey($lb.Database)) { $fileByDb[$lb.Database] = New-Object System.Collections.Generic.List[object] }
        $fileByDb[$lb.Database].Add($lb)
    }

    $dbs = @(@($histByDb.Keys) + @($fileByDb.Keys) | Sort-Object -Unique)
    if ($dbs.Count -eq 0) { Write-Host 'No backups to graph.'; return }

    Write-Host ''
    Write-Host 'Backup chain timeline  (-Graph)'
    Write-Host "  | backup present   X recorded in msdb, file missing   ~~[d]~~ idle gap   //gap// LSN break   //fork// recovery fork"

    foreach ($db in $dbs) {
        Write-Host ''
        Write-Host $db
        foreach ($type in $script:BackupTypes) {
            $usingHistory = $histByDb.ContainsKey($db) -and @($histByDb[$db] | Where-Object { $_.BackupType -eq $type -and -not $_.IsCopyOnly }).Count -gt 0
            if ($usingHistory) {
                $chain = @($histByDb[$db] | Where-Object { $_.BackupType -eq $type -and -not $_.IsCopyOnly } | Sort-Object Timestamp)
            }
            elseif ($fileByDb.ContainsKey($db)) {
                $chain = @($fileByDb[$db] | Where-Object { $_.BackupType -eq $type -and -not $_.IsCopyOnly } | Sort-Object Timestamp)
            }
            else { $chain = @() }
            if ($chain.Count -eq 0) { continue }

            $interval = $null
            $cleanup = $null
            if ($Model -and $Model.ContainsKey($db)) {
                $interval = $Model[$db][$type].IntervalHours
                $cleanup = $Model[$db][$type].CleanupHours
            }
            $gapH = if ($interval -and $interval -gt 0) { $interval * $ToleranceFactor } elseif ($type -eq 'LOG') { 2.0 } else { 30.0 }
            # A missing file older than @CleanupTime (plus one interval) has simply
            # aged out of retention - expected, not a hole. Only flag X inside the
            # retention window. Unknown retention => flag every gap, as before.
            $missHorizon = if ($null -ne $cleanup) {
                [double]$cleanup + $(if ($interval -and $interval -gt 0) { [double]$interval } else { 0 })
            }
            else { $null }

            $line = New-Object System.Text.StringBuilder
            $notes = New-Object System.Collections.Generic.List[string]

            for ($i = 0; $i -lt $chain.Count; $i++) {
                $r = $chain[$i]
                $missing = $usingHistory -and $r.PSObject.Properties['OnDisk'] -and $r.OnDisk -eq $false
                if ($missing -and $null -ne $missHorizon -and (($Now - $r.Timestamp).TotalHours) -gt $missHorizon) {
                    $missing = $false
                }

                if ($i -gt 0) {
                    $prev = $chain[$i - 1]
                    $span = ($r.Timestamp - $prev.Timestamp).TotalHours
                    # LSN continuity is only a thing for the LOG chain - each FULL / DIFF
                    # starts a long way past the previous one's last_lsn by design.
                    $forkBreak = $type -eq 'LOG' -and $usingHistory -and $prev.PSObject.Properties['ForkGuid'] -and $r.ForkGuid -and $prev.ForkGuid -and $prev.ForkGuid -ne $r.ForkGuid
                    $lsnBreak = $type -eq 'LOG' -and $usingHistory -and $null -ne $prev.LastLsn -and $null -ne $r.FirstLsn -and $r.FirstLsn -gt $prev.LastLsn

                    if ($forkBreak) {
                        [void]$line.Append(' //fork// ')
                        $notes.Add(('    {0:yyyy-MM-dd HH:mm}  recovery fork changed - chain broken here' -f $r.Timestamp))
                    }
                    elseif ($lsnBreak) {
                        [void]$line.Append(' //gap// ')
                        $notes.Add(('    {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm}  LSN break - a backup is missing from msdb' -f $prev.Timestamp, $r.Timestamp))
                    }
                    elseif ($span -gt $gapH) {
                        [void]$line.Append((' ~~[{0}]~~ ' -f (Get-DurationText $span)))
                        $notes.Add(('    {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm}  {2}, no {3} backups' -f $prev.Timestamp, $r.Timestamp, (Get-DurationText $span), $type))
                    }
                    else {
                        [void]$line.Append('-')
                    }
                }

                if ($missing) {
                    [void]$line.Append('X')
                    $gone = @(@($r.DevicePaths) | Where-Object { $_ } | ForEach-Object { Split-Path -Path ([string]$_) -Leaf })
                    $goneText = if ($gone.Count -gt 0) { '[{0}] ' -f ($gone -join ', ') } else { '' }
                    $notes.Add(('    {0:yyyy-MM-dd HH:mm}  file {1}missing (from msdb) - restore stops here' -f $r.Timestamp, $goneText))
                }
                else {
                    [void]$line.Append('|')
                }
            }

            $tail = ($Now - $chain[$chain.Count - 1].Timestamp).TotalHours
            if ($tail -gt $gapH) { [void]$line.Append((' ~~[{0}]~~> now' -f (Get-DurationText $tail))) }
            else { [void]$line.Append('--> now') }

            # Collapse long contiguous runs so a busy chain stays one line.
            $rendered = [regex]::Replace($line.ToString(), '(?:\|-){8,}\|', {
                    param($m)
                    $n = ([regex]::Matches($m.Value, '\|')).Count
                    "|-|-|..($n)..|-|-|"
                })

            Write-Host ('  {0,-4} {1}' -f $type, $rendered)
            foreach ($n in ($notes | Select-Object -Unique)) { Write-Host $n }
        }
    }
    Write-Host ''
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

# -Database accepts both -Database A,B (array) and a single quoted 'A,B' list
# (the style of Ola's own @Databases token); flatten to a plain pattern array.
$Database = @($Database | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Database.Count -eq 0) { $Database = @('*') }

# -JustLSN is a one-line-only view: silence the informational warning stream
# (job/path mismatches, empty scans) unless the caller asked for warnings
# explicitly. -Quiet takes precedence over -JustLSN.
if ($JustLSN -and $Quiet) { $JustLSN = $false }
if ($JustLSN -and -not $PSBoundParameters.ContainsKey('WarningAction')) {
    $WarningPreference = 'SilentlyContinue'
}

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

$logicalAll = @(Group-LogicalBackup -Record $records)
Write-Verbose "Grouped into $($logicalAll.Count) logical backup(s)."

# -SqlInstance accepts -SqlInstance A,B and a single 'A,B' string (like -Database).
# Zero instances = one pass with no SQL - the original single-target behaviour.
$instances = @($SqlInstance | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$multiInstance = $instances.Count -gt 1
if ($instances.Count -eq 0) { $instances = @('') }

# Results accumulated across every instance, for one combined HTML report,
# one pipeline stream, and one worst-case -FailOnGap exit code.
$allSorted = New-Object System.Collections.Generic.List[object]
$allPrediction = New-Object System.Collections.Generic.List[object]
$allRestore = New-Object System.Collections.Generic.List[object]
$anyError = $false
$anyWarn = $false

foreach ($inst in $instances) {
    $isSql = -not [string]::IsNullOrWhiteSpace($inst)

    # "Every path scanned for every server": one shared file inventory; each
    # instance keeps only the files whose parsed <SERVER$INSTANCE> matches it.
    # If nothing matches and it is the only instance, fall back to all files
    # (a single-server run pointed straight at that server's own folder).
    if ($isSql) {
        $logical = @($logicalAll | Where-Object { Test-InstanceMatch -FileInstance $_.Instance -SqlInstance $inst })
        if ($logical.Count -eq 0) {
            if ($multiInstance) { Write-Warning "No backup files under -BackupPath match instance '$inst'." }
            else { $logical = $logicalAll }
        }
    }
    else {
        $logical = $logicalAll
    }

    $jobConfig = $null
    $jobSchedule = @()
    $dbInfo = $null
    $commandLog = $null
    $backupHistory = @()
    if ($isSql) {
        try {
            $jobConfig = @(Get-OlaJobConfig -Instance $inst -Credential $SqlCredential)
            $dbInfo = Get-SqlDatabaseInfo -Instance $inst -Credential $SqlCredential
            Write-Verbose "Read $($jobConfig.Count) DatabaseBackup job step(s) and $($dbInfo.Count) database(s) from $inst."
        }
        catch {
            Write-Warning "Could not read configuration from $inst : $($_.Exception.Message)"
        }
        try {
            $jobSchedule = @(Get-OlaJobSchedule -Instance $inst -Credential $SqlCredential)
            Write-Verbose "Read $($jobSchedule.Count) DatabaseBackup job schedule(s) from $inst."
        }
        catch {
            Write-Warning "Could not read job schedules from $inst : $($_.Exception.Message)"
        }
        try {
            $commandLog = Get-OlaCommandLog -Instance $inst -Database $SolutionDatabase -SinceHours $HistoryHours -Credential $SqlCredential
            if ($null -eq $commandLog) {
                Write-Warning "dbo.CommandLog not found in [$SolutionDatabase] on $inst - pass -SolutionDatabase if the Maintenance Solution lives elsewhere."
            }
            else {
                Write-Verbose "Read $($commandLog.Count) CommandLog backup row(s) from [$SolutionDatabase]."
            }
        }
        catch {
            Write-Warning "Could not read dbo.CommandLog from [$SolutionDatabase] on $inst : $($_.Exception.Message)"
        }
        try {
            $backupHistory = @(Get-BackupSetHistory -Instance $inst -SinceHours $HistoryHours -Credential $SqlCredential)
            Write-Verbose "Read $($backupHistory.Count) backup-set history record(s) from msdb on $inst."
        }
        catch {
            Write-Warning "Could not read backup history from msdb on $inst : $($_.Exception.Message)"
        }
    }

# Drop databases that no longer exist / are not ONLINE in sys.databases - stale
# dbo.CommandLog rows and orphaned files for dropped or renamed databases.
if ($dbInfo -and -not $IncludeOfflineDatabases) {
    $live = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $dbInfo.Keys) { if ($dbInfo[$k].State -eq 'ONLINE') { [void]$live.Add($k) } }

    $droppedFrom = @($logical | Where-Object { -not $live.Contains($_.Database) } | ForEach-Object { $_.Database } | Sort-Object -Unique)
    $logical = @($logical | Where-Object { $live.Contains($_.Database) })
    if ($commandLog) { $commandLog = @($commandLog | Where-Object { $live.Contains($_.Database) }) }
    if ($backupHistory) { $backupHistory = @($backupHistory | Where-Object { $live.Contains($_.Database) }) }
    $onlineInfo = @{}
    foreach ($k in $dbInfo.Keys) { if ($live.Contains($k)) { $onlineInfo[$k] = $dbInfo[$k] } }
    $dbInfo = $onlineInfo

    Write-Verbose ("Restricted to {0} ONLINE database(s); ignoring backups for: {1} (use -IncludeOfflineDatabases to keep them)." -f `
            $live.Count, $(if ($droppedFrom.Count -gt 0) { $droppedFrom -join ', ' } else { '(none)' }))
}

# Scope everything downstream to -Database (default '*' = no filtering).
if ($Database -notcontains '*') {
    $logical = @($logical | Where-Object { Test-DatabaseMatch -Name $_.Database -Pattern $Database })
    if ($dbInfo) {
        $scoped = @{}
        foreach ($k in $dbInfo.Keys) {
            if (Test-DatabaseMatch -Name $k -Pattern $Database) { $scoped[$k] = $dbInfo[$k] }
        }
        $dbInfo = $scoped
    }
    if ($commandLog) { $commandLog = @($commandLog | Where-Object { Test-DatabaseMatch -Name $_.Database -Pattern $Database }) }
    if ($backupHistory) { $backupHistory = @($backupHistory | Where-Object { Test-DatabaseMatch -Name $_.Database -Pattern $Database }) }
    Write-Verbose ("Scoped to -Database {0}: {1} logical backup(s), {2} database(s)." -f ($Database -join ','), $logical.Count, $(if ($dbInfo) { $dbInfo.Count } else { 0 }))
}

$override = @{
    'FULL-Cleanup' = if ($PSBoundParameters.ContainsKey('FullCleanupTimeHours')) { $FullCleanupTimeHours } else { $null }
    'DIFF-Cleanup' = if ($PSBoundParameters.ContainsKey('DiffCleanupTimeHours')) { $DiffCleanupTimeHours } else { $null }
    'LOG-Cleanup'  = if ($PSBoundParameters.ContainsKey('LogCleanupTimeHours')) { $LogCleanupTimeHours } else { $null }
    'FULL-Interval' = if ($PSBoundParameters.ContainsKey('FullIntervalHours')) { $FullIntervalHours } else { $null }
    'DIFF-Interval' = if ($PSBoundParameters.ContainsKey('DiffIntervalHours')) { $DiffIntervalHours } else { $null }
    'LOG-Interval'  = if ($PSBoundParameters.ContainsKey('LogIntervalHours')) { $LogIntervalHours } else { $null }
}

$model = Get-ExpectationModel -LogicalBackup $logical -JobConfig $jobConfig -JobSchedule $jobSchedule -DatabaseInfo $dbInfo -CommandLog $commandLog -Config $config -Override $override

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

# Annotate history with on-disk status once, up front (Test-LsnChain and
# Write-ChainGraph both use it).
if ($backupHistory.Count -gt 0) { $backupHistory = @(Join-BackupSetToFile -History $backupHistory -LogicalBackup $logical) }

$lsn = Test-LsnChain -History $backupHistory -LogicalBackup $logical -DatabaseInfo $dbInfo
Write-Verbose "LSN chain status: $($lsn.Status) ($($lsn.Findings.Count) finding(s))."
if ($lsn.Findings.Count -gt 0) { $findings = @($findings) + @($lsn.Findings) }

# Stamp every finding with the instance it belongs to, so a multi-server run
# stays groupable on the pipeline (New-Finding fills Instance from the file tree;
# the -SqlInstance name is the stable key when we have it).
if ($isSql) { foreach ($f in $findings) { $f.Instance = $inst } }

$sorted = $findings | Sort-Object @{ E = { @('Error', 'Warning', 'Info').IndexOf($_.Severity) } }, Database, BackupType, Finding

# -JustLSN leads the line with the server + database, so a monitoring probe can
# key on it. Prefer the -SqlInstance name, then the instance parsed from the file
# tree, then this host's name.
$instancePrefix = ''
if ($JustLSN) {
    $instancePrefix = $inst
    if (-not $instancePrefix) {
        $fileInstances = @($logical | ForEach-Object { $_.Instance } | Where-Object { $_ } | Sort-Object -Unique)
        if ($fileInstances.Count -eq 1) { $instancePrefix = $fileInstances[0] }
    }
    if (-not $instancePrefix) { $instancePrefix = $env:COMPUTERNAME }
}

$summaryLine = Get-RunSummary -Now $script:Now -Logical $logical -Model $model -Finding $findings -LsnStatus $lsn.Status -InstancePrefix $instancePrefix
Write-Verbose $summaryLine

# Per-server banner for the multi-instance block view (not under -JustLSN, whose
# every line already starts with the server name).
if ($multiInstance -and -not $Quiet -and -not $JustLSN) {
    Write-Host ''
    Write-Host ('===  {0}  ' -f $inst).PadRight(60, '=') -ForegroundColor Cyan
}

if ($Advice -and -not $Quiet -and -not $JustLSN) {
    $adviceLines = @(Get-BackupAdvice -Model $model -LogicalBackup $logical -DatabaseInfo $dbInfo)
    if ($adviceLines.Count -gt 0) {
        Write-Host ''
        Write-Host 'Advice  (-Advice)' -ForegroundColor Cyan
        foreach ($a in $adviceLines) { Write-Host $a }
    }
}

if (-not $Quiet) {
    # Print one run-summary line, colouring the "LSN <status>" token wherever it
    # sits (it is not at the start under -JustLSN, which prefixes server + db).
    $writeSummaryLine = {
        param([string]$Line, [string]$Status)
        $color = switch ($Status) { 'valid' { 'Green' } 'error' { 'Red' } default { 'DarkYellow' } }
        $token = "LSN $Status"
        $at = $Line.IndexOf($token)
        Write-Host $Line.Substring(0, $at) -NoNewline
        Write-Host 'LSN ' -ForegroundColor White -NoNewline
        Write-Host $Status -ForegroundColor $color -NoNewline
        Write-Host $Line.Substring($at + $token.Length)
    }

    if ($JustLSN) {
        # One line per in-scope database, each with its own LSN verdict.
        $justDbs = @($model.Keys | Sort-Object)
        if ($justDbs.Count -eq 0) {
            & $writeSummaryLine $summaryLine $lsn.Status
        }
        foreach ($jdb in $justDbs) {
            $jLogical = @($logical | Where-Object { $_.Database -eq $jdb })
            $jFinding = @($findings | Where-Object { $_.Database -eq $jdb })
            $jHistory = @($backupHistory | Where-Object { $_.Database -eq $jdb })
            $jStatus = (Test-LsnChain -History $jHistory -LogicalBackup $jLogical -DatabaseInfo $dbInfo).Status
            $jLine = Get-RunSummary -Now $script:Now -Logical $jLogical -Model @{ $jdb = $model[$jdb] } `
                -Finding $jFinding -LsnStatus $jStatus -InstancePrefix $instancePrefix
            & $writeSummaryLine $jLine $jStatus
        }
    }
    else {
        Write-Host ''
        & $writeSummaryLine $summaryLine $lsn.Status
        if ($sorted) {
            Write-Host ''
            $sorted | Group-Object Severity | ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.Name, $_.Count) }
        }
        elseif (-not $Predict) {
            Write-Host 'No findings - retention, cadence and files on disk are consistent.' -ForegroundColor Green
        }
    }
}

    # --- accumulate this instance's results for the combined outputs ---
    foreach ($s in $sorted) { [void]$allSorted.Add($s) }
    if (@($findings | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0) { $anyError = $true }
    if (@($findings | Where-Object { $_.Severity -eq 'Warning' }).Count -gt 0) { $anyWarn = $true }

    $prediction = $null
    if ($Predict) {
        $prediction = @(Get-BackupPrediction -LogicalBackup $logical -Model $model -History $backupHistory -ToleranceFactor $GapToleranceFactor)
        if (-not $Quiet -and -not $JustLSN) { Write-PredictionMatrix -Prediction $prediction -LogicalBackup $logical }
        foreach ($p in $prediction) { [void]$allPrediction.Add($p) }
    }

    if ($Graph -and -not $Quiet -and -not $JustLSN) {
        Write-ChainGraph -History $backupHistory -LogicalBackup $logical -Model $model -ToleranceFactor $GapToleranceFactor
    }

    $restorePlans = $null
    if ($RestorePlan) {
        if ($backupHistory.Count -eq 0) {
            Write-Warning 'RestorePlan needs msdb history - supply -SqlInstance.'
            $restorePlans = @()
        }
        else {
            $restorePlans = @(Get-RestorePlan -History $backupHistory)
        }
        if (-not $Quiet -and -not $JustLSN) { Write-RestorePlan -Plan $restorePlans }
        foreach ($rp in $restorePlans) { [void]$allRestore.Add($rp) }
    }
}
# --- end per-instance loop ---

if ($ReportPath) {
    Write-HtmlReport -Finding @($allSorted) -Path $ReportPath -ScannedPath $BackupPath
    if (-not $Quiet -and -not $JustLSN) { Write-Host "HTML report: $ReportPath" }
}

# Emit objects on the pipeline: prediction records under -Predict, restore-plan
# records under -RestorePlan, otherwise the findings. -JustLSN emits nothing -
# the summary lines are the whole output (-FailOnGap still sets the exit code).
if ($JustLSN) { }
elseif ($Predict) { $allPrediction }
elseif ($RestorePlan) { $allRestore }
else { $allSorted }

if ($FailOnGap) {
    # Worst exit code across every instance: 1 if any server had an Error, else
    # 2 if any had a Warning, else 0.
    if ($anyError) { exit 1 }
    elseif ($anyWarn) { exit 2 }
    else { exit 0 }
}

#endregion
