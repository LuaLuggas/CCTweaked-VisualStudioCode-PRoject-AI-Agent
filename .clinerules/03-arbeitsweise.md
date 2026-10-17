# Arbeitsweise (Optimiert für höchste Präzision & Effizienz)

## Vor jeder Änderung (PFLICHT)
1. **Gezielt lesen:** Lies `docs/netzwerk.md`, `docs/peripherals.md` und die relevanten Zeilenbereiche (`StartLine`/`EndLine`) der betroffenen Programme, bevor du etwas änderst.
2. **Blueprint-Skill nutzen:** Aktiviere bei neuen Rollen oder MasterComputer-Erweiterungen immer den Skill `.agents/skills/bunker-role-blueprint/SKILL.md` und arbeite die 7-Punkte-Checkliste ab.
3. **Nachfragen statt Raten:** Wenn irgendetwas an einer Anfrage, einem UI-Detail oder einer Funktion unklar ist, probiere **niemals** Dinge auf gut Glück aus, sondern stelle gezielte Rückfragen (`ask_question`) an den Nutzer!
4. **Backup-Abfrage im Projekt (PFLICHT):** Frage vor **jeder** Änderung an bestehenden Skripten, ob das zu verändernde Skript vorher in `backups/<Rolle>/startup.lua` gespeichert bzw. aktualisiert werden soll.

## Beim Ändern & Selbst-Kontrolle
- Mache chirurgische Änderungen mit `replace_file_content`. Entferne keine Funktionen oder Sicherheitsprüfungen, die nicht erwähnt wurden.
- **Pflicht-Selbstcheck nach jedem Edit:**
  1. Stimmen alle benutzten Tabellen-/Feldnamen exakt mit ihrer Deklaration oben im Skript überein?
  2. Sind alle `string.format`-Aufrufe mit `or 0` / `or ""` gegen `nil` abgesichert?
  3. Passen alle Buttons in die 19 Zeilen eines Standard-Terminals?

## Nach jeder Änderung
- Erkläre in höchstens 5 Zeilen, was geändert wurde und warum.
- Sage kurz, was im Spiel zu tun ist (z. B. GitHub Sync in VS Code $\rightarrow$ Update am MasterComputer).
- Nenne 2–3 konkrete Testschritte im Spiel und was zu sehen sein sollte.
- Trage die Änderung in `docs/changelog.md` ein und halte `docs/netzwerk.md`, `docs/peripherals.md`, `installer.lua` sowie `roles/` aktuell.
