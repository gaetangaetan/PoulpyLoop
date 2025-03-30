--[[------------------------------------------------------------------------------
  PoulpyLoopyUI.lua
  Module contenant les fonctions de l'interface utilisateur pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper

-- Charger le module Core
local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/"
local core = dofile(script_path .. "PoulpyLoopyCore.lua")
local alk = dofile(script_path .. "PoulpyLoopyImportALK.lua")

-- Créer le contexte ImGui au niveau global
local ctx = reaper.ImGui_CreateContext('PoulpyLoopy')

-- Fonction utilitaire pour supprimer les espaces en début et fin de chaîne
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- Importer les fonctions et constantes du Core dont nous avons besoin
local COLORS = core.COLORS
local LOOP_TYPES = core.LOOP_TYPES
local VERSION = core.VERSION
local GMEM = core.GMEM
local GetTakeMetadata = core.GetTakeMetadata
local SetTakeMetadata = core.SetTakeMetadata
local IsLoopNameValid = core.IsLoopNameValid
local UpdateDependentLoops = core.UpdateDependentLoops
local ProcessMIDINotes = core.ProcessMIDINotes
local UnfoldPlayLoop = core.UnfoldPlayLoop
local get_record_monitor_loops_mode = core.get_record_monitor_loops_mode
local get_playback_mode = core.get_playback_mode
local save_record_monitor_loops_mode = core.save_record_monitor_loops_mode
local save_playback_mode = core.save_playback_mode
local addLooper = core.addLooper
local setLoopsMonoStereo = core.setLoopsMonoStereo
local parseALK = core.parseALK
local importProject = core.importProject
local importMetronome = core.importMetronome
local debug_console = core.debug_console

-- Module à exporter
local M = {}

--------------------------------------------------------------------------------
-- Variables locales pour l'interface
--------------------------------------------------------------------------------
local loop_types = LOOP_TYPES
local selected_loop_type_index = 0
local loop_name = ""
local is_mono = false
local pan = 0.0
local volume_db = 0.0
local reference_loop = ""
local pitch = 0
local monitoring = 0
local current_take = nil
local current_midi_note = nil
local current_midi_velocity = nil
local selected_click_track_index = 0
local last_cursor_pos = -1
local title_font = nil

-- Variables pour les modes
local record_monitor_loops = false
local playback_mode = false
local last_message_check = 0
local message_history = {}
local MAX_HISTORY_LINES = 20

-- Variables pour les entrées audio
local recInputOptions = {}
local selectedRecInputOption = 1

-- Données globales pour les loopers
local looperUsage = {}

-- Variables pour l'importation ALK
local alkData = nil
local errorMessage = ""

--------------------------------------------------------------------------------
-- Fonctions locales
--------------------------------------------------------------------------------
-- Fonction pour obtenir les loops RECORD précédentes
local function GetPreviousRecordLoopsInFolder(take)
    local base_track = reaper.GetMediaItemTake_Track(take)
    local curItem = reaper.GetMediaItemTake_Item(take)
    local curStart = reaper.GetMediaItemInfo_Value(curItem, "D_POSITION")
    local recordLoops = {}
    
    -- Ne traiter que la piste actuelle
    local nb = reaper.CountTrackMediaItems(base_track)
    for i = 0, nb-1 do
        local it = reaper.GetTrackMediaItem(base_track, i)
        local st = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if st < curStart then
            for tk = 0, reaper.CountTakes(it)-1 do
                local tkTake = reaper.GetTake(it, tk)
                if tkTake then
                    local ty = GetTakeMetadata(tkTake, "loop_type")
                    if ty == "RECORD" then
                        local nm = GetTakeMetadata(tkTake, "loop_name")
                        if nm ~= "" then
                            recordLoops[nm] = true
                        end
                    end
                end
            end
        end
    end
    
    local result = {}
    for k, _ in pairs(recordLoops) do
        table.insert(result, k)
    end
    table.sort(result)
    return result
end

--------------------------------------------------------------------------------
-- Fonctions de gestion des entrées audio
--------------------------------------------------------------------------------
local function buildRecInputOptions()
    recInputOptions = {}
    table.insert(recInputOptions, { label="None", iRecInput=0 })

    local maxAudioCh = reaper.GetNumAudioInputs()
    if maxAudioCh <= 0 then return end

    local channelNames = {}
    for i = 0, maxAudioCh - 1 do
        local retval, chName = reaper.GetInputChannelName(i, 0)
        if not retval or chName == "" then
            chName = "ch " .. (i + 1)
        end
        channelNames[i] = chName
    end

    -- Mono
    for i = 0, maxAudioCh - 1 do
        local label = "Mono: " .. (channelNames[i] or ("ch " .. (i + 1)))
        table.insert(recInputOptions, {
            label = label,
            iRecInput = i,
            isMono = true
        })
    end

    -- Stéréo
    for i = 0, maxAudioCh - 2 do
        local c1 = channelNames[i] or ("ch " .. (i + 1))
        local c2 = channelNames[i + 1] or ("ch " .. (i + 2))
        local label = "Stereo: " .. c1 .. " / " .. c2
        table.insert(recInputOptions, {
            label = label,
            iRecInput = (i | 1024),
            isStereo = true
        })
    end
end

local function getCurrentRecInputOption()
    return recInputOptions[selectedRecInputOption] or recInputOptions[1]
end

local function getCurrentRecInputLabel()
    return getCurrentRecInputOption().label
end

local function drawRecInputCombo()
    local label = getCurrentRecInputLabel()
    if reaper.ImGui_BeginCombo(ctx, "Entrée Audio", label) then
        for i, opt in ipairs(recInputOptions) do
            local isSel = (selectedRecInputOption == i)
            if reaper.ImGui_Selectable(ctx, opt.label, isSel) then
                selectedRecInputOption = i
            end
            if isSel then
                reaper.ImGui_SetItemDefaultFocus(ctx)
            end
        end
        reaper.ImGui_EndCombo(ctx)
    end
end

--------------------------------------------------------------------------------
-- Fonctions de gestion des loopers
--------------------------------------------------------------------------------
local function makeFolder(folderTrack, childTracks)
    reaper.SetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH", 1)
    for i, tr in ipairs(childTracks) do
        if i < #childTracks then
            reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
        else
            reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", -1)
        end
    end
end

local function addLooperBase(isMono)
    local selCount = reaper.CountSelectedTracks(0)
    if selCount == 0 then
        reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
        reaper.TrackList_AdjustWindows(false)
        local newTrack = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
        reaper.SetTrackSelected(newTrack, true)
        selCount = 1
    end

    local opt = recInputOptions[selectedRecInputOption]
    local iRec = opt and opt.iRecInput or 0

    local processedTracks = {}
    
    for i = 0, selCount - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if track then
            table.insert(processedTracks, track)
            reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", iRec)
            reaper.TrackFX_AddByName(track, "PoulpyLoop", false, -1)
            reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
            reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)

            local usage = isMono and "mono" or "stereo"
            local guid = reaper.GetTrackGUID(track)
            looperUsage[guid] = usage
        end
    end
    
    for _, track in ipairs(processedTracks) do
        reaper.SetTrackSelected(track, false)
    end
    
    reaper.UpdateArrange()
end

local function addLooper()
    local selCount = reaper.CountSelectedTracks(0)
    if selCount == 0 then
        reaper.ShowMessageBox("Aucune piste sélectionnée.", "Erreur", 0)
        return
    end

    local tracks = {}
    for i = 0, selCount - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if track then
            table.insert(tracks, track)
        end
    end

    if #tracks > 0 then
        local folderTrack = tracks[1]
        makeFolder(folderTrack, tracks)
        addLooperBase(false)  -- false = toujours en stéréo
    end
end

local function setLoopsMonoStereo(isMono)
    local selCount = reaper.CountSelectedTracks(0)
    if selCount == 0 then
        reaper.ShowMessageBox("Aucune piste sélectionnée.", "Erreur", 0)
        return
    end

    for i = 0, selCount - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if track then
            local itemCount = reaper.CountTrackMediaItems(track)
            for j = 0, itemCount - 1 do
                local item = reaper.GetTrackMediaItem(track, j)
                if item then
                    local take = reaper.GetActiveTake(item)
                    if take and reaper.TakeIsMIDI(take) then
                        local loop_type = GetTakeMetadata(take, "loop_type")
                        if loop_type == "RECORD" or loop_type == "OVERDUB" or loop_type == "MONITOR" then
                            SetTakeMetadata(take, "is_mono", tostring(isMono))
                        end
                    end
                end
            end
        end
    end
    ProcessMIDINotes()
    reaper.UpdateArrange()
end

--------------------------------------------------------------------------------
-- Fonctions de traitement MIDI
--------------------------------------------------------------------------------
local function ProcessMIDINotes()
    local noteCounters = {}
    local recordLoopPitches = {}
    local allTakes = {}

    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, t)
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item then
                for j = 0, reaper.CountTakes(item) - 1 do
                    local take = reaper.GetTake(item, j)
                    if take and reaper.TakeIsMIDI(take) then
                        local loop_type = GetTakeMetadata(take, "loop_type")
                        if loop_type then
                            table.insert(allTakes, {
                                take = take,
                                item = item,
                                start_time = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                                loop_type = loop_type,
                                track = track
                            })
                        end
                    end
                end
            end
        end
    end

    -- Trier les takes par piste et position
    table.sort(allTakes, function(a, b)
        local trackA_id = reaper.GetMediaTrackInfo_Value(a.track, "IP_TRACKNUMBER")
        local trackB_id = reaper.GetMediaTrackInfo_Value(b.track, "IP_TRACKNUMBER")
        if trackA_id == trackB_id then
            return a.start_time < b.start_time
        else
            return trackA_id < trackB_id
        end
    end)

    -- Traiter chaque take
    for _, entry in ipairs(allTakes) do
        local take = entry.take
        local item = entry.item
        local loop_type = entry.loop_type
        local track = entry.track
        local track_id = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")

        if not noteCounters[track_id] then
            noteCounters[track_id] = 1
            recordLoopPitches[track_id] = {}
        end

        if loop_type == "UNUSED" then goto continue end

        reaper.MIDI_SetAllEvts(take, "")
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_start + item_length
        local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_start)
        local end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_end)

        -- Traiter selon le type de loop
        if loop_type == "RECORD" then
            local pitch = noteCounters[track_id]
            noteCounters[track_id] = noteCounters[track_id] + 1
            local loop_name = GetTakeMetadata(take, "loop_name") or ""
            recordLoopPitches[track_id][loop_name] = pitch
            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, pitch, 1, false)

        elseif loop_type == "PLAY" or loop_type == "OVERDUB" then
            local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
            local ref_name = reference_loop:match("%d%d%s+(.*)")
            local refNote = recordLoopPitches[track_id][reference_loop] or
                          (ref_name and recordLoopPitches[track_id][ref_name])
            
            if not refNote then
                for name, pitch in pairs(recordLoopPitches[track_id]) do
                    local name_without_prefix = name:match("%d%d%s+(.*)")
                    if name_without_prefix and name_without_prefix == ref_name then
                        refNote = pitch
                        break
                    end
                end
            end

            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, refNote or 0,
                                 loop_type == "PLAY" and 2 or 3, false)

        elseif loop_type == "MONITOR" then
            local pitch = noteCounters[track_id]
            noteCounters[track_id] = noteCounters[track_id] + 1
            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, pitch, 4, false)
        end

        -- Insérer les CC MIDI
        if loop_type ~= "UNUSED" then
            local volume_db_val = tonumber(GetTakeMetadata(take, "volume_db")) or 0
            local cc07 = math.floor(((volume_db_val + 20) / 40) * 127 + 0.5)
            local is_mono_str = GetTakeMetadata(take, "is_mono") or "false"
            local cc08 = (is_mono_str == "true") and 0 or 1
            local pan_val = tonumber(GetTakeMetadata(take, "pan")) or 0
            local cc10 = math.floor(64 + pan_val * 63 + 0.5)
            local pitch_val = tonumber(GetTakeMetadata(take, "pitch")) or 0
            local cc09 = math.floor(64 + pitch_val + 0.5)
            local monitoring_val = tonumber(GetTakeMetadata(take, "monitoring")) or 0

            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 7, cc07, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 8, cc08, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 10, cc10, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 9, cc09, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 11, monitoring_val, false)
        end

        reaper.MIDI_Sort(take)
        ::continue::
    end
end

--------------------------------------------------------------------------------
-- Fonctions de mise à jour des données
--------------------------------------------------------------------------------
local function UpdateTakeData(take)
    if take then
        current_take = take
        local retval, notecnt, ccevtcnt, textsyxevtcnt = reaper.MIDI_CountEvts(take)
        if retval and notecnt > 0 then
            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, 0)
            if retval then
                current_midi_note = pitch
                current_midi_velocity = vel
            end
        else
            current_midi_note = nil
            current_midi_velocity = nil
        end
        
        loop_name = GetTakeMetadata(take, "loop_name") or ""
        is_mono = (GetTakeMetadata(take, "is_mono") == "true")
        pan = tonumber(GetTakeMetadata(take, "pan")) or 0.0
        volume_db = tonumber(GetTakeMetadata(take, "volume_db")) or 0.0
        reference_loop = GetTakeMetadata(take, "reference_loop") or ""
        pitch = tonumber(GetTakeMetadata(take, "pitch")) or 0
        
        local lt = GetTakeMetadata(take, "loop_type") or "RECORD"
        selected_loop_type_index = 0
        for i, v in ipairs(loop_types) do
            if v == lt then
                selected_loop_type_index = i - 1
                break
            end
        end
        
        monitoring = tonumber(GetTakeMetadata(take, "monitoring")) or (lt == "PLAY" and 0 or 1)
    end
end

--------------------------------------------------------------------------------
-- Fonctions d'initialisation et d'interface
--------------------------------------------------------------------------------
local function init()
    buildRecInputOptions()
    return ctx
end

local function destroyContext()
    if ctx then
        reaper.ImGui_DestroyContext(ctx)
        ctx = nil
    end
end

--------------------------------------------------------------------------------
-- Fonctions de dessin des onglets
--------------------------------------------------------------------------------
local function DrawLoopEditor()
    local item = reaper.GetSelectedMediaItem(0, 0)
    local take = item and reaper.GetActiveTake(item)
    
    if take and reaper.TakeIsMIDI(take) then
        if take ~= current_take then
            UpdateTakeData(take)
        end

        -- Affichage des informations MIDI
        if current_midi_note then
            reaper.ImGui_Text(ctx, string.format("Note MIDI: %d (Vélocité: %d)", current_midi_note, current_midi_velocity))
        else
            reaper.ImGui_Text(ctx, "Aucune note MIDI trouvée")
        end
        
        reaper.ImGui_Separator(ctx)

        -- Type de Loop
        local loop_type = loop_types[selected_loop_type_index + 1]
        if reaper.ImGui_BeginCombo(ctx, "Type de Loop", loop_type) then
            for i, v in ipairs(loop_types) do
                local is_sel = (selected_loop_type_index == (i - 1))
                if reaper.ImGui_Selectable(ctx, v, is_sel) then
                    selected_loop_type_index = i - 1
                    -- Forcer le mode Mono quand PLAY est sélectionné
                    if v == "PLAY" then
                        is_mono = true
                    end
                end
                if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
            end
            reaper.ImGui_EndCombo(ctx)
        end

        -- Options spécifiques selon le type de loop
        if loop_type == "RECORD" then
            local changed, new_name = reaper.ImGui_InputText(ctx, "Nom de la Loop", loop_name, 256)
            if changed then loop_name = trim(new_name) end

            if reaper.ImGui_RadioButton(ctx, "Mono", is_mono) then is_mono = true end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Stéréo", not is_mono) then is_mono = false end

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Panoramique", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Volume (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            if reaper.ImGui_RadioButton(ctx, "Monitoring ON", monitoring == 1) then monitoring = 1 end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Monitoring OFF", monitoring == 0) then monitoring = 0 end

        elseif loop_type == "PLAY" or loop_type == "OVERDUB" then
            local prev_loops = GetPreviousRecordLoopsInFolder(take)
            
            table.insert(prev_loops, 1, "(Aucun)")
            local sel_idx = 1
            
            if reference_loop and reference_loop ~= "" then
                local ref_trimmed = trim(reference_loop):lower()
                for i, name in ipairs(prev_loops) do
                    if trim(name):lower() == ref_trimmed then
                        sel_idx = i
                        break
                    end
                    
                    local name_without_prefix = name:match("%d%d%s+(.*)")
                    if name_without_prefix and trim(name_without_prefix):lower() == ref_trimmed then
                        sel_idx = i
                        break
                    end
                    
                    local ref_without_prefix = ref_trimmed:match("%d%d%s+(.*)")
                    if ref_without_prefix and trim(name):lower() == ref_without_prefix then
                        sel_idx = i
                        break
                    end
                end
            else
                -- Pour le type PLAY, sélectionner le dernier élément par défaut
                if loop_type == "PLAY" then
                    sel_idx = #prev_loops
                    reference_loop = prev_loops[sel_idx]  -- Mettre à jour reference_loop avec la valeur par défaut
                end
            end
            
            if reaper.ImGui_BeginCombo(ctx, "Loop de Référence", prev_loops[sel_idx] or "(Aucun)") then
                for i, name in ipairs(prev_loops) do
                    local is_sel = (sel_idx == i)
                    if reaper.ImGui_Selectable(ctx, name, is_sel) then
                        sel_idx = i
                        reference_loop = (name == "(Aucun)") and "" or name
                    end
                    if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
                end
                reaper.ImGui_EndCombo(ctx)
            end

            if loop_type == "OVERDUB" then
                if reaper.ImGui_RadioButton(ctx, "Mono", is_mono) then is_mono = true end
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_RadioButton(ctx, "Stéréo", not is_mono) then is_mono = false end
            end

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Panoramique", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Volume (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            -- Pour le type PLAY, monitoring OFF par défaut
            if loop_type == "PLAY" and not reference_loop then
                monitoring = 0
            end

            if reaper.ImGui_RadioButton(ctx, "Monitoring ON", monitoring == 1) then monitoring = 1 end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Monitoring OFF", monitoring == 0) then monitoring = 0 end

            if loop_type == "PLAY" then
                local pitch_changed, new_pitch = reaper.ImGui_SliderInt(ctx, "Pitch", pitch, -24, 24)
                if pitch_changed then pitch = new_pitch end
            end

        elseif loop_type == "MONITOR" then
            if reaper.ImGui_RadioButton(ctx, "Mono", is_mono) then is_mono = true end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Stéréo", not is_mono) then is_mono = false end

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Panoramique", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Volume (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            monitoring = 1  -- Toujours ON pour MONITOR
            reaper.ImGui_RadioButton(ctx, "Monitoring ON", true)
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Monitoring OFF", false) then monitoring = 0 end

        elseif loop_type == "UNUSED" then
            reaper.ImGui_Text(ctx, "Ce clip est marqué comme UNUSED.")
        end

        -- Bouton Appliquer
        if reaper.ImGui_Button(ctx, "Appliquer") then
            if loop_type == "RECORD" then
                local valid, message = IsLoopNameValid(take, loop_name)
                if not valid then
                    reaper.ShowMessageBox(message, "Erreur", 0)
                else
                    local old_name = GetTakeMetadata(take, "loop_name") or ""
                    SetTakeMetadata(take, "loop_type", loop_type)
                    SetTakeMetadata(take, "loop_name", loop_name)
                    SetTakeMetadata(take, "is_mono", tostring(is_mono))
                    SetTakeMetadata(take, "pan", tostring(pan))
                    SetTakeMetadata(take, "volume_db", tostring(volume_db))
                    SetTakeMetadata(take, "monitoring", tostring(monitoring))
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", loop_name, true)
                    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.RECORD)
                    if old_name ~= "" and old_name ~= loop_name then
                        UpdateDependentLoops(take, old_name, loop_name)
                    end
                    ProcessMIDINotes()
                end

            elseif loop_type == "OVERDUB" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "reference_loop", reference_loop)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "is_mono", tostring(is_mono))
                SetTakeMetadata(take, "monitoring", tostring(monitoring))
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.OVERDUB)
                ProcessMIDINotes()

            elseif loop_type == "PLAY" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "reference_loop", reference_loop)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "pitch", tostring(pitch))
                SetTakeMetadata(take, "monitoring", tostring(monitoring))
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.PLAY)
                ProcessMIDINotes()
                UnfoldPlayLoop(take)  -- Appel de la fonction d'unfolding après ProcessMIDINotes

            elseif loop_type == "MONITOR" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "is_mono", tostring(is_mono))
                SetTakeMetadata(take, "monitoring", "1")  -- Toujours ON
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.MONITOR)
                ProcessMIDINotes()

            elseif loop_type == "UNUSED" then
                SetTakeMetadata(take, "loop_type", "UNUSED")
                SetTakeMetadata(take, "reference_loop", "")
                SetTakeMetadata(take, "pan", "0")
                SetTakeMetadata(take, "volume_db", "0")
                SetTakeMetadata(take, "pitch", "0")
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "(Unused)", true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.UNUSED)
                ProcessMIDINotes()
            end
        end

    else
        reaper.ImGui_Text(ctx, "Aucun item MIDI sélectionné.")
    end
end

local function DrawOptions()
    -- Partie 1: Options d'enregistrement
    reaper.ImGui_Text(ctx, "Options d'enregistrement :")
    reaper.ImGui_Separator(ctx)

    -- Radio buttons pour l'enregistrement des loops MONITOR
    reaper.ImGui_Text(ctx, "Enregistrement des loops MONITOR :")
    local changed = false
    local new_record_monitor_loops = record_monitor_loops
    if reaper.ImGui_RadioButton(ctx, "ON", record_monitor_loops) then
        new_record_monitor_loops = true
        changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Les loops MONITOR sont enregistrées comme les loops RECORD. Utile pour le mixage ultérieur.")
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "OFF", not record_monitor_loops) then
        new_record_monitor_loops = false
        changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Les loops MONITOR ne sont pas enregistrées. Idéal pour le live pour économiser la mémoire.")
    end

    -- Si le mode a changé, on le sauvegarde
    if changed then
        record_monitor_loops = new_record_monitor_loops
        save_record_monitor_loops_mode(record_monitor_loops)
    end

    reaper.ImGui_Separator(ctx)

    -- Radio buttons pour le mode LIVE/PLAYBACK
    reaper.ImGui_Text(ctx, "Mode de fonctionnement :")
    local mode_changed = false
    local new_playback_mode = playback_mode
    if reaper.ImGui_RadioButton(ctx, "LIVE", not playback_mode) then
        new_playback_mode = false
        mode_changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Mode normal d'enregistrement et de lecture. Les loops peuvent être modifiées.")
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "PLAYBACK", playback_mode) then
        new_playback_mode = true
        mode_changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Toutes les loops sont en lecture seule. Aucun enregistrement n'est possible. Idéal pour la relecture d'un projet.")
    end

    -- Si le mode a changé, on le sauvegarde
    if mode_changed then
        playback_mode = new_playback_mode
        save_playback_mode(playback_mode)
    end

    reaper.ImGui_Separator(ctx)

    -- Partie 2: Monitoring à l'arrêt
    reaper.ImGui_Text(ctx, "Monitoring à l'arrêt des pistes PoulpyLoop :")
    reaper.ImGui_Separator(ctx)

    -- Tableau pour afficher les pistes avec PoulpyLoop
    reaper.ImGui_BeginTable(ctx, "monitoring_table", 2, reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg())
    reaper.ImGui_TableSetupColumn(ctx, "Piste", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Monitoring à l'arrêt", reaper.ImGui_TableColumnFlags_WidthFixed(), 150)
    reaper.ImGui_TableHeadersRow(ctx)

    -- Parcourir toutes les pistes
    local num_tracks = reaper.CountTracks(0)
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        local _, track_name = reaper.GetTrackName(track)
        
        -- Vérifier si la piste contient un plugin PoulpyLoop
        local has_poulpyloop = false
        local fx_count = reaper.TrackFX_GetCount(track)
        for j = 0, fx_count - 1 do
            local retval, fx_name = reaper.TrackFX_GetFXName(track, j, "")
            if fx_name:find("PoulpyLoop") then
                has_poulpyloop = true
                break
            end
        end

        if has_poulpyloop then
            reaper.ImGui_TableNextRow(ctx)
            
            -- Nom de la piste
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, track_name)

            -- Case à cocher pour le monitoring à l'arrêt
            reaper.ImGui_TableNextColumn(ctx)
            local monitoring_stop = reaper.gmem_read(GMEM.MONITORING_STOP_BASE + i) == 1
            if reaper.ImGui_Checkbox(ctx, "##monitoring_stop_" .. i, monitoring_stop) then
                reaper.gmem_write(GMEM.MONITORING_STOP_BASE + i, monitoring_stop and 0 or 1)
            end
            
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, "Lorsque cette option est activée, le signal d'entrée est routé vers les sorties lorsque la lecture est à l'arrêt.")
            end
        end
    end

    reaper.ImGui_EndTable(ctx)
end

local function DrawTools()
    -- Partie 1: Outils de base
    reaper.ImGui_Text(ctx, "Outils de base :")
    reaper.ImGui_Separator(ctx)
    
    reaper.ImGui_Text(ctx, "Entrée audio pour Looper :")
    drawRecInputCombo()

    if reaper.ImGui_Button(ctx, "Ajouter looper") then
        addLooper()
    end

    reaper.ImGui_Separator(ctx)
    
    if reaper.ImGui_Button(ctx, "Set mono") then
        setLoopsMonoStereo(true)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Set stereo") then
        setLoopsMonoStereo(false)
    end

    reaper.ImGui_Separator(ctx)
    
    -- Partie 2: Importation ALK
    reaper.ImGui_Text(ctx, "Importation ALK :")
    reaper.ImGui_Separator(ctx)
    
    reaper.ImGui_Text(ctx, "Fichier ALK: " .. ((alkData and "(chargé)") or "aucun"))
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Ouvrir .alk") then
        local ret, file = reaper.GetUserFileNameForRead("", "Fichier ALK", "alk")
        if ret then
            local content, err = alk.readFile(file)
            if not content then
                errorMessage = err
            else
                alkData, errorMessage = alk.parseALK(content)
            end
        end
    end

    if alkData and reaper.ImGui_Button(ctx, "Importer le projet ALK") then
        alk.importProject(alkData)
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Préparer pour PoulpyLoopy") then
        core.ProcessMIDINotes()
        reaper.ShowMessageBox("Préparation pour PoulpyLoopy terminée avec succès !", "Opération terminée", 0)
    end

    if errorMessage and #errorMessage > 0 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF0000FF)
        reaper.ImGui_Text(ctx, "Erreur: " .. errorMessage)
        reaper.ImGui_PopStyleColor(ctx)
    end

    reaper.ImGui_Separator(ctx)

    -- Partie 3: Automation du clic
    reaper.ImGui_Text(ctx, "Automation du clic :")
    reaper.ImGui_Separator(ctx)
    
    -- Menu déroulant pour les pistes de type Command
    if alkData then
        local commandTracks = alkData.trackTypes[3].tracks or {}
        local trackLabel = (#commandTracks > 0 and commandTracks[selected_click_track_index + 1].name) or "Aucune piste"
        
        reaper.ImGui_Text(ctx, "Piste d'automation du clic :")
        if reaper.ImGui_BeginCombo(ctx, "##ClickTrack", trackLabel) then
            for i, tr in ipairs(commandTracks) do
                local is_sel = (selected_click_track_index == i - 1)
                if reaper.ImGui_Selectable(ctx, tr.name, is_sel) then
                    selected_click_track_index = i - 1
                end
                if is_sel then
                    reaper.ImGui_SetItemDefaultFocus(ctx)
                end
            end
            reaper.ImGui_EndCombo(ctx)
        end

        -- Bouton pour appliquer l'automation
        if reaper.ImGui_Button(ctx, "Appliquer automation clic") then
            alk.importMetronome(alkData, selected_click_track_index)
        end
    else
        reaper.ImGui_Text(ctx, "Chargez d'abord un fichier ALK pour accéder aux pistes d'automation.")
    end
end

local function DrawStats()
    reaper.ImGui_Text(ctx, "Statistiques des instances de PoulpyLoop :")
    reaper.ImGui_Separator(ctx)
    
    -- En-têtes du tableau
    reaper.ImGui_BeginTable(ctx, "stats_table", 4, reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg())
    reaper.ImGui_TableSetupColumn(ctx, "ID", reaper.ImGui_TableColumnFlags_WidthFixed(), 50)
    reaper.ImGui_TableSetupColumn(ctx, "Mémoire utilisée", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Temps restant", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Notes actives", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableHeadersRow(ctx)
    
    -- Variables pour les statistiques totales
    local total_instances = 0
    local total_memory = 0
    local total_notes = 0
    
    -- Parcourir les 64 instances possibles
    for i = 0, 63 do
        local stats_base = GMEM.STATS_BASE + i * 3
        local memory_used = reaper.gmem_read(stats_base)
        local time_left = reaper.gmem_read(stats_base + 1)
        local notes_count = reaper.gmem_read(stats_base + 2)
        
        -- Afficher uniquement les instances actives (mémoire > 0)
        if memory_used > 0 then
            total_instances = total_instances + 1
            total_memory = total_memory + memory_used
            total_notes = total_notes + notes_count
            
            reaper.ImGui_TableNextRow(ctx)
            
            -- ID de l'instance
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, string.format("%d", i))
            
            -- Mémoire utilisée
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, string.format("%.1f MB", memory_used))
            
            -- Temps restant
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, string.format("%.1f s", time_left))
            
            -- Nombre de notes
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, string.format("%d", notes_count))
        end
    end
    
    reaper.ImGui_EndTable(ctx)
    
    -- Informations supplémentaires
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, string.format("Nombre total d'instances actives : %d", total_instances))
    reaper.ImGui_Text(ctx, string.format("Mémoire totale utilisée : %.1f MB", total_memory))
    reaper.ImGui_Text(ctx, string.format("Total des notes actives : %d", total_notes))
end

local function DrawDebug()
    -- État de lecture actuel
    local play_state = reaper.GetPlayState()
    local is_playing = play_state & 1
    reaper.ImGui_Text(ctx, "État de lecture: ")
    reaper.ImGui_SameLine(ctx)
    if is_playing == 1 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55FF55FF) -- Vert pour LECTURE
        reaper.ImGui_Text(ctx, "LECTURE")
    else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF5555FF) -- Rouge pour ARRÊTÉ
        reaper.ImGui_Text(ctx, "ARRÊTÉ")
    end
    reaper.ImGui_PopStyleColor(ctx)
    
    -- Mode actuel
    reaper.ImGui_Text(ctx, "Mode: ")
    reaper.ImGui_SameLine(ctx)
    if playback_mode then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF5555FF) -- Rouge pour PLAYBACK
        reaper.ImGui_Text(ctx, "PLAYBACK")
    else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55FF55FF) -- Vert pour LIVE
        reaper.ImGui_Text(ctx, "LIVE")
    end
    reaper.ImGui_PopStyleColor(ctx)
    
    -- Boutons d'action
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "Forcer l'analyse des offsets") then
        reaper.gmem_write(GMEM.FORCE_ANALYZE, 1)
        debug_console("Demande d'analyse forcée des offsets envoyée\n")
    end
end

local function DrawTitle()
    -- Obtenir la position de lecture actuelle
    local playPos = 0
    local playState = reaper.GetPlayState()
    
    if playState > 0 then
        -- En lecture, on utilise la position de lecture
        playPos = reaper.GetPlayPosition()
    else
        -- À l'arrêt, on utilise la position du curseur d'édition
        playPos = reaper.GetCursorPosition()
    end
    
    -- Vérifier si la position a changé depuis la dernière frame
    local positionChanged = (playPos ~= last_cursor_pos)
    last_cursor_pos = playPos
    
    -- Variables pour stocker les informations sur le dernier marqueur
    local lastMarkerName = nil
    local lastMarkerPos = -math.huge -- Commencer avec une valeur très négative
    
    -- Récupérer tous les marqueurs et trouver celui juste avant playPos
    local markerCount = reaper.CountProjectMarkers(0)
    for i = 0, markerCount - 1 do
        local retval, isRegion, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if retval and not isRegion then -- On ne veut que les marqueurs, pas les régions
            if pos <= playPos and pos > lastMarkerPos then
                lastMarkerName = name
                lastMarkerPos = pos
            end
        end
    end
    
    -- Centrer le texte horizontalement et verticalement
    local windowWidth = reaper.ImGui_GetWindowWidth(ctx)
    local windowHeight = reaper.ImGui_GetWindowHeight(ctx)
    
    -- Définir la couleur rose clair
    local roseColor = 0xFF21EAFF  -- Rose clair (format ABGR)
    
    -- Afficher le titre
    if lastMarkerName and lastMarkerName ~= "" then
        local uppercaseText = lastMarkerName:upper()
        local textWidth = reaper.ImGui_CalcTextSize(ctx, uppercaseText)
        local textHeight = reaper.ImGui_GetTextLineHeight(ctx)
        
        local centerX = windowWidth * 0.5
        local centerY = windowHeight * 0.5
        
        reaper.ImGui_SetCursorPos(ctx, centerX - textWidth * 0.5, centerY - textHeight * 0.5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), roseColor)
        reaper.ImGui_Text(ctx, uppercaseText)
        reaper.ImGui_PopStyleColor(ctx)
    else
        local text = "AUCUN MARQUEUR"
        local textWidth = reaper.ImGui_CalcTextSize(ctx, text)
        local textHeight = reaper.ImGui_GetTextLineHeight(ctx)
        
        local centerX = windowWidth * 0.5
        local centerY = windowHeight * 0.5
        
        reaper.ImGui_SetCursorPos(ctx, centerX - textWidth * 0.5, centerY - textHeight * 0.5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
        reaper.ImGui_Text(ctx, text)
        reaper.ImGui_PopStyleColor(ctx)
    end
end

--------------------------------------------------------------------------------
-- Fenêtre principale
--------------------------------------------------------------------------------
local function DrawMainWindow()
    -- Charger les valeurs depuis gmem au début de chaque frame
    record_monitor_loops = get_record_monitor_loops_mode()
    playback_mode = get_playback_mode()

    reaper.ImGui_SetNextWindowPos(ctx, 100, 50, reaper.ImGui_Cond_FirstUseEver())
    reaper.ImGui_SetNextWindowSize(ctx, 700, 500, reaper.ImGui_Cond_FirstUseEver())

    local visible, open = reaper.ImGui_Begin(ctx, "PoulpyLoopy v" .. VERSION, true)
    if visible then
        if reaper.ImGui_BeginTabBar(ctx, "MainTabs") then
            -- Onglet "Loop Editor"
            if reaper.ImGui_BeginTabItem(ctx, "Loop Editor") then
                DrawLoopEditor()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Options"
            if reaper.ImGui_BeginTabItem(ctx, "Options") then
                DrawOptions()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Tools"
            if reaper.ImGui_BeginTabItem(ctx, "Tools") then
                DrawTools()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Stats"
            if reaper.ImGui_BeginTabItem(ctx, "Stats") then
                DrawStats()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Debug"
            if reaper.ImGui_BeginTabItem(ctx, "Debug") then
                DrawDebug()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Title"
            if reaper.ImGui_BeginTabItem(ctx, "Title") then
                DrawTitle()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            reaper.ImGui_EndTabBar(ctx)
        end
        
        if reaper.ImGui_Button(ctx, "Fermer la fenêtre") then
            open = false
        end
    end
    
    reaper.ImGui_End(ctx)
    return open
end

-- Exporter les fonctions nécessaires
M.init = init
M.destroyContext = destroyContext
M.ProcessMIDINotes = ProcessMIDINotes
M.setLoopsMonoStereo = setLoopsMonoStereo
M.addLooperBase = addLooperBase
M.addLooper = addLooper
M.UpdateTakeData = UpdateTakeData
M.DrawMainWindow = DrawMainWindow

return M 