---
implements: vault_folder
spec-digest: 69c39ec64a8d5a1f6d65773daf3fe2968c79ee70a7a2ecdfb00297025a87365b
---

The exclusion engine half of `vault_folder` (R7, *Ignore files nest*): one
matcher compiling every source — a configured list and ignore files at any
depth — through the documented gitignore subset, plus the ignore-file tree a
host feeds from its own walk. Lives in the core so the standalone history CLI
and the daemon's folder service share one engine, never two.
