# APC Smart-UPS SUA2200I -> Proxmox Shutdown via NUT (Raspberry Pi 1 B+)

Ein dedizierter Raspberry Pi liest die USV per USB aus und agiert als
NUT-Server (Network UPS Tools); ein Proxmox-Host ist NUT-Client im selben
Netzwerksegment und faehrt sich bei Stromausfall rechtzeitig sauber
herunter.

## Aktueller Stand

- **Hardware-Anschluss:** USB-Weg ueber den `USB`(RJ50)-Port der USV mit
  einem USB-A-zu-RJ50-Kabel (z.B. Delock 67016), Treiber `usbhid-ups`. Der
  Serial-Weg (`apcsmart`) wurde verworfen (gefaehrliche, nicht-
  standardkonforme Pinbelegung am Sub-D-Port).
- **Pi-Grundinstallation:** durchgefuehrt - System aktuell, `nut`/
  `nut-client` installiert, Configs liegen unter `/etc/nut/`.
- **`nut-server`:** aktiv, `ups.conf` scharf (`usbhid-ups`-Treiber). Per
  `upsc` verifiziert - liefert echte Werte (Batterie, Spannungen, Status).
- **Shutdown-Schwelle:** `override.battery.charge.low = 30` in `ups.conf`
  gesetzt (Werks-Default der USV war 10%, fuer Server-/VM-Workloads zu
  knapp) - rein softwareseitiger Treiber-Override, kein Schreibzugriff
  auf die USV. Begruendung/Kriterien: [proxmox/SETUP.md](proxmox/SETUP.md).
- **`nut-monitor`:** bleibt **dauerhaft masked** - bewusste
  Architektur-Entscheidung: Der Pi soll niemals selbst herunterfahren
  (OverlayFS schuetzt die SD-Karte auch bei hartem Stromausfall) und
  dadurch garantiert bis zuletzt Daten liefern. Die Shutdown-Entscheidung
  liegt komplett bei Proxmox (dessen `upsmon` im `secondary`-Modus wertet
  die Werte selbst aus).
- **OverlayFS + Boot-Partition read-only:** Mechanismus aktiv, System
  steht aktuell bewusst auf `rw` (fuer laufende Config-Arbeiten, noch
  nicht wieder auf `ro` gesetzt). Jede Config-Aenderung braucht
  `sudo /root/writable.sh rw` vorher und `sudo /root/writable.sh ro`
  danach, sobald abgeschlossen.
- **Wartungs-Scripts auf dem Pi:** `/root/update.sh` (apt-Updates inkl.
  Overlay-Handling) und `/root/writable.sh` (rw/ro-Umschaltung fuer
  manuelle Config-Arbeiten) - beide end-to-end getestet.
- **SD-Karten-Schonung:** journald volatile (RAM-only Logs), Swap
  deaktiviert, Hardware-Watchdog aktiv.
- **Firewall (`ufw`):** aktiv - SSH erlaubt, NUT-Port (3493/tcp) offen fuer
  alle (NUT hat eigene Authentifizierung auf Anwendungsebene), sonst
  eingehend alles geblockt.
- **Proxmox-Seite:** noch nicht konfiguriert - Anleitung dafuer liegt
  bereit unter [proxmox/SETUP.md](proxmox/SETUP.md).
- **Netzwerk:** Pi ist am finalen Standort (direkt bei der USV) im
  Ziel-Netzwerk. IP ist sowohl per DHCP-Reservierung (Router) als auch
  zusaetzlich statisch auf dem Pi (NetworkManager) fixiert - persistiert
  ueber Reboots.
- **USB-Verbindung zur USV:** Kabel angeschlossen, `lsusb` erkennt die
  USV bereits als USB-Geraet (APC, Vendor-ID `051d`).

## Offene Punkte / Naechste Schritte

1. **Ungeklaerte Auffaelligkeit:** `ups.load`/`output.current` zeigen
   durchgehend 0, obwohl laut Betreiber mehrere Rechner + der
   Proxmox-Server sicher an dieser USV haengen (bestaetigt). Die
   HID-Beschreibung des Geraets hat nur einen einzigen, ungeteilten
   Ausgangskreis (keine separaten Outlet-Gruppen wie bei manchen
   Rack-Modellen) - ein "anderer, nicht ueberwachter Ausgangskreis" scheidet
   damit als Erklaerung aus. Verbleibend: entweder haengen die Geraete
   physisch nicht wirklich an dieser USV (z.B. vorgeschaltete Steckerleiste
   pruefen), oder der Sensor der USV meldet fehlerhaft - vor Ort mit
   Verkabelung/ggf. Ersatzmessung zu klaeren.
2. Proxmox-Client konfigurieren: [proxmox/SETUP.md](proxmox/SETUP.md).
3. Windows-Clients konfigurieren (falls gewuenscht):
   [windows/SETUP.md](windows/SETUP.md).
4. End-to-End-Reachability-Test von Proxmox -> Pi:3493 (Pi-seitige
   `ufw`-Regel steht bereits).
5. Kontrollierter Shutdown-Test **auf der Proxmox-Seite** (dort laeuft
   `upsmon` im `secondary`-Modus und trifft die Shutdown-Entscheidung -
   der Pi selbst hat bewusst keine eigene Shutdown-Logik) in einem
   unkritischen Zeitfenster, mit Log-Verifikation - nicht ungetestet am
   Produktivsystem scharf schalten.
6. Alarmierung bei Netzausfall/kritischem Akkustand ueber Uptime Kuma
   einrichten (periodischer Heartbeat + ereignisgetriebener Sofort-Push
   in denselben Monitor): [monitoring/SETUP.md](monitoring/SETUP.md).

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
`nut-server` (neu) starten - **`nut-monitor` bleibt bewusst dauerhaft
masked**, siehe "Aktueller Stand" oben (der Pi soll nie selbst
herunterfahren, das erledigt Proxmox):

```bash
sudo systemctl unmask nut-server
sudo systemctl enable --now nut-server
```

**Wichtig nach einem Standortwechsel:** `upsd.conf`s `LISTEN`-Zeile muss
auf die tatsaechliche, aktuelle IP des Pi zeigen - eine dort noch
eingetragene alte IP fuehrt zu einer Crash-Loop von `nut-server`
("no listening interface available").

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
