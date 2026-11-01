#!/bin/zsh
# CPU, wakeups, energy impact, memory and leaks of a test copy of Brim in typical situations.
# Each scenario measures Brim, its Now Playing bridge (perl) and WindowServer, which draws the island.
# Quits the installed Brim while it runs and restores it at the end.
# Usage: scripts/test/perf.sh [seconds per scenario, default 60] [scenario filter]
# For per-process energy in mW, run separately: sudo powermetrics --samplers tasks -i 5000 -n 12 | grep -E "Brim|perl"
set -uo pipefail
cd "${0:A:h}/../.."
source scripts/test/lib.sh
SECS=${1:-60}; FILTER=${2:-}
want() { [[ -z $FILTER || $1 == *$FILTER* ]]; }
scripts/build.sh --test >/dev/null 2>&1 || { echo "build failed"; exit 1; }
ensure_tools
HOOK=$TEST_APP/Contents/Resources/claude-hook.sh
CSV=$REPORT/perf.tsv
print "scenario\tseconds\tbrim_cpu_pct\tbridge_cpu_pct\twindowserver_cpu_pct\tbrim_wakeups_per_s\tbrim_energy\tfootprint_mb" > $CSV

# Cumulative CPU seconds of a process (ps reports [[hh:]mm:]ss.cc).
cpu() { ps -o time= -p $1 2>/dev/null | awk -F: '{ s=0; for (i=1;i<=NF;i++) s=s*60+$i; print s }'; }
bridge_pid() { pgrep -P $(app_pid) perl | head -1; }
ws_pid() { pgrep -x WindowServer | head -1; }
footprint_mb() { footprint -p $(app_pid) 2>/dev/null | awk '/phys_footprint:/ { v=$2; u=$3; if (u=="KB") v/=1024; if (u=="GB") v*=1024; print v; exit }'; }

# measure <name>: samples everything for $SECS seconds while the scenario runs in the background.
measure() {
  local name=$1 a=$(app_pid) b=$(bridge_pid) w=$(ws_pid)
  local a0=$(cpu $a) b0=$(cpu ${b:-0}) w0=$(cpu $w)
  # top's IDLEW is the total since launch, not per sample: the rate is the difference between the two samples.
  local toplines=$(top -l 2 -s $SECS -pid $a -stats pid,idlew,power 2>/dev/null | grep -E "^$a ")
  local a1=$(cpu $a) b1=$(cpu ${b:-0}) w1=$(cpu $w)
  local wake=$(echo $toplines | awk -v s=$SECS '{ gsub(/[^0-9]/, "", $2) } NR == 1 { w0 = $2 } NR == 2 { printf "%.2f", ($2 - w0) / s }')
  local power=$(echo $toplines | awk 'NR == 2 { print $3 }')
  local fp=$(footprint_mb)
  local ac=$(echo "$a0 $a1 $SECS" | awk '{ printf "%.3f", ($2-$1)/$3*100 }')
  local bc=$(echo "${b0:-0} ${b1:-0} $SECS" | awk '{ printf "%.3f", ($2-$1)/$3*100 }')
  local wc=$(echo "$w0 $w1 $SECS" | awk '{ printf "%.2f", ($2-$1)/$3*100 }')
  print "$name\t$SECS\t$ac\t$bc\t$wc\t$wake\t$power\t$fp" >> $CSV
  printf "  Brim %s%% CPU, %s wakeups/s, energy %s | bridge %s%% | WindowServer %s%% | footprint %s MB\n" $ac $wake $power $bc $wc $fp
  LAST_CPU=$ac; LAST_WAKE=$wake; LAST_WS=$wc
}

budget() { # budget <what> <value> <max>
  if (( $2 <= $3 )); then PASS=$((PASS+1)); print "  ✓ $1 $2 ≤ $3"
  else FAIL=$((FAIL+1)); FAILED+=("$SCENARIO: $1 $2 > $3"); print "  ✗ $1 $2 > $3"; fi
}

start_test_app || exit 1
trap stop_test_app EXIT
music_now=$(st .music)
[[ $music_now != null ]] && print "Note: something is playing ($music_now); idle numbers include it."
STARTUP_FP=$(footprint_mb)
print "Footprint after launch: $STARTUP_FP MB"
echo "perf.startup_footprint_mb	$STARTUP_FP" >> $REPORT/metrics.tsv

if want idle; then scenario "Idle (nothing happening)"
  ctl music off; ctl rec off; sleep 5   # past the launch work
  measure idle
  budget "Brim CPU %" $LAST_CPU 0.1
  budget "wakeups/s" $LAST_WAKE 1
  IDLE_WS=$LAST_WS
fi

if want music; then scenario "Music playing, ears visible (equalizer)"
  ctl music on; sleep 1
  measure music_visible
  budget "Brim CPU %" $LAST_CPU 0.5
  print "  WindowServer delta vs idle: $(echo "$LAST_WS ${IDLE_WS:-0}" | awk '{ printf "%.2f", $1-$2 }') points"
  ctl music off; sleep 1
fi

if want player; then scenario "Player open (scrubber ticking)"
  ctl music on; ctl hover; sleep 1
  measure player_open
  budget "Brim CPU %" $LAST_CPU 2
  ctl leave; ctl music off; sleep 1
fi

if want recording; then scenario "Screen recording indicator (1 s timer)"
  ctl rec on; sleep 1
  measure recording
  budget "Brim CPU %" $LAST_CPU 0.5
  ctl rec off; sleep 1
fi

if want claude; then scenario "Claude alert waiting in the ear (critter at rest)"
  print -r -- '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"perf","cwd":"/tmp/brim"}' | $HOOK
  sleep 35   # past the critter's 30 s idle animations
  measure claude_waiting
  budget "Brim CPU %" $LAST_CPU 0.1
  print -r -- '{"hook_event_name":"SessionEnd","session_id":"perf","cwd":"/tmp/brim"}' | $HOOK
  sleep 3
  measure after_claude
  # After the alert leaves, Brim goes back to idle wakeups.
  budget "wakeups/s after the alert" $LAST_WAKE 1
fi

if want stress; then scenario "Stress: 300 HUD steps, 100 alerts of each kind, 200 hook events"
  fp0=$(footprint_mb); c0=$(cpu $(app_pid))
  for i in {1..300}; do ctl hud volume $(( (i % 17) / 16.0 )); done
  for i in {1..100}; do ctl charge plugged; ctl device; ctl boop; ctl music on; ctl music off; done
  for i in {1..200}; do print -r -- "{\"hook_event_name\":\"Stop\",\"session_id\":\"p$i\",\"cwd\":\"/tmp/brim\",\"last_assistant_message\":\"Done $i\"}" | $HOOK; done
  sleep 12   # let every alert time out
  c1=$(cpu $(app_pid)); fp1=$(footprint_mb)
  print "  CPU spent: $(echo "$c0 $c1" | awk '{ printf "%.2f", $2-$1 }') s; footprint $fp0 → $fp1 MB"
  echo "perf.stress_cpu_seconds	$(echo "$c0 $c1" | awk '{ printf "%.2f", $2-$1 }')" >> $REPORT/metrics.tsv
  echo "perf.stress_footprint_growth_mb	$(echo "$fp0 $fp1" | awk '{ printf "%.1f", $2-$1 }')" >> $REPORT/metrics.tsv
  budget "footprint growth MB" $(echo "$fp0 $fp1" | awk '{ printf "%.1f", $2-$1 }') 5
  sleep 5
  measure after_stress
  budget "Brim CPU % back at rest" $LAST_CPU 0.1
fi

if want leaks; then scenario "Leaks after the stress run"
  out=$(leaks $(app_pid) 2>&1 | grep -E "leaks for|total leaked")
  print "  $out"
  n=$(echo $out | grep -oE "[0-9]+ leaks" | grep -oE "[0-9]+" | head -1)
  echo "perf.leaks	${n:--1}" >> $REPORT/metrics.tsv
  leaks $(app_pid) > $REPORT/leaks.txt 2>&1
  budget "leaked objects" ${n:-0} 0
fi

if want startup; then scenario "Launch time"
  pkill -f "$TEST_APP/Contents/MacOS/Brim"; sleep 1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  open -g -n --env BRIM_SOCKET="$BRIM_SOCKET" "$TEST_APP"
  for _ in {1..200}; do rm -f $STATE; ctl state; sleep 0.02; [[ -s $STATE ]] && break; done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  ms=$(echo "$t0 $t1" | awk '{ printf "%d", ($2-$1)*1000 }')
  print "  launch to first answer: $ms ms"
  echo "perf.launch_ms	$ms" >> $REPORT/metrics.tsv
  budget "launch ms" $ms 1500
fi

print "\nResults: $CSV"
column -t -s $'\t' $CSV
summary "perf"
