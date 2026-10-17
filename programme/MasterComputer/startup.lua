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

-- Zentrale Alarm-Sound- & Radio-Einstellungen fuer alle Lautsprecher (Upvalue-gebuendelt)
local spkCfg = {
    emergencyUrl      = "",
    emergencyTitle    = "",
    lockdownUrl       = "",
    lockdownTitle     = "",
    alarmVol          = 100,
    editEmergencyUrl  = "",
    editEmergencyTitle = "",
    editLockdownUrl   = "",
    editLockdownTitle = "",
    editAlarmVol      = 100,
    radioPlaylist     = {},
    editRadioPlaylist = {},
    selectedTrackIdx  = nil,
    radioScrollOffset = 0,
    marqueeOffset     = 0
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

local function extractYoutubeId(input)
    local str = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local id = str:match("youtu%.be/([%w%-_]+)")
    if id and #id == 11 then return id end
    id = str:match("[?&]v=([%w%-_]+)")
    if id and #id == 11 then return id end
    id = str:match("embed/([%w%-_]+)")
    if id and #id == 11 then return id end
    id = str:match("shorts/([%w%-_]+)")
    if id and #id == 11 then return id end
    if #str == 11 and str:match("^[%w%-_]+$") then return str end
    return ""
end

local function getMarqueeText(str, maxLen, offset)
    local s = tostring(str or "")
    if #s <= maxLen then
        return s .. string.rep(" ", maxLen - #s)
    end
    local spacer = "   ---   "
    local full = s .. spacer
    local startIdx = ((offset or 0) % #full) + 1
    local repeated = full .. full
    return repeated:sub(startIdx, startIdx + maxLen - 1)
end

spkCfg.cleanTitle = function(raw)
    local s = tostring(raw or "")
    s = s:gsub("\195\164", "ae"):gsub("\195\182", "oe"):gsub("\195\188", "ue")
    s = s:gsub("\195\132", "Ae"):gsub("\195\150", "Oe"):gsub("\195\156", "Ue"):gsub("\195\159", "ss")
    s = s:gsub("\226\128\147", "-"):gsub("\226\128\148", "-")
    s = s:gsub("[^\32-\126]", "")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

spkCfg.isBadTitle = function(t, id)
    local s = tostring(t or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return true end
    if id and s == tostring(id) then return true end
    local low = s:lower()
    if low:find("help me keep") or low:find("hosting is expensive") or low:find("patreon") then return true end
    if low:find("http://") or low:find("https://") or low:find("youtu%.be") or low:find("youtube%.com") then return true end
    return false
end

spkCfg.fetchVideoInfo = function(input)
    local trimmed = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return "", "" end
    local vid = extractYoutubeId(trimmed)

    -- 1. Offizielle YouTube oEmbed API fuer den echten Videonamen (funktioniert auch bei ungelisteten Videos)
    if vid ~= "" and http then
        local oUrl = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=" .. vid .. "&format=json"
        local res = http.get(oUrl)
        if res then
            local body = res.readAll()
            res.close()
            local data = textutils.unserializeJSON(body)
            if type(data) == "table" and type(data.title) == "string" and #data.title > 0 then
                local clean = spkCfg.cleanTitle(data.title)
                if clean ~= "" then return vid, clean end
            end
        end
        local nUrl = "https://noembed.com/embed?url=https://www.youtube.com/watch?v=" .. vid
        local nRes = http.get(nUrl)
        if nRes then
            local nBody = nRes.readAll()
            nRes.close()
            local nData = textutils.unserializeJSON(nBody)
            if type(nData) == "table" and type(nData.title) == "string" and #nData.title > 0 then
                local clean = spkCfg.cleanTitle(nData.title)
                if clean ~= "" then return vid, clean end
            end
        end
    end

    -- 2. Fallback / Text-Suche ueber Cloud-API (ignoriert den Patreon-Werbeeintrag auf Platz 1!)
    if http then
        local q = (vid ~= "") and vid or trimmed
        local sUrl = "https://ipod-2to6magyna-uc.a.run.app/?v=2.1&search=" .. textutils.urlEncode(q)
        local res = http.get(sUrl)
        if res then
            local body = res.readAll()
            res.close()
            local list = textutils.unserializeJSON(body)
            if type(list) == "table" then
                for _, item in ipairs(list) do
                    if type(item) == "table" and type(item.id) == "string" and item.id ~= "9Se1cKmJ_Ik" then
                        local nameClean = spkCfg.cleanTitle(item.name)
                        if not spkCfg.isBadTitle(nameClean, item.id) then
                            if vid == "" or item.id == vid then
                                return item.id, nameClean
                            end
                        end
                    end
                end
            end
        end
    end

    if vid ~= "" then
        return vid, "YouTube-Video"
    end
    return "", ""
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

local function hasPendingRadioChanges()
    local aList = spkCfg.radioPlaylist or {}
    local bList = spkCfg.editRadioPlaylist or {}
    if #aList ~= #bList then return true end
    for i = 1, #aList do
        local a = aList[i]
        local b = bList[i]
        if not b or a.id ~= b.id or a.title ~= b.title then return true end
    end
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
            currentRange      = currentRange,
            signSplitBlink    = signSplitBlink,
            signBlinkOn       = signBlinkOn,
            signBlinkOff      = signBlinkOff,
            spkEmergencyUrl   = spkCfg.emergencyUrl,
            spkEmergencyTitle = spkCfg.emergencyTitle,
            spkLockdownUrl    = spkCfg.lockdownUrl,
            spkLockdownTitle  = spkCfg.lockdownTitle,
            spkAlarmVol       = spkCfg.alarmVol,
            spkRadioPlaylist  = spkCfg.radioPlaylist
        }))
        f.close()
    end
end

local function loadMasterConfig()
    local repaired = false
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
                if type(data.spkEmergencyTitle) == "string" then spkCfg.emergencyTitle = spkCfg.cleanTitle(data.spkEmergencyTitle) end
                if type(data.spkLockdownUrl) == "string" then spkCfg.lockdownUrl = data.spkLockdownUrl end
                if type(data.spkLockdownTitle) == "string" then spkCfg.lockdownTitle = spkCfg.cleanTitle(data.spkLockdownTitle) end
                if type(data.spkAlarmVol) == "number" then spkCfg.alarmVol = math.max(0, math.min(100, data.spkAlarmVol)) end
                if type(data.spkRadioPlaylist) == "table" then
                    spkCfg.radioPlaylist = {}
                    for _, t in ipairs(data.spkRadioPlaylist) do
                        if type(t) == "table" and t.id then
                            local vid = tostring(t.id)
                            local ttl = spkCfg.cleanTitle(t.title or "")
                            if spkCfg.isBadTitle(ttl, vid) then
                                local _, realTitle = spkCfg.fetchVideoInfo(vid)
                                if realTitle ~= "" then ttl = realTitle; repaired = true end
                            end
                            table.insert(spkCfg.radioPlaylist, { id = vid, title = (ttl ~= "" and ttl or "YouTube-Video") })
                        end
                    end
                end
            end
        end
    end
    if spkCfg.emergencyUrl ~= "" and spkCfg.isBadTitle(spkCfg.emergencyTitle, extractYoutubeId(spkCfg.emergencyUrl)) then
        local _, realEm = spkCfg.fetchVideoInfo(spkCfg.emergencyUrl)
        if realEm ~= "" then spkCfg.emergencyTitle = realEm; repaired = true end
    end
    if spkCfg.lockdownUrl ~= "" and spkCfg.isBadTitle(spkCfg.lockdownTitle, extractYoutubeId(spkCfg.lockdownUrl)) then
        local _, realLd = spkCfg.fetchVideoInfo(spkCfg.lockdownUrl)
        if realLd ~= "" then spkCfg.lockdownTitle = realLd; repaired = true end
    end
    if repaired then
        saveMasterConfig()
    end
    editSignSplitBlink        = signSplitBlink
    editSignBlinkOn           = signBlinkOn
    editSignBlinkOff          = signBlinkOff
    spkCfg.editEmergencyUrl   = spkCfg.emergencyUrl
    spkCfg.editEmergencyTitle = spkCfg.emergencyTitle
    spkCfg.editLockdownUrl    = spkCfg.lockdownUrl
    spkCfg.editLockdownTitle  = spkCfg.lockdownTitle
    spkCfg.editAlarmVol       = spkCfg.alarmVol
    spkCfg.editRadioPlaylist  = {}
    for _, t in ipairs(spkCfg.radioPlaylist or {}) do
        table.insert(spkCfg.editRadioPlaylist, { id = t.id, title = t.title })
    end
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
    if viewMode == "verw_settings_spk" then
        drawHeaderTitle(2, "--- LAUTSPRECHER ---", colors.orange)

        drawMenuButton("nav_spk_alert", 5, "ALERT", colors.gray)
        drawMenuButton("nav_spk_radio", 7, "RADIO", colors.gray)
        drawMenuButton("nav_verw_settings", 14, "ZURUECK", colors.lightGray)

        drawDebugOverlay(15)
        return
    end

    local w = term.getSize()
    drawHeaderTitle(1, "--- SPEAKER ALERT ---", colors.orange)

    local boxW   = math.min(22, w - 2)
    local startX = math.floor((w - boxW) / 2) + 1

    term.setCursorPos(startX, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.write("Emergency Sound:")
    local hasEm   = (#(spkCfg.editEmergencyUrl or "") > 0)
    local emTitle = (hasEm and #(spkCfg.editEmergencyTitle or "") > 0) and spkCfg.editEmergencyTitle or (hasEm and "YouTube-Video" or "[ Link eingeben ]")
    local emDisp  = getMarqueeText(emTitle, boxW, spkCfg.marqueeOffset)
    addButton("spk_edit_em", startX, 4, boxW, emDisp, colors.gray, hasEm and colors.white or colors.lightGray)

    term.setCursorPos(startX, 6)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.orange)
    term.write("Lockdown Sound:")
    local hasLd   = (#(spkCfg.editLockdownUrl or "") > 0)
    local ldTitle = (hasLd and #(spkCfg.editLockdownTitle or "") > 0) and spkCfg.editLockdownTitle or (hasLd and "YouTube-Video" or "[ Link eingeben ]")
    local ldDisp  = getMarqueeText(ldTitle, boxW, spkCfg.marqueeOffset)
    addButton("spk_edit_ld", startX, 7, boxW, ldDisp, colors.gray, hasLd and colors.white or colors.lightGray)

    term.setCursorPos(startX, 9)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    local vol = tonumber(spkCfg.editAlarmVol) or 100
    term.write(string.format("Vol: %d%%", vol))
    addButton("spk_vol_dec", startX + 10, 9, 5, "-10%", colors.gray)
    addButton("spk_vol_inc", startX + 17, 9, 5, "+10%", colors.gray)

    local isDirty = hasPendingSpkChanges()
    drawMenuButton(
        "spk_send_alarm",
        12,
        "SPEICHERN & SENDEN",
        isDirty and colors.orange or colors.gray,
        isDirty and colors.black or colors.white
    )
    drawMenuButton("nav_spk_settings", 14, "ZURUECK", colors.lightGray)

    drawDebugOverlay(15)
end

local function drawVerwSettingsSpkRadioUI()
    local w = term.getSize()
    drawHeaderTitle(1, "--- SPEAKER RADIO ---", colors.yellow)

    local boxW   = math.min(22, w - 2)
    local startX = math.floor((w - boxW) / 2) + 1

    -- Button neuer Track
    addButton("radio_add_track", startX, 3, boxW, "[+] TRACK ZUFUEGEN", colors.green, colors.black)

    local list = spkCfg.editRadioPlaylist or {}
    local maxVisible = 4
    local startIdx = (spkCfg.radioScrollOffset or 0) + 1
    local endIdx = math.min(#list, startIdx + maxVisible - 1)

    term.setCursorPos(startX, 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write(string.format("Tracks: %d", #list))

    -- Scroll Pfeile oben rechts
    if #list > maxVisible then
        if (spkCfg.radioScrollOffset or 0) > 0 then
            addButton("radio_scroll_up", startX + boxW - 5, 4, 2, "^", colors.lightGray, colors.black)
        end
        if endIdx < #list then
            addButton("radio_scroll_dn", startX + boxW - 2, 4, 2, "v", colors.lightGray, colors.black)
        end
    end

    local yCursor = 5
    for i = startIdx, endIdx do
        local trk = list[i]
        local isSel = (spkCfg.selectedTrackIdx == i)
        local bgCol = isSel and colors.cyan or colors.gray
        local fgCol = isSel and colors.black or colors.white
        local cleanName = (trk.title and not spkCfg.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"
        local titleStr = string.format("%d. %s", i, cleanName)
        local dispText = getMarqueeText(titleStr, boxW, spkCfg.marqueeOffset or 0)
        addButton("radio_track_" .. i, startX, yCursor, boxW, dispText, bgCol, fgCol)
        yCursor = yCursor + 1
    end

    if #list == 0 then
        term.setCursorPos(startX, 6)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.write("Keine Tracks vorhanden.")
    end

    -- Aktionen fuer selektierten Track (Zeilen 10 & 11)
    if spkCfg.selectedTrackIdx and list[spkCfg.selectedTrackIdx] then
        addButton("radio_move_up", startX, 10, 10, "^ HOCH", colors.gray)
        addButton("radio_move_dn", startX + 12, 10, 10, "v RUNTER", colors.gray)
        addButton("radio_del_track", startX, 11, boxW, "X LOESCHEN", colors.red, colors.white)
    else
        term.setCursorPos(startX, 10)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.write("[ Track oben waehlen ]")
    end

    local isDirty = hasPendingRadioChanges()
    drawMenuButton(
        "radio_save_send",
        13,
        "SPEICHERN & SENDEN",
        isDirty and colors.orange or colors.gray,
        isDirty and colors.black or colors.white
    )
    drawMenuButton("nav_spk_settings", 15, "ZURUECK", colors.lightGray)

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
    elseif viewMode == "verw_settings_spk" or viewMode == "verw_settings_spk_alert" then drawVerwSettingsSpkUI()
    elseif viewMode == "verw_settings_spk_radio" then drawVerwSettingsSpkRadioUI()
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
    elseif id == "nav_verw_settings_spk" or id == "nav_spk_settings" then
        viewMode = "verw_settings_spk"
        scrollOffset = 0
    elseif id == "nav_spk_alert" then
        spkCfg.editEmergencyUrl   = spkCfg.emergencyUrl or ""
        spkCfg.editEmergencyTitle = spkCfg.emergencyTitle or ""
        spkCfg.editLockdownUrl    = spkCfg.lockdownUrl or ""
        spkCfg.editLockdownTitle  = spkCfg.lockdownTitle or ""
        spkCfg.editAlarmVol       = spkCfg.alarmVol or 100
        viewMode = "verw_settings_spk_alert"
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

    -- Einstellungen: Lautsprecher Alarm- & Radio-Konfiguration
    elseif id == "nav_spk_radio" then
        spkCfg.selectedTrackIdx  = nil
        spkCfg.radioScrollOffset = 0
        spkCfg.editRadioPlaylist = {}
        for _, t in ipairs(spkCfg.radioPlaylist or {}) do
            table.insert(spkCfg.editRadioPlaylist, { id = t.id, title = t.title })
        end
        viewMode = "verw_settings_spk_radio"
        scrollOffset = 0
    elseif id == "radio_scroll_up" then
        spkCfg.radioScrollOffset = math.max(0, (spkCfg.radioScrollOffset or 0) - 1)
    elseif id == "radio_scroll_dn" then
        local maxOff = math.max(0, #(spkCfg.editRadioPlaylist or {}) - 4)
        spkCfg.radioScrollOffset = math.min(maxOff, (spkCfg.radioScrollOffset or 0) + 1)
    elseif id:match("^radio_track_(%d+)$") then
        local sel = tonumber(id:match("^radio_track_(%d+)$"))
        if spkCfg.selectedTrackIdx == sel then
            spkCfg.selectedTrackIdx = nil
        else
            spkCfg.selectedTrackIdx = sel
        end
    elseif id == "radio_move_up" then
        local sel = spkCfg.selectedTrackIdx
        if sel and sel > 1 then
            local tmp = spkCfg.editRadioPlaylist[sel]
            spkCfg.editRadioPlaylist[sel] = spkCfg.editRadioPlaylist[sel - 1]
            spkCfg.editRadioPlaylist[sel - 1] = tmp
            spkCfg.selectedTrackIdx = sel - 1
        end
    elseif id == "radio_move_dn" then
        local sel = spkCfg.selectedTrackIdx
        if sel and sel < #(spkCfg.editRadioPlaylist or {}) then
            local tmp = spkCfg.editRadioPlaylist[sel]
            spkCfg.editRadioPlaylist[sel] = spkCfg.editRadioPlaylist[sel + 1]
            spkCfg.editRadioPlaylist[sel + 1] = tmp
            spkCfg.selectedTrackIdx = sel + 1
        end
    elseif id == "radio_del_track" then
        local sel = spkCfg.selectedTrackIdx
        if sel and spkCfg.editRadioPlaylist[sel] then
            table.remove(spkCfg.editRadioPlaylist, sel)
            spkCfg.selectedTrackIdx = nil
        end
    elseif id == "radio_add_track" then
        local input = editInput("YT-Link einfuegen:", false)
        if input and #input > 0 then
            addDebugMsg("Lade Videotitel...")
            drawUI()
            local vid, title = spkCfg.fetchVideoInfo(input)
            if vid ~= "" then
                table.insert(spkCfg.editRadioPlaylist, { id = vid, title = title })
                spkCfg.selectedTrackIdx = #spkCfg.editRadioPlaylist
                addDebugMsg("Gefunden: " .. title:sub(1, 14))
            else
                addDebugMsg("Fehler: Kein Video gefunden!")
            end
        end
    elseif id == "radio_save_send" then
        spkCfg.radioPlaylist = {}
        for _, t in ipairs(spkCfg.editRadioPlaylist or {}) do
            table.insert(spkCfg.radioPlaylist, { id = t.id, title = t.title })
        end
        saveMasterConfig()
        rednet.broadcast({
            action   = "set_radio_playlist",
            playlist = spkCfg.radioPlaylist
        }, CONFIG_PROTOCOL_SPK)
        addLog(0, true, string.format("Sende Radio (%d Tracks)", #spkCfg.radioPlaylist), "Master", "Master", nil)
        addDebugMsg(string.format("Radio gesendet (%d)", #spkCfg.radioPlaylist))

    elseif id == "spk_edit_em" then
        local val = editInput("Emergency-Link (-=Leer):", false)
        if val == "-" then
            spkCfg.editEmergencyUrl   = ""
            spkCfg.editEmergencyTitle = ""
        elseif val then
            addDebugMsg("Lade Videotitel...")
            drawUI()
            local vid, title = spkCfg.fetchVideoInfo(val)
            if vid ~= "" then
                spkCfg.editEmergencyUrl   = vid
                spkCfg.editEmergencyTitle = title
                addDebugMsg("Gefunden: " .. title:sub(1, 14))
            else
                addDebugMsg("Fehler: Kein Video gefunden!")
            end
        end
    elseif id == "spk_edit_ld" then
        local val = editInput("Lockdown-Link (-=Leer):", false)
        if val == "-" then
            spkCfg.editLockdownUrl   = ""
            spkCfg.editLockdownTitle = ""
        elseif val then
            addDebugMsg("Lade Videotitel...")
            drawUI()
            local vid, title = spkCfg.fetchVideoInfo(val)
            if vid ~= "" then
                spkCfg.editLockdownUrl   = vid
                spkCfg.editLockdownTitle = title
                addDebugMsg("Gefunden: " .. title:sub(1, 14))
            else
                addDebugMsg("Fehler: Kein Video gefunden!")
            end
        end
    elseif id == "spk_vol_dec" then
        spkCfg.editAlarmVol = math.max(0, (spkCfg.editAlarmVol or 100) - 10)
    elseif id == "spk_vol_inc" then
        spkCfg.editAlarmVol = math.min(100, (spkCfg.editAlarmVol or 100) + 10)
    elseif id == "spk_send_alarm" then
        spkCfg.emergencyUrl   = spkCfg.editEmergencyUrl or ""
        spkCfg.emergencyTitle = spkCfg.editEmergencyTitle or ""
        spkCfg.lockdownUrl    = spkCfg.editLockdownUrl or ""
        spkCfg.lockdownTitle  = spkCfg.editLockdownTitle or ""
        spkCfg.alarmVol       = spkCfg.editAlarmVol or 100
        saveMasterConfig()
        rednet.broadcast({
            action         = "set_alarm_config",
            emergencyUrl   = spkCfg.emergencyUrl,
            emergencyTitle = spkCfg.emergencyTitle,
            lockdownUrl    = spkCfg.lockdownUrl,
            lockdownTitle  = spkCfg.lockdownTitle,
            alarmVol       = spkCfg.alarmVol,
            alarmVolPct    = spkCfg.alarmVol,
            radioPlaylist  = spkCfg.radioPlaylist or {},
            isReply        = false
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
                elseif protocol == CONFIG_PROTOCOL_SPK and (message.action == "request_speaker_sync" or message.action == "request_radio_sync") then
                    rednet.send(id, {
                        action         = "set_alarm_config",
                        emergencyUrl   = spkCfg.emergencyUrl or "",
                        emergencyTitle = spkCfg.emergencyTitle or "",
                        lockdownUrl    = spkCfg.lockdownUrl or "",
                        lockdownTitle  = spkCfg.lockdownTitle or "",
                        alarmVol       = spkCfg.alarmVol or 100,
                        alarmVolPct    = spkCfg.alarmVol or 100,
                        radioPlaylist  = spkCfg.radioPlaylist or {},
                        isReply        = true
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
            spkCfg.marqueeOffset = (spkCfg.marqueeOffset or 0) + 1
            local t = os.epoch("utc") / 1000
            local changed = false
            for i = #debugLogs, 1, -1 do
                if debugLogs[i].expires <= t then
                    table.remove(debugLogs, i)
                    changed = true
                end
            end
            if changed or viewMode == "verw_settings_spk_radio" or viewMode == "verw_settings_spk_alert" then
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