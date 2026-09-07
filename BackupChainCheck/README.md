# BackupChainCheck

A read-only Windows PowerShell 5.1 tool that checks whether the SQL Server backup
files produced by [Ola Hallengren's Maintenance Solution](https://ola.hallengren.com/)
actually add up to the recovery coverage you think you have.

It does this by **reconciling three things that are normally never compared**:

1. **Retention** – the `@CleanupTime` value (in hours) and other backup settings
   configured in the `DatabaseBackup` Agent job steps (or supplied via a config file).
2. **Cadence** – how often each backup type is scheduled to run (read from SQL Agent
   schedules, from `msdb.dbo.backupset` history, or inferred from file timestamps).
3. **Reality** – the backup files that are actually present on the backup path(s).

When those three disagree, you have a gap.

---

## The question this answers

> `@CleanupTime` is 48 (hours) and a FULL backup runs every morning at 06:00, but
> there is only **one** FULL backup file on disk. Is that a problem?

Yes — and it is exactly the kind of thing this tool flags.

`@CleanupTime` is **not a schedule and not a guaranteed copy count**. It only means
*"after a successful backup, delete files of this database + this backup type that are
older than N hours."* (With `@CleanupMode = 'AFTER_BACKUP'`, the default, the delete
is skipped entirely if the backup fails.)

So retention + cadence imply an **expected file count**:

```
expected files per (database, backup type) ≈ floor(CleanupTime / IntervalHours) + 1
                                             (× @NumberOfFiles if the backup is striped)
```

| Setting                        | Interval | Expected FULL files |
|--------------------------------|----------|---------------------|
| `@CleanupTime = 48`, daily FULL | 24 h     | `floor(48/24) + 1` = **3** |
| `@CleanupTime = 24`, daily FULL | 24 h     | **2** (and briefly 1 right after cleanup) |
| `@CleanupTime = 48`, weekly FULL | 168 h   | **1** – by design, but a single-copy risk |

Finding **1** file where the math says **3** means one of:

- the backup job has been failing or not running (most common),
- `@CleanupMode = 'BEFORE_BACKUP'` plus a recent failure wiped older copies,
- something outside Ola's solution is deleting files,
- the schedule is not really daily,
- the job was only recently deployed.

BackupChainCheck reports the discrepancy, the likely cause, and the affected
databases so you can tell which case it is.

---

## What it checks

- **Count gaps** – fewer FULL / DIFF / LOG files present than retention + cadence
  *guarantee* (`floor(C/I)`). When there is too little history on disk to be sure,
  it downgrades to a lower-confidence warning and says why.
- **LOG / DIFF chain gaps** – spacing between consecutive backups larger than
  `interval × GapToleranceFactor` (default 1.5), i.e. missing backups that break
  point-in-time recovery. All gaps for a database roll up into one finding.
- **LSN chain** (`-SqlInstance`) – from `msdb` history: each LOG's `first_lsn`
  equals the previous `last_lsn` (contiguous, one recovery fork), no `is_damaged`
  backup, and no LOG recorded in `msdb` inside the on-disk chain window whose file
  has gone missing. Reported as the `LSN valid` / `error` headline plus findings.
- **Roll-forward coverage** – the oldest retained FULL has a LOG chain starting at
  or before it. `@CleanupTime` for LOG shorter than for FULL leaves your *oldest*
  full backups unrecoverable-forward.
- **Retention consistency**
  - `@CleanupTime(LOG)  >= @CleanupTime(FULL)` and `@CleanupTime(DIFF) <= @CleanupTime(FULL)`
  - `@CleanupTime <  IntervalHours` → risk of **zero** valid backups right after a cleanup.
  - `@CleanupTime` not a whole multiple of the interval → the copy count oscillates.
  - `@CleanupMode = 'BEFORE_BACKUP'` → old copies deleted before the new backup runs.
- **Stale / orphan files** – files far older than `@CleanupTime` still present
  (cleanup silently failing – permissions, striped-file mismatch, past failures).
- **Striping** – backups missing stripe members (`@NumberOfFiles` from the job, or
  inferred from the widest stripe set actually seen).
- **Failed runs** – `dbo.CommandLog` rows with a non-zero `ErrorNumber`, and
  successful runs in `CommandLog` with no matching file on disk.
- **Coverage** – ONLINE databases with no backup files under the scanned paths.
- **Recovery-model mismatch** – FULL/BULK_LOGGED databases with no LOG backups;
  LOG backups present for a SIMPLE database.
- **Configured-path mismatch** – a job's `@Directory` is not among the scanned roots.

---

## Requirements

- Windows PowerShell **5.1** (ships with Windows 10/11 and Windows Server 2016+).
  PowerShell 7 is not required and not targeted.
- Read access to the backup path(s) – local paths or UNC shares.
- *Optional:* a login on the SQL Server instance with read access to `msdb`, to
  `sys.databases`, and to `dbo.CommandLog` in the database where Ola's objects are
  installed (`SQLAgentReaderRole` + `db_datareader` on `msdb` and that database is
  enough). Without it, supply the expected retention/cadence in a config file.
- No external modules required — connectivity is plain ADO.NET
  (`System.Data.SqlClient`, built into .NET Framework).

The tool **never writes to SQL Server and never deletes or modifies backup files.**

---

## Usage

```powershell
# Reconcile against a live instance. Reads the DatabaseBackup job steps, sys.databases,
# and dbo.CommandLog (Ola's run log). -SolutionDatabase defaults to master.
.\Invoke-BackupChainCheck.ps1 -SqlInstance 'win11' -SolutionDatabase 'master' -BackupPath 'E:\backups\win11'

.\Invoke-BackupChainCheck.ps1 -SqlInstance 'SQL01' -BackupPath '\\nas01\sqlbackup'

# Solution installed in a dedicated DBA database
.\Invoke-BackupChainCheck.ps1 -SqlInstance 'SQL01' -SolutionDatabase 'DBA' -BackupPath 'D:\Backup'

# No SQL connection – describe expectations in a config file (see expectations.sample.json)
.\Invoke-BackupChainCheck.ps1 -BackupPath 'D:\Backup' -ConfigPath '.\expectations.json'

# Quick one-off: just check FULLs against a known retention/cadence
.\Invoke-BackupChainCheck.ps1 -BackupPath 'D:\Backup' -FullCleanupTimeHours 48 -FullIntervalHours 24

# Multiple roots, HTML report, monitoring exit code
.\Invoke-BackupChainCheck.ps1 -SqlInstance 'SQL01' `
    -BackupPath 'D:\Backup','\\nas01\sqlbackup' `
    -ReportPath '.\report.html' -FailOnGap

# One database, predicted-vs-actual matrix + ASCII chain timeline
.\Invoke-BackupChainCheck.ps1 -SqlInstance 'SQL01' -BackupPath 'D:\Backup' `
    -Database 'Finance' -Predict -Graph
```

`-Database` takes one or more `-like` wildcard patterns (default `*` = every
database) and scopes the whole analysis, not just the printed table.

With `-SqlInstance`, the analysis is limited to databases that currently exist
and are **ONLINE** in `sys.databases` — stale `dbo.CommandLog` rows and orphaned
files for dropped or renamed databases (a leftover `_ODS`, say) are ignored.
`-IncludeOfflineDatabases` keeps them.

### `-Predict` — what *should* be on disk

`-Predict` turns the retention math around: for every in-scope `(database, backup
type)` with a known retention and cadence it projects the set of backup files
that should be present right now — one slot every `IntervalHours`, back to age
`CleanupTime + IntervalHours` — and matches each slot to a real file.

```
Predicted backups on disk now  -  present / expected   (-Predict)

Database   FULL  DIFF  LOG
--------   ----  ----  ---
Finance    3/3   4/4   2/49
Sales      1/3   0/1   47/49

Finance / LOG  -  interval 1h 00m, retention 2d 0h 00m (AFTER_BACKUP), 1 file(s)/backup
   expected 49, present 2, missing 47, off-schedule 1
   missing slots: 2026-09-07 08:00, 2026-09-07 07:00, 2026-09-07 06:00, ... (+44 more)
```

It emits one `BackupChainCheck.Prediction` object per `(database, type)` on the
pipeline (each with a `.Slots` array of every projected slot, its age and
`present` / `partial` / `missing` status, plus `Schedule`, `NextScheduledRun` and
`IntervalSource`). The findings table still prints to the console, and
`-FailOnGap` still works off the findings.

With `-SqlInstance` the projected slot times come from the **SQL Agent schedule**
on the DatabaseBackup jobs (`daily at 18:00`, `every 1 hour`, …), so "missing
slots" line up with the times the backup was actually supposed to run.

### `-Graph` — the chain, drawn

`-Graph` prints an ASCII timeline per `(database, type)`:

```
Backup chain timeline  (-Graph)
  | backup present   X recorded in msdb, file missing   ~~[d]~~ idle gap   //gap// LSN break   //fork// recovery fork

StackOverflow2010
  FULL | ~~[6d 14h 37m]~~ |-|-|--> now
    2026-08-31 18:01 -> 2026-09-07 08:38  6d 14h 37m, no FULL backups
  LOG  |-|-|-|-|-|-|-X-|-|-|-|-|-| ~~[11h 00m]~~ | ~~[5d 23h 46m]~~ |-|-|-|--> now
    2026-08-31 16:00  file missing on disk (recorded in msdb) - restore stops here
    2026-09-01 09:00 -> 2026-09-07 08:46  5d 23h 46m, no LOG backups
```

Each `|` is a backup; `X` is one that `msdb` recorded but whose file is gone;
`~~[…]~~` is an idle stretch; `//gap//` an LSN break; `//fork//` a recovery-fork
change. Console only — the pipeline is unchanged.

When no retention is supplied (no `-SqlInstance`, no `-ConfigPath`, no
`-*CleanupTimeHours`), the tool still infers cadence from file spacing and reports
chain gaps, striping problems and coverage — it just cannot evaluate the
count-vs-retention check and says so.

Cadence, when not given explicitly, is taken from the SQL Agent schedule on the
DatabaseBackup jobs, then `dbo.CommandLog` run times, then the spacing of the
files on disk — in that order of preference. A `-*IntervalHours` parameter or a
config-file value overrides all of them.

### Output

The console output opens with a one-line summary — the **LSN chain verdict**, run
time, scope, `@CleanupTime` for FULL / DIFF / LOG (a range when it differs across
databases, `?` when unknown), the count of FULL / DIFF / LOG files found, and the
finding tally:

```
LSN valid  |  BackupChainCheck 2026-09-07 10:30  |  StackOverflow2010  |  @CleanupTime F/D/L 48/48/48h  |  files F/D/L 3/2/18  |  3E 4W 0I
```

`LSN valid` / `error` / `n/a` (green / red / yellow on the console) comes from
`Test-LsnChain`. With `-SqlInstance` it reads `msdb` history and checks that:

- each LOG backup's `first_lsn` equals the previous one's `last_lsn` — a
  contiguous chain on one recovery fork,
- no backup is `is_damaged`,
- and every LOG that `msdb` records **between the oldest and newest LOG that are
  actually on disk** still has its `.trn` file — so a log deleted (or aged off
  while its neighbours were kept) out of the middle of the retained chain is
  caught, even though the recorded LSNs still line up.

**Time gaps are not a break** — a database can sit idle for days with a perfectly
intact chain, which is why this can read `valid` even when the file-spacing check
reports "LOG chain gap". `n/a` means there was no `msdb` history to check (no
`-SqlInstance`, or no LOG backups in the window).

Each finding is then emitted as a `[pscustomobject]` on the pipeline so you can
filter, export, or feed it into monitoring:

```
Severity Database      BackupType Finding                                                 Expected  Found
-------- --------      ---------- -------                                                 --------  -----
Error    Sales         FULL       Fewer backups present than retention + cadence guarantee 2-3      1
Error    Finance       LOG        LOG chain gap of 4h 00m                                  <= 1h 30m ~3 backup(s) missing
Warning  Finance       LOG        LOG retention is shorter than FULL retention             >= 72h    24h
Info     Reporting     FULL       Only 1 FULL backup present - cannot confirm retention health        1
```

Each finding carries `Instance, Database, BackupType, Severity, Finding, Expected,
Found, Detail`. Repeated problems roll up: all log-chain gaps for one database
become a single finding with a count, not one row per gap.

`-ReportPath` additionally writes a standalone, theme-neutral HTML summary. With
`-FailOnGap` the script exits `1` if any `Error` finding is produced, `2` if only
`Warning`s, `0` otherwise — usable as an Agent job step or scheduled monitoring
check.

---

## Ola Hallengren layout this tool understands

Default directory structure:

```
<BackupRoot>\<SERVER$INSTANCE>\<DatabaseName>\<FULL|DIFF|LOG>\<file>
```

Default file name convention:

```
<SERVER$INSTANCE>_<DatabaseName>_<FULL|DIFF|LOG>_<yyyyMMdd>_<HHmmss>[_<n>].<bak|trn>
                                    optional _PARTIAL / _COPY_ONLY tokens ^   ^ stripe number
```

The timestamp in the file name is used as the backup time; `@NumberOfFiles > 1`
(striping) is detected from the trailing `_<n>` and counted as one logical backup.

---

## Caveats

- **`xp_delete_file` uses the backup header date, not the file's timestamp.** Ola's
  cleanup reads the media/backup-set date embedded in each file, which can differ
  from the filesystem `LastWriteTime` this tool sees. They are normally close, but
  don't treat a few-minutes difference as meaningful.
- **Cleanup is skipped on failure** (`AFTER_BACKUP` mode), so a *pile-up* of old
  files usually means past backup failures, not a retention bug.
- **`@CopyOnly = 'Y'` backups** land in a separate folder and are not governed by
  `@CleanupTime`; they are reported separately and excluded from chain math.
- **Third-party / off-box targets** – `@BackupSoftware` (LiteSpeed, SQL Backup),
  backup-to-URL (Azure Blob), and dedupe appliances change or hide the file layout;
  results there are best-effort.
- **Snapshot in time** – just before the scheduled run you legitimately have one
  fewer file than just after. Run the check at a consistent point in the cycle, or
  let the tool widen the tolerance using known schedule times.
- **Clock/timezone skew** between the machine writing backups and the machine
  running the check will shift computed ages.

---

## Files

| File | Purpose |
|------|---------|
| `Invoke-BackupChainCheck.ps1` | The tool. Single self-contained script. |
| `BackupChainCheck.Format.ps1xml` | Default table views for the emitted objects (loaded automatically; optional). |
| `expectations.sample.json` | Template for `-ConfigPath`. |
| `tests/Invoke-BackupChainCheck.Tests.ps1` | Pester tests for the parsing / math functions. |
| `CLAUDE.md` | Repo conventions and design notes. |

## Tests

```powershell
Invoke-Pester -Path .\tests
```

Written for the in-box Pester 3.4; also runs on 4.x / 5.x. No SQL Server needed.

## Status

Working. Filesystem reconciliation, config-file and `-SqlInstance` inputs,
`dbo.CommandLog` failure detection, HTML report and monitoring exit codes are all
implemented and covered by a smoke test. A future split into a proper module
(`src/`, `BackupChainCheck.psd1`) is described in `CLAUDE.md` but not done yet.

## License

MIT (see `LICENSE`).
