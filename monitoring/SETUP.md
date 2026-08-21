# Alarmierung bei Netzausfall + Uptime Kuma Integration

Generische Anleitung, unabhaengig vom konkreten Standort. Zwei Ebenen, die
sich ergaenzen:

1. **Sofort-Alarm** (Sekunden-Reaktionszeit): NUT ruft bei Statuswechsel
   direkt einen Push-Dienst auf - funktioniert unabhaengig von allem
   anderen, auch ohne Uptime Kuma.
2. **Uptime Kuma** als zusaetzliche VM/LXC auf Proxmox: Dashboard +
   Verlauf + Verteilung auf mehrere Kanaele (Push, E-Mail, Telegram, ...)
   fuer die generelle Umgebungsueberwachung, inkl. der USV als einem von
   mehreren ueberwachten Punkten.

**Hinweis:** Nicht an einem echten System gegengetestet (kein Zugriff auf
die Proxmox-Umgebung). Die NUT-Doku-Fakten (`NOTIFYCMD`/`NOTIFYFLAG`-Syntax)
sind gegen `upsmon.conf(5)` verifiziert, restliche Schritte (Kuma-UI,
Community-Scripts) bitte beim Umsetzen selbst pruefen.

## Ebene 1: Sofort-Alarm per Push (NUT -> ntfy.sh)

Laeuft auf dem System, das `upsmon` im `secondary`-Modus faehrt (Proxmox,
siehe `proxmox/SETUP.md`). Nutzt NUTs eingebauten Notify-Mechanismus.

### Notify-Script anlegen

```bash
# /usr/local/bin/nut-notify.sh
#!/bin/bash
MSG="$*"
TOPIC="https://ntfy.sh/<dein-eindeutiges-topic>"   # selbst waehlen, z.B. ffw-tittmoning-usv-xyz123

case "$NOTIFYTYPE" in
  ONBATT)
    curl -s -H "Title: USV-Alarm: Netzausfall" -H "Priority: urgent" -H "Tags: warning" \
      -d "Netzausfall am Standort - USV laeuft auf Batterie. $MSG" "$TOPIC"
    ;;
  ONLINE)
    curl -s -H "Title: USV: Netz wieder da" -H "Tags: white_check_mark" \
      -d "Netzversorgung wiederhergestellt. $MSG" "$TOPIC"
    ;;
  LOWBATT)
    curl -s -H "Title: USV-Alarm: Akku kritisch" -H "Priority: urgent" -H "Tags: rotating_light" \
      -d "Akku unter Schwelle, Shutdown steht bevor. $MSG" "$TOPIC"
    ;;
esac
```

```bash
chmod +x /usr/local/bin/nut-notify.sh
```

### In upsmon.conf einbinden

```
NOTIFYCMD /usr/local/bin/nut-notify.sh
NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
```

Wichtig laut Doku (`upsmon.conf(5)`): `NOTIFYCMD` wird nur fuer Events
aufgerufen, die `EXEC` in ihrem `NOTIFYFLAG` gesetzt haben - ohne das
passiert nichts. `$NOTIFYTYPE` (Umgebungsvariable) und die Nachricht als
Parameter (`$*`) stehen im Script wie oben gezeigt zur Verfuegung.

### Handy einrichten

App **ntfy** installieren (iOS/Android), das gewaehlte Topic abonnieren -
fertig, keine Account-Registrierung noetig. Alternativ selbst gehostete
ntfy-Instanz oder Pushover/Gotify verwenden (gleiches Prinzip, andere URL).

### E-Mail-Fallback (optional, zusaetzlich im selben Script)

```bash
echo "$MSG" | mailx -s "USV-Alarm: $NOTIFYTYPE" empfaenger@example.com
```

Setzt ein konfiguriertes MTA voraus (z.B. `msmtp`).

## Ebene 2: Uptime Kuma auf Proxmox

### Bereitstellung

**Option A - manuell (offizielles Docker-Image, volle Kontrolle):**

1. Kleinen Debian/Ubuntu-LXC anlegen (1 vCPU, 512MB-1GB RAM, 8GB Disk
   reichen locker).
2. Docker im Container installieren.
3. Uptime Kuma starten:
   ```bash
   docker run -d --restart=unless-stopped -p 3001:3001 \
     -v uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:1
   ```
4. Web-UI unter `http://<kuma-ip>:3001` aufrufen, Admin-Account anlegen.

**Option B - Proxmox Community-Scripts (schneller, fertiges LXC-Skript):**

Die Proxmox VE Community-Scripts (`community-scripts.github.io`) bieten
einen fertigen Uptime-Kuma-LXC-Installer per Einzeiler. **Vor Ausfuehrung
das Skript selbst anschauen** (es laeuft mit Root-Rechten auf dem
Proxmox-Host) - wie bei jedem Skript aus dem Internet, das man mit
erhoehten Rechten ausfuehrt.

### Notification-Kanaele in Kuma einrichten

`Settings -> Notifications -> Add Notification`:
- Push (ntfy/Pushover/Gotify - gleiches Topic wie oben nutzbar oder
  separates)
- Email (SMTP) als Fallback

### Push-Monitor fuer die USV anlegen

`Add New Monitor -> Monitor Type: Push`. Kuma generiert eine eindeutige
Push-URL nach dem Muster:
```
http://<kuma-ip>:3001/api/push/<token>?status=up&msg=OK&ping=
```

**Wichtig:** Ein Push-Monitor in Kuma erwartet ein **periodisches**
Signal (Heartbeat) - nicht nur bei Aenderungen. Bleibt das Netz wochenlang
stabil und es kommt nie ein Push, wertet Kuma das nach Ablauf des
konfigurierten Intervalls als "down" (Fehlalarm). Deshalb hier bewusst
**nicht** den ereignisgetriebenen `NOTIFYCMD`-Hook direkt wiederverwenden,
sondern ein periodisches Skript per Cron, das den aktuellen Stand aktiv
abfragt und meldet:

```bash
# /usr/local/bin/kuma-ups-heartbeat.sh
#!/bin/bash
UPS="apc2200@<PI_IP>"
KUMA_URL="http://<kuma-ip>:3001/api/push/<token>"

if upsc "$UPS" ups.status 2>/dev/null | grep -q "OB"; then
  curl -s "${KUMA_URL}?status=down&msg=USV+auf+Batterie&ping=" >/dev/null
else
  curl -s "${KUMA_URL}?status=up&msg=OK&ping=" >/dev/null
fi
```

```bash
chmod +x /usr/local/bin/kuma-ups-heartbeat.sh
crontab -e
# Zeile ergaenzen (alle 2 Minuten):
*/2 * * * * /usr/local/bin/kuma-ups-heartbeat.sh
```

Heartbeat-Intervall in Kuma passend zum Cron-Takt einstellen (z.B. auf
3-5 Minuten, etwas grosszuegiger als die Cron-Frequenz, um keine
Fehlalarme durch Timing-Jitter zu bekommen).

### Warum beide Ebenen sinnvoll sind

- **Ebene 1** (direkter `NOTIFYCMD`-Hook): reagiert in Sekunden, unabhaengig
  davon, ob Kuma laeuft/erreichbar ist.
- **Ebene 2** (Kuma-Heartbeat): etwas traegere Reaktionszeit (durch den
  Cron-Takt bestimmt, z.B. bis zu 2-5 Minuten), dafuer Dashboard,
  Verlaufs-Historie und ein zweiter, unabhaengiger Alarmweg als
  Rueckfallebene - falls z.B. der ntfy-Dienst selbst mal nicht erreichbar
  ist, meldet Kuma trotzdem.

## Test

1. Ebene 1 isoliert testen: `NOTIFYTYPE=ONBATT /usr/local/bin/nut-notify.sh "Testnachricht"`
   manuell ausfuehren - kommt die Push-Nachricht an?
2. Heartbeat-Skript isoliert testen: `/usr/local/bin/kuma-ups-heartbeat.sh`
   manuell ausfuehren, Kuma-Dashboard pruefen (sollte "up" zeigen).
3. Erst danach im Rahmen des ohnehin geplanten kontrollierten Shutdown-Tests
   (`proxmox/SETUP.md`, Abschnitt "Kontrollierter Test") mitpruefen, ob
   beide Alarme bei simuliertem `upsmon -c fsd` tatsaechlich ausloesen.
