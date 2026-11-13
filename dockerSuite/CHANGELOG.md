# Changelog

## 0.7.0
- New design: hero with live numbers, tab bar, cleaner cards and tables.
- New Overview tab (opens first): CPU, memory, system disk, uptime, service status
  (Docker, OpenLiteSpeed, CyberPanel, MariaDB), backup counts / size / age for containers,
  GLPI and server, daily-job status, and alerts (restart needed, disk >= 85%, no recent backup).
- Errors no longer show as a bare HTTP 500: every endpoint returns a readable JSON error and logs the
  traceback to /var/log/dockermanager/plugin-errors.log; the page explains non-JSON answers.
- Containers tab loads only when opened (faster first page).
- No change to backup, restore, GLPI or NAS logic (dmtool.sh, glpitool.sh, srvtool.sh unchanged).

## 0.6.0
- Previous release.
