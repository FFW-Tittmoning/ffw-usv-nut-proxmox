#!/bin/bash
# Ziel: /usr/local/bin/nut-kuma-notify.sh auf dem Raspberry Pi
#
# Ereignisgetriebener Sofort-Push an Uptime Kuma bei Netzausfall/
# kritischem Akkustand. Wird von upsmon ueber NOTIFYCMD aufgerufen (siehe
# pi/upsmon.conf und monitoring/SETUP.md fuer die sicherheitsrelevanten
# Rahmenbedingungen: SHUTDOWNCMD=/bin/true, Rolle secondary - diese
# upsmon-Instanz trifft KEINE Shutdown-Entscheidung, sie liefert nur
# Benachrichtigungs-Events).
#
# $NOTIFYTYPE wird von upsmon als Umgebungsvariable gesetzt (siehe
# upsmon.conf(5)).

KUMA_URL="http://<kuma-ip>:3001/api/push/<token>"   # identisch zur Heartbeat-URL

case "$NOTIFYTYPE" in
  ONBATT)
    curl -s "${KUMA_URL}?status=down&msg=Netzausfall%20-%20USV%20auf%20Batterie&ping=" >/dev/null
    ;;
  LOWBATT)
    curl -s "${KUMA_URL}?status=down&msg=KRITISCH%3A%20Akkustand%20niedrig%2C%20Shutdown%20bevorstehend&ping=" >/dev/null
    ;;
  ONLINE)
    curl -s "${KUMA_URL}?status=up&msg=Netzversorgung%20wiederhergestellt&ping=" >/dev/null
    ;;
esac
