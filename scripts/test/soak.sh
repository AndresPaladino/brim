#!/bin/zsh
# Long run on the installed Brim during normal use (or overnight): samples CPU, wakeups, energy,
# memory and battery every minute, then writes a summary and charts.
# Run it twice to compare: once normally, once with --without-brim (quits Brim for the run).
# Usage: scripts/test/soak.sh [hours, default 12] [--without-brim]
#   Ctrl-C stops early and still writes the summary.
set -uo pipefail
cd "${0:A:h}/../.."
HOURS=${1:-12}; MODE=with
[[ "${2:-}" == --without-brim ]] && MODE=without
SCRATCH=$HOME/Library/Caches/brim-build
OUT=$SCRATCH/test-reports/soak-$(date +%Y-%m-%d_%H%M)-$MODE
mkdir -p $OUT
CSV=$OUT/samples.tsv
print "time\tbrim_cpu_s\tbridge_cpu_s\tfootprint_mb\tbrim_wakeups\tbrim_power\tbattery_pct\ton_ac\tdisplay_sleep" > $CSV

if [[ $MODE == without ]]; then
  WAS=$(pgrep -xq Brim && echo yes || echo no)
  pkill -x Brim
  trap '[[ $WAS == yes ]] && open -g /Applications/Brim.app' EXIT
fi
caffeinate -i -w $$ &   # keep the Mac awake (display may sleep) so samples keep coming

cpu() { [[ -n ${1:-} ]] && ps -o time= -p $1 2>/dev/null | awk -F: '{ s=0; for (i=1;i<=NF;i++) s=s*60+$i; print s }' || echo 0; }
finish() {
  /usr/bin/python3 scripts/test/soak-report.py $CSV $OUT $MODE
  exit 0
}
trap finish INT TERM

print "Soak ($MODE Brim) for $HOURS h. Samples: $CSV"
end=$(( $(date +%s) + HOURS * 3600 ))
while (( $(date +%s) < end )); do
  b=$(pgrep -f "/Applications/Brim.app/Contents/MacOS/Brim" | head -1)
  p=${b:+$(pgrep -P $b perl | head -1)}
  # top's second sample covers the last 60 s and doubles as the wait between samples. Its IDLEW is the
  # total since launch, so the minute's wakeups are the difference between the two samples.
  line=$([[ -n $b ]] && top -l 2 -s 60 -pid $b -stats pid,idlew,power 2>/dev/null | grep -E "^$b " |
    awk '{ gsub(/[^0-9]/, "", $2) } NR == 1 { w0 = $2 } NR == 2 { print $1, $2 - w0, $3 }' || { sleep 60; echo "0 0 0"; })
  fp=$([[ -n $b ]] && footprint -p $b 2>/dev/null | awk '/phys_footprint:/ { v=$2; if ($3=="KB") v/=1024; print v; exit }' || echo 0)
  batt=$(pmset -g batt | grep -oE "[0-9]+%" | head -1 | tr -d %)
  ac=$(pmset -g batt | grep -q "AC Power" && echo 1 || echo 0)
  dsleep=$(pmset -g powerstate IODisplayWrangler 2>/dev/null | awk 'NR==3 { print ($2 < 4) ? 1 : 0 }')
  print "$(date +%s)\t$(cpu $b)\t$(cpu $p)\t${fp:-0}\t$(echo $line | awk '{print $2}')\t$(echo $line | awk '{print $3}')\t$batt\t$ac\t${dsleep:-0}" >> $CSV
done
finish
