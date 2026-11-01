"""Summary and charts for scripts/test/soak.sh. Usage: soak-report.py <samples.tsv> <out dir> <with|without>"""
import csv, sys, os

path, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
rows = list(csv.DictReader(open(path), delimiter="\t"))
if len(rows) < 2:
    print("Not enough samples."); sys.exit(0)
num = lambda r, k: float(r[k] or 0)
t0, t1 = num(rows[0], "time"), num(rows[-1], "time")
hours = (t1 - t0) / 3600
cpu = num(rows[-1], "brim_cpu_s") - num(rows[0], "brim_cpu_s")
bridge = num(rows[-1], "bridge_cpu_s") - num(rows[0], "bridge_cpu_s")
fps = [num(r, "footprint_mb") for r in rows if num(r, "footprint_mb") > 0]
wake = [num(r, "brim_wakeups") / 60 for r in rows]
on_battery = [r for r in rows if r["on_ac"] == "0"]
drain = None
if len(on_battery) > 1:
    span = (num(on_battery[-1], "time") - num(on_battery[0], "time")) / 3600
    if span > 0.25:
        drain = (num(on_battery[0], "battery_pct") - num(on_battery[-1], "battery_pct")) / span

lines = [
    f"# Soak, {mode} Brim, {hours:.1f} h",
    f"- Brim CPU: {cpu:.1f} s total, {cpu / max(1, t1 - t0) * 100:.4f} % average",
    f"- Now Playing bridge CPU: {bridge:.1f} s total",
    f"- Wakeups: {sum(wake) / len(wake):.2f}/s average, {max(wake):.2f}/s worst minute",
    f"- Footprint: {fps[0] if fps else 0:.1f} MB at start, {max(fps) if fps else 0:.1f} MB peak, {fps[-1] if fps else 0:.1f} MB at end",
    f"- Battery drain on battery: {drain:.2f} %/h" if drain is not None else "- Battery drain: not enough time on battery",
    "", "Compare with a run made with --without-brim over a similar period: the drain difference is Brim's cost.",
]
open(os.path.join(out, "summary.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))

def chart(name, key, transform=lambda r, v: v, unit=""):
    pts = [((num(r, "time") - t0) / 3600, transform(r, num(r, key))) for r in rows]
    w, h, pad = 900, 220, 40
    ymax = max(v for _, v in pts) or 1
    xmax = max(x for x, _ in pts) or 1
    path_d = " ".join(f"{'M' if i == 0 else 'L'}{pad + x / xmax * (w - 2 * pad):.1f},{h - pad - v / ymax * (h - 2 * pad):.1f}" for i, (x, v) in enumerate(pts))
    return (f'<h3>{name}</h3><svg width="{w}" height="{h}" style="background:#fff">'
            f'<path d="{path_d}" fill="none" stroke="#3b6fd8" stroke-width="1.5"/>'
            f'<text x="4" y="{pad}" font-size="11">{ymax:.2f}{unit}</text><text x="{w - pad}" y="{h - 10}" font-size="11">{xmax:.1f} h</text></svg>')

prev = {}
def per_minute(r, v, key="brim_cpu_s"):
    p = prev.get(key); prev[key] = v
    return 0 if p is None else max(0, (v - p) / 60 * 100)

html = ["<meta charset=utf-8><body style='font:14px -apple-system;margin:24px'>", "<pre>" + "\n".join(lines) + "</pre>",
        chart("Brim CPU % per minute", "brim_cpu_s", per_minute, " %"),
        chart("Footprint (MB)", "footprint_mb", unit=" MB"),
        chart("Idle wakeups per minute", "brim_wakeups"),
        chart("Battery %", "battery_pct", unit=" %")]
open(os.path.join(out, "charts.html"), "w").write("\n".join(html))
print(f"Charts: {os.path.join(out, 'charts.html')}")
