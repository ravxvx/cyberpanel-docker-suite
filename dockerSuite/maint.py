#!/usr/bin/env python3
"""Docker Suite maintenance (installed as /usr/local/sbin/dockersuite-maint, runs as root).

* guard  - keeps custom CyberPanel plugins working after a CyberPanel upgrade: keeps one copy of each
           protected plugin in /root/plugin-backup, puts a deleted plugin folder back, re-adds it to
           settings.py / urls.py and the sidebar, restarts the panel and rolls back if the panel breaks.
* clean  - deletes old copies (manual backups, replaced plugin versions, the copy of the previous panel
           that the CyberPanel upgrader leaves behind) after a number of days.
* status / save / delete - used by the Settings tab of Docker Suite. They print JSON.

It lives outside the plugin folder on purpose: a CyberPanel upgrade can delete the plugin, never this script.
"""
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

C = "/usr/local/CyberCP"
B = "/root/plugin-backup"
CONF = "/etc/dockermanager/maint.json"
LOG = "/var/log/dockermanager/plugin-guard.log"
DEFAULT = {"guard": True, "apps": ["wordpressToolkitPro", "dockerSuite"], "clean": True, "keep_days": 10, "panel_days": 30}
APP_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{1,40}$")
# sidebar marker written by each plugin's repair-menu.sh, and where that script lives
MENU = {"wordpressToolkitPro": ("WPT-BEGIN", ["bin/repair-menu.sh", "repair-menu.sh"]),
        "dockerSuite": ("DM-BEGIN", ["repair-menu.sh"]),
        "serverApp": ("SA-BEGIN", ["repair-menu.sh"])}
# what "clean" may delete: (glob, which limit applies)
RULES = [
    (B + "/replaced-*", "keep_days"),
    ("/root/*.bak-*", "keep_days"),
    ("/root/wp-config-*.bak", "keep_days"),
    ("/root/plugins-github-*.tar.gz", "keep_days"),
    ("/root/wptoolkit-*.tar.gz", "keep_days"),
    ("/root/dockerSuite-*.tar.gz", "keep_days"),
    ("/root/dockersuite-*.tar.gz", "keep_days"),
    ("/usr/local/.cyberpanel-previous-*", "panel_days"),
]
LABELS = {"replaced-": "Plugin version replaced by hand", ".bak-": "Config backup", "wp-config-": "wp-config.php backup",
          "plugins-github-": "Plugin archive", "wptoolkit-": "WP Toolkit version (self-update)",
          "dockersuite-": "Docker Suite version (self-update)", "dockerSuite-": "Docker Suite version",
          ".cyberpanel-previous-": "Previous CyberPanel (left by the upgrader)"}


def log(text):
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), text)
    print(line)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


def load_conf():
    conf = dict(DEFAULT)
    try:
        with open(CONF) as handle:
            data = json.load(handle)
        if isinstance(data, dict):
            conf.update({k: data[k] for k in DEFAULT if k in data})
    except (OSError, ValueError):
        pass
    return conf


def save_conf(data):
    conf = load_conf()
    conf["guard"] = bool(data.get("guard", conf["guard"]))
    conf["clean"] = bool(data.get("clean", conf["clean"]))
    for key, lo, hi in (("keep_days", 1, 365), ("panel_days", 1, 365)):
        try:
            conf[key] = max(lo, min(hi, int(data.get(key, conf[key]))))
        except (TypeError, ValueError):
            pass
    apps = data.get("apps", conf["apps"])
    if isinstance(apps, list):
        conf["apps"] = [a for a in apps if isinstance(a, str) and APP_RE.match(a)][:20]
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    tmp = CONF + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(conf, handle, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF)
    return conf


def version(path):
    try:
        with open(os.path.join(path, "meta.xml")) as handle:
            m = re.search(r"<version>([^<]+)</version>", handle.read())
        return m.group(1).strip() if m else ""
    except OSError:
        return ""


def size_of(path):
    if os.path.isfile(path):
        return os.path.getsize(path)
    out = subprocess.run(["du", "-sb", path], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out and out[0].isdigit() else 0


def mirror(src, dst):
    """Exact copy of a plugin folder (no rsync needed). Writes to a temp folder first, then swaps."""
    tmp = dst + ".tmp"
    if os.path.exists(tmp):
        shutil.rmtree(tmp)
    shutil.copytree(src, tmp, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    if os.path.exists(dst):
        shutil.rmtree(dst)
    os.rename(tmp, dst)


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def panel_code():
    r = sh("curl -sk -m 20 -o /dev/null -w '%{http_code}' https://127.0.0.1:8090/")
    return r.stdout.strip()


def register(apps):
    """Adds missing apps to settings.py / urls.py. Returns True when a file changed."""
    changed = False
    p = C + "/CyberCP/settings.py"
    s = open(p).read()
    o = s
    for a in apps:
        if "'%s'" % a not in s and '"%s"' % a not in s:
            s = re.sub(r"(INSTALLED_APPS\s*=\s*\[)", r"\1\n    '%s'," % a, s, count=1)
    if s != o:
        open(p, "w").write(s)
        changed = True
    p = C + "/CyberCP/urls.py"
    s = open(p).read()
    o = s
    if not re.search(r"^from django\.(urls|conf\.urls) import .*\binclude\b", s, re.M):
        s = re.sub(r"^from django\.urls import ", "from django.urls import include, ", s, count=1, flags=re.M)
    for a in apps:
        if "%s.urls" % a not in s:
            s = re.sub(r"(urlpatterns\s*=\s*\[)", r"\1\n    path('%s/', include('%s.urls'))," % (a, a), s, count=1)
    if s != o:
        open(p, "w").write(s)
        changed = True
    return changed


def guard(conf):
    if not conf["guard"]:
        return
    if not os.path.isfile(C + "/CyberCP/settings.py"):
        return
    os.makedirs(B, exist_ok=True)
    os.chmod(B, 0o700)
    st = os.stat(C + "/websiteFunctions") if os.path.isdir(C + "/websiteFunctions") else None
    fix = False
    present = []
    for a in conf["apps"]:
        live, copy = os.path.join(C, a), os.path.join(B, a)
        if os.path.isfile(live + "/meta.xml"):
            mirror(live, copy)
            present.append(a)
        elif os.path.isfile(copy + "/meta.xml"):
            mirror(copy, live)
            if st:
                for root, dirs, files in os.walk(live):
                    for name in [root] + [os.path.join(root, f) for f in files]:
                        os.lchown(name, st.st_uid, st.st_gid)
            log("restored the %s folder (version %s)" % (a, version(live)))
            present.append(a)
            fix = True
    shutil.copy2(C + "/CyberCP/settings.py", B + "/settings.py.prev")
    shutil.copy2(C + "/CyberCP/urls.py", B + "/urls.py.prev")
    if present and register(present):
        log("added %s to settings.py/urls.py" % ", ".join(present))
        fix = True
    idx = C + "/baseTemplate/templates/baseTemplate/index.html"
    try:
        template = open(idx).read()
    except OSError:
        template = ""
    for a in present:
        marker, scripts = MENU.get(a, ("", []))
        if marker and marker not in template:
            for rel in scripts:
                script = os.path.join(C, a, rel)
                if os.path.isfile(script):
                    sh("sh %s" % script)
                    log("sidebar link for %s restored" % a)
                    fix = True
                    break
    if fix:
        sh("systemctl restart lscpd")
        time.sleep(10)
        code = panel_code()
        if code in ("200", "302"):
            log("repair OK (panel answers %s)" % code)
        else:
            shutil.copy2(B + "/settings.py.prev", C + "/CyberCP/settings.py")
            shutil.copy2(B + "/urls.py.prev", C + "/CyberCP/urls.py")
            sh("systemctl restart lscpd")
            log("WARNING: panel answered %s after the repair - settings.py/urls.py rolled back" % code)


def candidates(conf):
    now = time.time()
    rows = []
    for pattern, limit_key in RULES:
        for path in sorted(glob.glob(pattern)):
            if os.path.islink(path):
                continue
            mtime = os.path.getmtime(path)
            age = (now - mtime) / 86400.0
            limit = conf[limit_key]
            label = next((v for k, v in LABELS.items() if k in os.path.basename(path)), "Old copy")
            rows.append({"path": path, "label": label, "size": size_of(path), "mtime": int(mtime),
                         "age_days": round(age, 1), "limit": limit, "delete_in": max(0, round(limit - age, 1)),
                         "panel": limit_key == "panel_days"})
    return rows


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.remove(path)


def clean(conf, force=False):
    if not conf["clean"] and not force:
        return []
    done = []
    for row in candidates(conf):
        if row["age_days"] >= row["limit"]:
            remove(row["path"])
            done.append(row)
            log("cleanup: deleted %s (%d days old)" % (row["path"], row["age_days"]))
    return done


def status(conf):
    apps = []
    template = ""
    try:
        template = open(C + "/baseTemplate/templates/baseTemplate/index.html").read()
        settings = open(C + "/CyberCP/settings.py").read()
        urls = open(C + "/CyberCP/urls.py").read()
    except OSError:
        settings = urls = ""
    names = list(conf["apps"])
    for extra in ("wordpressToolkitPro", "dockerSuite"):
        if extra not in names:
            names.append(extra)
    for a in names:
        live, copy = os.path.join(C, a), os.path.join(B, a)
        apps.append({"app": a, "protected": a in conf["apps"],
                     "installed": os.path.isfile(live + "/meta.xml"), "version": version(live),
                     "registered": ("'%s'" % a in settings or '"%s"' % a in settings) and ("%s.urls" % a in urls),
                     "menu": MENU.get(a, ("",))[0] in template if a in MENU else None,
                     "copy_version": version(copy),
                     "copy_time": int(os.path.getmtime(copy + "/meta.xml")) if os.path.isfile(copy + "/meta.xml") else 0})
    try:
        with open(LOG) as handle:
            tail = handle.read().splitlines()[-30:]
    except OSError:
        tail = []
    return {"ok": True, "conf": conf, "apps": apps, "log": tail, "files": candidates(conf), "update": wpt_state(),
            "cron": os.path.isfile("/etc/cron.d/dockersuite-maint")}


# ---------------- WP Toolkit Pro: check / update from GitHub ----------------
WPT = "wordpressToolkitPro"
WPT_REPO = "ravxvx/cyberpanel-wordpress-toolkit-pr"
WPT_RAW = "https://raw.githubusercontent.com/%s/main/%s/" % (WPT_REPO, WPT)
WPT_TGZ = "https://codeload.github.com/%s/tar.gz/refs/heads/main" % WPT_REPO
WPT_STATE = "/var/log/dockermanager/wpt-update.json"


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or "")[:3]) or (0,)


def fetch(url, timeout=30):
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "dockerSuite-maint"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def wpt_state():
    try:
        with open(WPT_STATE) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def wpt_check():
    installed = version(os.path.join(C, WPT))
    meta = fetch(WPT_RAW + "meta.xml").decode("utf-8", "replace")
    m = re.search(r"<version>([^<]+)</version>", meta)
    latest = m.group(1).strip() if m else ""
    notes = ""
    try:
        text = fetch(WPT_RAW + "CHANGELOG.md").decode("utf-8", "replace")
        parts = re.split(r"(?m)^## ", text)
        news = [p for p in parts[1:] if vtuple(p.split("\n", 1)[0]) > vtuple(installed)]
        notes = "\n".join("## " + p.strip() for p in news[:5])[:4000]
    except Exception:  # noqa: BLE001
        pass
    return {"installed": installed, "latest": latest, "newer": bool(latest) and vtuple(latest) > vtuple(installed), "notes": notes}


def wpt_update():
    """Download, verify, back up, swap, run post_install, check the panel; roll back on any failure."""
    import tarfile
    import tempfile
    state = {"running": True, "done": False, "ok": False, "log": [], "started": int(time.time())}

    def say(text):
        state["log"].append(time.strftime("%H:%M:%S ") + text)
        log("WP Toolkit update: " + text)
        with open(WPT_STATE + ".tmp", "w") as handle:
            json.dump(state, handle)
        os.replace(WPT_STATE + ".tmp", WPT_STATE)

    live = os.path.join(C, WPT)
    old_dir = live + ".old"
    tmp = tempfile.mkdtemp(prefix="wpt-upd-")
    swapped = False
    try:
        say("checking GitHub...")
        info = wpt_check()
        say("installed %s, on GitHub %s" % (info["installed"] or "-", info["latest"] or "-"))
        if not info["latest"]:
            raise RuntimeError("cannot read the version on GitHub")
        say("downloading %s ..." % WPT_TGZ)
        arc = os.path.join(tmp, "src.tgz")
        with open(arc, "wb") as handle:
            handle.write(fetch(WPT_TGZ, timeout=120))
        with tarfile.open(arc) as tf:
            for member in tf.getmembers():
                name = member.name
                if name.startswith("/") or ".." in name.split("/") or member.issym() or member.islnk() or member.isdev():
                    raise RuntimeError("unsafe file in the archive: %s" % name)
            tf.extractall(os.path.join(tmp, "x"))
        found = glob.glob(os.path.join(tmp, "x", "*", WPT))
        if not found:
            raise RuntimeError("the archive has no %s folder" % WPT)
        new = found[0]
        newv = version(new)
        if not newv:
            raise RuntimeError("the new version has no meta.xml version")
        say("checking files of %s ..." % newv)
        for f in glob.glob(os.path.join(new, "*.py")):
            r = sh("python3 -m py_compile %s" % f)
            if r.returncode != 0:
                raise RuntimeError("Python syntax error in %s: %s" % (os.path.basename(f), r.stderr[-300:]))
        for f in glob.glob(os.path.join(new, "bin", "*.sh")) + [os.path.join(new, x) for x in ("post_install", "pre_install", "pre_remove")]:
            if os.path.isfile(f):
                r = sh("bash -n %s" % f)
                if r.returncode != 0:
                    raise RuntimeError("shell syntax error in %s" % os.path.basename(f))
        sh("find %s -name __pycache__ -prune -exec rm -rf {} +" % new)
        if os.path.isdir(live):
            bk = "/root/wptoolkit-%s-%s.tar.gz" % (info["installed"] or "old", time.strftime("%Y%m%d-%H%M%S"))
            r = sh("tar -czf %s -C %s %s" % (bk, C, WPT))
            if r.returncode != 0:
                raise RuntimeError("could not back up the current version")
            os.chmod(bk, 0o600)
            say("current version saved to %s" % bk)
        st = os.stat(C + "/websiteFunctions")
        if os.path.exists(old_dir):
            shutil.rmtree(old_dir)
        if os.path.isdir(live):
            os.rename(live, old_dir)
        mirror(new, live)
        swapped = True
        for root, dirs, files in os.walk(live):
            for name in [root] + [os.path.join(root, f) for f in files]:
                os.lchown(name, st.st_uid, st.st_gid)
        say("files replaced, running post_install (the panel restarts) ...")
        sh("sh %s/post_install" % live)
        register([WPT])
        time.sleep(15)
        code = panel_code()
        if code not in ("200", "302"):
            sh("systemctl restart lscpd")
            time.sleep(10)
            code = panel_code()
        if code not in ("200", "302"):
            raise RuntimeError("the panel answered %s after the update" % code)
        if os.path.exists(old_dir):
            shutil.rmtree(old_dir)
        if os.path.isdir(B):
            mirror(live, os.path.join(B, WPT))
        state["ok"] = True
        say("done: WP Toolkit %s is installed (panel %s)" % (version(live), code))
    except Exception as exc:  # noqa: BLE001
        say("FAILED: %s" % exc)
        if swapped and os.path.isdir(old_dir):
            shutil.rmtree(live, ignore_errors=True)
            os.rename(old_dir, live)
            sh("systemctl restart lscpd")
            say("rolled back to the previous version")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        state["running"], state["done"] = False, True
        say("finished")


def main():
    if os.geteuid() != 0:
        print(json.dumps({"ok": False, "error": "must run as root"}))
        return 1
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    arg = sys.argv[2] if len(sys.argv) > 2 else ""
    conf = load_conf()
    if cmd == "guard":
        guard(conf)
        return 0
    if cmd == "guardforce":
        guard(dict(conf, guard=True))
        return 0
    if cmd == "clean":
        clean(conf)
        return 0
    if cmd == "wptupdate":
        st = wpt_state()
        if st.get("running") and time.time() - st.get("started", 0) < 900:
            return 0
        wpt_update()
        return 0
    try:
        if cmd == "status":
            out = status(conf)
        elif cmd == "save":
            conf = save_conf(json.loads(base64.b64decode(arg).decode("utf-8")))
            out = status(conf)
        elif cmd == "cleannow":
            out = status(conf)
            out["deleted"] = [r["path"] for r in clean(conf, force=True)]
            out["files"] = candidates(conf)
        elif cmd == "wptcheck":
            out = {"ok": True, "check": wpt_check(), "update": wpt_state()}
        elif cmd == "wptstate":
            out = {"ok": True, "update": wpt_state()}
        elif cmd == "delete":
            path = base64.b64decode(arg).decode("utf-8")
            allowed = {r["path"] for r in candidates(conf)}
            if path not in allowed:
                out = {"ok": False, "error": "This file is not on the list of old copies."}
            else:
                remove(path)
                log("deleted by hand: %s" % path)
                out = status(conf)
                out["deleted"] = [path]
        else:
            out = {"ok": False, "error": "unknown command"}
    except Exception as exc:  # noqa: BLE001
        out = {"ok": False, "error": str(exc)}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
