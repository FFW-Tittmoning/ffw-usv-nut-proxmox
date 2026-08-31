#!/bin/bash
# Ziel: /usr/local/bin/kuma-ups-heartbeat.sh auf dem Raspberry Pi
#
# Periodischer Heartbeat fuer den Uptime-Kuma-Push-Monitor der USV.
# Bewusst unter einem unprivilegierten User per Cron laufen lassen (nicht
# root) - braucht nur upsc (Leseabfrage) und curl (ausgehender Request),
# beides ohne erhoehte Rechte moeglich. Details: monitoring/SETUP.md.
#
# Crontab-Eintrag (als unprivilegierter User, NICHT root):
#   */2 * * * * /usr/local/bin/kuma-ups-heartbeat.sh

UPS="apc2200@localhost"
KUMA_URL="http://<kuma-ip>:3001/api/push/<token>"

if upsc "$UPS" ups.status 2>/dev/null | grep -q "OB"; then
  curl -s "${KUMA_URL}?status=down&msg=USV+auf+Batterie&ping=" >/dev/null
else
  curl -s "${KUMA_URL}?status=up&msg=OK&ping=" >/dev/null
fi
