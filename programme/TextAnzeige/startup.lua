-- ==================================
-- KOMMENTAR: TEXTANZEIGE & WEGWEISER SYSTEM (CC:Tweaked / ATM10)
-- Inklusive fehlerfreiem Start-Status-Check, nicht-blockierendem GPS-Cache,
-- buendigem Speichern/Sync-Layout, stabilen Timern & Master-Textvorschau.
-- (Upvalue-optimiert fuer das Lua 5.1 Limit von max. 60 Upvalues)
-- ==================================

local CFG = {
    PROTOCOL          = "notaus",
    LOCKDOWN_PROTOCOL = "lockdown",
    UPDATE_PROTOCOL   = "signs_update",
    CONFIG_PROTOCOL   = "signs_config",
    CONFIG_FILE       = "sign_config.txt",
    TEMP_FILE         = "startup.update_tmp",
    BACKUP_FILE       = "startup.backup",
    GITHUB_URL        = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/TextAnzeige/startup.lua",

    MASTER_ID   = 24,
    COMPUTER_ID = os.getComputerID(),

    MSG_ON     = "EMERGENCY_ON",
    MSG_OFF    = "EMERGENCY_OFF",
    MSG_LOCK   = "LOCKDOWN_ON",
    MSG_UNLOCK = "LOCKDOWN_OFF",
    MSG_STATUS = "STATUS_REQUEST",

    -- Alle von CC:Tweaked unterstuetzten Monitor-Skalierungen (0.5er Schritte)
    SCALES = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0},

    -- Auswaehlbare Textfarben fuer die einzelnen Zeilen
    TEXT_COLORS = {
        colors.white,
        colors.yellow,
        colors.orange,
        colors.red,
        colors.magenta,
        colors.pink,
        colors.purple,
        colors.blue,
        colors.lightBlue,
        colors.cyan,
        colors.lime,
        colors.green,
        colors.brown,
        colors.lightGray,
        colors.gray,
        colors.black
    },

    -- Auswaehlbare Hintergrundfarben fuer den gesamten Monitor (alle 16 Farben)
    BG_COLORS = {
        colors.black,
        colors.gray,
        colors.lightGray,
        colors.white,
        colors.blue,
        colors.lightBlue,
        colors.cyan,
        colors.green,
        colors.lime,
        colors.yellow,
        colors.orange,
        colors.brown,
        colors.red,
        colors.magenta,
        colors.pink,
        colors.purple
    },

    -- Einheitliche 0.10s Schritte fuer Alarm-Einblendung & Pause (Pause ab 0.00s!)
    BLINK_MIN     = 0.10,
    BLINK_OFF_MIN = 0.00,
    BLINK_MAX     = 3.00,
    BLINK_STEP    = 0.10,

    -- Einheitliche 0.10s Schritte fuer Laufschrift-Tempo
    SPEED_MIN  = 0.10,
    SPEED_MAX  = 1.00,
    SPEED_STEP = 0.10,

    -- Abstand zwischen wiederholenden Lauftexten in Zeichen (Minimum: 0)
    GAP_MIN  = 0,
    GAP_MAX  = 30,
    GAP_STEP = 1,

    MAX_LOG = 1,
    LOG_TTL = 4
}

-- ==================================
-- KOMMENTAR: ZUSTANDS-TABELLE (BUNDELT UPVALUES FUER LUA 5.1)
-- ==================================
local state = {
    savedLines      = {{text = "Wegweiser", dir = 0, color = colors.white}},
    savedScale      = 1.0,
    savedBlinkOn    = 1.20,
    savedBlinkOff   = 1.20,
    savedSplitBlink = false,
    savedSyncBlink  = false,
    savedSpeed      = 0.30,
    savedGap        = 6,
    savedBgColor    = colors.black,

    editLines       = {{text = "Wegweiser", dir = 0, color = colors.white}},
    editScale       = 1.0,
    editBlinkOn     = 1.20,
    editBlinkOff    = 1.20,
    editSplitBlink  = false,
    editSyncBlink   = false,
    editSpeed       = 0.30,
    editGap         = 6,
    editBgColor     = colors.black,

    focusLine    = nil, -- Index der aktuell bearbeiteten Textzeile
    cursorPos    = 1,   -- Zeichen-Index des blinkenden Cursors (1 bis #text + 1)
    scrollOffset = 0,   -- Vertikaler Scroll-Versatz fuer Textzeilen
    sliderScroll = 0,   -- Scroll-Versatz fuer Slider (falls Bildschirm klein ist)
    marqueeStep  = 0,   -- Aktueller Animationsschritt fuer Laufschrift

    baseMonW  = nil,
    baseMonH  = nil,
    cachedPos = nil,    -- Gespeicherte GPS-Position (verhindert Timer-Verlust im Betrieb!)

    emergencyActive = false,
    lockdownActive  = false,
    updatingState   = false,
    showAlertPhase  = false, -- true = Warnwort (EMERGENCY/LOCKDOWN), false = Wegweiser-Text

    monitor = nil,
    modem   = nil,
    logs    = {},
    dirty   = true,

    tickTimer        = nil,
    blinkTimer       = nil,
    marqueeTimer     = nil,
    syncTimeoutTimer = nil
}

local hitboxes = {
    lines        = {},
    colorBoxes   = {},
    slideBoxes   = {},
    moveUp       = {},
    moveDown     = {},
    del          = {},
    addBtn       = nil,
    saveBtn      = nil,
    syncBtn      = nil,
    bgBtn        = nil,
    blinkModeBtn = nil,
    sliders      = {},
    scrollUp     = nil,
    scrollDown   = nil,
    sScrollUp    = nil,
    sScrollDown  = nil
}

-- ==================================
-- KOMMENTAR: HILFSFUNKTIONEN & LOGS
-- ==================================
local function now()
    return os.epoch("utc") / 1000
end

local function round(val, step)
    return math.floor((val / step) + 0.5) * step
end

local function pad(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

local function isLightColor(col)
    return col == colors.white
        or col == colors.yellow
        or col == colors.lime
        or col == colors.lightBlue
        or col == colors.pink
        or col == colors.lightGray
        or col == colors.orange
end

local function isValidColorInList(col, list)
    for _, c in ipairs(list) do
        if c == col then return true end
    end
    return false
end

local function cycleColorList(currentCol, step, list)
    local curIdx = 1
    for i, c in ipairs(list) do
        if c == currentCol then
            curIdx = i
            break
        end
    end
    local nextIdx = ((curIdx - 1 + step) % #list) + 1
    return list[nextIdx]
end

local function copyLines(list)
    local res = {}
    for i, v in ipairs(list) do
        if type(v) == "table" then
            local d = 0
            if type(v.dir) == "number" then
                d = v.dir
            elseif v.slide == true then
                d = 1
            end
            local col = isValidColorInList(v.color, CFG.TEXT_COLORS) and v.color or colors.white
            res[i] = {text = tostring(v.text or ""), dir = d, color = col}
        else
            res[i] = {text = tostring(v or ""), dir = 0, color = colors.white}
        end
    end
    return res
end

local function addLog(text)
    local w = term.getSize()
    local maxW = math.max(1, w - 2)
    table.insert(state.logs, {text = tostring(text):sub(1, maxW), expires = now() + CFG.LOG_TTL})
    while #state.logs > CFG.MAX_LOG do table.remove(state.logs, 1) end
    state.dirty = true
end

local function hasPendingChanges()
    if math.abs(state.editScale - state.savedScale) > 0.01 then return true end
    if math.abs(state.editBlinkOn - state.savedBlinkOn) > 0.01 then return true end
    if math.abs(state.editBlinkOff - state.savedBlinkOff) > 0.01 then return true end
    if state.editSplitBlink ~= state.savedSplitBlink then return true end
    if state.editSyncBlink ~= state.savedSyncBlink then return true end
    if math.abs(state.editSpeed - state.savedSpeed) > 0.01 then return true end
    if state.editGap ~= state.savedGap then return true end
    if state.editBgColor ~= state.savedBgColor then return true end
    if #state.editLines ~= #state.savedLines then return true end
    for i = 1, #state.editLines do
        if state.editLines[i].text ~= state.savedLines[i].text then return true end
        if state.editLines[i].dir ~= state.savedLines[i].dir then return true end
        if state.editLines[i].color ~= state.savedLines[i].color then return true end
    end
    return false
end

local function hasAnySlidingLine()
    for _, item in ipairs(state.savedLines) do
        if (item.dir == 1 or item.dir == 2) and #(item.text or "") > 0 then
            return true
        end
    end
    return false
end

-- Liefert die erste nicht-leere Textzeile fuer die Geraeteliste im Master
local function getFirstLinePreview()
    for _, item in ipairs(state.savedLines) do
        local t = tostring(item.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #t > 0 then
            return t
        end
    end
    if state.savedLines[1] and state.savedLines[1].text then
        return tostring(state.savedLines[1].text)
    end
    return "Leer"
end

-- ==================================
-- KOMMENTAR: GPS-CACHE & MASTER-REPORTING (OHNE TIMER-VERLUST!)
-- WICHTIG: gps.locate() schluckt waehrend seiner Laufzeit alle Timer-Events!
-- Daher wird GPS nur einmalig vor dem Starten der Timer abgefragt und gecacht.
-- ==================================
local function refreshGpsCache()
    if not state.modem then
        state.cachedPos = "GPS n.verf."
        return state.cachedPos
    end
    local x, y, z = gps.locate(1.5)
    if x and y and z then
        state.cachedPos = string.format("%.0f, %.0f, %.0f", x, y, z)
    else
        state.cachedPos = state.cachedPos or "GPS n.verf."
    end
    return state.cachedPos
end

local function sendReport(success, details)
    if not state.modem then return end
    local posStr  = state.cachedPos or "GPS n.verf."
    local preview = getFirstLinePreview()
    local baseLbl = os.getComputerLabel() or ("Anzeige " .. tostring(CFG.COMPUTER_ID))

    pcall(function()
        rednet.send(CFG.MASTER_ID, {
            action  = "log_report",
            success = success,
            details = details or ("Text: " .. preview),
            pos     = posStr,
            label   = baseLbl,
            preview = preview,
            devType = "sign"
        }, CFG.UPDATE_PROTOCOL)
    end)
end

local function requestMasterBlinkSync()
    if not state.modem then
        addLog("Sync fehlgeschlagen: Kein Modem!")
        return
    end
    pcall(function()
        rednet.send(CFG.MASTER_ID, { action = "request_blink_sync" }, CFG.CONFIG_PROTOCOL)
    end)
    state.syncTimeoutTimer = os.startTimer(2.0)
    addLog("Suche Master fuer Blink-Sync...")
end

-- ==================================
-- KOMMENTAR: LIVE-PRUEFUNG OB TEXT AUF MONITOR PASST (OHNE FLACKERN)
-- ==================================
local function getPreviewDimensions()
    if not state.monitor or not state.baseMonW or not state.baseMonH then
        return nil, nil
    end
    local pw = math.max(1, math.floor((state.baseMonW / state.editScale) + 0.5))
    local ph = math.max(1, math.floor((state.baseMonH / state.editScale) + 0.5))
    return pw, ph
end

local function isTextTooLargeForMonitor()
    if not state.monitor then return false end
    local pw, ph = getPreviewDimensions()
    if not pw or not ph then return false end

    if #state.editLines > ph then
        return true
    end

    for _, item in ipairs(state.editLines) do
        if (item.dir or 0) == 0 and #(item.text or "") > pw then
            return true
        end
    end

    return false
end

-- ==================================
-- KOMMENTAR: KONFIGURATION LADEN & SPEICHERN
-- ==================================
local function loadConfig()
    if fs.exists(CFG.CONFIG_FILE) then
        local f = fs.open(CFG.CONFIG_FILE, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then
                if type(data.lines) == "table" and #data.lines >= 1 then
                    state.savedLines = copyLines(data.lines)
                end
                if type(data.scale) == "number" then
                    state.savedScale = data.scale
                end
                if type(data.blinkOn) == "number" then
                    state.savedBlinkOn = math.max(CFG.BLINK_MIN, math.min(CFG.BLINK_MAX, round(data.blinkOn, CFG.BLINK_STEP)))
                elseif type(data.blink) == "number" then
                    state.savedBlinkOn = math.max(CFG.BLINK_MIN, math.min(CFG.BLINK_MAX, round(data.blink, CFG.BLINK_STEP)))
                end
                if type(data.blinkOff) == "number" then
                    state.savedBlinkOff = math.max(CFG.BLINK_OFF_MIN, math.min(CFG.BLINK_MAX, round(data.blinkOff, CFG.BLINK_STEP)))
                elseif type(data.blink) == "number" then
                    state.savedBlinkOff = math.max(CFG.BLINK_OFF_MIN, math.min(CFG.BLINK_MAX, round(data.blink, CFG.BLINK_STEP)))
                end
                if type(data.splitBlink) == "boolean" then
                    state.savedSplitBlink = data.splitBlink
                else
                    state.savedSplitBlink = (math.abs(state.savedBlinkOn - state.savedBlinkOff) > 0.01)
                end
                if not state.savedSplitBlink then
                    state.savedBlinkOff = state.savedBlinkOn
                end
                if type(data.syncBlink) == "boolean" then
                    state.savedSyncBlink = data.syncBlink
                end
                if type(data.speed) == "number" then
                    state.savedSpeed = math.max(CFG.SPEED_MIN, math.min(CFG.SPEED_MAX, round(data.speed, CFG.SPEED_STEP)))
                end
                if type(data.gap) == "number" then
                    state.savedGap = math.max(CFG.GAP_MIN, math.min(CFG.GAP_MAX, math.floor(data.gap + 0.5)))
                end
                if isValidColorInList(data.bgColor, CFG.BG_COLORS) then
                    state.savedBgColor = data.bgColor
                end

                state.editLines      = copyLines(state.savedLines)
                state.editScale      = state.savedScale
                state.editBlinkOn    = state.savedBlinkOn
                state.editBlinkOff   = state.savedBlinkOff
                state.editSplitBlink = state.savedSplitBlink
                state.editSyncBlink  = state.savedSyncBlink
                state.editSpeed      = state.savedSpeed
                state.editGap        = state.savedGap
                state.editBgColor    = state.savedBgColor
                return true
            end
        end
    end
    state.editLines      = copyLines(state.savedLines)
    state.editScale      = state.savedScale
    state.editBlinkOn    = state.savedBlinkOn
    state.editBlinkOff   = state.savedBlinkOff
    state.editSplitBlink = state.savedSplitBlink
    state.editSyncBlink  = state.savedSyncBlink
    state.editSpeed      = state.savedSpeed
    state.editGap        = state.savedGap
    state.editBgColor    = state.savedBgColor
    return false
end

local function saveConfig()
    local f = fs.open(CFG.CONFIG_FILE, "w")
    if not f then
        addLog("Fehler beim Speichern!")
        return false
    end
    f.write(textutils.serialize({
        lines      = state.savedLines,
        scale      = state.savedScale,
        blinkOn    = state.savedBlinkOn,
        blinkOff   = state.savedBlinkOff,
        splitBlink = state.savedSplitBlink,
        syncBlink  = state.savedSyncBlink,
        speed      = state.savedSpeed,
        gap        = state.savedGap,
        bgColor    = state.savedBgColor
    }))
    f.close()
    return true
end

-- ==================================
-- KOMMENTAR: OPTIMALE SKALIERUNG FUER EXAKTE MITTE BERECHNEN
-- ==================================
local function setCenteredScaleForWord(mon, word)
    local bestOddPadding  = nil
    local bestEvenPadding = nil
    local bestOddTight    = nil
    local bestAny         = nil

    for i = #CFG.SCALES, 1, -1 do
        local sc = CFG.SCALES[i]
        mon.setTextScale(sc)
        local mw, mh = mon.getSize()

        if mw >= #word and mh >= 1 then
            if not bestAny then bestAny = sc end
            if mh % 2 == 1 and not bestOddTight then
                bestOddTight = sc
            end
            if mw >= (#word + 2) then
                if mh % 2 == 1 and not bestOddPadding then
                    bestOddPadding = sc
                elseif mh >= 3 and not bestEvenPadding then
                    bestEvenPadding = sc
                end
            end
        end
    end

    local chosen = bestOddPadding or bestEvenPadding or bestOddTight or bestAny or 0.5
    mon.setTextScale(chosen)
    return chosen
end

-- ==================================
-- KOMMENTAR: MONITOR ANZEIGE (ZENTRIERT, FARBIG, HINTERGRUND, LAUFSCHRIFT & ALARM)
-- ==================================
local function renderMonitor()
    local mon = state.monitor
    if not mon then return end

    local ok = pcall(function()
        -- 1. WARN-PHASE: EMERGENCY oder LOCKDOWN knallrot & exakt mittig
        if (state.emergencyActive or state.lockdownActive) and state.showAlertPhase then
            local alertWord = state.lockdownActive and "LOCKDOWN" or "EMERGENCY"
            setCenteredScaleForWord(mon, alertWord)

            if mon.setPaletteColor then
                mon.setPaletteColor(colors.red, 0xFF0000)
            end

            local mw, mh = mon.getSize()
            mon.setBackgroundColor(colors.red)
            mon.setTextColor(colors.white)
            mon.clear()

            for y = 1, mh do
                mon.setCursorPos(1, y)
                mon.write(string.rep(" ", mw))
            end

            local dispWord = alertWord
            if #dispWord > mw then
                dispWord = dispWord:sub(1, mw)
            end

            local startX = math.floor((mw - #dispWord) / 2) + 1
            local startY = math.ceil(mh / 2)

            mon.setCursorPos(math.max(1, startX), math.max(1, startY))
            mon.write(dispWord)

        -- 2. TEXT-PHASE: Gespeicherte Zeilen auf der gewaehlten Monitor-Hintergrundfarbe
        else
            if mon.setPaletteColor and term.nativePaletteColor then
                local r, g, b = term.nativePaletteColor(colors.red)
                mon.setPaletteColor(colors.red, r, g, b)
            end

            mon.setTextScale(state.savedScale)
            local mw, mh = mon.getSize()
            state.baseMonW = mw * state.savedScale
            state.baseMonH = mh * state.savedScale

            local bgCol = isValidColorInList(state.savedBgColor, CFG.BG_COLORS) and state.savedBgColor or colors.black
            mon.setBackgroundColor(bgCol)
            mon.setTextColor(colors.white)
            mon.clear()

            local totalLines = #state.savedLines
            local startY = math.floor((mh - totalLines) / 2) + 1

            for i, item in ipairs(state.savedLines) do
                local y = startY + i - 1
                if y >= 1 and y <= mh then
                    local rawText = tostring(item.text or "")
                    local lineCol = isValidColorInList(item.color, CFG.TEXT_COLORS) and item.color or colors.white
                    mon.setTextColor(lineCol)

                    if (item.dir == 1 or item.dir == 2) and #rawText > 0 then
                        local spacer  = string.rep(" ", math.max(0, state.savedGap))
                        local loopStr = rawText .. spacer
                        local loopLen = #loopStr
                        local outChars = {}

                        for c = 1, mw do
                            local pos
                            if item.dir == 1 then
                                pos = ((state.marqueeStep + c - 1) % loopLen) + 1
                            else
                                pos = ((c - 1 - state.marqueeStep) % loopLen) + 1
                            end
                            outChars[c] = loopStr:sub(pos, pos)
                        end
                        mon.setCursorPos(1, y)
                        mon.write(table.concat(outChars))
                    else
                        local dispLine = rawText
                        if #dispLine > mw then
                            dispLine = dispLine:sub(1, mw)
                        end
                        local startX = math.floor((mw - #dispLine) / 2) + 1
                        mon.setCursorPos(math.max(1, startX), y)
                        mon.write(dispLine)
                    end
                end
            end
        end
    end)

    if not ok then
        state.monitor = peripheral.find("monitor")
    end
end

-- ==================================
-- KOMMENTAR: PERIPHERIE INITIALISIERUNG
-- ==================================
local function setupPeripherals()
    state.monitor = peripheral.find("monitor")
    state.modem   = peripheral.find("modem")

    if state.modem then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then
                rednet.open(name)
            end
        end
    else
        addLog("Warnung: Kein Modem gefunden!")
    end

    if not state.monitor then
        addLog("Warnung: Kein Monitor gefunden!")
        state.baseMonW, state.baseMonH = nil, nil
    else
        pcall(function()
            state.monitor.setTextScale(1.0)
            state.baseMonW, state.baseMonH = state.monitor.getSize()
        end)
        renderMonitor()
    end
    state.dirty = true
end

-- ==================================
-- KOMMENTAR: MEHRZEILIGES LAYOUT & EINHEITLICHE SPALTENBREITE
-- ==================================
local function getFieldWidth(w)
    local fieldX = 6
    local rightReserved = 14
    return math.max(6, w - fieldX - rightReserved + 1), fieldX
end

local function buildVisualRows(w)
    local rows = {}
    local fieldW, fieldX = getFieldWidth(w)

    for idx, item in ipairs(state.editLines) do
        local text = item.text or ""
        local neededLen = #text + ((state.focusLine == idx) and 1 or 0)
        local numSubRows = math.max(1, math.ceil(neededLen / fieldW))

        for sub = 1, numSubRows do
            local sStart = (sub - 1) * fieldW + 1
            local sEnd   = sub * fieldW
            local chunk  = text:sub(sStart, sEnd)

            table.insert(rows, {
                kind       = "line_part",
                lineIdx    = idx,
                subIdx     = sub,
                numSubRows = numSubRows,
                fieldX     = fieldX,
                fieldW     = fieldW,
                sStart     = sStart,
                sEnd       = sEnd,
                chunk      = chunk,
                isLastSub  = (sub == numSubRows)
            })
        end
    end

    table.insert(rows, {kind = "add_btn"})
    return rows
end

local function getActiveSliderDefs()
    local defs = {
        {id = "scale", label = string.format("Groesse: %.1f", state.editScale), val = state.editScale, min = 0.5, max = 5.0}
    }
    if state.editSplitBlink then
        table.insert(defs, {
            id = "blinkOn",
            label = string.format("Alarm AN:%.2fs", state.editBlinkOn),
            val = state.editBlinkOn, min = CFG.BLINK_MIN, max = CFG.BLINK_MAX,
            hasModeToggle = true,
            locked = state.editSyncBlink
        })
        table.insert(defs, {
            id = "blinkOff",
            label = string.format("Pause:   %.2fs", state.editBlinkOff),
            val = state.editBlinkOff, min = CFG.BLINK_OFF_MIN, max = CFG.BLINK_MAX,
            locked = state.editSyncBlink
        })
    else
        table.insert(defs, {
            id = "blinkOn",
            label = string.format("Blinken: %.2fs", state.editBlinkOn),
            val = state.editBlinkOn, min = CFG.BLINK_MIN, max = CFG.BLINK_MAX,
            hasModeToggle = true,
            locked = state.editSyncBlink
        })
    end
    table.insert(defs, {id = "speed", label = string.format("Lauftempo:%.2fs", state.editSpeed), val = state.editSpeed, min = CFG.SPEED_MIN, max = CFG.SPEED_MAX})
    table.insert(defs, {id = "gap",   label = string.format("Abstand: %2d Z.", state.editGap),   val = state.editGap,   min = CFG.GAP_MIN,   max = CFG.GAP_MAX})
    return defs
end

local function getLayoutBounds(h)
    local totalSliders = state.editSplitBlink and 5 or 4
    local maxVisSliders = (h >= 19) and 5 or 4
    local sliderRowsVisible = math.min(totalSliders, maxVisSliders)
    local saveY      = h - sliderRowsVisible - 1
    local listTop    = 3
    local listBottom = math.max(listTop + 1, saveY - 2)
    return listTop, listBottom, saveY, sliderRowsVisible
end

local function ensureFocusVisible()
    local fLine = state.focusLine
    if not fLine or not state.editLines[fLine] then return end
    local w, h = term.getSize()
    local listTop, listBottom = getLayoutBounds(h)
    local maxVisRows = math.max(2, listBottom - listTop + 1)
    local vRows      = buildVisualRows(w)

    local txtLen = #state.editLines[fLine].text
    state.cursorPos = math.max(1, math.min(txtLen + 1, state.cursorPos))

    local fieldW = getFieldWidth(w)
    local activeSub = math.max(1, math.ceil(state.cursorPos / fieldW))

    local targetRow = nil
    for rIdx, r in ipairs(vRows) do
        if r.kind == "line_part" and r.lineIdx == fLine and r.subIdx == activeSub then
            targetRow = rIdx
            break
        end
    end

    if targetRow then
        if targetRow <= state.scrollOffset then
            state.scrollOffset = math.max(0, targetRow - 1)
        elseif targetRow > state.scrollOffset + maxVisRows then
            state.scrollOffset = targetRow - maxVisRows
        end
    end
end

-- ==================================
-- KOMMENTAR: INTERNE COMPUTER-GUI ZEICHNEN
-- ==================================
local function drawSliderBar(y, labelText, curVal, minVal, maxVal, rightMargin, isLocked)
    local w = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(isLocked and colors.gray or colors.lightGray)
    term.setCursorPos(2, y)
    term.write(pad(labelText, 14))

    local barX = 16
    local rMarg = rightMargin or 6
    local bW = math.max(5, w - barX - rMarg)

    term.setCursorPos(barX, y)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(isLocked and colors.lightGray or colors.white)
    term.write(" < ")

    local ratio = (curVal - minVal) / math.max(0.0001, (maxVal - minVal))
    local knobPos = math.floor(ratio * (bW - 1) + 0.5) + 1
    knobPos = math.max(1, math.min(bW, knobPos))

    for i = 1, bW do
        term.setCursorPos(barX + 2 + i, y)
        if i == knobPos then
            term.setBackgroundColor(isLocked and colors.lightGray or colors.orange)
            term.setTextColor(colors.black)
            term.write("O")
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
            term.write("-")
        end
    end

    term.setCursorPos(barX + 3 + bW, y)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(isLocked and colors.lightGray or colors.white)
    term.write(" > ")

    return {
        decX1 = barX, decX2 = barX + 2,
        barX1 = barX + 3, barX2 = barX + 2 + bW,
        incX1 = barX + 3 + bW, incX2 = barX + 5 + bW,
        y = y, width = bW, locked = isLocked
    }
end

local function drawUI()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    hitboxes.lines        = {}
    hitboxes.colorBoxes   = {}
    hitboxes.slideBoxes   = {}
    hitboxes.moveUp       = {}
    hitboxes.moveDown     = {}
    hitboxes.del          = {}
    hitboxes.addBtn       = nil
    hitboxes.saveBtn      = nil
    hitboxes.syncBtn      = nil
    hitboxes.bgBtn        = nil
    hitboxes.blinkModeBtn = nil
    hitboxes.sliders      = {}
    hitboxes.scrollUp     = nil
    hitboxes.scrollDown   = nil
    hitboxes.sScrollUp    = nil
    hitboxes.sScrollDown  = nil

    -- 1. Kopfzeile: Ueberschrift, Hintergrundfarben-Wahl [BG], Legende & ID oben rechts
    term.setCursorPos(2, 1)
    term.setTextColor(colors.cyan)
    term.write("Textanzeige")

    local bgBtnX = 14
    term.setCursorPos(bgBtnX, 1)
    term.setBackgroundColor(state.editBgColor)
    term.setTextColor(isLightColor(state.editBgColor) and colors.black or colors.white)
    term.write("[BG]")
    hitboxes.bgBtn = {x1 = bgBtnX, x2 = bgBtnX + 3, y = 1}

    term.setBackgroundColor(colors.black)
    if state.updatingState then
        term.setCursorPos(19, 1)
        term.setTextColor(colors.yellow)
        term.write("[UPDATING]")
    elseif state.emergencyActive or state.lockdownActive then
        term.setCursorPos(19, 1)
        term.setTextColor(colors.red)
        term.write(state.lockdownActive and "[LOCKDOWN]" or "[ALARM]")
    else
        term.setCursorPos(19, 1)
        term.setTextColor(colors.gray)
        local hintStr = "[C]=Txt [<]/[>] ^v"
        local idReserve = #("ID:" .. tostring(CFG.COMPUTER_ID)) + 2
        if 19 + #hintStr <= w - idReserve then
            term.write(hintStr)
        end
    end

    local idStr = "ID:" .. tostring(CFG.COMPUTER_ID)
    term.setCursorPos(math.max(1, w - #idStr), 1)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    -- 2. Scrollbarer Bereich fuer mitwachsende Textzeilen und "+" Button
    local listTop, listBottom, saveY, sliderVisCount = getLayoutBounds(h)
    local maxVisRows = math.max(2, listBottom - listTop + 1)

    local vRows = buildVisualRows(w)
    local totalVRows = #vRows

    if state.scrollOffset > math.max(0, totalVRows - maxVisRows) then
        state.scrollOffset = math.max(0, totalVRows - maxVisRows)
    end
    if state.scrollOffset < 0 then state.scrollOffset = 0 end

    if state.scrollOffset > 0 then
        term.setCursorPos(w, listTop)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write("^")
        hitboxes.scrollUp = {x = w, y = listTop}
    end
    if state.scrollOffset + maxVisRows < totalVRows then
        term.setCursorPos(w, listBottom)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write("v")
        hitboxes.scrollDown = {x = w, y = listBottom}
    end

    local cursorScreenX, cursorScreenY = nil, nil
    local visibleCount = math.min(totalVRows - state.scrollOffset, maxVisRows)
    local cursorTextCol = colors.black
    local cursorBgCol   = colors.gray

    for i = 1, visibleCount do
        local rowObj = vRows[state.scrollOffset + i]
        local y = listTop + i - 1

        if rowObj.kind == "line_part" then
            local idx     = rowObj.lineIdx
            local item    = state.editLines[idx]
            local fieldX  = rowObj.fieldX
            local fieldW  = rowObj.fieldW
            local lineCol = isValidColorInList(item.color, CFG.TEXT_COLORS) and item.color or colors.white

            if rowObj.subIdx == 1 then
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.lightGray)
                term.setCursorPos(2, y)
                term.write(string.format("%2d.", idx))
            else
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.gray)
                term.setCursorPos(2, y)
                term.write(" ..")
            end

            term.setCursorPos(fieldX, y)
            local fieldBg = colors.gray
            if state.focusLine == idx then
                if isLightColor(lineCol) then
                    fieldBg = colors.gray
                else
                    fieldBg = colors.lightGray
                end
            else
                if lineCol == colors.gray then
                    fieldBg = colors.black
                else
                    fieldBg = colors.gray
                end
            end
            term.setBackgroundColor(fieldBg)
            term.setTextColor(lineCol)
            term.write(pad(rowObj.chunk, fieldW))

            table.insert(hitboxes.lines, {
                lineIdx = idx,
                subIdx  = rowObj.subIdx,
                sStart  = rowObj.sStart,
                fieldX  = fieldX,
                fieldW  = fieldW,
                x1      = fieldX,
                x2      = fieldX + fieldW - 1,
                y       = y
            })

            if state.focusLine == idx then
                local txtLen = #(item.text or "")
                local cPos = math.max(1, math.min(txtLen + 1, state.cursorPos))
                if cPos >= rowObj.sStart and cPos <= rowObj.sEnd then
                    cursorScreenX = fieldX + (cPos - rowObj.sStart)
                    cursorScreenY = y
                    cursorTextCol = lineCol
                    cursorBgCol   = fieldBg
                end
            end

            if rowObj.subIdx == 1 then
                -- 1. Farbauswahl-Button "[C]"
                local colX = fieldX + fieldW + 1
                term.setCursorPos(colX, y)
                term.setBackgroundColor(lineCol)
                term.setTextColor(isLightColor(lineCol) and colors.black or colors.white)
                term.write("[C]")
                hitboxes.colorBoxes[idx] = {x1 = colX, x2 = colX + 2, y = y}

                -- 2. Laufschrift-Checkbox "[ ]" / "[<]" / "[>]"
                local chkX = colX + 4
                term.setCursorPos(chkX, y)
                if item.dir == 1 then
                    term.setBackgroundColor(colors.green)
                    term.setTextColor(colors.black)
                    term.write("[<]")
                elseif item.dir == 2 then
                    term.setBackgroundColor(colors.cyan)
                    term.setTextColor(colors.black)
                    term.write("[>]")
                else
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.lightGray)
                    term.write("[ ]")
                end
                hitboxes.slideBoxes[idx] = {x1 = chkX, x2 = chkX + 2, y = y}

                -- 3. Sortier-Button Hoch ("^")
                local upX = chkX + 4
                term.setCursorPos(upX, y)
                if idx > 1 then
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.white)
                    term.write("^")
                    hitboxes.moveUp[idx] = {x = upX, y = y}
                else
                    term.setBackgroundColor(colors.black)
                    term.setTextColor(colors.gray)
                    term.write("-")
                end

                -- 4. Sortier-Button Runter ("v")
                local dnX = chkX + 5
                term.setCursorPos(dnX, y)
                if idx < #state.editLines then
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.white)
                    term.write("v")
                    hitboxes.moveDown[idx] = {x = dnX, y = y}
                else
                    term.setBackgroundColor(colors.black)
                    term.setTextColor(colors.gray)
                    term.write("-")
                end

                -- 5. Loeschen "x" (nur ab Zeile 2)
                if idx > 1 then
                    local delX = chkX + 7
                    term.setCursorPos(delX, y)
                    term.setBackgroundColor(colors.red)
                    term.setTextColor(colors.white)
                    term.write("x")
                    hitboxes.del[idx] = {x1 = delX, x2 = delX, y = y}
                end
            end

        elseif rowObj.kind == "add_btn" then
            term.setCursorPos(6, y)
            term.setBackgroundColor(colors.green)
            term.setTextColor(colors.black)
            term.write(" + ")
            hitboxes.addBtn = {x1 = 6, x2 = 8, y = y}
        end
    end

    -- 3. "Speichern" Button & "Sync" Checkbox:
    -- Links exakt buendig mit den Schiebereglern darunter (X = 16) und rechts buendig mit dem ">"-Button!
    local barStartX = 16
    local barEndX   = w - 2
    local syncLabel = state.editSyncBlink and " [x] Sync " or " [ ] Sync "
    local syncW     = #syncLabel
    local gapW      = 2
    local saveX     = barStartX
    local saveW     = math.max(11, (barEndX - barStartX + 1) - syncW - gapW)
    local syncX     = saveX + saveW + gapW
    local isModified = hasPendingChanges()

    term.setCursorPos(saveX, saveY)
    term.setBackgroundColor(isModified and colors.orange or colors.gray)
    term.setTextColor(isModified and colors.black or colors.white)
    local saveLabel = "Speichern"
    local padL = math.floor((saveW - #saveLabel) / 2)
    term.write(pad(string.rep(" ", padL) .. saveLabel, saveW))
    hitboxes.saveBtn = {x1 = saveX, x2 = saveX + saveW - 1, y = saveY}

    term.setCursorPos(syncX, saveY)
    if state.editSyncBlink then
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.black)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
    end
    term.write(syncLabel)
    hitboxes.syncBtn = {x1 = syncX, x2 = syncX + syncW - 1, y = saveY}

    -- 4. Slider-Sektion (4 Slider bei [1S], 5 Slider bei [2S])
    local sliderDefs = getActiveSliderDefs()
    local maxSliderScroll = math.max(0, #sliderDefs - sliderVisCount)
    if state.sliderScroll > maxSliderScroll then state.sliderScroll = maxSliderScroll end
    if state.sliderScroll < 0 then state.sliderScroll = 0 end

    local sliderTopY = saveY + 1
    local sliderBottomY = sliderTopY + sliderVisCount - 1

    for sIdx = 1, sliderVisCount do
        local def = sliderDefs[state.sliderScroll + sIdx]
        if def then
            local sy = sliderTopY + sIdx - 1
            local rMargin = def.hasModeToggle and 12 or 7
            local box = drawSliderBar(sy, def.label, def.val, def.min, def.max, rMargin, def.locked)
            box.id = def.id
            hitboxes.sliders[def.id] = box

            if def.hasModeToggle then
                local mX = box.incX2 + 2
                term.setCursorPos(mX, sy)
                if state.editSyncBlink then
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.lightGray)
                elseif state.editSplitBlink then
                    term.setBackgroundColor(colors.cyan)
                    term.setTextColor(colors.black)
                else
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.white)
                end
                term.write(state.editSplitBlink and "[2S]" or "[1S]")
                hitboxes.blinkModeBtn = {x1 = mX, x2 = mX + 3, y = sy, locked = state.editSyncBlink}
            end
        end
    end

    if maxSliderScroll > 0 then
        if state.sliderScroll > 0 then
            term.setCursorPos(w, sliderTopY)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.write("^")
            hitboxes.sScrollUp = {x = w, y = sliderTopY}
        end
        if state.sliderScroll < maxSliderScroll then
            term.setCursorPos(w, sliderBottomY)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.write("v")
            hitboxes.sScrollDown = {x = w, y = sliderBottomY}
        end
    end

    -- 5. Unterste Zeile: Debug-Nachricht (hat Vorrang fuer direktes Feedback) oder Groessenwarnung
    term.setBackgroundColor(colors.black)
    if #state.logs > 0 then
        term.setCursorPos(2, h)
        term.setTextColor(colors.gray)
        term.write(pad(state.logs[#state.logs].text, w - 2))
    elseif isTextTooLargeForMonitor() then
        term.setCursorPos(1, h)
        term.setTextColor(colors.red)
        local warnMsg = "Hinweis: Text zu gross fuer die Anzeige! Groesse oder Text Anpassen."
        if #warnMsg > w then
            warnMsg = "Hinweis: Text zu gross! Groesse/Text anpassen."
        end
        local wX = math.max(1, math.floor((w - #warnMsg) / 2) + 1)
        term.setCursorPos(wX, h)
        term.write(warnMsg:sub(1, w))
    end

    -- Blinkenden Cursor setzen
    if state.focusLine and cursorScreenX and cursorScreenY then
        term.setBackgroundColor(cursorBgCol)
        term.setTextColor(cursorTextCol == cursorBgCol and colors.white or cursorTextCol)
        term.setCursorPos(cursorScreenX, cursorScreenY)
        term.setCursorBlink(true)
    else
        term.setCursorBlink(false)
    end
end

-- ==================================
-- KOMMENTAR: AKTIONEN, TIMER & PAUSE=0.00s DAUERANZEIGE
-- ==================================
local function isContinuousAlert()
    return state.savedSplitBlink and (state.savedBlinkOff <= 0.001)
end

local function getCurrentPhaseDuration()
    if not state.savedSplitBlink then
        return state.savedBlinkOn
    end
    return state.showAlertPhase and state.savedBlinkOn or state.savedBlinkOff
end

local function updateTimers()
    if state.emergencyActive or state.lockdownActive then
        if isContinuousAlert() then
            -- Pause ist 0.00s -> Dauerhaft Warnbildschirm ohne Blink-Timer!
            state.showAlertPhase = true
            state.blinkTimer = nil
        elseif not state.blinkTimer then
            state.showAlertPhase = true
            state.blinkTimer = os.startTimer(math.max(0.05, getCurrentPhaseDuration()))
        end
    else
        state.blinkTimer = nil
        state.showAlertPhase = false
    end

    if hasAnySlidingLine() and not state.marqueeTimer then
        state.marqueeTimer = os.startTimer(math.max(0.05, state.savedSpeed))
    elseif not hasAnySlidingLine() then
        state.marqueeTimer = nil
        state.marqueeStep = 0
    end
end

local function applyMasterBlinkConfig(msg, isAutoSync)
    if type(msg) ~= "table" then return end
    local bOn   = tonumber(msg.blinkOn)
    local bOff  = tonumber(msg.blinkOff)
    local sMode = (msg.splitBlink == true)
    if not bOn then return end

    state.syncTimeoutTimer = nil

    bOn = math.max(CFG.BLINK_MIN, math.min(CFG.BLINK_MAX, round(bOn, CFG.BLINK_STEP)))
    if sMode then
        bOff = math.max(CFG.BLINK_OFF_MIN, math.min(CFG.BLINK_MAX, round(bOff or bOn, CFG.BLINK_STEP)))
    else
        bOff = bOn
    end

    state.savedSplitBlink = sMode
    state.savedBlinkOn    = bOn
    state.savedBlinkOff   = bOff

    state.editSplitBlink  = sMode
    state.editBlinkOn     = bOn
    state.editBlinkOff    = bOff

    saveConfig()

    -- Sendet Bericht SOFORT mit gecachter GPS-Position (damit gps.locate NICHT den neuen blinkTimer schluckt!)
    sendReport(true, string.format("Sync aktiv (AN:%.2fs AUS:%.2fs)", state.savedBlinkOn, state.savedBlinkOff))

    if state.emergencyActive or state.lockdownActive then
        if isContinuousAlert() then
            state.showAlertPhase = true
            state.blinkTimer = nil
        else
            state.blinkTimer = os.startTimer(math.max(0.05, getCurrentPhaseDuration()))
        end
    end
    updateTimers()
    renderMonitor()
    addLog(isAutoSync and "Sync: Blink-Takt vom Master geladen." or "Master: Blink-Takt aktualisiert.")
    state.dirty = true
end

local function applySave()
    state.focusLine = nil
    if not state.editSplitBlink then
        state.editBlinkOff = state.editBlinkOn
    end
    state.savedLines      = copyLines(state.editLines)
    state.savedScale      = state.editScale
    state.savedBlinkOn    = state.editBlinkOn
    state.savedBlinkOff   = state.editBlinkOff
    state.savedSplitBlink = state.editSplitBlink
    state.savedSyncBlink  = state.editSyncBlink
    state.savedSpeed      = state.editSpeed
    state.savedGap        = state.editGap
    state.savedBgColor    = state.editBgColor
    state.marqueeStep     = 0

    if saveConfig() then
        addLog("Gespeichert & Monitor aktualisiert.")
    end

    -- Sendet aktualisierten Vorschau-Text an die Master-Geraeteliste
    sendReport(true, "Text: " .. getFirstLinePreview())

    if state.emergencyActive or state.lockdownActive then
        if isContinuousAlert() then
            state.showAlertPhase = true
            state.blinkTimer = nil
        else
            state.blinkTimer = os.startTimer(math.max(0.05, getCurrentPhaseDuration()))
        end
    end
    if hasAnySlidingLine() then
        state.marqueeTimer = os.startTimer(math.max(0.05, state.savedSpeed))
    end
    updateTimers()
    renderMonitor()
    state.dirty = true
end

local function swapLines(idxA, idxB)
    if not state.editLines[idxA] or not state.editLines[idxB] then return end
    state.editLines[idxA], state.editLines[idxB] = state.editLines[idxB], state.editLines[idxA]
    if state.focusLine == idxA then
        state.focusLine = idxB
    elseif state.focusLine == idxB then
        state.focusLine = idxA
    end
    state.dirty = true
end

local function changeScaleByStep(delta)
    local curIdx = 2
    for i, sc in ipairs(CFG.SCALES) do
        if math.abs(sc - state.editScale) < 0.05 then
            curIdx = i
            break
        end
    end
    local newIdx = math.max(1, math.min(#CFG.SCALES, curIdx + delta))
    state.editScale = CFG.SCALES[newIdx]
    state.dirty = true
end

local function changeBlinkOnByStep(delta)
    local nextVal = round(state.editBlinkOn + (delta * CFG.BLINK_STEP), CFG.BLINK_STEP)
    state.editBlinkOn = math.max(CFG.BLINK_MIN, math.min(CFG.BLINK_MAX, nextVal))
    if not state.editSplitBlink then
        state.editBlinkOff = state.editBlinkOn
    end
    state.dirty = true
end

local function changeBlinkOffByStep(delta)
    local nextVal = round(state.editBlinkOff + (delta * CFG.BLINK_STEP), CFG.BLINK_STEP)
    state.editBlinkOff = math.max(CFG.BLINK_OFF_MIN, math.min(CFG.BLINK_MAX, nextVal))
    state.dirty = true
end

local function changeSpeedByStep(delta)
    local nextVal = round(state.editSpeed + (delta * CFG.SPEED_STEP), CFG.SPEED_STEP)
    state.editSpeed = math.max(CFG.SPEED_MIN, math.min(CFG.SPEED_MAX, nextVal))
    state.dirty = true
end

local function changeGapByStep(delta)
    state.editGap = math.max(CFG.GAP_MIN, math.min(CFG.GAP_MAX, state.editGap + (delta * CFG.GAP_STEP)))
    state.dirty = true
end

local function triggerAlertState()
    if state.emergencyActive or state.lockdownActive then
        state.showAlertPhase = true
        if isContinuousAlert() then
            state.blinkTimer = nil
        else
            state.blinkTimer = os.startTimer(math.max(0.05, state.savedBlinkOn))
        end
        renderMonitor()
    else
        state.blinkTimer = nil
        state.showAlertPhase = false
        renderMonitor()
    end
end

-- ==================================
-- KOMMENTAR: REMOTE-UPDATE FUNKTION (UEBER GITHUB & MASTER)
-- ==================================
local function applyUpdate()
    state.updatingState = true
    drawUI()

    local function fail(reportText, uiText)
        sendReport(false, reportText)
        state.updatingState = false
        addLog(uiText or reportText)
        drawUI()
        return false
    end

    addLog("Lade Update von GitHub...")
    drawUI()

    if not http then return fail("HTTP-API inaktiv!", "Fehler: HTTP inaktiv") end

    local url = CFG.GITHUB_URL .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local response, httpErr, failResp = http.get(url)
    if not response then
        local why = tostring(httpErr)
        if failResp and failResp.getResponseCode then
            why = "HTTP " .. tostring(failResp.getResponseCode())
            pcall(failResp.close)
        end
        return fail("Download fehlgeschlagen (" .. why:sub(1, 24) .. ")", "Download-Fehler")
    end

    local content = response.readAll()
    response.close()

    if not content or #content == 0 then return fail("Datei ist leer", "Fehler: Datei leer") end

    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return fail("GitHub lieferte HTML statt Code", "Fehler: HTML erhalten")
    end

    local f = fs.open(CFG.TEMP_FILE, "w")
    if not f then return fail("Temp nicht schreibbar", "Fehler: Dateizugriff") end
    f.write(content)
    f.close()

    local compiled = loadfile(CFG.TEMP_FILE)
    fs.delete(CFG.TEMP_FILE)
    if not compiled then return fail("Syntaxfehler im Update", "Fehler: Syntax im Update") end

    if fs.exists(CFG.BACKUP_FILE) then fs.delete(CFG.BACKUP_FILE) end
    if fs.exists("startup.lua") then
        fs.copy("startup.lua", CFG.BACKUP_FILE)
    elseif fs.exists("startup") then
        fs.copy("startup", CFG.BACKUP_FILE)
    end

    local newFile = fs.open("startup.lua", "w")
    if not newFile then return fail("Schreiben verweigert", "Installationsfehler") end
    newFile.write(content)
    newFile.close()

    if fs.exists("startup") then fs.delete("startup") end

    sendReport(true, "Update erfolgreich (GitHub)")
    addLog("Update installiert! Neustart...")
    drawUI()
    sleep(2)
    os.reboot()
end

-- ==================================
-- KOMMENTAR: HAUPTSCHLEIFE (EVENTS)
-- ==================================
local function main()
    -- WICHTIG: Erst GPS einmalig cachen & Status-Anfragen senden, BEVOR die Timer
    -- fuer Laufschrift und Blinken gestartet werden (da gps.locate Events verwirft!)
    if state.modem then
        refreshGpsCache()
        rednet.broadcast(CFG.MSG_STATUS, CFG.PROTOCOL)
        rednet.broadcast(CFG.MSG_STATUS, CFG.LOCKDOWN_PROTOCOL)
        sendReport(true, "Text: " .. getFirstLinePreview())
        if state.savedSyncBlink then
            requestMasterBlinkSync()
        end
    end

    -- Jetzt die Timer starten (werden nicht mehr durch gps.locate verschluckt!)
    state.tickTimer    = os.startTimer(0.5)
    state.blinkTimer   = nil
    state.marqueeTimer = nil
    updateTimers()
    renderMonitor()

    while true do
        if state.dirty then
            drawUI()
            state.dirty = false
        end

        local ev, p1, p2, p3 = os.pullEvent()

        -- Mausklick & Ziehen fuer Slider, Farb-Auswahl, Text-Cursor, Sortierung und Buttons
        if (ev == "mouse_click" or ev == "mouse_drag") and not state.updatingState then
            local button, x, y = p1, p2, p3
            local handled = false

            -- Alle sichtbaren Slider pruefen
            for id, s in pairs(hitboxes.sliders) do
                if y == s.y then
                    if s.locked then
                        if ev == "mouse_click" and x >= s.decX1 and x <= s.incX2 then
                            addLog("Blink-Sync aktiv! Fuer manuell: [x] Sync deaktivieren.")
                            handled = true
                        end
                        break
                    end
                    if x >= s.barX1 and x <= s.barX2 then
                        local rel = (x - s.barX1) / math.max(1, (s.width - 1))
                        if id == "scale" then
                            local idx = math.floor(rel * (#CFG.SCALES - 1) + 0.5) + 1
                            idx = math.max(1, math.min(#CFG.SCALES, idx))
                            state.editScale = CFG.SCALES[idx]
                        elseif id == "blinkOn" then
                            local raw = CFG.BLINK_MIN + rel * (CFG.BLINK_MAX - CFG.BLINK_MIN)
                            state.editBlinkOn = math.max(CFG.BLINK_MIN, math.min(CFG.BLINK_MAX, round(raw, CFG.BLINK_STEP)))
                            if not state.editSplitBlink then
                                state.editBlinkOff = state.editBlinkOn
                            end
                        elseif id == "blinkOff" then
                            local raw = CFG.BLINK_OFF_MIN + rel * (CFG.BLINK_MAX - CFG.BLINK_OFF_MIN)
                            state.editBlinkOff = math.max(CFG.BLINK_OFF_MIN, math.min(CFG.BLINK_MAX, round(raw, CFG.BLINK_STEP)))
                        elseif id == "speed" then
                            local raw = CFG.SPEED_MIN + rel * (CFG.SPEED_MAX - CFG.SPEED_MIN)
                            state.editSpeed = math.max(CFG.SPEED_MIN, math.min(CFG.SPEED_MAX, round(raw, CFG.SPEED_STEP)))
                        elseif id == "gap" then
                            local raw = CFG.GAP_MIN + rel * (CFG.GAP_MAX - CFG.GAP_MIN)
                            state.editGap = math.max(CFG.GAP_MIN, math.min(CFG.GAP_MAX, math.floor(raw + 0.5)))
                        end
                        state.dirty = true
                        handled = true
                        break
                    elseif ev == "mouse_click" and x >= s.decX1 and x <= s.decX2 then
                        if id == "scale" then changeScaleByStep(-1)
                        elseif id == "blinkOn" then changeBlinkOnByStep(-1)
                        elseif id == "blinkOff" then changeBlinkOffByStep(-1)
                        elseif id == "speed" then changeSpeedByStep(-1)
                        elseif id == "gap" then changeGapByStep(-1) end
                        handled = true
                        break
                    elseif ev == "mouse_click" and x >= s.incX1 and x <= s.incX2 then
                        if id == "scale" then changeScaleByStep(1)
                        elseif id == "blinkOn" then changeBlinkOnByStep(1)
                        elseif id == "blinkOff" then changeBlinkOffByStep(1)
                        elseif id == "speed" then changeSpeedByStep(1)
                        elseif id == "gap" then changeGapByStep(1) end
                        handled = true
                        break
                    end
                end
            end

            if ev == "mouse_click" and not handled then
                -- Umschalter fuer 1-Slider vs. 2-Slider beim Blinken ([1S] / [2S])
                if hitboxes.blinkModeBtn and y == hitboxes.blinkModeBtn.y and x >= hitboxes.blinkModeBtn.x1 and x <= hitboxes.blinkModeBtn.x2 then
                    if hitboxes.blinkModeBtn.locked then
                        addLog("Blink-Sync aktiv! Fuer manuell: [x] Sync deaktivieren.")
                    else
                        state.editSplitBlink = not state.editSplitBlink
                        if not state.editSplitBlink then
                            state.editBlinkOff = state.editBlinkOn
                            state.sliderScroll = 0
                        end
                        state.dirty = true
                    end
                    handled = true
                end

                -- "Sync" Checkbox neben Speichern: Aktiviert/Deaktiviert Master-Synchronisation sofort
                if not handled and hitboxes.syncBtn and y == hitboxes.syncBtn.y and x >= hitboxes.syncBtn.x1 and x <= hitboxes.syncBtn.x2 then
                    state.editSyncBlink  = not state.editSyncBlink
                    state.savedSyncBlink = state.editSyncBlink
                    saveConfig()
                    if state.editSyncBlink then
                        requestMasterBlinkSync()
                    else
                        state.syncTimeoutTimer = nil
                        addLog("Blink-Sync deaktiviert (Manueller Modus).")
                    end
                    state.dirty = true
                    handled = true
                end

                -- Globaler Hintergrundfarb-Button "[BG]" oben in der Kopfzeile (Links-/Rechtsklick)
                if not handled and hitboxes.bgBtn and y == hitboxes.bgBtn.y and x >= hitboxes.bgBtn.x1 and x <= hitboxes.bgBtn.x2 then
                    local step = (button == 2) and -1 or 1
                    state.editBgColor = cycleColorList(state.editBgColor, step, CFG.BG_COLORS)
                    state.dirty = true
                    handled = true
                end

                -- Scroll-Pfeile (Textliste & Slider) pruefen
                if not handled then
                    if hitboxes.scrollUp and x == hitboxes.scrollUp.x and y == hitboxes.scrollUp.y then
                        state.scrollOffset = math.max(0, state.scrollOffset - 1)
                        state.dirty = true
                        handled = true
                    elseif hitboxes.scrollDown and x == hitboxes.scrollDown.x and y == hitboxes.scrollDown.y then
                        state.scrollOffset = state.scrollOffset + 1
                        state.dirty = true
                        handled = true
                    elseif hitboxes.sScrollUp and x == hitboxes.sScrollUp.x and y == hitboxes.sScrollUp.y then
                        state.sliderScroll = math.max(0, state.sliderScroll - 1)
                        state.dirty = true
                        handled = true
                    elseif hitboxes.sScrollDown and x == hitboxes.sScrollDown.x and y == hitboxes.sScrollDown.y then
                        state.sliderScroll = state.sliderScroll + 1
                        state.dirty = true
                        handled = true
                    end
                end

                -- Textfelder pruefen: Setzt den Cursor exakt an den angeklickten Buchstaben
                if not handled then
                    for _, box in ipairs(hitboxes.lines) do
                        if y == box.y and x >= box.x1 and x <= box.x2 then
                            state.focusLine = box.lineIdx
                            local txtLen = #(state.editLines[state.focusLine].text or "")
                            local clickedCharPos = box.sStart + (x - box.fieldX)
                            state.cursorPos = math.max(1, math.min(txtLen + 1, clickedCharPos))
                            ensureFocusVisible()
                            state.dirty = true
                            handled = true
                            break
                        end
                    end
                end

                -- Zeilen-Farbauswahl-Button ("[C]") pruefen
                if not handled then
                    for idx, box in pairs(hitboxes.colorBoxes) do
                        if y == box.y and x >= box.x1 and x <= box.x2 then
                            local step = (button == 2) and -1 or 1
                            state.editLines[idx].color = cycleColorList(state.editLines[idx].color, step, CFG.TEXT_COLORS)
                            state.dirty = true
                            handled = true
                            break
                        end
                    end
                end

                -- 3-Stufen Laufschrift-Checkbox ([ ] -> [<] -> [>]) pruefen
                if not handled then
                    for idx, box in pairs(hitboxes.slideBoxes) do
                        if y == box.y and x >= box.x1 and x <= box.x2 then
                            local step = (button == 2) and -1 or 1
                            state.editLines[idx].dir = ((state.editLines[idx].dir or 0) + step) % 3
                            state.dirty = true
                            handled = true
                            break
                        end
                    end
                end

                -- Zeilen-Sortierung: Nach oben verschieben ("^")
                if not handled then
                    for idx, box in pairs(hitboxes.moveUp) do
                        if y == box.y and x == box.x then
                            swapLines(idx, idx - 1)
                            handled = true
                            break
                        end
                    end
                end

                -- Zeilen-Sortierung: Nach unten verschieben ("v")
                if not handled then
                    for idx, box in pairs(hitboxes.moveDown) do
                        if y == box.y and x == box.x then
                            swapLines(idx, idx + 1)
                            handled = true
                            break
                        end
                    end
                end

                -- Loeschen-Button ("x") pruefen
                if not handled then
                    for idx, box in pairs(hitboxes.del) do
                        if y == box.y and x >= box.x1 and x <= box.x2 then
                            table.remove(state.editLines, idx)
                            if state.focusLine == idx then
                                state.focusLine = nil
                            elseif state.focusLine and state.focusLine > idx then
                                state.focusLine = state.focusLine - 1
                            end
                            state.dirty = true
                            handled = true
                            break
                        end
                    end
                end

                -- "+" Button pruefen
                if not handled and hitboxes.addBtn then
                    if y == hitboxes.addBtn.y and x >= hitboxes.addBtn.x1 and x <= hitboxes.addBtn.x2 then
                        table.insert(state.editLines, {text = "", dir = 0, color = colors.white})
                        state.focusLine = #state.editLines
                        state.cursorPos = 1
                        ensureFocusVisible()
                        state.dirty = true
                        handled = true
                    end
                end

                -- "Speichern" Button pruefen
                if not handled and hitboxes.saveBtn then
                    if y == hitboxes.saveBtn.y and x >= hitboxes.saveBtn.x1 and x <= hitboxes.saveBtn.x2 then
                        applySave()
                        handled = true
                    end
                end

                -- Klick ins Leere hebt Fokus auf
                if not handled then
                    state.focusLine = nil
                    state.dirty = true
                end
            end

        -- Mausrad: Oben scrollt die Textzeilen, unten im Slider-Bereich scrollt die Slider
        elseif ev == "mouse_scroll" and not state.updatingState then
            local dir, _, y = p1, p2, p3
            local _, _, saveY = getLayoutBounds( select(2, term.getSize()) )
            if y and y > saveY then
                state.sliderScroll = math.max(0, state.sliderScroll + dir)
            else
                state.scrollOffset = math.max(0, state.scrollOffset + dir)
            end
            state.dirty = true

        -- Texteingabe exakt an der aktuellen Cursor-Position einfuegen
        elseif ev == "char" and not state.updatingState then
            local fLine = state.focusLine
            if fLine and state.editLines[fLine] then
                local str = state.editLines[fLine].text or ""
                if #str < 240 then
                    state.cursorPos = math.max(1, math.min(#str + 1, state.cursorPos))
                    local before = str:sub(1, state.cursorPos - 1)
                    local after  = str:sub(state.cursorPos)
                    state.editLines[fLine].text = before .. p1 .. after
                    state.cursorPos = state.cursorPos + 1
                    ensureFocusVisible()
                    state.dirty = true
                end
            end

        -- Sondertasten (Backspace, Delete, Links/Rechts, Home/End, Hoch/Runter, Enter)
        elseif ev == "key" and not state.updatingState then
            local fLine = state.focusLine
            if fLine and state.editLines[fLine] then
                local str = state.editLines[fLine].text or ""
                state.cursorPos = math.max(1, math.min(#str + 1, state.cursorPos))

                if p1 == keys.backspace then
                    if state.cursorPos > 1 then
                        local before = str:sub(1, state.cursorPos - 2)
                        local after  = str:sub(state.cursorPos)
                        state.editLines[fLine].text = before .. after
                        state.cursorPos = state.cursorPos - 1
                        ensureFocusVisible()
                        state.dirty = true
                    end
                elseif p1 == keys.delete then
                    if state.cursorPos <= #str then
                        local before = str:sub(1, state.cursorPos - 1)
                        local after  = str:sub(state.cursorPos + 1)
                        state.editLines[fLine].text = before .. after
                        ensureFocusVisible()
                        state.dirty = true
                    end
                elseif p1 == keys.left then
                    if state.cursorPos > 1 then
                        state.cursorPos = state.cursorPos - 1
                        ensureFocusVisible()
                        state.dirty = true
                    end
                elseif p1 == keys.right then
                    if state.cursorPos <= #str then
                        state.cursorPos = state.cursorPos + 1
                        ensureFocusVisible()
                        state.dirty = true
                    end
                elseif p1 == keys.home then
                    state.cursorPos = 1
                    ensureFocusVisible()
                    state.dirty = true
                elseif p1 == keys["end"] then
                    state.cursorPos = #str + 1
                    ensureFocusVisible()
                    state.dirty = true
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    state.focusLine = nil
                    state.dirty = true
                elseif p1 == keys.up then
                    local w = term.getSize()
                    local fieldW = getFieldWidth(w)
                    if state.cursorPos > fieldW then
                        state.cursorPos = state.cursorPos - fieldW
                        ensureFocusVisible()
                        state.dirty = true
                    elseif fLine > 1 then
                        state.focusLine = fLine - 1
                        state.cursorPos = math.min(state.cursorPos, #(state.editLines[state.focusLine].text or "") + 1)
                        ensureFocusVisible()
                        state.dirty = true
                    end
                elseif p1 == keys.down then
                    local w = term.getSize()
                    local fieldW = getFieldWidth(w)
                    if state.cursorPos + fieldW <= #str + 1 then
                        state.cursorPos = state.cursorPos + fieldW
                        ensureFocusVisible()
                        state.dirty = true
                    elseif fLine < #state.editLines then
                        state.focusLine = fLine + 1
                        state.cursorPos = math.min(state.cursorPos, #(state.editLines[state.focusLine].text or "") + 1)
                        ensureFocusVisible()
                        state.dirty = true
                    end
                end
            end

        -- Rednet-Signale fuer Emergency, Lockdown, Master-Sync und Remote-Update
        elseif ev == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == CFG.PROTOCOL and not state.updatingState then
                if message == CFG.MSG_ON then
                    if not state.emergencyActive then
                        state.emergencyActive = true
                        triggerAlertState()
                        state.dirty = true
                    end
                elseif message == CFG.MSG_OFF then
                    if state.emergencyActive then
                        state.emergencyActive = false
                        triggerAlertState()
                        state.dirty = true
                    end
                end
            elseif protocol == CFG.LOCKDOWN_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_LOCK then
                    if not state.lockdownActive then
                        state.lockdownActive = true
                        triggerAlertState()
                        state.dirty = true
                    end
                elseif message == CFG.MSG_UNLOCK then
                    if state.lockdownActive then
                        state.lockdownActive = false
                        triggerAlertState()
                        state.dirty = true
                    end
                end
            elseif protocol == CFG.CONFIG_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_STATUS then
                    sendReport(true, "Text: " .. getFirstLinePreview())
                elseif type(message) == "table" and message.action == "set_blink" then
                    if state.savedSyncBlink or state.editSyncBlink then
                        applyMasterBlinkConfig(message, message.isReply == true)
                    else
                        addLog("Master-Blink ignoriert (Sync ist aus).")
                    end
                end
            elseif protocol == CFG.UPDATE_PROTOCOL then
                if senderId == CFG.MASTER_ID and type(message) == "table" and message.action == "update" then
                    pcall(function() rednet.send(CFG.MASTER_ID, { action = "ping_ack" }, CFG.UPDATE_PROTOCOL) end)
                    local ok, err = pcall(applyUpdate, message.code)
                    if not ok then
                        state.updatingState = false
                        sendReport(false, "Update-Fehler: " .. tostring(err):sub(1, 30))
                        addLog("Update-Fehler!")
                        state.dirty = true
                    end
                    -- Nach abgeschlossenem/fehlgeschlagenem Update Timer sicher wiederherstellen
                    state.tickTimer    = os.startTimer(0.5)
                    state.blinkTimer   = nil
                    state.marqueeTimer = nil
                    updateTimers()
                end
            end

        -- Timer fuer Alarm-Takt, Laufschrift, Sync-Timeout und Logs
        elseif ev == "timer" then
            if p1 == state.blinkTimer then
                if state.emergencyActive or state.lockdownActive then
                    if isContinuousAlert() then
                        state.showAlertPhase = true
                        state.blinkTimer = nil
                        renderMonitor()
                    else
                        state.showAlertPhase = not state.showAlertPhase
                        renderMonitor()
                        state.blinkTimer = os.startTimer(math.max(0.05, getCurrentPhaseDuration()))
                    end
                else
                    state.blinkTimer = nil
                    state.showAlertPhase = false
                    renderMonitor()
                end
            elseif p1 == state.marqueeTimer then
                if hasAnySlidingLine() then
                    state.marqueeStep = state.marqueeStep + 1
                    if not ((state.emergencyActive or state.lockdownActive) and state.showAlertPhase) then
                        renderMonitor()
                    end
                    state.marqueeTimer = os.startTimer(math.max(0.05, state.savedSpeed))
                else
                    state.marqueeTimer = nil
                end
            elseif p1 == state.syncTimeoutTimer then
                state.syncTimeoutTimer = nil
                addLog("Master offline (nutze lokalen Blink-Takt).")
            elseif p1 == state.tickTimer then
                state.tickTimer = os.startTimer(0.5)
                local t = now()
                for i = #state.logs, 1, -1 do
                    if state.logs[i].expires <= t then
                        table.remove(state.logs, i)
                        state.dirty = true
                    end
                end
            end

        -- Monitor-Aenderungen live abfangen
        elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
            setupPeripherals()
            state.dirty = true
        end
    end
end

-- ==================================
-- KOMMENTAR: PROGRAMMSTART & FEHLERSCHUTZ
-- ==================================
loadConfig()
setupPeripherals()

while true do
    local ok, err = pcall(main)
    if not ok then
        if tostring(err):find("Terminated") then
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("Textanzeige beendet.")
            return
        end
        addLog("Fehler: " .. tostring(err))
        sleep(2)
    end
end