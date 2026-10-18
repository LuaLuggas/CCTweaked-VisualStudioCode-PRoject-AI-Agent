-- ============================================================================
-- BUNKER RADIO-HOST (ZENTRALER AUDIO- & ALARM-SENDER FUER ATM10 / CC:TWEAKED)
-- ============================================================================
-- Streamt YouTube-Audio (Radio-Playlist sowie globale Emergency-/Lockdown-Alarme)
-- mit echtem Zeitstempel-Scheduling (os.epoch("utc"), seq & playAt) an alle
-- Bunker-Lautsprecher. Dadurch spielen alle Lautsprecher im exakt selben
-- Server-Tick ohne Echo, Drift oder verschluckte Buffer.
-- Waehrend eines Alarms laeuft die Radio-Playlist im Hintergrund weiter.
-- ============================================================================

local dfpwm = require("cc.audio.dfpwm")

-- ==================================
-- KOMMENTAR: KONFIGURATION & PROTOKOLLE (UPVALUE-GEBUENDELT)
-- ==================================
local CFG = {
    MASTER_ID         = 24,
    PROTOCOL          = "notaus",
    LOCKDOWN_PROTOCOL = "lockdown",
    UPDATE_PROTOCOL   = "radio_update",
    CONFIG_PROTOCOL   = "radio_config",
    SPK_CONFIG_PROTO  = "speaker_config",
    STREAM_PROTOCOL   = "bunker_radio_stream",

    MSG_ON            = "EMERGENCY_ON",
    MSG_OFF           = "EMERGENCY_OFF",
    MSG_LOCK          = "LOCKDOWN_ON",
    MSG_UNLOCK        = "LOCKDOWN_OFF",
    MSG_STATUS        = "STATUS_REQUEST",

    API_URL           = "https://ipod-2to6magyna-uc.a.run.app/",
    API_VERSION       = "2.1",
    GITHUB_URL        = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/RadioHost/startup.lua",
    CONFIG_FILE       = "radio_host.cfg",
    TEMP_FILE         = "startup.update_tmp",
    BACKUP_FILE       = "startup.backup",

    CHUNK_SIZE        = 3000,    -- 3000 Bytes = 24.000 Samples = exakt 500 ms Audio bei 48kHz
    CHUNK_MS          = 500,     -- Dauer eines Chunks in Millisekunden
    LEAD_MS           = 1500,    -- Vorlaufzeit (1,5 s) fuer geplante Wiedergabe (playAt)
    ALARM_LEAD_MS     = 1000,    -- Kuerzere Vorlaufzeit (1,0 s) fuer schnellen Alarm-Start
    MAX_ALARM_CACHE   = 40,      -- Bis zu 40 Chunks (20 s) Alarm-Ton im RAM fuer nahtlosen Loop

    LOG_TTL           = 4,
    MAX_LOG           = 2,
    COMPUTER_ID       = os.getComputerID()
}

-- ==================================
-- KOMMENTAR: ZUSTANDSTABELLE (UPVALUES BUNDELN)
-- ==================================
local state = {
    -- Radio-Playlist & Hintergrund-Fortschritt
    playlist          = {},
    curIdx            = 1,
    isPlaying         = true,
    curTitle          = "Kein Track",
    activeRadioId     = nil,
    radioStreamHandle = nil,
    loadingRadioUrl   = nil,
    isLoadingRadio    = false,
    bgRadioNextUtc    = 0,

    -- Vom Master synchronisierte Emergency- & Lockdown-Alarme
    emergencyActive   = false,
    lockdownActive    = false,
    emergencyId       = "",
    emergencyTitle    = "",
    lockdownId        = "",
    lockdownTitle     = "",
    alarmVolPct       = 100,
    activeAlarmId     = nil,
    alarmStreamHandle = nil,
    loadingAlarmUrl   = nil,
    isLoadingAlarm    = false,
    alarmCacheId      = nil,
    alarmCacheChunks  = {},
    alarmCacheComplete = false,
    alarmCacheIdx     = 1,

    -- Geplantes Broadcast-Scheduling (os.epoch("utc"))
    streamId          = 0,
    streamType        = "radio", -- "radio" | "emergency" | "lockdown"
    seq               = 0,
    streamStartUtc    = 0,
    prevPkt           = nil,
    paceTimer         = nil,
    audioError        = nil,

    -- Studio-Lautsprecher (nutzen exakt dieselbe playAt-Warteschlange wie Slave-Speaker!)
    volumePct         = 50,
    alarmVolSync      = true,
    speakers          = {},
    decoder           = dfpwm.make_decoder(),
    rxStreamId        = nil,
    rxQueue           = {},
    lastPlayedSeq     = 0,
    lastPlayAt        = 0,
    pendingBuffer     = nil,
    pendingVol        = 1.5,
    pendingPlayAt     = 0,
    syncTimer         = nil,

    -- UI & Interaktion
    selectedTrackIdx  = nil,
    scrollOffset      = 0,
    marqueeOffset     = 0,

    -- Peripherie & Netzwerk
    modem             = nil,
    cachedPos         = "GPS n.verf.",
    updatingState     = false,

    -- Status & Logs
    lastUpdateTime    = "-",
    lastUpdateStat    = "noch keins",
    logs              = {},
    dirty             = true,

    -- Timer
    tickTimer         = nil,
    retryTimer        = nil
}

local hitboxes = {}

-- ==================================
-- KOMMENTAR: HILFSFUNKTIONEN & TITEL-VERARBEITUNG
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
    local s = tostring(str or "")
    if s == "" then return "" end
    if #s <= maxLen then
        return s .. string.rep(" ", maxLen - #s)
    end
    local spacer = "   ---   "
    local full = s .. spacer
    local fullLen = #full
    local startIdx = ((offset or 0) % fullLen) + 1
    local repeated = full .. full
    return repeated:sub(startIdx, startIdx + maxLen - 1)
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

state.fetchVideoInfo = function(input)
    local trimmed = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return "", "" end
    local vid = extractYoutubeId(trimmed)

    if vid ~= "" and http then
        local oUrl = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=" .. vid .. "&format=json"
        local res = http.get(oUrl)
        if res then
            local raw = res.readAll()
            res.close()
            if raw then
                local data = textutils.unserializeJSON(raw)
                if type(data) == "table" and type(data.title) == "string" and #data.title > 0 then
                    local clean = state.cleanTitle(data.title)
                    if not state.isBadTitle(clean, vid) then
                        return vid, clean
                    end
                end
            end
        end
    end

    if http then
        local sUrl = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&search=" .. textutils.urlEncode(vid ~= "" and vid or trimmed)
        local res = http.get(sUrl)
        if res then
            local raw = res.readAll()
            res.close()
            if raw then
                local results = textutils.unserializeJSON(raw)
                if type(results) == "table" then
                    for _, item in ipairs(results) do
                        if type(item) == "table" and type(item.id) == "string" and #item.id == 11 then
                            if item.id ~= "9Se1cKmJ_Ik" and not state.isBadTitle(item.name, item.id) then
                                if vid == "" or item.id == vid then
                                    return item.id, state.cleanTitle(item.name)
                                end
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

local function addLog(msg)
    table.insert(state.logs, { text = tostring(msg), expires = now() + CFG.LOG_TTL })
    while #state.logs > CFG.MAX_LOG do
        table.remove(state.logs, 1)
    end
    state.dirty = true
end

-- ==================================
-- KOMMENTAR: KONFIGURATION SPEICHERN & LADEN
-- ==================================
local function saveConfig()
    local f = fs.open(CFG.CONFIG_FILE, "w")
    if not f then return false end
    f.write(textutils.serialize({
        playlist       = state.playlist,
        curIdx         = state.curIdx,
        isPlaying      = state.isPlaying,
        volumePct      = state.volumePct,
        alarmVolSync   = state.alarmVolSync,
        emergencyId    = state.emergencyId,
        emergencyTitle = state.emergencyTitle,
        lockdownId     = state.lockdownId,
        lockdownTitle  = state.lockdownTitle,
        alarmVolPct    = state.alarmVolPct,
        lastUpdateTime = state.lastUpdateTime,
        lastUpdateStat = state.lastUpdateStat
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
                if type(data.playlist) == "table" then
                    state.playlist = {}
                    for _, t in ipairs(data.playlist) do
                        if type(t) == "table" and t.id then
                            table.insert(state.playlist, { id = tostring(t.id), title = state.cleanTitle(t.title or "YouTube-Video") })
                        end
                    end
                end
                if type(data.curIdx) == "number" then state.curIdx = math.max(1, data.curIdx) end
                if type(data.isPlaying) == "boolean" then state.isPlaying = data.isPlaying end
                if type(data.volumePct) == "number" then state.volumePct = math.max(0, math.min(100, data.volumePct)) end
                if type(data.alarmVolSync) == "boolean" then state.alarmVolSync = data.alarmVolSync end
                if type(data.emergencyId) == "string" then state.emergencyId = extractYoutubeId(data.emergencyId) end
                if type(data.emergencyTitle) == "string" then state.emergencyTitle = state.cleanTitle(data.emergencyTitle) end
                if type(data.lockdownId) == "string" then state.lockdownId = extractYoutubeId(data.lockdownId) end
                if type(data.lockdownTitle) == "string" then state.lockdownTitle = state.cleanTitle(data.lockdownTitle) end
                if type(data.alarmVolPct) == "number" then state.alarmVolPct = math.max(0, math.min(100, data.alarmVolPct)) end
                if type(data.lastUpdateTime) == "string" then state.lastUpdateTime = data.lastUpdateTime end
                if type(data.lastUpdateStat) == "string" then state.lastUpdateStat = data.lastUpdateStat end
                return true
            end
        end
    end
    return false
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

local function getPreviewString()
    if state.lockdownActive then
        return "ALARM: LOCKDOWN"
    elseif state.emergencyActive then
        return "ALARM: EMERGENCY"
    end
    local status = state.isPlaying and "ON AIR" or "PAUSIERT"
    local tName = (state.curTitle ~= "" and state.curTitle ~= "Kein Track") and state.curTitle or "Kein Track"
    return status .. " (" .. tName:sub(1, 16) .. ")"
end

local function sendReport(success, details)
    if not state.modem then return end
    local label = os.getComputerLabel() or ("RadioHost " .. tostring(CFG.COMPUTER_ID))
    local preview = getPreviewString()
    pcall(function()
        rednet.send(CFG.MASTER_ID, {
            action  = "log_report",
            success = success,
            details = details or ("Online: " .. preview),
            pos     = state.cachedPos,
            label   = label,
            preview = preview,
            devType = "radio"
        }, CFG.UPDATE_PROTOCOL)
    end)
end

-- ==================================
-- KOMMENTAR: STUDIO-SPEAKER SYNCHRON-QUEUE (PLAYAT-SCHEDULER)
-- ==================================
local function pushBufferToStudioSpeakers(pcmBuffer, vol)
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

local function stopStudioSpeakers()
    state.rxQueue       = {}
    state.lastPlayedSeq = 0
    state.lastPlayAt    = 0
    state.pendingBuffer = nil
    state.decoder       = dfpwm.make_decoder()
    for _, spk in ipairs(state.speakers) do
        pcall(spk.stop)
    end
end

local function getStudioVolume(streamType)
    if streamType == "emergency" or streamType == "lockdown" then
        local pct = state.alarmVolSync and state.alarmVolPct or state.volumePct
        return (pct / 100) * 3.0
    end
    return (state.volumePct / 100) * 3.0
end

local function makeSilencePcm(samples)
    local tbl = {}
    for i = 1, samples do tbl[i] = 0 end
    return tbl
end

local function processStudioQueue()
    if #state.speakers == 0 then return end
    local nowUtc = os.epoch("utc")

    -- 1. Falls ein Puffer noch auf speaker_audio_empty wartet
    if state.pendingBuffer then
        if nowUtc < state.pendingPlayAt + 450 then
            if pushBufferToStudioSpeakers(state.pendingBuffer, state.pendingVol) then
                state.pendingBuffer = nil
            else
                return
            end
        else
            state.pendingBuffer = nil
        end
    end

    -- 2. Abgelaufene Chunks (> 450ms alt) verwerfen, aber Decoder warmhalten
    local minSeq = nil
    for seq, pkt in pairs(state.rxQueue) do
        if nowUtc >= pkt.playAt + 450 then
            pcall(state.decoder, pkt.chunk)
            if seq > state.lastPlayedSeq then
                state.lastPlayedSeq = seq
                state.lastPlayAt    = pkt.playAt
            end
            state.rxQueue[seq] = nil
        else
            if not minSeq or seq < minSeq then
                minSeq = seq
            end
        end
    end

    if not minSeq then return end

    local nextSeq = (state.lastPlayedSeq == 0) and minSeq or (state.lastPlayedSeq + 1)
    local pkt = state.rxQueue[nextSeq]

    -- 3. Erster Chunk nach Start / Resync: Exakt auf playAt warten oder Samples beschneiden
    if state.lastPlayedSeq == 0 and pkt then
        if nowUtc < pkt.playAt - 25 then
            state.syncTimer = os.startTimer(math.max(0.05, (pkt.playAt - nowUtc) / 1000))
            return
        end
        local ok, fullPcm = pcall(state.decoder, pkt.chunk)
        state.rxQueue[nextSeq] = nil
        state.lastPlayedSeq    = nextSeq
        state.lastPlayAt       = pkt.playAt
        if ok and fullPcm then
            local offsetMs = nowUtc - pkt.playAt
            local pcmToPlay = fullPcm
            if offsetMs > 50 and offsetMs < 450 then
                local skipSamples = math.floor(offsetMs * 48)
                if skipSamples > 0 and skipSamples < #fullPcm then
                    pcmToPlay = {}
                    for i = skipSamples + 1, #fullPcm do
                        pcmToPlay[#pcmToPlay + 1] = fullPcm[i]
                    end
                end
            end
            local vol = getStudioVolume(pkt.streamType)
            if not pushBufferToStudioSpeakers(pcmToPlay, vol) then
                state.pendingBuffer = pcmToPlay
                state.pendingVol    = vol
                state.pendingPlayAt = pkt.playAt
                return
            end
        end
        state.syncTimer = os.startTimer(0.45)
        return
    end

    -- 4. Folge-Chunks im laufenden Betrieb
    local expectedPlayAt = (pkt and pkt.playAt) or (state.lastPlayAt + CFG.CHUNK_MS)
    if nowUtc < expectedPlayAt - 50 then
        state.syncTimer = os.startTimer(math.max(0.05, (expectedPlayAt - 25 - nowUtc) / 1000))
        return
    end

    if pkt then
        local ok, pcm = pcall(state.decoder, pkt.chunk)
        state.rxQueue[nextSeq] = nil
        state.lastPlayedSeq    = nextSeq
        state.lastPlayAt       = pkt.playAt
        if ok and pcm then
            local vol = getStudioVolume(pkt.streamType)
            if not pushBufferToStudioSpeakers(pcm, vol) then
                state.pendingBuffer = pcm
                state.pendingVol    = vol
                state.pendingPlayAt = pkt.playAt
                return
            end
        end
        state.syncTimer = os.startTimer(0.45)
    elseif nowUtc >= expectedPlayAt and minSeq and minSeq > nextSeq then
        -- Fehlende Sequenznummer mit Stille gleicher Laenge (24.000 Samples = 500ms) ueberbruecken
        local silence = makeSilencePcm(24000)
        state.lastPlayedSeq = nextSeq
        state.lastPlayAt    = expectedPlayAt
        local vol = getStudioVolume(state.streamType)
        if not pushBufferToStudioSpeakers(silence, vol) then
            state.pendingBuffer = silence
            state.pendingVol    = vol
            state.pendingPlayAt = expectedPlayAt
            return
        end
        state.syncTimer = os.startTimer(0.45)
    end
end

local function enqueueStudioChunk(pkt)
    if #state.speakers == 0 then return end
    if pkt.streamId ~= state.rxStreamId then
        stopStudioSpeakers()
        state.rxStreamId = pkt.streamId
    end
    if pkt.seq <= state.lastPlayedSeq or state.rxQueue[pkt.seq] then
        return
    end
    state.rxQueue[pkt.seq] = pkt
    processStudioQueue()
end

-- ==================================
-- KOMMENTAR: AUDIO-ENGINE & ZEITSTEMPEL-BROADCAST
-- ==================================
local function closeRadioHandle()
    if state.radioStreamHandle then
        pcall(state.radioStreamHandle.close)
        state.radioStreamHandle = nil
    end
end

local function closeAlarmHandle()
    if state.alarmStreamHandle then
        pcall(state.alarmStreamHandle.close)
        state.alarmStreamHandle = nil
    end
end

local function startNewStreamSession(sType)
    local lead = (sType == "radio") and CFG.LEAD_MS or CFG.ALARM_LEAD_MS
    state.streamId       = os.epoch("utc")
    state.streamType     = sType
    state.seq            = 0
    state.streamStartUtc = os.epoch("utc") + lead
    state.prevPkt        = nil
    stopStudioSpeakers()
end

local function stopAllPlayback()
    closeRadioHandle()
    closeAlarmHandle()
    state.activeRadioId  = nil
    state.activeAlarmId  = nil
    state.loadingRadioUrl = nil
    state.loadingAlarmUrl = nil
    state.isLoadingRadio = false
    state.isLoadingAlarm = false
    state.prevPkt        = nil
    stopStudioSpeakers()
    if state.modem then
        rednet.broadcast({
            action   = "radio_stop",
            streamId = os.epoch("utc")
        }, CFG.STREAM_PROTOCOL)
    end
    state.dirty = true
end

local function getCurrentTrack()
    if #state.playlist == 0 then return nil end
    local idx = math.max(1, math.min(#state.playlist, state.curIdx or 1))
    return state.playlist[idx], idx
end

local function requestRadioStream(videoId)
    closeRadioHandle()
    if not http then
        state.audioError = "HTTP inaktiv"
        state.dirty = true
        return
    end
    local url = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&id=" .. textutils.urlEncode(videoId)
    state.loadingRadioUrl = url
    state.isLoadingRadio  = true
    state.audioError      = nil
    state.dirty           = true
    http.request({ url = url, binary = true })
end

local function requestAlarmStream(videoId)
    closeAlarmHandle()
    if state.alarmCacheId == videoId and state.alarmCacheComplete and #state.alarmCacheChunks > 0 then
        state.alarmCacheIdx  = 1
        state.isLoadingAlarm = false
        state.dirty          = true
        os.queueEvent("radio_feed")
        return
    end
    if not http then
        state.audioError = "HTTP inaktiv"
        state.dirty = true
        return
    end
    state.alarmCacheId       = videoId
    state.alarmCacheChunks   = {}
    state.alarmCacheComplete = false
    state.alarmCacheIdx      = 1

    local url = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&id=" .. textutils.urlEncode(videoId)
    state.loadingAlarmUrl = url
    state.isLoadingAlarm  = true
    state.audioError      = nil
    state.dirty           = true
    http.request({ url = url, binary = true })
end

local function advanceToNextRadioTrack(keepSession)
    if #state.playlist == 0 then
        closeRadioHandle()
        state.activeRadioId = nil
        state.curTitle      = "Kein Track"
        state.dirty         = true
        return
    end
    state.curIdx = (state.curIdx % #state.playlist) + 1
    saveConfig()
    local trk = state.playlist[state.curIdx]
    if trk and trk.id then
        state.activeRadioId = trk.id
        state.curTitle      = (trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"
        if not keepSession and state.streamType == "radio" then
            startNewStreamSession("radio")
        end
        requestRadioStream(trk.id)
    else
        closeRadioHandle()
    end
    state.dirty = true
end

-- Liest exakt 3000 Bytes (500ms) und fuellt am Track-Ende mit neutraler DFPWM-Stille (0x55) auf
local function readPaddedChunk(handle)
    if not handle then return nil end
    local chunk = handle.read(CFG.CHUNK_SIZE)
    if not chunk or #chunk == 0 then
        return nil
    end
    if #chunk < CFG.CHUNK_SIZE then
        chunk = chunk .. string.rep("\85", CFG.CHUNK_SIZE - #chunk)
    end
    return chunk
end

-- Liest den naechsten Alarm-Chunk (aus RAM-Cache oder HTTP-Stream) im Endlos-Loop
local function readNextAlarmChunk()
    if state.alarmCacheId == state.activeAlarmId and state.alarmCacheComplete and #state.alarmCacheChunks > 0 then
        local c = state.alarmCacheChunks[state.alarmCacheIdx]
        state.alarmCacheIdx = (state.alarmCacheIdx % #state.alarmCacheChunks) + 1
        return c
    end
    if state.alarmStreamHandle then
        local c = readPaddedChunk(state.alarmStreamHandle)
        if c then
            if state.alarmCacheId == state.activeAlarmId then
                if #state.alarmCacheChunks < CFG.MAX_ALARM_CACHE then
                    table.insert(state.alarmCacheChunks, c)
                else
                    state.alarmCacheId       = nil
                    state.alarmCacheChunks   = {}
                    state.alarmCacheComplete = false
                end
            end
            return c
        else
            closeAlarmHandle()
            if state.alarmCacheId == state.activeAlarmId and #state.alarmCacheChunks > 0 then
                state.alarmCacheComplete = true
                state.alarmCacheIdx      = 1
                local first = state.alarmCacheChunks[1]
                state.alarmCacheIdx = (#state.alarmCacheChunks > 1) and 2 or 1
                return first
            else
                requestAlarmStream(state.activeAlarmId)
                return nil
            end
        end
    end
    return nil
end

-- Haupt-Pumpe: Sendet Chunks streng nach Echtzeit-Uhr (os.epoch("utc")) mit 1,5s Vorlauf
local function pumpBroadcastStream()
    local nowUtc = os.epoch("utc")

    -- 1. Waehrend eines Alarms laeuft das Radio im Hintergrund lautlos im Echtzeit-Takt weiter!
    if (state.lockdownActive or state.emergencyActive) and state.isPlaying and #state.playlist > 0 then
        if state.bgRadioNextUtc <= 0 then
            state.bgRadioNextUtc = nowUtc + CFG.CHUNK_MS
        end
        while nowUtc >= state.bgRadioNextUtc do
            state.bgRadioNextUtc = state.bgRadioNextUtc + CFG.CHUNK_MS
            if state.radioStreamHandle then
                local bgChunk = state.radioStreamHandle.read(CFG.CHUNK_SIZE)
                if not bgChunk or #bgChunk == 0 then
                    closeRadioHandle()
                    advanceToNextRadioTrack(true)
                    break
                end
            end
        end
    else
        state.bgRadioNextUtc = 0
    end

    -- 2. Aktiven Stream-Modus bestimmen (Prioritaet: Lockdown > Emergency > Radio)
    local targetMode = "radio"
    local isAlarm    = false
    if state.lockdownActive and state.lockdownId ~= "" then
        targetMode = "lockdown"
        isAlarm    = true
    elseif state.emergencyActive and state.emergencyId ~= "" then
        targetMode = "emergency"
        isAlarm    = true
    elseif not state.isPlaying or #state.playlist == 0 then
        return
    end

    if isAlarm and state.isLoadingAlarm then return end
    if not isAlarm and state.isLoadingRadio then return end

    if state.streamId == 0 or state.streamType ~= targetMode then
        startNewStreamSession(targetMode)
    end

    local leadMs = isAlarm and CFG.ALARM_LEAD_MS or CFG.LEAD_MS

    -- 3. Falls die Uhr nach einem starken Server-Lag hinterherhinkt, veraltete Slots ueberspringen
    while true do
        local nextSeq    = state.seq + 1
        local nextPlayAt = state.streamStartUtc + (nextSeq - 1) * CFG.CHUNK_MS
        if nowUtc > nextPlayAt then
            -- Dieser Zeit-Slot liegt bereits in der Vergangenheit -> im Stream ueberspringen
            local skipped = isAlarm and readNextAlarmChunk() or readPaddedChunk(state.radioStreamHandle)
            if not skipped then
                if not isAlarm and state.radioStreamHandle then
                    closeRadioHandle()
                    advanceToNextRadioTrack(true)
                end
                return
            end
            state.seq = nextSeq
        else
            break
        end
    end

    -- 4. Alle Chunks innerhalb des Vorlauf-Fensters (leadMs) mit seq & playAt senden
    while true do
        nowUtc = os.epoch("utc")
        local nextSeq    = state.seq + 1
        local nextPlayAt = state.streamStartUtc + (nextSeq - 1) * CFG.CHUNK_MS

        if nextPlayAt - nowUtc > leadMs then
            -- Naechster Chunk ist noch nicht faellig -> präzisen Echtzeit-Timer stellen
            local waitMs = (nextPlayAt - leadMs) - nowUtc
            state.paceTimer = os.startTimer(math.max(0.05, waitMs / 1000))
            break
        end

        local chunk = nil
        local title = state.curTitle
        if isAlarm then
            chunk = readNextAlarmChunk()
            title = (targetMode == "lockdown") and "LOCKDOWN-ALARM" or "EMERGENCY-ALARM"
        else
            chunk = readPaddedChunk(state.radioStreamHandle)
            if not chunk and state.radioStreamHandle then
                closeRadioHandle()
                advanceToNextRadioTrack(true)
                return
            end
        end

        if not chunk then
            break
        end

        state.seq = nextSeq
        local pkt = {
            action     = "radio_chunk",
            streamId   = state.streamId,
            streamType = targetMode,
            seq        = state.seq,
            playAt     = nextPlayAt,
            chunk      = chunk,
            trackIdx   = state.curIdx,
            trackTitle = title
        }

        if state.modem then
            -- Vorherigen Chunk zur Sicherheit noch einmal mitsenden (Empfaenger filtern Duplikate ueber seq)
            if state.prevPkt and state.prevPkt.streamId == state.streamId then
                rednet.broadcast(state.prevPkt, CFG.STREAM_PROTOCOL)
            end
            rednet.broadcast(pkt, CFG.STREAM_PROTOCOL)
        end
        state.prevPkt = pkt

        -- Lokale Studio-Speaker ueber exakt dieselbe Synchron-Warteschlange speisen
        enqueueStudioChunk(pkt)
    end
end

local function syncPlaybackEngine()
    -- 1. Pruefen ob Alarm aktiv ist
    local wantAlarmId = nil
    local wantMode    = "radio"
    if state.lockdownActive and state.lockdownId ~= "" then
        wantAlarmId = state.lockdownId
        wantMode    = "lockdown"
    elseif state.emergencyActive and state.emergencyId ~= "" then
        wantAlarmId = state.emergencyId
        wantMode    = "emergency"
    end

    if wantAlarmId then
        if state.streamType ~= wantMode or state.activeAlarmId ~= wantAlarmId then
            state.activeAlarmId = wantAlarmId
            startNewStreamSession(wantMode)
            requestAlarmStream(wantAlarmId)
        elseif not state.isLoadingAlarm and not state.alarmStreamHandle and not state.alarmCacheComplete then
            requestAlarmStream(wantAlarmId)
        else
            pumpBroadcastStream()
        end
        -- Sicherstellen, dass das Radio im Hintergrund geladen bleibt, falls es aktiv war
        if state.isPlaying and #state.playlist > 0 and not state.radioStreamHandle and not state.isLoadingRadio then
            local trk = getCurrentTrack()
            if trk and trk.id then
                state.activeRadioId = trk.id
                state.curTitle      = (trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"
                requestRadioStream(trk.id)
            end
        end
        return
    else
        -- Kein Alarm aktiv -> Alarm-Handle schliessen
        if state.activeAlarmId or state.alarmStreamHandle then
            closeAlarmHandle()
            state.activeAlarmId = nil
        end
    end

    -- 2. Normaler Radio-Betrieb
    if not state.isPlaying or #state.playlist == 0 then
        if state.activeRadioId or state.radioStreamHandle or state.streamType ~= "radio" then
            stopAllPlayback()
            state.streamType = "radio"
        end
        return
    end

    local trk = getCurrentTrack()
    if not trk or not trk.id then
        stopAllPlayback()
        return
    end

    state.curTitle = (trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"

    if state.streamType ~= "radio" then
        startNewStreamSession("radio")
        if state.modem then
            rednet.broadcast({
                action   = "radio_alarm_end",
                streamId = state.streamId
            }, CFG.STREAM_PROTOCOL)
        end
    end

    if state.activeRadioId ~= trk.id then
        closeRadioHandle()
        state.activeRadioId = trk.id
        startNewStreamSession("radio")
        requestRadioStream(trk.id)
    elseif not state.isLoadingRadio and not state.radioStreamHandle then
        startNewStreamSession("radio")
        requestRadioStream(trk.id)
    else
        pumpBroadcastStream()
    end
end

-- ==================================
-- KOMMENTAR: TERMINAL UI (51x19 ADVANCED COMPUTER)
-- ==================================
local function drawUI()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    hitboxes = {}

    -- 1. Kopfzeile
    term.setCursorPos(2, 1)
    term.setTextColor(colors.yellow)
    term.write("--- BUNKER RADIO HOST ---")
    local idStr = "ID:" .. tostring(CFG.COMPUTER_ID)
    term.setCursorPos(math.max(1, w - #idStr), 1)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    -- 2. Status-Pill (ON AIR / ALARM / PAUSIERT) & Speaker-Info
    term.setCursorPos(2, 2)
    if state.lockdownActive then
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [ LOCKDOWN-ALARM ] ")
    elseif state.emergencyActive then
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [ EMERGENCY-ALARM ] ")
    elseif state.isPlaying and #state.playlist > 0 then
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [ ON AIR ] ")
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
        term.write(" [ PAUSIERT ] ")
    end
    hitboxes.toggleAirBtn = { x1 = 2, x2 = 15, y = 2 }

    term.setBackgroundColor(colors.black)
    term.setCursorPos(23, 2)
    if state.updatingState then
        term.setTextColor(colors.yellow)
        term.write("UPDATE LAEUFT...")
    elseif state.isLoadingRadio or state.isLoadingAlarm then
        term.setTextColor(colors.yellow)
        term.write("LADE STREAM...")
    elseif state.audioError then
        term.setTextColor(colors.red)
        term.write(tostring(state.audioError):sub(1, w - 24))
    else
        term.setTextColor(colors.lightGray)
        if #state.speakers > 0 then
            term.write(string.format("Sync-Tx + %d Studio-Spk", #state.speakers))
        else
            term.write("Sync-Tx (Rednet)")
        end
    end

    -- 3. Aktueller Track als Marquee-Laufschrift
    term.setCursorPos(2, 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    local curIdx = math.max(1, math.min(math.max(1, #state.playlist), state.curIdx or 1))
    term.write(string.format("AKTUELLER TRACK (%d/%d):", (#state.playlist > 0 and curIdx or 0), #state.playlist))

    term.setCursorPos(2, 5)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    local dispTitle = (#state.playlist > 0) and state.curTitle or "Keine Tracks in der Playlist"
    local marquee = getMarqueeText(dispTitle, w - 4, state.marqueeOffset)
    term.write(" " .. pad(marquee, w - 4) .. " ")

    -- 4. Steuer-Buttons: [ PLAY/PAUSE ] [ >> SKIP ] [ + LINK ]
    term.setCursorPos(2, 7)
    if state.isPlaying then
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [ PAUSE ] ")
    else
        term.setBackgroundColor(colors.lime)
        term.setTextColor(colors.black)
        term.write(" [ PLAY  ] ")
    end
    hitboxes.playBtn = { x1 = 2, x2 = 12, y = 7 }

    term.setCursorPos(14, 7)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" [ >> SKIP ] ")
    hitboxes.skipBtn = { x1 = 14, x2 = 26, y = 7 }

    term.setCursorPos(28, 7)
    term.setBackgroundColor(colors.cyan)
    term.setTextColor(colors.black)
    term.write(" [ + TRACK ZUFUEGEN ] ")
    hitboxes.addBtn = { x1 = 28, x2 = 49, y = 7 }

    -- 5. Playlist-Ansicht (Zeilen 9 bis 12, bis zu 4 sichtbare Eintraege)
    term.setCursorPos(2, 8)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write("PLAYLIST:")

    if #state.playlist > 4 then
        term.setCursorPos(w - 9, 8)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" UP ")
        hitboxes.scrollUp = { x1 = w - 9, x2 = w - 6, y = 8 }

        term.setCursorPos(w - 4, 8)
        term.write(" DN ")
        hitboxes.scrollDn = { x1 = w - 4, x2 = w - 1, y = 8 }
    end

    local maxOff = math.max(0, #state.playlist - 4)
    state.scrollOffset = math.max(0, math.min(maxOff, state.scrollOffset or 0))

    for row = 1, 4 do
        local idx = state.scrollOffset + row
        local y = 8 + row
        term.setCursorPos(2, y)
        local item = state.playlist[idx]
        if item then
            local isSel = (state.selectedTrackIdx == idx)
            local isCur = (state.curIdx == idx)
            term.setBackgroundColor(isSel and colors.orange or (isCur and colors.gray or colors.black))
            term.setTextColor(isSel and colors.black or (isCur and colors.yellow or colors.white))
            local prefix = string.format("%s%d.", isCur and ">" or " ", idx)
            local availW = w - 4 - #prefix - 1
            local tText  = isSel and getMarqueeText(item.title, availW, state.marqueeOffset) or pad(item.title, availW)
            term.write(prefix .. " " .. pad(tText, availW))
            hitboxes["track_" .. row] = { x1 = 2, x2 = w - 2, y = y, idx = idx }
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.gray)
            term.write(pad(string.format(" %d. - Leer -", idx), w - 3))
        end
    end

    -- 6. Sortier- & Loesch-Buttons fuer ausgewaehlten Track (Zeile 13)
    local sel = state.selectedTrackIdx
    local actBg = (sel and state.playlist[sel]) and colors.gray or colors.black
    local actFg = (sel and state.playlist[sel]) and colors.white or colors.gray

    term.setCursorPos(2, 13)
    term.setBackgroundColor(actBg)
    term.setTextColor(actFg)
    term.write(" [ HOCH ] ")
    hitboxes.moveUp = { x1 = 2, x2 = 11, y = 13 }

    term.setCursorPos(13, 13)
    term.write(" [ RUNTER ] ")
    hitboxes.moveDn = { x1 = 13, x2 = 24, y = 13 }

    term.setCursorPos(26, 13)
    term.setBackgroundColor((sel and state.playlist[sel]) and colors.red or colors.black)
    term.setTextColor((sel and state.playlist[sel]) and colors.white or colors.gray)
    term.write(" [ LOESCHEN ] ")
    hitboxes.delTrack = { x1 = 26, x2 = 39, y = 13 }

    -- 7. Studio-Lautstaerke Slider (Zeile 15)
    local volY = 15
    term.setCursorPos(2, volY)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write(pad(string.format("Studio:  %3d%%", state.volumePct), 14))

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

    -- 8. Update-Status (Zeile 17) & Debug-Logs (Zeilen 18-19)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 17)
    local updInfo = string.format("letz. Update: [%s] [%s]", tostring(state.lastUpdateTime), tostring(state.lastUpdateStat))
    term.write(updInfo:sub(1, w - 2))

    term.setTextColor(colors.gray)
    local startRow = h - #state.logs + 1
    for i, entry in ipairs(state.logs) do
        term.setCursorPos(2, startRow + i - 1)
        term.write(pad(entry.text, w - 2))
    end
end

-- ==================================
-- KOMMENTAR: DIALOG-EINGABE FUER NEUEN YOUTUBE-LINK
-- ==================================
local function editInput(promptText)
    local w, h = term.getSize()
    local boxW = math.min(46, w - 4)
    local startX = math.floor((w - boxW) / 2) + 1
    local startY = math.floor(h / 2) - 2

    term.setBackgroundColor(colors.gray)
    for y = startY, startY + 4 do
        term.setCursorPos(startX, y)
        term.write(string.rep(" ", boxW))
    end

    term.setCursorPos(startX + 1, startY + 1)
    term.setTextColor(colors.yellow)
    term.write(promptText:sub(1, boxW - 2))

    term.setCursorPos(startX + 1, startY + 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write(string.rep(" ", boxW - 2))

    term.setCursorPos(startX + 1, startY + 3)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightGray)
    term.write("Enter=OK | Strg+V=Einfuegen | Tab=Abbruch")

    local input = ""
    term.setCursorBlink(true)
    while true do
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.setCursorPos(startX + 2, startY + 2)
        local disp = input
        if #disp > boxW - 4 then
            disp = disp:sub(#disp - (boxW - 4) + 1)
        end
        term.write(pad(disp, boxW - 4))
        term.setCursorPos(startX + 2 + math.min(#input, boxW - 4), startY + 2)

        local ev, p1 = os.pullEvent()
        if ev == "char" then
            input = input .. p1
        elseif ev == "paste" then
            input = input .. tostring(p1 or "")
        elseif ev == "key" then
            if p1 == keys.enter then
                term.setCursorBlink(false)
                return input
            elseif p1 == keys.backspace then
                input = input:sub(1, math.max(0, #input - 1))
            elseif p1 == keys.tab then
                term.setCursorBlink(false)
                return nil
            end
        elseif ev == "timer" and p1 == state.paceTimer then
            state.paceTimer = nil
            pumpBroadcastStream()
        elseif ev == "timer" and p1 == state.syncTimer then
            state.syncTimer = nil
            processStudioQueue()
        end
    end
end

-- ==================================
-- KOMMENTAR: GITHUB AUTO-UPDATER
-- ==================================
local function applyUpdate()
    state.updatingState = true
    stopAllPlayback()
    addLog("Starte GitHub-Update...")
    drawUI()

    local function fail(reason)
        state.updatingState  = false
        state.lastUpdateStat = "Fehlgeschlagen"
        saveConfig()
        addLog("Update-Fehler: " .. reason)
        sendReport(false, "RadioHost-Update fehlgeschlagen: " .. reason)
        syncPlaybackEngine()
        return false
    end

    if not http then return fail("HTTP API deaktiviert") end

    local url = CFG.GITHUB_URL .. "?cb=" .. tostring(os.epoch("utc"))
    local res, httpErr = http.get(url)
    if not res then return fail("Download fehlgeschlagen (" .. tostring(httpErr) .. ")") end

    local content = res.readAll()
    res.close()

    if not content or #content < 50 then return fail("Datei leer oder unvollstaendig") end
    if content:find("<!DOCTYPE html>") or content:find("<html") then return fail("HTML statt Lua empfangen") end

    local tf = fs.open(CFG.TEMP_FILE, "w")
    if not tf then return fail("Schreibfehler Temp-Datei") end
    tf.write(content)
    tf.close()

    local fn, syntaxErr = loadfile(CFG.TEMP_FILE)
    if not fn then
        fs.delete(CFG.TEMP_FILE)
        return fail("Syntaxfehler: " .. tostring(syntaxErr):sub(1, 30))
    end

    if fs.exists("startup.lua") then
        fs.delete(CFG.BACKUP_FILE)
        fs.copy("startup.lua", CFG.BACKUP_FILE)
    end

    fs.delete("startup.lua")
    fs.move(CFG.TEMP_FILE, "startup.lua")
    if fs.exists("startup") and not fs.isDir("startup") then
        fs.delete("startup")
    end

    local t = os.date("*t")
    state.lastUpdateTime = string.format("%02d.%02d. %02d:%02d", t.day, t.month, t.hour, t.min)
    state.lastUpdateStat = "Erfolgreich"
    saveConfig()

    sendReport(true, "RadioHost erfolgreich aktualisiert! Neustart...")
    addLog("Update OK! Neustart...")
    drawUI()
    sleep(2)
    os.reboot()
end

-- ==================================
-- KOMMENTAR: PERIPHERIE & STARTUP
-- ==================================
local function setupPeripherals()
    state.speakers = { peripheral.find("speaker") }
    state.modem    = peripheral.find("modem")
    if state.modem then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then
                pcall(rednet.open, name)
            end
        end
    end
    state.dirty = true
end

local function applyAlarmConfig(msg)
    if type(msg.emergencyUrl) == "string" then
        state.emergencyId = extractYoutubeId(msg.emergencyUrl)
    end
    if type(msg.emergencyTitle) == "string" and #msg.emergencyTitle > 0 then
        state.emergencyTitle = state.cleanTitle(msg.emergencyTitle)
    end
    if type(msg.lockdownUrl) == "string" then
        state.lockdownId = extractYoutubeId(msg.lockdownUrl)
    end
    if type(msg.lockdownTitle) == "string" and #msg.lockdownTitle > 0 then
        state.lockdownTitle = state.cleanTitle(msg.lockdownTitle)
    end
    local vol = tonumber(msg.alarmVol) or tonumber(msg.alarmVolPct)
    if vol then
        state.alarmVolPct = math.max(0, math.min(100, vol))
    end
    saveConfig()
    syncPlaybackEngine()
end

-- ==================================
-- KOMMENTAR: HAUPTSCHLEIFE (EVENTS)
-- ==================================
local function main()
    setupPeripherals()
    if state.modem then
        refreshGpsCache()
        pcall(function()
            rednet.broadcast(CFG.MSG_STATUS, CFG.PROTOCOL)
            rednet.broadcast(CFG.MSG_STATUS, CFG.LOCKDOWN_PROTOCOL)
            rednet.send(CFG.MASTER_ID, { action = "request_radio_sync" }, CFG.CONFIG_PROTOCOL)
            rednet.send(CFG.MASTER_ID, { action = "request_speaker_sync" }, CFG.SPK_CONFIG_PROTO)
        end)
        sendReport(true)
    end

    state.tickTimer = os.startTimer(0.5)
    syncPlaybackEngine()

    while true do
        if state.dirty then
            drawUI()
            state.dirty = false
        end

        local ev, p1, p2, p3 = os.pullEvent()

        -- 1. Audio-Feeding fuer Stream & Studio-Lautsprecher
        if ev == "radio_feed" then
            pumpBroadcastStream()
        elseif ev == "speaker_audio_empty" then
            processStudioQueue()

        -- 2. HTTP-Antworten fuer Stream-Download (Radio & Alarm getrennt!)
        elseif ev == "http_success" then
            local url, handle = p1, p2
            if url == state.loadingAlarmUrl then
                state.loadingAlarmUrl   = nil
                state.isLoadingAlarm    = false
                state.alarmStreamHandle = handle
                state.dirty             = true
                pumpBroadcastStream()
            elseif url == state.loadingRadioUrl then
                state.loadingRadioUrl   = nil
                state.isLoadingRadio    = false
                state.radioStreamHandle = handle
                state.dirty             = true
                pumpBroadcastStream()
            else
                pcall(handle.close)
            end

        elseif ev == "http_failure" then
            local url = p1
            if url == state.loadingAlarmUrl then
                state.loadingAlarmUrl = nil
                state.isLoadingAlarm  = false
                state.audioError      = "Alarm-Stream Fehler"
                state.retryTimer      = os.startTimer(2.0)
                state.dirty           = true
            elseif url == state.loadingRadioUrl then
                state.loadingRadioUrl = nil
                state.isLoadingRadio  = false
                state.audioError      = "Stream-Fehler"
                addLog("Stream fehlgeschlagen! Naechster Track in 3s...")
                state.retryTimer      = os.startTimer(3.0)
                state.dirty           = true
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
                if hitboxes.toggleAirBtn and y == hitboxes.toggleAirBtn.y and x >= hitboxes.toggleAirBtn.x1 and x <= hitboxes.toggleAirBtn.x2 then
                    state.isPlaying = not state.isPlaying
                    saveConfig()
                    syncPlaybackEngine()
                    sendReport(true)
                    state.dirty = true
                elseif hitboxes.playBtn and y == hitboxes.playBtn.y and x >= hitboxes.playBtn.x1 and x <= hitboxes.playBtn.x2 then
                    state.isPlaying = not state.isPlaying
                    saveConfig()
                    syncPlaybackEngine()
                    sendReport(true)
                    state.dirty = true
                elseif hitboxes.skipBtn and y == hitboxes.skipBtn.y and x >= hitboxes.skipBtn.x1 and x <= hitboxes.skipBtn.x2 then
                    advanceToNextRadioTrack(false)
                    sendReport(true)
                elseif hitboxes.addBtn and y == hitboxes.addBtn.y and x >= hitboxes.addBtn.x1 and x <= hitboxes.addBtn.x2 then
                    local input = editInput("YouTube-Link / ID einfuegen:")
                    if input and #input > 0 then
                        addLog("Lade Videotitel...")
                        drawUI()
                        local vid, title = state.fetchVideoInfo(input)
                        if vid ~= "" then
                            table.insert(state.playlist, { id = vid, title = title })
                            state.selectedTrackIdx = #state.playlist
                            saveConfig()
                            addLog("Track zugefuegt: " .. title:sub(1, 20))
                            if not state.activeRadioId then
                                syncPlaybackEngine()
                            end
                        else
                            addLog("Fehler: Kein Video gefunden!")
                        end
                    end
                    state.dirty = true
                elseif hitboxes.moveUp and y == hitboxes.moveUp.y and x >= hitboxes.moveUp.x1 and x <= hitboxes.moveUp.x2 then
                    local sel = state.selectedTrackIdx
                    if sel and sel > 1 then
                        local tmp = state.playlist[sel]
                        state.playlist[sel] = state.playlist[sel - 1]
                        state.playlist[sel - 1] = tmp
                        state.selectedTrackIdx = sel - 1
                        saveConfig()
                        state.dirty = true
                    end
                elseif hitboxes.moveDn and y == hitboxes.moveDn.y and x >= hitboxes.moveDn.x1 and x <= hitboxes.moveDn.x2 then
                    local sel = state.selectedTrackIdx
                    if sel and sel < #state.playlist then
                        local tmp = state.playlist[sel]
                        state.playlist[sel] = state.playlist[sel + 1]
                        state.playlist[sel + 1] = tmp
                        state.selectedTrackIdx = sel + 1
                        saveConfig()
                        state.dirty = true
                    end
                elseif hitboxes.delTrack and y == hitboxes.delTrack.y and x >= hitboxes.delTrack.x1 and x <= hitboxes.delTrack.x2 then
                    local sel = state.selectedTrackIdx
                    if sel and state.playlist[sel] then
                        table.remove(state.playlist, sel)
                        state.selectedTrackIdx = nil
                        saveConfig()
                        if state.curIdx > #state.playlist then
                            state.curIdx = 1
                        end
                        syncPlaybackEngine()
                        state.dirty = true
                    end
                elseif hitboxes.scrollUp and y == hitboxes.scrollUp.y and x >= hitboxes.scrollUp.x1 and x <= hitboxes.scrollUp.x2 then
                    state.scrollOffset = math.max(0, (state.scrollOffset or 0) - 1)
                    state.dirty = true
                elseif hitboxes.scrollDn and y == hitboxes.scrollDn.y and x >= hitboxes.scrollDn.x1 and x <= hitboxes.scrollDn.x2 then
                    local maxOff = math.max(0, #state.playlist - 4)
                    state.scrollOffset = math.min(maxOff, (state.scrollOffset or 0) + 1)
                    state.dirty = true
                else
                    local clickedTrack = false
                    for k, hb in pairs(hitboxes) do
                        if k:match("^track_") and y == hb.y and x >= hb.x1 and x <= hb.x2 then
                            if state.selectedTrackIdx == hb.idx then
                                state.selectedTrackIdx = nil
                            else
                                state.selectedTrackIdx = hb.idx
                            end
                            clickedTrack = true
                            state.dirty = true
                            break
                        end
                    end
                    if not clickedTrack then
                        state.selectedTrackIdx = nil
                        state.dirty = true
                    end
                end
            end

        -- 4. Rednet-Nachrichten (Emergency, Lockdown, Master-Sync & Remote-Update)
        elseif ev == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3

            if protocol == CFG.PROTOCOL and not state.updatingState then
                if message == CFG.MSG_ON and not state.emergencyActive then
                    state.emergencyActive = true
                    addLog("EMERGENCY: Synchron-Alarm gestartet!")
                    syncPlaybackEngine()
                elseif message == CFG.MSG_OFF and state.emergencyActive then
                    state.emergencyActive = false
                    addLog("Emergency beendet -> Radio laeuft weiter.")
                    syncPlaybackEngine()
                end
                state.dirty = true

            elseif protocol == CFG.LOCKDOWN_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_LOCK and not state.lockdownActive then
                    state.lockdownActive = true
                    addLog("LOCKDOWN: Synchron-Alarm gestartet!")
                    syncPlaybackEngine()
                elseif message == CFG.MSG_UNLOCK and state.lockdownActive then
                    state.lockdownActive = false
                    addLog("Lockdown beendet -> Radio laeuft weiter.")
                    syncPlaybackEngine()
                end
                state.dirty = true

            elseif protocol == CFG.SPK_CONFIG_PROTO and not state.updatingState then
                if type(message) == "table" and message.action == "set_alarm_config" then
                    applyAlarmConfig(message)
                    if type(message.radioPlaylist) == "table" and #message.radioPlaylist > 0 and #state.playlist == 0 then
                        for _, t in ipairs(message.radioPlaylist) do
                            if type(t) == "table" and t.id then
                                table.insert(state.playlist, { id = tostring(t.id), title = state.cleanTitle(t.title or "YouTube-Video") })
                            end
                        end
                        saveConfig()
                        syncPlaybackEngine()
                    end
                end

            elseif protocol == CFG.CONFIG_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif type(message) == "table" then
                    if message.action == "set_alarm_config" then
                        applyAlarmConfig(message)
                    elseif message.action == "set_radio_playlist" and type(message.playlist) == "table" then
                        state.playlist = {}
                        for _, t in ipairs(message.playlist) do
                            if type(t) == "table" and t.id then
                                table.insert(state.playlist, { id = tostring(t.id), title = state.cleanTitle(t.title or "YouTube-Video") })
                            end
                        end
                        state.curIdx = 1
                        saveConfig()
                        addLog("Playlist aktualisiert (" .. tostring(#state.playlist) .. " Tracks)")
                        syncPlaybackEngine()
                        sendReport(true)
                        state.dirty = true
                    elseif message.action == "play" then
                        state.isPlaying = true
                        saveConfig()
                        syncPlaybackEngine()
                        sendReport(true)
                        state.dirty = true
                    elseif message.action == "stop" then
                        state.isPlaying = false
                        saveConfig()
                        syncPlaybackEngine()
                        sendReport(true)
                        state.dirty = true
                    elseif message.action == "skip" then
                        advanceToNextRadioTrack(false)
                        sendReport(true)
                    elseif message.action == "request_radio_sync" then
                        rednet.send(senderId, {
                            action     = "set_radio_playlist",
                            playlist   = state.playlist,
                            curIdx     = state.curIdx,
                            isPlaying  = state.isPlaying,
                            isReply    = true
                        }, CFG.CONFIG_PROTOCOL)
                    end
                end

            elseif protocol == CFG.UPDATE_PROTOCOL then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif senderId == CFG.MASTER_ID and type(message) == "table" and message.action == "update" then
                    pcall(function() rednet.send(CFG.MASTER_ID, { action = "ping_ack" }, CFG.UPDATE_PROTOCOL) end)
                    applyUpdate()
                    state.tickTimer = os.startTimer(0.5)
                end
            end

        -- 5. Timer fuer Broadcast-Pacing, Studio-Sync, Logs & Lauftext
        elseif ev == "timer" then
            if p1 == state.paceTimer then
                state.paceTimer = nil
                pumpBroadcastStream()
            elseif p1 == state.syncTimer then
                state.syncTimer = nil
                processStudioQueue()
            elseif p1 == state.tickTimer then
                state.tickTimer = os.startTimer(0.5)
                state.marqueeOffset = (state.marqueeOffset or 0) + 1
                state.dirty = true
                local t = now()
                for i = #state.logs, 1, -1 do
                    if state.logs[i].expires <= t then
                        table.remove(state.logs, i)
                    end
                end
                -- Sicherheits-Pumpe falls ein Timer verschluckt wurde
                pumpBroadcastStream()
                processStudioQueue()
            elseif p1 == state.retryTimer then
                state.retryTimer = nil
                if state.lockdownActive or state.emergencyActive then
                    syncPlaybackEngine()
                else
                    advanceToNextRadioTrack(false)
                end
            end

        elseif ev == "peripheral" or ev == "peripheral_detach" then
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
        stopAllPlayback()
        if tostring(err):find("Terminated") then
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("RadioHost beendet.")
            return
        end
        addLog("Fehler: " .. tostring(err))
        sleep(2)
    end
end
