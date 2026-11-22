#!/bin/bash
# Docker Suite - server backup (websites, system files, CyberPanel settings, MariaDB databases). Runs as root.
# Usage: srvtool.sh ACTION NAME|- EXTRA|- NONCE
# ACTION: getconfig setconfig keyset keyshow backup backups verify extract restoresite restoredb prune delete
set -uo pipefail
ACTION="${1:-}"; NAME="${2:--}"; EXTRA="${3:--}"; NONCE="${4:-}"
[ "$NAME" = "-" ] && NAME=""; [ "$EXTRA" = "-" ] && EXTRA=""
CONF_DIR="${DM_CONF_DIR:-/etc/dockermanager}"; SCONF="$CONF_DIR/server.json"; PASSF="$CONF_DIR/server.passphrase"
SBR="${DM_SERVER_BACKUP_ROOT:-/var/backups/server}"; RESTORE_ROOT="${DM_RESTORE_ROOT:-/var/restore}"
LOGDIR="${DM_LOG_DIR:-/var/log/dockermanager}"; RUNDIR="${DM_RUN_DIR:-/run/dockermanager}"
HOME_ROOT="${DM_HOME_ROOT:-/home}"
umask 077
[[ "$ACTION" =~ ^(getconfig|setconfig|keyset|keyshow|backup|backups|verify|extract|restoresite|restoredb|prune|delete)$ ]] || exit 1
[[ "$NONCE" =~ ^[0-9a-f]{12}$ ]] || exit 1
[[ "$NAME" =~ ^[A-Za-z0-9._-]*$ ]] && [[ "$NAME" != *..* ]] || exit 1
mkdir -p "$LOGDIR" "$CONF_DIR" "$SBR" "$RUNDIR"; chmod 700 "$LOGDIR" "$CONF_DIR" "$SBR" "$RUNDIR"
ID="srv-$ACTION-${NAME:-all}"
exec 9>"$RUNDIR/job-$ID.lock"
flock -n 9 || exit 0
exec >"$LOGDIR/job-$ID.log" 2>&1
echo "__START__ $NONCE"
fail(){ echo "ERROR: $*"; echo "__DONE__ FAIL"; exit 1; }
ok(){ echo "__DONE__ OK"; exit 0; }
say(){ echo "[$(date +%H:%M:%S)] $*"; }
lock_ops(){ [ "${DM_LOCK_HELD:-0}" = 1 ] && return 0; exec 8>"$RUNDIR/ops.lock"; flock -n 8 || fail "another backup/restore operation is already running"; }
TS_RE='^20[0-9]{6}-[0-9]{6}$'
DOM_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$'
DB_RE='^[A-Za-z0-9_]{1,64}$'
command -v python3 >/dev/null || fail "python3 is required"

DEFAULT_CONF='{"enabled":false,"sites":true,"system":true,"panel":true,"databases":true,"extra_paths":[],"exclude":["/home/*/backup","/home/*/.trash","*/wp-content/cache/*"],"retention_days":5,"min_keep":2,"encrypt":true}'
[ -f "$SCONF" ] || { echo "$DEFAULT_CONF" > "$SCONF"; chmod 600 "$SCONF"; }
cget(){ python3 - "$SCONF" "$1" "${2:-}" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
v=d
for k in sys.argv[2].split('.'):
    v=v.get(k) if isinstance(v,dict) else None
if v is None: v=sys.argv[3]
if isinstance(v,list): v="\n".join(map(str,v))
print(str(v).lower() if isinstance(v,bool) else v)
PY
}
free_kb(){ df --output=avail -k "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
fingerprint(){ [ -s "$PASSF" ] && sha256sum "$PASSF" | cut -c1-8 || echo none; }
have_key(){ [ -s "$PASSF" ]; }
# encryption helpers (stdin -> stdout)
enc(){ if [ "$ENCRYPT" = yes ]; then openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass file:"$PASSF"; else cat; fi; }
dec(){ case "$1" in *.enc) openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:"$PASSF";; *) cat;; esac; }
sfx(){ [ "$ENCRYPT" = yes ] && echo ".enc" || echo ""; }
list_ts(){ ls -1 "$SBR" 2>/dev/null | grep -E "$TS_RE" | sort; }

# MariaDB client settings (CyberPanel keeps the root password in /etc/cyberpanel/mysqlPassword)
mycnf(){
  MYCNF="$RUNDIR/my.cnf"
  python3 - "$MYCNF" <<'PY'
import os,sys
pw=""
for f in ("/etc/cyberpanel/mysqlPassword",):
    try: pw=open(f).read().strip(); break
    except Exception: pass
esc=pw.replace("\\","\\\\").replace('"','\\"')
open(sys.argv[1],"w").write('[client]\nuser=root\n'+('password="%s"\n'%esc if pw else ''))
os.chmod(sys.argv[1],0o600)
PY
}
mysqlc(){ mysql --defaults-extra-file="$MYCNF" "$@"; }
dumpc(){ mysqldump --defaults-extra-file="$MYCNF" "$@"; }
db_list(){ mysqlc -N -B -e 'SHOW DATABASES' 2>/dev/null | grep -vE '^(information_schema|performance_schema|sys)$'; }

# list of existing paths of a group (relative to /, one per line)
paths_for(){
  local g="$1" p
  case "$g" in
    sites) set -- "$HOME_ROOT";;
    system) set -- /etc /var/spool/cron /usr/local/lsws/conf /usr/local/lsws/admin/conf;;
    panel) set -- /usr/local/CyberCP/CyberCP/settings.py /usr/local/lscp/conf;;
    extra) mapfile -t _x < <(cget extra_paths); set -- "${_x[@]}";;
  esac
  for p in "$@"; do [ -n "$p" ] && [ -e "$p" ] && echo "${p#/}"; done
}
exclude_args(){
  EXC=()
  local x
  while IFS= read -r x; do [ -n "$x" ] && EXC+=("--exclude=${x#/}"); done < <(cget exclude)
  EXC+=("--exclude=${SBR#/}" "--exclude=${RESTORE_ROOT#/}")
}

case "$ACTION" in
getconfig|setconfig|keyset|keyshow) : ;;
*) ENCRYPT="$(cget encrypt true | sed 's/true/yes/;s/false/no/')"; [ "$ENCRYPT" = yes ] || ENCRYPT=no;;
esac

case "$ACTION" in
getconfig)
  echo "CONFIG|$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))' "$SCONF")"
  echo "KEY|$(have_key && echo yes || echo no)|$(fingerprint)"
  echo "FREE|$(( $(free_kb "$SBR") / 1048576 ))"
  for d in "$HOME_ROOT"/*/public_html; do [ -d "$d" ] && echo "SITE|$(basename "$(dirname "$d")")"; done
  echo "TOOLS|mysqldump=$(command -v mysqldump >/dev/null && echo yes || echo no),openssl=$(command -v openssl >/dev/null && echo yes || echo no)"
  ok;;
setconfig)
  echo "$EXTRA" | base64 -d > "$RUNDIR/newsconf.json" 2>/dev/null || fail "invalid data"
  python3 - "$RUNDIR/newsconf.json" "$SCONF" <<'PY' || fail "configuration rejected"
import json,re,sys
d=json.load(open(sys.argv[1]))
def num(v,lo,hi,dflt):
    try: v=int(v)
    except Exception: return dflt
    return max(lo,min(hi,v))
path_ok=lambda p: re.match(r'^/[A-Za-z0-9_./-]{1,200}$',str(p)) and str(p).rstrip('/') not in ('','/')
exc_ok=lambda p: re.match(r'^[A-Za-z0-9_./*-]{1,200}$',str(p))
out={"enabled":bool(d.get("enabled",True)),"sites":bool(d.get("sites",True)),"system":bool(d.get("system",True)),
 "panel":bool(d.get("panel",True)),"databases":bool(d.get("databases",True)),
 "extra_paths":[p for p in d.get("extra_paths",[]) if path_ok(p)][:30],
 "exclude":[p for p in d.get("exclude",[]) if exc_ok(p)][:30],
 "retention_days":num(d.get("retention_days"),1,365,5),"min_keep":num(d.get("min_keep"),1,30,2),
 "encrypt":bool(d.get("encrypt",True))}
open(sys.argv[2],"w").write(json.dumps(out,indent=1))
PY
  rm -f "$RUNDIR/newsconf.json"; chmod 600 "$SCONF"; say "Saved."; ok;;
keyset)
  PW="$(echo "$EXTRA" | base64 -d 2>/dev/null)"
  [ "${#PW}" -ge 12 ] || fail "passphrase must be at least 12 characters"
  [[ "$PW" != *$'\n'* ]] || fail "passphrase must be one line"
  if have_key && [ -n "$(list_ts)" ]; then
    echo "WARN: existing backups were encrypted with the OLD passphrase. They need the old passphrase to be opened. Keep it."
  fi
  printf '%s' "$PW" > "$PASSF.tmp" && mv "$PASSF.tmp" "$PASSF"; chmod 600 "$PASSF"; unset PW
  say "Passphrase saved (fingerprint $(fingerprint)). Store a copy somewhere safe OUTSIDE this server: without it encrypted backups cannot be opened."; ok;;
keyshow)
  have_key || fail "no passphrase set yet"
  echo "PASS|$(cat "$PASSF")"; echo "FPR|$(fingerprint)"; ok;;
backup)
  lock_ops
  command -v openssl >/dev/null || fail "openssl is not installed"
  if [ "$ENCRYPT" = yes ] && ! have_key; then fail "encryption is on but no passphrase is set. Set a passphrase first (or switch encryption off)."; fi
  TS="$(date +%Y%m%d-%H%M%S)"; D="$SBR/.partial-$TS"; mkdir -p "$D"; chmod 700 "$D"
  cleanup(){ [ -d "$D" ] && rm -rf "$D"; }
  exclude_args
  # space estimate (uncompressed size of the sources, need at least half of it free)
  est=0
  for g in sites system panel extra; do
    [ "$g" = sites ] && [ "$(cget sites true)" != true ] && continue
    [ "$g" = system ] && [ "$(cget system true)" != true ] && continue
    [ "$g" = panel ] && [ "$(cget panel true)" != true ] && continue
    while IFS= read -r p; do [ -n "$p" ] || continue; k="$(du -sk --exclude="$SBR" "/$p" 2>/dev/null | cut -f1)"; est=$((est + ${k:-0})); done < <(paths_for "$g")
  done
  fr="$(free_kb "$SBR")"
  say "Sources about $((est/1024)) MB, free $((fr/1024)) MB"
  [ "${fr:-0}" -ge $((est/2 + 1048576)) ] || { cleanup; fail "not enough free disk space for this backup"; }
  bad=0; made=""
  for g in sites system panel extra; do
    [ "$g" = sites ] && [ "$(cget sites true)" != true ] && continue
    [ "$g" = system ] && [ "$(cget system true)" != true ] && continue
    [ "$g" = panel ] && [ "$(cget panel true)" != true ] && continue
    mapfile -t P < <(paths_for "$g")
    [ "${#P[@]}" -gt 0 ] || { say "Nothing to back up for '$g' (paths missing) - skipped"; continue; }
    out="$D/files-$g.tar.gz$(sfx)"
    say "Archiving $g (${#P[@]} path(s))..."
    tar --warning=no-file-changed --ignore-failed-read "${EXC[@]}" -czf - -C / "${P[@]}" 2>"$D/.tar-$g.err" | enc > "$out"
    rc=("${PIPESTATUS[@]}")
    if [ "${rc[0]}" -gt 1 ] || [ "${rc[1]}" -ne 0 ]; then echo "ERROR: archive '$g' failed (tar ${rc[0]}, enc ${rc[1]})"; tail -3 "$D/.tar-$g.err"; bad=1; rm -f "$out"; continue; fi
    [ "${rc[0]}" -eq 1 ] && say "(some files changed while being read - normal for a running website)"
    made="$made $g"
  done
  nd=0
  if [ "$(cget databases true)" = true ]; then
    if ! command -v mysqldump >/dev/null; then echo "ERROR: mysqldump not found - databases skipped"; bad=1
    else
      mycnf
      if ! mysqlc -e 'SELECT 1' >/dev/null 2>&1; then echo "ERROR: cannot log in to MariaDB (check /etc/cyberpanel/mysqlPassword) - databases skipped"; bad=1
      else
        while IFS= read -r db; do
          [ -n "$db" ] || continue
          [[ "$db" =~ $DB_RE ]] || { echo "WARN: skipping database with unusual name"; continue; }
          label="$db"; [ "$db" = mysql ] && label="mysql-system"
          out="$D/db-$label.sql.gz$(sfx)"
          dumpc --single-transaction --quick --routines --events --triggers "$db" </dev/null 2>"$D/.dump.err" | gzip -c | enc > "$out"
          rc=("${PIPESTATUS[@]}")
          if [ "${rc[0]}" -ne 0 ] || [ "${rc[2]}" -ne 0 ]; then echo "ERROR: dump of $db failed"; tail -2 "$D/.dump.err"; bad=1; rm -f "$out"; continue; fi
          nd=$((nd+1))
        done < <(db_list </dev/null)
        say "Databases dumped: $nd"
      fi
    fi
  fi
  ls "$D" | grep -qE '^(files|db)-' || { cleanup; fail "nothing was backed up"; }
  ( cd "$D" && sha256sum files-* db-* 2>/dev/null > SHA256SUMS )
  { echo "created=$TS"; echo "host=$(hostname)"; echo "encrypted=$ENCRYPT"; echo "key_fingerprint=$([ "$ENCRYPT" = yes ] && fingerprint || echo -)"; echo "components=$made"; echo "databases=$nd"
    command -v dpkg >/dev/null && echo "packages=$(dpkg --get-selections 2>/dev/null | wc -l)"; [ -f /usr/local/CyberCP/version.txt ] && echo "cyberpanel=$(tr '\n' ' ' < /usr/local/CyberCP/version.txt)"; } > "$D/manifest.txt"
  rm -f "$D"/.tar-*.err "$D/.dump.err"
  mv "$D" "$SBR/$TS" || { cleanup; fail "cannot finalise backup"; }
  say "Backup $TS stored in $SBR/$TS ($(du -sk "$SBR/$TS" | cut -f1) KB, encrypted: $ENCRYPT)"
  [ "$bad" = 0 ] && ok || fail "backup finished with errors (see above)";;
backups)
  for d in $(list_ts | sort -r); do
    comp="$(grep '^components=' "$SBR/$d/manifest.txt" 2>/dev/null | cut -d= -f2- | xargs | tr ' ' ',')"
    nd="$(ls "$SBR/$d" 2>/dev/null | grep -c '^db-')"
    e="$(grep '^encrypted=' "$SBR/$d/manifest.txt" 2>/dev/null | cut -d= -f2)"; fp="$(grep '^key_fingerprint=' "$SBR/$d/manifest.txt" 2>/dev/null | cut -d= -f2)"
    echo "BACKUP|$d|$(du -sk "$SBR/$d" | cut -f1)|${d:0:4}-${d:4:2}-${d:6:2} ${d:9:2}:${d:11:2}|${e:-no}|${fp:--}|${comp:--}|$nd"
    echo "BDB|$d|$(ls "$SBR/$d" 2>/dev/null | grep '^db-' | sed 's/^db-//;s/\.sql\.gz.*//' | grep -v '^mysql-system$' | paste -sd, -)"
  done; ok;;
verify)
  [[ "$EXTRA" =~ $TS_RE ]] || fail "invalid backup id"; B="$SBR/$EXTRA"; [ -d "$B" ] || fail "backup not found"
  say "Checking checksums..."; ( cd "$B" && sha256sum -c --quiet SHA256SUMS ) || fail "checksum mismatch - backup is damaged"
  if ls "$B" | grep -q '\.enc$'; then
    have_key || fail "this backup is encrypted and no passphrase is set on this server"
    want="$(grep '^key_fingerprint=' "$B/manifest.txt" | cut -d= -f2)"
    [ -z "$want" ] || [ "$want" = - ] || [ "$want" = "$(fingerprint)" ] || echo "WARN: passphrase fingerprint differs (backup $want, current $(fingerprint))"
  fi
  for f in "$B"/files-* "$B"/db-*; do
    [ -f "$f" ] || continue
    dec "$f" < "$f" | gzip -t 2>/dev/null && say "OK  $(basename "$f")" || { echo "ERROR: cannot read $(basename "$f") (wrong passphrase or damaged file)"; fail "verification failed"; }
  done
  say "Backup $EXTRA is complete and readable."; ok;;
extract)
  lock_ops
  [[ "$EXTRA" =~ $TS_RE ]] || fail "invalid backup id"; B="$SBR/$EXTRA"; [ -d "$B" ] || fail "backup not found"
  ( cd "$B" && sha256sum -c --quiet SHA256SUMS ) || fail "checksum mismatch - backup is damaged"
  mkdir -p "$RESTORE_ROOT"; chmod 700 "$RESTORE_ROOT"
  need=$(( $(du -sk "$B" | cut -f1) * 3 )); [ "$(free_kb "$RESTORE_ROOT")" -ge "$need" ] || fail "not enough free disk space to extract"
  T="$RESTORE_ROOT/$EXTRA"; mkdir -p "$T"; chmod 700 "$RESTORE_ROOT" "$T"
  for f in "$B"/files-*; do
    [ -f "$f" ] || continue; g="$(basename "$f" | sed 's/^files-//;s/\.tar\.gz.*//')"; mkdir -p "$T/$g"
    say "Extracting $g ..."; dec "$f" < "$f" | tar -xzpf - -C "$T/$g" || fail "extract of $g failed"
  done
  mkdir -p "$T/db"
  for f in "$B"/db-*; do [ -f "$f" ] || continue; n="$(basename "$f" .enc)"; dec "$f" < "$f" > "$T/db/$n" || fail "decrypt of $n failed"; done
  say "Extracted to $T (nothing on the live server was changed). Delete it when you no longer need it: rm -rf $T"; ok;;
restoresite)
  lock_ops
  [[ "$EXTRA" =~ $TS_RE ]] || fail "invalid backup id"; [[ "$NAME" =~ $DOM_RE ]] || fail "invalid website name"
  B="$SBR/$EXTRA"; f="$(ls "$B"/files-sites.tar.gz* 2>/dev/null | head -1)"; [ -f "$f" ] || fail "this backup has no website files"
  ( cd "$B" && sha256sum -c --quiet SHA256SUMS ) || fail "checksum mismatch - backup is damaged"
  hr="${HOME_ROOT#/}"; TMP="$HOME_ROOT/.dm-restore-$EXTRA"; rm -rf "$TMP"; mkdir -p "$TMP"
  say "Extracting $NAME from the backup..."
  dec "$f" < "$f" | tar -xzpf - -C "$TMP" --wildcards "$hr/$NAME" "$hr/$NAME/*" 2>/dev/null
  [ -d "$TMP/$hr/$NAME" ] || { rm -rf "$TMP"; fail "website $NAME is not in this backup"; }
  NOW="$(date +%Y%m%d-%H%M%S)"
  if [ -d "$HOME_ROOT/$NAME" ]; then
    say "Keeping the current files as $HOME_ROOT/$NAME.before-restore-$NOW"
    mv "$HOME_ROOT/$NAME" "$HOME_ROOT/$NAME.before-restore-$NOW" || { rm -rf "$TMP"; fail "cannot move the current folder away"; }
  fi
  mv "$TMP/$hr/$NAME" "$HOME_ROOT/$NAME" || fail "cannot put the restored folder in place (current files are in $HOME_ROOT/$NAME.before-restore-$NOW)"
  rm -rf "$TMP"
  say "Website files of $NAME restored. The database is NOT touched: restore it separately if needed. Remove the old folder when you are sure: rm -rf $HOME_ROOT/$NAME.before-restore-$NOW"; ok;;
restoredb)
  lock_ops
  [[ "$EXTRA" =~ $TS_RE ]] || fail "invalid backup id"; [[ "$NAME" =~ $DB_RE ]] || fail "invalid database name"
  case "$NAME" in mysql|mysql-system|information_schema|performance_schema|sys) fail "system databases are not restored from here (see the documentation)";; esac
  B="$SBR/$EXTRA"; f="$(ls "$B"/db-"$NAME".sql.gz* 2>/dev/null | head -1)"; [ -f "$f" ] || fail "database $NAME is not in this backup"
  ( cd "$B" && sha256sum -c --quiet SHA256SUMS ) || fail "checksum mismatch - backup is damaged"
  mycnf; mysqlc -e 'SELECT 1' >/dev/null 2>&1 || fail "cannot log in to MariaDB"
  dec "$f" < "$f" | gzip -t || fail "cannot read the dump (wrong passphrase or damaged file)"
  mkdir -p "$SBR/_safety"; chmod 700 "$SBR/_safety"; NOW="$(date +%Y%m%d-%H%M%S)"
  if mysqlc -N -e "SELECT 1 FROM information_schema.schemata WHERE schema_name='$NAME'" 2>/dev/null | grep -q 1; then
    say "Safety dump of the current $NAME ..."
    dumpc --single-transaction --quick --routines --events --triggers "$NAME" </dev/null | gzip -c | enc > "$SBR/_safety/db-$NAME-before-restore-$NOW.sql.gz$(sfx)"
    [ "${PIPESTATUS[0]}" -eq 0 ] || fail "safety dump failed - restore cancelled"
  fi
  mysqlc -e "CREATE DATABASE IF NOT EXISTS \`$NAME\`" || fail "cannot create the database"
  say "Importing..."
  dec "$f" < "$f" | gunzip -c | mysqlc "$NAME" || fail "import failed (the safety dump is in $SBR/_safety/)"
  say "Database $NAME restored from $EXTRA. Tables that exist now but not in the dump were left in place."; ok;;
delete)
  lock_ops
  [[ "$EXTRA" =~ $TS_RE ]] || fail "invalid backup id"
  [ -d "$SBR/$EXTRA" ] || fail "backup not found"
  rm -rf "${SBR:?}/$EXTRA" || fail "could not delete $EXTRA"
  say "Deleted server backup $EXTRA"; ok;;
prune)
  lock_ops
  days="$(cget retention_days 5)"; keep="$(cget min_keep 2)"
  [[ "$days" =~ ^[0-9]+$ ]] && [[ "$keep" =~ ^[0-9]+$ ]] || fail "bad retention settings"
  mapfile -t ALL < <(list_ts); n=${#ALL[@]}; del=0
  for i in "${!ALL[@]}"; do
    d="${ALL[$i]}"; left=$((n - i - 1))
    [ "$left" -lt "$keep" ] && continue
    [ -n "$(find "$SBR/$d" -maxdepth 0 -mtime +"$days" 2>/dev/null)" ] || continue
    rm -rf "${SBR:?}/$d" && { say "Removed $d"; del=$((del+1)); }
  done
  find "$SBR/_safety" -type f -mtime +30 -delete 2>/dev/null
  say "Retention: $days days, always keep newest $keep. Removed $del."; ok;;
esac
