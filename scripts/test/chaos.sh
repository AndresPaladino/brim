#!/bin/zsh
# Robustness: what happens when things around Brim break. Runs on the test copy and restores the
# installed Brim at the end.
# Usage: scripts/test/chaos.sh [scenario filter]
set -uo pipefail
cd "${0:A:h}/../.."
source scripts/test/lib.sh
FILTER=${1:-}
want() { [[ -z $FILTER || $1 == *$FILTER* ]]; }
scripts/build.sh --test >/dev/null 2>&1 || { echo "build failed"; exit 1; }
ensure_tools
HOOK=$TEST_APP/Contents/Resources/claude-hook.sh
SOCK=$BRIM_SOCKET
start_test_app || exit 1
trap stop_test_app EXIT
alive() { kill -0 $(app_pid) 2>/dev/null; }
check_alive() { alive && { PASS=$((PASS+1)); print "  ✓ still running"; } || { FAIL=$((FAIL+1)); FAILED+=("$SCENARIO: Brim died"); print "  ✗ Brim died"; start_test_app >/dev/null; }; }
claude_works() { # clears any alert, sends a Stop event with a fresh session and checks that one shows
  local id=chaos-$RANDOM
  for s in $(st '.claudeSession // empty'); do print -r -- "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$s\"}" | $HOOK; done
  sleep 0.3
  print -r -- "{\"hook_event_name\":\"Stop\",\"session_id\":\"$id\",\"cwd\":\"/tmp/brim\",\"last_assistant_message\":\"ok\"}" | $HOOK
  sleep 0.4; [[ $(st .claudeSession) == $id ]]
}

if want bridge; then scenario "Now Playing bridge killed repeatedly"
  for i in {1..6}; do
    p=$(st .bridgePID)
    [[ $p -gt 0 ]] && kill -9 $p
    sleep 2.6   # the app waits 2 s before relaunching
  done
  check_alive
  eventually '.bridgePID > 0' true 6   # after five quick crashes it waits longer (4 s), but never gives up
  expect "bridge relaunched after the 6th crash" '.bridgePID > 0' true
  ctl media toggle; sleep 0.3   # writing to a dead bridge must not raise SIGPIPE
  check_alive
fi

if want stopped; then scenario "App frozen for 5 s while a hook waits"
  print -r -- '{"hook_event_name":"PermissionRequest","session_id":"frz","cwd":"/tmp/brim","tool_name":"Bash","tool_input":{"command":"ls"}}' | $HOOK > $REPORT/frz.out &
  sleep 0.5; kill -STOP $(app_pid); sleep 5; kill -CONT $(app_pid); sleep 0.5
  expect "request still shows" .claude permission
  ctl answer allow; wait
  grep -q allow $REPORT/frz.out && { PASS=$((PASS+1)); print "  ✓ answer delivered after the freeze"; } || { FAIL=$((FAIL+1)); FAILED+=("stopped: no answer"); print "  ✗ no answer"; }
fi

if want huge; then scenario "40 MB hook payload"
  perl -e 'print "{\"hook_event_name\":\"Stop\",\"session_id\":\"big\",\"last_assistant_message\":\"", "x" x (40*1024*1024), "\"}"' | $HOOK
  sleep 1
  check_alive
  expect "oversized event ignored" .claudeSession null
  sleep 0.5; claude_works && { PASS=$((PASS+1)); print "  ✓ next event works"; } || { FAIL=$((FAIL+1)); FAILED+=("huge: events stopped working"); print "  ✗ events stopped"; }
fi

if want idle-connections; then scenario "300 connections that never send a line"
  perl -MIO::Socket::UNIX -MTime::HiRes=usleep -e 'my (@s, $fail); for (1..300) { my $c = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $ARGV[0]); if ($c) { push @s, $c } else { $fail++ } usleep(2000) } print scalar(@s), " open, ", $fail // 0, " refused\n"; sleep 8' "$SOCK" > $REPORT/conns.out &
  sleep 2
  fds=$(lsof -p $(app_pid) 2>/dev/null | wc -l | tr -d ' ')
  claude_works && works=true || works=false
  wait
  print "  connections: $(cat $REPORT/conns.out 2>/dev/null) | Brim file descriptors while held: $fds"
  echo "chaos.idle_connections_fds	$fds" >> $REPORT/metrics.tsv
  $works && { PASS=$((PASS+1)); print "  ✓ real events still arrive"; } || { FAIL=$((FAIL+1)); FAILED+=("idle-connections: real events lost"); print "  ✗ real events lost while idle connections pile up"; }
  wait; sleep 1
  check_alive
fi

if want socket; then scenario "Socket file deleted while running"
  rm -f "$SOCK"
  ls -l "$SOCK" 2>/dev/null || print "  socket file gone"
  sleep 0.3
  claude_works && { PASS=$((PASS+1)); print "  ✓ alerts still work"; } || { FAIL=$((FAIL+1)); FAILED+=("socket: alerts stopped after the socket was deleted"); print "  ✗ alerts stopped"; }
fi

if want second; then scenario "A second Brim starts"
  open -g -n --env BRIM_SOCKET="$BRIM_SOCKET" "$TEST_APP"; sleep 2
  n=$(pgrep -f "$TEST_APP/Contents/MacOS/Brim" | wc -l | tr -d ' ')
  print "  instances running: $n"
  first=$(pgrep -f "$TEST_APP/Contents/MacOS/Brim" | head -1)
  pgrep -f "$TEST_APP/Contents/MacOS/Brim" | tail -n +2 | xargs kill 2>/dev/null; sleep 1
  (( n == 1 )) && { PASS=$((PASS+1)); print "  ✓ only one instance"; } || { FAIL=$((FAIL+1)); FAILED+=("second: $n instances ran at once"); print "  ✗ two instances ran at once"; }
  claude_works && { PASS=$((PASS+1)); print "  ✓ first instance still gets alerts"; } || { FAIL=$((FAIL+1)); FAILED+=("second: first instance lost its alerts"); print "  ✗ first instance lost its alerts"; }
fi

summary "chaos"
