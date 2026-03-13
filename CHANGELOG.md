# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses Semantic Versioning for public releases.

## [0.1.0] - 2026-03-13

### Added

- Native macOS host/client transport scaffold for `mock`, `display-jpeg`, and `bridge-jpeg` modes.
- Authenticated bridge ingest service with TCP control and UDP chunk transport.
- Bridge simulator reconnect logic, keepalive handling, file/directory JPEG sources, and local TCP JPEG ingest.
- Portable `macvr-jpeg-sender` helper for pushing JPEG frames into the bridge seam.
- Wine helper scripts for prefix setup, Steam launch, and Windows sender cross-build.
- Public release metadata including version file, MIT license, dependency list, third-party notices, and release notes.

### Changed

- Cleaned repository metadata for public publishing.
- Improved CLI release metadata with `--version` support.
- Reworked README for installation, usage, limitations, and compliance details.

### Fixed

- Bridge simulator reconnect handling after host restarts.
- Host stale-frame dropping for disconnected bridge producers.
- Client control-channel reconnect behavior after host restarts.
