# Projekt: Post-Apokalyptischer Bunker (ATM10 / MC 1.21.1)

Dieses Projekt enthält Lua-Programme für die Minecraft-Mod **CC: Tweaked** und **Advanced Peripherals** (Minecraft Java 1.21.1, Modpack All The Mods 10 auf einem gehosteten G-Portal-Server). Die Programme laufen auf Computern, Turtles und Pocket-Computern IM SPIEL. Ich bin Hobbyspieler und kein Programmierer.

> **Hinweis für Antigravity:** Das vollständige, automatisch geladene Haupt-Regelwerk liegt in [`GEMINI.md`](../GEMINI.md).

## Wie du mit mir sprichst
- Antworte auf Deutsch, kurz, präzise und ohne unnötigen Fachjargon.
- Erkläre bei jeder Änderung in höchstens 5 Zeilen, was du geändert hast und warum.
- Kommentare im Code schreibst du auf Deutsch.

## Ordnerstruktur
- `programme/<Rolle>/startup.lua`: Eigenständige All-in-One `startup.lua` je Computer-Rolle (`MasterComputer`, `EmergencyTerminal`, `Tuersensor`, `TextAnzeige`, `GPSHost`).
- `installer.lua` & `roles/<Rolle>.txt`: Rollen-Installer für neue Computer über GitHub.
- `docs/peripherals.md`: Welche Blöcke/Mods (CC:Tweaked, Advanced Peripherals, Mekanism, AE2, Mystical Agriculture) an welchen Computern hängen und welche Methoden bestätigt sind.
- `docs/netzwerk.md`: Alle Rednet-Protokolle, Computer-IDs (`MASTER_ID = 24`) und Nachrichtenformate.
- `docs/changelog.md`: Kurze Liste aller Änderungen.
