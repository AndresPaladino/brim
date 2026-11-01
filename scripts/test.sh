#!/bin/zsh
# Brim's test battery. One entry point for every level; reports go to
# ~/Library/Caches/brim-build/test-reports/<date>/.
# Usage: scripts/test.sh <level> [swift test args]
#   fast     unit, contract and fuzz tests (swift test), under a minute
#   visual   renders every island state and compares with Tests/Snapshots (--record to accept)
#   e2e      scenarios on a running test copy of Brim (scripts/test/e2e)
#   perf     CPU, wakeups, memory and leaks (scripts/test/perf)
#   chaos    kills, corrupt config, second instance (scripts/test/chaos.sh)
#   release  checks a dist build: architectures, signature, version, appcast
#   static   strict concurrency warnings and sanitizers
#   all      everything except the 12 h soak
set -uo pipefail
cd "${0:A:h}/.."
export BRIM_ROOT=$PWD
export SCRATCH="$HOME/Library/Caches/brim-build"
export REPORT="${BRIM_REPORT:-$SCRATCH/test-reports/$(date +%Y-%m-%d_%H%M)}"
mkdir -p "$REPORT"
# The Command Line Tools sometimes fail to find Swift Testing's macro plugin ("plugin for module
# 'TestingMacros' not found"). Loading it explicitly avoids that.
PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
SWIFT_TEST=(swift test --scratch-path "$SCRATCH")
[[ -f $PLUGIN ]] && SWIFT_TEST+=(-Xswiftc -load-plugin-library -Xswiftc $PLUGIN)

level=${1:-fast}; shift 2>/dev/null
rc=0

run_fast() {
  echo "== fast: swift test"
  "${SWIFT_TEST[@]}" "$@" 2>&1 | grep -v "ld: warning" | tee "$REPORT/fast.log" | grep -aE "error:|􀢄|✘|passed after|failed after|known issue|Test run" | grep -avE "^\[|Test .* passed after" | cut -c1-300
  [[ ${pipestatus[1]} -eq 0 ]] || rc=1
}

case $level in
  fast) run_fast "$@" ;;
  visual) scripts/test/visual.sh "$@" || rc=1 ;;
  e2e) scripts/test/e2e.sh "$@" || rc=1 ;;
  perf) scripts/test/perf.sh "$@" || rc=1 ;;
  chaos) scripts/test/chaos.sh "$@" || rc=1 ;;
  release) scripts/test/release-check.sh "$@" || rc=1 ;;
  static) scripts/test/static.sh "$@" || rc=1 ;;
  all)
    run_fast
    for s in visual e2e chaos perf static; do scripts/test/$s.sh || rc=1; done
    ;;
  *) echo "unknown level: $level"; exit 2 ;;
esac
echo "Report: $REPORT"
exit $rc
