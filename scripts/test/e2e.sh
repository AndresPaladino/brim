#!/bin/zsh
# End-to-end scenarios on a running test copy of Brim, driven through brimctl and the real hook scripts.
# Quits the installed Brim while it runs and restores it (and its preferences) at the end.
# Keep the mouse away from the notch: hovering opens the island and changes what the scenarios see.
# Usage: scripts/test/e2e.sh [scenario name filter]
set -uo pipefail
cd "${0:A:h}/../.."
source scripts/test/lib.sh
FILTER=${1:-}
scripts/build.sh --test >/dev/null 2>&1 || { echo "build failed"; exit 1; }
ensure_tools
HOOK=$TEST_APP/Contents/Resources/claude-hook.sh
OUT=$REPORT/e2e; mkdir -p $OUT
start_test_app || exit 1
trap stop_test_app EXIT

want() { [[ -z $FILTER || $1 == *$FILTER* ]]; }
reset() {
  ctl leave; ctl music off; ctl rec off; ctl autoanswer off
  for s in $(st '.claudeSession // empty'); do print -r -- "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$s\"}" | $HOOK; done
  sleep 0.3
}
# Sends a hook event in the background; its output lands in $OUT/<name>.out.
hook() { print -r -- "$2" | $HOOK > $OUT/$1.out 2>/dev/null & }

if want hud; then scenario "HUD shows and hides"
  reset
  ctl hud volume 0.5; sleep 0.2
  expect "HUD up" '.windows[0].mode' hud
  sleep 1.8
  expect "HUD gone after 1.6 s" '.hud' null
fi

if want music; then scenario "HUD over music, then back"
  reset
  ctl music on; sleep 0.4
  expect "ears with music" '.windows[0].mode' compact
  ctl hud brightness 0.8; sleep 0.2
  expect "HUD wins" '.windows[0].mode' hud
  sleep 1.8
  expect "music ears come back" '.windows[0].mode' compact
  ctl hover; sleep 0.4
  expect "player opens" '.windows[0].mode' media
  ctl leave; ctl music off; sleep 0.4
  expect "nothing left" '.windows[0].mode' idle
fi

if want permission; then scenario "Permission through the real hook, charge on top"
  reset
  hook perm '{"hook_event_name":"PermissionRequest","session_id":"e2e-perm","cwd":"/tmp/brim","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  eventually .claude permission 5
  expect "ear shows the request" '.windows[0].mode' claudeEar
  expect "answerable" '.claudeAnswerable' true
  ctl charge plugged; sleep 0.3
  expect "charge face covers it" '.windows[0].mode' charge
  sleep 3.4
  expect "request comes back" '.windows[0].mode' claudeEar
  ctl answer allow; sleep 0.8
  wait
  expect "alert gone after answering" '.claude' null
  grep -q '"allow"' $OUT/perm.out && { PASS=$((PASS+1)); print "  ✓ hook printed allow"; } || { FAIL=$((FAIL+1)); FAILED+=("permission: hook output $(cat $OUT/perm.out)"); print "  ✗ hook output: $(cat $OUT/perm.out)"; }
fi

if want question; then scenario "Question answered from the notch"
  reset
  hook q '{"hook_event_name":"PermissionRequest","session_id":"e2e-q","cwd":"/tmp/brim","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one?","multiSelect":false,"options":[{"label":"Red","description":""},{"label":"Blue","description":""}]}]}}'
  eventually .claude question 5
  ctl hover; sleep 0.4
  expect "drop opens" '.windows[0].mode' claude
  ctl choose Blue; sleep 1.2
  wait
  grep -q '"Pick one?":"Blue"' $OUT/q.out && { PASS=$((PASS+1)); print "  ✓ hook got the answer"; } || { FAIL=$((FAIL+1)); FAILED+=("question: $(cat $OUT/q.out)"); print "  ✗ hook output: $(cat $OUT/q.out)"; }
  expect "closed after answering" '.windows[0].open' false
fi

if want recording; then scenario "Recording, Claude and music at once"
  reset
  ctl music on; ctl rec on
  hook wait1 '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"e2e-rec","cwd":"/tmp/brim"}'
  sleep 0.5
  expect "recording owns the ears" '.windows[0].mode' recording
  ctl click; sleep 0.4
  expect "click opens Claude's drop" '.windows[0].mode' claude
  ctl leave; sleep 0.3
  expect "back to the timer" '.windows[0].mode' recording
  ctl rec off; sleep 0.3
  expect "Claude ear after recording" '.windows[0].mode' claudeEar
  hook end1 '{"hook_event_name":"SessionEnd","session_id":"e2e-rec","cwd":"/tmp/brim"}'; sleep 0.4
  expect "music ears after SessionEnd" '.windows[0].mode' compact
fi

if want stop-music; then scenario "Music stops while a permission is open"
  reset
  ctl music on
  hook perm2 '{"hook_event_name":"PermissionRequest","session_id":"e2e-pm","cwd":"/tmp/brim","tool_name":"Bash","tool_input":{"command":"ls"}}'
  eventually .claude permission 5
  ctl hover; sleep 0.4
  expect "permission drop open" '.windows[0].mode' claude
  ctl music off; sleep 0.4
  expect "drop stays open when music stops" '.windows[0].mode' claude
  ctl answer deny; sleep 0.8; wait
fi

if want boop; then scenario "Boop and annoyed boop"
  reset
  ctl click; sleep 0.15
  expect "boop" '.boop' boop
  ctl click; sleep 0.1; ctl click; sleep 0.15
  expect "third click is annoyed" '.boop' annoyed
  sleep 2.2
  expect "face leaves" '.boop' null
fi

if want frames; then scenario "Animations stop drawing when done"
  reset
  ctl charge plugged; sleep 2.0
  ctl stats reset; sleep 1.0
  frames=$(st .frames.face)
  print "  face frames drawn between 2.0 s and 3.0 s: $frames"
  echo "e2e.face_frames_after_animation	$frames" >> $REPORT/metrics.tsv
  if (( frames < 10 )); then PASS=$((PASS+1)); print "  ✓ face idle after its animation"
  else FAIL=$((FAIL+1)); FAILED+=("frames: face drew $frames frames after its animation"); print "  ✗ face keeps redrawing after its animation ends"; fi
  sleep 1
  hook wait2 '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"e2e-fr","cwd":"/tmp/brim"}'
  sleep 40
  ctl stats reset; sleep 10
  frames=$(st .frames.critter)
  print "  critter frames between 40 s and 50 s: $frames"
  echo "e2e.critter_frames_idle	$frames" >> $REPORT/metrics.tsv
  (( frames == 0 )) && { PASS=$((PASS+1)); print "  ✓ critter idle"; } || { FAIL=$((FAIL+1)); FAILED+=("frames: critter drew $frames frames while idle"); print "  ✗ critter still drawing"; }
  hook end2 '{"hook_event_name":"SessionEnd","session_id":"e2e-fr","cwd":"/tmp/brim"}'
fi

if want parallel; then scenario "Two permission requests in one session (subagents)"
  reset
  hook pa '{"hook_event_name":"PermissionRequest","session_id":"e2e-par","cwd":"/tmp/brim","tool_name":"Bash","tool_input":{"command":"first"}}'
  sleep 0.5
  hook pb '{"hook_event_name":"PermissionRequest","session_id":"e2e-par","cwd":"/tmp/brim","tool_name":"Bash","tool_input":{"command":"second"}}'
  sleep 0.8
  ctl answer allow; sleep 0.8   # the newest first
  ctl answer deny; sleep 0.8; wait
  print "  first hook output: '$(cat $OUT/pa.out | head -c 80)'  second: '$(cat $OUT/pb.out | head -c 80)'"
  if grep -q '"deny"' $OUT/pa.out && grep -q '"allow"' $OUT/pb.out; then PASS=$((PASS+1)); print "  ✓ both requests answered from the notch"
  else FAIL=$((FAIL+1)); FAILED+=("parallel: first '$(cat $OUT/pa.out)', second '$(cat $OUT/pb.out)'"); print "  ✗ not both answered"; fi
fi

if want crash; then scenario "Two questions pending in one session"
  reset
  pid=$(app_pid)
  hook qa '{"hook_event_name":"PermissionRequest","session_id":"e2e-crash","cwd":"/tmp/brim","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"First?","options":[{"label":"A"},{"label":"B"}]}]}}'
  sleep 0.5
  hook qb '{"hook_event_name":"PermissionRequest","session_id":"e2e-crash","cwd":"/tmp/brim","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Second?","options":[{"label":"C"},{"label":"D"}]}]}}'
  sleep 1.5
  if kill -0 $pid 2>/dev/null; then PASS=$((PASS+1)); print "  ✓ still running"; ctl answer deny; sleep 0.8; ctl answer deny
  else FAIL=$((FAIL+1)); FAILED+=("crash: Brim crashed with two questions in one session"); print "  ✗ Brim crashed"
    log show --last 1m --predicate 'process == "Brim"' --style compact 2>/dev/null | grep -iE "fatal|crash|exclusiv|index" | head -3 | sed 's/^/    /'
    ls -t ~/Library/Logs/DiagnosticReports/Brim* 2>/dev/null | head -1 | sed 's/^/    crash report: /'
    start_test_app >/dev/null; fi
  wait
fi

summary "e2e"
