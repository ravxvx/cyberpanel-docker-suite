#!/usr/bin/env python3
"""Data and actions for the Docker Suite phone app (/dockerSuite/m/). Runs as root through the panel.

    mobile.py status            -> JSON: system, services, websites, containers, security, alerts
    mobile.py act <base64 JSON> -> JSON: {"ok": ..., "message": ...}
"""
import base64
import concurrent.futures
import glob
import json
import os
import re
import shutil
import subprocess
import time

WPT_TOOL = "/usr/local/CyberCP/wordpressToolkitPro/bin/wptool.sh"
WPT_BACKUPS = "/home/wptoolkit-backups"
GUARD_LOG = "/var/log/dockermanager/plugin-guard.log"
DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
SERVICES = [("Web server", "lsws"), ("Panel", "lscpd"), ("Database", "mariadb"), ("Database", "mysql"),
            ("Docker", "docker"), ("CrowdSec", "crowdsec"), ("CrowdSec firewall", "crowdsec-firewall-bouncer"),
            ("Redis", "redis-server"), ("Antivirus", "imunify-antivirus"), ("Mail", "postfix")]
RESTARTABLE = {"lsws", "docker", "crowdsec", "crowdsec-firewall-bouncer", "redis-server", "mariadb", "mysql", "postfix"}
SKIP_HOMES = {"cyberpanel", "vmail", "docker", "backup", "wptoolkit-backups", "wptoolkit-migrations"}


def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (subprocess.TimeoutExpired, OSError):
        return 1, ""


def meminfo():
    data = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            data[k] = int(v.split()[0]) * 1024
    except (OSError, ValueError):
        pass
    total = data.get("MemTotal", 0)
    avail = data.get("MemAvailable", 0)
    return {"total": total, "used": total - avail}


def system():
    try:
        uptime = int(float(open("/proc/uptime").read().split()[0]))
    except (OSError, ValueError):
        uptime = 0
    du = shutil.disk_usage("/")
    return {"host": os.uname().nodename, "uptime": uptime, "load": [round(x, 2) for x in os.getloadavg()],
            "cpus": os.cpu_count() or 1, "mem": meminfo(), "disk": {"total": du.total, "used": du.used}}


def services():
    out, seen = [], set()
    for label, unit in SERVICES:
        _, load = run(["systemctl", "show", "-p", "LoadState", "--value", unit + ".service"])
        if load.strip() != "loaded":
            continue
        if label == "Database" and "Database" in seen:
            continue
        seen.add(label)
        _, state = run(["systemctl", "is-active", unit])
        out.append({"label": label, "unit": unit, "state": state.strip() or "unknown", "restart": unit in RESTARTABLE})
    return out


def wp_version(root):
    try:
        m = re.search(r"\$wp_version\s*=\s*'([^']+)'", open(os.path.join(root, "wp-includes/version.php")).read())
        return m.group(1) if m else ""
    except OSError:
        return ""


def last_backup(domain):
    files = [f for f in glob.glob(os.path.join(WPT_BACKUPS, domain, "*.tar.gz")) if os.path.isfile(f)]
    if not files:
        return None
    f = max(files, key=os.path.getmtime)
    return {"time": int(os.path.getmtime(f)), "size": os.path.getsize(f), "count": len(files)}


def probe(domain):
    code, out = run(["curl", "-sk", "-o", "/dev/null", "-m", "12", "-w", "%{http_code} %{time_total}",
                     "--resolve", "%s:443:127.0.0.1" % domain, "https://%s/" % domain], timeout=15)
    parts = out.split()
    try:
        return int(parts[0]), round(float(parts[1]), 2)
    except (IndexError, ValueError):
        return 0, 0.0


def ssl_days(domain):
    for path in ("/etc/letsencrypt/live/%s/fullchain.pem" % domain, "/etc/letsencrypt/live/%s/cert.pem" % domain):
        if os.path.isfile(path):
            code, out = run(["openssl", "x509", "-enddate", "-noout", "-in", path])
            m = re.search(r"notAfter=(.+)", out)
            if m:
                try:
                    end = time.mktime(time.strptime(m.group(1).strip().replace("  ", " "), "%b %d %H:%M:%S %Y %Z"))
                    return int((end - time.time()) // 86400)
                except ValueError:
                    return None
    return None


def websites():
    domains = []
    for d in sorted(glob.glob("/home/*/public_html")):
        name = d.split("/")[2]
        if name in SKIP_HOMES or "." not in name or not DOMAIN_RE.match(name):
            continue
        domains.append((name, d))

    def one(item):
        name, root = item
        code, secs = probe(name)
        return {"domain": name, "http": code, "time": secs, "wp": wp_version(root),
                "backup": last_backup(name), "ssl_days": ssl_days(name)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(one, domains))


def containers():
    code, out = run(["docker", "ps", "-a", "--format", "{{json .}}"], timeout=20)
    rows = []
    for line in out.splitlines():
        try:
            c = json.loads(line)
        except ValueError:
            continue
        rows.append({"name": c.get("Names", ""), "image": c.get("Image", ""), "state": c.get("State", ""),
                     "status": c.get("Status", "")})
    return rows


def security():
    sec = {"blocked": None, "infected": None, "logins": [], "guard": ""}
    code, out = run("cscli decisions list -o json 2>/dev/null", timeout=20)
    if code == 0:
        try:
            data = json.loads(out or "null") or []
            sec["blocked"] = sum(len(a.get("decisions") or []) for a in data if isinstance(a, dict))
        except ValueError:
            pass
    code, out = run("imunify-antivirus malware malicious list --json 2>/dev/null", timeout=40)
    if code == 0 and out.strip():
        try:
            data = json.loads(out)
            items = data.get("items", data) if isinstance(data, dict) else data
            sec["infected"] = sum(1 for i in items if isinstance(i, dict)
                                  and str(i.get("status", "found")).lower() in ("found", "infected", "malicious"))
        except ValueError:
            pass
    code, out = run(["last", "-n", "6", "-w", "-i"])
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 4 and p[0] not in ("reboot", "wtmp") and not line.startswith("wtmp"):
            sec["logins"].append({"user": p[0], "from": p[2], "when": " ".join(p[3:7])})
    try:
        sec["guard"] = open(GUARD_LOG).read().splitlines()[-1]
    except (OSError, IndexError):
        pass
    return sec


def alerts(s):
    a = []
    for w in s["websites"]:
        if not (200 <= w["http"] < 400):
            a.append({"level": "bad", "text": "%s answers %s" % (w["domain"], w["http"] or "nothing")})
        if w["ssl_days"] is not None and w["ssl_days"] < 14:
            a.append({"level": "warn", "text": "%s: SSL expires in %d days" % (w["domain"], w["ssl_days"])})
    for v in s["services"]:
        if v["state"] != "active":
            a.append({"level": "bad", "text": "%s (%s) is %s" % (v["label"], v["unit"], v["state"])})
    d = s["system"]["disk"]
    if d["total"] and d["used"] / d["total"] > 0.85:
        a.append({"level": "warn", "text": "Disk %d%% full" % (100 * d["used"] // d["total"])})
    m = s["system"]["mem"]
    if m["total"] and m["used"] / m["total"] > 0.9:
        a.append({"level": "warn", "text": "Memory %d%% used" % (100 * m["used"] // m["total"])})
    if s["security"]["infected"]:
        a.append({"level": "bad", "text": "ImunifyAV: %d infected file(s)" % s["security"]["infected"]})
    for c in s["containers"]:
        if c["state"] in ("exited", "dead", "restarting"):
            a.append({"level": "warn", "text": "Container %s is %s" % (c["name"], c["state"])})
    return a


def status():
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        f_sites = pool.submit(websites)
        f_cont = pool.submit(containers)
        f_sec = pool.submit(security)
        f_srv = pool.submit(services)
        s = {"system": system(), "websites": f_sites.result(), "containers": f_cont.result(),
             "security": f_sec.result(), "services": f_srv.result()}
    s["alerts"] = alerts(s)
    s["ok"] = True
    s["time"] = int(time.time())
    return s


def detached(unit, cmd):
    """Starts cmd as its own systemd unit, so a panel restart cannot stop it."""
    name = "dockersuite-%s-%d" % (unit, int(time.time()))
    code, _ = run(["systemd-run", "--quiet", "--collect", "--unit=" + name] + cmd)
    if code != 0:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def act(data):
    kind = data.get("do", "")
    target = str(data.get("target", ""))
    if kind == "service":
        if target not in RESTARTABLE:
            return {"ok": False, "error": "This service cannot be restarted from the app."}
        detached("svc", ["systemctl", "restart", target])
        return {"ok": True, "message": "Restarting %s..." % target}
    if kind == "container":
        if not NAME_RE.match(target) or target not in {c["name"] for c in containers()}:
            return {"ok": False, "error": "Unknown container."}
        code, out = run(["docker", "restart", target], timeout=90)
        return {"ok": code == 0, "message": "Container %s restarted." % target, "error": out[-200:]}
    if kind == "backup":
        if not DOMAIN_RE.match(target) or not os.path.isdir("/home/%s/public_html" % target):
            return {"ok": False, "error": "Unknown website."}
        if not os.path.isfile(WPT_TOOL):
            return {"ok": False, "error": "WP Toolkit Pro is not installed."}
        detached("wptbackup", ["/bin/bash", WPT_TOOL, "backup", target, "-", os.urandom(6).hex()])
        return {"ok": True, "message": "Backup of %s started. It shows up here in a few minutes." % target}
    return {"ok": False, "error": "Unknown action."}


def main():
    import sys
    if os.geteuid() != 0:
        print(json.dumps({"ok": False, "error": "must run as root"}))
        return
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    try:
        if cmd == "status":
            out = status()
        elif cmd == "act":
            out = act(json.loads(base64.b64decode(sys.argv[2]).decode("utf-8")))
        else:
            out = {"ok": False, "error": "unknown command"}
    except Exception as exc:  # noqa: BLE001
        out = {"ok": False, "error": str(exc)}
    print(json.dumps(out))


if __name__ == "__main__":
    main()
