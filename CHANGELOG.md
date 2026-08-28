# Changelog

All notable changes to Chrome RAM Watch are recorded here.

The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-08-28

### Added

- Combined live monitoring for every Chrome browser process tree with `-AllInstances`
- Conservative Normal, Elevated, High, and Critical pressure labels with explicit reasons
- Sustained-pressure detection after three consecutive successful Elevated-or-worse samples
- PID plus creation-time identities, process age, per-process deltas, and private-memory growth rates
- Bounded live observation with `-SampleCount`
- JSON schema `chrome-ram-watch/v2` with all-instance scope, full process rows, pressure, and trend fields
- Optional Manifest V3 cleanup companion for reviewing and explicitly discarding eligible inactive tabs
- Strict companion safeguards for active, pinned, audible, already-discarded, non-auto-discardable, recent, and unknown-state tabs
- Separate review and discard actions with final exact-tab-ID revalidation and confirmed result reporting

### Changed

- Unquoted launch-profile hints such as `Profile 35` are captured through the next Chrome flag or command-line end
- Bounded sample failures count toward the requested attempt limit and produce a nonzero final status
- Unavailable attempts reset sustained-pressure continuity instead of allowing a sustained label to bridge a sampling gap
- Parent-child attribution, cross-source metric joins, and every single-instance run are bound to creation-time identity so reused PIDs cannot silently inherit a Chrome tree or trend
- Total private-memory growth now compares the full selected scope, including child-process churn, only while the exact root identity set remains unchanged
- Available-memory and commit thresholds are classified from raw ratios and rounded only for display
- The cleanup companion scans only the Chrome window where its popup is open, labels incognito candidates, and includes keyboard and screen-reader focus handling
- Release archives use deterministic ZIP records across Windows PowerShell 5.1 and PowerShell 7, reject reparse-point path escapes, and stage outputs before replacing the final package
- The CI matrix uses a supported job-level shell selector while retaining Windows PowerShell 5.1 and PowerShell 7 coverage
- CI runs the release verifier and analyzes its PowerShell source under both matrix runtimes

### Security

- The core watcher remains read-only, network-free, file-write-free, and process-control-free
- The companion has no required permissions, host permissions, content scripts, background worker, network access, telemetry, or tab-closing API
- The optional `tabs` permission is requested only from a user gesture and is used only to display titles and URLs

## [0.1.0] - 2026-08-28

### Added

- Read-only monitoring of one Chrome browser process tree in the current Windows session
- System RAM, commit, paging, summed working-set, private-bytes, and CPU measurements
- Instance discovery and explicit selection by root browser PID
- One-shot terminal and versioned JSON output
- Retry behavior for continuous monitoring when Chrome data is temporarily unavailable
- Static safety and process-tree tests for Windows PowerShell 5.1 and PowerShell 7
