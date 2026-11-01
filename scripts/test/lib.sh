# Shared helpers for scripts/test/*.sh: run a test copy of Brim, talk to it, check its state.
# Sourced, not run.
SCRATCH=${SCRATCH:-$HOME/Library/Caches/brim-build}
REPORT=${REPORT:-$SCRATCH/test-reports/$(date +%Y-%m-%d_%H%M)}
TEST_APP=$SCRATCH/test.noindex/Brim.app
TOOLS=$SCRATCH/tools
BRIMCTL=$TOOLS/brimctl
STATE=$SCRATCH/snapshots/state.json
DOMAIN=com.andrespaladino.brim
# The test copy listens on its own socket, so real Claude Code and Codex sessions on this Mac
# (whose hooks use the normal one) don't send it alerts in the middle of a scenario.
export BRIM_SOCKET=$SCRATCH/test.sock
mkdir -p "$REPORT" "$TOOLS"
PASS=0; FAIL=0; KNOWN=0; FAILED=()

ensure_tools() {
  [[ -x $BRIMCTL && scripts/dev/brimctl.swift -ot $BRIMCTL ]] || swiftc scripts/dev/brimctl.swift -o $BRIMCTL 2>/dev/null
}

ctl() { $BRIMCTL "$@"; }

# Reads the app state (JSON) and prints one field with jq syntax, e.g. st .windows[0].mode
st() {
  rm -f $STATE
  ctl state
  for _ in {1..100}; do [[ -s $STATE ]] && break; sleep 0.02; done
  jq -r "$1" $STATE 2>/dev/null
}

# expect <description> <jq expression> <expected value>
expect() {
  local got; got=$(st "$2")
  if [[ "$got" == "$3" ]]; then PASS=$((PASS+1)); print "  ✓ $1"
  else FAIL=$((FAIL+1)); FAILED+=("$SCENARIO: $1 (got '$got', want '$3')"); print "  ✗ $1: got '$got', want '$3'"; fi
}

# Like expect, for a bug already known: failing is reported but doesn't fail the run.
expect_known() {
  local got; got=$(st "$3")
  if [[ "$got" == "$4" ]]; then PASS=$((PASS+1)); print "  ✓ $2 (known bug $1 no longer reproduces)"
  else KNOWN=$((KNOWN+1)); print "  ⚠ $2: got '$got', want '$4' [known: $1]"; fi
}

# eventually <jq expression> <value> [timeout s]: waits until the state matches.
eventually() {
  local deadline=$(( $(date +%s) + ${3:-5} ))
  while (( $(date +%s) <= deadline )); do [[ "$(st "$1")" == "$2" ]] && return 0; sleep 0.1; done
  return 1
}

scenario() { SCENARIO=$1; print -P "\n%B▶ $1%b"; }

app_pid() { pgrep -f "$TEST_APP/Contents/MacOS/Brim" | head -1; }

# Quits the installed Brim (remembering it was running), saves the preferences, starts the test copy.
start_test_app() {
  # Only the first start records the user's state; restarts after a crash keep it.
  if [[ -z ${WAS_RUNNING:-} ]]; then
    defaults export $DOMAIN "$REPORT/prefs-backup.plist"
    WAS_RUNNING=false
    if pgrep -xq Brim && ! pgrep -f "$TEST_APP" >/dev/null; then WAS_RUNNING=true; fi
  fi
  pkill -x Brim 2>/dev/null; sleep 0.5
  defaults write $DOMAIN debugTools -bool YES
  defaults write $DOMAIN onboardingDone -bool YES
  open -g -n --env BRIM_SOCKET="$BRIM_SOCKET" "$TEST_APP" --args ${=TEST_APP_ARGS:-}
  for _ in {1..50}; do [[ -n $(app_pid) ]] && break; sleep 0.1; done
  sleep 1.5
  [[ -n $(app_pid) ]] || { echo "test app did not start"; return 1; }
}

# Stops the test copy, restores preferences, reopens the installed Brim if it was running.
stop_test_app() {
  pkill -f "$TEST_APP/Contents/MacOS/Brim" 2>/dev/null; sleep 0.5
  [[ -f "$REPORT/prefs-backup.plist" ]] && defaults import $DOMAIN "$REPORT/prefs-backup.plist"
  if [[ ${WAS_RUNNING:-false} == true ]]; then open -g /Applications/Brim.app; fi
}

summary() {
  print "\n$PASS passed, $FAIL failed, $KNOWN known bugs reproduced"
  for f in $FAILED; do print -r -- "  ✗ $f"; done
  { print -r -- "## $1"; print -r -- "$PASS passed, $FAIL failed, $KNOWN known"; for f in $FAILED; do print -r -- "- ✗ $f"; done } >> "$REPORT/summary.md"
  (( FAIL == 0 ))
}
