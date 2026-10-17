-- ==================================
-- KOMMENTAR: TUER-SENSOR UND SCHLEUSEN-STEUERUNG (UI-Version)
-- ==================================

local PROTOCOL = "notaus"
local LOCKDOWN_PROTOCOL = "lockdown"
local UPDATE_PROTOCOL = "doors_update"
local CONFIG_PROTOCOL = "doors_config"

local MASTER_ID = 24
local COMPUTER_ID = os.getComputerID()

local TEMP_FILE = "startup.update_tmp"
local BACKUP_FILE = "startup.backup"
local CONFIG_FILE = "sensor_config.txt"
local GITHUB_URL = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/Tuersensor/startup.lua"

-- ==================================
-- KOMMENTAR: UI UND LOG-EINSTELLUNGEN
-- ==================================
local MAX_LOG  = 3   
local LOG_TTL  = 6   
local FIELD_X, FIELD_Y, FIELD_W = 9, 8, 6
local BTN_X, BTN_Y, BTN_W = 17, 8, 10

-- ==================================
-- KOMMENTAR: PERIPHERIE PRUEFEN
-- ==================================
local modem = peripheral.find("modem")
local detector = peripheral.find("player_detector")

if not modem or not detector then
    print("Fehler: Modem oder Player Detector fehlt!")
    return
end

rednet.open(peripheral.getName(modem))

-- ==================================
-- KOMMENTAR: ZUSTANDS-VARIABLEN
-- ==================================
local emergencyActive = false
local lockdownActive  = false
local updatingState   = false
local host            = { range = 5 }
local fieldStr        = tostring(host.range)
local focus           = false
local fresh           = false

local logs = {}
local dirty = true
local tickTimer
local sensorTimer

-- ==================================
-- KOMMENTAR: DEBUG NACHRICHTEN
-- ==================================
local function now() return os.epoch("utc") / 1000 end

local function addLog(text)
    local w = term.getSize()
    local maxW = w - 2
    local line = ""
    for word in text:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word > maxW then
            table.insert(logs, {text = line, expires = now() + LOG_TTL})
            line = word
        else
            line = line .. " " .. word
        end
    end
    if line ~= "" then
        table.insert(logs, {text = line, expires = now() + LOG_TTL})
    end
    while #logs > MAX_LOG do table.remove(logs, 1) end
    dirty = true
end

-- ==================================
-- KOMMENTAR: KONFIGURATION VERWALTEN
-- ==================================
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if type(data) == "table" and data.range then
                host.range = data.range
                fieldStr = tostring(host.range)
                return true
            end
        end
    end
    return false
end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    if f then
        f.write(textutils.serialize({ range = host.range }))
        f.close()
    end
end

loadConfig()

-- ==================================
-- KOMMENTAR: GPS-POSITIONSABFRAGE
-- ==================================
local function getPositionString()
    local x, y, z = gps.locate(2)
    if x and y and z then
        return string.format("%.0f, %.0f, %.0f", x, y, z)
    else
        return "GPS n.verf."
    end
end

-- ==================================
-- KOMMENTAR: BERICHT AN MASTER SENDEN
-- ==================================
local function sendReport(success, details)
    local posStr = getPositionString()
    local label = os.getComputerLabel() or ("Tuer " .. tostring(COMPUTER_ID))
    
    pcall(function()
        rednet.send(MASTER_ID, {
            action = "log_report",
            success = success,
            details = details,
            pos = posStr,
            label = label
        }, UPDATE_PROTOCOL)
    end)
end

-- ==================================
-- KOMMENTAR: HILFSFUNKTIONEN FUER UI
-- ==================================
local function pad(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

local function hasPendingChanges()
    local val = tonumber(fieldStr)
    return val ~= nil and val ~= host.range
end

-- ==================================
-- KOMMENTAR: GRAFISCHE BENUTZEROBERFLAECHE
-- ==================================
local function draw()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    
    -- Kopfzeile
    term.setCursorPos(2, 2)
    term.setTextColor(colors.cyan)
    term.write("--- TUERSENSOR ---")
    local idStr = "ID:" .. COMPUTER_ID
    term.setCursorPos(w - #idStr, 2)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    -- System-Status
    term.setCursorPos(2, 5)
    term.setTextColor(colors.white)
    term.write("Status: ")

    if updatingState then
        term.setTextColor(colors.yellow)
        term.write("WARTUNG / UPDATING")
    elseif lockdownActive then
        term.setTextColor(colors.red)
        term.write("LOCKDOWN (VERRIEGELT)")
    elseif emergencyActive then
        term.setTextColor(colors.orange)
        term.write("EMERGENCY (DAUERAUF)")
    else
        term.setTextColor(colors.green)
        term.write("NORMALBETRIEB")
    end

    -- Eingabebereich Reichweite
    term.setCursorPos(2, FIELD_Y)
    term.setTextColor(colors.lightGray)
    term.setBackgroundColor(colors.black)
    term.write("Range: ")

    term.setCursorPos(FIELD_X, FIELD_Y)
    if focus then
        term.setBackgroundColor(colors.lightGray)
        term.setTextColor(colors.black)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
    end
    term.write(pad(fieldStr, FIELD_W))

    -- Relocate / Set Button
    term.setCursorPos(BTN_X, BTN_Y)
    term.setBackgroundColor(hasPendingChanges() and colors.orange or colors.green)
    term.setTextColor(colors.black)
    local btnLabel = " SETZEN "
    local pL = math.floor((BTN_W - #btnLabel) / 2)
    term.write(pad(string.rep(" ", pL) .. btnLabel, BTN_W))

    -- Hinweis Text
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, FIELD_Y + 2)
    term.write("Scanner-Reichweite: " .. tostring(host.range) .. " Bloecke")

    -- Debug Logs
    term.setTextColor(colors.gray)
    local startRow = h - #logs + 1
    for i, entry in ipairs(logs) do
        term.setCursorPos(2, startRow + i - 1)
        term.write(pad(entry.text, w - 2))
    end

    -- Cursor Verwaltung
    if focus then
        term.setBackgroundColor(colors.lightGray)
        term.setTextColor(colors.black)
        term.setCursorPos(FIELD_X + math.min(#fieldStr, FIELD_W - 1), FIELD_Y)
        term.setCursorBlink(true)
    else
        term.setCursorBlink(false)
    end
end

-- ==================================
-- KOMMENTAR: AKTIONEN & UPDATE (GITHUB HTTP ABFRAGE)
-- ==================================
local function setStatusMessage(msg)
    addLog(msg)
    draw()
end

local function saveNewRange()
    local val = tonumber(fieldStr)
    if not val or val < 1 or val > 50 then
        addLog("Ungueltig! (Erlaubt: 1-50)")
        fieldStr = tostring(host.range)
        focus = false
        dirty = true
        return
    end

    focus = false
    host.range = math.floor(val)
    fieldStr = tostring(host.range)
    saveConfig()
    
    addLog("Reichweite gesetzt auf: " .. host.range)
    sendReport(true, "Range auf " .. tostring(host.range) .. " aktualisiert")
    dirty = true
end

local function applyUpdate()
    updatingState = true
    draw()

    local function fail(reportText, uiText)
        sendReport(false, reportText)
        updatingState = false
        setStatusMessage(uiText or reportText)
        return false
    end

    setStatusMessage("Lade Update von GitHub...")

    if not http then
        return fail("HTTP-API inaktiv!", "Fehler: HTTP inaktiv")
    end

    local url = GITHUB_URL .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local response, httpErr, failResp = http.get(url)
    if not response then
        local why = tostring(httpErr)
        if failResp and failResp.getResponseCode then
            why = "HTTP " .. tostring(failResp.getResponseCode())
            pcall(failResp.close)
        end
        return fail("Download: " .. why:sub(1, 40), "Download-Fehler: " .. why:sub(1, 22))
    end

    local content = response.readAll()
    response.close()

    if not content or #content == 0 then
        return fail("Datei ist leer", "Fehler: Datei leer")
    end

    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return fail("GitHub lieferte HTML statt Code", "Fehler: HTML erhalten")
    end

    local f = fs.open(TEMP_FILE, "w")
    if not f then return fail("Temp-Datei nicht schreibbar", "Fehler: Dateizugriff") end
    f.write(content)
    f.close()

    local compiled, syntaxErr = loadfile(TEMP_FILE)
    fs.delete(TEMP_FILE)

    if not compiled then
        return fail("Syntaxfehler: " .. tostring(syntaxErr):sub(1, 40), "Fehler: Syntax im Update")
    end

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists("startup.lua") then
        fs.copy("startup.lua", BACKUP_FILE)
    elseif fs.exists("startup") then
        fs.copy("startup", BACKUP_FILE)
    end

    local newFile = fs.open("startup.lua", "w")
    if not newFile then return fail("Dateizugriff verweigert", "Installationsfehler") end
    newFile.write(content)
    newFile.close()

    if fs.exists("startup") then fs.delete("startup") end

    sendReport(true, "Update erfolgreich (GitHub)")
    setStatusMessage("Neustart in 2s...")
    sleep(2)
    os.reboot()
end

-- ==================================
-- KOMMENTAR: SENSOR LOGIK TICK
-- ==================================
local function runSensorCheck()
    if updatingState then return end
    
    if lockdownActive then
        rs.setOutput("top", false)
    elseif emergencyActive then
        rs.setOutput("top", true)
    else
        local ok, players = pcall(function() return detector.getPlayersInRange(host.range) end)
        if ok and type(players) == "table" and #players > 0 then
            rs.setOutput("top", true)
        else
            rs.setOutput("top", false)
        end
    end
end

-- ==================================
-- KOMMENTAR: HAUPTSCHLEIFE (EVENTS)
-- ==================================
local function main()
    tickTimer = os.startTimer(0.5)
    sensorTimer = os.startTimer(0.5)

    while true do
        if dirty then
            draw()
            dirty = false
        end

        local ev, p1, p2, p3 = os.pullEvent()

        if ev == "timer" then
            if p1 == tickTimer then
                tickTimer = os.startTimer(0.5)
                local t = now()
                for i = #logs, 1, -1 do
                    if logs[i].expires <= t then
                        table.remove(logs, i)
                        dirty = true
                    end
                end
            elseif p1 == sensorTimer then
                runSensorCheck()
                sensorTimer = os.startTimer(0.5)
            end

        elseif ev == "mouse_click" then
            local x, y = p2, p3
            
            if y == FIELD_Y and x >= FIELD_X and x < FIELD_X + FIELD_W then
                focus = true
                fresh = true
                dirty = true
            elseif y == BTN_Y and x >= BTN_X and x < BTN_X + BTN_W then
                term.setCursorPos(BTN_X, BTN_Y)
                term.setBackgroundColor(colors.orange)
                term.setTextColor(colors.black)
                term.write(pad("  SETZEN  ", BTN_W))
                sleep(0.15)
                saveNewRange()
            else
                focus = false
                dirty = true
            end

        elseif ev == "char" then
            if focus then
                if p1:match("^%d$") then
                    if fresh then fieldStr = ""; fresh = false end
                    if #fieldStr < FIELD_W - 1 then
                        fieldStr = fieldStr .. p1
                    end
                    dirty = true
                end
            end

        elseif ev == "key" then
            if focus and p1 == keys.backspace then
                if fresh then fieldStr = ""; fresh = false
                else fieldStr = fieldStr:sub(1, -2) end
                dirty = true
            elseif focus and (p1 == keys.enter or p1 == keys.numPadEnter) then
                saveNewRange()
            end

        elseif ev == "rednet_message" then
            local id, message, protocol = p1, p2, p3
            
            if protocol == PROTOCOL and not updatingState then
                if message == "EMERGENCY_ON" then
                    emergencyActive = true
                    addLog("Not-Aus aktiviert!")
                    dirty = true
                elseif message == "EMERGENCY_OFF" then
                    emergencyActive = false
                    addLog("Not-Aus aufgehoben.")
                    dirty = true
                end
                
            elseif protocol == LOCKDOWN_PROTOCOL and not updatingState then
                if message == "LOCKDOWN_ON" then
                    lockdownActive = true
                    addLog("Lockdown verriegelt!")
                    dirty = true
                elseif message == "LOCKDOWN_OFF" then
                    lockdownActive = false
                    addLog("Lockdown aufgehoben.")
                    dirty = true
                end
                
            elseif protocol == CONFIG_PROTOCOL and not updatingState then
                if type(message) == "table" and message.action == "set_range" and type(message.range) == "number" then
                    fieldStr = tostring(message.range)
                    saveNewRange() -- Aktualisiert intern und speichert
                elseif message == "STATUS_REQUEST" then
                    sendReport(true, "Online (Range: " .. tostring(host.range) .. ")")
                end
                
            elseif protocol == UPDATE_PROTOCOL then
                if id == MASTER_ID and type(message) == "table" and message.action == "update" then
                    pcall(function() rednet.send(MASTER_ID, { action = "ping_ack" }, UPDATE_PROTOCOL) end)
                    local ok, err = pcall(applyUpdate, message.code)
                    if not ok then
                        updatingState = false
                        sendReport(false, "Update-Fehler: " .. tostring(err):sub(1, 40))
                        addLog("Update-Fehler: " .. tostring(err):sub(1, 30))
                    end
                end
            end
        end
    end
end

-- ==================================
-- KOMMENTAR: SCHUTZ-WRAPPER
-- ==================================
addLog("Sensor bereit. Warte auf Netzwerk...")
while true do
    local ok, err = pcall(main)
    if not ok then
        if tostring(err):find("Terminated") then
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("Tuersensor beendet.")
            return
        end
        addLog("Kritischer Fehler: " .. tostring(err))
        sleep(3)
    end
end