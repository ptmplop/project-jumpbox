#!/usr/bin/env python3
"""Aurora display test suite. Usage: suite.py [mock|e2e|cpu|all] [test-name-substring ...]

Needs a python with pyte:  python3 -m venv .venv && .venv/bin/pip install pyte
then e.g.                  JBX_DEV=1 .venv/bin/python suite.py all

Mock tests run the real display() against mock/mock.sh (no VPN). E2E tests
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
        if not settle(run, "conn", 25):
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
    if which in ("e2e", "all"):
        tests += [("e2e main", t_e2e_main), ("e2e sso", t_e2e_sso), ("e2e ctrlc", t_e2e_ctrl_c_compact),
                  ("e2e lock", t_e2e_vpn_restart_lock), ("e2e newip", t_e2e_server_new_ip),
                  ("e2e outage", t_e2e_long_outage), ("e2e gone", t_e2e_server_gone),
                  ("e2e lapse", t_e2e_sso_lapse), ("e2e headless", t_e2e_headless)]
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
