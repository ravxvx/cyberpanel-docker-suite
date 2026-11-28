import base64
import functools
import json
import os
import re
import secrets
import shlex
import shutil
import time
import traceback
import urllib.request

from django.http import JsonResponse
from django.views.decorators.http import require_POST

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(PLUGIN_DIR, "dmtool.sh")
GLPI_TOOL = os.path.join(PLUGIN_DIR, "glpitool.sh")
SRV_TOOL = os.path.join(PLUGIN_DIR, "srvtool.sh")
LOG_DIR = "/var/log/dockermanager"
ERRLOG = LOG_DIR + "/plugin-errors.log"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
NONCE_RE = re.compile(r"^[0-9a-f]{12}$")
BACKUP_RE = re.compile(r"^20[0-9]{6}-[0-9]{6}$")
B64_RE = re.compile(r"^[A-Za-z0-9+/=]{1,90000}$")
ACTIONS = ("list", "checkupd", "update", "ctl", "logs", "backup", "backups", "restore", "prune", "getconfig", "setconfig",
           "vpnsave", "remotetest", "keyshow", "keyinstall", "remotesend", "run", "delete",
           "inspect", "stats", "diskinfo", "cleanup", "testrestore", "gtestrestore", "alertcheck", "alerttest", "smtpsave", "selfupdate")
GLPI_ACTIONS = {"glist": "list", "gbackup": "backup", "gbackups": "backups", "gupdate": "update", "grestore": "restore", "glogs": "logs", "gnew": "new", "gcheck": "check", "gdelete": "delete"}
SRV_ACTIONS = {"sgetconfig": "getconfig", "ssetconfig": "setconfig", "skeyset": "keyset", "skeyshow": "keyshow", "sbackup": "backup",
               "sbackups": "backups", "sverify": "verify", "sextract": "extract", "srestoresite": "restoresite", "srestoredb": "restoredb",
               "sprune": "prune", "sdelete": "delete"}
SNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$")
SDB_RE = re.compile(r"^[A-Za-z0-9_]{1,64}$")
GNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
NEW_RE = re.compile(r"^(none|[a-z0-9][a-z0-9.-]{1,200}\.[a-z]{2,})\|[0-9]+\.[0-9]+\.[0-9]+\|[01]$")
_cache = {"t": 0, "tags": []}
NEEDS_NAME = ("update", "ctl", "logs", "backup", "backups", "restore", "vpnsave", "delete", "inspect", "stats", "testrestore", "gtestrestore")
CLEANUPS = ("dangling", "images", "buildcache", "volumes", "logs", "restore")


def _run(command):
    # Lazy import: if CyberPanel moves this module, only the plugin pages break, never the whole panel.
    from plogical.processUtilities import ProcessUtilities
    return ProcessUtilities.outputExecutioner(command)


def _sh(script):
    """Runs a shell snippet as root (the panel process itself is not root) and always returns text."""
    out = _run("bash -c " + shlex.quote(script))
    return out if isinstance(out, str) else ""


def _log_error(where, exc):
    try:
        line = "[%s] %s: %s\n%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), where, exc, traceback.format_exc(limit=6))
        enc = base64.b64encode(line.encode("utf-8", "replace")).decode()
        _sh("mkdir -p %s && chmod 700 %s && echo %s | base64 -d >> %s" % (LOG_DIR, LOG_DIR, enc, shlex.quote(ERRLOG)))
    except Exception:
        pass


def guarded(fn):
    """Turns any exception into a JSON error (plus a log line) instead of an opaque HTTP 500."""
    @functools.wraps(fn)
    def wrapper(request, *args, **kwargs):
        try:
            return fn(request, *args, **kwargs)
        except Exception as exc:  # noqa: BLE001
            _log_error(fn.__name__, exc)
            return JsonResponse({"ok": False, "error": "Internal error in %s: %s (details: %s)" % (fn.__name__, exc, ERRLOG)})
    return wrapper


def _is_admin(request):
    try:
        from plogical.acl import ACLManager
        return bool(ACLManager.loadedACL(request.session["userID"])["admin"])
    except Exception:
        return False


def _deny():
    return JsonResponse({"ok": False, "error": "Administrator login required."}, status=403)


def dashboard(request):
    try:
        from plogical.httpProc import httpProc
        return httpProc(request, "dockerSuite/dashboard.html", {}, "admin").render()
    except Exception as exc:  # noqa: BLE001
        _log_error("dashboard", exc)
        from django.http import HttpResponse
        return HttpResponse("<h3>Docker Suite could not render.</h3><pre>%s</pre><p>Details: %s</p>"
                            % (str(exc).replace("<", "&lt;"), ERRLOG), status=200)


def _log_path(action, name):
    if action in GLPI_ACTIONS:
        return "%s/job-glpi-%s-%s.log" % (LOG_DIR, GLPI_ACTIONS[action], name or "all")
    if action in SRV_ACTIONS:
        return "%s/job-srv-%s-%s.log" % (LOG_DIR, SRV_ACTIONS[action], name or "all")
    return "%s/job-%s-%s.log" % (LOG_DIR, action, name or "all")


def _validate(action, name, extra):
    """Returns (name, extra, error)."""
    if action in SRV_ACTIONS:
        if action == "srestoresite":
            if not SNAME_RE.match(name) or ".." in name:
                return None, None, "Invalid website name."
        elif action == "srestoredb":
            if not SDB_RE.match(name):
                return None, None, "Invalid database name."
        else:
            name = ""
        if action in ("sverify", "sextract", "srestoresite", "srestoredb", "sdelete"):
            if not BACKUP_RE.match(extra):
                return None, None, "Invalid backup id."
        elif action in ("ssetconfig", "skeyset"):
            if not B64_RE.match(extra):
                return None, None, "Invalid data."
        else:
            extra = ""
        return name, extra, None
    if action in GLPI_ACTIONS:
        if action != "glist" and not GNAME_RE.match(name):
            return None, None, "Invalid instance name."
        if action == "glist":
            name = ""
        if action == "gupdate" and not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+(:major)?$", extra):
            return None, None, "Invalid version."
        if action in ("grestore", "gdelete") and not BACKUP_RE.match(extra):
            return None, None, "Invalid backup id."
        if action == "gnew" and not NEW_RE.match(extra):
            return None, None, "Invalid domain, version or option."
        if action not in ("gupdate", "grestore", "gnew", "gdelete"):
            extra = ""
        return name, extra, None
    if action not in ACTIONS:
        return None, None, "Unknown action."
    if action in NEEDS_NAME:
        ok = NAME_RE.match(name) or (action == "backup" and name == "ALL")
        if action == "vpnsave":
            ok = name in ("wireguard", "openvpn", "openvpn-auth")
        if not ok:
            return None, None, "Invalid name."
    else:
        name = ""
    if action == "gtestrestore" and not GNAME_RE.match(name):
        return None, None, "Invalid instance name."
    if action == "ctl":
        if extra not in ("start", "stop", "restart"):
            return None, None, "Invalid command."
    elif action == "cleanup":
        if extra not in CLEANUPS:
            return None, None, "Invalid cleanup."
    elif action == "selfupdate":
        if extra not in ("check", "apply"):
            return None, None, "Invalid mode."
    elif action in ("restore", "delete", "testrestore", "gtestrestore"):
        if not BACKUP_RE.match(extra):
            return None, None, "Invalid backup id."
    elif action in ("setconfig", "vpnsave", "keyinstall", "smtpsave"):
        if not B64_RE.match(extra):
            return None, None, "Invalid data."
    else:
        extra = ""
    return name, extra, None


@require_POST
@guarded
def job(request):
    if not _is_admin(request):
        return _deny()
    action = request.POST.get("action", "")
    name = request.POST.get("name", "").strip()
    extra = request.POST.get("extra", "").strip()
    name, extra, err = _validate(action, name, extra)
    if err:
        return JsonResponse({"ok": False, "error": err})
    nonce = secrets.token_hex(6)
    if action in GLPI_ACTIONS:
        tool, real = GLPI_TOOL, GLPI_ACTIONS[action]
    elif action in SRV_ACTIONS:
        tool, real = SRV_TOOL, SRV_ACTIONS[action]
    else:
        tool, real = TOOL, action
    args = " ".join(shlex.quote(a) for a in (tool, real, name or "-", extra or "-", nonce))
    inner = "mkdir -p %s && chmod 700 %s && setsid nohup bash %s > /dev/null 2>&1 < /dev/null &" % (LOG_DIR, LOG_DIR, args)
    _run("bash -c " + shlex.quote(inner))
    return JsonResponse({"ok": True, "nonce": nonce})


@require_POST
@guarded
def jobstatus(request):
    if not _is_admin(request):
        return _deny()
    action = request.POST.get("action", "")
    name = request.POST.get("name", "").strip()
    nonce = request.POST.get("nonce", "")
    if (action not in ACTIONS and action not in GLPI_ACTIONS and action not in SRV_ACTIONS) or not NONCE_RE.match(nonce):
        return JsonResponse({"ok": False, "error": "Bad request."})
    if action in SRV_ACTIONS:
        if action == "srestoresite":
            if not SNAME_RE.match(name) or ".." in name:
                return JsonResponse({"ok": False, "error": "Invalid website name."})
        elif action == "srestoredb":
            if not SDB_RE.match(name):
                return JsonResponse({"ok": False, "error": "Invalid database name."})
        else:
            name = ""
    elif action in GLPI_ACTIONS:
        if action == "glist":
            name = ""
        elif not GNAME_RE.match(name):
            return JsonResponse({"ok": False, "error": "Invalid instance name."})
    elif action in NEEDS_NAME:
        if not (NAME_RE.match(name) or name == "ALL" or (action == "vpnsave" and name in ("wireguard", "openvpn", "openvpn-auth"))):
            return JsonResponse({"ok": False, "error": "Invalid name."})
    else:
        name = ""
    out = _run("cat %s" % shlex.quote(_log_path(action, name)))
    out = out if isinstance(out, str) else ""
    marker = "__START__ " + nonce
    if marker not in out:
        return JsonResponse({"ok": True, "started": False, "done": False, "success": False, "log": ""})
    text = out.split(marker, 1)[1]
    done = "__DONE__" in text
    success = "__DONE__ OK" in text
    text = text.replace("__DONE__ OK", "").replace("__DONE__ FAIL", "").strip("\n")
    return JsonResponse({"ok": True, "started": True, "done": done, "success": success, "log": text})


@require_POST
@guarded
def glpilatest(request):
    """Stable GLPI release tags from GitHub (cached for one hour). Read-only."""
    if not _is_admin(request):
        return _deny()
    if time.time() - _cache["t"] > 3600 or not _cache["tags"]:
        try:
            req = urllib.request.Request(
                "https://api.github.com/repos/glpi-project/glpi/releases?per_page=60",
                headers={"User-Agent": "dockerSuite-cyberpanel-plugin", "Accept": "application/vnd.github+json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                data = json.loads(r.read().decode("utf-8"))
            tags = [x["tag_name"] for x in data if not x.get("prerelease") and not x.get("draft")
                    and VERSION_RE.match(x.get("tag_name", ""))]
            _cache["tags"], _cache["t"] = tags, time.time()
        except Exception as exc:
            return JsonResponse({"ok": False, "error": "Cannot reach GitHub: %s" % exc})
    return JsonResponse({"ok": True, "tags": _cache["tags"]})


def _meminfo():
    info = {}
    with open("/proc/meminfo") as handle:
        for line in handle:
            parts = line.replace(":", " ").split()
            if len(parts) >= 2 and parts[1].isdigit():
                info[parts[0]] = int(parts[1]) * 1024
    return info


@require_POST
@guarded
def overview(request):
    """Read-only server summary for the Overview tab."""
    if not _is_admin(request):
        return _deny()
    data = {"ok": True}
    try:
        data["load"] = [round(x, 2) for x in os.getloadavg()]
        data["cpus"] = os.cpu_count() or 1
        with open("/proc/uptime") as handle:
            data["uptime"] = int(float(handle.read().split()[0]))
        mem = _meminfo()
        total = mem.get("MemTotal", 0)
        avail = mem.get("MemAvailable", mem.get("MemFree", 0))
        data["mem"] = {"total": total, "used": max(total - avail, 0)}
        usage = shutil.disk_usage("/")
        data["disk"] = {"total": usage.total, "used": usage.used}
    except (OSError, ValueError):
        data["system_error"] = True
    out = _sh(
        "echo '#svc'; for s in lsws lscpd mariadb docker fail2ban ufw; do echo \"$s $(systemctl is-active $s 2>/dev/null)\"; done; "
        "echo '#reboot'; test -f /var/run/reboot-required && echo yes; "
        "echo '#docker'; command -v docker >/dev/null 2>&1 && docker info --format '{{.ContainersRunning}} {{.Containers}} {{.Images}}' 2>/dev/null; "
        "echo '#bk-docker'; find /var/backups/docker -mindepth 2 -maxdepth 3 -type f -printf '%%T@ %%s\\n' 2>/dev/null; "
        "echo '#bk-glpi'; find /var/backups/glpi -mindepth 1 -maxdepth 3 -type f -printf '%%T@ %%s\\n' 2>/dev/null; "
        "echo '#bk-server'; find /var/backups/server -mindepth 1 -maxdepth 3 -type f -printf '%%T@ %%s\\n' 2>/dev/null; "
        "echo '#bk-wp'; find /home/wptoolkit-backups -maxdepth 3 -type f -name '*.tar.gz' -printf '%%T@ %%s\\n' 2>/dev/null; "
        "echo '#sites'; ls -1d /home/*/public_html 2>/dev/null | wc -l; "
        "echo '#bkdirs'; du -sb /var/backups/docker /var/backups/glpi /var/backups/server /home/wptoolkit-backups /var/restore 2>/dev/null; "
        "echo '#ai'; test -s /etc/dockermanager/assistant/api.key && echo yes; "
        "echo '#alerts'; test -f /etc/cron.d/dockermanager-alerts && echo yes; "
        "echo '#cron'; test -f /etc/cron.d/dockermanager-backup && grep -v '^#' /etc/cron.d/dockermanager-backup | head -1; "
        "echo '#errors'; test -f %s && grep -c '^\\[' %s 2>/dev/null" % (shlex.quote(ERRLOG), shlex.quote(ERRLOG)))
    section, lines = "", {}
    for line in out.splitlines():
        if line.startswith("#"):
            section = line[1:].strip(); lines[section] = []
        elif section:
            lines[section].append(line.strip())
    services = {}
    for row in lines.get("svc", []):
        parts = row.split()
        if len(parts) == 2:
            services[parts[0]] = parts[1]
    data["services"] = services
    data["reboot_required"] = "yes" in lines.get("reboot", [])
    for key in ("docker", "glpi", "server", "wp"):
        count, newest, size = 0, 0.0, 0
        for row in lines.get("bk-" + key, []):
            parts = row.split()
            if len(parts) == 2:
                try:
                    count += 1; newest = max(newest, float(parts[0])); size += int(float(parts[1]))
                except ValueError:
                    pass
        data.setdefault("backups", {})[key] = {"count": count, "newest": int(newest), "size": size}
    dock = (lines.get("docker") or [""])[0].split()
    data["docker"] = {"running": int(dock[0]), "total": int(dock[1]), "images": int(dock[2])} if len(dock) == 3 and all(x.isdigit() for x in dock) else None
    cron = (lines.get("cron") or [""])[0]
    m = re.match(r"^\s*(\d+)\s+(\d+)\s", cron)
    data["cron"] = {"present": bool(cron), "time": "%02d:%02d" % (int(m.group(2)), int(m.group(1))) if m else ""}
    sites = (lines.get("sites") or ["0"])[0]
    data["sites"] = int(sites) if sites.isdigit() else 0
    data["dirs"] = {}
    for row in lines.get("bkdirs", []):
        parts = row.split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            data["dirs"][parts[1]] = int(parts[0])
    data["assistant_key"] = "yes" in lines.get("ai", [])
    data["alerts_on"] = "yes" in lines.get("alerts", [])
    err = (lines.get("errors") or ["0"])[0]
    data["plugin_errors"] = int(err) if err.isdigit() else 0
    return JsonResponse(data)


MAINT_BIN = "/usr/local/sbin/dockersuite-maint"
MAINT_ACTIONS = ("status", "save", "cleannow", "guardnow", "delete", "wptcheck", "wptstate", "wptupdate")


@require_POST
@guarded
def maint(request):
    """Plugin protection (after CyberPanel upgrades) and cleanup of old copies - Settings tab."""
    if not _is_admin(request):
        return _deny()
    action = request.POST.get("action", "status")
    if action not in MAINT_ACTIONS:
        return JsonResponse({"ok": False, "error": "Unknown action."})
    arg = ""
    if action in ("save", "delete"):
        arg = request.POST.get("data64", "").strip()
        if not B64_RE.match(arg):
            return JsonResponse({"ok": False, "error": "Invalid data."})
    tool = MAINT_BIN if os.path.exists(MAINT_BIN) else "python3 " + shlex.quote(os.path.join(PLUGIN_DIR, "maint.py"))
    if action in ("wptupdate", "guardnow"):
        # Both can restart the panel. Run them as their own systemd unit, outside lscpd's process group:
        # a restart of lscpd would otherwise kill them half-way (before the health check / rollback).
        real = "wptupdate" if action == "wptupdate" else "guardforce"
        _sh("mkdir -p %s; if command -v systemd-run >/dev/null 2>&1; then systemd-run --quiet --collect --unit=dockersuite-%s-$(date +%%s) %s %s; "
            "else setsid nohup %s %s > /dev/null 2>&1 < /dev/null & fi" % (LOG_DIR, real, tool, real, tool, real))
        return JsonResponse({"ok": True, "started": True})
    out = _sh("%s %s %s" % (tool, action, shlex.quote(arg) if arg else "")).strip()
    try:
        return JsonResponse(json.loads(out.splitlines()[-1] if out else "{}"))
    except ValueError:
        return JsonResponse({"ok": False, "error": "Unexpected answer from the maintenance tool: %s" % out[-300:]})
