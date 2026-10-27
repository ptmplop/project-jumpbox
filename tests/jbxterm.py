"""Test harness for the jumpbox Aurora status display.

Runs a command (normally `docker run -it ...`) under a real pty of a chosen
size, records every byte it writes, and replays the stream through the pyte
terminal emulator so tests can look at the screen exactly as a terminal
would show it. Resizes are recorded at their byte offset in the stream and
applied to the emulator at the same point.

Cell widths follow what iTerm2 was measured to do (2026-10-23, DSR probe in
a default profile): a regional-indicator flag pair is 2 cells, East Asian
Wide/Fullwidth is 2, everything else used here (box drawing, blocks,
braille, ● ◉ ✕ ◈ ▲ ▼ · ↻ …) is 1. pyte's wcwidth is replaced with that rule.
"""
import codecs
import fcntl
import os
import re
import select
import signal
import struct
import subprocess
import termios
import threading
import time
import unicodedata

import pyte
from pyte import screens


def cell_width(ch):
    o = ord(ch)
    if 0x1F1E6 <= o <= 0x1F1FF:          # regional indicator: a pair is 2 cells
        return 1
    if unicodedata.combining(ch) or o in (0x200D, 0xFE0F):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


screens.wcwidth = cell_width             # pyte looks this global up on every draw

# Erases as iTerm2 (and xterm, tmux) do them. After a character is written in
# the last column with autowrap off, the cursor stays ON that cell; pyte
# instead leaves cursor.x == columns, one past the edge, so an ED/EL 0 there
# erases nothing, where a real terminal erases that last cell
# (VT100ScreenMutableState eraseInDisplay: x1 = MIN(cursor.x, width - 1)).
_erase_in_line = pyte.Screen.erase_in_line


def _erase_in_line_clamped(self, how=0, private=False):
    x = self.cursor.x
    if how in (0, 1) and x >= self.columns:
        self.cursor.x = self.columns - 1
    try:
        _erase_in_line(self, how, private)
    finally:
        self.cursor.x = x


pyte.Screen.erase_in_line = _erase_in_line_clamped


class PtyRun:
    """A command under a pty; the stream is kept with resize marks."""

    def __init__(self, cmd, rows, cols, env=None):
        self.rows, self.cols = rows, cols
        self.master, slave = os.openpty()
        self._winsize(slave, rows, cols)

        def child_setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                                     preexec_fn=child_setup, env=env, close_fds=True)
        os.close(slave)
        self.buf = bytearray()
        self.marks = []                  # (byte offset, rows, cols)
        self.times = []                  # (monotonic time, byte offset) per chunk
        self.lock = threading.Lock()
        self.t0 = time.monotonic()
        self._stop = False
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    @staticmethod
    def _winsize(fd, rows, cols):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def _read(self):
        while not self._stop:
            try:
                r, _, _ = select.select([self.master], [], [], 0.1)
            except (OSError, ValueError):
                return
            if not r:
                if self.proc.poll() is not None:
                    # drain anything left, then stop
                    try:
                        while True:
                            chunk = os.read(self.master, 65536)
                            if not chunk:
                                break
                            with self.lock:
                                self.buf += chunk
                                self.times.append((time.monotonic(), len(self.buf)))
                    except OSError:
                        pass
                    return
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self.lock:
                self.buf += chunk
                self.times.append((time.monotonic(), len(self.buf)))

    def resize(self, rows, cols):
        with self.lock:
            self.marks.append((len(self.buf), rows, cols))
            self.rows, self.cols = rows, cols
        self._winsize(self.master, rows, cols)
        try:
            os.kill(self.proc.pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass

    def send(self, data):
        try:
            os.write(self.master, data if isinstance(data, bytes) else data.encode())
            return True
        except OSError:
            return False

    def data(self):
        with self.lock:
            return bytes(self.buf), list(self.marks)

    def size_now(self):
        return len(self.buf)

    def wait_for(self, predicate, timeout, step=0.25):
        """Poll predicate(screen) until true; returns the screen or None."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            scr = self.screen()
            if predicate(scr):
                return scr
            time.sleep(step)
        return None

    def wait_bytes(self, needle, timeout, start=0):
        end = time.monotonic() + timeout
        n = needle.encode() if isinstance(needle, str) else needle
        while time.monotonic() < end:
            with self.lock:
                if self.buf.find(n, start) >= 0:
                    return True
            if self.proc.poll() is not None:
                with self.lock:
                    return self.buf.find(n, start) >= 0
            time.sleep(0.1)
        return False

    def screen(self, upto=None, complete=True):
        data, marks = self.data()
        if complete and upto is None:
            # A paint can reach us in several reads; don't look at half of one
            start = data.rfind(PAINT)
            if start >= 0 and data.find(PAINT_END, start) < 0:
                upto = start
        if upto is not None:
            data = data[:upto]
            marks = [m for m in marks if m[0] <= upto]
        return replay(data, marks, self._first_size())

    def _first_size(self):
        return getattr(self, "_initial", None)

    def close(self):
        self._stop = True
        try:
            os.close(self.master)
        except OSError:
            pass


def start(cmd, rows, cols, env=None):
    run = PtyRun(cmd, rows, cols, env)
    run._initial = (rows, cols)
    return run


class Screen:
    """What the terminal shows: rows of cells (char, fg, bg, bold)."""

    def __init__(self, pscreen):
        self.rows, self.cols = pscreen.lines, pscreen.columns
        self.mode = set(pscreen.mode)
        self.cursor_hidden = pyte.modes.DECTCEM not in pscreen.mode
        self.autowrap = pyte.modes.DECAWM in pscreen.mode
        self.cells = []
        for y in range(self.rows):
            line = pscreen.buffer[y]
            self.cells.append([line[x] for x in range(self.cols)])
        self.text = ["".join(c.data for c in row) for row in self.cells]

    def row(self, y):
        return self.text[y]

    def stripped(self):
        return [t.rstrip() for t in self.text]

    def dump(self):
        return "\n".join(f"{y:2d}|{t}|" for y, t in enumerate(self.text))

    def all_text(self):
        return "\n".join(self.text)


def replay(data, marks, initial):
    rows, cols = initial
    ps = pyte.Screen(cols, rows)
    st = pyte.Stream(ps)
    dec = codecs.getincrementaldecoder("utf-8")("replace")
    pos = 0
    for off, r, c in marks:
        if off > pos:
            st.feed(dec.decode(data[pos:off]))
            pos = off
        ps.resize(r, c)
    st.feed(dec.decode(data[pos:], final=True))
    return Screen(ps)


# ---------------------------------------------------------------- checks

ERR_PATTERNS = [rb"inc\.sh: line", rb"start\.sh: line", rb"command not found", rb"syntax error",
                rb"division by 0", rb"bad substitution", rb"unbound variable", rb"integer expression",
                rb"No such file or directory", rb"invalid arithmetic", rb"bad array subscript",
                rb"value too great", rb"Killed", rb"Terminated", rb"Done\s+ping"]


def stream_errors(data):
    """Bash error text anywhere in the stream (it would flash on the pane)."""
    found = []
    for p in ERR_PATTERNS:
        for m in re.finditer(p, data):
            s = max(0, m.start() - 60)
            found.append(data[s:m.end() + 60].decode("utf-8", "replace"))
    return found


# Escape sequences, for measuring raw output: CSI, OSC, charset selection,
# the two-byte ones, SI/SO
ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[@-Z\\-_]|[\x0e\x0f]")


def line_widths(data):
    """(cells, text) for every line of raw output (the motd's), escapes left
    out and cells counted as the terminal counts them (cell_width)."""
    out = []
    for ln in data.split(b"\n"):
        t = ANSI.sub(b"", ln).decode("utf-8", "replace").replace("\r", "")
        out.append((sum(cell_width(ch) for ch in t), t))
    return out


# The preamble every paint (full or rows-only) starts with, as paintFrame writes it
PAINT = b"\x1b\\\x1b[?6l\x1b[r\x0f\x1b(B\x1b[0m\x1b[?5l\x1b[4l\x1b[20l\x1b[?7l\x1b[?25l"
# every paint (full or rows-only) ends by parking the cursor home
PAINT_END = b"\x1b[H"


def paints(data):
    return [m.start() for m in re.finditer(re.escape(PAINT), data)]


def newlines_after_first_paint(data, end=None):
    """LF bytes written once the panel is up: the display must never write one."""
    p = data.find(PAINT)
    if p < 0:
        return None
    seg = data[p:end] if end else data[p:]
    return seg.count(b"\n")


def expected_layout(rows, cols):
    """(kind, width, rows of the frame kept) as the display chooses them."""
    if cols >= 66 and rows >= 10:
        return "full", 66, 10
    w = min(max(cols, 20), 66)
    return "compact", w, min(7, rows)


def frame_problems(scr, drop_kept=None):
    """Check the panel's geometry on a screen, cell by cell; returns problems."""
    probs = []
    kind, W, H = expected_layout(scr.rows, scr.cols)
    vis = min(W, scr.cols)
    cell = lambda y, x: scr.cells[y][x].data          # "" = right half of a wide char
    blank = lambda y, x: cell(y, x) in (" ", "")
    # Everything below the frame and right of it must be blank
    for y in range(H, scr.rows):
        if any(not blank(y, x) for x in range(scr.cols)):
            probs.append(f"row {y} below the frame is not blank: {scr.text[y].rstrip()!r}")
    if scr.cols > W:
        for y in range(H):
            if any(not blank(y, x) for x in range(W, scr.cols)):
                probs.append(f"row {y} has text right of the frame: {scr.text[y].rstrip()!r}")
    kept = list(range(H))
    if kind == "compact" and scr.rows < 7:
        order = [6, 5, 4, 3, 1, 2, 0]
        dropped = set(order[: 7 - scr.rows])
        kept = [r for r in range(7) if r not in dropped]
    top, bottom = 0, (9 if kind == "full" else 6)
    for y, role in enumerate(kept):
        first, second, last = cell(y, 0), cell(y, 1), cell(y, vis - 1)
        if role == top:
            if first + second != "╭─":
                probs.append(f"row {y} (top) starts {first + second!r}")
            if last != "╮":
                probs.append(f"row {y} (top) ends {last!r} at cell {vis - 1}")
        elif role == bottom:
            if first + second != "╰─":
                probs.append(f"row {y} (bottom) starts {first + second!r}")
            if last != "╯":
                probs.append(f"row {y} (bottom) ends {last!r} at cell {vis - 1}")
        else:
            if first != "│":
                probs.append(f"row {y} (side) starts {first!r}")
            if last != "│":
                probs.append(f"row {y} (side) ends {last!r} at cell {vis - 1}")
        # nothing between the borders may be a border character out of place
        inner = [cell(y, x) for x in range(1, vis - 1)]
        if role not in (top, bottom) and any(c in ("│", "╮", "╯", "╭", "╰") for c in inner):
            probs.append(f"row {y}: a border character inside the panel: {scr.text[y].rstrip()!r}")
    return probs


def detail_problems(scr, state, d):
    """The same details as the old display, as text on the screen.

    d: dict with port, sshport, host, ovpn, vpnver, osver, ip, country (or None).
    The compact panel's narrow-pane rules (under 40 columns) are mirrored:
    short badges, the IP before the uptime, port-first ssh, cut names.
    """
    probs = []
    kind, W, H = expected_layout(scr.rows, scr.cols)
    t = "\n".join(scr.text)
    flat = t.replace("\n", " ")

    def need(s, why):
        if s not in t:
            probs.append(f"missing {why}: {s!r}")

    def need_any(opts, why):
        if not any(o in t for o in opts):
            probs.append(f"missing {why}: one of {opts!r}")

    def need_re(rx, why):
        if not re.search(rx, flat):
            probs.append(f"missing {why}: /{rx}/")

    if scr.cols < W:                     # under 20 columns: cut by the terminal, geometry only
        return probs
    rows_kept = H if kind == "full" else min(7, scr.rows)
    full = kind == "full"
    seven = full or scr.rows >= 7
    # state, always on the top row
    words = {"conn": ["CONNECTED", "● UP", "◉ UP"], "down": ["DISCONNECTED", "✕ DOWN"],
             "sso": ["SIGN-IN PENDING", "◈ SSO"]}[state]
    need_any(words, "state")
    if full:
        need("PROJECT JUMPBOX", "name")
        need(f"{d['vpnver']} · Alpine {d['osver']}", "versions")
        need(f"127.0.0.1:{d['port']}", "socks5 address")
        need(f"ssh jumpbox@127.0.0.1 -p {d['sshport']}", "ssh command")
        need("password jumpbox", "ssh password")
        need(f"docker exec -it {d['host']} sh -l", "shell command")
        need(d["ovpn"][: W - 8], "config file")
    elif seven:
        port = str(d["port"])
        need(f":{port}", "socks5 port")
        # the password stays with ssh: on the ssh row from 45 columns, else
        # labelled on the socks row while the ssh row is on screen
        if W >= 45:
            need("pw jumpbox", "ssh password (ssh row)")
            need(f"127.0.0.1:{port}", "socks5 address")
        elif 2 + 7 + 10 + len(port) + 15 <= W - 1:
            need(f"127.0.0.1:{port} ssh pw jumpbox", "socks5 address + labelled ssh password")
        elif 2 + 7 + 1 + len(port) + 15 <= W - 1:
            need(f"socks5 :{port} ssh pw jumpbox", "labelled ssh password")
        elif W >= 37:
            need(f"127.0.0.1:{port}", "socks5 address")
        need(f"-p {d['sshport']}", "ssh port")
        if W >= 33:
            need(f"ssh jumpbox@127.0.0.1 -p {d['sshport']}", "ssh command")
        if W >= 25 + len(d["host"]):
            need(f"docker exec -it {d['host']} sh -l", "shell command")
        elif W >= 21 + len(d["host"]):
            need(f"docker exec -it {d['host']}", "shell container")
        need(d["ovpn"][: max(0, W - 8)], "config file")
    if kind == "compact" and scr.rows < 5 and "pw jumpbox" in t:
        probs.append("ssh password shown without the ssh row")
    if seven or scr.rows >= 2:
        # the exit row survives down to 3 rows (top, exit, status)
        if scr.rows >= 3 or full:
            if d.get("ip"):
                if W >= 20:
                    need(d["ip"], "public IP")
                if d.get("country") and full:
                    need(d["country"], "country")
            elif "Looking up" not in t:          # the background lookup may still be running
                need("Unable to" if W >= 30 else "Unable", "IP lookup failure note")
    if state == "conn":
        if full:
            need("last reconnect", "reconnect label")
            need_re(r"\d\dh \d\dm \d\ds", "time since reconnect")
        if scr.rows >= 2 or full:
            need_re(r"▼ \d+(\.\d)? (B|KiB|MiB|GiB|TiB)", "download total")
            if full or W >= 27:
                need_re(r"▲ \d+(\.\d)? (B|KiB|MiB|GiB|TiB)", "upload total")
            if full or W >= 40:
                need("ping", "ping label")
    elif state == "down":
        if scr.rows >= 2 or full:
            need("Waiting for", "waiting message")
    elif state == "sso":
        if scr.rows >= 2 or full:
            need("SSO sign-in pending" if full or W >= 24 else "SSO sign-in", "sso message")
    return probs


def badge_bg(scr):
    """Background colour of the state badge in the full layout (row 1)."""
    for x, c in enumerate(scr.cells[1]):
        if c.bg not in ("default", None, ""):
            return c.bg
    return None


STATE_BG = {"conn": "50eba0", "down": "ff6078", "sso": "ffc656"}
