#!/bin/sh
# Adds (or refreshes) the "Docker Suite" sidebar link. Written in a safe form: if the plugin's URL ever
# disappears (e.g. after a CyberPanel upgrade) the link is hidden instead of breaking the panel.
# Run any time:   sh /usr/local/CyberCP/dockerSuite/repair-menu.sh && systemctl restart lscpd
IDX="${1:-/usr/local/CyberCP/baseTemplate/templates/baseTemplate/index.html}"
[ -f "$IDX" ] || { echo "Template not found: $IDX"; exit 1; }
LINK="{# DM-BEGIN #}{% url 'dockerSuite' as dm_url %}{% if dm_url %}<a href=\"{{ dm_url }}\" class=\"menu-item\"><div class=\"icon-wrapper\"><i class=\"fas fa-cubes\"></i></div><span>Docker Suite</span></a>{% endif %}{# DM-END #}"
sed -i '/DM-BEGIN/d' "$IDX"
if grep -q "{% url 'dockerSuite' %}\" class=\"menu-item\"" "$IDX" && grep -q '</a>' "$IDX"; then
  sed -i "/{% url 'dockerSuite' %}\" class=\"menu-item\"/,/<\/a>/d" "$IDX"
fi
for TARGET in "url 'ListWPSites' %}\" class=\"menu-item\"" "url 'listWebsites' %}\" class=\"menu-item\""; do
  if grep -q "$TARGET" "$IDX"; then sed -i "/$TARGET/i $LINK" "$IDX"; break; fi
done
if grep -q "DM-BEGIN" "$IDX"; then echo "Sidebar link added."; else echo "WARNING: could not add the link; open /dockerSuite/ directly."; exit 1; fi
