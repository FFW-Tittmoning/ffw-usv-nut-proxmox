# APC Smart 2200 -> Proxmox Shutdown via NUT (Raspberry Pi 1 B+)

Status (2026-08-14): Teil A ist auf dem echten Pi (`USVPI`, PI_IP)
durchgefuehrt - System aktualisiert, `nut`/`nut-client` installiert, Configs
liegen unter `/etc/nut/`. `nut-server`/`nut-monitor` sind bewusst **masked**
(nicht nur disabled - `nut.target` zieht sie sonst trotzdem rein, siehe
CLAUDE.md), `ups.conf` bleibt komplett auskommentiert. journald/Swap/
Watchdog sind bereits SD-Karten-schonend konfiguriert (Details CLAUDE.md).
Hardware (USV-Anschluss, Kabel) ist noch NICHT verifiziert - siehe "Offene
Punkte" unten. Details zum genauen Deployment-Stand: [CLAUDE.md](CLAUDE.md).

## Offene Punkte (vor Ort, nicht raten)

Modell (APC Smart-UPS SUA2200I) und Port-Layout sind per Foto bestaetigt,
siehe [CLAUDE.md](CLAUDE.md). Entscheidung 2026-08-14: **USB-Weg** ueber
den `USB`(RJ50)-Port der USV mit einem USB-A-zu-RJ50-Kabel (z.B. Delock
67016) und Treiber `usbhid-ups` - der Serial-Weg (`apcsmart`) wurde wegen
einer gefaehrlichen, nicht-standardkonformen Pinbelegung verworfen.

Noch offen:

1. Delock-67016-Kabel muss noch bestellt/geliefert werden.
2. Nach Anschluss: `lsusb` pruefen, dann isolierter `usbhid-ups`-Test
   (siehe Schritt 5 unten) - Kompatibilitaet ist laut NUT-Doku sehr
   wahrscheinlich, aber am konkreten Geraet noch nicht verifiziert.

## Teil A - jetzt schon sicher machbar (hardwareunabhaengig)

### 1. Raspberry Pi OS Lite flashen

Mit Raspberry Pi Imager (Advanced Options / Zahnrad vor dem Schreiben):
- Hostname setzen (z.B. `nut-ups.local`)
- SSH aktivieren, eigenen Public Key oder Passwort hinterlegen
- WLAN NICHT noetig, wenn der Pi per Kabel im selben Segment wie Proxmox
  haengt

### 2. Erstes Update (per SSH auf dem Pi)

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

### 3. NUT installieren (auf dem Pi)

```bash
sudo apt install -y nut nut-client
```

Das installiert den Server-Teil (`nut` -> upsd, upsdrvctl) und den
Client-Teil (`nut-client` -> upsmon). Nach der Installation startet Debian
normalerweise `nut-monitor`/`upsmon` automatisch mit einer leeren Default-
Config - das ist unschaedlich, solange `ups.conf` leer/auskommentiert ist.

### 4. Entwurfs-Configs auf den Pi kopieren

Von diesem Rechner aus (PI_HOST durch echten Hostnamen/IP ersetzen):

```bash
scp pi/nut.conf pi/ups.conf pi/upsd.users pi/upsd.conf pi/upsmon.conf \
    pi@PI_HOST:/tmp/
```

Auf dem Pi dann an den richtigen Ort verschieben (Owner/Rechte beachten):

```bash
sudo mv /tmp/nut.conf /tmp/ups.conf /tmp/upsd.users /tmp/upsd.conf /tmp/upsmon.conf /etc/nut/
sudo chown root:nut /etc/nut/upsd.users
sudo chmod 640 /etc/nut/upsd.users
```

In `/etc/nut/upsd.conf` noch `PI_IP` durch die feste IP des Pi ersetzen,
und in `upsd.users` / `upsmon.conf` `CHANGE_ME` durch ein echtes generiertes
Passwort (in beiden Dateien identisch):

```bash
openssl rand -base64 24
```

### 5. WICHTIG - noch NICHT aktivieren

`ups.conf` bleibt auskommentiert, solange der Treiber nicht isoliert
getestet wurde:

```bash
lsusb   # sollte nach Anschluss ein APC-Geraet zeigen
# danach [apc2200]-Block in /etc/nut/ups.conf einkommentieren (driver =
# usbhid-ups, port = auto), dann:
sudo /lib/nut/usbhid-ups -DDDD -a apc2200
# oder:
sudo upsdrvctl start
upsc apc2200@localhost
```

Erst wenn hier reale Werte (Ladezustand, Status, Spannung) ankommen,
Dienste (neu) starten:

```bash
sudo systemctl unmask nut-server nut-monitor
sudo systemctl enable --now nut-server
sudo systemctl enable --now nut-monitor
```

### 6. Firewall (erledigt, Stand 2026-08-14)

`ufw` ist installiert und aktiv. SSH zuerst erlaubt (Absicherung gegen
Aussperren), NUT-Port bewusst offen fuer alle (nicht auf die Proxmox-IP
beschraenkt - Entscheidung des Nutzers, NUT hat eigene
Benutzer/Passwort-Authentifizierung auf Anwendungsebene). Alles andere
eingehend geblockt:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment "SSH"
sudo ufw allow 3493/tcp comment "NUT upsd"
sudo ufw enable
```

Nach dem Enable **immer mit einer neuen SSH-Verbindung verifizieren**
(nicht nur die bestehende Session pruefen), dass der Zugriff noch
funktioniert. Status pruefen: `sudo ufw status verbose`.

## Teil B - Proxmox-Seite (Client)

Erst konfigurieren, nachdem `upsc apc2200@PI_IP` vom Pi aus lokal
funktioniert (Schritt 2 des Gesamtplans) und Port 3493 erreichbar ist.

```bash
apt install -y nut-client
```

Dann `proxmox/nut.conf` und `proxmox/upsmon.conf` nach `/etc/nut/`
kopieren, `PI_IP` und `CHANGE_ME` anpassen, und mit

```bash
upsc apc2200@PI_IP
```

von Proxmox aus verifizieren, bevor `nut-client` (neu)gestartet wird.

## Danach (siehe Gesamtplan, hier nicht enthalten)

- End-to-End-Reachability-Test von Proxmox -> Pi:3493 (Pi-seitige
  `ufw`-Regel ist bereits gesetzt, siehe Schritt 6 oben)
- Kontrollierter Shutdown-Test (`upsmon -c fsd` auf dem Pi) in einem
  unkritischen Zeitfenster, Proxmox-Log-Verifikation
- Overlay-/Read-only-Root auf dem Pi erst NACH bestaetigter Grundfunktion
