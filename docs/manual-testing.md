# macOS acceptance checklist

Run on an actual Mac before calling a release ready for general use. Linux core tests do not establish UI behavior.

1. Build the app and launch from Finder. Confirm one native window and the app icon.
2. Add a reachable SSH server. Verify first-use host-key rejection, then verify the host in Terminal and reconnect.
3. Exercise agent authentication, a specific private key and an encrypted key already loaded in ssh-agent.
4. Add an offline server. Cancel connecting, delete its bookmark and confirm the rest of the UI remains usable.
5. Browse local / remote paths containing Chinese, spaces, quotes and newlines. Check hidden files, empty folders, symlink display and back navigation.
6. Upload and download a folder with 10,000 small files, a multi-GB file, empty directories and relative / broken symlinks. Compare checksums and counts independently.
7. Pause mid-file, quit the app, relaunch, explicitly resume and verify final checksums.
8. Disconnect the network during a transfer, reconnect and retry. Confirm no automatic retry storm.
9. Modify / remove a source file before verification. Confirm the task fails or retries and never silently publishes a known difference.
10. Create a same-name file / directory at the destination during transfer. Confirm it is preserved and staged data remains.
11. Test permission denied and low disk space at both endpoints. Confirm actionable errors and intact sources.
12. Clean an interrupted upload and download. Confirm only that task's staging tree is removed.
13. Drag from Finder into the remote pane, and from the remote pane into the local pane. Test multiselection using the transfer buttons.
14. Validate that leaving the app idle or reopening it does not mount volumes or initiate a connection.

Preview limitations: rsync 3 is an external dependency; password prompts and pure SFTP-only servers are not supported. The app is not notarized. UI checks above must not be marked passed solely because source compilation or unit tests pass.
