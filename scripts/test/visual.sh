#!/bin/zsh
# Visual regression: renders every island state in English and Spanish with the app's own views and
# compares them with Tests/Snapshots. Writes diffs and a gallery to the report folder.
# Usage: scripts/test/visual.sh [--record] [--with-windows]
#   --record        accept the current renders as the new reference
#   --with-windows  also render Settings (briefly shows a real window)
set -uo pipefail
cd "${0:A:h}/../.."
SCRATCH=${SCRATCH:-$HOME/Library/Caches/brim-build}
REPORT=${REPORT:-$SCRATCH/test-reports/$(date +%Y-%m-%d_%H%M)}
GOLDEN=Tests/Snapshots
APP=$SCRATCH/test.noindex/Brim.app
IMGDIFF=$SCRATCH/tools/imgdiff
record=false; windows=""
for a in "$@"; do [[ $a == --record ]] && record=true; [[ $a == --with-windows ]] && windows=--with-windows; done

scripts/build.sh --test >/dev/null 2>&1 || { echo "build failed"; exit 1; }
if [[ ! -x $IMGDIFF || scripts/test/imgdiff.swift -nt $IMGDIFF ]]; then
  mkdir -p ${IMGDIFF:h} && swiftc -O scripts/test/imgdiff.swift -o $IMGDIFF 2>/dev/null
fi

OUT=$REPORT/visual
rm -rf $OUT; mkdir -p $OUT
RENDER_ARGS="--plain -AppleLanguages (en)" scripts/test/render-matrix.sh $APP $OUT/en $windows
RENDER_ARGS="--plain -AppleLanguages (es)" scripts/test/render-matrix.sh $APP $OUT/es $windows

rc=0
if $record; then
  rm -rf $GOLDEN; mkdir -p $GOLDEN
  cp -R $OUT/en $OUT/es $GOLDEN/
  echo "Recorded $(find $GOLDEN -name '*.png' | wc -l | tr -d ' ') reference images in $GOLDEN"
else
  for lang in en es; do
    echo "== $lang"
    $IMGDIFF $GOLDEN/$lang $OUT/$lang $OUT/diff/$lang | tee $OUT/diff-$lang.txt | grep -v "^$" | tail -15 || rc=1
  done
fi

# Gallery: every render, with its diff next to it when it changed.
{
  echo '<!doctype html><meta charset="utf-8"><title>Brim renders</title><style>body{font:13px -apple-system;background:#1d1d1f;color:#eee;margin:24px}
  h2{margin-top:32px}figure{display:inline-block;margin:8px;vertical-align:top;background:#2a2a2c;padding:8px;border-radius:8px}
  img{max-width:560px;display:block}figcaption{margin-top:6px;color:#aaa}.diff{outline:2px solid #f0f}</style>'
  for lang in en es; do
    echo "<h2>$lang</h2>"
    for f in $(cd $OUT/$lang && find . -name '*.png' | sort); do
      f=${f#./}
      echo "<figure><img src=\"$lang/$f\"><figcaption>$f</figcaption>"
      [[ -f $OUT/diff/$lang/$f ]] && echo "<img class=diff src=\"diff/$lang/$f\"><figcaption>diff (magenta = changed)</figcaption>"
      echo "</figure>"
    done
  done
} > $OUT/gallery.html
echo "Gallery: $OUT/gallery.html"
exit $rc
