# CLAUDE.md

Guidance for working in this repository.

## What this is

`BackupChainCheck` is a **read-only Windows PowerShell 5.1** tool that reconciles
Ola Hallengren `DatabaseBackup` retention (`@CleanupTime`, in hours) and schedule
against the backup files actually present on disk, and reports recovery-coverage
gaps. See `README.md` for the functional design and the reconciliation math.

Core rule: **the tool must never write to SQL Server and never delete or modify
backup files.** Every SQL query is a read-only `SELECT` against `msdb`,
`sys.databases` / `master`, and `<SolutionDatabase>.dbo.CommandLog`. No
`RESTORE`, not even `VERIFYONLY` (verify results are read from `CommandLog`).
Every filesystem operation is enumeration only.

## Runtime target: Windows PowerShell 5.1 only

Do **not** use PowerShell 7+ syntax. In particular, these are unavailable and will
break under 5.1:

- Ternary `a ? b : c`, null-coalescing `??`, null-conditional `?.`
- Pipeline chain operators `&&` / `||` (in scripts)
- `ForEach-Object -Parallel`, `Get-Error`, `Get-Uptime`
- `ConvertFrom-Json -AsHashtable`, `ConvertTo-Json -EnumsAsStrings`
- `[System.Text.Json]` (use `ConvertTo-Json` / `ConvertFrom-Json`)
- `Clean {}` blocks, `using namespace` for arbitrary assemblies not loaded by 5.1

Use instead:
- `if/else`, explicit `$null -eq $x` checks (null on the left)
- `[pscustomobject]@{ ... }` for output records
- `System.Data.SqlClient` (built into .NET Framework 4.x, always present in 5.1)
- `#Requires -Version 5.1` at the top of every script/module

Every script starts with:

```powershell
#Requires -Version 5.1
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
```

**StrictMode is 1.0, not 2.0+, on purpose.** 2.0+ turns PowerShell's
scalar/collection unification into hard errors — `.Count` on a single object,
member enumeration (`$x.Prop`) over a possibly-empty result — which this code
relies on heavily. 1.0 still catches the bug that actually bites (typo'd /
uninitialised variables). If you raise it, you must wrap every possibly-scalar
expression in `@(...)` before `.Count` or `[index]` and guard every `.Prop`
enumeration — not worth it here.

## Repository layout

Today it is one self-contained script plus tests:

```
Invoke-BackupChainCheck.ps1              The whole tool. param() block, helper
                                         functions in #region blocks, then a
                                         #region Main that runs the analysis.
                                         Returns early when dot-sourced
                                         (InvocationName -eq '.') so tests can
                                         load the functions without running it.
BackupChainCheck.Format.ps1xml           Default TableControl views for the emitted
                                         BackupChainCheck.Finding / .Prediction /
                                         .RestorePlan / .RestoreStep objects.
                                         Loaded via Update-FormatData at
                                         script start (guarded - the script still
                                         works if it is missing). Optional polish,
                                         not a second code file.
expectations.sample.json                 Template for -ConfigPath.
tests/Invoke-BackupChainCheck.Tests.ps1  Pester tests (parsing + math), no SQL.
```

Internal structure of the script, in order:

- `New-Finding` (tags output `BackupChainCheck.Finding`) / `Get-DurationText` /
  `Get-DataSizeText` / `Get-Median` / `Get-RunSummary` (the one-line header) —
  small helpers.
- `ConvertFrom-OlaBackupFile` — one FileInfo (or stand-in) → parsed record.
  Directory structure trusted first, file name is the fallback.
- `Get-BackupFileInventory` / `Group-LogicalBackup` — scan + collapse striping.
- `Invoke-SqlQuery` — thin read-only ADO.NET helper.
- `Get-OlaJobConfig` — regex `@CleanupTime` / `@CleanupMode` / `@NumberOfFiles` /
  `@BackupType` / `@Databases` / `@Directory` out of `msdb.dbo.sysjobsteps`.
- `Get-OlaJobSchedule` — the SQL Agent schedule(s) on each DatabaseBackup job
  (`sysschedules` + `sysjobschedules`), turned into an intended interval + text +
  next-run time per (backup type, scope). `ConvertTo-ScheduleInterval` /
  `ConvertFrom-AgentTime` do the `freq_*` decoding (pure, tested).
- `Get-OlaCommandLog` — `BACKUP_DATABASE` / `BACKUP_LOG` rows from
  `<SolutionDatabase>.dbo.CommandLog`; returns `$null` if the table is absent,
  otherwise a plain array (never a `-NoEnumerate` `List` — that trips an ETS
  binder bug in the caller's `@(...)`).
- `Get-BackupSetHistory` / `Group-BackupSetRow` — `msdb.dbo.backupset` +
  `backupmediafamily` + `backupmediaset` for D/I/L backups, one record per
  logical backup with its LSN chain fields (`FirstLsn` … `DifferentialBaseLsn`,
  kept as `[decimal]` — never `[double]`), recovery-fork guids, damage/verify
  flags, stripe device paths, and size/throughput (`BackupSizeBytes`,
  `CompressedSizeBytes`, `DurationSeconds`, `SpeedMBps` = `backup_size / run
  time`, `$null` under a second). `Group-BackupSetRow` is the pure shaper the
  tests drive with stand-in rows. LSN/bool marshalling helpers:
  `ConvertTo-LsnDecimal`, `ConvertTo-NullableBool`.
- `Get-SqlDatabaseInfo` — `sys.databases` recovery model / state / last backup.
  Main then drops databases that are not present + ONLINE here (stale
  `CommandLog` / orphaned files) unless `-IncludeOfflineDatabases`.
- `Expand-DatabaseScope` — Ola `@Databases` token → concrete database list.
- `Get-ExpectationModel` — layers interval (files → CommandLog → SQL Agent
  schedule → config → params) and retention (config defaults → job → config
  per-db → params) into `$model[db][type]` (also carries `ScheduleText` /
  `NextRun` when a schedule set the interval).
- `Test-BackupChain` — the file/retention/cadence checks; emits `New-Finding`.
- `Join-BackupSetToFile` — annotates each `Get-BackupSetHistory` record with
  `OnDisk` / `MatchedPath` (device-path match, then db+type+timestamp fallback).
- `Test-LsnChain` — LSN continuity of the LOG chain from `Get-BackupSetHistory`
  (each LOG `first_lsn` = previous `last_lsn`, one recovery fork, nothing
  `is_damaged`, DIFF bases present) plus, with `-LogicalBackup`, a hole in the
  on-disk chain (a recorded LOG between the oldest and newest on-disk LOG whose
  own file is gone) and a chain with no FULL backup file left on disk to restore
  first. Time gaps are deliberately NOT breaks. Returns
  `@{ Status = 'valid'|'error'|'n/a'; Findings }`; `Status` is the first column
  of the `Get-RunSummary` line (green / red / dark-yellow on the console).
- `Get-BackupAdvice` — the `-Advice` mode: plain-language notes on the retention
  / cadence design (DIFF kept longer than FULL, LOG shorter than FULL, cleanup
  below cadence, thin FULL copy count), grouped by identical settings, plus an
  approximate wasted-space figure (files past retention + orphaned diffs, summing
  `SizeBytes` from `Group-LogicalBackup`). Pure; console-only in Main.
- `Write-ChainGraph` — the `-Graph` mode: an ASCII timeline per (database, type)
  from the annotated history (or files), `|` per backup, `X` for a missing file,
  `~~[dur]~~` / `//gap//` / `//fork//` between. LSN-break markers are LOG-only.
  `X` (and its "file [name] missing" note) is only drawn inside the retention
  window — age `<= CleanupHours + IntervalHours`; older missing records aged out
  and render as `|`. Unknown retention flags every gap.
- `Get-BackupPrediction` / `Write-PredictionMatrix` — the `-Predict` mode.
  `Get-BackupPrediction` projects, per (database, type) with a known retention +
  interval, the backup slots that should be on disk now (one every interval, back
  to age `Cleanup + Interval`), greedily matches each to the closest unclaimed
  actual within half an interval, and emits a `BackupChainCheck.Prediction`
  record with a `.Slots` breakdown (and `SpeedMBps` — the median
  `Get-BackupSetHistory` throughput for that database + type; the `MB/s` column
  in the emitted table). Pure; takes `-History` and `-Now` for testability.
- `Get-RestorePlan` / `Write-RestorePlan` — the `-RestorePlan` mode: per database,
  the shortest sequence of backup FILES ON DISK that forms a valid LSN chain to
  the newest recoverable point (newest on-disk FULL → newest on-disk DIFF whose
  `DifferentialBaseLsn` = that FULL's `FirstLsn` → contiguous on-disk LOGs from
  the anchor LSN forward). Pure; reads the `Join-BackupSetToFile`-annotated
  history (LSNs are only in msdb). Emits `BackupChainCheck.RestorePlan` (with a
  `.Steps` array of `BackupChainCheck.RestoreStep` and a `.RestoreScript` string
  of the T-SQL `RESTORE … WITH NORECOVERY` statements + trailing `WITH RECOVERY`
  when complete; striped backups list every `DISK =` member), `Complete` false +
  `Reason` when a link's file is gone. Needs `-SqlInstance`.
- `Test-DatabaseMatch` — `-Database` wildcard filter (`-like`, `*` = all).
- `Write-HtmlReport`.

**Watch the switch/local-variable name clash:** the `-RestorePlan` switch param
and any `$restorePlan` local are the same variable (PowerShell is
case-insensitive) — Main uses `$restorePlans` for the result to avoid clobbering
the switch. Same trap waits for any future `$predict` / `$graph` / `$advice`.

`#region Main`, in order: load config → scan files → (`-SqlInstance`) read job
config, schedule, `CommandLog`, backup history → drop non-ONLINE / dropped
databases unless `-IncludeOfflineDatabases` → apply `-Database` scope →
`Get-ExpectationModel` → `Test-BackupChain` → `Join-BackupSetToFile` (annotate
history once) → `Test-LsnChain` → merge findings → `Get-RunSummary` +
console/`-Predict`/`-Graph`/`-RestorePlan` output → HTML report → emit pipeline
objects (predictions under `-Predict`, restore plans under `-RestorePlan`, else
findings) → `-FailOnGap` exit code.

**A future module split** (`BackupChainCheck.psd1` + `.psm1` + `src/` with one
public function per file, `docs/ola-conventions.md`) is fine to do later, but keep
the single-script entry point working — it is what the README documents.

## Coding conventions

- Approved verbs only (`Get-Verb`). Public functions: `[CmdletBinding()]`,
  comment-based help, typed + validated parameters, pipeline-friendly.
- Emit **objects, not text**. No `Write-Host` for data; use `Write-Verbose`,
  `Write-Warning`, `Write-Error` for diagnostics and the pipeline for results.
  The exception is the deliberate human-facing console views — `Get-RunSummary`,
  `Write-PredictionMatrix`, `Write-ChainGraph`, the findings table — which
  `Write-Host` under `-not $Quiet` *in addition to* the pipeline objects, never
  instead of them. `BackupChainCheck.Format.ps1xml` gives the pipeline objects
  their default table view.
- Findings are `[pscustomobject]` with a stable shape:
  `Instance, Database, BackupType, Severity ('Error'|'Warning'|'Info'), Finding, Expected, Found, Detail`.
- SQL access is plain ADO.NET (`System.Data.SqlClient`) via `Invoke-SqlQuery`.
  No dependency on the `SqlServer` / `SQLPS` module — do not add one. All queries
  are read-only against `msdb`, `master` / `sys.databases`, and `dbo.CommandLog`.
- SQL failures degrade gracefully: wrap the calls in `try/catch`, `Write-Warning`,
  and carry on with whatever inputs are available.
- Paths: support local and UNC. `Get-ChildItem -Recurse -File -Include` is fine at
  current scale; switch to `[System.IO.Directory]::EnumerateFiles` only if a real
  large-tree problem shows up.
- Dates: the file-name timestamp is the source of truth for backup time. `AgeHours`
  is computed once against `$script:Now`. Clock/timezone skew between the backup
  host and the checking host is a known limitation — noted in the README.

## Testing

- Pester, syntax compatible with **Pester 3.4** (in-box on Windows): `Describe` /
  `It` / `Should Be`. Avoid 4.x/5.x-only forms (`Should -Be`, `-Show`).
- Tests dot-source the script (`. $scriptPath -BackupPath $env:TEMP`) and call the
  internal functions directly. `ConvertFrom-OlaBackupFile` takes an untyped `$File`
  so tests can pass a lightweight stand-in instead of a real `FileInfo`.
- `Invoke-Pester -Path .\tests` must pass before any commit. No live SQL Server.
- If PSScriptAnalyzer is available, keep it clean; the editor also surfaces its
  rules inline (unused variables, unapproved verbs).

## Safety / scope

- Read-only everywhere. If a change would write to SQL Server or touch a backup
  file, stop and flag it.
- Don't add telemetry, don't call external services.
- Don't commit or push unless the user explicitly asks.
