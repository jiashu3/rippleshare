# RippleShare · by RippleLab

**A bridge between your Mac and your servers.**

RippleShare is an open-source native macOS file client from [RippleLab](https://www.ripplelab.hk). Browse your Mac and a server side by side, drag files between them, and disconnect whenever you want. No Finder mounts or automatic reconnection.

## Developer preview

Version 0.1 implements connection bookmarks, file browsing, hidden-file visibility, filtering, directory creation, renaming, drag-and-drop transfers, and a persistent transfer queue. Whole directories include hidden files, empty folders, and symbolic links.

Transfers use OpenSSH and rsync 3+. They land in a task-owned staging directory, undergo a checksum dry run, then publish with an exclusive rename. Existing destinations are never overwritten. Interrupted jobs retain partial data and can be resumed or cleaned up explicitly.

## Requirements

- macOS 13 or newer, Apple Silicon or Intel, and rsync 3+ (`brew install rsync`).
- A Linux or macOS server with SSH shell access, Python 3.8+, and rsync 3+.
- SSH key / agent authentication and a previously verified host key in your SSH known-hosts configuration.

Pure SFTP accounts and password prompts are not supported yet. Encrypted keys must be loaded into ssh-agent. The first-run connection editor provides a copyable SSH command for verifying the host in Terminal.

## Build

On a Mac with Swift 5.9+ and Xcode command line tools:

```sh
swift test
swift run RippleShare
bash scripts/build-app.sh
```

The packaging script creates a universal app and ZIP in `dist/`. CI builds downloadable artifacts. The preview is ad-hoc signed, **not Developer ID signed or notarized**.

On Linux, `swift test` exercises the core; `python3 -m unittest discover -s tests -v` tests the remote helper and transfer behavior. SwiftUI requires macOS.

## Boundaries

This release transfers directories through rsync, not an archive bundle. Retry rescans the source and reuses available files / partial data. It does not snapshot a changing source. Preserve important source trees unchanged during a transfer.

Contents, permissions, modification times, and symlinks are preserved. Owners, ACLs, extended attributes, Finder metadata, resource forks, and hard-link relationships are not guaranteed. Special files are rejected. Existing destination names require a different destination or a manual rename. Space checks on retries are conservative.

No accounts, telemetry, or cloud relay. Connection and task metadata stay in `~/Library/Application Support/RippleShare/`. Passwords and private keys are not stored by the app. MIT licensed; OpenSSH and rsync are external tools with their own licenses.
