import json
import os
import re
import secrets
import shlex
import time
import urllib.request

from django.http import JsonResponse
from django.views.decorators.http import require_POST

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(PLUGIN_DIR, "dmtool.sh")
GLPI_TOOL = os.path.join(PLUGIN_DIR, "glpitool.sh")
SRV_TOOL = os.path.join(PLUGIN_DIR, "srvtool.sh")
LOG_DIR = "/var/log/dockermanager"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
NONCE_RE = re.compile(r"^[0-9a-f]{12}$")
BACKUP_RE = re.compile(r"^20[0-9]{6}-[0-9]{6}$")
B64_RE = re.compile(r"^[A-Za-z0-9+/=]{1,90000}$")
ACTIONS = ("list", "checkupd", "update", "ctl", "logs", "backup", "backups", "restore", "prune", "getconfig", "setconfig",
           "vpnsave", "remotetest", "keyshow", "keyinstall", "remotesend", "run", "delete")
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
NEEDS_NAME = ("update", "ctl", "logs", "backup", "backups", "restore", "vpnsave", "delete")


def _run(command):
    # Lazy import: if CyberPanel moves this module, only the plugin pages break, never the whole panel.
    from plogical.processUtilities import ProcessUtilities
    return ProcessUtilities.outputExecutioner(command)


def _is_admin(request):
    try:
        from plogical.acl import ACLManager
        return bool(ACLManager.loadedACL(request.session["userID"])["admin"])
    except Exception:
        return False


def _deny():
    return JsonResponse({"ok": False, "error": "Administrator login required."}, status=403)


def dashboard(request):
    from plogical.httpProc import httpProc
    return httpProc(request, "dockerSuite/dashboard.html", {}, "admin").render()


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
    if action == "ctl":
        if extra not in ("start", "stop", "restart"):
            return None, None, "Invalid command."
    elif action in ("restore", "delete"):
        if not BACKUP_RE.match(extra):
            return None, None, "Invalid backup id."
    elif action in ("setconfig", "vpnsave", "keyinstall"):
        if not B64_RE.match(extra):
            return None, None, "Invalid data."
    else:
        extra = ""
    return name, extra, None


@require_POST
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
