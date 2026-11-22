# BobTV Windows preference storage patch

Baseline: pub.dev `shared_preferences_windows` 2.4.1, with its original BSD license.
The app resolves this package through a path override.

The upstream writer encodes the full preference map and calls
`File.writeAsStringSync` on Flutter's UI isolate. On the Windows test machine,
an approximately 0.8 MB preference file took about 2.4 seconds per write.
Repeated session saves during preview promotion accumulated roughly 10 seconds
before the next UI frame, while native player ownership moved in milliseconds.

The writer now snapshots each update before yielding and serializes asynchronous
staged writes and replacements by preference filename. A completed, flushed
snapshot replaces the old file, so concurrent readers never observe a
partially rewritten document. Transient Windows sharing locks are retried. Every mutation still completes
with the result of its own write. A failed operation does not prevent later
snapshots from being saved. Normal Windows shutdown drains pending writes before
closing the Flutter engine. The preference format and existing data are retained.

The client also avoids saving unchanged session fields. The regression tests use
controlled disk futures to check responsiveness, snapshot ordering, failure
recovery, clear ordering and shutdown draining.
