# Architecture and transfer contract

## Components

- **RippleShare**: SwiftUI/AppKit desktop UI and main-actor application model.
- **RippleCore**: validated connection / path models, subprocess lifecycle, SSH protocol, persistence, staging and transfer engine. No third-party Swift packages.
- **remote.py**: Python standard-library helper passed through an authenticated SSH command. JSON input is base64 encoded; stdout is a JSON envelope. No permanent server process or installation.
- **OpenSSH + rsync 3**: encrypted transport, host identity checks, protected path arguments, checksummed incremental transfer.

## State machine

`queued → preparing → transferring → verifying → completed`

Any running state may become `paused` through cancellation or `failed` through an error. Both can return to `queued` through an explicit retry. Relaunch converts unfinished jobs to `paused`. The queue is serial. Disconnect pauses work and clears the remote browser. There is no startup connection or background reconnect loop.

## Destination staging

Each task creates `<destination>/.rippleshare-<UUID>/` with a private mode and an owner marker. Its `payload/` holds a single source basename. Partial files live under rsync's task-specific partial directory. Source files are never deleted.

Rsync checks content on retry and removes stale entries only inside the task's payload. A second checksum dry run, including deletion detection, must have no reported changes before completion. Publication uses Linux `renameat2(RENAME_NOREPLACE)` or macOS `renamex_np(RENAME_EXCL)` so a destination created after the precheck is not overwritten. Servers without these primitives cannot publish a transfer.

This is not a snapshot protocol. Files can change after the final verification. Databases and other actively written files need their own snapshot/export process. Verification is rsync's negotiated checksum over an authenticated channel, not a signed archival manifest. A connection loss after remote publication may leave an ambiguous task state; the app retains the error and does not overwrite or delete the resulting final directory.

## Security boundaries

SSH enforces known-host verification and disables agent forwarding. The app respects user-controlled SSH config; the app never inserts private material into the repository. Host/user input is validated before invoking SSH. Remote paths travel through rsync's protected-argument protocol; helper requests are JSON, not shell interpolation. Staging checks reject symlink substitution at the stage root, marker and payload. Symlink contents are preserved without recursion into their targets.

The server account and other processes running as that account are trusted. This is not protection against concurrent malicious mutation of every directory component by the same user. Filesystem permissions still govern all operations. Deleting a connection is local and does not delete server files; associated task history remains available for cleanup.

## Release boundaries

The first UI is Chinese. English documentation is included; interface localization, password/keychain login, archive acceleration, SFTP-only fallback, file promises for dragging downloads into Finder, signed/notarized distribution, and GUI automation remain subsequent work. Remote-to-local drag currently targets the app's local pane. System Finder is only used as an optional upload source or local folder picker.
