# Changelog

## 0.8.2
- Assistant settings: the model is now a normal drop-down list (filled by "Load models"), with "Type another model name..." for anything else.
- New "Test" button: saves the provider and checks that the model answers and can run commands (tool use).
- Groq default model is now openai/gpt-oss-120b (llama-3.3-70b-versatile is not available to every key).
- Form fields stay white when the panel uses a dark theme.

## 0.8.1
- Assistant: choose the AI provider in Settings - Anthropic Claude, Groq (free tier), Google Gemini (free tier),
  OpenRouter, or any OpenAI-compatible API (e.g. Ollama). One key per provider, stored root-only.
- "Load models" lists the models your key can use; clear message when a free-tier limit is hit (HTTP 429).

## 0.8.0
- Cleaner layout: Overview, Containers, GLPI, Backups (server backup, schedule, NAS/VPN as sub-tabs),
  Assistant, Settings. Activity log is a small bar at the bottom of the page; links like
  `#tab=containers&ct=name` open a tab or container directly.
- Server Command Center is now built in: server overview (CPU, memory, disk, services, newest backup
  incl. WordPress Toolkit backups), AI assistant with approval for every changing command, and the audit log.
  The API key, model and audit log of the old plugin are copied over on install.
- Container details: click a container for live CPU / memory / network / disk usage (refreshes every 10 s),
  ports, networks, volumes with sizes, restart policy, health, the last 60 log lines, and its backups.
- Test restore: the "Test" button checks a container or GLPI backup without touching anything live:
  checksums, every archive is unpacked in memory, and the database dump is imported into a temporary
  container (no network) that is deleted afterwards.
- Disk cleanup (Settings): dangling and unused images, build cache, unused volumes (confirm with DELETE),
  container logs over 50 MB, extracted backups in /var/restore.
- E-mail alerts (Settings): a container stops or is unhealthy, disk over the limit, no new backup, nightly
  job errors. Checked every 10 minutes; one mail per problem, a reminder after 24 h, a mail when fixed.
  Sends through this server (sendmail) or any SMTP server.
- Self-update from GitHub (Settings > Docker Suite updates): new files are checked first, the current version
  is saved to /root/dockersuite-<version>-<date>.tar.gz. Uses the GitHub API at a fixed commit, so a new
  release is visible at once.
- Fix: reinstalling or updating no longer resets the settings (NAS, containers, schedule) to defaults.
- Includes 0.7.1 (green design, delete backups, GLPI 11 requirements check) and the 0.7.0 error handling.

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
