#!/usr/bin/env python3
# Copyright 2026 Dell Technologies, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
"""Live + after-the-fact viewer for a QEMU test run.

Every INTERVAL seconds: screendump via the QEMU monitor socket -> PNG, then
rewrite <workdir>/view/index.html (auto-refresh: latest screen, milestones,
serial tail) and timeline.html (every screenshot). Serve <workdir>/view with
any static HTTP server. Runs as root (the monitor socket is root-owned)
until <workdir>/view/STOP exists or QEMU has gone away.

Usage: view.py <workdir> [interval_seconds]
"""
import html
import os
import re
import socket
import subprocess
import sys
import time

WORKDIR = sys.argv[1]
INTERVAL = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
# Optional tag for a second VM in the same run (e.g. "installed"): uses
# monitor-<tag>.sock / serial-<tag>.log and writes view/<tag>/.
TAG = sys.argv[3] if len(sys.argv) > 3 else ""
VIEW = os.path.join(WORKDIR, "view", TAG) if TAG else os.path.join(WORKDIR, "view")
MON = os.path.join(WORKDIR, f"monitor-{TAG}.sock" if TAG else "monitor.sock")
SERIAL = os.path.join(WORKDIR, f"serial-{TAG}.log" if TAG else "serial.log")
ANSI = re.compile(r"\x1b\[[0-9;=?]*[A-Za-z]")

# (label, regex) in boot order; first match in the serial log marks it done.
MILESTONES = [
    ("fdo-uefi-rs started", r"FDO|fdo-uefi"),
    ("TO2 / BMO image-begin", r"BMO: .*(image[_-]begin|delivery|URL)"),
    ("Image downloaded + SHA-256 verified (debug log)", r"SHA256 verified OK|Image hash VERIFIED"),
    ("Chainloading BMO image", r"Chainloading BMO image"),
    ("winpe-uki-stub running", r"winpe-uki-stub \d"),
    ("wimboot started", r"wimboot v\d"),
    ("bootmgfw extracted from boot.wim", r"extracted .*bootmgfw"),
    ("WIM patched (files injected)", r"patching WIM"),
]


def screendump(path):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(MON)
    s.sendall(("screendump " + path + "\n").encode())
    time.sleep(0.7)
    s.close()


def serial_lines():
    try:
        raw = open(SERIAL, "rb").read().decode("utf-8", "replace")
    except FileNotFoundError:
        return []
    text = ANSI.sub("", raw).replace("\r\n", "\n").replace("\r", "\n")
    return [ln for ln in text.split("\n") if ln.strip()]


def write(name, content):
    tmp = os.path.join(VIEW, name + ".tmp")
    with open(tmp, "w") as f:
        f.write(content)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(VIEW, name))


def render(shots, start, running):
    lines = serial_lines()
    joined = "\n".join(lines)
    ms = "".join(
        f"<li>{'[x]' if re.search(rx, joined) else '[ ]'} {html.escape(label)}</li>"
        for label, rx in MILESTONES
    )
    spike_html = "".join(
        f"<h3>WinPE {html.escape(n)}</h3><pre>" + html.escape(open(os.path.join(VIEW, n), errors="replace").read()) + "</pre>"
        for n in sorted(os.listdir(VIEW)) if n.endswith(".log")
    )
    elapsed = int(time.time() - start)
    state = f"RUNNING {elapsed}s" if running else f"FINISHED after {elapsed}s"
    refresh = '<meta http-equiv="refresh" content="3">' if running else ""
    latest = f'<img src="{shots[-1]}" style="max-width:100%;border:1px solid #888">' if shots else "<p>(no screenshot yet)</p>"
    tail = html.escape("\n".join(lines[-70:]))
    write("index.html", f"""<!doctype html><html><head><meta charset="utf-8">{refresh}
<title>{state}</title><style>body{{font-family:sans-serif;margin:12px}}pre{{background:#111;color:#ddd;padding:8px;font-size:12px;white-space:pre-wrap}}
.cols{{display:flex;gap:16px}}.cols>div{{flex:1;min-width:0}}</style></head><body>
<h2>QEMU test{' (' + TAG + ')' if TAG else ''}: {state}</h2><p><a href="timeline.html">timeline ({len(shots)} screenshots)</a> | <a href="serial.txt">full serial log</a>{' | <a href="installed/index.html">installed-system boot</a>' if os.path.isdir(os.path.join(VIEW, "installed")) else ''}{' | <a href="../index.html">WinPE run</a>' if TAG else ''}</p>
<div class="cols"><div>{latest}<ul style="list-style:none;padding:0">{ms}</ul>{spike_html}</div>
<div><h3>Serial (last 70 lines)</h3><pre>{tail}</pre></div></div></body></html>""")
    write("serial.txt", joined + "\n")
    items = "".join(
        f'<div style="display:inline-block;margin:4px;text-align:center"><a href="{s}"><img src="{s}" width="320"></a><br>{s}</div>'
        for s in shots
    )
    write("timeline.html", f"<!doctype html><html><head><meta charset='utf-8'><title>timeline</title></head><body><h2>{state}</h2>{items}</body></html>")


def main():
    os.makedirs(VIEW, exist_ok=True)
    start = time.time()
    shots, seen_qemu, n = [], False, 0
    while True:
        alive = os.path.exists(MON)
        seen_qemu |= alive
        if alive:
            n += 1
            ppm = os.path.join(VIEW, f"shot-{n:04d}.ppm")
            png = f"shot-{n:04d}-t{int(time.time() - start):04d}s.png"
            try:
                screendump(ppm)
                with open(os.path.join(VIEW, png), "wb") as out:
                    subprocess.run(["pnmtopng", ppm], stdout=out, stderr=subprocess.DEVNULL, check=True)
                os.chmod(os.path.join(VIEW, png), 0o644)
                shots.append(png)
            except (OSError, subprocess.CalledProcessError):
                pass
            finally:
                if os.path.exists(ppm):
                    os.remove(ppm)
        stop = os.path.exists(os.path.join(VIEW, "STOP")) or (seen_qemu and not alive)
        render(shots, start, not stop)
        if stop:
            return
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
