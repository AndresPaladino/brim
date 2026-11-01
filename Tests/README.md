# Tests

`scripts/test.sh <level>` runs one level of the battery. Reports, logs, renders and metrics go to
`~/Library/Caches/brim-build/test-reports/<date>/`.

| Level | What it checks | Time |
|---|---|---|
| `fast` | Logic, socket protocol, hook installers, hook scripts, localization, fuzzing (`swift test`) | ~10 s |
| `visual` | Every island state rendered in English and Spanish, compared with `Tests/Snapshots` | ~30 s |
| `e2e` | Scenarios on a running test copy, through `brimctl` and the real hook scripts | ~2 min |
| `perf` | CPU, wakeups, energy, memory, leaks and launch time per situation | ~8 min |
| `chaos` | Killed bridge, frozen app, huge payloads, deleted socket, second instance | ~1 min |
| `static` | Warnings, strict concurrency, Thread and Address Sanitizer | ~10 min |
| `release` | The build in `dist/`: architectures, signatures, versions, appcast, Rosetta | ~10 s |
| `all` | Everything above except `release` | ~25 min |

`e2e`, `perf` and `chaos` quit the installed Brim while they run, restore its preferences and reopen it.
Keep the mouse away from the notch while they run.

Other tools:

- `scripts/test/soak.sh [hours] [--without-brim]`: long run on the installed Brim with CPU, wakeups,
  memory and battery every minute. Run it once with Brim and once without to see its battery cost.
- `scripts/test/visual.sh --record`: accept the current renders as the new reference after a
  deliberate visual change. Look at the gallery first.
- `BRIM_FUZZ=10000 BRIM_SEED=<n> scripts/test.sh fast --filter Fuzz`: longer or replayed fuzzing.
- `Tests/MANUAL.md`: checks that need real hardware.

Known bugs are kept as tests that fail today, wrapped in `withKnownIssue` (or reported as "known" by
the shell scripts), so the battery stays green. When one is fixed, its test starts passing and Swift
Testing flags the known issue as no longer happening: remove the wrapper then.
