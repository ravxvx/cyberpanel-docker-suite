# Docker Suite for CyberPanel

CyberPanel plugin: containers overview, GLPI (Docker) backup/update with rollback, image updates,
server backup (websites, system, databases; optional AES-256 encryption) and optional copy to a NAS over SSH
(OpenVPN / WireGuard). Version 0.7.0 adds a new design, an Overview tab and readable error messages.

## Install (as root)
```
cp dockerSuite.zip /usr/local/CyberCP/dockerSuite.zip      # the zip must be named exactly dockerSuite.zip
cd /usr/local/CyberCP
/usr/local/CyberCP/bin/python pluginInstaller/pluginInstaller.py install --pluginName dockerSuite
```
Refresh the panel with Ctrl+F5. Ready zip: `dist/dockerSuite.zip`.

## Upgrade / remove
```
cd /usr/local/CyberCP
/usr/local/CyberCP/bin/python pluginInstaller/pluginInstaller.py remove --pluginName dockerSuite
```
then install again. Removing keeps backups (`/var/backups/docker`) and settings (`/etc/dockermanager`).

## Errors
Details are logged to `/var/log/dockermanager/plugin-errors.log`.

## Build the zip
```
zip -r dist/dockerSuite.zip dockerSuite -x '*/__pycache__/*'
```
