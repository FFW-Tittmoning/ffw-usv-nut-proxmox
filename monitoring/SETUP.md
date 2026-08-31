# Alarmierung bei Netzausfall + kritischem Akkustand ueber Uptime Kuma

Generische Anleitung, unabhaengig vom konkreten Standort. **Uptime Kuma
ist die alleinige Benachrichtigungsquelle** (Push/E-Mail/Telegram/... -
konfiguriert in Kuma selbst).

**Bewusste Architektur-Entscheidung: Beide Signalwege laufen auf dem Pi
selbst, nicht auf Proxmox.** Der Pi ist das einzige Geraet, das direkt an
der USV haengt - eine Alarmierung, die dort startet, hat keine Abhaengigkeit
von Proxmox (Erreichbarkeit, korrekte NUT-Client-Konfiguration, Boot-Status
etc.). Selbst wenn Proxmox selbst das Problem waere (haengt, ist falsch
konfiguriert, faehrt gerade herunter), meldet der Pi den Netzausfall
trotzdem zuverlaessig.

Zwei sich ergaenzende Signalwege in **denselben Kuma-Push-Monitor**:

1. **Periodischer Heartbeat per Cron** - haelt den Kuma-Monitor "am Leben"
   und liefert den Normalzustand.
2. **Ereignisgetriebener Sofort-Push per NUT `NOTIFYCMD`** - meldet
   Netzausfall und kritischen Akkustand sofort, ohne auf den naechsten
   Cron-Takt zu warten.

**Hinweis:** Diese Anleitung beschreibt den an diesem Standort
eingesetzten Aufbau. Die NUT-Doku-Fakten (`NOTIFYCMD`/`NOTIFYFLAG`-Syntax)
sind gegen `upsmon.conf(5)` verifiziert.

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

## Wichtige Sicherheitsklarstellung: zweite, unabhaengige `upsmon`-Instanz

Fuer den `NOTIFYCMD`-Hook muss auf dem Pi `nut-monitor` (`upsmon`) laufen -
das ist eine **separate, rein lokale** `upsmon`-Instanz, unabhaengig von
Proxmox' eigenem `upsmon` (das weiterhin allein die echte
Shutdown-Entscheidung trifft, siehe `proxmox/SETUP.md`). Damit diese
lokale Instanz strukturell **niemals** einen Shutdown ausloesen oder die
USV beeinflussen kann, sind zwei Absicherungen essenziell:

1. **`SHUTDOWNCMD "/bin/true"`** statt eines echten Shutdown-Befehls -
   `upsmon` kann intern seinen vollen Zustandsautomat durchlaufen (inkl.
   FSD-Deklaration), ohne dass am Ende real etwas passiert.
2. **Rolle `secondary`**, nicht `primary` - laut `upsmon.conf(5)` wird
   `POWERDOWNFLAG` (der einzige Mechanismus, der die USV abschalten
   koennte) ausschliesslich von einem `upsmon` im `primary`-Modus gesetzt.
   Mit `secondary` ist dieser Pfad strukturell unerreichbar, nicht nur
   unkonfiguriert (zusaetzlich ist `POWERDOWNFLAG` ohnehin nirgends
   gesetzt - doppelte Absicherung).

Diese lokale Instanz aendert nichts an der uebergeordneten
Architektur-Entscheidung "Pi faehrt niemals selbst herunter" - sie liefert
lediglich Benachrichtigungs-Events, keine Shutdown-Aktionen.

## Voraussetzungen

- Kuma-Push-Monitor fuer die USV angelegt, Push-URL bekannt:
  ```
  http://<kuma-ip>:3001/api/push/<token>
  ```
- Notification-Kanaele (Push/E-Mail/...) in Kuma selbst eingerichtet
  (`Settings -> Notifications`) und dem Monitor zugewiesen.

## 1. Periodischer Heartbeat (auf dem Pi)

### Script

Liegt auch als fertige Datei im Repo: [pi/kuma-ups-heartbeat.sh](../pi/kuma-ups-heartbeat.sh)
(`<kuma-ip>`/`<token>` vor dem Deployment anpassen).

```bash
# /usr/local/bin/kuma-ups-heartbeat.sh
#!/bin/bash
UPS="apc2200@localhost"
KUMA_URL="http://<kuma-ip>:3001/api/push/<token>"

if upsc "$UPS" ups.status 2>/dev/null | grep -q "OB"; then
  curl -s "${KUMA_URL}?status=down&msg=USV+auf+Batterie&ping=" >/dev/null
else
  curl -s "${KUMA_URL}?status=up&msg=OK&ping=" >/dev/null
fi
```

```bash
sudo chmod +x /usr/local/bin/kuma-ups-heartbeat.sh
```

### Cron-Job

**Bewusst unter einem unprivilegierten User (nicht root)** - das Script
braucht nur `upsc` (reine Leseabfrage) und `curl` (ausgehender
HTTP-Request), beides ohne erhoehte Rechte moeglich (Least Privilege). An
diesem Standort laeuft es unter dem ohnehin durchgaengig genutzten
Admin-Account des Pi:

```bash
crontab -e   # als der gewuenschte unprivilegierte User, NICHT root
# Zeile ergaenzen (alle 2 Minuten):
*/2 * * * * /usr/local/bin/kuma-ups-heartbeat.sh
```

Heartbeat-Intervall in Kuma passend zum Cron-Takt einstellen (z.B. auf
3-5 Minuten, etwas grosszuegiger als die Cron-Frequenz, um keine
Fehlalarme durch Timing-Jitter zu bekommen).

Verifikation: `crontab -l` (als der jeweilige User, nicht root!) und
`journalctl -u cron | grep kuma-ups-heartbeat` zeigen die periodischen
Laeufe.

## 2. Sofort-Push bei Netzausfall + kritischem Akkustand (auf dem Pi)

### Voraussetzung: `nut-monitor` auf dem Pi aktivieren

Standardmaessig ist `nut-monitor` auf einem reinen NUT-Server-Pi masked
(siehe Haupt-Setup). Fuer diesen Notify-Zweck muss er unmaskiert und mit
der unten stehenden, abgesicherten Config aktiviert werden:

```bash
sudo systemctl unmask nut-monitor
```

`/etc/nut/upsmon.conf` auf dem Pi:

```
MONITOR apc2200@localhost 1 monuser <passwort-aus-upsd.users> secondary

SHUTDOWNCMD "/bin/true"

NOTIFYCMD /usr/local/bin/nut-kuma-notify.sh
NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE SYSLOG+WALL+EXEC
```

### Notify-Script

Liegt auch als fertige Datei im Repo: [pi/nut-kuma-notify.sh](../pi/nut-kuma-notify.sh)
(`<kuma-ip>`/`<token>` vor dem Deployment anpassen, identisch zur
Heartbeat-URL).

```bash
# /usr/local/bin/nut-kuma-notify.sh
#!/bin/bash
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
```

```bash
sudo chmod +x /usr/local/bin/nut-kuma-notify.sh
```

`LOWBATT` und `ONBATT` senden beide `status=down` (Kuma kennt nur
up/down), unterscheiden sich aber in der `msg` - dadurch zeigt die
Kuma-Benachrichtigung trotzdem den richtigen Grund an.

Wichtig laut Doku (`upsmon.conf(5)`): `NOTIFYCMD` wird nur fuer Events
aufgerufen, die `EXEC` in ihrem `NOTIFYFLAG` gesetzt haben. Die
Umgebungsvariable `$NOTIFYTYPE` steht im Script wie oben gezeigt zur
Verfuegung.

### Aktivieren

```bash
sudo systemctl enable --now nut-monitor
```

**Hinweis zu OverlayFS/Boot-RO:** Alle Aenderungen an `/etc/nut/upsmon.conf`
sowie das Anlegen der Scripts unter `/usr/local/bin/` erfordern vorher
`sudo /root/writable.sh rw` (danach `sudo /root/writable.sh ro`), da das
Root-Dateisystem des Pi normalerweise read-only ist (siehe Haupt-Setup).

## Bekannte Einschraenkung: `LOWBATT` loest keine eigene Benachrichtigung aus

Der Wechsel von `ONBATT` auf `LOWBATT` erzeugt **keine zusaetzliche**
Kuma-Benachrichtigung, obwohl das Notify-Script bei beiden Events einen
Push absetzt.

**Ursache:** Kuma markiert einen Heartbeat intern nur dann als
benachrichtigungswuerdig ("important"), wenn sich der Monitor-**Status**
(up/down) aendert. Der Push-API-Endpunkt (`/api/push/<token>`) kennt nur
die Parameter `status`, `msg` und `ping` - keinen Weg, eine
Benachrichtigung ohne echten Statuswechsel zu erzwingen. Da `ONBATT` den
Monitor bereits auf `down` setzt, ist der nachfolgende `LOWBATT`-Push
(ebenfalls `status=down`) aus Kumas Sicht keine Aenderung und loest
nichts aus. Die Unterscheidung der `msg`-Texte zwischen `ONBATT` und
`LOWBATT` im Script dient dadurch nur der Dokumentation/dem Log, nicht
einer eigenstaendigen Alarmierung.

**Bewusst so akzeptiert**, u.a. verworfene Alternativen: ein zweiter
Kuma-Monitor nur fuer `LOWBATT` (zu unuebersichtlich), ein direkter
Zweitkanal ausserhalb von Kuma nur fuer diesen Fall, Kumas "Resend
Notification if Down X times"-Einstellung (zeitbasiert, nicht
event-spezifisch), sowie ein Fake-Transition-Trick (`down`→`up`→`down`,
der zwischendurch eine irrefuehrende "Netz wieder da"-Meldung erzeugen
wuerde).

**Praktische Konsequenz fuer den Betrieb:** Die erste Benachrichtigung
(`ONBATT`, "Netzausfall") kommt zuverlaessig sofort. Eine gesonderte
Eskalation bei Erreichen des kritischen Akkustands (`LOWBATT`) gibt es
**nicht** - wer das benoetigt, muss eine der oben verworfenen Optionen
doch noch umsetzen.

## Test

1. Notify-Script isoliert testen (Umgebungsvariable in derselben Zeile
   setzen, sonst wird sie nicht an den Kindprozess weitergegeben):
   ```bash
   NOTIFYTYPE=ONBATT /usr/local/bin/nut-kuma-notify.sh
   ```
   Kuma-Dashboard pruefen: Monitor sollte sofort auf "down" springen,
   konfigurierte Benachrichtigung sollte ausgeloest werden. Danach mit
   `LOWBATT` und `ONLINE` wiederholen.
2. Heartbeat-Script isoliert testen (als der jeweilige unprivilegierte
   User, nicht root):
   ```bash
   /usr/local/bin/kuma-ups-heartbeat.sh
   ```
   Kuma-Dashboard sollte "up" zeigen.
3. Erst danach im Rahmen des ohnehin geplanten kontrollierten Shutdown-Tests
   (`proxmox/SETUP.md`, Abschnitt "Kontrollierter Test") mitpruefen, ob der
   Alarm bei echtem simuliertem `upsmon -c fsd` (auf Proxmox ausgefuehrt)
   ebenfalls ausloest - dieser Test betrifft primaer Proxmox' eigenen
   `upsmon`, nicht direkt die hier beschriebene lokale Notify-Instanz auf
   dem Pi.
