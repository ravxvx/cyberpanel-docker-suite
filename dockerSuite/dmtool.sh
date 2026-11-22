#!/bin/bash
# Docker Suite - runs as root. Usage: dmtool.sh ACTION NAME|- EXTRA|- NONCE
# ACTION: list checkupd update ctl logs backup backups restore prune getconfig setconfig vpnsave remotetest keyshow keyinstall remotesend run
set -uo pipefail
ACTION="${1:-}"; NAME="${2:--}"; EXTRA="${3:--}"; NONCE="${4:-}"
[ "$NAME" = "-" ] && NAME=""; [ "$EXTRA" = "-" ] && EXTRA=""
CONF_DIR="${DM_CONF_DIR:-/etc/dockermanager}"; CONF="$CONF_DIR/config.json"
BR="${DM_BACKUP_ROOT:-/var/backups/docker}"; GBR="${DM_GLPI_BACKUP_ROOT:-/var/backups/glpi}"; LOGDIR="${DM_LOG_DIR:-/var/log/dockermanager}"
RUNDIR="${DM_RUN_DIR:-/run/dockermanager}"; CRON_FILE="${DM_CRON_FILE:-/etc/cron.d/dockermanager-backup}"
SELF="$(readlink -f "$0")"
umask 077
[[ "$ACTION" =~ ^(list|checkupd|update|ctl|logs|backup|backups|restore|prune|getconfig|setconfig|vpnsave|remotetest|keyshow|keyinstall|remotesend|run|delete)$ ]] || exit 1
[[ "$NONCE" =~ ^[0-9a-f]{12}$ ]] || exit 1
mkdir -p "$LOGDIR" "$CONF_DIR/vpn" "$BR" "$RUNDIR"; chmod 700 "$LOGDIR" "$CONF_DIR" "$CONF_DIR/vpn" "$BR" "$RUNDIR"
ID="$ACTION-${NAME:-all}"
exec 9>"$RUNDIR/job-$ID.lock"
flock -n 9 || exit 0
exec >"$LOGDIR/job-$ID.log" 2>&1
echo "__START__ $NONCE"
fail(){ echo "ERROR: $*"; echo "__DONE__ FAIL"; exit 1; }
ok(){ echo "__DONE__ OK"; exit 0; }
say(){ echo "[$(date +%H:%M:%S)] $*"; }
CT_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'
TS_RE='^20[0-9]{6}-[0-9]{6}$'
command -v python3 >/dev/null || fail "python3 is required"
case "$ACTION" in vpnsave|getconfig|setconfig|keyshow|prune) : ;; *) command -v docker >/dev/null || fail "docker is not installed";; esac

DEFAULT_CONF='{"retention_days":5,"min_keep":2,"schedule":"02:30","auto":true,"exclude_paths":["/opt/glpi/"],"containers":{},"remote":{"enabled":false,"host":"","port":22,"user":"","path":"","retention_days":30,"vpn":"none","vpn_routes":""}}'
[ -f "$CONF" ] || { echo "$DEFAULT_CONF" > "$CONF"; chmod 600 "$CONF"; }
cget(){ python3 - "$CONF" "$1" "${2:-}" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
v=d
for k in sys.argv[2].split('.'):
    v=v.get(k) if isinstance(v,dict) else None
if v is None: v=sys.argv[3]
print(str(v).lower() if isinstance(v,bool) else v)
PY
}
# yes|no|auto-excluded for a container
ct_enabled(){ python3 - "$CONF" "$1" "$2" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
name,wd=sys.argv[2],sys.argv[3]
c=(d.get("containers") or {}).get(name,{})
if "backup" in c: print("yes" if c["backup"] else "no"); sys.exit()
for p in d.get("exclude_paths",[]):
    if p and wd.startswith(p): print("auto-excluded"); sys.exit()
print("yes")
PY
}
ct_stop(){ python3 - "$CONF" "$1" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print("yes" if (d.get("containers") or {}).get(sys.argv[2],{}).get("stop") else "no")
PY
}
free_gb(){ df --output=avail -BG "$BR" 2>/dev/null | tail -1 | tr -dc '0-9'; }
ts_epoch(){ date -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s 2>/dev/null; }
lock_ops(){ [ "${DM_LOCK_HELD:-0}" = 1 ] && return 0; exec 8>"$RUNDIR/ops.lock"; flock -n 8 || fail "another backup/restore operation is already running"; }
ensure_alpine(){ docker image inspect alpine:3 >/dev/null 2>&1 || { say "Pulling alpine:3 (helper image for volume archives)..."; docker pull -q alpine:3 >/dev/null || return 1; }; }

# ---------------- backup ----------------
backup_one(){
  local c="$1" tag="${2:-}" ts dest part info wd img state i=0 stopped=0 dbdone=0 rc
  [[ "$c" =~ $CT_RE ]] || { echo "ERROR: bad container name $c"; return 1; }
  docker inspect "$c" >/dev/null 2>&1 || { echo "ERROR: container $c not found"; return 1; }
  [ "$(free_gb)" -ge 1 ] 2>/dev/null || { echo "ERROR: less than 1 GB free in $BR"; return 1; }
  ts="$(date +%Y%m%d-%H%M%S)"; dest="$BR/$c/$ts"; part="$BR/$c/.partial-$ts"
  mkdir -p "$part" || return 1
  say "[$c] backup started"
  docker inspect "$c" > "$part/inspect.json" 2>/dev/null
  info="$(python3 - "$part/inspect.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))[0]
l=d["Config"].get("Labels") or {}
print(d["Config"]["Image"].split("/")[-1].split(":")[0].lower()+"|"+l.get("com.docker.compose.project.working_dir","")+"|"+d["State"]["Status"])
PY
)"
  img="${info%%|*}"; wd="$(echo "$info" | cut -d'|' -f2)"; state="${info##*|}"
  : > "$part/mounts.tsv"
  # database dump
  case "$img" in
    mariadb|mysql)
      docker exec -i "$c" sh -c 'PW="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"; D=$(command -v mariadb-dump || command -v mysqldump); [ -n "$PW" ] && [ -n "$D" ] || exit 90; MYSQL_PWD="$PW" "$D" -uroot --single-transaction --routines --events --all-databases' 2>"$part/db.err" | gzip > "$part/db.sql.gz"
      rc=("${PIPESTATUS[@]}")
      if [ "${rc[0]}" = 0 ] && zcat "$part/db.sql.gz" | tail -3 | grep -q "Dump completed"; then dbdone=1; say "[$c] database dump OK"
      else echo "WARN: [$c] database dump failed or no root password in container env ($(head -c 200 "$part/db.err" 2>/dev/null)); falling back to the data volume"; rm -f "$part/db.sql.gz"; fi;;
    postgres)
      docker exec -i "$c" sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' 2>"$part/db.err" | gzip > "$part/db.sql.gz"
      rc=("${PIPESTATUS[@]}")
      if [ "${rc[0]}" = 0 ] && zcat "$part/db.sql.gz" | tail -3 | grep -q "dump complete"; then dbdone=1; say "[$c] database dump OK"
      else echo "WARN: [$c] pg_dumpall failed; falling back to the data volume"; rm -f "$part/db.sql.gz"; fi;;
  esac
  rm -f "$part/db.err"
  # stop for consistent copy (optional per-container setting)
  if [ "$(ct_stop "$c")" = yes ] && [ "$state" = running ]; then say "[$c] stopping for a consistent copy"; docker stop "$c" >/dev/null && stopped=1; fi
  local fails=0
  while IFS='|' read -r typ nm src dst; do
    [ -n "$typ" ] || continue
    if [ "$dbdone" = 1 ] && { [ "$dst" = /var/lib/mysql ] || [ "$dst" = /var/lib/postgresql/data ] || [ "$dst" = /var/lib/postgresql ]; }; then
      say "[$c] skipping $dst (covered by the database dump)"; continue; fi
    i=$((i+1)); local f="mount-$i.tar.gz"
    if [ "$typ" = volume ]; then
      ensure_alpine || { echo "ERROR: cannot get helper image"; fails=1; break; }
      docker run --rm -v "$nm:/src:ro" alpine:3 tar -czf - -C /src . </dev/null > "$part/$f"; rc=$?
    elif [ "$typ" = bind ] && [ -d "$src" ]; then
      tar -czf "$part/$f" -C "$src" . ; rc=$?
    else
      i=$((i-1)); continue
    fi
    if [ "$rc" -gt 1 ] || [ ! -s "$part/$f" ]; then echo "ERROR: [$c] archiving $dst failed (rc=$rc)"; fails=1; else
      printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$typ" "${nm:-$src}" "$dst" "$f" >> "$part/mounts.tsv"; say "[$c] archived $dst ($(du -h "$part/$f" | cut -f1))"; fi
  done < <(python3 - "$part/inspect.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))[0]
for m in d.get("Mounts",[]):
    t=m.get("Type")
    if t=="volume": print("volume|%s|%s|%s"%(m["Name"],m.get("Source",""),m["Destination"]))
    elif t=="bind": print("bind||%s|%s"%(m["Source"],m["Destination"]))
PY
)
  [ "$stopped" = 1 ] && { docker start "$c" >/dev/null && say "[$c] started again"; }
  if [ -n "$wd" ] && [ -d "$wd" ]; then
    ( cd "$wd" && ls | grep -E '^(docker-compose|compose)\.ya?ml$|^\.env$' | xargs -r tar -czf "$part/compose.tar.gz" ) 2>/dev/null && say "[$c] compose files saved"
  fi
  if [ "$fails" = 1 ]; then rm -rf "$part"; echo "ERROR: [$c] backup FAILED, nothing kept"; return 1; fi
  if [ ! -s "$part/mounts.tsv" ] && [ ! -s "$part/db.sql.gz" ]; then echo "NOTE: [$c] has no volumes or databases - only the container settings were saved"; fi
  { echo "container=$c"; echo "image=$img"; echo "created=$(date -Is)"; echo "tag=$tag"; echo "database_dump=$dbdone"; } > "$part/manifest.txt"
  ( cd "$part" && sha256sum * > SHA256SUMS )
  mv "$part" "$dest" && say "[$c] backup OK -> $dest ($(du -sh "$dest" | cut -f1))"
}

backup_all(){
  local n=0 bad=0 c wd en names
  mapfile -t names < <(docker ps -a --format '{{.Names}}')   # array, not a pipe: docker exec -i must not eat the list
  for c in "${names[@]}"; do
    [ -n "$c" ] || continue
    wd="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null)"
    en="$(ct_enabled "$c" "$wd")"
    if [ "$en" != yes ]; then say "[$c] skipped ($en)"; continue; fi
    n=$((n+1)); backup_one "$c" </dev/null || bad=$((bad+1))
  done
  say "Backups: $n container(s), $bad failed"
  [ "$bad" = 0 ]
}

# ---------------- retention ----------------
prune_local(){
  local root="${1:-$BR}" days min d dir kept ts ep now cutoff removed=0 id
  days="$(cget retention_days 5)"; min="$(cget min_keep 2)"
  [[ "$days" =~ ^[0-9]+$ ]] && [[ "$min" =~ ^[0-9]+$ ]] || { echo "ERROR: bad retention settings"; return 1; }
  now="$(date +%s)"; cutoff=$((days*86400))
  for dir in "$root"/*/; do
    [ -d "$dir" ] || continue
    kept=0
    while read -r id; do
      [[ "$id" =~ $TS_RE ]] || continue
      kept=$((kept+1))
      [ "$kept" -le "$min" ] && continue
      ep="$(ts_epoch "$id")"; [ -n "$ep" ] || continue
      if [ $((now-ep)) -gt "$cutoff" ]; then rm -rf "${dir:?}$id"; removed=$((removed+1)); say "removed ${dir##$root/}$id (older than $days days)"; fi
    done < <(ls -1 "$dir" 2>/dev/null | sort -r)
    find "$dir" -maxdepth 1 -name '.partial-*' -mmin +1440 -exec rm -rf {} + 2>/dev/null
    rmdir "$dir" 2>/dev/null
  done
  say "Retention: kept at least $min per container, removed $removed backup(s) older than $days days"
}


# ---------------- image updates ----------------
# Same-tag refresh only (e.g. nginx:1 -> newer build of nginx:1). A tag/major change is never done automatically.
ct_compose(){ # name -> prints "dir|service|project|files" or fails
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$1" 2>/dev/null
}
compose_cmd(){ # sets CMD array for a container's project
  local info dir svc proj files f
  info="$(ct_compose "$1")"; dir="${info%%|*}"; svc="$(echo "$info" | cut -d'|' -f2)"; proj="$(echo "$info" | cut -d'|' -f3)"; files="$(echo "$info" | cut -d'|' -f4)"
  [ -n "$dir" ] && [ -d "$dir" ] && [ -n "$svc" ] || return 1
  CDIR="$dir"; CSVC="$svc"; CMD=(docker compose -p "$proj")
  IFS=',' read -ra FL <<< "$files"; for f in "${FL[@]}"; do [ -f "$f" ] && CMD+=(-f "$f"); done
  return 0
}

# ---------------- VPN + remote ----------------
VPN_UP=0
vpn_down(){
  [ "$VPN_UP" = 1 ] || return 0
  [ -f "$RUNDIR/dmvpn.type" ] || return 0
  case "$(cat "$RUNDIR/dmvpn.type")" in
    wireguard) wg-quick down dmvpn >/dev/null 2>&1;;
    openvpn) [ -f "$RUNDIR/openvpn.pid" ] && kill "$(cat "$RUNDIR/openvpn.pid")" 2>/dev/null; sleep 1;;
  esac
  rm -f "$RUNDIR/dmvpn.type"; VPN_UP=0; say "VPN disconnected"
}
trap vpn_down EXIT
need_pkg(){ command -v "$1" >/dev/null 2>&1 || { say "Installing $2 ..."; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1 || return 1; }; command -v "$1" >/dev/null 2>&1; }
route_for(){ # dev routes...
  local dev="$1" host="$2" ip r
  ip="$host"; [[ "$host" =~ ^[0-9.]+$ ]] || ip="$(getent ahostsv4 "$host" | awk '{print $1; exit}')"
  [ -n "$ip" ] && ip route replace "$ip/32" dev "$dev" 2>/dev/null
  shift 2
  for r in "$@"; do [[ "$r" =~ ^[0-9.]+/[0-9]+$ ]] && ip route replace "$r" dev "$dev" 2>/dev/null; done
}
vpn_up(){
  local kind host routes; kind="$(cget remote.vpn none)"; host="$(cget remote.host)"; routes="$(cget remote.vpn_routes | tr ',' ' ')"
  [ "$kind" = none ] && return 0
  # NOTE: only routes to the NAS are added. The default route is never touched, so SSH/panel access to this server keeps working.
  case "$kind" in
  wireguard)
    [ -f "$CONF_DIR/vpn/wireguard.conf" ] || { echo "ERROR: no WireGuard config uploaded"; return 1; }
    need_pkg wg-quick wireguard-tools || { echo "ERROR: cannot install wireguard-tools"; return 1; }
    mkdir -p /etc/wireguard
    python3 - "$CONF_DIR/vpn/wireguard.conf" /etc/wireguard/dmvpn.conf <<'PY'
import re,sys
out=[];done=False
for l in open(sys.argv[1]).read().splitlines():
    if re.match(r'\s*(DNS|PostUp|PreUp|PostDown|PreDown|Table|SaveConfig)\s*=',l,re.I): continue
    out.append(l)
    if re.match(r'\s*\[Interface\]',l,re.I) and not done: out.append("Table = off"); done=True
open(sys.argv[2],"w").write("\n".join(out)+"\n")
PY
    chmod 600 /etc/wireguard/dmvpn.conf
    wg-quick down dmvpn >/dev/null 2>&1
    wg-quick up dmvpn >/dev/null 2>&1 || { echo "ERROR: wg-quick up failed"; return 1; }
    echo wireguard > "$RUNDIR/dmvpn.type"; VPN_UP=1
    local allowed; allowed="$(wg show dmvpn allowed-ips | awk '{for(i=2;i<=NF;i++) print $i}' | grep -v '^0.0.0.0/0$' | grep -v ':' )"
    # shellcheck disable=SC2086
    route_for dmvpn "$host" $allowed $routes
    sleep 2; say "WireGuard connected";;
  openvpn)
    [ -f "$CONF_DIR/vpn/openvpn.conf" ] || { echo "ERROR: no OpenVPN config uploaded"; return 1; }
    need_pkg openvpn openvpn || { echo "ERROR: cannot install openvpn"; return 1; }
    local cfg="$RUNDIR/ovpn.conf" log="$LOGDIR/openvpn.log" auth=""
    [ -f "$CONF_DIR/vpn/openvpn-auth.conf" ] && auth="$CONF_DIR/vpn/openvpn-auth.conf"
    grep -viE '^\s*(redirect-gateway|redirect-private|route-nopull|script-security|up|down|route-up|route-pre-down|ipchange|dev|daemon|log|log-append|writepid|auth-user-pass)(\s|$)' "$CONF_DIR/vpn/openvpn.conf" > "$cfg"
    [ -n "$auth" ] && echo "auth-user-pass $auth" >> "$cfg"
    : > "$log"; chmod 600 "$cfg" "$log"
    openvpn --config "$cfg" --dev dmtun0 --dev-type tun --route-nopull --script-security 1 --daemon dmvpn --log "$log" --writepid "$RUNDIR/openvpn.pid" 
    local t=0; until grep -q "Initialization Sequence Completed" "$log"; do sleep 1; t=$((t+1)); [ "$t" -gt 45 ] && { echo "ERROR: OpenVPN did not connect in 45 s:"; tail -8 "$log"; kill "$(cat "$RUNDIR/openvpn.pid" 2>/dev/null)" 2>/dev/null; return 1; }; done
    echo openvpn > "$RUNDIR/dmvpn.type"; VPN_UP=1
    # shellcheck disable=SC2086
    route_for dmtun0 "$host" $routes
    say "OpenVPN connected";;
  *) echo "ERROR: unknown VPN type"; return 1;;
  esac
}
remote_vars(){
  RHOST="$(cget remote.host)"; RPORT="$(cget remote.port 22)"; RUSER="$(cget remote.user)"; RPATH="$(cget remote.path)"; RDAYS="$(cget remote.retention_days 30)"
  [[ "$RHOST" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: remote host is not set or invalid"; return 1; }
  [[ "$RPORT" =~ ^[0-9]{1,5}$ ]] || { echo "ERROR: invalid port"; return 1; }
  [[ "$RUSER" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,40}$ ]] || { echo "ERROR: invalid remote user"; return 1; }
  [[ "$RPATH" =~ ^/[A-Za-z0-9_./-]{1,200}$ ]] && [ "$RPATH" != / ] || { echo "ERROR: remote path must be an absolute path like /volume1/backups (no spaces)"; return 1; }
  [[ "$RDAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid remote retention"; return 1; }
  KEY="$CONF_DIR/id_ed25519"
  SSHOPT=(-i "$KEY" -p "$RPORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$CONF_DIR/known_hosts" -o ConnectTimeout=15)
}
ensure_key(){ [ -f "$CONF_DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$CONF_DIR/id_ed25519" -C "dockermanager@$(hostname)"; }

# ---------------- actions ----------------
case "$ACTION" in
list)
  echo "FREE|$(free_gb)"
  docker system df --format 'DF|{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null
  declare -A CPU MEM
  while IFS='|' read -r n cpu mem; do CPU[$n]="$cpu"; MEM[$n]="${mem%% /*}"; done < <(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null)
  while IFS='|' read -r n img st status proj ports wd; do
    en="$(ct_enabled "$n" "$wd")"
    last="-"; cnt=0
    if [ -d "$BR/$n" ]; then last="$(ls -1 "$BR/$n" | grep -E "$TS_RE" | sort | tail -1)"; cnt="$(ls -1 "$BR/$n" | grep -cE "$TS_RE")"; [ -n "$last" ] || last="-"; fi
    echo "CT|$n|$img|$st|$status|${proj:--}|${ports:--}|${CPU[$n]:--}|${MEM[$n]:--}|$en|$last|$cnt"
  done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}|{{.Label "com.docker.compose.project"}}|{{.Ports}}|{{.Label "com.docker.compose.project.working_dir"}}')
  ok;;
checkupd)
  lock_ops
  docker info >/dev/null 2>&1 || fail "docker daemon not reachable"
  while read -r c; do
    [ -n "$c" ] || continue
    ref="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)"; cur="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
    if ! compose_cmd "$c"; then echo "UPD|$c|$ref|unsupported|not managed by docker compose"; continue; fi
    case "$ref" in *@sha256:*) echo "UPD|$c|$ref|pinned|image is pinned by digest"; continue;; esac
    [[ "$ref" =~ ^[A-Za-z0-9._/:-]+$ ]] || { echo "UPD|$c|$ref|unsupported|odd image name"; continue; }
    if ! docker pull -q "$ref" >/dev/null 2>&1; then echo "UPD|$c|$ref|unsupported|not available in a registry (locally built?)"; continue; fi
    new="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)"
    if [ "$new" != "$cur" ]; then echo "UPD|$c|$ref|yes|newer image of the same tag downloaded"; else echo "UPD|$c|$ref|no|up to date"; fi
  done < <(docker ps -a --format '{{.Names}}' </dev/null)
  ok;;
update)
  lock_ops
  [[ "$NAME" =~ $CT_RE ]] || fail "invalid container name"
  docker inspect "$NAME" >/dev/null 2>&1 || fail "container not found"
  compose_cmd "$NAME" || fail "$NAME is not managed by docker compose (or its project folder is missing) - cannot update it safely"
  ref="$(docker inspect -f '{{.Config.Image}}' "$NAME")"; old="$(docker inspect -f '{{.Image}}' "$NAME")"
  case "$ref" in *@sha256:*) fail "image is pinned by digest";; esac
  cd "$CDIR" || fail "cannot enter $CDIR"
  say "Backup before update..."; backup_one "$NAME" pre-update </dev/null || fail "backup failed - update cancelled, nothing changed"
  say "Pulling $ref ..."; "${CMD[@]}" pull "$CSVC" || fail "pull failed - nothing changed"
  new="$(docker image inspect -f '{{.Id}}' "$ref")"
  [ "$new" != "$old" ] || { say "Already up to date ($ref)"; ok; }
  say "Recreating $CSVC with the new image..."
  "${CMD[@]}" up -d --no-deps "$CSVC" || echo "WARN: compose up reported an error"
  good=0
  for t in $(seq 1 30); do
    sleep 2
    st="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null)"
    case "$st" in running\|healthy|running\|none) [ "$t" -ge 4 ] && { good=1; break; };; esac
  done
  if [ "$good" = 1 ]; then say "Update OK: $NAME runs the new image ($st)"; say "Old image kept for now. Remove unused images later with: docker image prune"; ok; fi
  echo "ERROR: $NAME did not become healthy ($st). Rolling back to the previous image..."
  docker tag "$old" "$ref" && "${CMD[@]}" up -d --no-deps --force-recreate "$CSVC" && say "Rolled back to the previous image. The pre-update backup is in Backups if you need to restore data." || echo "ERROR: automatic rollback failed - use Backups > Restore"
  fail "update failed, rolled back";;
ctl)
  [[ "$NAME" =~ $CT_RE ]] || fail "invalid container name"
  case "$EXTRA" in start|stop|restart) :;; *) fail "invalid command";; esac
  docker "$EXTRA" "$NAME" && say "$EXTRA $NAME: done" || fail "docker $EXTRA failed"
  docker ps -a --filter "name=^$NAME\$" --format '{{.Names}}: {{.Status}}'; ok;;
logs)
  [[ "$NAME" =~ $CT_RE ]] || fail "invalid container name"
  docker logs --tail 200 --timestamps "$NAME" 2>&1 | tail -200; ok;;
backup)
  lock_ops
  if [ "$NAME" = ALL ]; then backup_all && ok || fail "some backups failed"; fi
  backup_one "$NAME" manual && ok || fail "backup failed";;
backups)
  [[ "$NAME" =~ $CT_RE ]] || fail "invalid container name"
  [ -d "$BR/$NAME" ] && for d in $(ls -1 "$BR/$NAME" | grep -E "$TS_RE" | sort -r); do
    echo "BACKUP|$d|$(du -sk "$BR/$NAME/$d" | cut -f1)|${d:0:4}-${d:4:2}-${d:6:2} ${d:9:2}:${d:11:2}|$(ls "$BR/$NAME/$d" | grep -c '^mount-')|$([ -f "$BR/$NAME/$d/db.sql.gz" ] && echo db || echo -)"; done
  ok;;
delete)
  lock_ops
  [[ "$NAME" =~ $CT_RE ]] || fail "invalid container name"
  [[ "$EXTRA" =~ $TS_RE ]] || fail "invalid backup id"
  [ -d "$BR/$NAME/$EXTRA" ] || fail "backup not found"
  rm -rf "${BR:?}/$NAME/$EXTRA" || fail "could not delete $EXTRA"
  say "Deleted backup $EXTRA of $NAME"; ok;;
restore)
  lock_ops
  [[ "$NAME" =~ $CT_RE ]] || fail "invalid container name"
  [[ "$EXTRA" =~ $TS_RE ]] || fail "invalid backup id"
  B="$BR/$NAME/$EXTRA"; [ -d "$B" ] || fail "backup not found"
  docker inspect "$NAME" >/dev/null 2>&1 || fail "container $NAME does not exist (recreate it from its compose file first: see compose.tar.gz in the backup)"
  say "Verifying checksums..."; ( cd "$B" && sha256sum -c --quiet SHA256SUMS ) || fail "checksum mismatch - backup is damaged"
  say "Safety backup of the current state..."; backup_one "$NAME" pre-restore || fail "safety backup failed, restore cancelled"
  was_running="$(docker inspect -f '{{.State.Running}}' "$NAME")"
  say "Stopping $NAME..."; docker stop "$NAME" >/dev/null
  ensure_alpine || fail "cannot get helper image"
  while IFS=$'\t' read -r i typ nm dst f; do
    [ -n "$i" ] || continue
    say "Restoring $dst ..."
    if [ "$typ" = volume ]; then
      docker run --rm -i -v "$nm:/dst" alpine:3 sh -c 'cd /dst && find . -mindepth 1 -delete && tar -xzf -' < "$B/$f" || fail "restoring $dst failed"
    else
      [ -d "$nm" ] || fail "bind path $nm missing"
      ( cd "$nm" && find . -mindepth 1 -delete && tar -xzf - ) < "$B/$f" || fail "restoring $dst failed"
    fi
  done < "$B/mounts.tsv"
  [ "$was_running" = true ] || [ -f "$B/db.sql.gz" ] && { docker start "$NAME" >/dev/null || fail "cannot start $NAME"; }
  if [ -f "$B/db.sql.gz" ]; then
    say "Importing database dump..."
    for t in $(seq 1 40); do docker exec "$NAME" sh -c 'true' 2>/dev/null && sleep 3 && break; sleep 2; done
    img="$(grep '^image=' "$B/manifest.txt" | cut -d= -f2)"
    case "$img" in
      postgres) zcat "$B/db.sql.gz" | docker exec -i "$NAME" sh -c 'psql -U "${POSTGRES_USER:-postgres}" -d postgres' >/dev/null || fail "database import failed";;
      *) zcat "$B/db.sql.gz" | docker exec -i "$NAME" sh -c 'PW="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"; C=$(command -v mariadb || command -v mysql); MYSQL_PWD="$PW" "$C" -uroot' || fail "database import failed";;
    esac
  fi
  say "Restore finished"; ok;;
prune) lock_ops; prune_local && { [ -d "$GBR" ] && prune_local "$GBR"; ok; } || fail "retention failed";;
getconfig)
  echo "CONFIG|$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))' "$CONF")"
  echo "VPNFILES|wireguard=$([ -f "$CONF_DIR/vpn/wireguard.conf" ] && echo yes || echo no),openvpn=$([ -f "$CONF_DIR/vpn/openvpn.conf" ] && echo yes || echo no),auth=$([ -f "$CONF_DIR/vpn/openvpn-auth.conf" ] && echo yes || echo no)"
  [ -f "$CONF_DIR/id_ed25519.pub" ] && echo "PUBKEY|$(cat "$CONF_DIR/id_ed25519.pub")"
  ok;;
setconfig)
  echo "$EXTRA" | base64 -d > "$RUNDIR/newconf.json" 2>/dev/null || fail "invalid data"
  python3 - "$RUNDIR/newconf.json" "$CONF" <<'PY' || fail "configuration rejected"
import json,re,sys
d=json.load(open(sys.argv[1]))
def num(v,lo,hi,dflt):
    try: v=int(v)
    except Exception: return dflt
    return max(lo,min(hi,v))
r=d.get("remote",{})
out={"retention_days":num(d.get("retention_days"),1,365,5),"min_keep":num(d.get("min_keep"),1,30,2),
 "schedule":d.get("schedule") if re.match(r'^([01][0-9]|2[0-3]):[0-5][0-9]$',str(d.get("schedule",""))) else "02:30",
 "auto":bool(d.get("auto",True)),
 "exclude_paths":[p for p in d.get("exclude_paths",["/opt/glpi/"]) if re.match(r'^/[A-Za-z0-9_./-]*$',str(p))][:20],
 "containers":{k:{"backup":bool(v.get("backup",True)),"stop":bool(v.get("stop",False))} for k,v in (d.get("containers") or {}).items() if re.match(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$',k) and isinstance(v,dict)},
 "remote":{"enabled":bool(r.get("enabled",False)),
  "host":r.get("host","") if re.match(r'^[A-Za-z0-9._-]{0,200}$',str(r.get("host",""))) else "",
  "port":num(r.get("port"),1,65535,22),
  "user":r.get("user","") if re.match(r'^[A-Za-z_][A-Za-z0-9_.-]{0,40}$|^$',str(r.get("user",""))) else "",
  "path":r.get("path","") if re.match(r'^(/[A-Za-z0-9_./-]{1,200})?$',str(r.get("path",""))) else "",
  "retention_days":num(r.get("retention_days"),1,3650,30),
  "vpn":r.get("vpn") if r.get("vpn") in ("none","openvpn","wireguard") else "none",
  "vpn_routes":",".join(x for x in re.split(r'[,\s]+',str(r.get("vpn_routes",""))) if re.match(r'^[0-9.]+/[0-9]{1,2}$',x))}}
open(sys.argv[2],"w").write(json.dumps(out,indent=1))
PY
  rm -f "$RUNDIR/newconf.json"; chmod 600 "$CONF"
  if [ "$(cget auto true)" = true ]; then
    sch="$(cget schedule 02:30)"
    printf '%s %s * * * root %s run - - 0123456789ab\n' "${sch:3:2}" "${sch:0:2}" "$(dirname "$SELF")/dmtool.sh" > "$CRON_FILE.tmp" && mv "$CRON_FILE.tmp" "$CRON_FILE" && chmod 644 "$CRON_FILE"
    say "Saved. Automatic job at $sch every day."
  else rm -f "$CRON_FILE"; say "Saved. Automatic job is OFF."; fi
  ok;;
vpnsave)
  case "$NAME" in wireguard|openvpn|openvpn-auth) :;; *) fail "bad name";; esac
  echo "$EXTRA" | base64 -d > "$CONF_DIR/vpn/$NAME.conf.tmp" 2>/dev/null || fail "invalid data"
  [ -s "$CONF_DIR/vpn/$NAME.conf.tmp" ] || fail "empty file"
  mv "$CONF_DIR/vpn/$NAME.conf.tmp" "$CONF_DIR/vpn/$NAME.conf"; chmod 600 "$CONF_DIR/vpn/$NAME.conf"
  say "Saved $NAME (readable by root only)."; ok;;
keyshow)
  ensure_key; echo "PUBKEY|$(cat "$CONF_DIR/id_ed25519.pub")"; ok;;
keyinstall)
  remote_vars || fail "fix the remote settings first (Save settings)"
  ensure_key
  need_pkg sshpass sshpass || fail "cannot install sshpass"
  vpn_up || fail "VPN failed"
  PW="$(echo "$EXTRA" | base64 -d 2>/dev/null)"; [ -n "$PW" ] || fail "empty password"
  PUB="$(cat "$CONF_DIR/id_ed25519.pub")"
  SSHPASS="$PW" sshpass -e ssh -p "$RPORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$CONF_DIR/known_hosts" -o ConnectTimeout=15 -o PubkeyAuthentication=no "$RUSER@$RHOST" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qF '$PUB' ~/.ssh/authorized_keys || echo '$PUB' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys && echo KEY-INSTALLED" || fail "could not install the key (wrong password, SSH disabled on the NAS, or no route)"
  unset PW; say "Done. The password was used once and is not stored."; ok;;
remotetest)
  remote_vars || fail "fix the remote settings first (Save settings)"
  ensure_key; vpn_up || fail "VPN failed"
  ssh "${SSHOPT[@]}" "$RUSER@$RHOST" "echo connected as \$(whoami); mkdir -p '$RPATH' && df -h '$RPATH' | tail -1; command -v rsync >/dev/null && echo rsync: available || echo rsync: MISSING on the NAS" || fail "SSH login with key failed. Install the key first (Install key button)."
  ok;;
remotesend)
  lock_ops
  [ "$(cget remote.enabled false)" = true ] || fail "remote backup is switched off in Settings"
  remote_vars || fail "remote settings invalid"
  ensure_key; vpn_up || fail "VPN failed"
  say "Sending $BR -> $RUSER@$RHOST:$RPATH ..."
  ssh "${SSHOPT[@]}" "$RUSER@$RHOST" "mkdir -p '$RPATH'" || fail "cannot reach the NAS"
  rsync -a --partial --exclude='.partial-*' -e "ssh ${SSHOPT[*]}" "$BR/" "$RUSER@$RHOST:$RPATH/" || fail "rsync failed"
  if [ -d "$GBR" ] && ls -d "$GBR"/*/ >/dev/null 2>&1; then
    say "Sending GLPI backups -> $RPATH/_glpi/ ..."
    ssh "${SSHOPT[@]}" "$RUSER@$RHOST" "mkdir -p '$RPATH/_glpi'" && rsync -a --partial --exclude='.partial-*' -e "ssh ${SSHOPT[*]}" "$GBR/" "$RUSER@$RHOST:$RPATH/_glpi/" || fail "rsync of GLPI backups failed"
    ssh "${SSHOPT[@]}" "$RUSER@$RHOST" "find '$RPATH/_glpi' -mindepth 2 -maxdepth 2 -type d -name '20??????-??????' -mtime +$RDAYS -exec rm -rf {} +"
  fi
  SBR_DIR="${DM_SERVER_BACKUP_ROOT:-/var/backups/server}"
  if [ -d "$SBR_DIR" ] && ls -d "$SBR_DIR"/20??????-??????/ >/dev/null 2>&1; then
    say "Sending server backups -> $RPATH/_server/ ..."
    ssh "${SSHOPT[@]}" "$RUSER@$RHOST" "mkdir -p '$RPATH/_server'" && rsync -a --partial --exclude='.partial-*' --exclude='_safety' -e "ssh ${SSHOPT[*]}" "$SBR_DIR/" "$RUSER@$RHOST:$RPATH/_server/" || fail "rsync of server backups failed"
    ssh "${SSHOPT[@]}" "$RUSER@$RHOST" "find '$RPATH/_server' -mindepth 1 -maxdepth 1 -type d -name '20??????-??????' -mtime +$RDAYS -exec rm -rf {} +"
  fi
  ssh "${SSHOPT[@]}" "$RUSER@$RHOST" "find '$RPATH' -mindepth 2 -maxdepth 2 -type d -name '20??????-??????' -mtime +$RDAYS -exec rm -rf {} +" && say "Remote retention applied ($RDAYS days)"
  say "Remote copy finished"; ok;;
run)
  lock_ops
  export DM_LOCK_HELD=1
  bad=0
  backup_all || bad=1
  if ls -d /opt/glpi/*/ >/dev/null 2>&1 && [ -x "$(dirname "$SELF")/glpibackup" ]; then
    say "GLPI backups..."
    GLPI_BACKUP_KEEP=999 "$(dirname "$SELF")/glpibackup" --all </dev/null || bad=1
  fi
  prune_local || bad=1
  [ -d "$GBR" ] && { prune_local "$GBR" || bad=1; }
  if [ -x "$(dirname "$SELF")/srvtool.sh" ] && [ "$(python3 -c 'import json;print(json.load(open("'"$CONF_DIR"'/server.json")).get("enabled",False))' 2>/dev/null)" = True ]; then
    say "Server backup (websites, system, databases)..."
    ( exec 8>&-; bash "$(dirname "$SELF")/srvtool.sh" backup - - "$NONCE" >/dev/null 2>&1 )
    grep -vE '^(__START__|__DONE__)' "$LOGDIR/job-srv-backup-all.log" 2>/dev/null | tail -8
    grep -q '__DONE__ OK' "$LOGDIR/job-srv-backup-all.log" 2>/dev/null || bad=1
    ( exec 8>&-; bash "$(dirname "$SELF")/srvtool.sh" prune - - "$NONCE" >/dev/null 2>&1 )
  fi
  if ls -d /opt/glpi/*/ >/dev/null 2>&1 && [ -x "$(dirname "$SELF")/glpitool.sh" ]; then
    say "GLPI health tests..."
    ( exec 8>&-; bash "$(dirname "$SELF")/glpitool.sh" check all - "$NONCE" >/dev/null 2>&1 )
    grep -E '^(TEST\|[^|]*\|(WARN|FAIL)|RESULT)' "$LOGDIR/job-glpi-check-all.log" 2>/dev/null
    grep -q '__DONE__ OK' "$LOGDIR/job-glpi-check-all.log" 2>/dev/null || bad=1
  fi
  if [ "$(cget remote.enabled false)" = true ]; then
    ( exec 8>&-; "$SELF" remotesend - - "$NONCE" >/dev/null 2>&1 ); rc=$?
    # remotesend writes its own log; show its result here
    tail -5 "$LOGDIR/job-remotesend-all.log" 2>/dev/null | grep -v '__START__'
    grep -q '__DONE__ OK' "$LOGDIR/job-remotesend-all.log" 2>/dev/null || bad=1
  fi
  [ "$bad" = 0 ] && ok || fail "finished with errors";;
esac
