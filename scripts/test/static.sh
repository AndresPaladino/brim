#!/bin/zsh
# Compiler checks and sanitizers.
#   - warnings in the normal build and with complete strict concurrency (Swift 6 readiness)
#   - the unit tests under Thread Sanitizer and Address Sanitizer
# Usage: scripts/test/static.sh [--no-sanitizers]
set -uo pipefail
cd "${0:A:h}/../.."
SCRATCH=${SCRATCH:-$HOME/Library/Caches/brim-build}
REPORT=${REPORT:-$SCRATCH/test-reports/$(date +%Y-%m-%d_%H%M)}
mkdir -p $REPORT
PLUGIN=(-Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib)
rc=0
count() { sed "s/\x1b\[[0-9;]*m//g" $1 | grep -E "^/.*: warning:" | grep -v "ld: warning" | sort -u | wc -l | tr -d ' '; }

# Warnings only show when the module compiles, so drop its cached objects first.
rm -rf $SCRATCH/static-normal/out/Intermediates.noindex/Brim.build $SCRATCH/static-strict/out/Intermediates.noindex/Brim.build
echo "== warnings (normal build)"
swift build --scratch-path $SCRATCH/static-normal > $REPORT/warnings.log 2>&1
echo "  $(count $REPORT/warnings.log) warnings"

echo "== strict concurrency (complete)"
swift build --scratch-path $SCRATCH/static-strict -Xswiftc -strict-concurrency=complete > $REPORT/strict.log 2>&1
n=$(count $REPORT/strict.log)
echo "  $n warnings; most common:"
sed "s/\x1b\[[0-9;]*m//g" $REPORT/strict.log | grep -E "^/.*: warning:" | grep -v "ld: warning" | grep -oE "warning: [^']*" | sed -E 's/[0-9]+//g' | sort | uniq -c | sort -rn | head -6 | sed 's/^/   /'
echo "static.strict_concurrency_warnings	$n" >> $REPORT/metrics.tsv

if [[ "${1:-}" != --no-sanitizers ]]; then
  for san in thread address; do
    echo "== swift test --sanitize=$san"
    swift test --scratch-path $SCRATCH/san-$san --sanitize=$san "${PLUGIN[@]}" --skip "secondQuestionInTheSameSessionDoesNotCrash" > $REPORT/sanitize-$san.log 2>&1
    if grep -qE "WARNING: ThreadSanitizer|ERROR: AddressSanitizer" $REPORT/sanitize-$san.log; then
      rc=1; echo "  ✗ $san sanitizer reports:"; grep -E "WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY:" $REPORT/sanitize-$san.log | sort | uniq -c | head -8
    else
      echo "  ✓ clean ($(grep -aoE "Test run with [0-9]+ tests" $REPORT/sanitize-$san.log | tail -1))"
    fi
  done
fi
{ echo "## static"; echo "strict concurrency warnings: $n"; } >> $REPORT/summary.md
exit $rc
