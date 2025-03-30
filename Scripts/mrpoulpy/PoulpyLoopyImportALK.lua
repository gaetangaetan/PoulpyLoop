--[[------------------------------------------------------------------------------
  PoulpyLoopyImportALK.lua
  Module contenant les fonctions d'importation ALK pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper

-- Charger le module Core
local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/"
local core = dofile(script_path .. "PoulpyLoopyCore.lua")

-- Importer les fonctions et constantes du Core dont nous avons besoin
local COLORS = core.COLORS
local SetTakeMetadata = core.SetTakeMetadata

-- Partition de la timeline
local signatureSections = {
    { startBeat=0,   endBeat=840,   sigNum=3, sigDenom=4 },
    { startBeat=840, endBeat=1200,  sigNum=4, sigDenom=4 },
    { startBeat=1200,endBeat=999999,sigNum=4, sigDenom=4 }
}

--------------------------------------------------------------------------------
-- Fonctions utilitaires
--------------------------------------------------------------------------------
local function ComputeMeasureBeatFromGlobalBeat(globalBeat, sections)
    local leftover = globalBeat
    local measureCount = 0
    for _, sec in ipairs(sections) do
        local sectionLen = sec.endBeat - sec.startBeat
        if leftover < sectionLen then
            local fullM = math.floor(leftover/sec.sigNum)
            measureCount = measureCount + fullM
            local beatIn = leftover % sec.sigNum
            return measureCount, beatIn, sec.sigNum, sec.sigDenom
        else
            local f = math.floor(sectionLen / sec.sigNum)
            measureCount = measureCount + f
            leftover = leftover - sectionLen
        end
    end
    local last = sections[#sections]
    local measureSize = last.sigNum
    local f = math.floor(leftover / measureSize)
    measureCount = measureCount + f
    local b = leftover % measureSize
    return measureCount, b, last.sigNum, last.sigDenom
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil, "Impossible d'ouvrir le fichier" end
    local c = f:read("*all")
    f:close()
    return c
end

--------------------------------------------------------------------------------
-- Fonctions de parsing ALK
--------------------------------------------------------------------------------
local function parseALK(content)
    if not content then return nil, "Contenu vide" end

    local data = {
        tracks = {},
        trackTypes = {
            [0] = { name="Piste Audio", tracks={} },
            [1] = { name="Piste Instrument", tracks={} },
            [2] = { name="Piste MIDI", tracks={} },
            [3] = { name="Command", tracks={} },
            [4] = { name="Control", tracks={} }
        },
        transport = {}
    }

    local tAttr = content:match('<transport%s+([^>]+)>')
    if tAttr then
        data.transport.id = tAttr:match('id="([^"]*)"') or ""
        data.transport.bpm = tonumber(tAttr:match('bpm="([^"]*)"') or "0")
        data.transport.position = tonumber(tAttr:match('position="([^"]*)"') or "0")
    end

    for trackAttr, trackBody in content:gmatch('<track%s+([^>]+)>(.-)</track>') do
        local track = { loops = {} }
        track.name = trackAttr:match('name="([^"]*)"') or "Sans nom"
        track.id = trackAttr:match('id="([^"]*)"') or ""
        track.trackType = tonumber(trackAttr:match('trackType="([^"]*)"') or "0")
        track.color = trackAttr:match('color="([^"]*)"') or ""
        track.enabled = (trackAttr:match('enabled="([^"]*)"') == "1")
        track.solo = (trackAttr:match('solo="([^"]*)"') == "1")

        local loopCount = 0
        for loopAttr, loopInner in trackBody:gmatch('<loop%s+([^>]+)>(.-)</loop>') do
            loopCount = loopCount + 1
            local lp = {}
            lp.name = loopAttr:match('name="([^"]*)"') or ("Region " .. loopCount)
            lp.id = loopAttr:match('id="([^"]*)"') or ""
            lp.regionType = tonumber(loopAttr:match('regionType="([^"]*)"') or "0")
            lp.playLooped = (loopAttr:match('playLooped="([^"]*)"') == "1")
            lp.tempoAdjust = (loopAttr:match('tempoAdjust="([^"]*)"') == "1")
            lp.pitchChgSemis = tonumber(loopAttr:match('pitchChgSemis="([^"]*)"') or "0")
            lp.recordLoopName = loopAttr:match('recordLoopName="([^"]*)"') or ""

            local dAttr = loopInner:match('<[Dd]oubleinterval%s+([^>]+)/>')
            if dAttr then
                lp.beginTime = tonumber(dAttr:match('begin="([^"]*)"') or "0")
                lp.endTime = tonumber(dAttr:match('end="([^"]*)"') or "0")
                lp.duration = lp.endTime - lp.beginTime
            else
                lp.beginTime = 0
                lp.endTime = 0
                lp.duration = 0
            end

            local destBlock = loopInner:match('<destinations>(.-)</destinations>')
            if destBlock then
                lp.destinations = {}
                for line in destBlock:gmatch('<destination%s+([^>]+)') do
                    local d = {}
                    d.type = line:match('type="([^"]*)"')
                    d.object = line:match('object="([^"]*)"')
                    d.arg = line:match('arg="([^"]*)"')
                    d.value = tonumber(line:match('value="([^"]*)"') or "0")
                    d.min = tonumber(line:match('min="([^"]*)"') or "0")
                    d.max = tonumber(line:match('max="([^"]*)"') or "1")
                    table.insert(lp.destinations, d)
                end
                if lp.regionType == 3 then
                    for _, dd in ipairs(lp.destinations) do
                        if dd.object == data.transport.id then
                            if dd.arg == "0" then
                                lp.tempoBpm = dd.value * 170 + 60
                            elseif dd.arg == "5" then
                                lp.signature = math.floor(dd.value * 23 + 1 + 0.5)
                            end
                        end
                    end
                end
            end

            table.insert(track.loops, lp)
        end
        table.insert(data.tracks, track)
        local tt = track.trackType or 0
        if tt >= 0 and tt <= 4 then
            table.insert(data.trackTypes[tt].tracks, track)
        end
    end

    return data
end

--------------------------------------------------------------------------------
-- Fonctions d'importation
--------------------------------------------------------------------------------
local function importAutomation(alkData)
    if not alkData then return end

    local tempoTr
    for _, tr in ipairs(alkData.trackTypes[3].tracks) do
        if (tr.name or ""):upper() == "TEMPO" then
            tempoTr = tr
            break
        end
    end
    if not tempoTr then
        debug_console("Aucune piste TEMPO trouvée dans l'ALK\n")
        return
    end
    for _, lp in ipairs(tempoTr.loops or {}) do
        if lp.regionType == 3 then
            local meas, beatIn, sN, sD = ComputeMeasureBeatFromGlobalBeat(lp.beginTime, signatureSections)
            local newBpm = alkData.transport.bpm
            if lp.tempoBpm then newBpm = lp.tempoBpm end
            if lp.signature then sN = lp.signature; sD = 4 end
            reaper.SetTempoTimeSigMarker(0, -1, -1, meas, beatIn, newBpm, sN, sD, false)
        end
    end
end

local function importRegions(alkData)
    if not alkData then return end
    local totalTracks = #alkData.tracks
    local startIdx = reaper.CountTracks(0) - totalTracks

    for i, alkTrack in ipairs(alkData.tracks) do
        if alkTrack.trackType ~= 3 then
            local track = reaper.GetTrack(0, startIdx + i - 1)
            if track then
                -- Identifier les loops RECORD qui sont référencées
                local referencedLoops = {}
                if alkTrack.trackType == 0 then
                    for _, lp in ipairs(alkTrack.loops) do
                        if lp.regionType == 1 and lp.recordLoopName ~= "" then
                            referencedLoops[lp.recordLoopName] = true
                        end
                    end
                end

                -- Création item MIDI
                for _, lp in ipairs(alkTrack.loops) do
                    if lp.regionType ~= 3 then
                        local tStart = reaper.TimeMap2_beatsToTime(0, lp.beginTime)
                        local tEnd = reaper.TimeMap2_beatsToTime(0, lp.endTime)
                        local item = reaper.CreateNewMIDIItemInProj(track, tStart, tEnd, false)
                        if item then
                            local take = reaper.GetActiveTake(item)
                            local finalLoopType
                            local regionName = lp.name
                            
                            -- Détermination du type de loop
                            if lp.regionType == 0 then
                                -- Si c'est une région RECORD, on vérifie si elle est référencée
                                if referencedLoops[lp.name] then
                                    finalLoopType = "RECORD"
                                else
                                    finalLoopType = "MONITOR"  -- RECORD non référencée -> MONITOR
                                end
                            elseif lp.regionType == 1 then
                                finalLoopType = "PLAY"
                                if lp.recordLoopName ~= "" then
                                    regionName = lp.recordLoopName
                                end
                            end

                            local trackNum = startIdx + i
                            local prefix = string.format("%02d", trackNum)
                            local finalName = prefix .. " " .. regionName
                            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", finalName, true)

                            -- Couleur
                            if alkTrack.trackType == 0 then
                                local itemColor
                                if finalLoopType == "PLAY" then
                                    itemColor = COLORS.PLAY
                                elseif finalLoopType == "RECORD" then
                                    itemColor = COLORS.RECORD
                                else
                                    itemColor = COLORS.MONITOR
                                end
                                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", itemColor)
                            end

                            -- Stocker P_EXT
                            SetTakeMetadata(take, "loop_type", finalLoopType)
                            SetTakeMetadata(take, "loop_name", finalName)
                            SetTakeMetadata(take, "pitch", tostring(lp.pitchChgSemis or 0))
                            
                            -- Initialisation du monitoring en fonction du type de loop
                            local monitoring = "1"  -- Par défaut ON pour RECORD, MONITOR et OVERDUB
                            if finalLoopType == "PLAY" then
                                monitoring = "0"  -- OFF pour PLAY
                            end
                            SetTakeMetadata(take, "monitoring", monitoring)
                            
                            -- Pour les loops PLAY, on stocke aussi la référence à la loop RECORD
                            if finalLoopType == "PLAY" and lp.recordLoopName ~= "" then
                                local refName = prefix .. " " .. lp.recordLoopName
                                SetTakeMetadata(take, "reference_loop", refName)
                            end
                        end
                    end
                end
            end
        end
    end
    reaper.UpdateArrange()
end

local function importMetronome(alkData, selectedTrackIndex)
    if not alkData then return end
    
    -- Utiliser la piste sélectionnée dans le menu déroulant
    local selectedTrackIndex = selectedTrackIndex or 0
    local clickTracks = alkData.trackTypes[3].tracks or {}
    
    if #clickTracks == 0 then
        reaper.ShowMessageBox("Aucune piste de commande (Command) trouvée dans le projet ALK.", "Information", 0)
        return
    end
    
    local metronomeTrack = clickTracks[selectedTrackIndex + 1]
    if not metronomeTrack then
        reaper.ShowMessageBox("Piste de clic invalide.", "Erreur", 0)
        return
    end
    
    -- Sélectionner la dernière piste du projet
    local lastTrackIndex = reaper.CountTracks(0) - 1
    local lastTrack = reaper.GetTrack(0, lastTrackIndex)
    if lastTrack then
        reaper.SetOnlyTrackSelected(lastTrack)
    end
    
    -- Créer une nouvelle piste et nommer comme la piste sélectionnée
    reaper.Main_OnCommand(40042, 0)  -- Go to start of project
    reaper.Main_OnCommand(40222, 0)  -- Loop points: Set start point
    reaper.Main_OnCommand(40043, 0)  -- Go to end of project
    reaper.Main_OnCommand(40223, 0)  -- Loop points: Set end point
    
    -- Stocker l'index de la piste avant de la créer
    local trackIndex = reaper.CountTracks(0)
    reaper.Main_OnCommand(40001, 0)  -- Track: Insert new track
    
    -- Récupérer la piste créée
    local track = reaper.GetTrack(0, trackIndex)
    if not track then
        reaper.ShowMessageBox("Erreur : Impossible de créer la piste.", "Erreur", 0)
        return
    end
    
    -- Nommer la piste comme la piste sélectionnée
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", metronomeTrack.name, true)
    
    -- Insérer la source de clic
    reaper.Main_OnCommand(40013, 0)  -- Insert click source

    -- Vérifier qu'un item a bien été créé
    local numItems = reaper.CountTrackMediaItems(track)
    if numItems == 0 then
        reaper.ShowMessageBox("Erreur : Aucun item créé sur la piste.", "Erreur", 0)
        return
    end
    
    local item = reaper.GetTrackMediaItem(track, 0)
    
    -- Marquer l'item comme "sans automation" initialement
    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.CLICK_NO_AUTO)

    -- Table pour stocker les segments à supprimer (pour éviter de modifier la collection pendant l'itération)
    local segmentsToDelete = {}

    -- Découper aux points de début et fin selon les données ALK
    for _, lp in ipairs(metronomeTrack.loops or {}) do
        if lp.beginTime and lp.endTime then
            local startTime = reaper.TimeMap2_beatsToTime(0, lp.beginTime)
            local endTime = reaper.TimeMap2_beatsToTime(0, lp.endTime)
            
            -- Découper aux points de début et fin
            reaper.SetEditCurPos(startTime, false, false)
            reaper.Main_OnCommand(40012, 0)  -- Split items at edit cursor
            reaper.SetEditCurPos(endTime, false, false)
            reaper.Main_OnCommand(40012, 0)  -- Split items at edit cursor
            
            -- Trouver l'item correspondant à cette section
            local numItems = reaper.CountTrackMediaItems(track)
            for i = 0, numItems - 1 do
                local splitItem = reaper.GetTrackMediaItem(track, i)
                local splitStart = reaper.GetMediaItemInfo_Value(splitItem, "D_POSITION")
                local splitLength = reaper.GetMediaItemInfo_Value(splitItem, "D_LENGTH")
                local splitEnd = splitStart + splitLength
                
                -- Vérifier si c'est un segment qui correspond exactement à cette boucle
                if math.abs(splitStart - startTime) < 0.01 and math.abs(splitEnd - endTime) < 0.01 then
                    -- Vérifier si la section doit être mutée/supprimée
                    local shouldDelete = false
                    
                    if lp.destinations then
                        for _, dest in ipairs(lp.destinations) do
                            if dest.type == "parameter" then
                                if dest.value == 0 then
                                    -- Marquer pour suppression
                                    shouldDelete = true
                                else
                                    -- Marquer comme actif
                                    reaper.SetMediaItemInfo_Value(splitItem, "I_CUSTOMCOLOR", COLORS.CLICK_ACTIVE)
                                end
                                break
                            end
                        end
                    end
                    
                    if shouldDelete then
                        table.insert(segmentsToDelete, splitItem)
                    end
                    
                    break
                end
            end
        end
    end
    
    -- Supprimer les segments marqués pour suppression
    for _, itemToDelete in ipairs(segmentsToDelete) do
        reaper.DeleteTrackMediaItem(track, itemToDelete)
    end
    
    -- Supprimer les petits segments résiduels (moins de 0.05 seconde)
    local i = 0
    while i < reaper.CountTrackMediaItems(track) do
        local currentItem = reaper.GetTrackMediaItem(track, i)
        local itemLength = reaper.GetMediaItemInfo_Value(currentItem, "D_LENGTH")
        
        if itemLength < 0.05 then
            reaper.DeleteTrackMediaItem(track, currentItem)
        else
            i = i + 1
        end
    end

    reaper.UpdateArrange()
    reaper.ShowMessageBox("Automation du clic appliquée avec succès!", "Opération terminée", 0)
end

local function importProject(alkData)
    if not alkData then return end

    reaper.Undo_BeginBlock()
    local count0 = reaper.CountTracks(0)
    for i, alkTrack in ipairs(alkData.tracks) do
        reaper.InsertTrackAtIndex(count0 + i - 1, true)
        local tr = reaper.GetTrack(0, count0 + i - 1)
        reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", alkTrack.name, true)
        local c
        if alkTrack.trackType == 0 then
            c = COLORS.RECORD
        elseif alkTrack.trackType == 1 then
            c = COLORS.PLAY
        elseif alkTrack.trackType == 2 then
            c = COLORS.MONITOR
        elseif alkTrack.trackType == 3 then
            c = COLORS.OVERDUB
        elseif alkTrack.trackType == 4 then
            c = COLORS.MONITOR_REF
        else
            c = COLORS.AUTOMATION
        end
        reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", c)
    end
    reaper.Undo_EndBlock("Importer les pistes ALK", -1)
    reaper.TrackList_AdjustWindows(false)
    reaper.SetMasterTrackVisibility(1)

    importAutomation(alkData)
    importRegions(alkData)
    
    -- Afficher un message de confirmation
    reaper.ShowMessageBox("Importation du projet ALK terminée avec succès !", "Opération terminée", 0)
end

--------------------------------------------------------------------------------
-- Export des fonctions
--------------------------------------------------------------------------------
return {
    parseALK = parseALK,
    importProject = importProject,
    importMetronome = importMetronome,
    readFile = readFile
} 