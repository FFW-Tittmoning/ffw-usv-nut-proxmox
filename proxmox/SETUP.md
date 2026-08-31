# Proxmox als NUT-Client einrichten (Shutdown bei USV-Kritisch)

Generische Anleitung, unabhaengig vom konkreten Standort. Ziel: Proxmox
liest die USV-Werte vom Pi (NUT-Server) und entscheidet **eigenstaendig**,
wann es sich selbst herunterfaehrt. Der Pi selbst trifft **keine**
Shutdown-Entscheidung - er soll auch bei stark entladener Batterie einfach
weiter Daten liefern, bis er hart die Spannung verliert (das schadet dank
OverlayFS/Boot-Partition read-only nicht der SD-Karte).

**Hinweis:** `nut-monitor` laeuft inzwischen auch auf dem Pi selbst - aber
nur fuer eine lokale, von Proxmox unabhaengige Kuma-Benachrichtigung
(`SHUTDOWNCMD` dort auf `/bin/true` neutralisiert, Rolle `secondary`,
siehe [monitoring/SETUP.md](../monitoring/SETUP.md)). Das aendert nichts an
der Architektur hier: Die tatsaechliche Shutdown-Entscheidung liegt
weiterhin ausschliesslich bei Proxmox.

## Funktionsprinzip (kurz)

NUT trifft die Shutdown-Entscheidung nicht anhand eines frei auf Proxmox
konfigurierbaren Prozentwerts, sondern anhand zweier Status-Flags im
`ups.status`, die vom **Treiber auf dem Pi** gesetzt werden:

- **`OB`** (On Battery) - echter Netzausfall, USV laeuft auf Akku
- **`LB`** (Low Battery) - Akku unter der konfigurierten Schwelle

Erst wenn **beide gleichzeitig** anliegen (`OB LB`), fuehrt `upsmon` auf
Proxmox den konfigurierten `SHUTDOWNCMD` aus. Ein reiner Batterietest bei
anliegendem Netz setzt `OB` gar nicht erst - dadurch ist ein versehentliches
Ausloesen durch reine Kalibrierungs-/Testzyklen der USV ausgeschlossen.

Die `LB`-Schwelle wird **auf dem Pi** per Treiber-Override in
`/etc/nut/ups.conf` gesetzt (`override.battery.charge.low`), NICHT auf
Proxmox - das ist eine rein softwareseitige Einstellung im Treiberprozess,
kein Schreibzugriff auf die USV-Hardware selbst. Aktuell auf diesem
Standort auf **30%** gesetzt (Begruendung: Werks-Default der USV ist 10%,
zu knapp fuer einen Host mit mehreren VMs - siehe "Wahl der Schwelle"
unten).

## Voraussetzung (bereits erledigt auf dem Pi)

- `nut-server` auf dem Pi aktiv, `ups.conf` mit `override.battery.charge.low`
  auf den gewuenschten Wert gesetzt und verifiziert (`upsc <ups>@<PI_IP>`
  zeigt den Override-Wert).
- Firewall (`ufw`) auf dem Pi erlaubt Port 3493/tcp.
- Zugangsdaten (`monuser` + Passwort) aus `/etc/nut/upsd.users` auf dem Pi
  bekannt (`sudo cat /etc/nut/upsd.users`).

## Schritt 1: nut-client installieren

```bash
apt install -y nut-client
```

## Schritt 2: Konfigurieren

`nut.conf` und `upsmon.conf` aus diesem Verzeichnis (`proxmox/`) als
Vorlage nutzen, nach `/etc/nut/` kopieren und anpassen:

```
# /etc/nut/nut.conf
MODE=netclient
```

```
# /etc/nut/upsmon.conf
MONITOR <ups-name>@<PI_IP> 1 monuser <passwort> secondary
SHUTDOWNCMD "/sbin/shutdown -h now"
```

- `<ups-name>` = der Name aus `ups.conf` auf dem Pi (z.B. `apc2200`)
- `<PI_IP>` = aktuelle IP des Pi
- `<passwort>` = aus `/etc/nut/upsd.users` auf dem Pi

## Schritt 3: Verbindung verifizieren (VOR dem Dienst-Start)

```bash
upsc <ups-name>@<PI_IP>
```

Sollte den vollen Datensatz zeigen (Ladezustand, Status, Spannungen).
Stimmt `battery.charge.low` mit dem gewuenschten Wert ueberein?

## Schritt 4: Dienst aktivieren

Name des Client-Dienstes vorher pruefen (je nach Proxmox-/Debian-Version
kann er `nut-monitor` oder `nut-client` heissen):

```bash
systemctl list-units 'nut*'
systemctl enable --now nut-monitor   # ggf. anderen Namen einsetzen
```

## Schritt 5: Kontrollierter Test - ERST mit Dummy-Kommando

Nicht ungetestet am Produktivsystem scharf schalten. NUT sieht dafuer
extra eine Simulation vor (`upsmon(8)`, Abschnitt "SIMULATING POWER
FAILURES"):

1. `SHUTDOWNCMD` testweise auf einen harmlosen Dummy-Befehl setzen, z.B.:
   ```
   SHUTDOWNCMD "logger 'NUT-TEST: wuerde jetzt herunterfahren'"
   ```
2. Kritischen Zustand simulieren (kein Stecker ziehen noetig):
   ```bash
   upsmon -c fsd
   ```
3. Prüfen, ob der Dummy-Befehl wirklich ausgeloest wurde (Log/`journalctl`).
4. **Wichtig danach:** Auf dem Pi `upsd` neu starten, um das gesetzte
   FSD-Flag zurueckzusetzen, sonst bleibt der "kritisch"-Zustand haengen:
   ```bash
   sudo systemctl restart nut-server   # auf dem Pi
   ```
   Ausserdem pruefen, dass kein `POWERDOWNFLAG`-File (z.B. `/etc/killpower`)
   auf einem primary-System zurueckgeblieben ist - bei uns strukturell
   nicht relevant, da kein `upsmon` an diesem Standort im primary-Modus
   laeuft (weder Proxmox noch der Pi selbst - beide `secondary`) und
   `POWERDOWNFLAG` nirgends konfiguriert ist.
5. Erst wenn der Testlauf sauber durchlaeuft: `SHUTDOWNCMD` auf den echten
   Befehl umstellen und final in einem unkritischen Zeitfenster testen.

## Proxmox-spezifische Besonderheit: VM-Shutdown-Zeit einplanen

Ein `shutdown -h now` auf dem Proxmox-Host faehrt nicht sofort hart
herunter - laufende VMs werden zuerst regulaer gestoppt (Proxmox gibt
dafuer standardmaessig bis zu ~180s pro VM, bevor hart abgewuergt wird).
Bei mehreren VMs kann das in Summe mehrere Minuten dauern. Die gewaehlte
Batterie-Schwelle (Schritt "Voraussetzung") muss genug Restlaufzeit fuer
**VM-Shutdown + Host-Shutdown** uebrig lassen, nicht nur fuer den nackten
Host-Halt.

## Wahl der Schwelle (Hintergrund)

- Werks-Default der USV: 10% - fuer Server-/Virtualisierungs-Workloads
  meist zu knapp.
- Ueblich fuer diesen Anwendungsfall: 20-50%, je nach gewuenschtem Puffer.
- Faktoren, die eine hoehere Schwelle nahelegen: viele/lang laufende VMs,
  hohe tatsaechliche Last am Ausgang, oder eine Batterie, deren reales
  Alter/Zustand nicht zweifelsfrei bekannt ist.
- An diesem Standort: Batterien werden turnusmaessig alle 2 Jahre
  getauscht, daher kein zusaetzlicher Sicherheitsaufschlag dafuer noetig -
  30% wurde als ausreichender genereller Puffer gewaehlt.

## Optional: Fruehwarnung ohne Shutdown

`battery.charge.warning` (aktuell 50% laut USV) ist ein rein informativer
NUT-Wert - koennte fuer eine fruehzeitige Benachrichtigung (z.B. Mail bei
50%) genutzt werden, ohne dass dabei etwas heruntergefahren wird. Separates
Thema, hier nicht weiter ausgefuehrt (siehe `NOTIFYCMD`/`NOTIFYFLAG` in
`upsmon.conf(5)`).
