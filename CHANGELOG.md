# Changelog

All notable changes to Chrome RAM Watch are recorded here.

The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-08-28

### Added

- Read-only monitoring of one Chrome browser process tree in the current Windows session
- System RAM, commit, paging, summed working-set, private-bytes, and CPU measurements
- Instance discovery and explicit selection by root browser PID
- One-shot terminal and versioned JSON output
- Retry behavior for continuous monitoring when Chrome data is temporarily unavailable
- Static safety and process-tree tests for Windows PowerShell 5.1 and PowerShell 7
