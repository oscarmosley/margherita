Watch folders safety verification

Outputs always go into .Margherita Outputs beneath the selected destination.
UI must display this actual output path. Hidden inputs are not enumerated and
explicit roots with hidden ancestors, including the reserved directory, are refused.
This exclusion does not depend on successful ledger persistence.

Failed conversions are not marked consumed. Retries back off from 2 seconds
to at most 300 seconds. Successful nonempty output with no notes is persisted.

Opt-in original cleanup first renames into a private UUID recovery folder beneath
.Margherita Recovery on the watched root volume. A captured replacement is never
trashed if device, inode, size or nanosecond mtime differs. Rename changes ctime,
so post-rename ctime cannot be compared to the pre-rename sample. A mismatched
candidate is restored to a unique non-overwriting recovered name. Errors leave it
in recovery and update observable status. Keep-original remains the default.

The FSEvents context owns its flag through retain/release callbacks.

Run python3 -m unittest Tests.test_watch_folders for compiled portable tests.
Run Tests/test_watch_folders_mac.sh on a Mac for native integration.
Linux policy and parser tests are not a native macOS build or race proof.
Hostile concurrent directory replacement and writers holding open source file
descriptors are not fully preventable with stat-and-path APIs.
