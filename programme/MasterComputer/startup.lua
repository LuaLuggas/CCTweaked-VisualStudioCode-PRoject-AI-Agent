-- ==================================
-- KOMMENTAR: PROTOKOLLE & KONFIGURATION
-- ==================================
local UPDATE_PROTOCOL_TERM = "notaus_update"
local UPDATE_PROTOCOL_DOOR = "doors_update"
local UPDATE_PROTOCOL_SIGN = "signs_update"
local UPDATE_PROTOCOL_GPS  = "gps_update"
local UPDATE_PROTOCOL_SPK  = "speaker_update"
local CONFIG_PROTOCOL_DOOR = "doors_config"
local CONFIG_PROTOCOL_SIGN = "signs_config"
local CONFIG_PROTOCOL_GPS  = "gps_config"
local CONFIG_PROTOCOL_SPK  = "speaker_config"
local STATUS_PROTOCOL      = "notaus"
local TERMINALS_FILE       = "terminals.db"
local MASTER_CFG_FILE      = "master_config.cfg"
local TEMP_FILE            = "startup.update_tmp"
local BACKUP_FILE          = "startup.backup"
local GITHUB_URL_MASTER    = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/MasterComputer/startup.lua"

-- ==================================
-- KOMMENTAR: PERIPHERIE PRUEFEN
-- ==================================
local modem = peripheral.find("modem")

if not modem then
    print("Fehler: Kein Modem gefunden!")
    return
end

rednet.open(peripheral.getName(modem))

-- ==================================
-- KOMMENTAR: GLOBALE VARIABLEN & STATUS
-- ==================================
local masterID     = os.getComputerID()
local currentRange = 5

-- Zentrale Blink-Einstellungen fuer alle synchronisierten Textanzeigen
local signSplitBlink = false
local signBlinkOn    = 1.20
local signBlinkOff   = 1.20
local editSignSplitBlink = false
local editSignBlinkOn    = 1.20
local editSignBlinkOff   = 1.20

-- Zentrale Alarm-Sound-Einstellungen fuer alle Lautsprecher (Upvalue-gebuendelt)
local spkCfg = {
    emergencyUrl     = "",
    lockdownUrl      = "",
    alarmVol         = 100,
    editEmergencyUrl = "",
    editLockdownUrl  = "",
    editAlarmVol     = 100
}

local statusMessage = ""

-- Log, UI und Temporaere Nachrichten
local logEntries = {}
local debugLogs  = {}
local MAX_LOGS   = 100
local MAX_DEBUG  = 3
local LOG_TTL    = 4
local scrollOffset = 0
local viewMode = "main" 
local filterId = nil
local terminalFilter = nil 
local registeredTerminals = {}
local currentButtons = {}
local tickTimer = os.startTimer(0.5)

local function round(val, step)
    return math.floor((val / step) + 0.5) * step
end

local function hasPendingSignBlinkChanges()
    if editSignSplitBlink ~= signSplitBlink then return true end
    if math.abs(editSignBlinkOn - signBlinkOn) > 0.01 then return true end
    local effEditOff  = editSignSplitBlink and editSignBlinkOff or editSignBlinkOn
    local effSavedOff = signSplitBlink and signBlinkOff or signBlinkOn
    if math.abs(effEditOff - effSavedOff) > 0.01 then return true end
    return false
end

local function hasPendingSpkChanges()
    if spkCfg.editEmergencyUrl ~= spkCfg.emergencyUrl then return true end
    if spkCfg.editLockdownUrl ~= spkCfg.lockdownUrl then return true end
    if spkCfg.editAlarmVol ~= spkCfg.alarmVol then return true end
    return false
end

-- ==================================
-- KOMMENTAR: DEBUG NACHRICHTEN SYSTEM
-- ==================================
local function addDebugMsg(text)
    local w = term.getSize()
    local maxW = w - 4
    local expTime = (os.epoch("utc") / 1000) + LOG_TTL
    local line = ""
    for word in tostring(text):gmatch("%S+") do
        if #word > maxW then word = word:sub(1, maxW) end
        if line == "" then
            line = word
        elseif #line + 1 + #word > maxW then
            table.insert(debugLogs, {text = line, expires = expTime})
            line = word
        else
            line = line .. " " .. word
        end
    end
    if line ~= "" then
        table.insert(debugLogs, {text = line, expires = expTime})
    end
    while #debugLogs > MAX_DEBUG do table.remove(debugLogs, 1) end
end

-- ==================================
-- KOMMENTAR: DATENBANK & MASTER-KONFIGURATION
-- ==================================
local function saveMasterConfig()
    local f = fs.open(MASTER_CFG_FILE, "w")
    if f then
        f.write(textutils.serialize({
            currentRange    = currentRange,
            signSplitBlink  = signSplitBlink,
            signBlinkOn     = signBlinkOn,
            signBlinkOff    = signBlinkOff,
            spkEmergencyUrl = spkCfg.emergencyUrl,
            spkLockdownUrl  = spkCfg.lockdownUrl,
            spkAlarmVol     = spkCfg.alarmVol
        }))
        f.close()
    end
end

local function loadMasterConfig()
    if fs.exists(MASTER_CFG_FILE) then
        local f = fs.open(MASTER_CFG_FILE, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then
                if type(data.currentRange) == "number" then currentRange = data.currentRange end
                if type(data.signSplitBlink) == "boolean" then signSplitBlink = data.signSplitBlink end
                if type(data.signBlinkOn) == "number" then signBlinkOn = data.signBlinkOn end
                if type(data.signBlinkOff) == "number" then signBlinkOff = data.signBlinkOff end
                if type(data.spkEmergencyUrl) == "string" then spkCfg.emergencyUrl = data.spkEmergencyUrl end
                if type(data.spkLockdownUrl) == "string" then spkCfg.lockdownUrl = data.spkLockdownUrl end
                if type(data.spkAlarmVol) == "number" then spkCfg.alarmVol = math.max(0, math.min(100, data.spkAlarmVol)) end
            end
        end
    end
    editSignSplitBlink      = signSplitBlink
    editSignBlinkOn         = signBlinkOn
    editSignBlinkOff        = signBlinkOff
    spkCfg.editEmergencyUrl = spkCfg.emergencyUrl
    spkCfg.editLockdownUrl  = spkCfg.lockdownUrl
    spkCfg.editAlarmVol     = spkCfg.alarmVol
end

local function saveTerminals()
    local file = fs.open(TERMINALS_FILE, "w")
    if file then
        file.write(textutils.serialize(registeredTerminals))
        file.close()
    end
end

local function loadTerminals()
    if fs.exists(TERMINALS_FILE) then
        local file = fs.open(TERMINALS_FILE, "r")
        if file then
            local data = textutils.unserialize(file.readAll())
            file.close()
            if type(data) == "table" then 
                for k, v in pairs(data) do
                    if not v.devType then
                        v.devType = (v.pos == "Sensor") and "door" or "terminal"
                    end
                    registeredTerminals[k] = v
                end
            end
        end
    end
end

loadMasterConfig()
loadTerminals()

-- ==================================
-- KOMMENTAR: GERAETE REGISTRIEREN UND LOGS
-- ==================================
local function registerTerminal(id, label, pos, protocol, preview, explicitType)
    if not id then return end
    
    local prevEntry = registeredTerminals[id]
    local devType = explicitType or "terminal"
    if not explicitType then
        if protocol == UPDATE_PROTOCOL_DOOR or protocol == CONFIG_PROTOCOL_DOOR then
            devType = "door"
        elseif protocol == UPDATE_PROTOCOL_GPS or protocol == CONFIG_PROTOCOL_GPS then
            devType = "gps"
        elseif protocol == UPDATE_PROTOCOL_SIGN or protocol == CONFIG_PROTOCOL_SIGN then
            devType = "sign"
        elseif protocol == UPDATE_PROTOCOL_SPK or protocol == CONFIG_PROTOCOL_SPK then
            devType = "speaker"
        elseif protocol == UPDATE_PROTOCOL_TERM or protocol == STATUS_PROTOCOL then
            devType = "terminal"
        elseif prevEntry and prevEntry.devType then
            devType = prevEntry.devType
        end
    end

    local finalLabel = label or (prevEntry and prevEntry.label) or ("ID " .. tostring(id))
    local finalPos   = pos or (prevEntry and prevEntry.pos) or "Unbekannt"
    local finalPrev  = preview or (prevEntry and prevEntry.preview)

    registeredTerminals[id] = {
        id       = id,
        label    = finalLabel,
        pos      = finalPos,
        devType  = devType,
        preview  = finalPrev,
        lastSeen = os.date("%H:%M:%S")
    }
    saveTerminals()
end

local function addLog(terminalId, success, details, posStr, label, protocol, preview, explicitType)
    local entry = {
        time  = os.date("%H:%M:%S"),
        id    = terminalId,
        ok    = success,
        text  = details or "",
        pos   = posStr or "Unbekannt",
        label = label or ("ID " .. tostring(terminalId))
    }
    table.insert(logEntries, entry)
    if #logEntries > MAX_LOGS then table.remove(logEntries, 1) end
    if terminalId > 0 then
        registerTerminal(terminalId, label, posStr, protocol, preview, explicitType)
    end
end

-- ==================================
-- KOMMENTAR: LISTEN-FILTER
-- ==================================
local function getFilteredLogs()
    if not filterId then return logEntries end
    local filtered = {}
    for _, entry in ipairs(logEntries) do
        if entry.id == filterId then table.insert(filtered, entry) end
    end
    return filtered
end

local function getTerminalsList(filter)
    local list = {}
    for _, termData in pairs(registeredTerminals) do 
        if not filter then
            table.insert(list, termData)
        elseif filter == "doors" and termData.devType == "door" then
            table.insert(list, termData)
        elseif filter == "terminals" and termData.devType == "terminal" then
            table.insert(list, termData)
        elseif filter == "signs" and termData.devType == "sign" then
            table.insert(list, termData)
        elseif filter == "gps" and termData.devType == "gps" then
            table.insert(list, termData)
        elseif filter == "speakers" and termData.devType == "speaker" then
            table.insert(list, termData)
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- ==================================
-- KOMMENTAR: DYNAMISCHES BUTTON SYSTEM & TITEL-RENDERER
-- ==================================
local function clearButtons()
    currentButtons = {}
end

local function drawHeaderTitle(y, title, col)
    local w = term.getSize()
    local tStr = title:sub(1, w - 2)
    local startX = math.max(1, math.floor((w - #tStr) / 2) + 1)
    term.setCursorPos(startX, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(col or colors.white)
    term.write(tStr)
end

local function addButton(id, x, y, width, text, bgCol, textCol)
    bgCol = bgCol or colors.gray
    textCol = textCol or colors.white
    
    term.setCursorPos(x, y)
    term.setBackgroundColor(bgCol)
    term.setTextColor(textCol)
    
    local cleanText = text:sub(1, width)
    local padL = math.floor((width - #cleanText) / 2)
    local padR = width - #cleanText - padL
    term.write(string.rep(" ", padL) .. cleanText .. string.rep(" ", padR))
    
    table.insert(currentButtons, {id = id, x1 = x, x2 = x + width - 1, y = y, text = cleanText})
end

local function drawMenuButton(id, y, text, bgCol, textCol)
    local w = term.getSize()
    local btnW = math.min(24, w - 2)
    local startX = math.floor((w - btnW) / 2) + 1
    addButton(id, startX, y, btnW, text, bgCol, textCol)
end

local function drawDebugOverlay(minRow)
    if #debugLogs == 0 then return end
    local w, h = term.getSize()
    local startRow = h - #debugLogs + 1
    for i, entry in ipairs(debugLogs) do
        local rowY = startRow + i - 1
        if rowY > (minRow or 13) and rowY <= h then
            term.setCursorPos(2, rowY)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.gray)
            local tStr = entry.text:sub(1, w - 2)
            term.write(tStr .. string.rep(" ", math.max(0, w - 2 - #tStr)))
        end
    end
end

-- ==================================
-- KOMMENTAR: UI RENDERER - MENUES
-- ==================================
local function drawMainUI()
    local w = term.getSize()
    drawHeaderTitle(3, "--- BUNKER MASTER ---", colors.red)

    local idStr = "ID: " .. tostring(masterID)
    term.setCursorPos(math.max(1, math.floor((w - #idStr) / 2) + 1), 4)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    drawMenuButton("nav_console", 7, "KONSOLEN-LOG", colors.gray)
    drawMenuButton("nav_verw_main", 9, "VERWALTUNG", colors.gray)

    drawDebugOverlay(11)
end

local function drawVerwaltungMainUI()
    drawHeaderTitle(2, "--- VERWALTUNG ---", colors.orange)

    drawMenuButton("nav_verw_geraete", 5, "GERAETE LISTE", colors.gray)
    drawMenuButton("nav_verw_updates", 7, "UPDATES", colors.gray)
    drawMenuButton("nav_verw_settings", 9, "EINSTELLUNGEN", colors.gray)
    drawMenuButton("nav_main", 14, "ZURUECK", colors.lightGray)

    drawDebugOverlay(15)
end

local function drawVerwGeraeteUI()
    drawHeaderTitle(2, "--- GERAETE LISTE ---", colors.yellow)

    drawMenuButton("terminals_all", 4, "ALLE GERAETE", colors.gray)
    drawMenuButton("terminals_doors", 6, "TUERSENSOREN", colors.gray)
    drawMenuButton("terminals_terms", 8, "TERMINALS", colors.gray)
    drawMenuButton("terminals_signs", 10, "TEXTANZEIGEN", colors.gray)
    drawMenuButton("terminals_gps", 12, "GPS-HOSTS", colors.gray)
    drawMenuButton("terminals_speakers", 14, "LAUTSPRECHER", colors.gray)
    drawMenuButton("nav_verw_main", 16, "ZURUECK", colors.lightGray)

    drawDebugOverlay(17)
end

local function drawVerwUpdatesUI()
    drawHeaderTitle(2, "--- UPDATES ---", colors.lightBlue)

    drawMenuButton("update_terminals", 4, "UPDATE: TERMINALS", colors.gray)
    drawMenuButton("update_doors", 6, "UPDATE: TUEREN", colors.gray)
    drawMenuButton("update_signs", 8, "UPDATE: ANZEIGEN", colors.gray)
    drawMenuButton("update_gps", 10, "UPDATE: GPS-HOSTS", colors.gray)
    drawMenuButton("update_speakers", 12, "UPDATE: SPEAKER", colors.gray)
    drawMenuButton("update_master", 14, "UPDATE: MASTER", colors.cyan, colors.black)
    drawMenuButton("nav_verw_main", 16, "ZURUECK", colors.lightGray)

    drawDebugOverlay(17)
end

local function drawVerwSettingsUI()
    drawHeaderTitle(2, "--- EINSTELLUNGEN ---", colors.magenta)

    drawMenuButton("nav_verw_settings_doors", 5, "TUEREN", colors.gray)
    drawMenuButton("nav_verw_settings_signs", 7, "TEXTANZEIGEN", colors.gray)
    drawMenuButton("nav_verw_settings_gps", 9, "GPS-HOST", colors.gray)
    drawMenuButton("nav_verw_settings_spk", 11, "LAUTSPRECHER", colors.gray)
    drawMenuButton("nav_verw_main", 14, "ZURUECK", colors.lightGray)

    drawDebugOverlay(15)
end

local function drawVerwSettingsDoorsUI()
    drawHeaderTitle(2, "--- TUEREN ---", colors.green)

    drawMenuButton("nav_range", 5, "SENSOR REICHWEITE", colors.gray)
    drawMenuButton("nav_verw_settings", 14, "ZURUECK", colors.lightGray)

    drawDebugOverlay(15)
end

local function drawVerwSettingsSignsUI()
    drawHeaderTitle(2, "--- TEXTANZEIGEN ---", colors.lime)

    drawMenuButton("nav_sign_blink", 5, "BLINK-GESCHWINDIGKEIT", colors.gray)
    drawMenuButton("nav_verw_settings", 14, "ZURUECK", colors.lightGray)

    drawDebugOverlay(15)
end

-- ==================================
-- KOMMENTAR: UI RENDERER - EINSTELLUNGEN -> GPS-HOST & LAUTSPRECHER
-- ==================================
local function drawVerwSettingsGpsUI()
    drawHeaderTitle(2, "--- GPS-HOST ---", colors.cyan)

    drawMenuButton("action_relocate_gps", 5, "RELOCATE HOSTS", colors.gray)
    drawMenuButton("nav_verw_settings", 14, "ZURUECK", colors.lightGray)

    drawDebugOverlay(14)
end

local function drawVerwSettingsSpkUI()
    local w = term.getSize()
    drawHeaderTitle(2, "--- LAUTSPRECHER ---", colors.orange)

    local boxW   = math.min(22, w - 2)
    local startX = math.floor((w - boxW) / 2) + 1

    term.setCursorPos(startX, 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.write("Emergency YT-Link:")
    local emDisp = (#spkCfg.editEmergencyUrl > 0) and spkCfg.editEmergencyUrl or "[ Link eingeben ]"
    if #emDisp > boxW - 2 then emDisp = emDisp:sub(1, boxW - 5) .. "..." end
    addButton("spk_edit_em", startX, 5, boxW, emDisp, colors.gray, (#spkCfg.editEmergencyUrl > 0) and colors.white or colors.lightGray)

    term.setCursorPos(startX, 7)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.orange)
    term.write("Lockdown YT-Link:")
    local ldDisp = (#spkCfg.editLockdownUrl > 0) and spkCfg.editLockdownUrl or "[ Link eingeben ]"
    if #ldDisp > boxW - 2 then ldDisp = ldDisp:sub(1, boxW - 5) .. "..." end
    addButton("spk_edit_ld", startX, 8, boxW, ldDisp, colors.gray, (#spkCfg.editLockdownUrl > 0) and colors.white or colors.lightGray)

    term.setCursorPos(startX, 10)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    local vol = tonumber(spkCfg.editAlarmVol) or 100
    term.write(string.format("Vol: %d%%", vol))
    addButton("spk_vol_dec", startX + 10, 10, 5, "-10%", colors.gray)
    addButton("spk_vol_inc", startX + 17, 10, 5, "+10%", colors.gray)

    local isDirty = hasPendingSpkChanges()
    drawMenuButton(
        "spk_send_alarm",
        13,
        "SPEICHERN & SENDEN",
        isDirty and colors.orange or colors.gray,
        isDirty and colors.black or colors.white
    )
    drawMenuButton("nav_verw_settings", 15, "ZURUECK", colors.lightGray)

    drawDebugOverlay(16)
end

local function drawSignBlinkUI()
    local w = term.getSize()
    drawHeaderTitle(2, "--- ANZEIGEN BLINK-SYNC ---", colors.pink)

    local modeLabel = editSignSplitBlink and "MODUS: [2S] GETRENNT" or "MODUS: [1S] GLEICH"
    drawMenuButton("toggle_sign_split", 4, modeLabel, editSignSplitBlink and colors.cyan or colors.gray, editSignSplitBlink and colors.black or colors.white)

    if not editSignSplitBlink then
        term.setCursorPos(2, 6)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.write(string.format("Blink-Takt: %.2fs", editSignBlinkOn))

        local startX = math.floor((w - 24) / 2) + 1
        addButton("sign_on_dec", startX, 8, 11, "- 0.10s", colors.gray)
        addButton("sign_on_inc", startX + 13, 8, 11, "+ 0.10s", colors.gray)
    else
        local startX = math.floor((w - 24) / 2) + 1
        term.setCursorPos(startX, 6)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.write(string.format("AN: %.2fs", editSignBlinkOn))
        addButton("sign_on_dec", startX + 12, 6, 5, "-0.1", colors.gray)
        addButton("sign_on_inc", startX + 18, 6, 5, "+0.1", colors.gray)

        term.setCursorPos(startX, 8)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        if editSignBlinkOff <= 0.001 then
            term.write("AUS:0.00s(Dauer)")
        else
            term.write(string.format("AUS:%.2fs", editSignBlinkOff))
        end
        addButton("sign_off_dec", startX + 12, 8, 5, "-0.1", colors.gray)
        addButton("sign_off_inc", startX + 18, 8, 5, "+0.1", colors.gray)
    end

    local isDirty = hasPendingSignBlinkChanges()
    drawMenuButton(
        "send_sign_blink",
        11,
        "SPEICHERN & SENDEN",
        isDirty and colors.orange or colors.gray,
        isDirty and colors.black or colors.white
    )
    drawMenuButton("nav_verw_settings_signs", 13, "ZURUECK", colors.lightGray)

    drawDebugOverlay(13)
end

local function drawRangeUI()
    drawHeaderTitle(2, "--- SENSOR REICHWEITE ---", colors.green)

    term.setCursorPos(2, 5)
    term.setTextColor(colors.white)
    term.write("Aktuelle Reichweite:")
    
    term.setCursorPos(2, 6)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(string.format(" %-20s", tostring(currentRange) .. " Bloecke"))

    drawMenuButton("action_range", 9, "AENDERN & SENDEN", colors.gray)
    drawMenuButton("nav_verw_settings_doors", 12, "ZURUECK", colors.lightGray)

    drawDebugOverlay(13)
end

local function drawConsoleUI()
    local w, h = term.getSize()
    local title = "--- LOG ---" .. (filterId and (" [ID:" .. filterId .. "]") or " [Alle]")
    drawHeaderTitle(1, title, colors.cyan)

    local listHeight = h - 4
    local currentLogs = getFilteredLogs()
    local yCursor = 3
    local startIndex = scrollOffset + 1

    for i = startIndex, #currentLogs do
        local entry = currentLogs[i]
        if yCursor > 2 + listHeight then break end

        local statusStr = entry.ok and "[OK]" or "[FEHL]"
        if yCursor <= 2 + listHeight then
            term.setCursorPos(2, yCursor)
            term.setTextColor(entry.ok and colors.green or colors.red)
            term.write(string.format("[%s] %s", entry.time, statusStr):sub(1, w - 2))
            yCursor = yCursor + 1
        end

        if yCursor <= 2 + listHeight then
            term.setCursorPos(4, yCursor)
            term.setTextColor(colors.white)
            term.write(entry.label:sub(1, w - 4))
            yCursor = yCursor + 1
        end

        local remText = entry.text
        while #remText > 0 and yCursor <= 2 + listHeight do
            term.setCursorPos(4, yCursor)
            term.setTextColor(colors.lightGray)
            term.write(remText:sub(1, w - 4))
            remText = remText:sub(w - 3)
            yCursor = yCursor + 1
        end
    end

    if #currentLogs == 0 then
        term.setCursorPos(2, 4)
        term.setTextColor(colors.gray)
        term.write("Keine Log-Eintraege.")
    end

    addButton("nav_main", 2, h, 8, " [BACK] ")
    addButton("console_clr", 11, h, 7, " [CLR] ")
    addButton("console_flt", 19, h, 7, " [FLT] ")
end

local function drawTerminalsUI()
    local w, h = term.getSize()
    
    local title = "--- ALLE GERAETE ---"
    local titleCol = colors.yellow
    if terminalFilter == "doors" then
        title = "--- TUERSENSOREN ---"
        titleCol = colors.green
    elseif terminalFilter == "terminals" then
        title = "--- TERMINALS ---"
        titleCol = colors.orange
    elseif terminalFilter == "signs" then
        title = "--- TEXTANZEIGEN ---"
        titleCol = colors.lime
    elseif terminalFilter == "gps" then
        title = "--- GPS-HOSTS ---"
        titleCol = colors.cyan
    elseif terminalFilter == "speakers" then
        title = "--- LAUTSPRECHER ---"
        titleCol = colors.orange
    end
    drawHeaderTitle(1, title, titleCol)

    local listHeight = h - 4
    local termList = getTerminalsList(terminalFilter)
    local yCursor = 3
    local startIndex = scrollOffset + 1

    for i = startIndex, #termList do
        local tData = termList[i]
        if yCursor > 2 + listHeight then break end

        if yCursor <= 2 + listHeight then
            term.setCursorPos(2, yCursor)
            term.setTextColor(colors.green)
            local displayLabel = tData.label or ("ID " .. tostring(tData.id))
            if tData.devType == "sign" and tData.preview and #tostring(tData.preview) > 0 then
                displayLabel = "\"" .. tostring(tData.preview) .. "\""
            elseif (tData.devType == "gps" or tData.devType == "speaker") and tData.preview and #tostring(tData.preview) > 0 then
                displayLabel = "[" .. tostring(tData.preview) .. "]"
            end
            local line1 = string.format("ID:%d | %s", tData.id, displayLabel)
            term.write(line1:sub(1, w - 2))
            yCursor = yCursor + 1
        end

        if yCursor <= 2 + listHeight then
            term.setCursorPos(4, yCursor)
            term.setTextColor(colors.lightGray)
            local line2 = string.format("Pos: %s", tostring(tData.pos or "Unbekannt"))
            term.write(line2:sub(1, w - 4))
            yCursor = yCursor + 1
        end
    end

    if #termList == 0 then
        term.setCursorPos(2, 4)
        term.setTextColor(colors.gray)
        term.write("Keine Geraete gefunden.")
    end

    if #debugLogs > 0 then
        term.setCursorPos(2, h - 1)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        local dStr = debugLogs[#debugLogs].text:sub(1, w - 2)
        term.write(dStr .. string.rep(" ", math.max(0, w - 2 - #dStr)))
    end

    addButton("nav_verw_geraete", 1, h, 6, " BACK ")
    addButton("geraete_del", 8, h, 5, " DEL ")
    addButton("geraete_clr", 14, h, 5, " CLR ")
    addButton("geraete_ref", 20, h, 5, " REF ")
end

local function drawUI()
    term.setBackgroundColor(colors.black)
    term.clear()
    clearButtons()

    if viewMode == "main" then drawMainUI()
    elseif viewMode == "verw_main" then drawVerwaltungMainUI()
    elseif viewMode == "verw_geraete" then drawVerwGeraeteUI()
    elseif viewMode == "verw_updates" then drawVerwUpdatesUI()
    elseif viewMode == "verw_settings" then drawVerwSettingsUI()
    elseif viewMode == "verw_settings_doors" then drawVerwSettingsDoorsUI()
    elseif viewMode == "verw_settings_signs" then drawVerwSettingsSignsUI()
    elseif viewMode == "verw_settings_gps" then drawVerwSettingsGpsUI()
    elseif viewMode == "verw_settings_spk" then drawVerwSettingsSpkUI()
    elseif viewMode == "sign_blink" then drawSignBlinkUI()
    elseif viewMode == "console" then drawConsoleUI()
    elseif viewMode == "terminals" then drawTerminalsUI()
    elseif viewMode == "range" then drawRangeUI()
    end
end

-- ==================================
-- KOMMENTAR: DIALOG EINGABEN, SELBST-UPDATE & AKTIONEN
-- ==================================
local function applyMasterSelfUpdate()
    addDebugMsg("Lade Master-Update von GitHub...")
    drawUI()

    local function fail(reason)
        addLog(0, false, "Master-Update fehlgeschlagen: " .. reason, "Master", "Master", nil)
        addDebugMsg("Fehler: " .. reason)
        return false
    end

    if not http then
        return fail("HTTP-API inaktiv")
    end

    local url = GITHUB_URL_MASTER .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local res, httpErr, failResp = http.get(url)
    if not res then
        local why = tostring(httpErr)
        if failResp and failResp.getResponseCode then
            why = "HTTP " .. tostring(failResp.getResponseCode())
            pcall(failResp.close)
        end
        return fail("Download (" .. why:sub(1, 18) .. ")")
    end

    local content = res.readAll()
    res.close()

    if not content or #content == 0 then
        return fail("Datei leer")
    end

    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return fail("HTML statt Code erhalten")
    end

    local tf = fs.open(TEMP_FILE, "w")
    if not tf then
        return fail("Temp nicht schreibbar")
    end
    tf.write(content)
    tf.close()

    local compiled = loadfile(TEMP_FILE)
    fs.delete(TEMP_FILE)
    if not compiled then
        return fail("Syntaxfehler im Code")
    end

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists("startup.lua") then
        pcall(fs.copy, "startup.lua", BACKUP_FILE)
    elseif fs.exists("startup") then
        pcall(fs.copy, "startup", BACKUP_FILE)
    end

    local f = fs.open("startup.lua", "w")
    if not f then
        return fail("Schreibfehler startup.lua")
    end
    f.write(content)
    f.close()

    if fs.exists("startup") then fs.delete("startup") end

    addLog(0, true, "Master-Update installiert (GitHub)", "Master", "Master", nil)
    addDebugMsg("Update installiert! Neustart...")
    drawUI()
    sleep(1.5)
    os.reboot()
end

local function editInput(prompt, allowNumbersOnly)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(2, 2)
    term.write(prompt)
    term.setCursorPos(2, 4)
    write("> ")
    local input = read()
    if allowNumbersOnly then return tonumber(input) end
    if input and #input > 0 then return input:gsub("^%s+", ""):gsub("%s+$", "") end
    return nil
end

local function handleAction(id)
    if id == "nav_main" then viewMode = "main"
    elseif id == "nav_console" then viewMode = "console"
    elseif id == "nav_verw_main" then viewMode = "verw_main"; scrollOffset = 0
    elseif id == "nav_verw_geraete" then viewMode = "verw_geraete"; scrollOffset = 0
    elseif id == "nav_verw_updates" then viewMode = "verw_updates"; scrollOffset = 0
    elseif id == "nav_verw_settings" then viewMode = "verw_settings"; scrollOffset = 0
    elseif id == "nav_verw_settings_doors" or id == "verw_settings_doors" then viewMode = "verw_settings_doors"; scrollOffset = 0
    elseif id == "nav_verw_settings_signs" then viewMode = "verw_settings_signs"; scrollOffset = 0
    elseif id == "nav_verw_settings_gps" then viewMode = "verw_settings_gps"; scrollOffset = 0
    elseif id == "nav_verw_settings_spk" then
        spkCfg.editEmergencyUrl = spkCfg.emergencyUrl or ""
        spkCfg.editLockdownUrl  = spkCfg.lockdownUrl or ""
        spkCfg.editAlarmVol     = spkCfg.alarmVol or 100
        viewMode = "verw_settings_spk"
        scrollOffset = 0
    elseif id == "nav_sign_blink" then
        editSignSplitBlink = signSplitBlink
        editSignBlinkOn    = signBlinkOn
        editSignBlinkOff   = signBlinkOff
        viewMode = "sign_blink"
        scrollOffset = 0
    elseif id == "nav_range" or id == "range" then viewMode = "range"; scrollOffset = 0

    -- Direkt-Updates ueber GitHub ausloesen
    elseif id == "update_terminals" then
        rednet.broadcast({ action = "update" }, UPDATE_PROTOCOL_TERM)
        addLog(0, true, "Sende GitHub-Update: Terminals", "Master", "Master", nil)
        addDebugMsg("Update an Terminals gesendet!")
    elseif id == "update_doors" then
        rednet.broadcast({ action = "update" }, UPDATE_PROTOCOL_DOOR)
        addLog(0, true, "Sende GitHub-Update: Tueren", "Master", "Master", nil)
        addDebugMsg("Update an Tueren gesendet!")
    elseif id == "update_signs" then
        rednet.broadcast({ action = "update" }, UPDATE_PROTOCOL_SIGN)
        addLog(0, true, "Sende GitHub-Update: Anzeigen", "Master", "Master", nil)
        addDebugMsg("Update an Anzeigen gesendet!")
    elseif id == "update_gps" then
        rednet.broadcast({ action = "update" }, UPDATE_PROTOCOL_GPS)
        rednet.broadcast({ action = "update_gps" }, UPDATE_PROTOCOL_SIGN)
        addLog(0, true, "Sende GitHub-Update: GPS-Hosts", "Master", "Master", nil)
        addDebugMsg("Update an GPS-Hosts gesendet!")
    elseif id == "update_speakers" then
        rednet.broadcast({ action = "update" }, UPDATE_PROTOCOL_SPK)
        addLog(0, true, "Sende GitHub-Update: Lautsprecher", "Master", "Master", nil)
        addDebugMsg("Update an Lautsprecher gesendet!")
    elseif id == "update_master" then
        applyMasterSelfUpdate()
    
    elseif id == "terminals_all" then terminalFilter = nil; viewMode = "terminals"; scrollOffset = 0
    elseif id == "terminals_doors" then terminalFilter = "doors"; viewMode = "terminals"; scrollOffset = 0
    elseif id == "terminals_terms" then terminalFilter = "terminals"; viewMode = "terminals"; scrollOffset = 0
    elseif id == "terminals_signs" then terminalFilter = "signs"; viewMode = "terminals"; scrollOffset = 0
    elseif id == "terminals_gps" then terminalFilter = "gps"; viewMode = "terminals"; scrollOffset = 0
    elseif id == "terminals_speakers" then terminalFilter = "speakers"; viewMode = "terminals"; scrollOffset = 0
    
    elseif id == "geraete_del" then
        local idNum = editInput("Geraete ID zum Loeschen:", true)
        if idNum and registeredTerminals[idNum] then
            registeredTerminals[idNum] = nil
            saveTerminals()
            addDebugMsg("Geraet ID " .. tostring(idNum) .. " geloescht.")
        else
            addDebugMsg("ID nicht gefunden.")
        end
        scrollOffset = 0
    elseif id == "geraete_clr" then
        registeredTerminals = {}
        saveTerminals()
        scrollOffset = 0
        addDebugMsg("Geraeteliste geleert.")
    elseif id == "geraete_ref" then
        -- Sendet Status-Request an alle Geraete-Typen inklusive GPS-Hosts & Lautsprecher!
        rednet.broadcast("STATUS_REQUEST", STATUS_PROTOCOL)
        rednet.broadcast("STATUS_REQUEST", UPDATE_PROTOCOL_TERM)
        rednet.broadcast("STATUS_REQUEST", CONFIG_PROTOCOL_DOOR)
        rednet.broadcast("STATUS_REQUEST", CONFIG_PROTOCOL_SIGN)
        rednet.broadcast("STATUS_REQUEST", UPDATE_PROTOCOL_SIGN)
        rednet.broadcast("STATUS_REQUEST", CONFIG_PROTOCOL_GPS)
        rednet.broadcast("STATUS_REQUEST", UPDATE_PROTOCOL_GPS)
        rednet.broadcast("STATUS_REQUEST", CONFIG_PROTOCOL_SPK)
        rednet.broadcast("STATUS_REQUEST", UPDATE_PROTOCOL_SPK)
        addDebugMsg("Ping an alle Geraete gesendet...")
    
    elseif id == "console_clr" then
        logEntries = {}; scrollOffset = 0
    elseif id == "console_flt" then
        filterId = editInput("ID-Filter (Leer = Alle):", true)
        scrollOffset = 0
    
    elseif id == "action_range" then
        local newRange = editInput("Reichweite (1-30):", true)
        if newRange and newRange >= 1 and newRange <= 30 then
            currentRange = newRange
            saveMasterConfig()
            rednet.broadcast({ action = "set_range", range = currentRange }, CONFIG_PROTOCOL_DOOR)
            addLog(0, true, "Sende Reichweite " .. currentRange, "Master", "Master", nil)
            addDebugMsg("Reichweite auf " .. currentRange .. " geaendert und gesendet.")
        else
            addDebugMsg("Fehler: Ungueltige Eingabe (1-30).")
        end

    -- Einstellungen: GPS-Hosts gleichzeitig anhand ihrer gespeicherten Coords relocaten
    elseif id == "action_relocate_gps" then
        rednet.broadcast({ action = "relocate" }, CONFIG_PROTOCOL_GPS)
        rednet.broadcast({ action = "relocate" }, UPDATE_PROTOCOL_GPS)
        addLog(0, true, "Sende Relocate an alle GPS-Hosts", "Master", "Master", nil)
        addDebugMsg("Relocate-Befehl an alle GPS-Hosts gesendet.")

    -- Einstellungen: Lautsprecher Alarm-Konfiguration
    elseif id == "spk_edit_em" then
        local val = editInput("Emergency-Link (-=Leer):", false)
        if val == "-" then
            spkCfg.editEmergencyUrl = ""
        elseif val then
            spkCfg.editEmergencyUrl = val
        end
    elseif id == "spk_edit_ld" then
        local val = editInput("Lockdown-Link (-=Leer):", false)
        if val == "-" then
            spkCfg.editLockdownUrl = ""
        elseif val then
            spkCfg.editLockdownUrl = val
        end
    elseif id == "spk_vol_dec" then
        spkCfg.editAlarmVol = math.max(0, (spkCfg.editAlarmVol or 100) - 10)
    elseif id == "spk_vol_inc" then
        spkCfg.editAlarmVol = math.min(100, (spkCfg.editAlarmVol or 100) + 10)
    elseif id == "spk_send_alarm" then
        spkCfg.emergencyUrl = spkCfg.editEmergencyUrl or ""
        spkCfg.lockdownUrl  = spkCfg.editLockdownUrl or ""
        spkCfg.alarmVol     = spkCfg.editAlarmVol or 100
        saveMasterConfig()
        rednet.broadcast({
            action       = "set_alarm_config",
            emergencyUrl = spkCfg.emergencyUrl,
            lockdownUrl  = spkCfg.lockdownUrl,
            alarmVol     = spkCfg.alarmVol,
            alarmVolPct  = spkCfg.alarmVol,
            isReply      = false
        }, CONFIG_PROTOCOL_SPK)
        addLog(0, true, string.format("Sende Speaker-Alarm-Sync (Vol:%d%%)", spkCfg.alarmVol), "Master", "Master", nil)
        addDebugMsg("Gespeichert und an alle Speaker gesendet.")

    elseif id == "toggle_sign_split" then
        editSignSplitBlink = not editSignSplitBlink
        if not editSignSplitBlink then
            editSignBlinkOff = editSignBlinkOn
        end
    elseif id == "sign_on_dec" then
        editSignBlinkOn = math.max(0.10, round(editSignBlinkOn - 0.10, 0.10))
        if not editSignSplitBlink then editSignBlinkOff = editSignBlinkOn end
    elseif id == "sign_on_inc" then
        editSignBlinkOn = math.min(3.00, round(editSignBlinkOn + 0.10, 0.10))
        if not editSignSplitBlink then editSignBlinkOff = editSignBlinkOn end
    elseif id == "sign_off_dec" then
        editSignBlinkOff = math.max(0.00, round(editSignBlinkOff - 0.10, 0.10))
    elseif id == "sign_off_inc" then
        editSignBlinkOff = math.min(3.00, round(editSignBlinkOff + 0.10, 0.10))
    elseif id == "send_sign_blink" then
        if not editSignSplitBlink then editSignBlinkOff = editSignBlinkOn end
        signSplitBlink = editSignSplitBlink
        signBlinkOn    = editSignBlinkOn
        signBlinkOff   = editSignBlinkOff
        saveMasterConfig()
        rednet.broadcast({
            action     = "set_blink",
            splitBlink = signSplitBlink,
            blinkOn    = signBlinkOn,
            blinkOff   = signBlinkOff,
            isReply    = false
        }, CONFIG_PROTOCOL_SIGN)
        addLog(0, true, string.format("Sende Blink-Sync (AN:%.2fs AUS:%.2fs)", signBlinkOn, signBlinkOff), "Master", "Master", nil)
        addDebugMsg("Gespeichert und an alle Anzeigen gesendet.")
    end
end

-- ==================================
-- KOMMENTAR: HAUPTSCHLEIFE
-- ==================================
local function main()
    tickTimer = os.startTimer(0.5)
    drawUI()

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "mouse_click" then
            local x, y = p2, p3
            local clicked = nil
            for _, btn in ipairs(currentButtons) do
                if y == btn.y and x >= btn.x1 and x <= btn.x2 then
                    clicked = btn
                    break
                end
            end

            if clicked then
                term.setCursorPos(clicked.x1, clicked.y)
                term.setBackgroundColor(colors.orange)
                term.setTextColor(colors.black)
                local w = clicked.x2 - clicked.x1 + 1
                local padL = math.floor((w - #clicked.text) / 2)
                local padR = w - #clicked.text - padL
                term.write(string.rep(" ", padL) .. clicked.text .. string.rep(" ", padR))
                
                sleep(0.15)
                handleAction(clicked.id)
                tickTimer = os.startTimer(0.5)
                drawUI()
            end

        elseif event == "mouse_scroll" then
            if viewMode == "console" or viewMode == "terminals" then
                local maxOff = (viewMode == "console") and math.max(0, #getFilteredLogs() - 1) or math.max(0, #getTerminalsList(terminalFilter) - 1)
                scrollOffset = math.max(0, math.min(maxOff, scrollOffset + p1))
                drawUI()
            end

        elseif event == "char" and (p1 == "q" or p1 == "Q") then
            if viewMode == "main" then break else viewMode = "main"; drawUI() end

        elseif event == "rednet_message" then
            local id, message, protocol = p1, p2, p3

            if (protocol == UPDATE_PROTOCOL_TERM or protocol == UPDATE_PROTOCOL_DOOR or protocol == UPDATE_PROTOCOL_SIGN or protocol == UPDATE_PROTOCOL_GPS or protocol == UPDATE_PROTOCOL_SPK or protocol == CONFIG_PROTOCOL_DOOR or protocol == CONFIG_PROTOCOL_SIGN or protocol == CONFIG_PROTOCOL_GPS or protocol == CONFIG_PROTOCOL_SPK) and type(message) == "table" then
                if message.action == "log_report" then
                    addLog(id, message.success, message.details, message.pos, message.label, protocol, message.preview, message.devType)
                    if viewMode == "console" or viewMode == "terminals" then drawUI() end
                elseif protocol == CONFIG_PROTOCOL_SIGN and message.action == "request_blink_sync" then
                    rednet.send(id, {
                        action     = "set_blink",
                        splitBlink = signSplitBlink,
                        blinkOn    = signBlinkOn,
                        blinkOff   = signBlinkOff,
                        isReply    = true
                    }, CONFIG_PROTOCOL_SIGN)
                elseif protocol == CONFIG_PROTOCOL_SPK and message.action == "request_speaker_sync" then
                    rednet.send(id, {
                        action       = "set_alarm_config",
                        emergencyUrl = spkCfg.emergencyUrl or "",
                        lockdownUrl  = spkCfg.lockdownUrl or "",
                        alarmVol     = spkCfg.alarmVol or 100,
                        alarmVolPct  = spkCfg.alarmVol or 100,
                        isReply      = true
                    }, CONFIG_PROTOCOL_SPK)
                end
            elseif protocol == STATUS_PROTOCOL and (message == "EMERGENCY_ON" or message == "EMERGENCY_OFF") then
                local existingPos = registeredTerminals[id] and registeredTerminals[id].pos or "Terminal"
                local existingLbl = registeredTerminals[id] and registeredTerminals[id].label or ("Terminal " .. tostring(id))
                addLog(id, true, "Online (" .. tostring(message) .. ")", existingPos, existingLbl, UPDATE_PROTOCOL_TERM, nil, "terminal")
                if viewMode == "console" or viewMode == "terminals" then drawUI() end
            end

        elseif event == "timer" and p1 == tickTimer then
            tickTimer = os.startTimer(0.5)
            local t = os.epoch("utc") / 1000
            local changed = false
            for i = #debugLogs, 1, -1 do
                if debugLogs[i].expires <= t then
                    table.remove(debugLogs, i)
                    changed = true
                end
            end
            if changed then
                drawUI()
            end
        end
    end
end

-- ==================================
-- KOMMENTAR: SCHUTZ-WRAPPER
-- ==================================
local ok, err = pcall(main)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if not ok and err ~= "Terminated" then
    print("Fehler in der Master-Control: " .. tostring(err))
end