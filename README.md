# APC Smart-UPS SUA2200I -> Proxmox Shutdown via NUT (Raspberry Pi 1 B+)

Ein dedizierter Raspberry Pi liest die USV per USB aus und agiert als
NUT-Server (Network UPS Tools); ein Proxmox-Host ist NUT-Client im selben
Netzwerksegment und faehrt sich bei Stromausfall rechtzeitig sauber
herunter. Details/Hintergrund/Entscheidungshistorie: [CLAUDE.md](CLAUDE.md).

## Aktueller Stand

- **Hardware-Anschluss:** USB-Weg ueber den `USB`(RJ50)-Port der USV mit
  einem USB-A-zu-RJ50-Kabel (z.B. Delock 67016), Treiber `usbhid-ups`. Der
  Serial-Weg (`apcsmart`) wurde verworfen (gefaehrliche, nicht-
  standardkonforme Pinbelegung am Sub-D-Port).
- **Pi-Grundinstallation:** durchgefuehrt - System aktuell, `nut`/
  `nut-client` installiert, Configs liegen unter `/etc/nut/`.
- **`nut-server`/`nut-monitor`:** bewusst **masked** (nicht nur disabled -
  `nut.target` zieht sie sonst trotzdem rein), `ups.conf` bleibt komplett
  auskommentiert, bis der USB-Treiber isoliert getestet ist.
- **OverlayFS + Boot-Partition read-only:** aktiv. Jede weitere
  Config-Aenderung auf dem Pi braucht deshalb vorher
  `sudo /root/writable.sh rw` und danach `sudo /root/writable.sh ro`
  (Details/Hintergrund: CLAUDE.md).
- **Wartungs-Scripts auf dem Pi:** `/root/update.sh` (apt-Updates inkl.
  Overlay-Handling) und `/root/writable.sh` (rw/ro-Umschaltung fuer
  manuelle Config-Arbeiten) - beide end-to-end getestet.
- **SD-Karten-Schonung:** journald volatile (RAM-only Logs), Swap
  deaktiviert, Hardware-Watchdog aktiv.
- **Firewall (`ufw`):** aktiv - SSH erlaubt, NUT-Port (3493/tcp) offen fuer
  alle (NUT hat eigene Authentifizierung auf Anwendungsebene), sonst
  eingehend alles geblockt.
- **Proxmox-Seite:** noch nicht konfiguriert.
- **IP des Pi:** wird aktuell per DHCP bezogen, noch nicht als feste
  Reservierung hinterlegt - siehe Offene Punkte.

## Offene Punkte / Naechste Schritte

1. Feste IP fuer den Pi sicherstellen (DHCP-Reservierung im Router
   bevorzugt, sonst statisch auf dem Pi) - muss vor dem finalen
   Proxmox-Rollout stehen, sonst kann die Verbindung nach einem
   Lease-Wechsel brechen.
2. Delock-67016-Kabel (USB-A -> RJ50) beschaffen und an Pi + USV
   anschliessen.
3. `lsusb` pruefen (sollte die USV als USB-Geraet zeigen), danach
   isolierten `usbhid-ups`-Treibertest durchfuehren (siehe Setup-Schritt
   5 unten). Kompatibilitaet ist laut NUT-Doku sehr wahrscheinlich, aber
   am konkreten Geraet noch nicht verifiziert.
4. Nach erfolgreichem Treibertest: `nut-server`/`nut-monitor` unmasken
   und aktivieren.
5. Proxmox-Client konfigurieren (Setup-Teil B unten) und Verbindung
   verifizieren.
6. End-to-End-Reachability-Test von Proxmox -> Pi:3493 (Pi-seitige
   `ufw`-Regel steht bereits).
7. Kontrollierter Shutdown-Test (`upsmon -c fsd` auf dem Pi) in einem
   unkritischen Zeitfenster, Proxmox-Log-Verifikation - nicht ungetestet
   am Produktivsystem scharf schalten.

## Setup-Schritte (Referenz)

### Teil A - Pi-Grundinstallation

#### 1. Raspberry Pi OS Lite flashen

Mit Raspberry Pi Imager (Advanced Options / Zahnrad vor dem Schreiben):
- Hostname setzen
- SSH aktivieren, eigenen Public Key oder Passwort hinterlegen
- WLAN NICHT noetig, wenn der Pi per Kabel im selben Segment wie Proxmox
  haengt

#### 2. Erstes Update (per SSH auf dem Pi)

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

#### 3. NUT installieren (auf dem Pi)

```bash
sudo apt install -y nut nut-client
```

Das installiert den Server-Teil (`nut` -> upsd, upsdrvctl) und den
Client-Teil (`nut-client` -> upsmon).

#### 4. Entwurfs-Configs auf den Pi kopieren

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

**Hinweis:** Solange OverlayFS aktiv ist, muss vor jeder dieser Aenderungen
`sudo /root/writable.sh rw` ausgefuehrt werden (danach `... ro`).

#### 5. Treiber isoliert testen - vor dem Aktivieren

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

#### 6. Firewall

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

### Teil B - Proxmox-Seite (Client)

Erst konfigurieren, nachdem `upsc apc2200@PI_IP` vom Pi aus lokal
funktioniert und Port 3493 erreichbar ist.

```bash
apt install -y nut-client
```

Dann `proxmox/nut.conf` und `proxmox/upsmon.conf` nach `/etc/nut/`
kopieren, `PI_IP` und `CHANGE_ME` anpassen, und mit

```bash
upsc apc2200@PI_IP
```

von Proxmox aus verifizieren, bevor `nut-client` (neu)gestartet wird.
