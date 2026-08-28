## Summary

Describe the problem and the behavior changed.

## Verification

- [ ] Windows PowerShell 5.1 static tests pass
- [ ] PowerShell 7 static tests pass
- [ ] Companion JavaScript and manifest safety tests pass
- [ ] Release archive integrity and reproducibility tests pass
- [ ] PSScriptAnalyzer reports no warnings or errors
- [ ] Live output was tested read-only, if this change affects collection

## Safety and privacy

- [ ] The PowerShell watcher remains read-only, file-write-free, process-control-free, and network-free
- [ ] Manual discard remains exact-ID-bound, separately confirmed, and immediately revalidated
- [ ] Automatic discard remains disabled by default, explicitly consented, pressure-gated, cooldown-bound, capped, exact-ID-bound, and immediately revalidated
- [ ] The companion does not close tabs, inject page code, use host permissions, use native messaging, use synced storage, control processes, or use the network
- [ ] The watcher does not emit raw Chrome command lines or page URLs; any displayed executable path is documented
- [ ] The companion does not persist or transmit titles, URLs, page contents, incognito metadata, raw errors, or browsing history
- [ ] Any automatic local state or journal remains bounded, sanitized, and documented
- [ ] Any optional tab-title or URL display and its runtime permission are documented
- [ ] New data collection or output is documented
