-- ============================================================================
-- KOMMENTAR: BUNKER LAUTSPRECHER & ALARM-AUDIO SYSTEM (CC:Tweaked / ATM10)
-- Streamt YouTube-Audio (auch nicht-gelistete Videos) im DFPWM-Format ueber
-- angeschlossene Speaker. Unterstuetzt Dauer-Loop, Redstone-, Spieler-, Funk-,
-- Radio- und Broadcast-Trigger sowie Emergency- & Lockdown-Alarme vom Master.
-- HINWEIS: Im Modus [ BROADCAST ] laeuft der Stream auch bei Emergency/Lockdown
-- ununterbrochen weiter (Oberflaechen-Durchsage)!
-- (Upvalue-optimiert fuer das Lua 5.1 Limit von max. 60 Upvalues)
-- ============================================================================

local dfpwm = require("cc.audio.dfpwm")

local CFG = {
    PROTOCOL                  = "notaus",
    LOCKDOWN_PROTOCOL         = "lockdown",
    UPDATE_PROTOCOL           = "speaker_update",
    CONFIG_PROTOCOL           = "speaker_config",
    TRIGGER_PROTOCOL          = "speaker_trigger",
    STREAM_PROTOCOL           = "bunker_radio_stream",
    BROADCAST_STREAM_PROTOCOL = "bunker_broadcast_stream",

    CONFIG_FILE = "speaker_config.txt",
    TEMP_FILE   = "startup.update_tmp",
    BACKUP_FILE = "startup.backup",
    GITHUB_URL  = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/Lautsprecher/startup.lua",
    API_URL     = "https://ipod-2to6magyna-uc.a.run.app/",
    API_VERSION = "2.1",

    MASTER_ID   = 24,
    COMPUTER_ID = os.getComputerID(),

    MSG_ON     = "EMERGENCY_ON",
    MSG_OFF    = "EMERGENCY_OFF",
    MSG_LOCK   = "LOCKDOWN_ON",
    MSG_UNLOCK = "LOCKDOWN_OFF",
    MSG_STATUS = "STATUS_REQUEST",

    MODES = { "MANUELL", "REDSTONE", "SPIELER", "FUNK", "RADIO", "BROADCAST" },

    -- Bis zu 24 Chunks (~384 KB) im RAM cachen fuer nahtlosen Loop ohne Nachladen
    MAX_CACHE_CHUNKS = 24,
    CHUNK_SIZE       = 16 * 1024,

    MAX_LOG = 2,
    LOG_TTL = 5
}

-- ==================================
-- KOMMENTAR: ZUSTANDS-TABELLE (BUNDELT UPVALUES FUER LUA 5.1)
-- ==================================
local state = {
    -- Gespeicherte lokale Einstellungen
    localUrl        = "",
    localVideoId    = "",
    localTitle      = "Kein Video",
    volumePct       = 50,     -- 0 bis 100 (100% = 3.0 in CC:Tweaked)
    loopEnabled     = true,
    triggerMode     = 1,      -- 1=MANUELL, 2=REDSTONE, 3=SPIELER, 4=FUNK, 5=RADIO, 6=BROADCAST
    sensorRange     = 5,
    userPlaying     = false,  -- Ob im manuellen Modus Play aktiv war

    -- Vom Master synchronisierte Alarm-, Radio- & Broadcast-Einstellungen
    emergencyUrl          = "",
    emergencyId           = "",
    emergencyTitle        = "",
    lockdownUrl           = "",
    lockdownId            = "",
    lockdownTitle         = "",
    alarmVolumePct        = 100,
    alarmVolSync          = true,  -- true = Master-Alarmlautstaerke, false = Manuelle Lautstaerke
    radioPlaylist         = {},
    radioTrackIdx         = 1,
    curRadioTrackIdx      = 1,
    curRadioTitle         = "",
    broadcastPlaylist     = {},
    broadcastTrackIdx     = 1,
    curBroadcastTrackIdx  = 1,
    curBroadcastTitle     = "",
    marqueeOffset         = 0,

    -- Update-Historie
    lastUpdateTime  = "-",
    lastUpdateStat  = "noch keins",

    -- UI-Eingabefeld
    fieldUrl        = "",
    focusUrl        = false,
    freshFocus      = false,

    -- Laufzeit-Zustaende
    emergencyActive = false,
    lockdownActive  = false,
    updatingState   = false,
    rsTriggered     = false,
    playerTriggered = false,
    remoteTriggered = false,

    -- Audio-Engine & HTTP-Streaming
    speakers        = {},
    modem           = nil,
    detector        = nil,
    decoder         = dfpwm.make_decoder(),
    activeTargetId  = nil,    -- Aktuell abgespielte 11-stellige YouTube-ID
    loadingUrl      = nil,    -- Aktuell laufender HTTP-Stream-Request
    searchUrl       = nil,    -- Aktuell laufender HTTP-Such-Request
    searchTarget    = nil,    -- "local" | "emergency" | "lockdown"
    streamHandle    = nil,
    streamFirstChunk = false,
    pendingBuffer   = nil,
    isLoadingAudio  = false,
    audioError      = nil,

    -- RAM-Cache fuer kurzen/mittellangen Loop-Sound (verhindert Lade-Pause beim Loop)
    cacheId         = nil,
    cacheChunks     = {},
    cacheComplete   = false,
    cacheReadIdx    = 1,

    cachedPos       = "GPS n.verf.",
    logs            = {},
    dirty           = true,

    tickTimer       = nil,
    sensorTimer     = nil,
    retryTimer      = nil
}

local hitboxes = {
    urlField     = nil,
    clearBtn     = nil,
    saveUrlBtn   = nil,
    playBtn      = nil,
    loopBtn      = nil,
    alarmSyncBtn = nil,
    modeBtn      = nil,
    rangeDec     = nil,
    rangeInc     = nil,
    volDec       = nil,
    volBar       = nil,
    volInc       = nil
}

-- ==================================
-- KOMMENTAR: HILFSFUNKTIONEN & YOUTUBE-ID PARSER
-- ==================================
local function now()
    return os.epoch("utc") / 1000
end

local function pad(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

local function getMarqueeText(str, maxLen, offset)
    str = tostring(str or "")
    if str == "" then return "" end
    if #str <= maxLen then
        return str
    end
    local spacer = "   ---   "
    local full = str .. spacer
    local fullLen = #full
    local startIdx = ((offset or 0) % fullLen) + 1
    local doubled = full .. full
    return doubled:sub(startIdx, startIdx + maxLen - 1)
end

state.cleanTitle = function(raw)
    local s = tostring(raw or "")
    s = s:gsub("\195\164", "ae"):gsub("\195\182", "oe"):gsub("\195\188", "ue")
    s = s:gsub("\195\132", "Ae"):gsub("\195\150", "Oe"):gsub("\195\156", "Ue"):gsub("\195\159", "ss")
    s = s:gsub("\226\128\147", "-"):gsub("\226\128\148", "-")
    s = s:gsub("[^\32-\126]", "")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

state.isBadTitle = function(t, id)
    local s = tostring(t or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "Kein Video" then return true end
    if id and s == tostring(id) then return true end
    local low = s:lower()
    if low:find("help me keep") or low:find("hosting is expensive") or low:find("patreon") then return true end
    if low:find("http://") or low:find("https://") or low:find("youtu%.be") or low:find("youtube%.com") then return true end
    return false
end

local function addLog(text)
    local w = term.getSize()
    local maxW = math.max(1, w - 2)
    table.insert(state.logs, { text = tostring(text):sub(1, maxW), expires = now() + CFG.LOG_TTL })
    while #state.logs > CFG.MAX_LOG do
        table.remove(state.logs, 1)
    end
    state.dirty = true
end

-- Extrahiert die 11-stellige YouTube-Video-ID aus beliebigen YouTube-Links oder direkter ID
local function extractYoutubeId(input)
    if type(input) ~= "string" then return "" end
    local s = input:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return "" end

    local patterns = {
        "[?&]v=([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "youtu%.be/([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "youtube%.com/shorts/([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "youtube%.com/embed/([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "^([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])$"
    }
    for _, pat in ipairs(patterns) do
        local id = s:match(pat)
        if id and #id == 11 then
            return id
        end
    end
    return ""
end

local function hasPendingUrlChange()
    local trimmed = (state.fieldUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return state.focusUrl and (#trimmed > 0)
end

state.getEffectiveAlarmVol = function()
    local pct = state.alarmVolSync and (tonumber(state.alarmVolumePct) or 100) or (tonumber(state.volumePct) or 50)
    return (math.max(0, math.min(100, pct)) / 100) * 3.0
end

-- ==================================
-- KOMMENTAR: KONFIGURATION LADEN & SPEICHERN
-- ==================================
local function saveConfig()
    local f = fs.open(CFG.CONFIG_FILE, "w")
    if not f then return false end
    f.write(textutils.serialize({
        localUrl          = state.localUrl,
        localVideoId      = state.localVideoId,
        localTitle        = state.localTitle,
        volumePct         = state.volumePct,
        loopEnabled       = state.loopEnabled,
        triggerMode       = state.triggerMode,
        sensorRange       = state.sensorRange,
        userPlaying       = state.userPlaying,
        emergencyUrl      = state.emergencyUrl,
        emergencyId       = state.emergencyId,
        emergencyTitle    = state.emergencyTitle,
        lockdownUrl       = state.lockdownUrl,
        lockdownId        = state.lockdownId,
        lockdownTitle     = state.lockdownTitle,
        alarmVolumePct    = state.alarmVolumePct,
        alarmVolSync      = state.alarmVolSync,
        radioPlaylist     = state.radioPlaylist,
        radioTrackIdx     = state.radioTrackIdx,
        broadcastPlaylist = state.broadcastPlaylist,
        broadcastTrackIdx = state.broadcastTrackIdx,
        lastUpdateTime    = state.lastUpdateTime,
        lastUpdateStat    = state.lastUpdateStat
    }))
    f.close()
    return true
end

local function loadConfig()
    if fs.exists(CFG.CONFIG_FILE) then
        local f = fs.open(CFG.CONFIG_FILE, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then
                if type(data.localUrl) == "string" then state.localUrl = data.localUrl end
                if type(data.localVideoId) == "string" then state.localVideoId = data.localVideoId end
                if type(data.localTitle) == "string" then state.localTitle = state.cleanTitle(data.localTitle) end
                if type(data.volumePct) == "number" then state.volumePct = math.max(0, math.min(100, data.volumePct)) end
                if type(data.loopEnabled) == "boolean" then state.loopEnabled = data.loopEnabled end
                if type(data.triggerMode) == "number" and CFG.MODES[data.triggerMode] then state.triggerMode = data.triggerMode end
                if type(data.sensorRange) == "number" then state.sensorRange = math.max(1, math.min(50, data.sensorRange)) end
                if type(data.userPlaying) == "boolean" then state.userPlaying = data.userPlaying end
                if type(data.emergencyUrl) == "string" then state.emergencyUrl = data.emergencyUrl end
                if type(data.emergencyId) == "string" then state.emergencyId = data.emergencyId end
                if type(data.emergencyTitle) == "string" then state.emergencyTitle = state.cleanTitle(data.emergencyTitle) end
                if type(data.lockdownUrl) == "string" then state.lockdownUrl = data.lockdownUrl end
                if type(data.lockdownId) == "string" then state.lockdownId = data.lockdownId end
                if type(data.lockdownTitle) == "string" then state.lockdownTitle = state.cleanTitle(data.lockdownTitle) end
                if type(data.alarmVolumePct) == "number" then state.alarmVolumePct = math.max(0, math.min(100, data.alarmVolumePct)) end
                if type(data.alarmVolSync) == "boolean" then state.alarmVolSync = data.alarmVolSync end
                if type(data.radioPlaylist) == "table" then state.radioPlaylist = data.radioPlaylist end
                if type(data.radioTrackIdx) == "number" then state.radioTrackIdx = math.max(1, data.radioTrackIdx) end
                if type(data.broadcastPlaylist) == "table" then state.broadcastPlaylist = data.broadcastPlaylist end
                if type(data.broadcastTrackIdx) == "number" then state.broadcastTrackIdx = math.max(1, data.broadcastTrackIdx) end
                if type(data.lastUpdateTime) == "string" then state.lastUpdateTime = data.lastUpdateTime end
                if type(data.lastUpdateStat) == "string" then state.lastUpdateStat = data.lastUpdateStat end

                -- Falls localVideoId durch alten API-Werbeeintrag ueberschrieben wurde, aus localUrl wiederherstellen
                if state.localVideoId == "9Se1cKmJ_Ik" and state.localUrl ~= "" then
                    local origId = extractYoutubeId(state.localUrl)
                    if origId ~= "" and origId ~= "9Se1cKmJ_Ik" then
                        state.localVideoId = origId
                    end
                end
                state.fieldUrl = ""
                return true
            end
        end
    end
    state.fieldUrl = ""
    return false
end

-- ==================================
-- KOMMENTAR: GPS-CACHE & MASTER-REPORTING
-- ==================================
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

local function getPreviewString()
    local modeName = CFG.MODES[state.triggerMode] or "MANUELL"
    local songInfo = "Kein Video"
    if modeName == "RADIO" then
        if state.curRadioTitle and state.curRadioTitle ~= "" then
            songInfo = state.curRadioTitle
        elseif type(state.radioPlaylist) == "table" and #state.radioPlaylist > 0 then
            local curIdx = math.max(1, math.min(#state.radioPlaylist, state.radioTrackIdx or 1))
            local trk = state.radioPlaylist[curIdx]
            songInfo = (trk and trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "Radio-Track"
        else
            songInfo = "Bunker-Radio"
        end
    elseif modeName == "BROADCAST" then
        if state.curBroadcastTitle and state.curBroadcastTitle ~= "" then
            songInfo = state.curBroadcastTitle
        elseif type(state.broadcastPlaylist) == "table" and #state.broadcastPlaylist > 0 then
            local curIdx = math.max(1, math.min(#state.broadcastPlaylist, state.broadcastTrackIdx or 1))
            local trk = state.broadcastPlaylist[curIdx]
            songInfo = (trk and trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "Broadcast-Track"
        else
            songInfo = "Broadcast"
        end
        return "BROADCAST (" .. songInfo:sub(1, 16) .. ")"
    elseif state.localVideoId ~= "" then
        songInfo = (not state.isBadTitle(state.localTitle, state.localVideoId)) and state.localTitle or "YouTube-Video"
    end

    if state.lockdownActive then
        return "LOCKDOWN-ALARM"
    elseif state.emergencyActive then
        return "EMERGENCY-ALARM"
    elseif state.activeTargetId then
        return "Spielt (" .. modeName .. ": " .. songInfo:sub(1, 18) .. ")"
    else
        return modeName .. " (" .. songInfo:sub(1, 18) .. ")"
    end
end

local function sendReport(success, details)
    if not state.modem then return end
    local label = os.getComputerLabel() or ("Speaker " .. tostring(CFG.COMPUTER_ID))
    local preview = getPreviewString()
    pcall(function()
        rednet.send(CFG.MASTER_ID, {
            action  = "log_report",
            success = success,
            details = details or ("Online: " .. preview),
            pos     = state.cachedPos,
            label   = label,
            preview = preview,
            devType = "speaker"
        }, CFG.UPDATE_PROTOCOL)
    end)
end

-- ==================================
-- KOMMENTAR: PERIPHERIE & REDSTONE PRUEFUNG
-- ==================================
local function setupPeripherals()
    state.speakers = { peripheral.find("speaker") }
    state.modem    = peripheral.find("modem")
    state.detector = peripheral.find("player_detector")

    if state.modem then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then
                pcall(rednet.open, name)
            end
        end
    end
    state.dirty = true
end

local function isAnyRedstoneActive()
    for _, side in ipairs(rs.getSides()) do
        if rs.getInput(side) then
            return true
        end
    end
    return false
end

local function isPlayerInRange()
    if not state.detector then return false end
    local ok, players = pcall(function() return state.detector.getPlayersInRange(state.sensorRange) end)
    return ok and type(players) == "table" and #players > 0
end

-- ==================================
-- KOMMENTAR: AUDIO-ENGINE (NICHT-BLOCKIEREND MIT RAM-CACHE)
-- ==================================
local function closeStreamHandle()
    if state.streamHandle then
        pcall(state.streamHandle.close)
        state.streamHandle = nil
    end
end

local function stopAllSpeakers()
    closeStreamHandle()
    state.pendingBuffer  = nil
    state.activeTargetId = nil
    state.loadingUrl     = nil
    state.isLoadingAudio = false
    for _, spk in ipairs(state.speakers) do
        pcall(spk.stop)
    end
    state.dirty = true
end

-- Ermittelt, welche Video-ID aktuell abgespielt werden soll
-- WICHTIG: Im Modus [ BROADCAST ] wird KEIN Emergency/Lockdown-Alarm abgespielt!
local function getDesiredPlayback()
    if state.updatingState then
        return nil, 0, false
    end

    local mode = CFG.MODES[state.triggerMode]
    if mode == "BROADCAST" then
        -- Broadcast-Stream wird direkt per Rednet vom BroadcastHost empfangen (auch bei Emergency/Lockdown!)
        return nil, 0, false
    end

    if state.lockdownActive then
        if state.lockdownId ~= "" then
            return state.lockdownId, state.getEffectiveAlarmVol(), true
        end
        return nil, 0, false
    elseif state.emergencyActive then
        if state.emergencyId ~= "" then
            return state.emergencyId, state.getEffectiveAlarmVol(), true
        end
        return nil, 0, false
    end

    -- Normalbetrieb: Je nach gewaehltem Trigger-Modus
    local vol = (state.volumePct / 100) * 3.0
    local shouldPlay = false

    if mode == "MANUELL" then
        shouldPlay = state.userPlaying
    elseif mode == "REDSTONE" then
        shouldPlay = state.rsTriggered
    elseif mode == "SPIELER" then
        shouldPlay = state.playerTriggered
    elseif mode == "FUNK" then
        shouldPlay = state.remoteTriggered
    elseif mode == "RADIO" then
        -- Radio-Stream laeuft ueber den zentralen RadioHost per Rednet (DFPWM Chunks)
        return nil, 0, false
    end

    if shouldPlay and state.localVideoId ~= "" then
        return state.localVideoId, vol, state.loopEnabled
    end
    return nil, 0, false
end

-- Spielt einen einzelnen Puffer auf allen angeschlossenen Speakern ab
local function pushBufferToSpeakers(pcmBuffer, vol)
    if #state.speakers == 0 or vol <= 0.001 then
        return true
    end
    local allAccepted = true
    for _, spk in ipairs(state.speakers) do
        local ok, accepted = pcall(spk.playAudio, pcmBuffer, vol)
        if ok and not accepted then
            allAccepted = false
        end
    end
    return allAccepted
end

-- Startet den Download-Stream fuer eine Video-ID
local function requestAudioStream(videoId)
    closeStreamHandle()
    state.pendingBuffer = nil

    -- Falls dieser Track bereits vollstaendig im RAM-Cache liegt, direkt aus RAM abspielen!
    if state.cacheId == videoId and state.cacheComplete and #state.cacheChunks > 0 then
        state.cacheReadIdx   = 1
        state.isLoadingAudio = false
        state.audioError     = nil
        state.decoder        = dfpwm.make_decoder()
        state.dirty          = true
        os.queueEvent("speaker_feed")
        return
    end

    if not http then
        state.audioError = "HTTP inaktiv"
        state.dirty = true
        return
    end

    state.cacheId       = videoId
    state.cacheChunks   = {}
    state.cacheComplete = false
    state.cacheReadIdx  = 1

    local url = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&id=" .. textutils.urlEncode(videoId)
    state.loadingUrl     = url
    state.isLoadingAudio = true
    state.audioError     = nil
    state.dirty          = true
    http.request({ url = url, binary = true })
end

-- Liest den naechsten Audio-Chunk (aus RAM-Cache oder HTTP-Stream) und gibt ihn an die Speaker
local function feedNextAudioChunk()
    local targetId, vol, shouldLoop = getDesiredPlayback()
    if not targetId or targetId ~= state.activeTargetId then
        return
    end
    if state.isLoadingAudio then
        return
    end

    -- 1. Falls noch ein ungesendeter Puffer wartet (weil Speaker-Puffer voll war)
    if state.pendingBuffer then
        if pushBufferToSpeakers(state.pendingBuffer, vol) then
            state.pendingBuffer = nil
        else
            return -- Warten auf naechstes speaker_audio_empty
        end
    end

    -- 2. Aus RAM-Cache lesen (wenn bereits vollstaendig gecacht)
    if state.cacheId == targetId and state.cacheComplete and not state.streamHandle then
        local rawChunk = state.cacheChunks[state.cacheReadIdx]
        if rawChunk then
            state.cacheReadIdx = state.cacheReadIdx + 1
            local pcm = state.decoder(rawChunk)
            if not pushBufferToSpeakers(pcm, vol) then
                state.pendingBuffer = pcm
            else
                os.queueEvent("speaker_feed")
            end
            return
        else
            -- Ende des gecachten Tracks erreicht
            if shouldLoop then
                state.cacheReadIdx = 1
                state.decoder = dfpwm.make_decoder()
                os.queueEvent("speaker_feed")
            else
                -- Einmalige Wiedergabe beendet
                if CFG.MODES[state.triggerMode] == "MANUELL" then state.userPlaying = false; saveConfig() end
                state.rsTriggered     = false
                state.playerTriggered = false
                state.remoteTriggered = false
                stopAllSpeakers()
            end
            return
        end
    end

    -- 3. Aus aktivem HTTP-Stream lesen
    if state.streamHandle then
        local chunk = state.streamHandle.read(CFG.CHUNK_SIZE)
        if chunk and #chunk > 0 then
            if state.cacheId == targetId then
                if #state.cacheChunks < CFG.MAX_CACHE_CHUNKS then
                    table.insert(state.cacheChunks, chunk)
                else
                    -- Track ist zu lang fuer den kleinen RAM-Cache -> normal weiterstreamen
                    state.cacheId = nil
                    state.cacheChunks = {}
                    state.cacheComplete = false
                end
            end
            local pcm = state.decoder(chunk)
            if not pushBufferToSpeakers(pcm, vol) then
                state.pendingBuffer = pcm
            else
                os.queueEvent("speaker_feed")
            end
        else
            -- Stream ist zu Ende!
            closeStreamHandle()
            if state.cacheId == targetId and #state.cacheChunks > 0 then
                state.cacheComplete = true
            end
            if shouldLoop then
                requestAudioStream(targetId)
            else
                if CFG.MODES[state.triggerMode] == "MANUELL" then state.userPlaying = false; saveConfig() end
                state.rsTriggered     = false
                state.playerTriggered = false
                state.remoteTriggered = false
                stopAllSpeakers()
            end
        end
    end
end

-- Synchronisiert den aktuellen Audio-Zustand mit dem Soll-Zustand (Alarm / Trigger / Stop)
local function syncAudioEngine()
    local desiredId = getDesiredPlayback()
    if not desiredId then
        if state.activeTargetId or state.isLoadingAudio then
            stopAllSpeakers()
        end
        return
    end

    if state.activeTargetId ~= desiredId then
        stopAllSpeakers()
        state.activeTargetId = desiredId
        requestAudioStream(desiredId)
    elseif not state.isLoadingAudio and not state.streamHandle and not (state.cacheId == desiredId and state.cacheComplete) then
        requestAudioStream(desiredId)
    end
end

-- Loest Link/ID oder Suchbegriff auf und laedt den echten Videotitel ueber YouTube oEmbed
local function resolveInputToVideoId(rawInput, targetType)
    local trimmed = tostring(rawInput or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return ""
    end
    local directId = extractYoutubeId(trimmed)
    if directId ~= "" then
        if http and state.searchUrl == nil then
            local oUrl = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=" .. directId .. "&format=json"
            state.searchUrl    = oUrl
            state.searchTarget = targetType
            http.request(oUrl)
        end
        return directId
    end
    if http then
        local sUrl = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&search=" .. textutils.urlEncode(trimmed)
        state.searchUrl    = sUrl
        state.searchTarget = targetType
        http.request(sUrl)
        addLog("Suche Video: " .. trimmed:sub(1, 20))
    end
    return ""
end

-- ==================================
-- KOMMENTAR: TERMINAL UI ZEICHNEN (BUNKER-STYLE)
-- ==================================
local function drawUI()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    hitboxes.urlField     = nil
    hitboxes.clearBtn     = nil
    hitboxes.saveUrlBtn   = nil
    hitboxes.playBtn      = nil
    hitboxes.loopBtn      = nil
    hitboxes.alarmSyncBtn = nil
    hitboxes.modeBtn      = nil
    hitboxes.rangeDec     = nil
    hitboxes.rangeInc     = nil
    hitboxes.volDec       = nil
    hitboxes.volBar       = nil
    hitboxes.volInc       = nil

    local modeName        = CFG.MODES[state.triggerMode] or "MANUELL"
    local isRadioMode     = (modeName == "RADIO")
    local isBroadcastMode = (modeName == "BROADCAST")
    local isStreamMode    = (isRadioMode or isBroadcastMode)
    local fieldX          = 2
    local btnW            = 10
    local btnX            = w - btnW
    local fieldW          = math.max(10, btnX - fieldX - 2)

    -- 1. Kopfzeile
    term.setCursorPos(2, 1)
    term.setTextColor(colors.cyan)
    term.write("--- LAUTSPRECHER ---")
    local idStr = "ID:" .. tostring(CFG.COMPUTER_ID)
    term.setCursorPos(math.max(1, w - #idStr), 1)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    -- 2. Status-Zeile
    term.setCursorPos(2, 3)
    term.setTextColor(colors.white)
    term.write("Status: ")
    if state.updatingState then
        term.setTextColor(colors.yellow)
        term.write("WARTUNG / UPDATING")
    elseif #state.speakers == 0 then
        term.setTextColor(colors.red)
        term.write("FEHLER: KEIN SPEAKER!")
    elseif isBroadcastMode then
        term.setTextColor(colors.magenta)
        term.write("EMPFANG (BROADCAST 24/7)")
    elseif state.lockdownActive then
        term.setTextColor(colors.red)
        term.write("LOCKDOWN (ALARM-TON)")
    elseif state.emergencyActive then
        term.setTextColor(colors.red)
        term.write("EMERGENCY (ALARM-TON)")
    elseif state.isLoadingAudio then
        term.setTextColor(colors.yellow)
        term.write("LADE AUDIO STREAM...")
    elseif state.audioError then
        term.setTextColor(colors.red)
        term.write("FEHLER: " .. tostring(state.audioError):sub(1, w - 18))
    elseif isRadioMode then
        term.setTextColor(colors.lime)
        term.write("EMPFANG (BUNKER-RADIO)")
    elseif state.activeTargetId then
        term.setTextColor(colors.lime)
        term.write("SPIELT (" .. modeName .. ")")
    else
        term.setTextColor(colors.green)
        term.write("BEREIT (" .. tostring(#state.speakers) .. " Speaker)")
    end

    if isRadioMode then
        -- 3. Radio-Wiedergabe & Track-Titel (Marquee)
        term.setCursorPos(2, 5)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.cyan)
        term.write("BUNKER-RADIO:")
        local curIdx = state.curRadioTrackIdx or state.radioTrackIdx or 1
        if type(state.radioPlaylist) == "table" and #state.radioPlaylist > 0 then
            curIdx = math.max(1, math.min(#state.radioPlaylist, curIdx))
            term.setTextColor(colors.white)
            term.write(string.format(" Track %d/%d", curIdx, #state.radioPlaylist))
        else
            term.setTextColor(colors.white)
            term.write(string.format(" Track %d", curIdx))
        end

        local curTrackTitle = (state.curRadioTitle and state.curRadioTitle ~= "") and state.curRadioTitle or "Kein Track verfuegbar"
        if curTrackTitle == "Kein Track verfuegbar" and type(state.radioPlaylist) == "table" and #state.radioPlaylist > 0 then
            local trk = state.radioPlaylist[curIdx]
            curTrackTitle = (trk and trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"
        end

        term.setCursorPos(2, 6)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        local radioMarquee = getMarqueeText(curTrackTitle, w - 4, state.marqueeOffset)
        term.write(" " .. pad(radioMarquee, w - 4) .. " ")

        -- 4. Status-Hinweis (Play/Stop & Loop deaktiviert im Radio-Modus)
        term.setCursorPos(2, 8)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.write("Live-Stream aktiv (Zentraler Radio-Host)")
    elseif isBroadcastMode then
        -- 3. Broadcast-Wiedergabe & Track-Titel (Marquee)
        term.setCursorPos(2, 5)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.magenta)
        term.write("OBERFLAECHEN-BROADCAST:")
        local curIdx = state.curBroadcastTrackIdx or state.broadcastTrackIdx or 1
        if type(state.broadcastPlaylist) == "table" and #state.broadcastPlaylist > 0 then
            curIdx = math.max(1, math.min(#state.broadcastPlaylist, curIdx))
            term.setTextColor(colors.white)
            term.write(string.format(" Track %d/%d", curIdx, #state.broadcastPlaylist))
        else
            term.setTextColor(colors.white)
            term.write(string.format(" Track %d", curIdx))
        end

        local curTrackTitle = (state.curBroadcastTitle and state.curBroadcastTitle ~= "") and state.curBroadcastTitle or "Kein Track verfuegbar"
        if curTrackTitle == "Kein Track verfuegbar" and type(state.broadcastPlaylist) == "table" and #state.broadcastPlaylist > 0 then
            local trk = state.broadcastPlaylist[curIdx]
            curTrackTitle = (trk and trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"
        end

        term.setCursorPos(2, 6)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        local bcMarquee = getMarqueeText(curTrackTitle, w - 4, state.marqueeOffset)
        term.write(" " .. pad(bcMarquee, w - 4) .. " ")

        -- 4. Status-Hinweis (Broadcast ignoriert Emergency/Lockdown!)
        term.setCursorPos(2, 8)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.write("24/7 Loop aktiv (Ignoriert Emergency/Lockdown)")
    else
        -- 3. Eingabefeld fuer lokales YouTube-Video (zeigt im Ruhezustand den Videotitel als Lauftext!)
        term.setCursorPos(2, 5)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        if state.focusUrl then
            term.write("YouTube-Link einfuegen (Strg+V):")
        else
            term.write("Aktuelles Video (Klick zum Aendern):")
        end

        local clrX = w - 6
        term.setCursorPos(clrX, 5)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" CLR ")
        hitboxes.clearBtn = { x1 = clrX, x2 = clrX + 4, y = 5 }

        term.setCursorPos(fieldX, 6)
        if state.focusUrl then
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.black)
            local dispUrl = state.fieldUrl or ""
            if #dispUrl > fieldW then
                dispUrl = dispUrl:sub(#dispUrl - fieldW + 1)
            end
            term.write(pad(dispUrl, fieldW))
        else
            term.setBackgroundColor(colors.gray)
            if state.localVideoId ~= "" then
                term.setTextColor(colors.white)
                local songTitle = (not state.isBadTitle(state.localTitle, state.localVideoId)) and state.localTitle or "Lade Videotitel..."
                local songMarquee = getMarqueeText(songTitle, fieldW - 2, state.marqueeOffset)
                term.write(" " .. pad(songMarquee, fieldW - 2) .. " ")
            else
                term.setTextColor(colors.lightGray)
                term.write(pad(" [ Hier klicken & Link einfuegen ]", fieldW))
            end
        end
        hitboxes.urlField = { x1 = fieldX, x2 = fieldX + fieldW - 1, y = 6 }

        local isUrlDirty = hasPendingUrlChange()
        term.setCursorPos(btnX, 6)
        term.setBackgroundColor(isUrlDirty and colors.orange or colors.green)
        term.setTextColor(colors.black)
        term.write(pad("  SETZEN  ", btnW))
        hitboxes.saveUrlBtn = { x1 = btnX, x2 = btnX + btnW - 1, y = 6 }

        -- 4. Play / Stop & Loop-Schalter
        term.setCursorPos(2, 8)
        local isPlayingLocal = (state.activeTargetId ~= nil and not state.emergencyActive and not state.lockdownActive)
        if isPlayingLocal then
            term.setBackgroundColor(colors.red)
            term.setTextColor(colors.white)
            term.write("   STOP   ")
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.write("   PLAY   ")
        end
        hitboxes.playBtn = { x1 = 2, x2 = 11, y = 8 }

        term.setCursorPos(14, 8)
        if state.loopEnabled then
            term.setBackgroundColor(colors.green)
            term.setTextColor(colors.black)
            term.write(" [x] LOOP AN  ")
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.write(" [ ] LOOP AUS ")
        end
        hitboxes.loopBtn = { x1 = 14, x2 = 27, y = 8 }
    end

    -- 5. Ausloeser-Modus (MANUELL / REDSTONE / SPIELER / FUNK / RADIO / BROADCAST)
    term.setCursorPos(2, 10)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write("Modus: ")

    modeName = CFG.MODES[state.triggerMode] or "MANUELL"
    local modeBg   = colors.gray
    local modeFg   = colors.white
    if modeName == "REDSTONE" then modeBg = colors.orange; modeFg = colors.black
    elseif modeName == "SPIELER" then modeBg = colors.cyan; modeFg = colors.black
    elseif modeName == "FUNK" then modeBg = colors.purple; modeFg = colors.white
    elseif modeName == "RADIO" then modeBg = colors.yellow; modeFg = colors.black
    elseif modeName == "BROADCAST" then modeBg = colors.magenta; modeFg = colors.white
    end

    term.setCursorPos(9, 10)
    term.setBackgroundColor(modeBg)
    term.setTextColor(modeFg)
    local mStr = " [ " .. modeName .. " ] "
    term.write(mStr)
    hitboxes.modeBtn = { x1 = 9, x2 = 9 + #mStr - 1, y = 10 }

    if modeName == "SPIELER" then
        local rX = 9 + #mStr + 2
        term.setCursorPos(rX, 10)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" - ")
        hitboxes.rangeDec = { x1 = rX, x2 = rX + 2, y = 10 }

        term.setBackgroundColor(colors.black)
        term.setTextColor( state.detector and colors.white or colors.red )
        local rTxt = string.format(" %dm ", state.sensorRange)
        term.write(rTxt)

        local incX = rX + 3 + #rTxt
        term.setCursorPos(incX, 10)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" + ")
        hitboxes.rangeInc = { x1 = incX, x2 = incX + 2, y = 10 }
    end

    -- 6. Lautstaerke-Slider (0% - 100%)
    local volY = 12
    term.setCursorPos(2, volY)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write(pad(string.format("Lautst.: %3d%%", state.volumePct), 14))

    local barX = 16
    local bW   = math.max(6, w - barX - 6)
    term.setCursorPos(barX, volY)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" < ")

    local knobPos = math.floor((state.volumePct / 100) * (bW - 1) + 0.5) + 1
    knobPos = math.max(1, math.min(bW, knobPos))

    for i = 1, bW do
        term.setCursorPos(barX + 2 + i, volY)
        if i == knobPos then
            term.setBackgroundColor(colors.orange)
            term.setTextColor(colors.black)
            term.write("O")
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
            term.write("-")
        end
    end

    term.setCursorPos(barX + 3 + bW, volY)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" > ")

    hitboxes.volDec = { x1 = barX, x2 = barX + 2, y = volY }
    hitboxes.volBar = { x1 = barX + 3, x2 = barX + 2 + bW, y = volY, width = bW }
    hitboxes.volInc = { x1 = barX + 3 + bW, x2 = barX + 5 + bW, y = volY }

    -- 7. Alarm-Lautstaerke Sync-Button (Zeile 14) & Alarm-Info (Zeile 15)
    term.setCursorPos(2, 14)
    term.setBackgroundColor(colors.black)
    if isBroadcastMode then
        term.setTextColor(colors.magenta)
        term.write("Alarm-Status: Deaktiviert im Broadcast-Modus")
    else
        term.setTextColor(colors.lightGray)
        term.write("Alarm-Lautst.: ")
        local syncBtnX = 17
        term.setCursorPos(syncBtnX, 14)
        local syncLabel
        if state.alarmVolSync then
            term.setBackgroundColor(colors.green)
            term.setTextColor(colors.black)
            syncLabel = string.format(" [x] Sync (Master: %d%%) ", tonumber(state.alarmVolumePct) or 100)
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            syncLabel = string.format(" [ ] Sync (Manuell: %d%%) ", tonumber(state.volumePct) or 50)
        end
        term.write(syncLabel)
        hitboxes.alarmSyncBtn = { x1 = syncBtnX, x2 = syncBtnX + #syncLabel - 1, y = 14 }
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 15)
    local emStat = (state.emergencyId ~= "") and ((not state.isBadTitle(state.emergencyTitle, state.emergencyId)) and state.emergencyTitle or "Gesetzt") or "Aus"
    local ldStat = (state.lockdownId ~= "") and ((not state.isBadTitle(state.lockdownTitle, state.lockdownId)) and state.lockdownTitle or "Gesetzt") or "Aus"
    local alarmInfo = string.format("Alert: EM[%s] LD[%s] | Upd:[%s]", emStat, ldStat, tostring(state.lastUpdateTime))
    term.write(pad(getMarqueeText(alarmInfo, w - 2, state.marqueeOffset), w - 2))

    -- 8. Temporaere Debug-Logs unten
    term.setTextColor(colors.gray)
    local startRow = h - #state.logs + 1
    for i, entry in ipairs(state.logs) do
        term.setCursorPos(2, startRow + i - 1)
        term.write(pad(entry.text, w - 2))
    end

    if state.focusUrl and not isStreamMode then
        term.setBackgroundColor(colors.lightGray)
        term.setTextColor(colors.black)
        local curX = fieldX + math.min(#(state.fieldUrl or ""), fieldW - 1)
        term.setCursorPos(curX, 6)
        term.setCursorBlink(true)
    else
        term.setCursorBlink(false)
    end
end

-- ==================================
-- KOMMENTAR: AKTIONEN, TRIGGER & REMOTE-UPDATE
-- ==================================
local function applyUrlField()
    local trimmed = (state.fieldUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
    state.focusUrl = false
    state.fieldUrl = ""

    if trimmed == "" then
        state.dirty = true
        return
    end

    state.localUrl = trimmed
    local vid = resolveInputToVideoId(trimmed, "local")
    if vid ~= "" then
        state.localVideoId = vid
        state.localTitle   = "Lade Videotitel..."
        saveConfig()
        addLog("Lade Videotitel...")
        if state.activeTargetId and not state.emergencyActive and not state.lockdownActive then
            state.activeTargetId = nil
        end
        syncAudioEngine()
    end
    state.dirty = true
end

local function applyMasterAlarmConfig(msg, isReply)
    if type(msg) ~= "table" then return end
    if type(msg.emergencyTitle) == "string" then
        state.emergencyTitle = state.cleanTitle(msg.emergencyTitle)
    end
    if type(msg.lockdownTitle) == "string" then
        state.lockdownTitle = state.cleanTitle(msg.lockdownTitle)
    end
    if type(msg.emergencyUrl) == "string" then
        state.emergencyUrl = msg.emergencyUrl
        state.emergencyId  = extractYoutubeId(msg.emergencyUrl)
        if state.emergencyUrl ~= "" and state.emergencyId == "" then
            resolveInputToVideoId(state.emergencyUrl, "emergency")
        elseif state.emergencyId ~= "" and state.isBadTitle(state.emergencyTitle, state.emergencyId) then
            resolveInputToVideoId(state.emergencyId, "emergency")
        end
    end
    if type(msg.lockdownUrl) == "string" then
        state.lockdownUrl = msg.lockdownUrl
        state.lockdownId  = extractYoutubeId(msg.lockdownUrl)
        if state.lockdownUrl ~= "" and state.lockdownId == "" then
            resolveInputToVideoId(state.lockdownUrl, "lockdown")
        elseif state.lockdownId ~= "" and state.isBadTitle(state.lockdownTitle, state.lockdownId) then
            resolveInputToVideoId(state.lockdownId, "lockdown")
        end
    end
    if type(msg.alarmVol) == "number" then
        state.alarmVolumePct = math.max(0, math.min(100, math.floor(msg.alarmVol + 0.5)))
    end
    saveConfig()
    syncAudioEngine()
    addLog(isReply and "Sync: Alarm-Daten vom Master geladen." or "Master: Alarm-Sounds aktualisiert!")
    sendReport(true, string.format("Alarm-Sync aktiv (Vol:%d%%)", state.alarmVolumePct))
    state.dirty = true
end

local function checkTriggers()
    local mode = CFG.MODES[state.triggerMode]
    if mode == "REDSTONE" then
        local active = isAnyRedstoneActive()
        if active and not state.rsTriggered then
            state.rsTriggered = true
            syncAudioEngine()
        elseif not active and state.rsTriggered and state.loopEnabled then
            state.rsTriggered = false
            syncAudioEngine()
        end
    elseif mode == "SPIELER" then
        local active = isPlayerInRange()
        if active and not state.playerTriggered then
            state.playerTriggered = true
            syncAudioEngine()
        elseif not active and state.playerTriggered and state.loopEnabled then
            state.playerTriggered = false
            syncAudioEngine()
        end
    end
end

local function applyUpdate()
    state.updatingState = true
    stopAllSpeakers()
    addLog("Lade Update von GitHub...")
    drawUI()

    local function failUpdate(reason)
        state.lastUpdateTime = os.date("%H:%M:%S")
        state.lastUpdateStat = "fehlgeschlagen"
        state.updatingState  = false
        saveConfig()
        sendReport(false, reason)
        addLog("Update fehlgeschlagen: " .. reason)
        drawUI()
        return false
    end

    if not http then
        return failUpdate("HTTP inaktiv")
    end

    local url = CFG.GITHUB_URL .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local res, httpErr, failResp = http.get(url)
    if not res then
        local why = tostring(httpErr)
        if failResp and failResp.getResponseCode then
            why = "HTTP " .. tostring(failResp.getResponseCode())
            pcall(failResp.close)
        end
        return failUpdate("Download (" .. why:sub(1, 20) .. ")")
    end

    local content = res.readAll()
    res.close()
    if not content or #content == 0 then
        return failUpdate("Datei leer")
    end

    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return failUpdate("HTML statt Code erhalten")
    end

    local tf = fs.open(CFG.TEMP_FILE, "w")
    if not tf then
        return failUpdate("Schreibfehler Temp")
    end
    tf.write(content)
    tf.close()

    local compiled = loadfile(CFG.TEMP_FILE)
    fs.delete(CFG.TEMP_FILE)
    if not compiled then
        return failUpdate("Syntaxfehler im Code")
    end

    if fs.exists(CFG.BACKUP_FILE) then fs.delete(CFG.BACKUP_FILE) end
    if fs.exists("startup.lua") then
        pcall(fs.copy, "startup.lua", CFG.BACKUP_FILE)
    elseif fs.exists("startup") then
        pcall(fs.copy, "startup", CFG.BACKUP_FILE)
    end

    local f = fs.open("startup.lua", "w")
    if not f then
        return failUpdate("Schreibfehler startup.lua")
    end
    f.write(content)
    f.close()

    if fs.exists("startup") then fs.delete("startup") end

    state.lastUpdateTime = os.date("%H:%M:%S")
    state.lastUpdateStat = "erfolgreich"
    saveConfig()

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
    if state.localVideoId ~= "" and state.isBadTitle(state.localTitle, state.localVideoId) then
        resolveInputToVideoId(state.localVideoId, "local")
    end

    if state.modem then
        refreshGpsCache()
        rednet.broadcast(CFG.MSG_STATUS, CFG.PROTOCOL)
        rednet.broadcast(CFG.MSG_STATUS, CFG.LOCKDOWN_PROTOCOL)
        pcall(function()
            rednet.send(CFG.MASTER_ID, { action = "request_speaker_sync" }, CFG.CONFIG_PROTOCOL)
        end)
        sendReport(true)
    end

    state.tickTimer   = os.startTimer(0.5)
    state.sensorTimer = os.startTimer(0.5)
    checkTriggers()
    syncAudioEngine()

    while true do
        if state.dirty then
            drawUI()
            state.dirty = false
        end

        local ev, p1, p2, p3 = os.pullEvent()

        -- 1. Audio-Feeding (nicht-blockierend pro Chunk)
        if ev == "speaker_audio_empty" or ev == "speaker_feed" then
            feedNextAudioChunk()

        -- 2. HTTP-Antworten fuer Audio-Stream & YouTube-Titel/Suche
        elseif ev == "http_success" then
            local url, handle = p1, p2
            if url == state.loadingUrl then
                state.loadingUrl     = nil
                state.isLoadingAudio = false
                state.streamHandle   = handle
                state.decoder        = dfpwm.make_decoder()
                state.dirty          = true
                feedNextAudioChunk()
            elseif url == state.searchUrl then
                state.searchUrl = nil
                local body = handle.readAll()
                handle.close()
                local results = textutils.unserializeJSON(body)
                if type(results) == "table" and type(results.title) == "string" and #results.title > 0 then
                    -- Offizielle YouTube oEmbed Antwort
                    local clean = state.cleanTitle(results.title)
                    if state.searchTarget == "local" then
                        state.localTitle = (clean ~= "" and clean or "YouTube-Video")
                        saveConfig()
                        addLog("Video: " .. state.localTitle:sub(1, 28))
                        sendReport(true)
                    elseif state.searchTarget == "emergency" then
                        state.emergencyTitle = clean
                        saveConfig()
                    elseif state.searchTarget == "lockdown" then
                        state.lockdownTitle = clean
                        saveConfig()
                    end
                elseif type(results) == "table" then
                    -- Cloud-Suchantwort (filtert den Patreon-Werbeeintrag 9Se1cKmJ_Ik heraus!)
                    local foundId, foundTitle = nil, nil
                    for _, item in ipairs(results) do
                        if type(item) == "table" and type(item.id) == "string" and item.id ~= "9Se1cKmJ_Ik" then
                            local cName = state.cleanTitle(item.name)
                            if not state.isBadTitle(cName, item.id) then
                                foundId    = item.id
                                foundTitle = cName
                                break
                            end
                        end
                    end
                    if foundId then
                        if state.searchTarget == "local" then
                            state.localVideoId = foundId
                            state.localTitle   = foundTitle
                            saveConfig()
                            addLog("Video: " .. state.localTitle:sub(1, 28))
                            sendReport(true)
                            syncAudioEngine()
                        elseif state.searchTarget == "emergency" then
                            state.emergencyId    = foundId
                            state.emergencyTitle = foundTitle
                            saveConfig()
                            syncAudioEngine()
                        elseif state.searchTarget == "lockdown" then
                            state.lockdownId    = foundId
                            state.lockdownTitle = foundTitle
                            saveConfig()
                            syncAudioEngine()
                        end
                    else
                        addLog("Kein YouTube-Treffer gefunden!")
                    end
                end
                state.dirty = true
            else
                pcall(handle.close)
            end

        elseif ev == "http_failure" then
            local url = p1
            if url == state.loadingUrl then
                state.loadingUrl     = nil
                state.isLoadingAudio = false
                state.audioError     = "Stream-Fehler"
                addLog("Audio-Stream fehlgeschlagen! Neuer Versuch in 3s...")
                state.retryTimer     = os.startTimer(3.0)
                state.dirty          = true
            elseif url == state.searchUrl then
                state.searchUrl = nil
                if state.searchTarget == "local" and state.localTitle == "Lade Videotitel..." then
                    state.localTitle = "YouTube-Video"
                    saveConfig()
                    state.dirty = true
                end
            end

        -- 3. Mausklicks & Lautstaerke-Slider
        elseif (ev == "mouse_click" or ev == "mouse_drag") and not state.updatingState then
            local x, y = p2, p3
            local handled = false

            if hitboxes.volBar and y == hitboxes.volBar.y and x >= hitboxes.volBar.x1 and x <= hitboxes.volBar.x2 then
                local rel = (x - hitboxes.volBar.x1) / math.max(1, hitboxes.volBar.width - 1)
                state.volumePct = math.max(0, math.min(100, math.floor((rel * 20) + 0.5) * 5))
                saveConfig()
                state.dirty = true
                handled = true
            elseif ev == "mouse_click" and hitboxes.volDec and y == hitboxes.volDec.y and x >= hitboxes.volDec.x1 and x <= hitboxes.volDec.x2 then
                state.volumePct = math.max(0, state.volumePct - 5)
                saveConfig()
                state.dirty = true
                handled = true
            elseif ev == "mouse_click" and hitboxes.volInc and y == hitboxes.volInc.y and x >= hitboxes.volInc.x1 and x <= hitboxes.volInc.x2 then
                state.volumePct = math.min(100, state.volumePct + 5)
                saveConfig()
                state.dirty = true
                handled = true
            end

            if ev == "mouse_click" and not handled then
                if hitboxes.urlField and y == hitboxes.urlField.y and x >= hitboxes.urlField.x1 and x <= hitboxes.urlField.x2 then
                    if not state.focusUrl then
                        state.focusUrl = true
                        state.fieldUrl = ""
                    end
                    state.dirty = true
                elseif hitboxes.clearBtn and y == hitboxes.clearBtn.y and x >= hitboxes.clearBtn.x1 and x <= hitboxes.clearBtn.x2 then
                    if state.focusUrl and #(state.fieldUrl or "") > 0 then
                        state.fieldUrl = ""
                    else
                        state.localUrl     = ""
                        state.localVideoId = ""
                        state.localTitle   = "Kein Video"
                        state.fieldUrl     = ""
                        state.focusUrl     = false
                        saveConfig()
                        stopAllSpeakers()
                        addLog("Video geloescht.")
                        sendReport(true, "Kein Video")
                    end
                    state.dirty = true
                elseif hitboxes.saveUrlBtn and y == hitboxes.saveUrlBtn.y and x >= hitboxes.saveUrlBtn.x1 and x <= hitboxes.saveUrlBtn.x2 then
                    applyUrlField()
                elseif hitboxes.playBtn and y == hitboxes.playBtn.y and x >= hitboxes.playBtn.x1 and x <= hitboxes.playBtn.x2 then
                    if hasPendingUrlChange() then
                        applyUrlField()
                    else
                        state.focusUrl = false
                        state.fieldUrl = ""
                    end
                    local isPlayingLocal = (state.activeTargetId ~= nil and not state.emergencyActive and not state.lockdownActive)
                    if isPlayingLocal then
                        state.userPlaying     = false
                        state.rsTriggered     = false
                        state.playerTriggered = false
                        state.remoteTriggered = false
                        saveConfig()
                        stopAllSpeakers()
                        addLog("Wiedergabe gestoppt.")
                    else
                        if state.localVideoId == "" then
                            addLog("Bitte erst einen YouTube-Link setzen!")
                        else
                            if CFG.MODES[state.triggerMode] == "MANUELL" then
                                state.userPlaying = true
                                saveConfig()
                            else
                                state.remoteTriggered = true
                            end
                            syncAudioEngine()
                            addLog("Starte Wiedergabe...")
                        end
                    end
                    sendReport(true)
                    state.dirty = true
                elseif hitboxes.loopBtn and y == hitboxes.loopBtn.y and x >= hitboxes.loopBtn.x1 and x <= hitboxes.loopBtn.x2 then
                    state.focusUrl    = false
                    state.fieldUrl    = ""
                    state.loopEnabled = not state.loopEnabled
                    saveConfig()
                    addLog(state.loopEnabled and "Loop aktiviert." or "Loop deaktiviert (1x abspielen).")
                    state.dirty = true
                elseif hitboxes.alarmSyncBtn and y == hitboxes.alarmSyncBtn.y and x >= hitboxes.alarmSyncBtn.x1 and x <= hitboxes.alarmSyncBtn.x2 then
                    state.focusUrl     = false
                    state.fieldUrl     = ""
                    state.alarmVolSync = not state.alarmVolSync
                    saveConfig()
                    if state.alarmVolSync then
                        addLog("Alarm-Lautstaerke: Sync mit Master (" .. tostring(state.alarmVolumePct or 100) .. "%)")
                    else
                        addLog("Alarm-Lautstaerke: Manuell (" .. tostring(state.volumePct or 50) .. "%)")
                    end
                    state.dirty = true
                elseif hitboxes.modeBtn and y == hitboxes.modeBtn.y and x >= hitboxes.modeBtn.x1 and x <= hitboxes.modeBtn.x2 then
                    state.focusUrl        = false
                    state.fieldUrl        = ""
                    state.triggerMode     = (state.triggerMode % #CFG.MODES) + 1
                    state.rsTriggered     = false
                    state.playerTriggered = false
                    state.remoteTriggered = false
                    saveConfig()
                    stopAllSpeakers()
                    checkTriggers()
                    syncAudioEngine()
                    sendReport(true, "Modus: " .. CFG.MODES[state.triggerMode])
                    addLog("Modus gewechselt: " .. CFG.MODES[state.triggerMode])
                    state.dirty = true
                elseif hitboxes.rangeDec and y == hitboxes.rangeDec.y and x >= hitboxes.rangeDec.x1 and x <= hitboxes.rangeDec.x2 then
                    state.sensorRange = math.max(1, state.sensorRange - 1)
                    saveConfig()
                    state.dirty = true
                elseif hitboxes.rangeInc and y == hitboxes.rangeInc.y and x >= hitboxes.rangeInc.x1 and x <= hitboxes.rangeInc.x2 then
                    state.sensorRange = math.min(50, state.sensorRange + 1)
                    saveConfig()
                    state.dirty = true
                else
                    state.focusUrl = false
                    state.fieldUrl = ""
                    state.dirty    = true
                end
            end

        -- 4. Tastatureingabe & Strg+V (Paste) fuer YouTube-Links
        elseif ev == "paste" and state.focusUrl and not state.updatingState then
            state.fieldUrl = (state.fieldUrl or "") .. tostring(p1 or "")
            state.dirty    = true

        elseif ev == "char" and state.focusUrl and not state.updatingState then
            state.fieldUrl = (state.fieldUrl or "") .. p1
            state.dirty    = true

        elseif ev == "key" and state.focusUrl and not state.updatingState then
            if p1 == keys.backspace then
                state.fieldUrl = (state.fieldUrl or ""):sub(1, -2)
                state.dirty    = true
            elseif p1 == keys.enter or p1 == keys.numPadEnter then
                applyUrlField()
            end

        -- 5. Redstone-Event fuer sofortige Trigger-Reaktion
        elseif ev == "redstone" and not state.updatingState then
            checkTriggers()

        -- 6. Rednet-Nachrichten (Emergency, Lockdown, Master-Sync, Funk-Trigger, Radio, Broadcast, Update)
        elseif ev == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3

            if protocol == CFG.PROTOCOL and not state.updatingState then
                if message == CFG.MSG_ON and not state.emergencyActive then
                    state.emergencyActive = true
                    if CFG.MODES[state.triggerMode] ~= "BROADCAST" then
                        syncAudioEngine()
                        addLog("EMERGENCY-ALARM aktiviert!")
                    end
                elseif message == CFG.MSG_OFF and state.emergencyActive then
                    state.emergencyActive = false
                    if CFG.MODES[state.triggerMode] ~= "BROADCAST" then
                        syncAudioEngine()
                        addLog("Emergency beendet -> Vorheriger Modus.")
                    end
                end
                state.dirty = true

            elseif protocol == CFG.LOCKDOWN_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_LOCK and not state.lockdownActive then
                    state.lockdownActive = true
                    if CFG.MODES[state.triggerMode] ~= "BROADCAST" then
                        syncAudioEngine()
                        addLog("LOCKDOWN-ALARM aktiviert!")
                    end
                elseif message == CFG.MSG_UNLOCK and state.lockdownActive then
                    state.lockdownActive = false
                    if CFG.MODES[state.triggerMode] ~= "BROADCAST" then
                        syncAudioEngine()
                        addLog("Lockdown beendet -> Vorheriger Modus.")
                    end
                end
                state.dirty = true

            elseif protocol == CFG.CONFIG_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif type(message) == "table" and message.action == "set_alarm_config" then
                    applyMasterAlarmConfig(message, message.isReply == true)
                    if type(message.radioPlaylist) == "table" then
                        state.radioPlaylist = message.radioPlaylist
                        saveConfig()
                    end
                    if type(message.broadcastPlaylist) == "table" then
                        state.broadcastPlaylist = message.broadcastPlaylist
                        saveConfig()
                    end
                elseif type(message) == "table" and message.action == "set_radio_playlist" then
                    if type(message.playlist) == "table" then
                        state.radioPlaylist = message.playlist
                        state.radioTrackIdx = 1
                        saveConfig()
                        addLog("Master: Radio-Playlist aktualisiert (" .. tostring(#state.radioPlaylist) .. " Tracks)")
                        state.dirty = true
                    end
                elseif type(message) == "table" and message.action == "set_broadcast_playlist" then
                    if type(message.playlist) == "table" then
                        state.broadcastPlaylist = message.playlist
                        state.broadcastTrackIdx = 1
                        saveConfig()
                        addLog("Master: Broadcast-Playlist aktualisiert (" .. tostring(#state.broadcastPlaylist) .. " Tracks)")
                        state.dirty = true
                    end
                end

            elseif protocol == CFG.STREAM_PROTOCOL and not state.updatingState then
                if CFG.MODES[state.triggerMode] == "RADIO" and not state.emergencyActive and not state.lockdownActive then
                    if type(message) == "table" and message.action == "radio_chunk" and message.chunk then
                        state.curRadioTrackIdx = message.trackIdx or 1
                        state.curRadioTitle    = message.trackTitle or "Radio-Track"
                        local vol = (state.volumePct / 100) * 3.0
                        if vol > 0.001 and #state.speakers > 0 then
                            local ok, pcm = pcall(state.decoder, message.chunk)
                            if ok and pcm then
                                pushBufferToSpeakers(pcm, vol)
                            end
                        end
                        state.dirty = true
                    end
                end

            elseif protocol == CFG.BROADCAST_STREAM_PROTOCOL and not state.updatingState then
                -- WICHTIG: Im Modus [ BROADCAST ] spielt der Stream auch bei aktivem Emergency / Lockdown!
                if CFG.MODES[state.triggerMode] == "BROADCAST" then
                    if type(message) == "table" and message.action == "broadcast_chunk" and message.chunk then
                        state.curBroadcastTrackIdx = message.trackIdx or 1
                        state.curBroadcastTitle    = message.trackTitle or "Broadcast-Track"
                        local vol = (state.volumePct / 100) * 3.0
                        if vol > 0.001 and #state.speakers > 0 then
                            local ok, pcm = pcall(state.decoder, message.chunk)
                            if ok and pcm then
                                pushBufferToSpeakers(pcm, vol)
                            end
                        end
                        state.dirty = true
                    end
                end

            elseif protocol == CFG.TRIGGER_PROTOCOL and not state.updatingState then
                if CFG.MODES[state.triggerMode] == "FUNK" then
                    if message == "PLAY" or (type(message) == "table" and message.action == "play") then
                        state.remoteTriggered = true
                        syncAudioEngine()
                        addLog("Funk-Trigger empfangen (Start).")
                    elseif message == "STOP" or (type(message) == "table" and message.action == "stop") then
                        state.remoteTriggered = false
                        syncAudioEngine()
                        addLog("Funk-Trigger empfangen (Stop).")
                    end
                end

            elseif protocol == CFG.UPDATE_PROTOCOL then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif senderId == CFG.MASTER_ID and type(message) == "table" and message.action == "update" then
                    pcall(function() rednet.send(CFG.MASTER_ID, { action = "ping_ack" }, CFG.UPDATE_PROTOCOL) end)
                    applyUpdate()
                    state.tickTimer   = os.startTimer(0.5)
                    state.sensorTimer = os.startTimer(0.5)
                end
            end

        -- 7. Timer fuer Log-Ablauf, Lauftext-Marquee, Spieler-Detektor und Stream-Retry
        elseif ev == "timer" then
            if p1 == state.tickTimer then
                state.tickTimer = os.startTimer(0.5)
                state.marqueeOffset = (state.marqueeOffset or 0) + 1
                state.dirty = true
                local t = now()
                for i = #state.logs, 1, -1 do
                    if state.logs[i].expires <= t then
                        table.remove(state.logs, i)
                        state.dirty = true
                    end
                end
            elseif p1 == state.sensorTimer then
                state.sensorTimer = os.startTimer(0.5)
                checkTriggers()
            elseif p1 == state.retryTimer then
                state.retryTimer     = nil
                state.activeTargetId = nil
                syncAudioEngine()
            end

        elseif ev == "peripheral" or ev == "peripheral_detach" then
            setupPeripherals()
            syncAudioEngine()
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
        stopAllSpeakers()
        if tostring(err):find("Terminated") then
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("Lautsprecher beendet.")
            return
        end
        addLog("Fehler: " .. tostring(err))
        sleep(2)
    end
end
