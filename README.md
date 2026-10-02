# Entropy History

Local, per-file history for Markdown notes: versions, verified content, diff,
blame, restore and branch reconciliation. Works over an ordinary folder.
No sync service, daemon, server, account or Dart runtime is required by the plugin.

## Install in Obsidian with BRAT

In BRAT, choose **Add a beta plugin** and enter `kltsv/entropy-hist`.
Enable **Entropy History**. On first history operation it downloads the native
engine for your machine from the matching release, verifies SHA-256 and caches
it outside the vault (`~/.entropy-hist/engines/<version>/`). Subsequent use works
offline. Supported hosts: macOS and Linux x64/arm64, Windows x64.

Use the history ribbon or commands to record, inspect and restore versions.
Automatic recording of saved edits is opt-in in plugin settings. Existing
`.hist/` history is shared with the standalone CLI and the Sync daemon.
An offline platform ZIP can also be built with `npm run package`.

## Standalone CLI and library

`packages/entropy_hist` is a pure Dart package with no dependency on Entropy Sync.
Release assets `hist-<platform>-<arch>` provide the standalone `hist` CLI.
Run `hist --help` for recording, log/show/diff/blame/restore/merge/status.
`hist-bridge-*` is the structured engine used by the Obsidian plugin.

## Develop

```sh
npm ci
cd packages/entropy_hist
dart pub get
dart analyze
dart test
cd ../..
python3 compile.py
python3 -m unittest discover -s tool/test
npm test
npm run build
npm run release:native
```

`npm test` builds a real native bridge and exercises it through plugin logic
and DOM-backed Obsidian API mocks. Full Obsidian UI verification is separate.
The project checker in `tool/spec_graph.py` also validates specs imported by
other products, without copying their source of truth.

## Release

Set matching `manifest.json` and `package.json` versions; push an equal tag
(e.g. `0.1.0`). CI verifies each native platform and attaches three BRAT files,
the bridge and CLI binaries, and `SHA256SUMS`. Never replace binaries under an
existing tag: publish a new version so embedded checksums stay authoritative.

MIT licensed. Dependency licenses remain their respective owners'.
