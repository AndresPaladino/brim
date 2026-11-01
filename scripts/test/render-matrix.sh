#!/bin/zsh
# Renders every island state the app can draw without running, one PNG each.
# Usage: scripts/test/render-matrix.sh <Brim.app> <out dir> [--with-windows]
# --with-windows also renders Settings, which briefly puts a real window on screen.
# RENDER_ARGS adds arguments to every render, e.g. RENDER_ARGS="-AppleLanguages (es)".
set -uo pipefail
APP=$1; OUT=$2
BIN="$APP/Contents/MacOS/Brim"
mkdir -p "$OUT"
r() { local name=$1; shift; "$BIN" "$@" ${=RENDER_ARGS:-} >/dev/null 2>&1 || echo "render failed: $name" >&2; }

# Island states
r readme --render-readme "$OUT/readme"
for k in airpods jbl wired usb low; do r device-$k --render-device "$OUT/device-$k.png" $k; done
for k in full plugged unplugged low; do r charge-$k --render-charge "$OUT/charge-$k.png" $k; done
for ms in 0 300 700 1300 1900; do r boop-$ms --render-boop "$OUT/boop-$ms.png" $ms; done
r boop-annoyed --render-boop "$OUT/boop-annoyed.png" 900 annoyed
for v in "" other claude external "other external" "claude external"; do
  r rec-$v --render-recording "$OUT/recording${v:+-${v// /-}}.png" ${=v}
done
for m in hud compact media idle empty; do r ext-$m --render-external "$OUT/external-$m.png" $m; done

# Claude Code and Codex
kinds=(permission permission-long edit write web patch mcp question question-multi question-3lines question-long
       question-wide codex-question done done-long done-short waiting error error-long)
for k in $kinds; do
  r claude-$k-ear  --render-claude "$OUT/claude-$k-ear.png" $k
  r claude-$k-open --render-claude "$OUT/claude-$k-open.png" $k open
done
r claude-music      --render-claude "$OUT/claude-permission-music.png" permission music
r claude-external   --render-claude "$OUT/claude-permission-external.png" permission external
r claude-ext-open   --render-claude "$OUT/claude-question-external-open.png" question open external
r claude-noapprove  --render-claude "$OUT/claude-permission-noapprove-open.png" permission open noapprove
r claude-yes        --render-claude "$OUT/claude-permission-yes.png" permission open yes
r claude-no         --render-claude "$OUT/claude-permission-no.png" permission open no
r claude-codex      --render-claude "$OUT/claude-codex-permission-open.png" patch open codex
r claude-codex-q    --render-claude "$OUT/claude-codex-question-open.png" codex-question open codex
r claude-chosen     --render-claude "$OUT/claude-question-multi-chosen.png" question-multi open chosen=Music,Claude
r claude-longproj   --render-claude "$OUT/claude-waiting-longproject.png" waiting project=my-extremely-long-project-name-that-keeps-going

# Onboarding (off-screen window), light and dark
for a in light dark; do
  for s in welcome access bt conflict notch features agents done; do
    r onb-$s-$a --render-onboarding "$OUT/onboarding-$s-$a.png" $s --appearance $a
  done
done

if [[ "${3:-}" == "--with-windows" ]]; then
  for a in light dark; do
    for t in general alerts claude; do r settings-$t-$a --render-settings "$OUT/settings-$t-$a.png" $t --appearance $a; done
  done
fi
ls "$OUT"/*.png "$OUT"/readme/*.png 2>/dev/null | wc -l | xargs echo "PNG files:"
