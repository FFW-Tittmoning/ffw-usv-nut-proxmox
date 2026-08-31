# Alarmierung bei Netzausfall + kritischem Akkustand ueber Uptime Kuma

Generische Anleitung, unabhaengig vom konkreten Standort. **Uptime Kuma
ist die alleinige Benachrichtigungsquelle** (Push/E-Mail/Telegram/... -
konfiguriert in Kuma selbst). Damit Kuma sowohl sofort reagiert als auch
keine Fehlalarme durch Timeouts produziert, laufen zwei sich ergaenzende
Signalwege in **denselben Push-Monitor**:

1. **Periodischer Heartbeat per Cron** (bereits eingerichtet und laeuft) -
   haelt den Kuma-Monitor "am Leben" und liefert den Normalzustand.
2. **Ereignisgetriebener Sofort-Push per NUT `NOTIFYCMD`** (neu, dieser
   Abschnitt) - meldet Netzausfall und kritischen Akkustand **sofort**,
   ohne auf den naechsten Cron-Takt zu warten.

**Hinweis:** Nicht an einem echten System gegengetestet (kein Zugriff auf
die Proxmox-Umgebung). Die NUT-Doku-Fakten (`NOTIFYCMD`/`NOTIFYFLAG`-Syntax)
sind gegen `upsmon.conf(5)` verifiziert, Kuma-UI-Details bitte beim
Umsetzen selbst pruefen.

## Warum beide Signalwege noetig sind

Ein Kuma-**Push**-Monitor erwartet ein periodisches Signal - bleibt es
laenger als das konfigurierte Intervall aus, wertet Kuma das als "down"
(Timeout), unabhaengig vom tatsaechlichen USV-Status. Ein rein
ereignisgetriebener Push (nur bei Aenderungen) wuerde deshalb nach Wochen
ohne Netzausfall selbst einen Fehlalarm ausloesen ("kein Heartbeat mehr
angekommen"). Deshalb bleibt der Cron-Heartbeat als Basis bestehen - der
`NOTIFYCMD`-Hook ergaenzt ihn nur um sofortige Reaktion GENAU in dem
Moment, in dem sich der Status aendert, statt bis zu 2 Minuten (Cron-Takt)
darauf zu warten.

## Voraussetzung (bereits erledigt)

- Kuma-Push-Monitor fuer die USV angelegt, Push-URL bekannt:
  ```
  http://<kuma-ip>:3001/api/push/<token>
  ```
- Periodisches Heartbeat-Skript per Cron laeuft bereits (alle 2 Minuten,
  meldet aktuellen Normalzustand).
- Notification-Kanaele (Push/E-Mail/...) in Kuma selbst eingerichtet
  (`Settings -> Notifications`) und dem Monitor zugewiesen.

## Sofort-Push bei Netzausfall + kritischem Akkustand einrichten

### Notify-Script anlegen

```bash
# /usr/local/bin/nut-kuma-notify.sh
#!/bin/bash
KUMA_URL="http://<kuma-ip>:3001/api/push/<token>"   # identisch zur Cron-URL

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
```

```bash
chmod +x /usr/local/bin/nut-kuma-notify.sh
```

`LOWBATT` und `ONBATT` senden beide `status=down` (Kuma kennt nur
up/down), unterscheiden sich aber in der `msg` - dadurch zeigt die
Kuma-Benachrichtigung trotzdem den richtigen Grund an ("Netzausfall" vs.
"kritischer Akkustand").

### In upsmon.conf einbinden (auf Proxmox)

```
NOTIFYCMD /usr/local/bin/nut-kuma-notify.sh
NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE SYSLOG+WALL+EXEC
```

Wichtig laut Doku (`upsmon.conf(5)`): `NOTIFYCMD` wird nur fuer Events
aufgerufen, die `EXEC` in ihrem `NOTIFYFLAG` gesetzt haben. Die
Umgebungsvariable `$NOTIFYTYPE` steht im Script wie oben gezeigt zur
Verfuegung.

`upsmon` neu laden/starten, damit die Config-Aenderung greift:
```bash
systemctl restart nut-monitor   # ggf. anderen Dienstnamen einsetzen, siehe proxmox/SETUP.md
```

## Test

1. Script isoliert testen (ohne echten Ereignisauslauf):
   ```bash
   NOTIFYTYPE=ONBATT /usr/local/bin/nut-kuma-notify.sh
   ```
   Kuma-Dashboard pruefen: Monitor sollte sofort auf "down" springen,
   konfigurierte Benachrichtigung sollte ausgeloest werden.
2. Danach mit `NOTIFYTYPE=LOWBATT` und `NOTIFYTYPE=ONLINE` wiederholen.
3. Erst danach im Rahmen des ohnehin geplanten kontrollierten Shutdown-Tests
   (`proxmox/SETUP.md`, Abschnitt "Kontrollierter Test") mitpruefen, ob der
   Alarm bei echtem simuliertem `upsmon -c fsd` ebenfalls ausloest.
