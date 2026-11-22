# Prepared preview handoff validation, 2026-11-22

Ready channel previews transfer their existing decoder and controller to the
main viewport. A rapid second click also reuses the prepared or active player.
Explicit replacement routes still use the existing route-selection path.

The handoff's asynchronous native volume commands operate on their owned mpv
cores without entering media_kit's process-wide player lock. An unrelated
decoder's stop/disposal can hold that lock while waiting for native work.
Retirement checks, selection-generation checks, audio muting order and native
property acknowledgements remain in place.

The existing media_kit 1.2.6 fork is now the resolved application dependency.
After callback/render teardown and the upstream grace period, it terminates
detached native cores in a worker isolate. Its disposal future includes that
termination; the resource registry continues tracking timed-out callers.

## Windows x64 comparison

The same compiled native runner, engine, video plugin and red/green AVI inputs
were used with separate AOT snapshots. The baseline application sources came
from public 1.4.2+2, commit `5971ad5ebe424c56d50922fbea3aef1c45d4729b`.
The diagnostic fixture holds the real SDK player lock during the third handoff,
representing another decoder's unfinished stop/disposal.

- Baseline: first two handoffs succeeded; the contended handoff failed after
  2,002,085 microseconds. The fixture exited with its expected failure code 2.
- Fixed: all six handoffs reused their decoder/controller. Measured visible
  handoff times were 28.864, 33.063, 31.774, 34.047, 52.043 and 36.158 ms.
- During the held-lock handoff, the service committed in 2.579 ms and the new
  main video pixels appeared in 31.774 ms.
- Maximum event-loop heartbeat gap was 51 ms. Final resource count was zero,
  including completion of detached native core termination. Exit code was 0.
- The Windows blocking-C disposal regression and related ownership/resource
  tests passed, 14 tests. Related local Flutter regressions also passed.

These are controlled, silent local-media tests on the affected Windows PC.
They reproduce shared-lock contention, and do not establish internet stream
startup latency or audible continuity for every station. No new public package
was published by this validation.

## Diagnostic launch isolation

Set a fresh `LOCALAPPDATA` directory before launching any diagnostic runner.
The native update bootstrap executes before Dart, even when a diagnostic Dart
entry point supplies its own log directory. Give `MaterialApp` the same unique
window title as the native fixture so pixel checks identify its own window.

Final comparison receipts are `baseline4-presentation.jsonl` and
`fixed3-presentation.jsonl` in the local output directory
`BobTV-preview-fast-20261122`. Earlier startup/isolation attempts are excluded.
The normal 1.4.2+2 installation's executable/AOT hashes and process were checked;
its test-affected startup counter was restored and its installation retained.
