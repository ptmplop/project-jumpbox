#!/usr/bin/env python3
"""Aurora display and motd test suite. Usage: suite.py [mock|e2e|cpu|all] [test-name-substring ...]

Needs a python with pyte:  python3 -m venv .venv && .venv/bin/pip install pyte
then e.g.                  JBX_DEV=1 .venv/bin/python suite.py all

Mock tests run the real display() against mock/mock.sh (no VPN), and open
login shells in it for the motd (configs/motd.sh). E2E tests
run the real image (start.sh) against a local OpenVPN server (e2e.py); the
throwaway PKI for it is made on first use in e2e/pki. Tests use only
containers and networks named jbx-t<n>-* / jbx-t<n>. The image tested is
jumpbox:latest (JBX_IMAGE to change it); JBX_DEV=1 mounts the
working copies of the scripts in ../configs over the image's, so a change
can be tested before a build. The cpu test compares against an older build,
JBX_OLD_IMAGE (default jumpbox:pre-aurora). Results go to stdout and
results-<when>.json.
"""
import concurrent.futures as cf
import json
import os
import re
import shlex
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e as E          # noqa: E402
import jbxterm as J      # noqa: E402
import pyte              # noqa: E402

T = E.T
IMAGE = E.IMAGE
SLOT_MOCK = 7            # container names jbx-t7-*
MOCK = dict(port=10079, sshport=12080, host="4c7e19a2f05d", ovpn="example-gateway-sso.ovpn",
            vpnver="OpenVPN 2.7.7", osver="3.24.2", ip="198.51.100.147", country="India")
RESULTS = []


def result(name, problems, **info):
    ok = not problems
    RESULTS.append(dict(name=name, ok=ok, problems=problems, info=info))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "\n    " + "\n    ".join(problems[:12])), flush=True)
    return ok


def rm(name):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def mock_cmd(name, env=None, extra=None, image=None):
    cmd = ["docker", "run", "-it", "--init", "--name", name, "--cap-add", "NET_ADMIN",
           "--hostname", "4c7e19a2f05d", "-e", "PORT=10079", "-e", "SSHPORT=12080", "-v", f"{T}:/t:ro"]
    for k, v in (env or {}).items():
        cmd += ["-e", f"{k}={v}"]
    cmd += extra or []
    cmd += E.dev_mounts()
    cmd += [image or IMAGE, "/t/mock/mock.sh"]
    return cmd


def mexec(name, *args):
    return subprocess.run(["docker", "exec", name, *args], capture_output=True, text=True)


def state_word(st):
    return {"conn": "CONNECTED", "down": "DISCONNECTED", "sso": "SIGN"}[st]


def shows_state(scr, st):
    t = scr.all_text()
    if st == "conn":
        return ("CONNECTED" in t or " UP " in t) and "DISCONNECTED" not in t and "DOWN" not in t
    if st == "down":
        return "DISCONNECTED" in t or "✕ DOWN" in t
    return "SIGN-IN" in t or "◈ SSO" in t


def set_state(name, st):
    mexec(name, "/t/mock/state.sh", {"conn": "conn", "down": "down", "sso": "sso"}[st])


def settle(run, st, timeout=15):
    return run.wait_for(lambda s: shows_state(s, st) and not J.frame_problems(s), timeout)


def log_problems(name, problems):
    """bash's own messages go to /var/log/jumpbox-display.log: there must be none"""
    r = subprocess.run(["docker", "exec", name, "cat", "/var/log/jumpbox-display.log"], capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        problems.append("display error log: " + r.stdout.strip()[:600])


def stream_checks(run, problems, until=None, name=None):
    if name:
        log_problems(name, problems)
    data, _ = run.data()
    if until is not None:
        data = data[:until]
    errs = J.stream_errors(data)
    if errs:
        problems.append(f"bash error text in the stream: {errs[:2]}")
    lf = J.newlines_after_first_paint(data)
    if lf:
        problems.append(f"{lf} newline(s) written after the first paint")
    return data


# ------------------------------------------------------------------ mock tests

SIZES = [(10, 66), (11, 66), (10, 80), (24, 120), (9, 66), (7, 40), (8, 50), (7, 65), (10, 65),
         (12, 58), (6, 40), (5, 40), (4, 40), (3, 40), (2, 40), (7, 36), (7, 30), (7, 24), (10, 20)]


def t_layout(rows, cols):
    name = f"jbx-t{SLOT_MOCK}-l{rows}x{cols}"
    rm(name)
    run = J.start(mock_cmd(name), rows, cols)
    problems = []
    try:
        for st in ("conn", "down", "sso", "conn"):
            if st != "conn" or problems or True:
                set_state(name, st) if st != "conn" else mexec(name, "/t/mock/state.sh", "conn")
            scr = settle(run, st, 20)
            if scr is None:
                scr = run.screen()
                problems.append(f"[{st}] state never shown cleanly; frame problems: {J.frame_problems(scr)[:4]}")
                problems.append("screen:\n" + scr.dump())
                break
            time.sleep(1.2)               # a few more paints (animation, spinners)
            scr = run.screen()
            p = J.frame_problems(scr) + J.detail_problems(scr, st, MOCK)
            kind, W, H = J.expected_layout(rows, cols)
            if kind == "full":
                bg = J.badge_bg(scr)
                if bg != J.STATE_BG[st]:
                    p.append(f"badge background {bg}, expected {J.STATE_BG[st]}")
            if p:
                problems += [f"[{st}] {x}" for x in p] + ["screen:\n" + scr.dump()]
        stream_checks(run, problems, name=name)
    finally:
        rm(name)
        run.close()
    return result(f"mock layout {rows}x{cols} conn/down/sso", problems)


def t_resize_sequence():
    name = f"jbx-t{SLOT_MOCK}-resize"
    rm(name)
    run = J.start(mock_cmd(name), 10, 66)
    problems = []
    seq = [(7, 40), (11, 66), (30, 100), (5, 30), (10, 66), (9, 50), (40, 160), (2, 12), (10, 66), (7, 40), (10, 66)]
    try:
        # Connected and the IP looked up: every size checked below expects the IP
        if not run.wait_for(lambda s: shows_state(s, "conn") and "Looking up" not in s.all_text()
                            and not J.frame_problems(s), 25):
            problems.append("never connected")
        for i, (r, c) in enumerate(seq):
            run.resize(r, c)
            time.sleep(0.9)
            scr = run.screen()
            p = J.frame_problems(scr) + J.detail_problems(scr, "conn", MOCK)
            if p:
                problems += [f"after resize #{i} to {r}x{c}: {x}" for x in p] + [scr.dump()]
        # a burst of resizes, then check it settles
        for k in range(30):
            run.resize(8 + k % 5, 40 + (k * 7) % 40)
            time.sleep(0.03)
        run.resize(10, 66)
        time.sleep(1.0)
        scr = run.screen()
        p = J.frame_problems(scr) + J.detail_problems(scr, "conn", MOCK)
        if p:
            problems += [f"after a resize burst: {x}" for x in p] + [scr.dump()]
        stream_checks(run, problems, name=name)
    finally:
        rm(name)
        run.close()
    return result("mock resize sequence + burst", problems)


def t_keys():
    name = f"jbx-t{SLOT_MOCK}-keys"
    rm(name)
    run = J.start(mock_cmd(name), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        before = len(J.paints(run.data()[0]))
        run.send(b"abc xyz\r\r\r\r\r")
        run.send(b"\x13")             # Ctrl-S: output must not stop
        run.send(b"\x1a")             # Ctrl-Z: must not suspend the loop
        run.send(b"\x1b[A\x1b[B\x1bOP\t\x7f\x7f")
        run.send(b"\x11")             # Ctrl-Q
        time.sleep(2.5)
        data, _ = run.data()
        after = len(J.paints(data))
        if after - before < 8:
            problems.append(f"only {after - before} paints in 2.5s after the keys (frozen?)")
        scr = run.screen()
        if "abc" in scr.all_text() or "xyz" in scr.all_text():
            problems.append("typed text is visible on the screen")
        p = J.frame_problems(scr) + J.detail_problems(scr, "conn", MOCK)
        problems += p
        if p:
            problems.append(scr.dump())
        st = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", name], capture_output=True, text=True).stdout.strip()
        if st != "true":
            problems.append("container stopped after the keys")
        stream_checks(run, problems, name=name)
    finally:
        rm(name)
        run.close()
    return result("mock keys (echo off, ^S ^Z ^Q, arrows, Enter)", problems)


def t_stop(kind):
    name = f"jbx-t{SLOT_MOCK}-stop-{kind}"
    rm(name)
    run = J.start(mock_cmd(name), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        mark = run.size_now()
        t0 = time.time()
        if kind == "docker-stop":
            subprocess.run(["docker", "stop", name], capture_output=True)
        elif kind == "ctrl-c":
            run.send(b"\x03")
        elif kind == "stop-file":
            mexec(name, "touch", "/.stop")
        elif kind == "stop-during-resizes":
            p = subprocess.Popen(["docker", "stop", name])
            for k in range(40):
                run.resize(8 + k % 4, 50 + k % 17)
                time.sleep(0.02)
            p.wait()
        for _ in range(100):
            if run.proc.poll() is not None:
                break
            time.sleep(0.1)
        dt = time.time() - t0
        ec = subprocess.run(["docker", "inspect", "-f", "{{.State.ExitCode}}", name], capture_output=True, text=True).stdout.strip()
        if ec != "0":
            problems.append(f"exit code {ec} (137 = SIGKILL after the stop timeout)")
        if dt > 5:
            problems.append(f"took {dt:.1f}s to stop")
        data, _ = run.data()
        tail = data[mark:]
        if b"\x1b[?25h" not in tail:
            problems.append("cursor never shown again (no cnorm)")
        if b"\x1b[?7h" not in tail:
            problems.append("autowrap never turned back on (no smam)")
        if kind != "stop-file" and b"Exit complete" not in tail:
            problems.append("no 'Exit complete'")
        if kind == "stop-file":
            scr = run.screen()
            if any(line.strip() for line in scr.text):
                problems.append("screen not cleared on /.stop:\n" + scr.dump())
        stream_checks(run, problems, until=mark)
        return result(f"mock stop via {kind}", problems, seconds=round(dt, 2))
    finally:
        rm(name)
        run.close()


GEO_CASES = [
    ("gb", dict(MOCK_GEO_FILE="/t/mock/geo-gb.json"), ["🇬🇧", "United Kingdom  "], ["Great Britain"]),
    ("ba", dict(MOCK_GEO_FILE="/t/mock/geo-ba.json"), ["🇧🇦", "Bosnia and Herzegovina"], []),
    ("kr", dict(MOCK_GEO_FILE="/t/mock/geo-kr.json"), ["🇰🇷", "Korea  "], ["Republic"]),
    ("tr", dict(MOCK_GEO_FILE="/t/mock/geo-tr.json"), ["🇹🇷", "Türkiye"], []),
    ("err", dict(MOCK_GEO_FILE="/t/mock/geo-err.json"), ["EXIT    198.51.100.147"], ["null", "Invalid"]),
    ("evil", dict(MOCK_GEO_FILE="/t/mock/geo-evil.json"), ["198.51.100.147"], ['"', "$(", "`"]),
    ("ipfail", dict(MOCK_IP="fail"), ["Unable to determine from API call"], ["198.51"]),
    ("geofail", dict(MOCK_GEO_FILE="fail"), ["EXIT    198.51.100.147"], ["India"]),
    ("ip-html", dict(MOCK_IP="<html>502 Bad Gateway</html>"), ["Unable to determine from API call"], ["html"]),
]


def t_geo(tag, env, want, avoid):
    name = f"jbx-t{SLOT_MOCK}-geo-{tag}"
    rm(name)
    run = J.start(mock_cmd(name, env=env), 10, 66)
    problems = []
    try:
        scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and "Looking up" not in s.all_text(), 25)
        time.sleep(1)
        scr = run.screen()
        exit_row = scr.row(3)
        for w in want:
            if w not in exit_row:
                problems.append(f"EXIT row lacks {w!r}: {exit_row.rstrip()!r}")
        for a in avoid:
            if a in exit_row:
                problems.append(f"EXIT row has {a!r}: {exit_row.rstrip()!r}")
        problems += J.frame_problems(scr)
        prof = mexec(name, "bash", "-c", "source /etc/profile >/dev/null 2>&1 && printf '%s|%s|%s|%s' \"$IP\" \"$CC\" \"$CTN\" \"$EMOJI\"; test -e /tmp/pwned && echo PWNED")
        if "PWNED" in prof.stdout:
            problems.append("geo data executed code via /etc/profile")
        out = mexec(name, "bash", "-c", "bash -n /etc/profile && echo SYNTAX-OK")
        if "SYNTAX-OK" not in out.stdout:
            problems.append(f"/etc/profile no longer parses: {out.stderr.strip()[:200]}")
        stream_checks(run, problems, name=name)
        return result(f"mock geo {tag}", problems, profile=prof.stdout.strip())
    finally:
        rm(name)
        run.close()


def t_fields():
    """SSHPORT default/override, long config file name and hostname."""
    problems = []
    cases = [
        ("sshport-default", dict(SSHPORT=""), [], "ssh jumpbox@127.0.0.1 -p 12079"),
        ("sshport-set", dict(SSHPORT="12080"), [], "ssh jumpbox@127.0.0.1 -p 12080"),
        ("sshport-zero-lead", dict(SSHPORT="08080"), [], "ssh jumpbox@127.0.0.1 -p 8080"),
        ("port-nonnum", dict(PORT="abc", SSHPORT=""), [], "ssh jumpbox@127.0.0.1 -p ?"),
        ("long-ovpn", dict(OVPNFILE="a-very-long-openvpn-profile-name-for-a-gateway-in-somewhere-far-away.ovpn"), [], "a-very-long-openvpn-profile-name"),
        ("long-host", {}, ["--hostname", "jumpbox-with-a-really-long-hostname-1234567890"], "docker exec -it jumpbox-with-a-really-long-hos… sh -l"),
    ]
    for tag, env, extra, want in cases:
        name = f"jbx-t{SLOT_MOCK}-f-{tag}"
        rm(name)
        cmd = mock_cmd(name, env=env, extra=extra)
        if extra:
            i = cmd.index("--hostname")
            del cmd[i:i + 2]
        run = J.start(cmd, 10, 66)
        try:
            scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and "Looking up" not in s.all_text(), 25)
            scr = run.screen()
            if want not in scr.all_text():
                problems.append(f"[{tag}] missing {want!r}:\n{scr.dump()}")
            p = J.frame_problems(scr)
            if p:
                problems += [f"[{tag}] {x}" for x in p] + [scr.dump()]
            for run_ in (run,):
                d, _ = run_.data()
                if J.stream_errors(d):
                    problems.append(f"[{tag}] errors: {J.stream_errors(d)[:2]}")
            # compact too
            run.resize(7, 40)
            time.sleep(1)
            scr = run.screen()
            p = J.frame_problems(scr)
            if p:
                problems += [f"[{tag} 40x7] {x}" for x in p] + [scr.dump()]
        finally:
            rm(name)
            run.close()
    return result("mock fields (SSHPORT, PORT junk, long names)", problems)


def t_connchecker_respawn():
    name = f"jbx-t{SLOT_MOCK}-respawn"
    rm(name)
    run = J.start(mock_cmd(name), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        pid1 = mexec(name, "cat", "/.conn_check_pid").stdout.strip()
        mexec(name, "kill", "-9", pid1)
        time.sleep(7)
        pid2 = mexec(name, "cat", "/.conn_check_pid").stdout.strip()
        alive = mexec(name, "kill", "-0", pid2).returncode == 0
        if pid2 == pid1 or not alive:
            problems.append(f"connCheck not respawned (pid {pid1} -> {pid2}, alive={alive})")
        set_state(name, "down")
        if not settle(run, "down", 20):
            problems.append("state stopped tracking after the respawn")
        stream_checks(run, problems)
    finally:
        rm(name)
        run.close()
    return result("mock connCheck respawn", problems)


def t_tun_recreate():
    """CONNCHECK=ping (real ICMP via docker): tun0 deleted -> 'interface is down';
    recreated -> counters restart from 0 without a bogus rate."""
    name = f"jbx-t{SLOT_MOCK}-tun"
    rm(name)
    run = J.start(mock_cmd(name, env=dict(CONNCHECK="ping")), 10, 66)
    problems = []
    try:
        if not settle(run, "conn", 25):
            problems.append("never connected (ICMP to 8.8.8.8 from docker?)")
        mexec(name, "ip", "link", "del", "tun0")
        scr = run.wait_for(lambda s: "interface is down" in s.all_text(), 8)
        if not scr:
            problems.append("no 'interface is down' after deleting tun0:\n" + run.screen().dump())
        mexec(name, "sh", "-c", "ip link add tun0 type veth peer name tunpeer && ip link set tun0 up && ip link set tunpeer up && ip addr add 10.99.0.2/24 dev tun0 && ip neigh add 10.99.0.1 lladdr 02:00:00:00:00:01 dev tun0")
        scr = run.wait_for(lambda s: re.search(r"▼ \d", s.all_text()) is not None, 8)
        time.sleep(3)
        scr = run.screen()
        if not scr or "interface is down" in scr.all_text():
            problems.append("stats did not come back after recreating tun0")
        m = re.search(r"▼ ([\d.]+) (B|KiB|MiB|GiB)", scr.all_text())
        if m and m.group(2) in ("MiB", "GiB"):
            problems.append(f"download total after recreation looks wrong: {m.group(0)}")
        problems += J.frame_problems(scr)
        stream_checks(run, problems)
    finally:
        rm(name)
        run.close()
    return result("mock tun0 deleted/recreated (interface down, counter reset)", problems)


def proc_cpu_ticks(name, pid_cmd):
    pid = mexec(name, "sh", "-c", pid_cmd).stdout.strip().split()[0]
    st = mexec(name, "cat", f"/proc/{pid}/stat").stdout.split()
    return pid, int(st[13]) + int(st[14]) + int(st[15]) + int(st[16])


def t_cpu_vs_old():
    """CPU of the display shell (and its children) over 30s, new vs old image."""
    problems = []
    info = {}
    old = os.environ.get("JBX_OLD_IMAGE", "jumpbox:pre-aurora")
    for tag, image, dev in (("old", old, False), ("new", IMAGE, True)):
        name = f"jbx-t{SLOT_MOCK}-cpu-{tag}"
        rm(name)
        saved = os.environ.get("JBX_DEV")
        if not dev:
            os.environ.pop("JBX_DEV", None)
        cmd = mock_cmd(name, env=dict(MOCK_TRAFFIC="off"), image=image)
        if saved is not None:
            os.environ["JBX_DEV"] = saved
        run = J.start(cmd, 10, 66)
        try:
            run.wait_for(lambda s: "Connected" in s.all_text() or "CONNECTED" in s.all_text(), 25)
            time.sleep(3)
            hz = int(mexec(name, "getconf", "CLK_TCK").stdout.strip() or 100)
            pid, a = proc_cpu_ticks(name, "pgrep -x mock.sh | head -1")
            b0 = run.size_now()
            t0 = time.time()
            time.sleep(30)
            _, b = proc_cpu_ticks(name, f"echo {pid}")
            dt = time.time() - t0
            cpu = (b - a) / hz / dt * 100
            info[tag] = dict(cpu_pct=round(cpu, 2), bytes_per_s=int((run.size_now() - b0) / dt))
        finally:
            rm(name)
            run.close()
    if info.get("new", {}).get("cpu_pct", 99) > 6:
        problems.append(f"display CPU {info['new']['cpu_pct']}% of one core")
    return result("mock CPU + output rate, new vs old display", problems, **info)


# ------------------------------------------------------------------ e2e tests

def e2e_details(run, name, n):
    host = E.sh("docker", "exec", name, "cat", "/etc/hostname").stdout.strip()
    ipv = E.sh("docker", "exec", name, "sh", "-c", "source /etc/profile; echo $IP").stdout.strip()
    return dict(port=29990 + n, sshport=31990 + n, host=host, ovpn="client.ovpn", vpnver="OpenVPN 2.7.7",
                osver="3.24.2", ip=ipv or None, country=None)


def t_e2e_main(n=1):
    """start.sh for real: startup lines, connect, traffic, latency, outage, reconnect, vpn-restart, stop."""
    name = f"jbx-t{n}-main"
    E.setup(n)
    run = J.start(E.client_cmd(n, name), 10, 66)
    problems = []
    info = {}
    try:
        scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and "Looking up" not in s.all_text(), 60)
        data, _ = run.data()
        pre = data[:data.find(J.PAINT)] if J.PAINT in data else data
        for w in (b"Starting...", b"Connect using:", b"Connecting the tunnel", b"Waiting for connection", "▸".encode()):
            if w not in pre:
                problems.append(f"startup output lacks {w!r}")
        if not scr:
            problems.append("never connected:\n" + run.screen().dump())
            return result("e2e main flow", problems)
        time.sleep(2)
        d = e2e_details(run, name, n)
        info["ip"] = d["ip"]
        scr = run.screen()
        problems += J.frame_problems(scr) + J.detail_problems(scr, "conn", d)
        if not d["ip"]:
            problems.append("no public IP through the tunnel (EXIT row: %r)" % scr.row(3))
        # traffic both ways
        E.server_exec(n, "iperf3", "-s", "-D", "-B", f"10.89.{n}.1")
        time.sleep(0.5)
        E.sh("docker", "exec", name, "iperf3", "-c", f"10.89.{n}.1", "-t", "3", "-b", "30M")
        E.sh("docker", "exec", name, "iperf3", "-c", f"10.89.{n}.1", "-t", "3", "-b", "30M", "-R")
        time.sleep(1.5)
        scr = run.screen()
        row = scr.row(8)
        info["stats_row"] = row.rstrip()
        m_rx = re.search(r"▼ ([\d.]+) (\w+)", row)
        m_tx = re.search(r"▲ ([\d.]+) (\w+)", row)
        if not (m_rx and m_rx.group(2) == "MiB" and m_tx and m_tx.group(2) == "MiB"):
            problems.append(f"totals after 2x3s of 30Mbit/s don't read MiB: {row.rstrip()!r}")
        if not re.search(r"[▆▇█]", row):
            problems.append(f"sparklines flat after traffic bursts: {row.rstrip()!r}")
        # latency
        E.server_exec(n, "tc", "qdisc", "add", "dev", "eth0", "root", "netem", "delay", "60ms")
        scr = run.wait_for(lambda s: re.search(r"ping (\d+)ms", s.row(8)) and 40 <= int(re.search(r"ping (\d+)ms", s.row(8)).group(1)) <= 140, 20)
        if not scr:
            problems.append(f"ping never showed ~60ms: {run.screen().row(8).rstrip()!r}")
        E.server_exec(n, "tc", "qdisc", "del", "dev", "eth0", "root")
        # outage long enough for ping-restart (keepalive 2 10), then reconnect
        E.sh("docker", "pause", f"jbx-t{n}-srv")
        scr = run.wait_for(lambda s: "DISCONNECTED" in s.all_text(), 30)
        if not scr:
            problems.append("no DISCONNECTED during the outage")
        else:
            problems += [f"[down] {x}" for x in J.frame_problems(scr) + J.detail_problems(scr, "down", d)]
        time.sleep(14)
        E.sh("docker", "unpause", f"jbx-t{n}-srv")
        scr = run.wait_for(lambda s: "DISCONNECTED" not in s.all_text() and "CONNECTED" in s.all_text(), 60)
        if not scr:
            problems.append("no reconnect after the outage")
        else:
            m = re.search(r"last reconnect (\d\d)h (\d\d)m (\d\d)s", scr.all_text())
            if not m or int(m.group(1)) or int(m.group(2)) > 1:
                problems.append(f"last reconnect didn't reset after ping-restart: {scr.row(1).rstrip()!r}")
        # vpn-restart from another shell
        mark = run.size_now()
        vr = E.sh("docker", "exec", name, "vpn-restart")
        info["vpn_restart_tail"] = vr.stdout.strip().splitlines()[-2:]
        if "VPN restarted successfully" not in vr.stdout:
            problems.append(f"vpn-restart failed: {vr.stdout[-300:]!r}")
        if "▸" not in vr.stdout:
            problems.append("vpn-restart output not in the new style")
        scr = run.wait_for(lambda s: "DISCONNECTED" not in s.all_text() and "CONNECTED" in s.all_text(), 30)
        time.sleep(3)
        scr = run.screen()
        problems += [f"[after vpn-restart] {x}" for x in J.frame_problems(scr) + J.detail_problems(scr, "conn", d)]
        rate_txt = scr.row(8)
        if re.search(r"[▼▲] [\d.]+ (GiB|TiB|PiB)", rate_txt):
            problems.append(f"bogus totals after tun0 was recreated: {rate_txt.rstrip()!r}")
        data = stream_checks(run, problems)
        # cpu
        st = E.sh("docker", "stats", "--no-stream", "--format", "{{.CPUPerc}} {{.MemUsage}}", name).stdout.strip()
        info["docker_stats"] = st
        mark = run.size_now()
        t0 = time.time()
        E.sh("docker", "stop", name)
        dt = time.time() - t0
        ec = E.sh("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout.strip()
        if ec != "0" or dt > 5:
            problems.append(f"docker stop: exit {ec} after {dt:.1f}s")
        time.sleep(0.5)
        tail = run.data()[0][mark:]
        if b"\x1b[?25h" not in tail or b"\x1b[?7h" not in tail or b"Exit complete" not in tail:
            problems.append("shutdown didn't restore the terminal / print Exit complete")
        return result("e2e main flow (start, traffic, latency, outage, vpn-restart, stop)", problems, **info)
    except Exception:
        problems.append(traceback.format_exc())
        return result("e2e main flow", problems, **info)
    finally:
        run.close()
        E.teardown(n)


def t_e2e_sso(n=2):
    """SSO against a server holding the client with client-pending-auth."""
    name = f"jbx-t{n}-sso"
    E.setup(n, sso=True)
    E.server_exec(n, "touch", "/tmp/sso-on")
    run = J.start(E.client_cmd(n, name, env=dict(SSO="true")), 10, 66)
    problems = []
    info = {}
    try:
        ok = run.wait_bytes("Finish the SSO sign-in in your browser", 45)
        if not ok:
            problems.append("startup never showed the SSO sign-in prompt")
        data, _ = run.data()
        if b"https://sso.example.test/login?sess=" not in data:
            problems.append("sign-in URL not printed")
        u = E.sh("docker", "exec", name, "sso-url").stdout.strip()
        info["sso_url"] = u
        if not u.startswith("https://sso.example.test/login"):
            problems.append(f"sso-url gave {u!r}")
        E.server_exec(n, "rm", "-f", "/tmp/sso-on")
        E.server_exec(n, "touch", "/tmp/sso-approve")
        scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and "DISCONNECTED" not in s.all_text(), 45)
        if not scr:
            problems.append("not connected after approving the sign-in:\n" + run.screen().dump())
            return result("e2e SSO", problems, **info)
        # now force a reconnect that needs a sign-in again
        E.server_exec(n, "touch", "/tmp/sso-on")
        E.sh("docker", "exec", name, "pkill", "-USR1", "-x", "openvpn")
        scr = run.wait_for(lambda s: "SIGN-IN PENDING" in s.all_text(), 40)
        if not scr:
            problems.append("display never showed SIGN-IN PENDING on the re-auth:\n" + run.screen().dump())
        else:
            d = e2e_details(run, name, n)
            problems += [f"[sso] {x}" for x in J.frame_problems(scr) + J.detail_problems(scr, "sso", d)]
            if J.badge_bg(scr) != J.STATE_BG["sso"]:
                problems.append(f"sso badge colour {J.badge_bg(scr)}")
        E.server_exec(n, "rm", "-f", "/tmp/sso-on")
        E.server_exec(n, "touch", "/tmp/sso-approve")
        scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and "DISCONNECTED" not in s.all_text()
                           and "SIGN-IN" not in s.all_text(), 45)
        if not scr:
            problems.append("not back to CONNECTED after the second approval:\n" + run.screen().dump())
        stream_checks(run, problems)
        info["mgmt"] = E.server_exec(n, "tail", "-5", "/tmp/mgmt.log").stdout.strip().splitlines()
        return result("e2e SSO (pending at start, pending on re-auth in the panel)", problems, **info)
    except Exception:
        problems.append(traceback.format_exc())
        return result("e2e SSO", problems, **info)
    finally:
        try:
            E.sh("docker", "stop", name)
        finally:
            run.close()
            E.teardown(n)


def t_e2e_ctrl_c_compact(n=3):
    """Start in a 40x7 pane, grow it, then Ctrl-C."""
    name = f"jbx-t{n}-ctrlc"
    E.setup(n)
    run = J.start(E.client_cmd(n, name), 7, 40)
    problems = []
    try:
        scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and not J.frame_problems(s)
                           and "Looking up" not in s.all_text(), 60)
        if not scr:
            problems.append("compact panel never came up:\n" + run.screen().dump())
        else:
            d = e2e_details(run, name, n)
            problems += J.detail_problems(scr, "conn", d)
        run.resize(11, 66)
        time.sleep(1)
        scr = run.screen()
        problems += J.frame_problems(scr)
        mark = run.size_now()
        run.send(b"\x03")
        for _ in range(80):
            if run.proc.poll() is not None:
                break
            time.sleep(0.1)
        ec = E.sh("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout.strip()
        tail = run.data()[0][mark:]
        if ec != "0":
            problems.append(f"exit code {ec} after Ctrl-C")
        if b"Exit complete" not in tail or b"\x1b[?25h" not in tail:
            problems.append("Ctrl-C shutdown output incomplete")
        stream_checks(run, problems, until=mark)
        return result("e2e compact start, grow, Ctrl-C", problems)
    finally:
        run.close()
        E.teardown(n)


# ------------------------------------------------------------------ regression tests for the review findings

def t_openvpn_stopped():
    """No openvpn process: the panel says so instead of a spinning 'retrying'."""
    name = f"jbx-t{SLOT_MOCK}-stopped"
    rm(name)
    run = J.start(mock_cmd(name), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        set_state(name, "down")
        mexec(name, "pkill", "-x", "openvpn")
        scr = run.wait_for(lambda s: "openvpn stopped" in s.row(1) and "OpenVPN is not running" in s.row(8), 15)
        if not scr:
            problems.append("full layout never said openvpn stopped:\n" + run.screen().dump())
        else:
            problems += J.frame_problems(scr)
            if re.search("[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]", scr.row(1) + scr.row(8)):
                problems.append("still spinning: " + scr.row(1).rstrip())
        run.resize(7, 40)
        scr = run.wait_for(lambda s: "OpenVPN is not running" in s.all_text() and not J.frame_problems(s), 5)
        if not scr:
            problems.append("compact layout never said OpenVPN is not running:\n" + run.screen().dump())
        else:
            problems += J.frame_problems(scr)
        stream_checks(run, problems, name=name)
    finally:
        rm(name)
        run.close()
    return result("mock openvpn not running (stopped, not 'retrying')", problems)


def t_paste_then_ctrl_c():
    name = f"jbx-t{SLOT_MOCK}-paste"
    rm(name)
    run = J.start(mock_cmd(name), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        run.send((b"x" * 59 + b"\r") * 200)          # 12 KB of lines
        for _ in range(45):                           # and Enter held down
            run.send(b"\r" * 100)
            time.sleep(0.02)
        time.sleep(1.5)
        scr = run.screen()
        problems += J.frame_problems(scr)
        mark = run.size_now()
        t0 = time.time()
        run.send(b"\x03")
        for _ in range(60):
            if run.proc.poll() is not None:
                break
            time.sleep(0.1)
        dt = time.time() - t0
        ec = subprocess.run(["docker", "inspect", "-f", "{{.State.ExitCode}}", name], capture_output=True, text=True).stdout.strip()
        if run.proc.poll() is None or ec != "0":
            problems.append(f"Ctrl-C after a 12 KB paste: still running after {dt:.1f}s (exit {ec})")
        elif b"Exit complete" not in run.data()[0][mark:]:
            problems.append("no Exit complete after Ctrl-C")
        return result("mock 12 KB paste + held Enter, then Ctrl-C", problems, seconds=round(dt, 2))
    finally:
        rm(name)
        run.close()


def t_slow_lookup():
    """Lookup hosts that time out (split tunnel): the panel keeps going, follows a
    resize, and docker stop is quick and clean."""
    name = f"jbx-t{SLOT_MOCK}-slowlookup"
    rm(name)
    run = J.start(mock_cmd(name, env=dict(MOCK_CURL_DELAY="5", MOCK_IP="fail")), 10, 66)
    problems = []
    info = {}
    try:
        scr = run.wait_for(lambda s: "Looking up the public IP" in s.all_text(), 25)
        if not scr:
            problems.append("panel never showed the lookup note")
        n0 = len(J.paints(run.data()[0]))
        time.sleep(2)
        info["paints_in_2s"] = len(J.paints(run.data()[0])) - n0
        if info["paints_in_2s"] < 7:
            problems.append(f"panel frozen during the lookup: {info['paints_in_2s']} paints in 2s")
        run.resize(7, 40)
        scr = run.wait_for(lambda s: not J.frame_problems(s), 3)
        if not scr:
            problems.append("resize during the lookup not followed:\n" + run.screen().dump())
        mark = run.size_now()
        t0 = time.time()
        subprocess.run(["docker", "stop", name], capture_output=True)
        dt = time.time() - t0
        ec = subprocess.run(["docker", "inspect", "-f", "{{.State.ExitCode}}", name], capture_output=True, text=True).stdout.strip()
        info.update(stop_s=round(dt, 2), exit=ec)
        if ec != "0" or dt > 2.5:
            problems.append(f"docker stop during the lookup: exit {ec} after {dt:.1f}s")
        time.sleep(0.3)
        scr = run.screen()
        if scr.cursor_hidden or not scr.autowrap:
            problems.append(f"terminal left with cursor hidden={scr.cursor_hidden} autowrap={scr.autowrap}")
        return result("mock slow lookup: animates, follows resize, quick clean stop", problems, **info)
    finally:
        rm(name)
        run.close()


def t_lookup_failure_after_delay():
    """The note turns into 'Unable to determine' once the background lookup gives up."""
    name = f"jbx-t{SLOT_MOCK}-lookfail"
    rm(name)
    run = J.start(mock_cmd(name, env=dict(MOCK_CURL_DELAY="1", MOCK_IP="fail")), 10, 66)
    problems = []
    try:
        scr = run.wait_for(lambda s: "Unable to determine from API call" in s.row(3), 20)
        if not scr:
            problems.append("lookup failure never shown:\n" + run.screen().dump())
        prof = mexec(name, "sh", "-c", "grep -c '^export EMOJI=\"\"' /etc/profile").stdout.strip()
        if prof != "1":
            problems.append(f"EMOJI not exported empty when there's no flag ({prof})")
        stream_checks(run, problems, name=name)
    finally:
        rm(name)
        run.close()
    return result("mock lookup failing after a delay; EMOJI exported empty", problems)


def t_term_dumb():
    name = f"jbx-t{SLOT_MOCK}-dumb"
    rm(name)
    run = J.start(mock_cmd(name, env=dict(TERM="dumb")), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        run.send(b"\x03")
        for _ in range(60):
            if run.proc.poll() is not None:
                break
            time.sleep(0.1)
        time.sleep(0.3)
        scr = run.screen()
        if scr.cursor_hidden or not scr.autowrap:
            problems.append(f"TERM=dumb: cursor hidden={scr.cursor_hidden} autowrap={scr.autowrap} after exit")
        if any(c in scr.all_text() for c in "╭╰│"):
            problems.append("TERM=dumb: the panel is still on screen under the shutdown text:\n" + scr.dump())
        if "tput:" in run.data()[0].decode("utf-8", "replace"):
            problems.append("tput errors in the output")
    finally:
        rm(name)
        run.close()
    return result("mock TERM=dumb: exit restores the terminal, clears the panel", problems)


def t_stray_modes():
    name = f"jbx-t{SLOT_MOCK}-modes"
    rm(name)
    run = J.start(mock_cmd(name), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        mexec(name, "sh", "-c", r"printf '\033[?5h\033[4h\033[20h\033[?6h\033[3;5r\033(0junk\033]0;unterminated' > /proc/1/fd/1")
        time.sleep(1.6)
        scr = run.screen()
        bad = [m for m, label in ((pyte.modes.DECSCNM, "DECSCNM"), (pyte.modes.IRM, "IRM"), (pyte.modes.LNM, "LNM"),
                                  (pyte.modes.DECOM, "DECOM")) if m in scr.mode]
        if bad:
            problems.append(f"modes still set after a repaint: {bad}")
        problems += J.frame_problems(scr) + J.detail_problems(scr, "conn", MOCK)
        if problems:
            problems.append(scr.dump())
    finally:
        rm(name)
        run.close()
    return result("mock stray output setting terminal modes", problems)


def t_odd_data():
    """NUL / wide / combining / RTL country names, ESC and CJK in the hostname."""
    problems = []
    cases = [
        ("nul", '{"ip":"192.0.2.10","country_code":"IN","country_name":"In\\u0000dia"}', None, "India"),
        ("cjk", '{"ip":"192.0.2.10","country_code":"JP","country_name":"日本 Japan"}', None, "Japan"),
        ("harakat", '{"ip":"192.0.2.10","country_code":"EG","country_name":"مِصْرُ Egypt"}', None, "Egypt"),
        ("devanagari", '{"ip":"192.0.2.10","country_code":"NP","country_name":"नेपाल Nepal"}', None, "Nepal"),
        ("esc-host", None, "\x1b[31mred", "?[31mred"),
        ("cjk-host", None, "日本host", "??host"),
    ]
    for tag, geo, hostname, want in cases:
        name = f"jbx-t{SLOT_MOCK}-odd-{tag}"
        rm(name)
        env, extra = {}, []
        if geo:
            path = os.path.join(T, "mock", f"geo-odd-{tag}.json")
            with open(path, "w") as f:
                f.write(geo)
            env["MOCK_GEO_FILE"] = f"/t/mock/geo-odd-{tag}.json"
        cmd = mock_cmd(name, env=env)
        if hostname:
            i = cmd.index("--hostname")
            cmd[i + 1] = hostname
        for size in ((10, 66), (10, 80), (7, 40)):
            run = J.start(cmd, *size)
            try:
                scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and "Looking up" not in s.all_text(), 25)
                time.sleep(1.2)
                scr = run.screen()
                p = J.frame_problems(scr)
                # in the compact panel the country gives way to the whole IP and the time
                fits = size[1] >= 66 or tag.endswith("host") or len(want) + 1 + 15 <= size[1] - 7 - 11
                if fits and want not in scr.all_text():
                    p.append(f"expected {want!r} on screen")
                d, _ = run.data()
                if b"warning" in d or J.stream_errors(d):
                    p.append("warning/error text in the stream")
                log_problems(name, p)
                if p:
                    problems += [f"[{tag} {size[0]}x{size[1]}] {x}" for x in p] + [scr.dump()]
            finally:
                rm(name)
                run.close()
    return result("mock odd data (NUL, CJK, combining marks, ESC/CJK hostname)", problems)


def t_compact_sso_alive():
    name = f"jbx-t{SLOT_MOCK}-ssoalive"
    rm(name)
    run = J.start(mock_cmd(name), 7, 40)
    problems = []
    try:
        settle(run, "conn", 25)
        set_state(name, "sso")
        settle(run, "sso", 15)
        seen = set()
        for _ in range(12):
            time.sleep(0.2)
            seen.add(run.screen().all_text())
        if len(seen) < 2:
            problems.append("compact SSO view doesn't change at all over 2.4s")
    finally:
        rm(name)
        run.close()
    return result("mock compact SSO view is visibly alive", problems)


def t_rates_reset():
    name = f"jbx-t{SLOT_MOCK}-ratereset"
    rm(name)
    run = J.start(mock_cmd(name, env=dict(CONNCHECK="ping", MOCK_TRAFFIC="off")), 10, 66)
    problems = []
    try:
        settle(run, "conn", 25)
        # a burst on the old tunnel
        mexec(name, "sh", "-c", "for i in $(seq 1 400); do head -c 1400 /dev/urandom; done | socat -u -b 1400 - INTERFACE:tunpeer")
        time.sleep(1.5)
        mexec(name, "sh", "-c", "ip link del tun0; sleep 1.2; "
                                "ip link add tun0 type veth peer name tunpeer && ip link set tun0 up && ip link set tunpeer up && "
                                "ip addr add 10.99.0.2/24 dev tun0")
        time.sleep(1.6)
        row = run.screen().row(8)
        sparks = row[15:22] + row[36:43]
        if re.search("[▄▅▆▇█]", sparks):
            problems.append(f"old tunnel's burst still in the sparklines after tun0 was recreated: {row.rstrip()!r}")
    finally:
        rm(name)
        run.close()
    return result("mock rate history cleared for a new tun0", problems)


def t_attach_second_client():
    """docker attach from a bigger client: the original pane's rows don't flicker."""
    name = f"jbx-t{SLOT_MOCK}-attach"
    rm(name)
    a = J.start(mock_cmd(name), 7, 40)
    b = None
    problems = []
    try:
        settle(a, "conn", 25)
        b = J.start(["docker", "attach", name], 10, 66)
        time.sleep(1.5)
        set_state(name, "down")
        a.wait_for(lambda s: "DOWN" in s.all_text() or "DISCONNECTED" in s.all_text(), 15)
        time.sleep(1.5)
        lasts = set()
        for _ in range(12):
            time.sleep(0.09)
            lasts.add(a.screen().row(6))
        if len(lasts) > 1:
            problems.append(f"the small pane's last row changes between paints: {sorted(lasts)}")
        b.send(b"\x10\x11")      # Ctrl-P Ctrl-Q detaches b
    finally:
        rm(name)
        a.close()
        if b:
            b.close()
    return result("mock second client attached at a bigger size: no flicker", problems)


def t_e2e_vpn_restart_lock(n=4):
    name = f"jbx-t{n}-lock"
    E.setup(n)
    run = J.start(E.client_cmd(n, name), 10, 66)
    problems = []
    info = {}
    try:
        if not run.wait_for(lambda s: "CONNECTED" in s.all_text() and "Looking up" not in s.all_text(), 60):
            problems.append("never connected")
            return result("e2e vpn-restart lock", problems)
        import threading
        outs = {}
        def go(k):
            outs[k] = E.sh("docker", "exec", name, "vpn-restart").stdout
        th = [threading.Thread(target=go, args=(k,)) for k in (1, 2)]
        th[0].start(); time.sleep(0.3); th[1].start()
        for t in th:
            t.join(120)
        both = outs.get(1, "") + outs.get(2, "")
        info["first"] = outs.get(1, "")[-120:]
        info["second"] = outs.get(2, "")[-120:]
        if "already running" not in both:
            problems.append("the second, concurrent vpn-restart wasn't refused")
        if "VPN restarted successfully" not in both:
            problems.append("neither vpn-restart succeeded")
        nproc = E.sh("docker", "exec", name, "sh", "-c", "pgrep -x openvpn | wc -l").stdout.strip()
        info["openvpn_procs"] = nproc
        if nproc != "1":
            problems.append(f"{nproc} openvpn processes after the two runs")
        holders = E.sh("docker", "exec", name, "sh", "-c",
                       "for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep -q vpn-restart.lock && echo ${p#/proc/}; done").stdout.split()
        if holders:
            problems.append(f"lock still held after vpn-restart finished, by pids {holders}")
        out3 = E.sh("docker", "exec", name, "vpn-restart").stdout
        if "VPN restarted successfully" not in out3:
            problems.append("a later vpn-restart didn't run: " + out3[-200:])
        size = E.sh("docker", "exec", name, "sh", "-c", "wc -c < /var/log/openvpn.log").stdout.strip()
        info["openvpn_log_bytes"] = size
        if size.isdigit() and int(size) > 5_000_000:
            problems.append(f"openvpn log grew to {size} bytes")
        scr = run.wait_for(lambda s: "CONNECTED" in s.all_text() and "DISCONNECTED" not in s.all_text(), 30)
        if not scr:
            problems.append("panel not back to CONNECTED:\n" + run.screen().dump())
        stream_checks(run, problems, name=name)
        return result("e2e vpn-restart lock (concurrent refused, lock released)", problems, **info)
    finally:
        E.sh("docker", "stop", name)
        run.close()
        E.teardown(n)


# ------------------------------------------------------------------ re-pin, SSO lapse, headless

def connected(scr):
    t = scr.all_text()
    return "CONNECTED" in t and "DISCONNECTED" not in t and "Looking up" not in t


def dexec(name, *args):
    return E.sh("docker", "exec", name, *args)


def pins_of(name):
    return dexec(name, "grep", "jumpbox-pin", "/etc/hosts").stdout.strip().splitlines()


def hosts_ok(name, problems):
    if dexec(name, "grep", "-c", "localhost", "/etc/hosts").stdout.strip() in ("", "0"):
        problems.append("/etc/hosts lost its own (localhost) entries")


def t_e2e_server_new_ip(n=5):
    """The server comes back on a new address: the watcher re-pins and OpenVPN follows by itself."""
    name = f"jbx-t{n}-newip"
    net, srv = E.names(n)
    E.setup(n)
    ip0 = E.container_ip(srv)
    run = J.start(E.client_cmd(n, name), 10, 66)
    problems, info = [], {}
    try:
        if not run.wait_for(connected, 60):
            problems.append("never connected:\n" + run.screen().dump())
            return result("e2e server back on a new address", problems)
        info["pins_before"] = pins_of(name)
        E.sh("docker", "rm", "-f", srv)
        if not run.wait_for(lambda s: "DISCONNECTED" in s.all_text(), 30):
            problems.append("no DISCONNECTED after the server went")
        time.sleep(5)
        # something else takes the old address, so the server gets a new one
        E.sh("docker", "run", "-d", "--name", f"jbx-t{n}-pad", "--network", net, "--entrypoint", "/bin/sh",
             E.IMAGE, "-c", "sleep 900")
        ip1 = E.start_server(n)
        info["server_ip"] = [ip0, ip1]
        if ip1 == ip0:
            problems.append(f"test setup: the server came back on the same address {ip1}")
        t_back = time.time()
        scr = run.wait_for(connected, 120)
        info["reconnected_after_back_s"] = round(time.time() - t_back, 1) if scr else None
        if not scr:
            problems.append(f"no reconnect within 120s of the server coming back on {ip1}:\n" + run.screen().dump())
        info["pins_after"] = pins_of(name)
        if info["pins_after"] != [f"{ip1} {srv} # jumpbox-pin"]:
            problems.append(f"pins after: {info['pins_after']}")
        info["events"] = dexec(name, "cat", "/var/log/jumpbox.log").stdout.strip().splitlines()
        if not any("moved to a new address" in e for e in info["events"]):
            problems.append("no 'moved' event in /var/log/jumpbox.log")
        hosts_ok(name, problems)
        stream_checks(run, problems, name=name)
        return result("e2e server back on a new address: re-pinned, reconnected by itself", problems, **info)
    finally:
        E.sh("docker", "stop", name)
        run.close()
        E.teardown(n)


def t_e2e_long_outage(n=8):
    """A 75s outage on the same address: the re-pin finds nothing moved and changes nothing."""
    name = f"jbx-t{n}-outage"
    _, srv = E.names(n)
    E.setup(n)
    run = J.start(E.client_cmd(n, name), 10, 66)
    problems, info = [], {}
    try:
        if not run.wait_for(connected, 60):
            problems.append("never connected")
            return result("e2e 75s outage, same address", problems)
        before = dexec(name, "md5sum", "/etc/hosts").stdout.split()[:1]
        E.sh("docker", "pause", srv)
        time.sleep(75)
        mid = dexec(name, "md5sum", "/etc/hosts").stdout.split()[:1]
        E.sh("docker", "unpause", srv)
        t_back = time.time()
        scr = run.wait_for(connected, 90)
        info["reconnected_after_back_s"] = round(time.time() - t_back, 1) if scr else None
        if not scr:
            problems.append("no reconnect after the outage:\n" + run.screen().dump())
        after = dexec(name, "md5sum", "/etc/hosts").stdout.split()[:1]
        if not (before == mid == after):
            problems.append(f"/etc/hosts changed: {before} {mid} {after}")
        ev = dexec(name, "cat", "/var/log/jumpbox.log").stdout
        if "moved" in ev:
            problems.append("a 'moved' event for a server that never moved: " + ev.strip())
        hosts_ok(name, problems)
        stream_checks(run, problems, name=name)
        return result("e2e 75s outage, same address: nothing re-pinned, normal reconnect", problems, **info)
    finally:
        E.sh("docker", "stop", name)
        run.close()
        E.teardown(n)


def t_e2e_server_gone(n=9):
    """The server's name stops resolving for 75s: the old pin is kept, then the client reconnects."""
    name = f"jbx-t{n}-gone"
    _, srv = E.names(n)
    E.setup(n)
    run = J.start(E.client_cmd(n, name), 10, 66)
    problems, info = [], {}
    try:
        if not run.wait_for(connected, 60):
            problems.append("never connected")
            return result("e2e server name gone for 75s", problems)
        pins0 = pins_of(name)
        E.sh("docker", "rm", "-f", srv)
        time.sleep(75)
        pins1 = pins_of(name)
        info["pins"] = [pins0, pins1]
        if pins1 != pins0:
            problems.append(f"pins changed while the name didn't resolve: {pins0} -> {pins1}")
        E.start_server(n)
        scr = run.wait_for(connected, 120)
        if not scr:
            problems.append("no reconnect once the server was back:\n" + run.screen().dump())
        if "moved" in dexec(name, "cat", "/var/log/jumpbox.log").stdout and E.container_ip(srv) in " ".join(pins0):
            problems.append("a 'moved' event though the server came back where it was")
        hosts_ok(name, problems)
        stream_checks(run, problems, name=name)
        return result("e2e server name gone for 75s: old pin kept, reconnected", problems, **info)
    finally:
        E.sh("docker", "stop", name)
        run.close()
        E.teardown(n)


def t_e2e_sso_lapse(n=6):
    """A re-auth sign-in left unapproved: one URL, then OpenVPN stopped with the reason on the panel;
    vpn-restart recovers."""
    name = f"jbx-t{n}-lapse"
    E.setup(n, sso=True)
    run = J.start(E.client_cmd(n, name, env=dict(SSO="true")), 10, 66)
    problems, info = [], {}
    try:
        if not run.wait_for(connected, 60):
            problems.append("never connected:\n" + run.screen().dump())
            return result("e2e SSO re-auth left unapproved", problems)
        E.server_exec(n, "sh", "-c", "echo 30 > /tmp/sso-timeout; touch /tmp/sso-on")
        dexec(name, "pkill", "-USR1", "-x", "openvpn")
        if not run.wait_for(lambda s: "SIGN-IN PENDING" in s.all_text(), 40):
            problems.append("never showed SIGN-IN PENDING:\n" + run.screen().dump())
        t0 = time.time()
        scr = run.wait_for(lambda s: "openvpn stopped" in s.row(1) and "SSO sign-in not completed in time" in s.row(8), 70)
        info["stopped_after_s"] = round(time.time() - t0, 1) if scr else None
        if not scr:
            problems.append("panel never said the sign-in ran out:\n" + run.screen().dump())
        else:
            problems += J.frame_problems(scr)
        time.sleep(40)                     # nothing may start over on its own
        # distinct URLs: the server repeats a pending one while the client asks for
        # its config, and sso-url -f only opens a tab for a new URL
        urls = sorted(set(re.findall(r"pushed by server \('WEB_AUTH::([^']+)'\)",
                                     dexec(name, "cat", "/var/log/openvpn.log").stdout)))
        info["sign_in_urls"] = urls
        if len(urls) != 1:
            problems.append(f"{len(urls)} different sign-in URLs, expected exactly 1: {urls}")
        if dexec(name, "pgrep", "-x", "openvpn").stdout.strip():
            problems.append("OpenVPN still running after the window ran out")
        if dexec(name, "sso-url").returncode == 0:
            problems.append("sso-url still hands out a URL")
        info["events"] = dexec(name, "cat", "/var/log/jumpbox.log").stdout.strip().splitlines()
        if not any("window ran out" in e for e in info["events"]):
            problems.append("no 'window ran out' event logged")
        # compact layout says it too
        run.resize(7, 40)
        scr = run.wait_for(lambda s: "SSO sign-in not completed" in s.all_text() and not J.frame_problems(s), 5)
        if not scr:
            problems.append("compact panel lacks the reason:\n" + run.screen().dump())
        run.resize(10, 66)
        # recovery
        E.server_exec(n, "rm", "-f", "/tmp/sso-on")
        vr = dexec(name, "vpn-restart")
        if "VPN restarted successfully" not in vr.stdout:
            problems.append("vpn-restart didn't recover: " + vr.stdout[-300:])
        if not run.wait_for(connected, 30):
            problems.append("panel not CONNECTED after vpn-restart:\n" + run.screen().dump())
        if dexec(name, "test", "-e", "/run/jumpbox/stopped").returncode == 0:
            problems.append("stop reason still there after vpn-restart")
        stream_checks(run, problems, name=name)
        return result("e2e SSO re-auth left unapproved: one URL, stopped with the reason, vpn-restart recovers", problems, **info)
    finally:
        E.sh("docker", "stop", name)
        run.close()
        E.teardown(n)


def headless_logs(name):
    return subprocess.run(["docker", "logs", name], capture_output=True).stdout


def wait_logs(name, needle, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if needle.encode() in headless_logs(name):
            return True
        time.sleep(0.5)
    return False


def t_headless_mock():
    """docker run -d: no panel, a plain timestamped line per state change, clean stop."""
    name = f"jbx-t{SLOT_MOCK}-headless"
    rm(name)
    cmd = mock_cmd(name)
    cmd[cmd.index("-it")] = "-d"
    subprocess.run(cmd, capture_output=True)
    problems, info = [], {}
    try:
        for needle, action in (("connected, public IP 198.51.100.147 (India)", None),
                               ("disconnected, waiting for outbound connectivity", ("down",)),
                               ("SSO sign-in pending: https://sso.example.test/login?sess=42", ("sso",)),
                               ("disconnected: OpenVPN is not running, run vpn-restart", ("stop",))):
            if action == ("down",) or action == ("sso",):
                set_state(name, action[0])
            elif action == ("stop",):
                mexec(name, "pkill", "-x", "openvpn")
            if not wait_logs(name, needle, 20):
                problems.append(f"no log line {needle!r}")
        t0 = time.time()
        subprocess.run(["docker", "stop", name], capture_output=True)
        dt = time.time() - t0
        ec = subprocess.run(["docker", "inspect", "-f", "{{.State.ExitCode}}", name], capture_output=True, text=True).stdout.strip()
        info.update(stop_s=round(dt, 2), exit=ec)
        if ec != "0" or dt > 3:
            problems.append(f"docker stop: exit {ec} after {dt:.1f}s")
        logs = headless_logs(name)
        info["lines"] = logs.decode("utf-8", "replace").strip().splitlines()[:12]
        if b"\x1b" in logs:
            problems.append("escape sequences in the headless log")
        if b"Exit complete" not in logs:
            problems.append("no Exit complete")
        if re.search(rb"(inc\.sh|start\.sh): line|tput:", logs):
            problems.append("error text in the log")
        return result("mock headless (docker run -d): plain lines per state change, clean stop", problems, **info)
    finally:
        rm(name)


def t_e2e_headless(n=10):
    name = f"jbx-t{n}-headless"
    E.setup(n)
    subprocess.run(E.client_cmd(n, name, tty=False), capture_output=True)
    problems, info = [], {}
    try:
        if not wait_logs(name, "connected, public IP", 60):
            problems.append("no 'connected, public IP' line in docker logs")
        t0 = time.time()
        subprocess.run(["docker", "stop", name], capture_output=True)
        ec = subprocess.run(["docker", "inspect", "-f", "{{.State.ExitCode}}", name], capture_output=True, text=True).stdout.strip()
        if ec != "0" or time.time() - t0 > 3:
            problems.append(f"docker stop: exit {ec} after {time.time() - t0:.1f}s")
        logs = headless_logs(name)
        info["lines"] = logs.decode("utf-8", "replace").strip().splitlines()
        if b"\x1b" in logs:
            problems.append("escape sequences in the headless log")
        for w in (b"Starting...", b"Connect using:", b"Waiting for connection", b"Exit complete"):
            if w not in logs:
                problems.append(f"log lacks {w!r}")
        return result("e2e headless start.sh (docker run -d): plain startup, status and shutdown lines", problems, **info)
    finally:
        E.teardown(n)


# ------------------------------------------------------------------ motd
# The welcome screen (configs/motd.sh) a login shell in the container prints.
# Shells are opened the way the README opens one, docker exec -it
# <container> bash -l (or sh -l), into a connected mock container, under a
# pty of each size.

MOTD_ENV = dict(DCN="jbx-mock", OVPNFILE="example-gateway-sso.ovpn")
# The wide, medium and compact layouts at their edges, and the tiny one
MOTD_SIZES = [(24, 80), (36, 120), (40, 160), (30, 100), (24, 64), (20, 50), (16, 40), (14, 30), (12, 30), (6, 20)]
PROMPT = b"[Project Jumpbox]"
CLEAR = b"\x1b[H\x1b[2J"
NEVER = "the mock never connected, or its IP lookup never finished"
# Twenty aliases with long names, as a CUSTOMCONF script would add them
ALIASES = ("ssh-prod-database-primary ssh-prod-database-replica bastion-eu bastion-us alerts grafana kibana "
           "jenkins build1 build2 build3 pve1 pve2 pve3 pve4 ipmi-rack1 ipmi-rack2 switch-core fw-edge vpn-test").split()
# Each state's badge as the motd draws it (the panel's at its first tick),
# long and short. The state is told by its badge: a word alone can't do it,
# CONNECTED being a part of DISCONNECTED.
MOTD_BADGES = {"conn": ("◉ CONNECTED", "◉ UP"), "down": ("✕ DISCONNECTED", "✕ DOWN"), "sso": ("◇ SIGN-IN", "◇ SSO")}
# In the motd's own output: nothing but its colours (reset, bold, 24-bit
# foreground and background) and line ends
NOT_SGR = re.compile(rb"\x1b(?!\[(?:0|1|[34]8;2;\d+;\d+;\d+)m)")
CONTROL = re.compile(rb"[\x00-\x09\x0b\x0c\x0e-\x1a\x1c-\x1f\x7f]")


def motd_append(name, path, text):
    """Append text to a file in the container, any bytes, no shell quoting involved."""
    subprocess.run(["docker", "exec", "-i", name, "sh", "-c", f"cat >> {path}"], input=text.encode(), capture_output=True)


def wait_until(fn, timeout, step=0.25):
    """Poll fn() until it's true, for up to timeout seconds."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if fn():
            return True
        time.sleep(step)
    return False


def listening(name, *ports):
    """Something listens on each port (in hex, as /proc/net/tcp has them) in the container."""
    t = mexec(name, "cat", "/proc/net/tcp", "/proc/net/tcp6").stdout
    return all(re.search(rf":{p} [0-9A-F:]+ 0A ", t) for p in ports)


def motd_mock(name, env=None, extra=None, healthy=False):
    """A connected mock container to open shells in, its IP lookup done
    (run.mock_ok: it got there). Returns the panel's run: keep it open,
    closing it stops the container. healthy: with what a start.sh container
    has as well - the kill switch and IPv6 block, SOCKS5 and sshd - so no
    check needs attention."""
    rm(name)
    run = J.start(mock_cmd(name, env=dict(MOTD_ENV, **(env or {})), extra=extra), 10, 66)
    run.mock_ok = bool(run.wait_for(lambda s: shows_state(s, "conn") and "Looking up" not in s.all_text(), 25))
    if healthy and run.mock_ok:
        mexec(name, "bash", "-c", "source /config/inc.sh; killSwitch; sockdStart; sshdStart")
        run.mock_ok = wait_until(lambda: listening(name, "0438", "0016"), 15)
    return run


def motd_shell(name, rows, cols, shell="bash"):
    """A login shell in the container, opened as the README opens one; the
    run once its prompt is up. The motd's error log is emptied first, so
    what's in it is this shell's."""
    mexec(name, "sh", "-c", ": > /var/log/jumpbox-motd.log")
    run = J.start(["docker", "exec", "-it", name, shell, "-l"], rows, cols,
                  env=dict(os.environ, DOCKER_CLI_HINTS="false"))
    run.wait_bytes(PROMPT, 15)
    time.sleep(0.3)
    return run


def motd_close(run):
    """Leave the shell (closing the pty alone leaves it running) and close the run."""
    run.send(b"exit\r")
    time.sleep(0.2)
    run.close()


def motd_checks(name, run, rows, cols):
    """What every motd must do: get to the prompt with no error text; clear
    the screen once, never the scrollback; write nothing but its colours
    and line ends; no line wider than the pane, and its boxes' lines all one
    width (a text measured wrong breaks a border); the top still on screen
    above the prompt, however many rows that takes; the cursor shown and
    line wrap on afterwards; nothing in its error log."""
    probs = []
    data, _ = run.data()
    if PROMPT not in data:
        probs.append("no prompt")
    errs = J.stream_errors(data)
    if errs:
        probs.append(f"error text: {errs[:2]}")
    if b"\x1b[3J" in data:
        probs.append("the scrollback was wiped (\\e[3J)")
    start = data.find(CLEAR)
    if start < 0:
        probs.append("no clear screen before the motd")
    else:
        # The motd's lines: from its clear to the end of its last one. What
        # comes after (bash's bracketed-paste mode, the prompt) is the shell's.
        start += len(CLEAR)
        p = data.find(PROMPT, start)
        end = data.rfind(b"\n", start, p if p >= 0 else len(data)) + 1 or start
        motd = data[start:end]
        m = NOT_SGR.search(motd)
        if m:
            probs.append(f"an escape that isn't a colour: {motd[m.start():m.start() + 12]!r}")
        m = CONTROL.search(motd)
        if m:
            probs.append(f"a control byte: {motd[m.start():m.start() + 1]!r}")
        widths = J.line_widths(motd)
        for i, (w, t) in enumerate(widths):
            if w > cols:
                probs.append(f"line {i} is {w} cells wide in {cols} columns: {t[:80]!r}")
        box = sorted({w for w, t in widths if t[:2] in (" ╭", " │", " ╰")})
        if len(box) > 1:
            probs.append(f"the boxes' lines aren't all one width: {box}")
        height = motd.count(b"\n")
        pw = J.line_widths(data[end:])[0][0]
        prompt_rows = max(1, -(-pw // cols))
        if height + prompt_rows > rows:
            probs.append(f"{height} lines and the prompt's {prompt_rows} rows don't fit in {rows}: the top scrolled away")
    scr = run.screen()
    if scr.cursor_hidden or not scr.autowrap:
        probs.append(f"left the cursor hidden ({scr.cursor_hidden}) or line wrap off ({not scr.autowrap})")
    log = mexec(name, "cat", "/var/log/jumpbox-motd.log").stdout.strip()
    if log:
        probs.append(f"motd error log: {log[:400]}")
    return probs


def motd_want(state, rows, cols, caution=False):
    """Text the motd shows for the mock at that size, besides its badge; a
    tuple is any one of its texts, a pattern a match. caution: what the
    mock as it starts is missing (the kill switch, the IPv6 block, SOCKS5
    and sshd), each one shown, connected being CAUTION."""
    want = ["10079"]
    if cols >= 50:
        want += ["12080", "198.51.100.147"]
        # What it's doing and what to run, so neither state passes for the other
        if state == "down":
            want += ["Waiting for", "to start over"]
        elif state == "stopped":
            want += ["completed in time", "to reconnect"]
        elif state == "starting":
            want.append("OpenVPN is starting")
        elif state == "starting-otp":
            want.append("one-time code")
        elif state == "sso":
            want.append("sso-url")
    if state == "conn" and rows >= 24 and cols >= 64:
        # The tunnel's details, as mock.sh logs them
        want.append("X25519MLKEM768")
        if cols >= 80:
            want += ["192.0.2.10:1194", "AES-256-GCM", "TLSv1.3", "10.99.0.2/24", ("◆ post-quantum", "◆ PQ")]
    if caution and state == "conn":
        if cols >= 30:
            want += ["need attention", "kill switch off", "IPv6 open", "SOCKS5 down", "SSH down"]
        else:
            # The tiny layout: the four as a count
            want.append(re.compile(r"UP ▲ 4"))
    return want


def motd_text_problems(scr, want):
    t = scr.all_text()
    probs = []
    for w in want:
        if isinstance(w, re.Pattern):
            if not w.search(t):
                probs.append(f"missing {w.pattern!r}")
        elif not any(x in t for x in (w if isinstance(w, tuple) else (w,))):
            probs.append(f"missing {w!r}")
    return probs


def motd_state_problems(scr, st):
    """The badge says the state (stopped and starting are down), and no other badge is there."""
    t = scr.all_text()
    want = "down" if st in ("stopped", "starting", "starting-otp") else st
    shown = [s for s, badges in MOTD_BADGES.items() if any(b in t for b in badges)]
    return [] if shown == [want] else [f"the badge says {'/'.join(shown) or 'nothing'}, not {want}"]


def motd_wide_problems(scr, cols):
    """From 100 columns, the wide layout: ACCESS and TUNNEL side by side."""
    if cols >= 100 and not any("ACCESS" in t and "TUNNEL" in t for t in scr.text):
        return ["ACCESS and TUNNEL aren't side by side, as the wide layout has them"]
    return []


def t_motd_layouts():
    """Every size, the tiny one too, twenty long aliases: within the pane,
    the top on screen, the layout the size calls for, the essentials shown
    - each check that needs attention among them."""
    name = f"jbx-t{SLOT_MOCK}-motd"
    title = "motd at every size, with twenty long aliases"
    panel = motd_mock(name)
    problems = []
    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        motd_append(name, "/root/.profile", "".join(f"alias {a}='ssh {a}'\n" for a in ALIASES))
        for rows, cols in MOTD_SIZES:
            run = motd_shell(name, rows, cols)
            try:
                scr = run.screen()
                p = (motd_checks(name, run, rows, cols) + motd_state_problems(scr, "conn")
                     + motd_text_problems(scr, motd_want("conn", rows, cols, caution=True))
                     + motd_wide_problems(scr, cols))
                if cols >= 80 and rows >= 24 and not any(a in scr.all_text() for a in ALIASES[:3]):
                    p.append("no aliases shown")
                if p:
                    problems += [f"[{rows}x{cols}] {x}" for x in p] + [scr.dump()]
            finally:
                motd_close(run)
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_healthy():
    """The screen users see every day: connected, with the kill switch, the
    IPv6 block and both listeners up. Every size, without aliases and with
    twenty: nothing shows as failed or needing attention."""
    name = f"jbx-t{SLOT_MOCK}-motd-healthy"
    title = "motd on a healthy connection, at every size, without aliases and with twenty"
    panel = motd_mock(name, healthy=True)
    problems = []
    try:
        if not panel.mock_ok:
            return result(title, [NEVER + " (or its listeners never came up)"])
        for tag in ("no aliases", "aliases"):
            if tag == "aliases":
                motd_append(name, "/root/.profile", "".join(f"alias {a}='ssh {a}'\n" for a in ALIASES))
            for rows, cols in MOTD_SIZES:
                run = motd_shell(name, rows, cols)
                try:
                    scr = run.screen()
                    t = scr.all_text()
                    p = (motd_checks(name, run, rows, cols) + motd_state_problems(scr, "conn")
                         + motd_text_problems(scr, motd_want("conn", rows, cols)) + motd_wide_problems(scr, cols))
                    # CAUTION is "N checks need attention", or "UP ▲ N" in the
                    # tiny layout (a ▲ alone is the upload arrow); ◌ a check
                    # that couldn't be read
                    if "✕" in t or "◌" in t or "attention" in t or re.search(r"UP ▲ \d", t):
                        p.append("something shows as failed, unknown or needing attention")
                    if p:
                        problems += [f"[{tag} {rows}x{cols}] {x}" for x in p] + [scr.dump()]
                finally:
                    motd_close(run)
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_states():
    """Down, SSO pending, back up, stopped with a reason - before the
    watcher has seen OpenVPN go as well as after - and starting (start.sh's
    marker, OpenVPN not running yet), plain and waiting for the one-time
    code: the motd's badge says which, and what to run or do. While it's
    starting vpn-restart waits for start.sh's lock, then says so and does
    nothing."""
    name = f"jbx-t{SLOT_MOCK}-motd-states"
    title = "motd states: down, sso, conn, stopped (unseen and seen), starting (and on the OTP); vpn-restart then"
    panel = motd_mock(name)
    problems = []

    def look(tag, st):
        for rows, cols in ((24, 80), (20, 50)):
            run = motd_shell(name, rows, cols)
            try:
                scr = run.screen()
                p = (motd_checks(name, run, rows, cols) + motd_state_problems(scr, st)
                     + motd_text_problems(scr, motd_want(st, rows, cols, caution=True)))
                if st.startswith("starting"):
                    # Nothing to run yet, and the last run's reason doesn't stand
                    p += [f"shows {x!r}" for x in ("to reconnect", "to start over", "completed in time", "stopped")
                          if x in scr.all_text()]
                if p:
                    problems.extend([f"[{tag} {rows}x{cols}] {x}" for x in p] + [scr.dump()])
            finally:
                motd_close(run)

    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        for st in ("down", "sso", "conn", "stopped", "starting", "starting-otp"):
            if st == "stopped":
                # Held still, the watcher can't see OpenVPN go: the motd
                # mustn't take its last word (connected) for it
                pid = mexec(name, "cat", "/.conn_check_pid").stdout.strip()
                if not pid.isdigit():
                    problems.append("[stopped] no watcher to hold still")
                    continue
                mexec(name, "kill", "-STOP", pid)
                mexec(name, "pkill", "-x", "openvpn")
                mexec(name, "sh", "-c", "mkdir -p /run/jumpbox; echo 'SSO sign-in not completed in time' > /run/jumpbox/stopped")
                if wait_until(lambda: mexec(name, "pgrep", "-x", "openvpn").returncode != 0, 10):
                    look("stopped, unseen", st)
                else:
                    problems.append("[stopped] OpenVPN never went")
                mexec(name, "kill", "-CONT", pid)
                # Settled once the watcher has seen it go (it looks every 5s)
                there = wait_until(lambda: mexec(name, "cat", "/.conn_check").stdout.strip() == "1", 20)
            elif st == "starting":
                there = mexec(name, "touch", "/run/jumpbox/starting").returncode == 0
            elif st == "starting-otp":
                # connectOvpn at its prompt for the code
                there = mexec(name, "sh", "-c", "echo otp > /run/jumpbox/starting").returncode == 0
            else:
                set_state(name, st)
                there = settle(panel, st, 20)
            if not there:
                problems.append(f"[{st}] the mock never got there")
                continue
            look(st, st)
        # start.sh holds the lock till its OpenVPN runs. Gone ahead,
        # vpn-restart's first step would be to delete tun0.
        subprocess.run(["docker", "exec", "-d", name, "flock", "/run/vpn-restart.lock", "sleep", "29"], capture_output=True)
        if wait_until(lambda: mexec(name, "flock", "-n", "/run/vpn-restart.lock", "true").returncode != 0, 5):
            for marker, said in (("otp", "waiting for the one-time code on its console: docker attach"), ("", "still starting")):
                mexec(name, "sh", "-c", f"echo {marker} > /run/jumpbox/starting" if marker else ": > /run/jumpbox/starting")
                r = mexec(name, "vpn-restart")
                if r.returncode != 1 or said not in r.stdout:
                    problems.append(f"[vpn-restart while starting {marker}] exit {r.returncode}: {r.stdout.strip()[-200:]!r}")
                if mexec(name, "ip", "link", "show", "tun0").returncode != 0:
                    problems.append(f"[vpn-restart while starting {marker}] it went ahead: tun0 is gone")
                    break
        else:
            problems.append("[vpn-restart while starting] couldn't take the lock to hold it")
        mexec(name, "pkill", "-f", "sleep 29")
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_quiet():
    """No motd unless an interactive shell writes to a terminal and wasn't given a command: scripted logins keep their output."""
    name = f"jbx-t{SLOT_MOCK}-motd-quiet"
    title = "motd stays out of scripted logins (bash -lc, -t, bash -lic / sh -lic, piped sh -l / bash -li)"
    panel = motd_mock(name)
    problems = []
    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        env = dict(os.environ, DOCKER_CLI_HINTS="false")
        cases = (("bash -lc", ["docker", "exec", name, "bash", "-lc", "echo hi"], None, b"hi\n"),
                 ("tty bash -lc", ["docker", "exec", "-t", name, "bash", "-lc", "echo hi"], None, b"hi\r\n"),
                 ("tty bash -lic", ["docker", "exec", "-t", name, "bash", "-lic", "echo hi"], None, b"hi\r\n"),
                 ("tty sh -lic", ["docker", "exec", "-t", name, "sh", "-lic", "echo hi"], None, b"hi\r\n"),
                 ("sh -l, piped", ["docker", "exec", "-i", name, "sh", "-l"], b"echo hi\nexit\n", b"hi\n"),
                 ("bash -li, piped", ["docker", "exec", "-i", name, "bash", "-li"], b"echo hi\nexit\n", b"hi\n"))
        for tag, cmd, stdin, want in cases:
            r = subprocess.run(cmd, input=stdin, capture_output=True, env=env, timeout=30)
            if r.stdout != want:
                problems.append(f"[{tag}] stdout {r.stdout[:200]!r}, expected {want!r}")
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_ash():
    """sh -l (busybox ash), the shell command the panel shows: same motd, then the prompt."""
    name = f"jbx-t{SLOT_MOCK}-motd-ash"
    title = "motd under sh -l (busybox ash)"
    panel = motd_mock(name)
    problems = []
    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        run = motd_shell(name, 24, 80, shell="sh")
        try:
            scr = run.screen()
            problems += (motd_checks(name, run, 24, 80) + motd_state_problems(scr, "conn")
                         + motd_text_problems(scr, motd_want("conn", 24, 80, caution=True)))
            if problems:
                problems.append(scr.dump())
        finally:
            motd_close(run)
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_odd():
    """Data the motd has to read as the system does: a point-to-point tun0
    (topology net30, with the route to the server's own tunnel address it
    pushes), the server over IPv6, resolv.conf as musl reads it (an indented
    nameserver, one with a port, a fourth), aliases defined twice, two on a
    line, after --, chained with ; and quoted whole, a line going on with
    something else after ;, the last line with no newline, and a mount
    point with a space in it."""
    name = f"jbx-t{SLOT_MOCK}-motd-odd"
    title = "motd with net30 tun0, an IPv6 server, musl's resolv.conf, odd alias lines, a mount with a space"
    panel = motd_mock(name, extra=["-v", f"{T}/mock:/root/my share:ro"])
    problems = []
    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        mexec(name, "sh", "-c", "ip addr flush dev tun0 && ip addr add 10.78.0.6 peer 10.78.0.5 dev tun0 "
                                "&& ip route add 10.20.0.0/16 via 10.78.0.5 dev tun0 "
                                "&& ip route add 10.78.0.1 via 10.78.0.5 dev tun0")
        motd_append(name, "/var/log/openvpn.log", "2026-10-26 10:00:00 TCPv6_CLIENT link remote: [AF_INET6]2001:db8::10:1194\n")
        # Two pushed servers as setdns writes them (the second indented, which
        # musl skips), one with a port (not an address, so skipped too), then
        # two more: musl takes the first three it can use
        mexec(name, "sh", "-c", "printf 'search corp.example\\nnameserver 10.20.0.53\\n        nameserver 10.20.1.53\\n"
                                "nameserver 10.20.9.53:53\\nnameserver 10.20.2.53\\nnameserver 10.20.3.53\\n"
                                "nameserver 10.20.4.53\\n' > /etc/resolv.conf")
        motd_append(name, "/root/.profile", "alias dup-probe='echo 1'\nalias dup-probe='echo 2'\n"
                                            "alias two-a='echo a' two-b=\"echo \\\"b\\\" x=y\"\nalias -- opt-probe='echo c'\n"
                                            "alias semi-probe='ls -la'; PATH=$PATH:/opt/tools/bin\n"
                                            "alias chain-a='echo a'; alias chain-b='echo b'\n"
                                            "alias 'quoted-probe=ls -la'\nalias last-probe='echo z'")
        for rows, cols in ((36, 120), (40, 160)):
            run = motd_shell(name, rows, cols)
            try:
                scr = run.screen()
                t = scr.all_text()
                p = motd_checks(name, run, rows, cols) + motd_state_problems(scr, "conn")
                p += motd_text_problems(scr, ["10.78.0.6/32", "split, 1 route", "[2001:db8::10]:1194", "10.20.0.53",
                                              "10.20.2.53", "10.20.3.53", "two-a", "two-b", "opt-probe", "semi-probe",
                                              "chain-a", "chain-b", "quoted-probe", "last-probe", "/root/my share"])
                for gone in ("10.20.1.53", "10.20.9.53", "10.20.4.53"):
                    if gone in t:
                        p.append(f"{gone} is shown, but the resolver doesn't use it")
                if "PATH" in t:
                    p.append("PATH (set after an alias on its line) is shown as an alias")
                if t.count("dup-probe") != 1:
                    p.append(f"dup-probe is shown {t.count('dup-probe')} times, not once")
                if p:
                    problems += [f"[{rows}x{cols}] {x}" for x in p] + [scr.dump()]
            finally:
                motd_close(run)
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_ctrlc():
    """Ctrl-C while the motd runs ends the motd and nothing more: the rest of
    ~/.profile, the aliases set up there, still runs, under bash -l and sh
    -l. resolv.conf padded with comments holds the motd up long enough to
    interrupt it."""
    name = f"jbx-t{SLOT_MOCK}-motd-ctrlc"
    title = "Ctrl-C during the motd keeps the rest of ~/.profile (bash -l, sh -l)"
    panel = motd_mock(name)
    problems = []
    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        motd_append(name, "/root/.profile", "alias ctrlc-probe='echo ok'\n")
        mexec(name, "sh", "-c", "yes '# padding' | head -n 150000 >> /etc/resolv.conf")
        for shell in ("bash", "sh"):
            run = J.start(["docker", "exec", "-it", name, shell, "-l"], 24, 80, env=dict(os.environ, DOCKER_CLI_HINTS="false"))
            try:
                time.sleep(1.2)
                data = run.data()[0]
                if CLEAR in data or PROMPT in data:
                    problems.append(f"[{shell}] the motd was done before Ctrl-C: nothing to interrupt")
                    continue
                off = len(data)
                run.send(b"\x03")
                if not run.wait_bytes(PROMPT, 15, start=off):
                    problems.append(f"[{shell}] no prompt after Ctrl-C")
                    continue
                # Ended there: it never got as far as drawing
                if run.data()[0].find(CLEAR, off) >= 0:
                    problems.append(f"[{shell}] the motd went on after Ctrl-C")
                run.send(b"alias ctrlc-probe\r")
                if not run.wait_bytes(b"echo ok", 5):
                    problems += [f"[{shell}] the alias after the motd in ~/.profile isn't defined", run.screen().dump()]
            finally:
                motd_close(run)
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_prompt():
    """The prompt's colours are inside \\[ \\] (Dockerfile), so a command
    line longer than the pane is edited where it's shown: Ctrl-A and an X
    put the X at its start, under bash -l and sh -l."""
    name = f"jbx-t{SLOT_MOCK}-motd-prompt"
    title = "prompt: a long command line is edited in the right place (bash -l, sh -l)"
    panel = motd_mock(name)
    problems = []
    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        for shell in ("bash", "sh"):
            run = motd_shell(name, 12, 60, shell)
            try:
                run.send(b"echo " + b"abcdefghijklmnopqrstuvwxyz" * 3)
                time.sleep(0.5)
                run.send(b"\x01X")
                time.sleep(0.5)
                scr = run.screen()
                # The X at the start, and the line still whole up to the
                # pane's edge (the mock's prompt is 34 cells): a prompt
                # measured wrong redraws it short, or somewhere else
                rows = [t.rstrip() for t in scr.text if "[Project Jumpbox]" in t]
                if not rows or not rows[-1].endswith("/ # Xecho abcdefghijklmnopqrst"):
                    problems += [f"[{shell}] the X isn't at the start of the line: {rows[-1] if rows else None!r}", scr.dump()]
            finally:
                run.send(b"\x03")
                motd_close(run)
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def t_motd_hostile():
    """Hostile data in what the motd reads: the geo lookup (which the panel
    cleans first) and, straight in where the motd's own checks are all there
    is, /etc/profile's exports, the hostname, the OpenVPN log, resolv.conf,
    an alias and a stop reason. Nothing runs, and nothing but colours reaches
    the terminal (motd_checks)."""
    name = f"jbx-t{SLOT_MOCK}-motd-hostile"
    title = "motd with hostile geo, exports, hostname, log, resolv.conf, alias and stop reason"
    rm(name)
    cmd = mock_cmd(name, env=dict(MOTD_ENV, MOCK_GEO_FILE="/t/mock/geo-evil.json"))
    cmd[cmd.index("--hostname") + 1] = "\x1b[2Jred"
    panel = J.start(cmd, 10, 66)
    problems = []
    try:
        if not panel.wait_for(lambda s: shows_state(s, "conn") and "Looking up" not in s.all_text(), 25):
            return result(title, [NEVER])
        # Escapes only in /etc/profile and ~/.profile, never $(...): the
        # login shell runs those itself. OSC and CSI, in upper case as well,
        # so a value that's upper-cased still shows it. The IP stays good
        # for now: without one there's no country shown to look at.
        motd_append(name, "/etc/profile", 'export IP="198.51.100.9"\nexport CC="\x1b]0;x\x07"\n'
                                          'export CTN="\x1b[2JEvil\x1b]0;pwn\x07land"\n')
        motd_append(name, "/root/.profile", "alias ev\x1b[2Jil='echo x'\nalias fine-one='echo y'\n")
        motd_append(name, "/var/log/openvpn.log",
                    "2026-10-26 10:00:00 UDPv4 link remote: [AF_INET]$(touch /tmp/pwned)\x1b[2J:1194\n"
                    "2026-10-26 10:00:00 Data Channel: cipher 'AES\x1b[31m$(touch /tmp/pwned)\x1b]0;X\x07', peer-id: 0\n"
                    "2026-10-26 10:00:00 Control Channel: TLSv1.3\x1b[2J, cipher x, key agreement: $(touch /tmp/pwned)\n")
        motd_append(name, "/etc/resolv.conf",
                    "nameserver \x1b[2J$(touch /tmp/pwned)\nnameserver 192.0.2.53\x1b]0;x\x07\n"
                    "search \x1b[2Jevil `touch /tmp/pwned`\n")
        for rows, cols in ((24, 80), (30, 120)):
            run = motd_shell(name, rows, cols)
            try:
                scr = run.screen()
                p = motd_checks(name, run, rows, cols)
                for want in ("fine-one", "Evil"):
                    if want not in scr.all_text():
                        p.append(f"{want!r} isn't shown (the alias after the hostile one, the country)")
                if p:
                    problems += [f"[{rows}x{cols}] {x}" for x in p] + [scr.dump()]
            finally:
                motd_close(run)
        # Stopped, with a hostile reason and now a hostile IP
        mexec(name, "pkill", "-x", "openvpn")
        mexec(name, "mkdir", "-p", "/run/jumpbox")
        motd_append(name, "/run/jumpbox/stopped", "Stopped \x1b[2Jby \x1b]0;pwn\x07evil \x1b[31mred\n")
        motd_append(name, "/etc/profile", 'export IP="\x1b[2J198.51.100.9"\n')
        wait_until(lambda: mexec(name, "pgrep", "-x", "openvpn").returncode != 0, 10)
        run = motd_shell(name, 30, 120)
        try:
            scr = run.screen()
            p = motd_checks(name, run, 30, 120) + motd_state_problems(scr, "stopped")
            if "evil" not in scr.all_text():
                p.append("the stop reason isn't shown")
            if p:
                problems += [f"[stopped 30x120] {x}" for x in p] + [scr.dump()]
        finally:
            motd_close(run)
        if mexec(name, "test", "-e", "/tmp/pwned").returncode == 0:
            problems.append("hostile data ran a command (/tmp/pwned exists)")
    finally:
        rm(name)
        panel.close()
    return result(title, problems)


def run_once(name, args, timeout):
    """docker run --rm --name <name> <args>: its (returncode, stdout,
    stderr), or None when it outlasts timeout. The container is gone
    afterwards however it ended."""
    rm(name)
    try:
        r = subprocess.run(["docker", "run", "--rm", "--name", name, *args], capture_output=True, timeout=timeout)
        return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return None
    finally:
        rm(name)


# TUNNEL's last row left blank: an unwanted in MOTD_RENDERS
BLANK_TUNNEL_END = object()
# The renderer on fixtures (tests/motd: what motdCollect would have set),
# for states too rare or too short-lived to set up in a mock, each at a
# size where it once went wrong: (fixture, rows, cols, wanted, unwanted), a
# pattern for a match
MOTD_RENDERS = [
    # Three DNS servers, room for only the first: it says how many more
    ("many", 19, 67, ["· DNS +3"], []),
    # An IPv6 nameserver too long to sit by its label, others after it: counted
    ("dns6", 24, 104, [re.compile(r"DNS\s+3 servers")], []),
    # Only the server known: no rows of dashes, and it never connected
    ("no-handshake", 24, 80, ["not connected yet"], [" · - ", " · TLS -"]),
    # The compact panel, the kill switch unknown: no blank row, the aliases kept
    ("sso-unknown-ks", 20, 24, ["gitlab"], [re.compile(r"^\s*│\s*│\s*$", re.M)]),
    # A dead SOCKS5's row doesn't carry the checks' count
    ("down-3bad", 9, 48, [], [re.compile(r"SOCKS5.*✓")]),
    # A short pane keeps the server being retried over the checks' count
    ("down-socks-ssh", 13, 40, ["retrying"], []),
    # The cipher unknown, TLS known: TLS by the server, the key agreement kept
    ("tls-no-cipher", 15, 100, ["X25519MLKEM768"], []),
    # TUNNEL as tall as its rows beside ACCESS
    ("dns6-max", 30, 100, ["DNS"], [BLANK_TUNNEL_END]),
    # Starting: said beside the badge as well, and nothing to run, in every
    # layout; waiting for the one-time code, how to give it
    ("starting", 30, 100, ["OpenVPN is starting"], ["to reconnect", "to start over", "stopped"]),
    ("starting", 24, 80, [re.compile(r"DISCONNECTED\s+starting"), "OpenVPN is starting"],
     ["to reconnect", "to start over", "stopped"]),
    ("starting", 24, 64, ["OpenVPN is starting"], ["to reconnect", "to start over", "stopped"]),
    ("starting", 20, 50, ["OpenVPN is starting"], ["to reconnect", "to start over", "stopped"]),
    ("starting", 6, 20, ["starting"], ["vpn-restart"]),
    ("starting-otp", 24, 80, ["one-time code on the console: docker attach 4c7e19a2f05d"],
     ["OpenVPN is starting", "to reconnect", "to start over"]),
    ("starting-otp", 12, 40, ["one-time", "docker attach 4c7e19a2f05d"], ["OpenVPN is starting", "to reconnect"]),
    ("starting-otp", 6, 20, ["waiting for OTP"], ["vpn-restart"]),
    # No server in the log: not logged yet, or further back than is read
    ("no-server", 24, 80, ["not logged yet"], []),
    ("aged-out", 24, 80, ["not in the recent log"], []),
    ("tcp-first", 24, 80, ["retrying 192.0.2.20:443 · TCP"], []),
]


def motd_tunnel_rows(lines):
    """TUNNEL's rows inside its borders, or None when there's no TUNNEL."""
    for i, t in enumerate(lines):
        k = t.find("╭─ TUNNEL")
        if k < 0:
            continue
        e = t.find("╮", k)
        rows = []
        for t2 in lines[i + 1:]:
            if len(t2) > k and t2[k] == "╰":
                break
            rows.append(t2[k + 1:e])
        return rows
    return None


def t_motd_render():
    """The renderer alone on the fixtures in MOTD_RENDERS: what each wants
    and doesn't, within the pane and leaving the prompt its rows, its boxes'
    lines one width, no error text."""
    name = f"jbx-t{SLOT_MOCK}-motd-render"
    title = "motd renderer on fixtures, at the sizes where each once went wrong"
    script = ("source /config/inc.sh >/dev/null 2>&1; auroraInit; source <(sed '$d' /config/motd.sh)\n"
              "for c in \"$@\"; do ( source /t/motd/${c%%:*}.sh; s=${c#*:}; motdRows=${s%x*} motdCols=${s#*x}\n"
              "  printf '@@ %s %s\\n' \"$c\" \"${#dcn}\"; motdRender 2>&1 ); done")
    r = run_once(name, ["--entrypoint", "bash", "-v", f"{T}:/t:ro", *E.dev_mounts(), IMAGE, "-c", script, "render"]
                 + [f"{f}:{rows}x{cols}" for f, rows, cols, _, _ in MOTD_RENDERS], 120)
    if r is None:
        return result(title, ["the renderer was still going after 120s"])
    frames, dcns, cur = {}, {}, None
    for ln in r[1].split("\n"):
        if ln.startswith("@@ "):
            case, _, n = ln[3:].partition(" ")
            cur, dcns[case] = frames.setdefault(case, []), int(n or 0)
        elif cur is not None:
            cur.append(re.sub(r"\x1b\[[0-9;]*m", "", ln))
    problems = []
    for f, rows, cols, want, unwanted in MOTD_RENDERS:
        tag = f"[{f} {rows}x{cols}]"
        lines = frames.get(f"{f}:{rows}x{cols}")
        if lines is None:
            problems.append(f"{tag} not drawn: {r[2][-300:]!r}")
            continue
        while lines and not lines[-1]:
            lines.pop()
        text = "\n".join(lines)
        p = [f"missing {getattr(w, 'pattern', w)!r}" for w in want
             if not (w.search(text) if isinstance(w, re.Pattern) else w in text)]
        for w in unwanted:
            if w is BLANK_TUNNEL_END:
                tr = motd_tunnel_rows(lines)
                if tr and not tr[-1].strip():
                    p.append("TUNNEL's last row is blank")
            elif w.search(text) if isinstance(w, re.Pattern) else w in text:
                p.append(f"shows {getattr(w, 'pattern', w)!r}")
        widths = [sum(J.cell_width(ch) for ch in t) for t in lines]
        if max(widths, default=0) > cols:
            p.append(f"a line {max(widths)} cells wide in {cols} columns")
        box = sorted({w for w, t in zip(widths, lines) if t[:2] in (" ╭", " │", " ╰")})
        if len(box) > 1:
            p.append(f"the boxes' lines aren't all one width: {box}")
        # The prompt after it, " [Project Jumpbox] | <DCN> / # "
        prompt = max(1, -(-(26 + dcns.get(f"{f}:{rows}x{cols}", 0)) // cols))
        if len(lines) + prompt > rows:
            p.append(f"{len(lines)} lines and the prompt's {prompt} rows in {rows}: the top would scroll away")
        if re.search(r"line \d+:|bash:|command not found", text):
            p.append("error text")
        if p:
            problems += [f"{tag} {x}" for x in p] + [text]
    return result(title, problems)


# OpenVPN logs and what the motd takes from them: (name, log lines, or a
# size to fill with a line that names no server, server, proto, logWhole)
MOTD_LOGS = [
    ("udp", ["UDPv4 link remote: [AF_INET]192.0.2.10:1194"], "192.0.2.10:1194", "UDP", "1"),
    # TCP logs its link line only once connected: each try names the server
    ("tcp refused", ["Attempting to establish TCP connection with [AF_INET]192.0.2.20:443",
                     "TCP: connect to [AF_INET]192.0.2.20:443 failed: Connection refused"], "192.0.2.20:443", "TCP", "1"),
    ("tcp ipv6", ["Attempting to establish TCP connection with [AF_INET6]2001:db8::20:443"], "[2001:db8::20]:443", "TCP", "1"),
    ("unresolved", ["RESOLVE: Cannot resolve host address: vpn.example.test:1194 (Try again)"],
     "vpn.example.test:1194", "", "1"),
    ("resolved later", ["RESOLVE: Cannot resolve host address: vpn.example.test:1194 (Try again)",
                        "UDPv4 link remote: [AF_INET]192.0.2.10:1194"], "192.0.2.10:1194", "UDP", "1"),
    # A route's name that didn't resolve is logged the same way: not the server
    ("route unresolved", ["UDPv4 link remote: [AF_INET]192.0.2.10:1194",
                          "RESOLVE: Cannot resolve host address: nosuch.example.test:[AF_INET] (Name does not resolve)"],
     "192.0.2.10:1194", "UDP", "1"),
    # Hostile ones taken for nothing, and not over the server already known
    ("hostile tcp try", ["Attempting to establish TCP connection with [AF_INET]$(touch${IFS}/tmp/pwned)\x1b[2J:443"],
     "", "", "1"),
    ("hostile resolve", ["RESOLVE: Cannot resolve host address: \x1b]0;x\x07evil.example:1194 (x)"], "", "", "1"),
    ("hostile after", ["UDPv4 link remote: [AF_INET]192.0.2.10:1194",
                       "Attempting to establish TCP connection with [AF_INET]$(touch${IFS}/tmp/pwned)\x1b[2J:443",
                       "RESOLVE: Cannot resolve host address: $(touch${IFS}/tmp/pwned):1194 (x)"],
     "192.0.2.10:1194", "UDP", "1"),
    ("nothing yet", [], "", "", "1"),
    # More than is read, the server's line further back
    ("aged out", 2100000, "", "", "0"),
]


# resolv.conf as musl reads it: (name, contents, nameservers, search)
MOTD_RESOLV = [
    ("crlf", "nameserver 10.20.0.53\r\nsearch corp.example lab.example\r\n", "10.20.0.53", "corp.example lab.example"),
    # Longer lines than its 255 bytes skipped whole
    ("long line", "nameserver 10.20.7.53" + " " * 240 + "#\nnameserver 10.20.0.53\n", "10.20.0.53", ""),
    ("scope", "nameserver fe80::53%eth0\nnameserver 10.20.0.53\n", "fe80::53 10.20.0.53", ""),
    ("bare search", "search corp.example\nsearch\nnameserver 10.20.0.53\n", "10.20.0.53", ""),
    # Not addresses, so no slot of the three
    ("not addresses", "nameserver abc\nnameserver 10.20.9.53:53\nnameserver 10.20.0.53\n", "10.20.0.53", ""),
]
# Alias lines after the image's ~/.profile: (name, lines, the names defined)
MOTD_ALIAS_LINES = [
    ("chained", ["alias and-a='echo a' && alias and-b='echo b'; alias semi-c=1;alias semi-d=2"],
     "and-a and-b semi-c semi-d"),
    ("then something else", ["alias semi-probe='ls -la'; PATH=$PATH:/opt/tools/bin", "alias x=$(echo y=z)"],
     "semi-probe x"),
    ("quoted whole", ["alias 'q-a=ls -la' \"q-b=ls -A\""], "q-a q-b"),
    ("seen before", ["alias d-a=1", "alias d-a=1", "  alias   d-b=2", "alias d-a=3"], "d-a d-b"),
]


def t_motd_collect():
    """motdCollect on what it reads: OpenVPN logs (MOTD_LOGS) - the server
    and its protocol from a link line, from TCP's tries or from a name that
    didn't resolve, nothing from hostile lines, and whether all of the log
    was read; resolv.conf as musl reads it (MOTD_RESOLV); alias lines
    (MOTD_ALIAS_LINES)."""
    name = f"jbx-t{SLOT_MOCK}-motd-collect"
    title = "motd's collector on OpenVPN logs, resolv.conf and alias lines"
    lines = ["source /config/inc.sh >/dev/null 2>&1; source <(sed '$d' /config/motd.sh); L=/var/log/openvpn.log"]
    for case, log, *_ in MOTD_LOGS:
        if isinstance(log, int):
            lines.append(f"yes '2026-10-27 10:00:00 read from TUN/TAP : Input/output error' | head -c {log} > $L")
        else:
            lines.append("printf '%s\\n' " + " ".join(shlex.quote(f"2026-10-27 10:00:00 {x}") for x in log) + " > $L"
                         if log else ": > $L")
        lines.append(f"motdCollect 2>&1; printf '@@ %s|%s|%s|%s\\n' {shlex.quote(case)} \"$server\" \"$proto\" \"$logWhole\"")
    for case, text, _, _ in MOTD_RESOLV:
        lines.append(f"printf '%s' {shlex.quote(text)} > /etc/resolv.conf; motdCollect 2>&1; "
                     f"printf '@@R %s|%s|%s\\n' {shlex.quote(case)} \"${{dns[*]}}\" \"$dnsSearch\"")
    lines.append("cp /root/.profile /tmp/profile0")
    for case, text, _ in MOTD_ALIAS_LINES:
        lines.append(f"{{ cat /tmp/profile0; printf '%s\\n' {' '.join(shlex.quote(x) for x in text)}; }} > /root/.profile; "
                     f"motdCollect 2>&1; printf '@@A %s|%s\\n' {shlex.quote(case)} \"${{aliases[*]}}\"")
    lines.append("[[ -e /tmp/pwned ]] && echo PWNED")
    r = run_once(name, ["--entrypoint", "bash", *E.dev_mounts(), IMAGE, "-c", "\n".join(lines)], 60)
    if r is None:
        return result(title, ["motdCollect was still going after 60s"])
    _, out, err = r
    got = {m.group(1): m.group(2, 3, 4) for m in re.finditer(r"^@@ ([^|\n]*)\|([^|\n]*)\|([^|\n]*)\|([^|\n]*)$", out, re.M)}
    problems = []
    for case, _, server, proto, whole in MOTD_LOGS:
        if got.get(case) != (server, proto, whole):
            problems.append(f"[{case}] server/proto/logWhole {got.get(case)}, expected {(server, proto, whole)}")
    got = {m.group(1): m.group(2, 3) for m in re.finditer(r"^@@R ([^|\n]*)\|([^|\n]*)\|([^|\n]*)$", out, re.M)}
    for case, _, dns, search in MOTD_RESOLV:
        if got.get(case) != (dns, search):
            problems.append(f"[resolv.conf {case}] nameservers/search {got.get(case)}, expected {(dns, search)}")
    got = {m.group(1): m.group(2) for m in re.finditer(r"^@@A ([^|\n]*)\|([^|\n]*)$", out, re.M)}
    for case, _, names in MOTD_ALIAS_LINES:
        if got.get(case) != names:
            problems.append(f"[aliases {case}] {got.get(case)!r}, expected {names!r}")
    if "PWNED" in out:
        problems.append("a hostile log line ran a command")
    if re.search(r"line \d+:|bash:", out + err):
        problems.append(f"error text: {(out + err)[-300:]!r}")
    return result(title, problems)


def t_connect_auth():
    """connectOvpn's openvpn command (sg stubbed to print it) and the motd's
    auth label, for an AUTHFILE with OTP unset, false and true (with a key
    passphrase and without: an empty --askpass stops OpenVPN), and for none;
    at its prompt for the code, start.sh's marker saying so till it's in;
    and start.sh refusing an OTP that's neither true nor false rather than
    sending the password without its code."""
    name = f"jbx-t{SLOT_MOCK}-auth"
    title = "connectOvpn's auth for OTP and AUTHFILE, the motd's label for it, start.sh's OTP check"
    cases = (  # environment, in the command, not in it, the motd's label
        ("AUTHFILE=office-auth", "--auth-user-pass /vpn/office-auth", None, "password"),
        ("AUTHFILE=office-auth OTP=false", "--auth-user-pass /vpn/office-auth", None, "password"),
        ("AUTHFILE=office-auth OTP=true OTPIN=123456", '--auth-user-pass <(cat /vpn/office-auth; echo "123456")',
         "--askpass", "otp"),
        ("AUTHFILE=office-auth OTP=true OTPIN=123456 PRIVKEY=sekrit", '--askpass <(echo "sekrit")', None, "otp"),
        ("", None, "--auth-user-pass", "certificate"),
    )
    script = ("source /config/inc.sh >/dev/null 2>&1; source <(sed '$d' /config/motd.sh)\n"
              "pinRemotes() { :; }; sg() { printf 'CMD %s\\n' \"$3\"; }\n"
              "for c in \"$@\"; do ( [[ -n $c ]] && export $c; printf '@@ %s\\n' \"$c\"\n"
              "  connectOvpn 2>&1 | grep '^CMD'; motdCollect 2>/dev/null; echo \"auth=$auth\" ); done\n"
              # At its prompt for the code, start.sh's marker says so, and
              # not once the code is in
              "( printf '@@ prompt\\n'; export AUTHFILE=office-auth OTP=true; mkdir -p /run/jumpbox; : > /run/jumpbox/starting\n"
              "  { sleep 0.5; cat /run/jumpbox/starting > /tmp/during; echo 654321; } | connectOvpn 2>&1 | grep '^CMD'\n"
              "  printf 'MARK %s|%s\\n' \"$(cat /tmp/during)\" \"$(cat /run/jumpbox/starting)\" )")
    r = run_once(name, ["--entrypoint", "bash", "-e", "OVPNFILE=client.ovpn", *E.dev_mounts(), IMAGE, "-c", script, "auth"]
                 + [c[0] for c in cases], 60)
    if r is None:
        return result(title, ["connectOvpn was still going after 60s"])
    outs = {b.split("\n", 1)[0]: b for b in r[1].split("@@ ")[1:]}
    problems = []
    for env, want, unwanted, label in cases:
        out = outs.get(env, "")
        cmd = " ".join(" ".join(ln.split()) for ln in out.split("\n") if ln.startswith("CMD"))
        if not cmd:
            problems.append(f"[{env or 'no AUTHFILE'}] no openvpn command: {out[-200:]!r}")
            continue
        if want and want not in cmd:
            problems.append(f"[{env or 'no AUTHFILE'}] the command lacks {want!r}: {cmd[-240:]!r}")
        if unwanted and unwanted in cmd:
            problems.append(f"[{env or 'no AUTHFILE'}] the command has {unwanted!r}")
        if f"auth={label}\n" not in out:
            problems.append(f"[{env or 'no AUTHFILE'}] the motd's label isn't {label!r}: {out[-80:]!r}")
    m = re.search(r"^MARK ([^|\n]*)\|([^|\n]*)$", outs.get("prompt", ""), re.M)
    if not m or m.groups() != ("otp", ""):
        problems.append(f"[OTP=true, no OTPIN] the marker while waiting for the code / after: {m.groups() if m else None}")
    if 'echo "654321")' not in outs.get("prompt", ""):
        problems.append("[OTP=true, no OTPIN] the code read at the prompt isn't in the command")
    # Refused before anything starts; let through, start.sh would go on to
    # connect (and, with no profile, wait out waitConn)
    r = run_once(name, ["-e", "DCN=jbx-auth", "-e", "PORT=10079", "-e", "OVPNFILE=client.ovpn", "-e", "AUTHFILE=office-auth",
                        "-e", "OTP=1", *E.dev_mounts(), IMAGE], 20)
    if r is None:
        problems.append("[start.sh, OTP=1] not refused: still running after 20s")
    elif r[0] != 1 or "OTP must be true or false" not in r[1]:
        problems.append(f"[start.sh, OTP=1] exit {r[0]}, not refused: {r[1][-200:]!r}")
    return result(title, problems)


def motd_times(name, n=5):
    """The motd's run time, n times, as a login shell would see it."""
    runs = []
    for _ in range(n):
        r = subprocess.run(["docker", "exec", "-t", name, "bash", "-c", "TIMEFORMAT=%3R; time bash /config/motd.sh"],
                           capture_output=True, timeout=60, env=dict(os.environ, DOCKER_CLI_HINTS="false"))
        m = re.search(rb"(\d+\.\d{3})\s*$", r.stdout)
        if m:
            runs.append(float(m.group(1)))
    return runs


def t_motd_time():
    """The motd's own run time, connected, and down with 100 MB of OpenVPN
    log (a refused password retried every 2s for a day or two), of which
    only the end is read."""
    name = f"jbx-t{SLOT_MOCK}-motd-time"
    title = "motd run time, connected and down with a 100 MB log"
    panel = motd_mock(name)
    problems, info = [], {}
    try:
        if not panel.mock_ok:
            return result(title, [NEVER])
        info["seconds"] = motd_times(name)
        set_state(name, "down")
        if not settle(panel, "down", 20):
            problems.append("the mock never went down")
        mexec(name, "sh", "-c", "yes 'read from TUN/TAP : Input/output error (fd=7,code=5)' "
                                "| head -c 100000000 >> /var/log/openvpn.log")
        info["seconds_down_100mb"] = motd_times(name)
        for key, limit in (("seconds", 0.3), ("seconds_down_100mb", 0.5)):
            runs = info[key]
            if len(runs) < 5:
                problems.append(f"couldn't time it ({key}): {runs}")
            elif sorted(runs)[2] > limit:
                problems.append(f"{key}: median {sorted(runs)[2]:.3f}s, over the {limit}s budget")
    finally:
        rm(name)
        panel.close()
    return result(title, problems, **info)


def t_e2e_motd(n=11):
    """The motd against a real OpenVPN connection: the details it lifts from the log, tun0, DNS, the kill switch, the listeners."""
    name = f"jbx-t{n}-motd"
    title = "e2e motd: real tunnel details"
    E.setup(n)
    panel = J.start(E.client_cmd(n, name), 10, 66)
    problems = []
    try:
        if not panel.wait_for(lambda s: shows_state(s, "conn") and "Looking up" not in s.all_text(), 60):
            return result(title, ["never connected"])
        run = motd_shell(name, 30, 120)
        try:
            scr = run.screen()
            problems += motd_checks(name, run, 30, 120) + motd_state_problems(scr, "conn")
            # The server's address changes from run to run: its port doesn't
            problems += motd_text_problems(scr, ["UDP", ":1194", "AES-256-GCM", "TLSv1.3", "X25519", f"10.89.{n}.",
                                                 "full tunnel", "1.1.1.1", str(29990 + n), str(31990 + n), "client.ovpn"])
            # A healthy start.sh container: kill switch, IPv6 block, both
            # listeners and the watcher all fine, and all read (◌: couldn't be)
            if "✕" in scr.all_text() or "◌" in scr.all_text():
                problems.append("a check shows as failed or unknown on a healthy connection")
            if problems:
                problems.append(scr.dump())
        finally:
            motd_close(run)
        return result(title, problems, screen=scr.stripped())
    finally:
        panel.close()
        E.teardown(n)


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    filt = sys.argv[2:]
    tests = []
    if which in ("mock", "all"):
        tests += [(f"layout {r}x{c}", (lambda r=r, c=c: t_layout(r, c))) for r, c in SIZES]
        tests += [("resize", t_resize_sequence), ("keys", t_keys)]
        tests += [(f"stop {k}", (lambda k=k: t_stop(k))) for k in ("docker-stop", "ctrl-c", "stop-file", "stop-during-resizes")]
        tests += [(f"geo {g[0]}", (lambda g=g: t_geo(*g))) for g in GEO_CASES]
        tests += [("fields", t_fields), ("respawn", t_connchecker_respawn), ("tun", t_tun_recreate)]
        tests += [("stopped", t_openvpn_stopped), ("paste", t_paste_then_ctrl_c), ("slowlookup", t_slow_lookup),
                  ("lookfail", t_lookup_failure_after_delay), ("dumb", t_term_dumb), ("modes", t_stray_modes),
                  ("odd", t_odd_data), ("ssoalive", t_compact_sso_alive), ("ratereset", t_rates_reset),
                  ("attach", t_attach_second_client), ("headless", t_headless_mock)]
        tests += [("motd layouts", t_motd_layouts), ("motd healthy", t_motd_healthy), ("motd states", t_motd_states),
                  ("motd quiet", t_motd_quiet), ("motd ash", t_motd_ash), ("motd odd", t_motd_odd),
                  ("motd ctrlc", t_motd_ctrlc), ("motd prompt", t_motd_prompt), ("motd hostile", t_motd_hostile),
                  ("motd time", t_motd_time), ("motd render", t_motd_render), ("motd collect", t_motd_collect),
                  ("connect auth", t_connect_auth)]
    if which in ("e2e", "all"):
        tests += [("e2e main", t_e2e_main), ("e2e sso", t_e2e_sso), ("e2e ctrlc", t_e2e_ctrl_c_compact),
                  ("e2e lock", t_e2e_vpn_restart_lock), ("e2e newip", t_e2e_server_new_ip),
                  ("e2e outage", t_e2e_long_outage), ("e2e gone", t_e2e_server_gone),
                  ("e2e lapse", t_e2e_sso_lapse), ("e2e headless", t_e2e_headless), ("e2e motd", t_e2e_motd)]
    if which in ("cpu", "all"):
        tests += [("cpu", t_cpu_vs_old)]
    if filt:
        tests = [t for t in tests if any(f in t[0] for f in filt)]
    workers = int(os.environ.get("JBX_WORKERS", "4"))
    t0 = time.time()
    with cf.ThreadPoolExecutor(workers) as ex:
        futs = [ex.submit(fn) for _, fn in tests]
        for f in futs:
            try:
                f.result()
            except Exception:
                result("harness error", [traceback.format_exc()])
    passed = sum(r["ok"] for r in RESULTS)
    print(f"\n{passed}/{len(RESULTS)} passed in {time.time() - t0:.0f}s")
    out = os.path.join(T, f"results-{which}-{int(time.time())}.json")
    with open(out, "w") as f:
        json.dump(RESULTS, f, indent=1)
    print("results:", out)


if __name__ == "__main__":
    main()
