# Bunker Control System – CC:Tweaked & Advanced Peripherals (ATM10)

Zentrales Repository für das Steuerungs-, Sicherheits- und Informationssystem unseres Endzeit-/Biohazard-Bunkers in **All The Mods 10 (Minecraft 1.21.1)**.

## 📂 Projektstruktur

- **[`GEMINI.md`](./GEMINI.md)**: Haupt-Regelwerk für den Antigravity AI-Agenten (Code-Architektur, Bunker-UI-Styleguide, Lua 5.1 Upvalue-Schutz, Update-Standards). Wird automatisch bei jeder Konversation geladen.
- **[`programme/`](./programme/)**: Die eigenständigen `startup.lua`-Programme je Computer-Rolle:
  - [`MasterComputer/startup.lua`](./programme/MasterComputer/startup.lua) – Zentrale Verwaltung (ID 24), Geräteliste, Log-Konsole, Blink-Sync & Remote-Updater.
  - [`EmergencyTerminal/startup.lua`](./programme/EmergencyTerminal/startup.lua) – Touch-Monitor-Panel für Not-Aus (`EMERGENCY`) und Verriegelung (`LOCKDOWN`).
  - [`Tuersensor/startup.lua`](./programme/Tuersensor/startup.lua) – Automatische Tür-/Schleusensteuerung via `player_detector` mit Emergency-/Lockdown-Override.
  - [`TextAnzeige/startup.lua`](./programme/TextAnzeige/startup.lua) – Mehrzeilige Wegweiser- & Warnmonitore mit Live-Editor, Farben, Laufschrift und Blink-Sync.
  - [`GPSHost/startup.lua`](./programme/GPSHost/startup.lua) – GPS-Satelliten-Host mit UI und Remote-Relocate.
- **[`docs/`](./docs/)**:
  - [`netzwerk.md`](./docs/netzwerk.md) – Alle Rednet-Protokolle, Computer-IDs und Nachrichtenformate.
  - [`peripherals.md`](./docs/peripherals.md) – Verwendete und geplante Peripherals (CC:Tweaked, Advanced Peripherals, Mekanism, AE2, Mystical Agriculture).
  - [`changelog.md`](./docs/changelog.md) – Verlauf aller Änderungen.
- **[`roles/`](./roles/)** & **[`update.lua`](./update.lua)**: Rollen-Zuordnungen und Direkt-Updater über GitHub.

## 🔒 Sicherheitshinweis
Keine Passwörter, Server-Logins oder privaten API-Schlüssel in dieses Repository schreiben, da es für den Ingame-Abruf per `http.get` öffentlich (Public) auf GitHub liegt.
