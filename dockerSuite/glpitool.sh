#!/bin/bash
# GLPI Manager - actions for docker-compose GLPI instances in /opt/glpi/<name>/ (runs as root).
# Usage: glpitool.sh ACTION NAME|- EXTRA|- NONCE      ACTION: list | backup | backups | update | restore | logs | new | check | check
set -uo pipefail
ACTION="${1:-}"; NAME="${2:--}"; EXTRA="${3:--}"; NONCE="${4:-}"
[ "$NAME" = "-" ] && NAME=""; [ "$EXTRA" = "-" ] && EXTRA=""
BASE="${GLPI_BASE:-/opt/glpi}"; BACKUPROOT="${GLPI_BACKUP_ROOT:-/var/backups/glpi}"; LOGDIR="${DM_LOG_DIR:-/var/log/dockermanager}"
SELF="$(dirname "$(readlink -f "$0")")"
umask 077
[[ "$ACTION" =~ ^(list|backup|backups|update|restore|logs|new|check|delete)$ ]] || exit 1
[[ "$NONCE" =~ ^[0-9a-f]{12}$ ]] || exit 1
mkdir -p "$LOGDIR"; chmod 700 "$LOGDIR"; GLPI_LOCKDIR="${DM_RUN_DIR:-/var/run}"; mkdir -p "$GLPI_LOCKDIR"
ID="glpi-$ACTION-${NAME:-all}"
exec 9>"/var/run/glpimanager-job-$ID.lock"
flock -n 9 || exit 0
exec >"$LOGDIR/job-$ID.log" 2>&1
echo "__START__ $NONCE"
fail(){ echo "ERROR: $*"; echo "__DONE__ FAIL"; exit 1; }
ok(){ echo "__DONE__ OK"; exit 0; }
command -v docker >/dev/null || fail "docker is not installed"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is not available"

compose_file(){ ls "$1" 2>/dev/null | grep -E '^(docker-compose|compose)\.ya?ml$' | head -1; }
need_inst(){
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || fail "invalid instance name"
  DIR="$BASE/$NAME"
  [ -n "$(compose_file "$DIR")" ] || fail "no docker-compose file in $DIR"
  exec 8>"/var/run/glpimanager-$NAME.lock"
  flock -n 8 || fail "another operation is already running for $NAME"
  cd "$DIR" || fail "cannot enter $DIR"
}
svc_info(){   # service -> image|state|started
  local cid
  cid="$(docker compose ps -a -q "$1" 2>/dev/null | head -1)"
  [ -n "$cid" ] || { echo "-|missing|-"; return; }
  docker inspect -f '{{.Config.Image}}|{{.State.Status}}|{{.State.StartedAt}}' "$cid" 2>/dev/null || echo "-|unknown|-"
}

# ---------------- health check ----------------
# sqlq SQL -> runs the query as DB root inside the db container (credentials come from the container's own env)
sqlq(){ docker compose exec -T db sh -c 'PW="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"; DB="${MARIADB_DATABASE:-${MYSQL_DATABASE:-glpi}}"; C=$(command -v mariadb || command -v mysql); MYSQL_PWD="$PW" "$C" -uroot -N -B "$DB" -e "$1"' sh "$1" </dev/null 2>/dev/null; }
# run_checks: current dir = instance dir, NAME/DIR set. Prints CHECK lines; sets CHK_OK/CHK_WARN/CHK_FAIL. PL_BEFORE = newline list of plugins active before an update (optional).
run_checks(){
  CHK_OK=0; CHK_WARN=0; CHK_FAIL=0
  chk(){ echo "CHECK|$1|$2|$3"; case "$2" in OK) CHK_OK=$((CHK_OK+1));; WARN) CHK_WARN=$((CHK_WARN+1));; FAIL) CHK_FAIL=$((CHK_FAIL+1));; esac; }
  local svc info st rc img tag q port code body t dbv users tables
  for svc in glpi db; do
    info="$(svc_info "$svc")"; st="$(echo "$info" | cut -d'|' -f2)"
    cid="$(docker compose ps -a -q "$svc" 2>/dev/null | head -1)"
    if [ "$st" != running ]; then chk "container $svc" FAIL "state: ${st:-unknown}"; else
      rc="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null)"
      if [ "${rc:-0}" -gt 3 ] 2>/dev/null; then chk "container $svc" WARN "running, but restarted $rc times"; else chk "container $svc" OK "running"; fi
    fi
  done
  q="$(sqlq 'SELECT 1')"; if [ "$q" = 1 ]; then chk "database answers" OK "SELECT 1 works"; else chk "database answers" FAIL "cannot query the database"; fi
  tables="$(sqlq 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()')"
  if [[ "$tables" =~ ^[0-9]+$ ]] && [ "$tables" -gt 100 ]; then chk "database schema" OK "$tables tables"; else chk "database schema" FAIL "only ${tables:-0} tables - database empty or damaged"; fi
  dbv="$(sqlq "SELECT value FROM glpi_configs WHERE context='core' AND name='version' LIMIT 1")"
  img="$(docker compose ps -q glpi 2>/dev/null | head -1 | xargs -r docker inspect -f '{{.Config.Image}}' 2>/dev/null)"; tag="${img##*:}"
  if [ -z "$dbv" ]; then chk "version match" FAIL "cannot read the database version"
  elif [ "$dbv" = "$tag" ]; then chk "version match" OK "database and image are both $dbv"
  else chk "version match" FAIL "image is $tag but the database is $dbv - run database:update"; fi
  users="$(sqlq 'SELECT COUNT(*) FROM glpi_users WHERE is_deleted=0')"
  if [[ "$users" =~ ^[0-9]+$ ]] && [ "$users" -ge 1 ]; then chk "data present" OK "$users user(s), $(sqlq 'SELECT COUNT(*) FROM glpi_tickets') ticket(s)"; else chk "data present" FAIL "no users found"; fi
  port="$(docker compose port glpi 80 2>/dev/null | sed 's/.*://' | head -1)"
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    body="$(mktemp)"; t="$(curl -s -m 15 -o "$body" -w '%{http_code} %{time_total}' "http://127.0.0.1:$port/index.php" 2>/dev/null)"; code="${t%% *}"
    case "$code" in 200|301|302|303|307|308) chk "web answers" OK "HTTP $code in ${t##* }s";; *) chk "web answers" FAIL "HTTP ${code:-none}";; esac
    if grep -qi 'glpi' "$body" 2>/dev/null || [[ "$code" =~ ^30 ]]; then chk "login page" OK "GLPI page served"; else chk "login page" WARN "response does not look like the GLPI login page"; fi
    rm -f "$body"
  else chk "web answers" FAIL "no published port for the glpi service"; fi
  # plugins
  local pl_now lost
  pl_now="$(sqlq 'SELECT directory FROM glpi_plugins WHERE state=1 ORDER BY directory')"
  if [ -n "${PL_BEFORE:-}" ]; then
    lost="$(comm -23 <(echo "$PL_BEFORE" | sort) <(echo "$pl_now" | sort) | tr '\n' ' ')"
    if [ -n "$lost" ]; then chk "plugins" WARN "no longer active after the update: $lost(check GLPI > Setup > Plugins)"; else chk "plugins" OK "all previously active plugins are still active"; fi
  else chk "plugins" OK "$(echo "$pl_now" | grep -c .) active plugin(s): $(echo "$pl_now" | tr '\n' ' ')"; fi
  # GLPI's own diagnostics (skipped if this version does not have them)
  local out
  out="$(timeout 90 docker compose exec -T -u www-data glpi php /var/www/glpi/bin/console system:check_requirements --no-interaction </dev/null 2>&1)"; rc=$?
  if echo "$out" | grep -qi 'not defined\|command .* not'; then chk "GLPI requirements" OK "skipped (not available in this version)"
  elif [ $rc -eq 0 ]; then chk "GLPI requirements" OK "all requirements met"; else chk "GLPI requirements" WARN "$(echo "$out" | grep -i 'error\|fail\|✘\|missing' | head -2 | tr '\n' ' ')- run 'bin/console system:check_requirements' for details"; fi
  out="$(timeout 120 docker compose exec -T -u www-data glpi php /var/www/glpi/bin/console database:check_schema_integrity --no-interaction </dev/null 2>&1)"; rc=$?
  if echo "$out" | grep -qi 'not defined\|command .* not'; then chk "schema integrity" OK "skipped (not available in this version)"
  elif [ $rc -eq 0 ]; then chk "schema integrity" OK "database structure matches this GLPI version"; else chk "schema integrity" WARN "differences found: run 'bin/console database:check_schema_integrity' for details"; fi
  # recent errors in GLPI logs (last 15 min)
  out="$(docker compose exec -T glpi sh -c 'for f in $(find /var/glpi -maxdepth 3 \( -name php-errors.log -o -name sql-errors.log \) -mmin -15 -size +0 2>/dev/null); do echo "== $f"; tail -n 3 "$f"; done' </dev/null 2>/dev/null)"
  if [ -n "$out" ]; then chk "error logs" WARN "new log lines in the last 15 min: $(echo "$out" | tr '\n' ' ' | cut -c1-300)"; else chk "error logs" OK "no new errors in php-errors.log / sql-errors.log"; fi
  # backups, disk, domain/SSL
  local last age free dom exp days hc
  last="$(ls -1dt "$BACKUPROOT/$NAME"/20* 2>/dev/null | grep -v partial | head -1)"
  if [ -z "$last" ]; then chk "backup" WARN "no backup yet"; else
    age=$(( ( $(date +%s) - $(stat -c %Y "$last") ) / 3600 ))
    if [ "$age" -le 36 ]; then chk "backup" OK "last backup $age h ago"; else chk "backup" WARN "last backup is $age h old"; fi; fi
  free="$(df -Pk "$BACKUPROOT" 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1048576}')"
  if [ -n "$free" ] && [ "$free" -ge 2 ]; then chk "disk space" OK "${free} GB free for backups"; else chk "disk space" WARN "only ${free:-?} GB free"; fi
  dom="$(cat "$DIR/.domain" 2>/dev/null | head -1)"
  if [[ "$dom" =~ ^[a-z0-9.-]+$ ]]; then
    hc="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$dom/" 2>/dev/null)"
    case "$hc" in 200|301|302|303|307|308) chk "public HTTPS" OK "https://$dom -> HTTP $hc";; *) chk "public HTTPS" FAIL "https://$dom -> HTTP ${hc:-none}";; esac
    exp="$(echo | timeout 10 openssl s_client -servername "$dom" -connect "$dom:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [ -n "$exp" ]; then days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
      if [ "$days" -ge 14 ]; then chk "SSL certificate" OK "valid for $days more days"; else chk "SSL certificate" WARN "expires in $days days"; fi
    else chk "SSL certificate" WARN "cannot read the certificate"; fi
  else chk "public HTTPS" OK "skipped (no domain recorded: echo yourdomain > $DIR/.domain to enable)"; fi
  echo "RESULT|$NAME|$CHK_OK|$CHK_WARN|$CHK_FAIL"
}

case "$ACTION" in

list)
  for d in "$BASE"/*/; do
    d="${d%/}"; [ -n "$(compose_file "$d")" ] || continue
    n="$(basename "$d")"
    [[ "$n" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || continue
    cd "$d" || continue
    IFS='|' read -r gimg gst gsince <<<"$(svc_info glpi)"
    IFS='|' read -r dimg dst _ <<<"$(svc_info db)"
    port="$(docker compose port glpi 80 2>/dev/null | sed 's/.*://' | head -1)"
    last="$(ls -1dt "$BACKUPROOT/$n"/20* 2>/dev/null | head -1)"
    cnt="$(ls -1d "$BACKUPROOT/$n"/20* 2>/dev/null | wc -l)"
    free="$(df -Pk "$BACKUPROOT" 2>/dev/null | awk 'NR==2{printf "%.1f", $4/1048576}')"
    echo "INST|$n|${gimg:--}|${gst:--}|${gsince:--}|${dimg:--}|${dst:--}|${port:--}|$(basename "${last:--}")|$cnt|${free:--}"
  done
  ok ;;

backup)
  need_inst
  "$SELF/glpibackup" "$DIR" && ok
  fail "backup failed - see the messages above" ;;

backups)
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || fail "invalid instance name"
  for b in $(ls -1dt "$BACKUPROOT/$NAME"/20* 2>/dev/null); do
    [[ "$(basename "$b")" =~ \.partial$ ]] && continue
    echo "BACKUP|$(basename "$b")|$(du -sk "$b" | cut -f1)|$(stat -c %y "$b" | cut -c1-16)"
  done
  ok ;;

delete)
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || fail "invalid instance name"
  [[ "$EXTRA" =~ ^20[0-9]{6}-[0-9]{6}$ ]] || fail "invalid backup id"
  [ -d "$BACKUPROOT/$NAME/$EXTRA" ] || fail "backup not found"
  exec 8>"/var/run/glpimanager-$NAME.lock"
  flock -n 8 || fail "another operation is already running for $NAME"
  rm -rf "${BACKUPROOT:?}/$NAME/$EXTRA" || fail "could not delete $EXTRA"
  echo "Deleted GLPI backup $EXTRA of $NAME"
  ok ;;

logs)
  need_inst
  docker compose logs --no-color --tail 120 glpi db 2>&1
  ok ;;

restore)
  need_inst
  [[ "$EXTRA" =~ ^20[0-9]{6}-[0-9]{6}$ ]] || fail "invalid backup id"
  [ -d "$BACKUPROOT/$NAME/$EXTRA" ] || fail "backup not found"
  "$SELF/glpirestore" --yes "$BACKUPROOT/$NAME/$EXTRA" "$DIR" && ok
  fail "restore failed - a safety backup of the previous state is in $BACKUPROOT/$NAME" ;;

update)
  need_inst
  MAJOR_OK=0; case "$EXTRA" in *:major) MAJOR_OK=1; EXTRA="${EXTRA%:major}";; esac
  [[ "$EXTRA" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid target version"
  F="$(compose_file "$DIR")"
  cur="$(grep -oE 'glpi/glpi:[0-9][0-9A-Za-z._-]*' "$F" | head -1 | cut -d: -f2)"
  [ -n "$cur" ] || fail "no 'glpi/glpi:<version>' image in $F (maybe the version comes from .env - edit it by hand)"
  [ "$cur" != "$EXTRA" ] || fail "already on $EXTRA"
  if [ "${cur%%.*}" != "${EXTRA%%.*}" ]; then
    [ "$MAJOR_OK" = 1 ] || fail "major upgrade blocked ($cur -> $EXTRA): confirm it in the panel"
    echo "!! MAJOR upgrade $cur -> $EXTRA confirmed by the administrator. Backup is made first; automatic rollback if it fails."
  fi
  [ "$(printf '%s\n%s\n' "$cur" "$EXTRA" | sort -V | tail -1)" = "$EXTRA" ] || fail "downgrade blocked ($cur -> $EXTRA)"
  echo "== Health check BEFORE the update =="
  run_checks
  [ "$CHK_FAIL" -eq 0 ] || fail "GLPI is not healthy before the update (see the failed checks above) - fix that first; nothing was changed"
  echo "== Pulling glpi/glpi:$EXTRA =="
  docker pull "glpi/glpi:$EXTRA" 2>&1 | tail -3
  docker image inspect "glpi/glpi:$EXTRA" >/dev/null 2>&1 || fail "cannot pull glpi/glpi:$EXTRA (does the tag exist?)"
  echo "== Backup before the update =="
  "$SELF/glpibackup" "$DIR" || fail "backup failed - nothing was changed"
  BK="$(ls -1dt "$BACKUPROOT/$NAME"/20* | grep -v partial | head -1)"
  [ -d "$BK" ] || fail "cannot locate the backup just made"
  cp "$F" "$BK/$F.pre-update"
  PL_BEFORE="$(sqlq 'SELECT directory FROM glpi_plugins WHERE state=1 ORDER BY directory')"
  echo "== Switching $cur -> $EXTRA =="
  sed -i "s#glpi/glpi:$cur#glpi/glpi:$EXTRA#" "$F"
  rollback(){
    echo "!! $1 - rolling back to $cur"
    cp "$BK/$F.pre-update" "$F"
    "$SELF/glpirestore" --yes --no-safety "$BK" "$DIR"
    echo "Rolled back to $cur (database and files restored from $BK)."
    echo "__DONE__ FAIL"; exit 1
  }
  docker compose up -d glpi 2>&1 | tail -3
  [ "${PIPESTATUS[0]}" -eq 0 ] || rollback "cannot start the new container"
  port="$(docker compose port glpi 80 2>/dev/null | sed 's/.*://' | head -1)"
  [[ "$port" =~ ^[0-9]+$ ]] || rollback "cannot find the published port of the glpi service"
  wait_http(){
    local i code
    for i in $(seq 1 40); do
      code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$port/")"
      case "$code" in 200|301|302|303|307|308|401|403) return 0;; esac
      sleep 3
    done
    return 1
  }
  echo "== Waiting for GLPI =="
  wait_http || rollback "GLPI did not answer after the update"
  echo "== Database update (bin/console database:update) =="
  docker compose exec -T -u www-data glpi php /var/www/glpi/bin/console database:update --no-interaction > "$LOGDIR/.dbupdate-$NAME.txt" 2>&1
  rc=$?
  tail -n 15 "$LOGDIR/.dbupdate-$NAME.txt"
  [ "$rc" -eq 0 ] || rollback "database:update failed"
  wait_http || rollback "GLPI is not healthy after the database update"
  echo "== Health check after the update =="
  run_checks
  [ "$CHK_FAIL" -eq 0 ] || rollback "health check found $CHK_FAIL critical problem(s)"
  [ "$CHK_WARN" -eq 0 ] || echo "NOTE: $CHK_WARN warning(s) above - GLPI works, but please review them."
  echo "Updated $NAME: $cur -> $EXTRA. Backup kept: $BK"
  echo "Reminder: check your custom plugins (e.g. Device Timeline) in GLPI > Setup > Plugins."
  ok ;;
check)
  need_inst
  run_checks
  [ "$CHK_FAIL" -eq 0 ] && ok || fail "health check found $CHK_FAIL critical problem(s)" ;;
new)
  # Create a NEW, independent GLPI instance (own DB, volumes, port, optional domain + SSL). EXTRA = DOMAIN|none|VERSION|PUBLISH(0/1)
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || fail "invalid instance name (use a-z, 0-9, - and _)"
  IFS='|' read -r DOM VER PUB <<<"$EXTRA"
  [[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid GLPI version"
  [[ "$PUB" =~ ^[01]$ ]] || PUB=0
  [ "$DOM" = none ] && DOM=""
  if [ -n "$DOM" ]; then [[ "$DOM" =~ ^[a-z0-9]([a-z0-9.-]{1,200})\.[a-z]{2,}$ ]] || fail "invalid domain name"; fi
  exec 7>"$GLPI_LOCKDIR/glpimanager-new.lock" 2>/dev/null || exec 7>"/tmp/glpimanager-new.lock"
  flock -n 7 || fail "another instance is being created"
  DIR="$BASE/$NAME"
  [ ! -e "$DIR" ] || fail "$DIR already exists - choose another name"
  # free local port: not used by other instances' compose files and not listening
  PORT=18081
  while grep -rqs "127.0.0.1:$PORT:" "$BASE"/*/ 2>/dev/null || (ss -ltn 2>/dev/null | grep -q ":$PORT "); do PORT=$((PORT+1)); [ "$PORT" -gt 18999 ] && fail "no free port"; done
  echo "== Creating $NAME: GLPI $VER on 127.0.0.1:$PORT =="
  docker pull "glpi/glpi:$VER" 2>&1 | tail -2
  docker image inspect "glpi/glpi:$VER" >/dev/null 2>&1 || fail "cannot pull glpi/glpi:$VER (does the tag exist?)"
  docker pull mariadb:11.8 2>&1 | tail -1
  mkdir -p "$DIR" || fail "cannot create $DIR"; chmod 700 "$DIR"
  RP="$(openssl rand -hex 16)"; DP="$(openssl rand -hex 16)"
  printf 'DB_ROOT_PASSWORD=%s\nDB_PASSWORD=%s\n' "$RP" "$DP" > "$DIR/.env"; chmod 600 "$DIR/.env"
  cat > "$DIR/compose.yml" <<CMP
name: glpi_$NAME
services:
  glpi:
    image: glpi/glpi:$VER
    restart: unless-stopped
    depends_on:
      - db
    ports:
      - "127.0.0.1:$PORT:80"
    volumes:
      - glpi_data:/var/glpi
      - glpi_plugins:/var/www/glpi/plugins
  db:
    image: mariadb:11.8
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: glpi
      MARIADB_USER: glpi
      MARIADB_PASSWORD: \${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
volumes:
  glpi_data:
  glpi_plugins:
  db_data:
CMP
  [ -n "$DOM" ] && echo "$DOM" > "$DIR/.domain"
  cd "$DIR" || fail "cannot enter $DIR"
  cleanup_fail(){ echo "!! $1"; echo "The folder $DIR was kept so you can inspect it (docker compose logs). Remove it with: cd $DIR && docker compose down -v && cd .. && rm -rf $NAME"; echo "__DONE__ FAIL"; exit 1; }
  echo "== Starting containers =="
  docker compose up -d 2>&1 | tail -4; [ "${PIPESTATUS[0]}" -eq 0 ] || cleanup_fail "docker compose up failed"
  echo "== Waiting for the database =="
  okdb=0; for i in $(seq 1 45); do docker compose exec -T -e MYSQL_PWD="$RP" db sh -c 'mariadb-admin ping -uroot --silent' >/dev/null 2>&1 </dev/null && { okdb=1; break; }; sleep 2; done
  [ "$okdb" = 1 ] || cleanup_fail "database did not start in 90 s"
  echo "== Installing the empty GLPI database =="
  docker compose exec -T -u www-data -e DBP="$DP" glpi sh -c 'php /var/www/glpi/bin/console database:install --db-host=db --db-name=glpi --db-user=glpi --db-password="$DBP" --default-language=en_GB --no-interaction --force' </dev/null 2>&1 | tail -8
  [ "${PIPESTATUS[0]}" -eq 0 ] || cleanup_fail "database:install failed - open http://127.0.0.1:$PORT through the domain and use the web installer (DB host: db, name: glpi, user: glpi, password: see $DIR/.env)"
  okh=0; for i in $(seq 1 30); do code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/")"; case "$code" in 200|301|302|303|307|308|401|403) okh=1; break;; esac; sleep 2; done
  [ "$okh" = 1 ] || echo "WARN: GLPI did not answer on port $PORT yet (HTTP $code)"
  echo "== GLPI answers on 127.0.0.1:$PORT =="
  if [ "$PUB" = 1 ] && [ -n "$DOM" ]; then
    echo "== Publishing https://$DOM (DNS of $DOM must already point to this server) =="
    VH="/usr/local/lsws/conf/vhosts/$DOM/vhost.conf"
    if [ ! -f "$VH" ]; then
      cyberpanel createWebsite --package Default --owner admin --domainName "$DOM" --email "admin@$DOM" --php 8.3 2>&1 | tail -3
    fi
    if [ -f "$VH" ]; then
      cyberpanel issueSSL --domainName "$DOM" 2>&1 | tail -3 || true
      if ! grep -q "glpi_$NAME" "$VH"; then
        cp "$VH" "$VH.bak-$(date +%s)"
        cat >> "$VH" <<VHB

extprocessor glpi_$NAME {
  type                    proxy
  address                 http://127.0.0.1:$PORT
  maxConns                100
  pcKeepAliveTimeout      60
  initTimeout             60
  retryTimeout            0
  respBuffer              0
}

context / {
  type                    proxy
  handler                 glpi_$NAME
  addDefaultCharset       off
}
VHB
      fi
      systemctl restart lsws >/dev/null 2>&1 || /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1
      sleep 3; echo "Website published: https://$DOM"
    else
      echo "WARN: could not create the website automatically. Create it in CyberPanel (Websites > Create Website for $DOM), issue SSL, then add a proxy to http://127.0.0.1:$PORT."
    fi
  elif [ -n "$DOM" ]; then
    echo "Domain not published (option off). Create the website for $DOM in CyberPanel and proxy it to http://127.0.0.1:$PORT."
  fi
  echo "== Health check =="
  run_checks
  echo ""
  echo "DONE: instance '$NAME' created."
  echo "  Local address : http://127.0.0.1:$PORT"
  [ -n "$DOM" ] && echo "  Domain        : https://$DOM"
  echo "  Database/root passwords are stored in $DIR/.env (root only)."
  echo "  FIRST LOGIN   : glpi / glpi  (also tech/tech, normal/normal, post-only/postonly)."
  echo "  -> Change ALL default passwords immediately and set the URL in GLPI: Setup > General > URL of the application."
  echo "  This instance is now included in nightly backups, retention and the NAS copy."
  ok ;;
esac
