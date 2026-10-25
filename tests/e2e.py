"""End-to-end rig: a real OpenVPN server container and the jumpbox client.

Slot n owns: docker network jbx-t<n>, server jbx-t<n>-srv, VPN subnet
10.89.<n>.0/24, client names jbx-t<n>-*, host ports 2999<n>/3199<n> (not
published unless asked). Nothing here touches any other container.
"""
import os
import re
import subprocess
import threading
import time

T = os.path.dirname(os.path.abspath(__file__))
IMAGE = os.environ.get("JBX_IMAGE", "jumpbox:latest")


def sh(*args, check=False, quiet=True):
    r = subprocess.run(list(args), capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"{args}: {r.stderr.strip()}")
    return r


def geo_key():
    """An ip2location.io key for the country lookup, from GEOAPIKEY in the
    environment. Optional: without one the panel shows the IP and no country,
    and the e2e checks don't look for a country."""
    return os.environ.get("GEOAPIKEY", "")


def names(n):
    return f"jbx-t{n}", f"jbx-t{n}-srv"


def pki():
    """The throwaway test PKI (CA, server, client), made on first use - once,
    though the suite's threads all ask for it at the start."""
    d = os.path.join(T, "e2e", "pki")
    with _PKI_LOCK:
        if not os.path.exists(os.path.join(d, "client.key")):
            os.makedirs(d, exist_ok=True)
            sh("docker", "run", "--rm", "-v", f"{d}:/out", "-v", f"{os.path.join(T, 'e2e')}:/t/e2e:ro",
               "--entrypoint", "/bin/bash", IMAGE, "/t/e2e/mkpki.sh", check=True)
    return d


_PKI_LOCK = threading.Lock()


def start_server(n, sso=False):
    """(Re)start slot n's server container on its network; returns its IP."""
    net, srv = names(n)
    sh("docker", "run", "-d", "--name", srv, "--network", net, "--cap-add", "NET_ADMIN",
       "--sysctl", "net.ipv4.ip_forward=1", "-v", f"{T}:/t:ro", "--entrypoint", "/bin/bash",
       IMAGE, "/t/e2e/server.sh", str(n), "sso" if sso else "", check=True)
    if sso:
        sh("docker", "exec", "-d", srv, "/t/e2e/sso-responder.sh", check=True)
    for _ in range(50):
        if sh("docker", "exec", srv, "grep", "-q", "Initialization Sequence Completed", "/tmp/server.log").returncode == 0:
            break
        time.sleep(0.2)
    return container_ip(srv)


def container_ip(name):
    return sh("docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", name).stdout.strip()


def setup(n, sso=False):
    net, srv = names(n)
    pki()
    teardown(n)
    sh("docker", "network", "create", net, check=True)
    start_server(n, sso)
    vdir = os.path.join(T, "e2e", f"vpn-{n}")
    os.makedirs(vdir, exist_ok=True)
    pdir = os.path.join(T, "e2e", "pki")
    rd = lambda f: open(os.path.join(pdir, f)).read().strip()
    ovpn = (f"client\ndev tun\nproto udp\nremote {srv} 1194\nnobind\nremote-cert-tls server\n"
            f"verb 3\n<ca>\n{rd('ca.crt')}\n</ca>\n<cert>\n{rd('client.crt')}\n</cert>\n"
            f"<key>\n{rd('client.key')}\n</key>\n")
    with open(os.path.join(vdir, "client.ovpn"), "w") as f:
        f.write(ovpn)
    return vdir


def client_cmd(n, name, env=None, publish=False, image=None, extra=None, tty=True):
    net, _ = names(n)
    port = 29990 + n
    e = {"DCN": name, "OVPNFILE": "client.ovpn", "PORT": str(port), "TZ": "UTC",
         "GEOAPIKEY": geo_key()}
    e.update(env or {})
    cmd = ["docker", "run", "-it" if tty else "-d", "--init", "--name", name, "--network", net,
           "--cap-add", "NET_ADMIN", "-v", f"{os.path.join(T, 'e2e', f'vpn-{n}')}:/vpn:ro"]
    if publish:
        cmd += ["-p", f"127.0.0.1:{port}:1080", "-p", f"127.0.0.1:{port + 2000}:22"]
    for k, v in e.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += extra or []
    cmd += dev_mounts()
    cmd.append(image or IMAGE)
    return cmd


CONFIGS = os.path.normpath(os.path.join(T, "..", "configs"))


def dev_mounts():
    """JBX_DEV=1: the working copies of the scripts over the image's own.

    Staged once per process into its own directory: the working files are
    mode 600 and a bind mount keeps the mode (so /start.sh wouldn't be
    executable), and rewriting a staged file while another container starts
    makes Docker Desktop's file sharing see it missing for a moment.
    """
    global _STAGED
    if not os.environ.get("JBX_DEV"):
        return []
    with _STAGE_LOCK:                    # the suite starts containers from several threads
        if _STAGED is None:
            _STAGED = _stage()
        return list(_STAGED)


def _stage():
    if True:
        stage = os.path.join(T, f"dev-stage-{os.getpid()}")
        os.makedirs(stage, exist_ok=True)
        mounts = []
        for src, dst in (("inc.sh", "/config/inc.sh"), ("start.sh", "/start.sh"),
                         ("vpn-restart.sh", "/usr/local/bin/vpn-restart"),
                         ("sso-url.sh", "/usr/local/bin/sso-url")):
            with open(os.path.join(CONFIGS, src), "rb") as f, open(os.path.join(stage, src), "wb") as g:
                g.write(f.read())
            os.chmod(os.path.join(stage, src), 0o755)
            mounts += ["-v", f"{os.path.join(stage, src)}:{dst}:ro"]
        return mounts


_STAGED = None
_STAGE_LOCK = threading.Lock()


def server_exec(n, *args):
    _, srv = names(n)
    return sh("docker", "exec", srv, *args)


def teardown(n):
    net, srv = names(n)
    r = sh("docker", "ps", "-a", "--format", "{{.Names}}", "--filter", f"name=^jbx-t{n}-")
    for c in r.stdout.split():
        if re.fullmatch(rf"jbx-t{n}-[A-Za-z0-9_.-]+", c):
            sh("docker", "rm", "-f", c)
    sh("docker", "network", "rm", net)
