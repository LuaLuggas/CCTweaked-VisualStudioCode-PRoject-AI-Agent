# Arbeitsweise

## Vor jeder Änderung (PFLICHT)
1. **Lesen:** Lies die betroffenen Programme und die Dateien in `docs/`, bevor du etwas änderst.
2. **Nachfragen statt Raten:** Wenn irgendetwas an einer Anfrage, einem UI-Detail oder einer Funktion unklar ist, probiere **niemals** Dinge auf gut Glück aus, sondern stelle gezielte Rückfragen an den Nutzer!
3. **Backup-Abfrage im Projekt (PFLICHT):** Frage vor **jeder** Änderung an bestehenden Skripten, ob das zu verändernde Skript vorher im Projekt als Backup gespeichert bzw. das letzte Backup überschrieben werden soll, damit jederzeit sofort auf den letzten funktionierenden Stand zurückgegriffen werden kann.
4. **Kurzer Plan:** Bei neuen Ideen oder Umbauten schlage erst einen kurzen Plan vor (welche Dateien ändern sich, was kann schiefgehen) und warte auf das OK.

## Beim Ändern
- Mache die kleinste Änderung, die funktioniert. Schreibe keine Dateien komplett neu, benenne nichts um und entferne keine Funktionen, die nicht erwähnt wurden. Bestehendes, das läuft, bleibt wie es ist.
- Halte dich strikt an den Bunker-UI-Styleguide und die Lua 5.1 Regeln aus [`GEMINI.md`](../GEMINI.md).
- Bleibe im Projektordner. Lösche keine Dateien ohne Rückfrage.

## Nach jeder Änderung
- Erkläre in höchstens 5 Zeilen, was geändert wurde und warum.
- Sage kurz, was im Spiel zu tun ist (z. B. GitHub Sync in VS Code -> Update am MasterComputer).
- Nenne 2–3 konkrete Testschritte im Spiel und was zu sehen sein sollte.
- Trage die Änderung in `docs/changelog.md` ein und halte `docs/netzwerk.md`, `docs/peripherals.md` sowie `roles/` aktuell.
