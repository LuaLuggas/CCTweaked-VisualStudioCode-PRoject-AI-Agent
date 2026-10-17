---
name: bunker-role-blueprint
description: >-
  Complete step-by-step blueprint, Lua 5.1 skeleton template, and 7-point MasterComputer
  integration checklist for creating or extending CC:Tweaked Bunker roles in ATM10.
  Activate this skill whenever creating a new role in programme/<Rolle>/startup.lua,
  integrating a device/setting into MasterComputer/startup.lua, or adding a new peripheral.
---

# Bunker Role & MasterComputer Integration Blueprint

Nutze diesen Skill als exakte Vorlage, um mit minimalem Token-Verbrauch und 0 Fehlern neue Computer-Rollen zu bauen oder in den `MasterComputer` (`ID 24`) einzubinden.

---

## 1. Die 7-Punkte-Checkliste für `programme/MasterComputer/startup.lua`

Wenn eine neue Geräte-Kategorie oder Einstellung in den `MasterComputer` eingebaut wird, **müssen** genau diese 7 Stellen im Skript synchron angepasst werden:

1. **Protokoll-Konstanten & State-Tabelle (Zeilen 1–60):**
   - `UPDATE_PROTOCOL_<KEY> = "<rolle>_update"` und `CONFIG_PROTOCOL_<KEY> = "<rolle>_config"` anlegen.
   - **WICHTIG (60-Upvalue-Limit):** Keine losen `local`-Variablen hinzufügen! Neue Einstellungen immer in einer gebündelten Tabelle (z. B. `local myCfg = { val = 100, editVal = 100 }`) ablegen.
   - `hasPending<Key>Changes()` Funktion ergänzen.
2. **Persistenz (`saveMasterConfig` & `loadMasterConfig`):**
   - Felder beim Speichern in `MASTER_CFG_FILE` eintragen und beim Laden mit `type(data.xyz) == ...` prüfen.
3. **Geräte-Registrierung (`registerTerminal` & `getTerminalsList`):**
   - In `registerTerminal()` die Erkennung für `devType = "<type>"` anhand des Protokolls ergänzen.
   - In `getTerminalsList(filterType)` den Filter `elseif filterType == "<filter>" and data.devType == "<type>"` ergänzen.
4. **Menü-Buttons & Pocket-Geometrie (`drawVerwGeraeteUI`, `drawVerwUpdatesUI`, `drawVerwSettingsUI`):**
   - **WICHTIG:** Der `MasterComputer` ist **IMMER ein Advanced Pocket Computer (`26 Spalten × 20 Zeilen`)**!
   - Horizontal: Maximale nutzbare Breite ist **22–24 Zeichen** (Spalten `2..25`, `btnWidth = math.min(22, w - 2)`). Nebeneinanderliegende Elemente dürfen niemals über Spalte 25 hinausgehen!
   - Vertikal: Buttons maximal bis Zeile `16` platzieren, Zeile `17–20` bleibt für `drawDebugOverlay` / Footer-Buttons.
5. **Listen-Header & View-Routing (`drawTerminalsUI` & `drawUI`):**
   - In `drawTerminalsUI()` den Titel für `terminalFilter == "<filter>"` und die Vorschau-Formatierung (`tData.preview`) ergänzen.
   - In `drawUI()` den `elseif viewMode == "..."` Zweig eintragen.
6. **Button-Aktionen (`handleAction(id)`):**
   - Beim Öffnen eines Einstellungs-Menüs (`nav_verw_settings_<key>`) die `edit*`-Felder mit sicheren Fallbacks (`or 0` / `or ""`) aus den gespeicherten Feldern kopieren.
   - Update-Broadcast (`rednet.broadcast({ action = "update" }, UPDATE_PROTOCOL_<KEY>)`) einbauen.
   - In `geraete_ref` (`REF`-Button) `rednet.broadcast("STATUS_REQUEST", ...)` für die neuen Protokolle ergänzen!
7. **Rednet-Empfang (`rednet_message` in `main()`):**
   - Die neuen Protokolle in die `if (protocol == ...)` Bedingung aufnehmen, damit `log_report` empfangen wird.
   - Falls das Slave-Gerät beim Start Einstellungen abfragt (`request_<key>_sync`), direkt per `rednet.send(id, { ..., isReply = true }, CONFIG_PROTOCOL_<KEY>)` antworten.

*(Zusätzlich immer `installer.lua`, `roles/<Rolle>.txt`, `backups/<Rolle>/startup.lua`, `docs/netzwerk.md`, `docs/peripherals.md` und `docs/changelog.md` aktualisieren!)*

---

## 2. Standard-Template für eine neue Rolle (`programme/<Rolle>/startup.lua`)

Jede neue Rolle nutzt dieses bewährte Grundgerüst (Upvalue-sicher, GPS-gecacht, mit GitHub-Auto-Updater und Bunker-UI):

```lua
-- ==================================
-- KOMMENTAR: KONFIGURATION & KONSTANTEN (UPVALUE-GEBUENDELT)
-- ==================================
local CFG = {
    MASTER_ID         = 24,
    PROTOCOL          = "notaus",
    LOCKDOWN_PROTOCOL = "lockdown",
    UPDATE_PROTOCOL   = "neue_rolle_update",
    CONFIG_PROTOCOL   = "neue_rolle_config",

    MSG_ON            = "EMERGENCY_ON",
    MSG_OFF           = "EMERGENCY_OFF",
    MSG_LOCK          = "LOCKDOWN_ON",
    MSG_UNLOCK        = "LOCKDOWN_OFF",
    MSG_STATUS        = "STATUS_REQUEST",

    GITHUB_URL        = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/NeueRolle/startup.lua",
    CONFIG_FILE       = "rolle.cfg",
    TEMP_FILE         = "startup.update_tmp",
    BACKUP_FILE       = "startup.backup",
    LOG_TTL           = 5,
    COMPUTER_ID       = os.getComputerID()
}

-- ==================================
-- KOMMENTAR: LAUFZEIT-ZUSTAND & UI-HITBOXEN
-- ==================================
local state = {
    modem           = nil,
    emergencyActive = false,
    lockdownActive  = false,
    updatingState   = false,
    lastUpdateTime  = "-",
    lastUpdateStat  = "noch keins",
    cachedPos       = "GPS n.verf.",
    statusLogs      = {},
    dirty           = true,
    tickTimer       = nil
}

local hitboxes = {}

local function now()
    return os.epoch("utc") / 1000
end

local function addLog(msg)
    local text = tostring(msg or "")
    if #text == 0 then return end
    table.insert(state.statusLogs, { text = text:sub(1, 48), expires = now() + CFG.LOG_TTL })
    while #state.statusLogs > 2 do
        table.remove(state.statusLogs, 1)
    end
    state.dirty = true
end

local function refreshGpsCache()
    if not state.modem then
        state.cachedPos = "GPS n.verf."
        return
    end
    local x, y, z = gps.locate(1.5)
    if x and y and z then
        state.cachedPos = string.format("%.0f, %.0f, %.0f", x, y, z)
    end
end

local function sendReport(success, details)
    if not state.modem then return end
    local label = os.getComputerLabel() or ("Geraet " .. tostring(CFG.COMPUTER_ID))
    local preview = "Bereit"
    pcall(function()
        rednet.send(CFG.MASTER_ID, {
            action  = "log_report",
            success = success,
            details = details or ("Online: " .. preview),
            pos     = state.cachedPos,
            label   = label,
            preview = preview,
            devType = "neue_rolle"
        }, CFG.UPDATE_PROTOCOL)
    end)
end
```

---

## 3. Anti-Bug-Checkliste vor Abschluss jedes Tasks

1. **Keine Umlaute in UI-Strings:** Wurden alle `ä, ö, ü, ß` in sichtbaren Texten durch `ae, oe, ue, ss` ersetzt?
2. **Kein `nil` in `string.format`:** Ist jedes `%d` / `%.2f` mit `(tonumber(x) or 0)` und jedes `%s` mit `tostring(x or "")` abgesichert?
3. **60-Upvalue-Limit eingehalten:** Wurden neue Variablen in `CFG` / `state` / `hitboxes` gelegt statt als einzelne `local`-Variablen?
4. **GPS-Cache eingehalten:** Wird `gps.locate()` nur beim Start in `refreshGpsCache()` aufgerufen und niemals innerhalb eines laufenden Timer-Zyklus?
5. **Backup-Pflicht:** Wurde der Nutzer vor dem Editieren bestehender Skripte gefragt und das Backup in `backups/<Rolle>/startup.lua` aktualisiert?

