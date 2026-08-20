# Windows-PC als NUT-Client einrichten (Shutdown + Bildschirm-Warnung)

Generische Anleitung, unabhaengig vom konkreten Standort. Gleiches Prinzip
wie bei Proxmox (siehe `proxmox/SETUP.md`): Der Windows-PC liest die
USV-Werte vom Pi (NUT-Server) und entscheidet **eigenstaendig**, wann er
sich herunterfaehrt. Zusaetzlich: sichtbare Warnung auf dem Bildschirm,
bevor es tatsaechlich passiert.

**Hinweis:** Diese Anleitung wurde nicht an einem echten Windows-PC
gegengetestet (kein Zugriff darauf). Protokoll-Fakten (Port, Zugangsdaten,
Funktionsprinzip) sind sicher, UI-Details bitte beim Einrichten selbst
verifizieren.

## Empfohlenes Tool: WinNUT-Client

NUT selbst bringt keinen offiziellen Windows-GUI-Client mit. In der
NUT-Community verbreitet und aktiv gepflegt ist das quelloffene
Community-Projekt **WinNUT-Client**. Nur ueber die offizielle
GitHub-Release-Seite des Projekts beziehen, nicht ueber
Drittanbieter-Downloadportale (Signaturen/Herkunft vor der Installation
pruefen wie bei jeder ausfuehrbaren Software).

Es laeuft als Tray-Anwendung/Dienst, verbindet sich zu einem NUT-Server
(unserem Pi), zeigt Status-Benachrichtigungen (Popup bei Netzausfall,
Low-Battery, Kommunikationsverlust) und kann bei Bedarf einen sauberen
Windows-Shutdown ausloesen.

## Voraussetzung (bereits erledigt auf dem Pi)

- `nut-server` auf dem Pi aktiv, `ups.conf` mit
  `override.battery.charge.low` auf den gewuenschten Wert gesetzt.
- Firewall (`ufw`) auf dem Pi erlaubt Port 3493/tcp.
- Zugangsdaten (`monuser` + Passwort) aus `/etc/nut/upsd.users` auf dem Pi
  bekannt (`sudo cat /etc/nut/upsd.users`).

## Installation & Konfiguration

1. Aktuelles Release von der offiziellen WinNUT-Client-Projektseite
   herunterladen und installieren.
2. In den Verbindungs-Einstellungen:
   - Server: `<PI_IP>`
   - Port: `3493`
   - UPS-Name: `apc2200` (bzw. der tatsaechliche Name aus `ups.conf`)
   - Benutzer/Passwort: `monuser` / `<aus upsd.users>`
3. Verbindung testen (WinNUT sollte Live-Werte wie Ladezustand/Status
   anzeigen).

## Zwei Ebenen der Bildschirm-Warnung

1. **Sofortige Tray-Benachrichtigung** bei Statuswechsel (Windows-Toast) -
   in WinNUT als Notify-Option pro Ereignis (Netzausfall, Low-Battery,
   Kommunikationsverlust) aktivierbar.
2. **Verzoegerter Shutdown mit sichtbarem Countdown:** Windows' eigener
   `shutdown /s /t <sekunden>`-Befehl zeigt selbst eine System-Meldung mit
   Restzeit im Vordergrund an (nicht einfach wegklickbar, deutlich
   auffaelliger als ein Tray-Popup). WinNUT nutzt intern diesen
   Mechanismus, wenn ein Delay-Wert konfiguriert ist. Ein Delay von z.B.
   60-120 Sekunden gibt einer Person am Rechner eine klare, native
   Windows-Warnung inkl. Restzeit, bevor tatsaechlich heruntergefahren
   wird - deutlich sichtbarer als ein reines Hintergrund-Ereignis.

## Analogie zur Proxmox-Shutdown-Logik

Genau wie bei Proxmox (siehe `proxmox/SETUP.md`, Abschnitt
"Funktionsprinzip"): Die eigentliche Shutdown-Entscheidung basiert auf den
`OB`/`LB`-Status-Flags, die der Treiber auf dem Pi anhand des dort
gesetzten `override.battery.charge.low`-Werts ermittelt - nicht auf einem
separat am Windows-PC eingestellten Prozentwert. WinNUT liest lediglich
diese Werte vom Pi und reagiert darauf.

## Test

Analog zum Proxmox-Vorgehen (`proxmox/SETUP.md`, Abschnitt "Kontrollierter
Test"): Erst mit ausreichend Delay und in einem unkritischen Zeitfenster
testen (z.B. per `upsmon -c fsd` auf einem Client, oder WinNUTs eigener
Testfunktion, falls vorhanden), bevor der Shutdown-Mechanismus fuer den
produktiven Einsatz scharf geschaltet wird. Nach jedem Test auf dem Pi
`nut-server` neu starten, um das FSD-Flag zurueckzusetzen:

```bash
sudo systemctl restart nut-server
```
