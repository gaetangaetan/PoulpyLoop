--[[------------------------------------------------------------------------------
  PoulpyLoopyUI.lua
  Interface utilisateur pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper
local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/"
local core = dofile(script_path .. "PoulpyLoopyCore0.lua")

-- Variables globales
local ctx = nil
local window_width = 400
local window_height = 270
local window_flags = reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_NoCollapse()
local window_title = "PoulpyLoopy v" .. core.VERSION

-- Charger le module Core
local alk = dofile(script_path .. "PoulpyLoopyImportALK.lua")
local core1 = dofile(script_path .. "PoulpyLoopyCore1.lua")  -- Ajout du chargement de core1
local core2 = dofile(script_path .. "PoulpyLoopyCore2.lua")  -- Nouveau module

-- Créer le contexte ImGui au niveau global
local ctx = nil

-- Fonction utilitaire pour supprimer les espaces en début et fin de chaîne
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- Importer les fonctions et constantes du Core dont nous avons besoin
local COLORS = core.COLORS
local LOOP_TYPES = core.LOOP_TYPES
local VERSION = core.VERSION
local GMEM = core.GMEM
local GetTakeMetadata = core1.GetTakeMetadata
local SetTakeMetadata = core1.SetTakeMetadata
local IsLoopNameValid = core1.IsLoopNameValid
local UpdateDependentLoops = core1.UpdateDependentLoops
local ProcessMIDINotes = core1.ProcessMIDINotes
local UnfoldPlayLoop = core1.UnfoldPlayLoop
local get_record_monitor_loops_mode = core1.get_record_monitor_loops_mode
local get_playback_mode = core1.get_playback_mode
local save_record_monitor_loops_mode = core1.save_record_monitor_loops_mode
local save_playback_mode = core1.save_playback_mode
local addLooper = core1.addLooper
local setLoopsMonoStereo = core1.setLoopsMonoStereo
local parseALK = core1.parseALK
local importProject = core1.importProject
local importMetronome = core1.importMetronome
local debug_console = core1.debug_console
local ApplyMIDIChanges = core1.ApplyMIDIChanges
local update_jsfx_constants = core.update_jsfx_constants  -- Ajout de l'import

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
local progress_message = ""
local processing_items = {}
local show_modulation = false
local render_realtime = true  -- true = realtime (idle), false = full speed
local TOOLS_TAB_HEIGHT = 460  -- Hauteur par défaut pour l'onglet Tools
local current_tab = "Loop Editor"  -- Onglet actuellement affiché

-- Nouveaux paramètres de modulation
local modulation_params = {
    { name = "Mod 1", start_value = 0, end_value = 0, start_cc = 21, end_cc = 22 },
    { name = "Mod 2", start_value = 0, end_value = 0, start_cc = 23, end_cc = 24 },
    { name = "Mod 3", start_value = 0, end_value = 0, start_cc = 25, end_cc = 26 },
    { name = "Mod 4", start_value = 0, end_value = 0, start_cc = 27, end_cc = 28 },
    { name = "Mod 5", start_value = 0, end_value = 0, start_cc = 29, end_cc = 30 },
    { name = "Mod 6", start_value = 0, end_value = 0, start_cc = 31, end_cc = 32 },
    { name = "Mod 7", start_value = 0, end_value = 0, start_cc = 33, end_cc = 34 },
    { name = "Mod 8", start_value = 0, end_value = 0, start_cc = 35, end_cc = 36 },
    { name = "Mod 9", start_value = 0, end_value = 0, start_cc = 37, end_cc = 38 },
    { name = "Mod 10", start_value = 0, end_value = 0, start_cc = 39, end_cc = 40 }
}

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

-- Préparation des variables pour les sélections multiples
local midi_data = nil  -- Pour stocker les données MIDI entre les appels

-- Constantes pour la communication via gmem
local GMEM_UI_COMMAND = 29000      -- Commande de l'UI (0=normal, 1=sauvegarde, 2=chargement)
local GMEM_INSTANCE_ID = 29001     -- ID de l'instance sollicitée
local GMEM_DATA_LENGTH = 29002     -- Longueur des données
local GMEM_WRITING_RIGHT = 29003   -- Qui a le droit d'écrire (0=PoulpyLoopy, 1=PoulpyLoop)
local GMEM_TOTAL_LENGTH = 29004    -- Taille totale des données
local GMEM_SAVE_COMPLETE = 29005    -- Signal de fin de sauvegarde
local GMEM_DEBUG_CODE = 29006      -- Code de débogage
local GMEM_DEBUG_VALUE = 29007     -- Valeur associée au code de débogage
local GMEM_DATA_START = 30000      -- Début de la mémoire de données
local GMEM_DATA_END = 59999        -- Fin de la mémoire de données
local GMEM_LOG_START = 29008      -- Début du journal
local GMEM_LOG_LENGTH = 29009     -- Nombre d'entrées dans le journal
local GMEM_LOG_DATA = 29010       -- Début des données du journal

-- Constantes pour les codes de débogage
local DEBUG_NONE = 0              -- Pas de message
local DEBUG_FIND_NOTE_START = 1   -- Début de recherche de note
local DEBUG_FIND_NOTE_FOUND = 2   -- Note trouvée
local DEBUG_FIND_NOTE_NONE = 3    -- Aucune note trouvée
local DEBUG_SAVE_START = 4        -- Début de sauvegarde
local DEBUG_SAVE_NO_DATA = 5      -- Rien à sauvegarder
local DEBUG_SAVE_NOTE_START = 6   -- Début sauvegarde d'une note
local DEBUG_SAVE_NOTE_DATA = 7    -- Envoi données d'une note
local DEBUG_SAVE_NOTE_END = 8     -- Fin sauvegarde d'une note

-- Types de messages du journal
local LOG_NOTE_LENGTH = 1     -- Longueur d'une note (value1=note_id, value2=length)
local LOG_NOTE_FOUND = 2      -- Note trouvée (value1=note_id, value2=data_size)
local LOG_TOTAL_SIZE = 3      -- Taille totale calculée (value1=size, value2=0)
local LOG_SEARCH_START = 4    -- Début de recherche (value1=start_from, value2=0)
local LOG_NO_NOTE = 5         -- Aucune note trouvée (value1=0, value2=0)
local LOG_STATE = 6           -- Changement d'état (value1=old_state, value2=new_state)

-- Fonction pour interpréter un message de débogage
local function interpret_debug_message(code, value)
    if code == DEBUG_NONE then return end
    
    local message = "  DEBUG: "
    if code == DEBUG_FIND_NOTE_START then
        message = message .. "Recherche de note à partir de " .. value
    elseif code == DEBUG_FIND_NOTE_FOUND then
        message = message .. "Note trouvée: " .. value
    elseif code == DEBUG_FIND_NOTE_NONE then
        message = message .. "Aucune note trouvée"
    elseif code == DEBUG_SAVE_START then
        message = message .. "Début de la sauvegarde"
    elseif code == DEBUG_SAVE_NO_DATA then
        message = message .. "Aucune donnée à sauvegarder"
    elseif code == DEBUG_SAVE_NOTE_START then
        message = message .. "Début sauvegarde note " .. value
    elseif code == DEBUG_SAVE_NOTE_DATA then
        message = message .. "Envoi " .. value .. " échantillons"
    elseif code == DEBUG_SAVE_NOTE_END then
        message = message .. "Fin sauvegarde note " .. value
    else
        message = message .. "Code inconnu: " .. code .. " (valeur: " .. value .. ")"
    end
    
    reaper.ShowConsoleMsg(message .. "\n")
end

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
local function ProcessMIDINotes(track, return_data)
    local noteCounters = {}
    local recordLoopPitches = {}
    local allTakes = {}

    -- Récupérer tous les items MIDI d'une piste ou de toutes les pistes
    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks - 1 do
        local current_track = reaper.GetTrack(0, t)
        -- Si un filtre de piste est spécifié, ignorer les autres pistes
        if not track or current_track == track then
            local item_count = reaper.CountTrackMediaItems(current_track)
            for i = 0, item_count - 1 do
                local item = reaper.GetTrackMediaItem(current_track, i)
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
                                    track = current_track
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    -- Tri par piste/position temporelle
    table.sort(allTakes, function(a, b)
        local trackA_id = reaper.GetMediaTrackInfo_Value(a.track, "IP_TRACKNUMBER")
        local trackB_id = reaper.GetMediaTrackInfo_Value(b.track, "IP_TRACKNUMBER")
        if trackA_id == trackB_id then
            return a.start_time < b.start_time
        else
            return trackA_id < trackB_id
        end
    end)

    -- Traitement des items
    for _, entry in ipairs(allTakes) do
        local take = entry.take
        local item = entry.item
        local loop_type = entry.loop_type
        local track_id = reaper.GetMediaTrackInfo_Value(entry.track, "IP_TRACKNUMBER")
        
        if not noteCounters[track_id] then
            noteCounters[track_id] = 1  -- Démarrer à 1
            recordLoopPitches[track_id] = {}
        end

        if loop_type == "UNUSED" then goto continue end

        reaper.MIDI_SetAllEvts(take, "")
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_start + item_length
        local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_start)
        local end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_end)

        if loop_type == "RECORD" then
            local pitch = noteCounters[track_id]
            noteCounters[track_id] = noteCounters[track_id] + 1
            local loop_name = GetTakeMetadata(take, "loop_name") or ""
            recordLoopPitches[track_id][loop_name] = pitch
            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, pitch, 1, false)
        
        elseif loop_type == "PLAY" then
            local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
            local ref_name = reference_loop:match("%d%d%s+(.*)")
            local refNote = 0
            
            if recordLoopPitches[track_id][reference_loop] then
                refNote = recordLoopPitches[track_id][reference_loop]
            elseif ref_name and recordLoopPitches[track_id][ref_name] then
                refNote = recordLoopPitches[track_id][ref_name]
            else
                for name, pitch in pairs(recordLoopPitches[track_id]) do
                    local name_without_prefix = name:match("%d%d%s+(.*)")
                    if name_without_prefix and name_without_prefix == ref_name then
                        refNote = pitch
                        break
                    end
                end
            end
            
            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, refNote, 2, false)
        
        elseif loop_type == "OVERDUB" then
            -- Même logique que pour PLAY
            local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
            local ref_name = reference_loop:match("%d%d%s+(.*)")
            local refNote = 0
            
            if recordLoopPitches[track_id][reference_loop] then
                refNote = recordLoopPitches[track_id][reference_loop]
            elseif ref_name and recordLoopPitches[track_id][ref_name] then
                refNote = recordLoopPitches[track_id][ref_name]
            else
                for name, pitch in pairs(recordLoopPitches[track_id]) do
                    local name_without_prefix = name:match("%d%d%s+(.*)")
                    if name_without_prefix and name_without_prefix == ref_name then
                        refNote = pitch
                        break
                    end
                end
            end
            
            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, refNote, 3, false)
        
        elseif loop_type == "MONITOR" then
            local pitch = noteCounters[track_id]
            noteCounters[track_id] = noteCounters[track_id] + 1
            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, pitch, 4, false)
        end

        -- Insertion des CC MIDI pour les paramètres de modulation
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
            
            -- Ajouter les CC pour la durée du bloc si c'est un bloc RECORD ou MONITOR
            if loop_type == "RECORD" or loop_type == "MONITOR" then
                local block_length = math.floor(item_length * 10) -- Convertir en dixièmes de secondes
                local cc19_val = math.floor(block_length / 128)
                local cc20_val = block_length % 128
                reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 19, cc19_val, false)
                reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 20, cc20_val, false)
            end
            
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 7, cc07, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 8, cc08, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 10, cc10, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 9, cc09, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 11, monitoring_val, false)
            
            -- Insérer les CC MIDI pour les paramètres de modulation
            for i, param in ipairs(modulation_params) do
                local start_value = tonumber(GetTakeMetadata(take, "mod_" .. i .. "_start")) or 0
                local end_value = tonumber(GetTakeMetadata(take, "mod_" .. i .. "_end")) or 0
                reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, param.start_cc, start_value, false)
                reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, param.end_cc, end_value, false)
            end
        end

        reaper.MIDI_Sort(take)
        ::continue::
    end

    if return_data then
        return {
            noteCounters = noteCounters,
            recordLoopPitches = recordLoopPitches
        }
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
        
        -- Charger les valeurs des paramètres de modulation
        for i, param in ipairs(modulation_params) do
            local start_value = tonumber(GetTakeMetadata(take, "mod_" .. i .. "_start")) or 0
            local end_value = tonumber(GetTakeMetadata(take, "mod_" .. i .. "_end")) or 0
            param.start_value = start_value
            param.end_value = end_value
        end
        
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
    -- Restaurer la largeur de la fenêtre
    local saved_width = reaper.GetExtState("PoulpyLoopy", "window_width")
    if saved_width ~= "" then
        window_width = tonumber(saved_width)
    end
    
    -- Créer le contexte ImGui s'il n'existe pas déjà
    if not ctx then
        ctx = reaper.ImGui_CreateContext('PoulpyLoopy')
    end
    
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
    local is_midi = take and reaper.TakeIsMIDI(take)
    
    -- N'afficher l'éditeur que si on a un item MIDI
    if is_midi then
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

        -- Afficher le nombre d'éléments sélectionnés
        local selected_items = {}
        local num_tracks = reaper.CountTracks(0)
        local selected_track = nil
        local all_same_track = true
        
        for t = 0, num_tracks - 1 do
            local track = reaper.GetTrack(0, t)
            local item_count = reaper.CountTrackMediaItems(track)
            for i = 0, item_count - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                if reaper.IsMediaItemSelected(item) then
                    local take = reaper.GetActiveTake(item)
                    if take and reaper.TakeIsMIDI(take) then
                        table.insert(selected_items, {item = item, take = take, track = track})
                        if not selected_track then
                            selected_track = track
                        elseif selected_track ~= track then
                            all_same_track = false
                        end
                    end
                end
            end
        end
        
        reaper.ImGui_Text(ctx, string.format("Éléments sélectionnés : %d", #selected_items))
        if #selected_items > 1 and not all_same_track then
            reaper.ImGui_TextColored(ctx, 0xFF0000FF, "Attention : Tous les blocs sélectionnés doivent être sur la même piste!")
        end

        -- Type de Loop
        local loop_type = loop_types[selected_loop_type_index + 1]
        if reaper.ImGui_BeginCombo(ctx, "Type", loop_type) then
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
            local changed, new_name = reaper.ImGui_InputText(ctx, "Nom", loop_name, 256)
            if changed then loop_name = trim(new_name) end

            if reaper.ImGui_RadioButton(ctx, "Mono", is_mono) then is_mono = true end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Stéréo", not is_mono) then is_mono = false end

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Pan", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Vol (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            if reaper.ImGui_Checkbox(ctx, "Monitoring", monitoring == 1) then
                monitoring = (monitoring == 1) and 0 or 1
            end

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
            
            if reaper.ImGui_BeginCombo(ctx, "Réf", prev_loops[sel_idx] or "(Aucun)") then
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

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Pan", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Vol (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            -- Pour le type PLAY, monitoring OFF par défaut
            if loop_type == "PLAY" and not reference_loop then
                monitoring = 0
            end

            if reaper.ImGui_Checkbox(ctx, "Monitoring", monitoring == 1) then
                monitoring = (monitoring == 1) and 0 or 1
            end

            if loop_type == "PLAY" then
                local pitch_changed, new_pitch = reaper.ImGui_SliderInt(ctx, "Pitch", pitch, -24, 24)
                if pitch_changed then pitch = new_pitch end
            end

        elseif loop_type == "MONITOR" then
            if reaper.ImGui_RadioButton(ctx, "Mono", is_mono) then is_mono = true end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Stéréo", not is_mono) then is_mono = false end

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Pan", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Vol (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            monitoring = 1  -- Toujours ON pour MONITOR
            if reaper.ImGui_Checkbox(ctx, "Monitoring", true) then
                monitoring = 0
            end

        elseif loop_type == "UNUSED" then
            reaper.ImGui_Text(ctx, "Ce clip est marqué comme UNUSED.")
        end

        -- Nouveaux faders de modulation
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Afficher la modulation") then
            show_modulation = not show_modulation
        end
        
        if show_modulation then
            -- Afficher les paramètres de modulation en une seule colonne
            for i, param in ipairs(modulation_params) do
                reaper.ImGui_Text(ctx, param.name)
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushItemWidth(ctx, 60)  -- Largeur fixe pour les DragInt
                local changed_start, new_start = reaper.ImGui_DragInt(ctx, "Début##" .. i, param.start_value, 1, 0, 127, "%d")
                if changed_start then param.start_value = new_start end
                reaper.ImGui_PopItemWidth(ctx)
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushItemWidth(ctx, 60)  -- Largeur fixe pour les DragInt
                local changed_end, new_end = reaper.ImGui_DragInt(ctx, "Fin##" .. i, param.end_value, 1, 0, 127, "%d")
                if changed_end then param.end_value = new_end end
                reaper.ImGui_PopItemWidth(ctx)
            end
        end

        -- Bouton Appliquer
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x127349FF )  -- Vert
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x1AA368FF)  -- Vert plus clair pour le hover
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xF7E47EFF)  -- Vert encore plus clair pour le clic
        
        if reaper.ImGui_Button(ctx, "Appliquer") then
            if #selected_items > 1 and not all_same_track then
                reaper.ShowMessageBox("Tous les blocs sélectionnés doivent être sur la même piste.", "Erreur", 0)
                reaper.ImGui_PopStyleColor(ctx, 3)  -- Restaurer les couleurs avant de retourner
                return
            end

            -- Si plusieurs items sont sélectionnés
            if #selected_items > 1 then
                -- Vérifier que tous les items sont du même type
                local first_type = GetTakeMetadata(selected_items[1].take, "loop_type")
                local all_same_type = true
                local all_valid_type = (first_type == "PLAY" or first_type == "MONITOR")

                for i = 2, #selected_items do
                    local item_type = GetTakeMetadata(selected_items[i].take, "loop_type")
                    if item_type ~= first_type then
                        all_same_type = false
                        break
                    end
                    if item_type ~= "PLAY" and item_type ~= "MONITOR" then
                        all_valid_type = false
                        break
                    end
                end

                if not all_same_type then
                    reaper.ShowMessageBox("Les items sélectionnés doivent être du même type.", "Erreur", 0)
                    reaper.ImGui_PopStyleColor(ctx, 3)  -- Restaurer les couleurs avant de retourner
                    return
                end

                if not all_valid_type then
                    reaper.ShowMessageBox("La modification en masse n'est autorisée que pour les types PLAY et MONITOR.", "Erreur", 0)
                    reaper.ImGui_PopStyleColor(ctx, 3)  -- Restaurer les couleurs avant de retourner
                    return
                end

                -- Appliquer les modifications à tous les items sélectionnés
                processing_items = selected_items  -- Stocker les items à traiter
                local current_item_index = 1
                
                local function processNextItem()
                    if current_item_index <= #processing_items then
                        local item_data = processing_items[current_item_index]
                        local item = item_data.item
                        local take = item_data.take
                        local item_type = GetTakeMetadata(take, "loop_type")

                        -- Mettre à jour le message de progression
                        progress_message = string.format("Traitement en cours... (%d/%d)", current_item_index, #processing_items)
                        
                        if item_type == "PLAY" then
                            SetTakeMetadata(take, "loop_type", item_type)
                            SetTakeMetadata(take, "reference_loop", reference_loop)
                            SetTakeMetadata(take, "pan", tostring(pan))
                            SetTakeMetadata(take, "volume_db", tostring(volume_db))
                            SetTakeMetadata(take, "pitch", tostring(pitch))
                            SetTakeMetadata(take, "monitoring", tostring(monitoring))
                            -- Sauvegarder les valeurs des paramètres de modulation
                            for i, param in ipairs(modulation_params) do
                                SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                                SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
                            end
                            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                            reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.PLAY)
                            
                            -- Pour le premier élément, obtenir les données MIDI
                            if current_item_index == 1 then
                                midi_data = ProcessMIDINotes(item_data.track, true)
                            else
                                -- Pour les éléments suivants, appliquer directement les modifications
                                ApplyMIDIChanges(take, item, midi_data)
                            end
                            
                            UnfoldPlayLoop(take)
                        elseif item_type == "MONITOR" then
                            SetTakeMetadata(take, "loop_type", item_type)
                            SetTakeMetadata(take, "pan", tostring(pan))
                            SetTakeMetadata(take, "volume_db", tostring(volume_db))
                            SetTakeMetadata(take, "is_mono", tostring(is_mono))
                            SetTakeMetadata(take, "monitoring", "1")  -- Toujours ON
                            -- Sauvegarder les valeurs des paramètres de modulation
                            for i, param in ipairs(modulation_params) do
                                SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                                SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
                            end
                            reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.MONITOR)
                            
                            -- Pour le premier élément, obtenir les données MIDI
                            if current_item_index == 1 then
                                midi_data = ProcessMIDINotes(item_data.track, true)
                            else
                                -- Pour les éléments suivants, appliquer directement les modifications
                                ApplyMIDIChanges(take, item, midi_data)
                            end
                        end

                        current_item_index = current_item_index + 1
                        reaper.defer(processNextItem)
                    else
                        -- Traitement terminé - effacer le message et la liste
                        progress_message = ""
                        processing_items = {}
                        midi_data = nil  -- Libérer les données MIDI
                    end
                end

                -- Démarrer le traitement
                reaper.defer(processNextItem)
                reaper.ImGui_PopStyleColor(ctx, 3)  -- Restaurer les couleurs avant de retourner
                return
            end

            -- Code existant pour un seul item
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
                    -- Sauvegarder les valeurs des paramètres de modulation
                    for i, param in ipairs(modulation_params) do
                        SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                        SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
                    end
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", loop_name, true)
                    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.RECORD)
                    if old_name ~= "" and old_name ~= loop_name then
                        UpdateDependentLoops(take, old_name, loop_name)
                    end
                    local track = reaper.GetMediaItemTake_Track(take)
                    ProcessMIDINotes(track)
                end

            elseif loop_type == "OVERDUB" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "reference_loop", reference_loop)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "is_mono", tostring(is_mono))
                SetTakeMetadata(take, "monitoring", tostring(monitoring))
                -- Sauvegarder les valeurs des paramètres de modulation
                for i, param in ipairs(modulation_params) do
                    SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                    SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
                end
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.OVERDUB)
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)

            elseif loop_type == "PLAY" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "reference_loop", reference_loop)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "pitch", tostring(pitch))
                SetTakeMetadata(take, "monitoring", tostring(monitoring))
                -- Sauvegarder les valeurs des paramètres de modulation
                for i, param in ipairs(modulation_params) do
                    SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                    SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
                end
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.PLAY)
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)
                UnfoldPlayLoop(take)

            elseif loop_type == "MONITOR" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "is_mono", tostring(is_mono))
                SetTakeMetadata(take, "monitoring", "1")  -- Toujours ON
                -- Sauvegarder les valeurs des paramètres de modulation
                for i, param in ipairs(modulation_params) do
                    SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                    SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
                end
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.MONITOR)
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)

            elseif loop_type == "UNUSED" then
                SetTakeMetadata(take, "loop_type", "UNUSED")
                SetTakeMetadata(take, "reference_loop", "")
                SetTakeMetadata(take, "pan", "0")
                SetTakeMetadata(take, "volume_db", "0")
                SetTakeMetadata(take, "pitch", "0")
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "(Unused)", true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.UNUSED)
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)
            end
        end
        reaper.ImGui_PopStyleColor(ctx, 3)  -- Restaurer les couleurs

        -- Bouton "Insérer clic" à droite du bouton "Appliquer"
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xAB47BCFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00AA40FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x008000FF)
        
        if reaper.ImGui_Button(ctx, "Insérer clic") then
            if item and take and is_midi then
                -- Set loop points to items
                reaper.Main_OnCommand(41039, 0)
                
                -- Supprimer l'item MIDI qui a servi à définir les points de loop
                local track = reaper.GetMediaItem_Track(item)
                reaper.DeleteTrackMediaItem(track, item)
                
                -- Insert click source
                reaper.Main_OnCommand(40013, 0)
                
                -- Colorer le nouvel item de clic
                local new_item = reaper.GetSelectedMediaItem(0, 0)
                if new_item then
                    reaper.SetMediaItemInfo_Value(new_item, "I_CUSTOMCOLOR", COLORS.CLICK)
                end
                
                -- Forcer la mise à jour des variables
                item = nil
                take = nil
                is_midi = false
            end
        end
        
        reaper.ImGui_PopStyleColor(ctx, 3)

        -- Afficher le message de progression s'il existe
        if progress_message ~= "" then
            reaper.ImGui_Text(ctx, progress_message)
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

    -- Tableau pour stocker les pistes avec PoulpyLoop et leurs indices de monitoring
    local poulpy_tracks = {}
    local num_tracks = reaper.CountTracks(0)
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        local fx_count = reaper.TrackFX_GetCount(track)
        local has_poulpyloop = false
        
        -- Vérifier si la piste contient un plugin PoulpyLoop
        for j = 0, fx_count - 1 do
            local retval, fx_name = reaper.TrackFX_GetFXName(track, j, "")
            if fx_name:find("PoulpyLoop") then
                has_poulpyloop = true
                break
            end
        end

        if has_poulpyloop then
            table.insert(poulpy_tracks, {
                track = track,
                track_index = i,
                monitoring_index = #poulpy_tracks  -- Index séquentiel pour le monitoring
            })
        end
    end

    -- Tableau pour afficher les pistes avec PoulpyLoop
    reaper.ImGui_BeginTable(ctx, "monitoring_table", 2, reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg())
    reaper.ImGui_TableSetupColumn(ctx, "Piste", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Monitoring à l'arrêt", reaper.ImGui_TableColumnFlags_WidthFixed(), 150)
    reaper.ImGui_TableHeadersRow(ctx)

    -- Afficher uniquement les pistes avec PoulpyLoop
    for _, track_info in ipairs(poulpy_tracks) do
        reaper.ImGui_TableNextRow(ctx)
        
        -- Nom de la piste
        reaper.ImGui_TableNextColumn(ctx)
        local _, track_name = reaper.GetTrackName(track_info.track)
        reaper.ImGui_Text(ctx, track_name)

        -- Case à cocher pour le monitoring à l'arrêt
        reaper.ImGui_TableNextColumn(ctx)
        local monitoring_stop = reaper.gmem_read(GMEM.MONITORING_STOP_BASE + track_info.monitoring_index) == 1
        if reaper.ImGui_Checkbox(ctx, "##monitoring_stop_" .. track_info.track_index, monitoring_stop) then
            -- Mettre à jour slider3 pour toutes les instances de PoulpyLoop sur cette piste
            local fx_count = reaper.TrackFX_GetCount(track_info.track)
            for j = 0, fx_count - 1 do
                local retval, fx_name = reaper.TrackFX_GetFXName(track_info.track, j, "")
                if fx_name:find("PoulpyLoop") then
                    -- Au lieu d'écrire directement dans gmem, on va modifier le paramètre du plugin
                    -- qui s'occupera lui-même de mettre à jour gmem
                    local new_value = monitoring_stop and 0 or 1
                    reaper.TrackFX_SetParam(track_info.track, j, 2, new_value) -- slider3 est le paramètre d'index 2
                end
            end
        end
        
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Lorsque cette option est activée, le signal d'entrée est routé vers les sorties lorsque la lecture est à l'arrêt.")
        end
    end

    reaper.ImGui_EndTable(ctx)
end

local function RenderSelection()
    -- Vérifier qu'il y a au moins un item sélectionné
    local sel_count = reaper.CountSelectedMediaItems(0)
    if sel_count == 0 then
        reaper.ShowMessageBox("Aucun bloc sélectionné.", "Erreur", 0)
        return
    end
    
    -- Sauvegarder le mode actuel et passer en PLAYBACK si nécessaire
    local was_live_mode = not get_playback_mode()
    if was_live_mode then
        save_playback_mode(true)  -- Passer en mode PLAYBACK
    end
    
    -- Trouver les bornes de la sélection et collecter les pistes
    local min_pos = math.huge
    local max_pos = 0
    local tracks_to_render = {}  -- Table pour stocker {track = track, name = name}
    
    for i = 0, sel_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        
        -- Mettre à jour les bornes globales
        min_pos = math.min(min_pos, item_pos)
        max_pos = math.max(max_pos, item_end)
        
        -- Récupérer la piste et ses infos
        local track = reaper.GetMediaItem_Track(item)
        local track_found = false
        for _, t in ipairs(tracks_to_render) do
            if t.track == track then
                track_found = true
                break
            end
        end
        
        if not track_found then
            -- Récupérer le nom de la piste
            local _, track_name = reaper.GetTrackName(track)
            
            -- Récupérer le nom du bloc pour le nom de fichier
            local take = reaper.GetActiveTake(item)
            local block_name = ""
            if take and reaper.TakeIsMIDI(take) then
                local loop_type = GetTakeMetadata(take, "loop_type") or ""
                if loop_type == "RECORD" then
                    block_name = GetTakeMetadata(take, "loop_name") or ""
                elseif loop_type == "PLAY" or loop_type == "OVERDUB" then
                    block_name = GetTakeMetadata(take, "reference_loop") or ""
                end
            end
            
            -- Ajouter la piste à la liste
            table.insert(tracks_to_render, {
                track = track,
                track_name = track_name,
                block_name = block_name
            })
        end
    end
    
    -- Vérifier que nous avons des bornes valides
    if min_pos == math.huge or max_pos <= min_pos then
        reaper.ShowMessageBox("Impossible de déterminer les bornes de la sélection.", "Erreur", 0)
        return
    end
    
    -- Définir la sélection temporelle
    reaper.GetSet_LoopTimeRange(true, false, min_pos, max_pos, false)
    
    -- Créer le dossier Media s'il n'existe pas
    local media_path = reaper.GetProjectPath() .. "/Media"
    if not reaper.file_exists(media_path) then
        reaper.RecursiveCreateDirectory(media_path, 0)
    end
    
    -- Sauvegarder la sélection de pistes actuelle
    local saved_tracks = {}
    local num_tracks = reaper.CountTracks(0)
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if reaper.IsTrackSelected(track) then
            table.insert(saved_tracks, track)
            reaper.SetTrackSelected(track, false)
        end
    end
    
    -- Pour chaque piste à rendre
    for _, track_info in ipairs(tracks_to_render) do
        -- Créer le nom de fichier
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local base_name = track_info.block_name ~= "" and track_info.block_name or track_info.track_name
        local file_name = base_name .. "_" .. timestamp
        
        -- Sélectionner uniquement cette piste
        reaper.SetTrackSelected(track_info.track, true)
        
        -- Configurer le rendu
        reaper.PreventUIRefresh(1)
        
        -- Configurer les paramètres de rendu
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", file_name, true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATH", media_path, true)
        
        -- Paramètres de rendu
        reaper.SNM_SetIntConfigVar("projrenderstems", 3)     -- 3 = stems (selected tracks)
        reaper.SNM_SetIntConfigVar("workrender", 8192)       -- zone de rendu8192 = time selection
        reaper.SNM_SetIntConfigVar("projrendersrate", 2)     -- 2 = stereo (attention: nom trompeur!)
        reaper.SNM_SetIntConfigVar("projrendernch", 0)       -- 0 = project sample rate (attention: nom trompeur!)
        reaper.SNM_SetIntConfigVar("projrenderlimit", render_realtime and 4 or 0)  -- 4 = offline render (idle), 0 = full speed
        reaper.SNM_SetIntConfigVar("renderclosewhendone", 1) -- 1 = close when done
        reaper.SNM_SetIntConfigVar("renderaddtoproj", 1)     -- 1 = add rendered items to project
        
        -- Options supplémentaires pour assurer un bon rendu
        reaper.SNM_SetIntConfigVar("projrenderrateinternal", 1) -- 1 = use project sample rate for mixing
        reaper.SNM_SetIntConfigVar("projrenderresample", 4)     -- 4 = better quality (384pt Sinc)
        --reaper.SNM_SetIntConfigVar("rendercfg", 2002876005)     -- WAV
                
        reaper.PreventUIRefresh(-1)


        -- Lancer le rendu
        --reaper.Main_OnCommand(41824, 0) -- Render project, using the most recent render settings
        reaper.Main_OnCommand(42230, 0) -- Render project, 
        
        -- Désélectionner la piste
        reaper.SetTrackSelected(track_info.track, false)
    end
    
    -- Restaurer la sélection de pistes originale
    for _, track in ipairs(saved_tracks) do
        reaper.SetTrackSelected(track, true)
    end
    
    -- Revenir en mode LIVE si nécessaire
    if was_live_mode then
        save_playback_mode(false)  -- Retour en mode LIVE
    end
end

-- Fonction pour mettre à jour un bloc
local function UpdateBlock(take)
    -- Sauvegarder la sélection actuelle
    local old_sel_items = {}
    for s = 0, reaper.CountSelectedMediaItems(0) - 1 do
        old_sel_items[s+1] = reaper.GetSelectedMediaItem(0, s)
    end
    
    -- Désélectionner tous les items
    for _, sel_item in ipairs(old_sel_items) do
        reaper.SetMediaItemSelected(sel_item, false)
    end
    
    -- Sélectionner l'item à mettre à jour
    local item = reaper.GetMediaItemTake_Item(take)
    reaper.SetMediaItemSelected(item, true)
    
    -- Forcer une mise à jour des données
    UpdateTakeData(take)
    
    -- Simuler un clic sur le bouton Appliquer
    if current_take then
        local loop_type = GetTakeMetadata(take, "loop_type")
        if loop_type == "RECORD" then
            local valid, message = IsLoopNameValid(take, loop_name)
            if valid then
                local old_name = GetTakeMetadata(take, "loop_name") or ""
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "loop_name", loop_name)
                SetTakeMetadata(take, "is_mono", tostring(is_mono))
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "monitoring", tostring(monitoring))
                for i, param in ipairs(modulation_params) do
                    SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                    SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
                end
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", loop_name, true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.RECORD)
                if old_name ~= "" and old_name ~= loop_name then
                    UpdateDependentLoops(take, old_name, loop_name)
                end
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)
            end
        elseif loop_type == "PLAY" then
            SetTakeMetadata(take, "loop_type", loop_type)
            SetTakeMetadata(take, "reference_loop", reference_loop)
            SetTakeMetadata(take, "pan", tostring(pan))
            SetTakeMetadata(take, "volume_db", tostring(volume_db))
            SetTakeMetadata(take, "pitch", tostring(pitch))
            SetTakeMetadata(take, "monitoring", tostring(monitoring))
            for i, param in ipairs(modulation_params) do
                SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
            end
            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
            reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.PLAY)
        elseif loop_type == "OVERDUB" then
            SetTakeMetadata(take, "loop_type", loop_type)
            SetTakeMetadata(take, "reference_loop", reference_loop)
            SetTakeMetadata(take, "pan", tostring(pan))
            SetTakeMetadata(take, "volume_db", tostring(volume_db))
            SetTakeMetadata(take, "is_mono", tostring(is_mono))
            SetTakeMetadata(take, "monitoring", tostring(monitoring))
            for i, param in ipairs(modulation_params) do
                SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
            end
            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
            reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.OVERDUB)
        elseif loop_type == "MONITOR" then
            SetTakeMetadata(take, "loop_type", loop_type)
            SetTakeMetadata(take, "pan", tostring(pan))
            SetTakeMetadata(take, "volume_db", tostring(volume_db))
            SetTakeMetadata(take, "is_mono", tostring(is_mono))
            SetTakeMetadata(take, "monitoring", "1")
            for i, param in ipairs(modulation_params) do
                SetTakeMetadata(take, "mod_" .. i .. "_start", tostring(param.start_value))
                SetTakeMetadata(take, "mod_" .. i .. "_end", tostring(param.end_value))
            end
            reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.MONITOR)
        end
    end
    
    -- Restaurer la sélection originale
    reaper.SetMediaItemSelected(item, false)
    for _, sel_item in ipairs(old_sel_items) do
        reaper.SetMediaItemSelected(sel_item, true)
    end
end

-- Fonction pour mettre à jour tous les blocs du projet
local function UpdateAllBlocks()
    -- Sauvegarder la sélection actuelle
    local old_sel_items = {}
    for s = 0, reaper.CountSelectedMediaItems(0) - 1 do
        old_sel_items[s+1] = reaper.GetSelectedMediaItem(0, s)
    end
    
    -- Tableau pour stocker tous les blocs à traiter
    local blocks_to_process = {}
    
    -- Compter et collecter tous les blocs à traiter
    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, t)
        local fx_count = reaper.TrackFX_GetCount(track)
        local has_poulpy_loop = false
        
        -- Vérifier si la piste contient PoulpyLoop
        for j = 0, fx_count - 1 do
            local retval, fx_name = reaper.TrackFX_GetFXName(track, j, "")
            if fx_name:find("PoulpyLoop") then
                has_poulpy_loop = true
                break
            end
        end
        
        if has_poulpy_loop then
            local item_count = reaper.CountTrackMediaItems(track)
            for i = 0, item_count - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                local take = reaper.GetActiveTake(item)
                if take and reaper.TakeIsMIDI(take) and GetTakeMetadata(take, "loop_type") then
                    table.insert(blocks_to_process, {
                        take = take,
                        item = item,
                        track = track
                    })
                end
            end
        end
    end
    
    -- Si aucun bloc à traiter, on s'arrête
    if #blocks_to_process == 0 then
        reaper.ShowMessageBox("Aucun bloc à mettre à jour.", "Information", 0)
        return
    end
    
    -- Variables pour le suivi de la progression
    local total_blocks = #blocks_to_process
    local processed_blocks = 0
    
    -- Fonction pour traiter le prochain bloc
    local function ProcessNextBlock()
        if processed_blocks >= total_blocks then
            -- Traitement terminé
            progress_message = "Mise à jour terminée!"
            -- Restaurer la sélection originale
            for _, sel_item in ipairs(old_sel_items) do
                reaper.SetMediaItemSelected(sel_item, true)
            end
            return
        end
        
        -- Traiter le bloc actuel
        local block = blocks_to_process[processed_blocks + 1]
        UpdateBlock(block.take)
        
        -- Mettre à jour le compteur et le message
        processed_blocks = processed_blocks + 1
        progress_message = string.format("Mise à jour des blocs... (%d/%d)", processed_blocks, total_blocks)
        
        -- Programmer le traitement du prochain bloc
        reaper.defer(ProcessNextBlock)
    end
    
    -- Démarrer le traitement
    progress_message = "Démarrage de la mise à jour..."
    ProcessNextBlock()
end

local function DrawTools()
    -- Forcer la hauteur de la fenêtre à TOOLS_TAB_HEIGHT
    reaper.ImGui_SetNextWindowSize(ctx, window_width, TOOLS_TAB_HEIGHT, reaper.ImGui_Cond_Appearing())
    
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
    
    -- Partie 2: Rendu audio
    reaper.ImGui_Text(ctx, "Rendu audio :")
    reaper.ImGui_Separator(ctx)
    
    -- Radio buttons pour le mode de rendu
    if reaper.ImGui_RadioButton(ctx, "Full Speed", not render_realtime) then
        render_realtime = false
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Realtime", render_realtime) then
        render_realtime = true
    end
    
    if reaper.ImGui_Button(ctx, "Render Selection") then
        RenderSelection()
    end

    reaper.ImGui_Separator(ctx)
    
    -- Partie 3: Importation ALK
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
    
    -- Partie 4: Gestion des données audio
    reaper.ImGui_Text(ctx, "Gestion des données audio :")
    reaper.ImGui_Separator(ctx)
    
    if reaper.ImGui_Button(ctx, "Enregistrer les données audio") then
        core2.SaveAudioData()
    end
    
    if reaper.ImGui_Button(ctx, "Charger les données audio") then
        core2.LoadAudioData()
    end

    reaper.ImGui_Separator(ctx)

    -- Partie 5: Automation du clic
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

    reaper.ImGui_Separator(ctx)
    
    -- Partie 5: Mise à jour globale
    reaper.ImGui_Text(ctx, "Mise à jour globale :")
    reaper.ImGui_Separator(ctx)
    
    -- Bouton avec style spécial pour la mise à jour globale
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xAB47BCFF)  -- Violet
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xBA68C8FF)  -- Violet plus clair
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x9C27B0FF)  -- Violet plus foncé
    
    if reaper.ImGui_Button(ctx, "Mettre à jour tous les blocs") then
        -- Demander confirmation
        local confirm = reaper.ShowMessageBox(
            "Cette opération va mettre à jour tous les blocs du projet pour les rendre compatibles avec la dernière version.\n\n" ..
            "Cette opération peut prendre un certain temps selon la taille du projet.\n\n" ..
            "Voulez-vous continuer ?",
            "Confirmation de mise à jour globale",
            4)  -- 4 = Yes/No
        
        if confirm == 6 then  -- 6 = Yes
            UpdateAllBlocks()
        end
    end
    
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    if progress_message ~= "" then
        reaper.ImGui_Text(ctx, progress_message)
    end
    
    reaper.ImGui_Separator(ctx)
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

    -- Nouveau bouton pour mettre à jour les constantes
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xAB47BCFF)  -- Violet
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xBA68C8FF)  -- Violet plus clair
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x9C27B0FF)  -- Violet plus foncé
    
    if reaper.ImGui_Button(ctx, "Mettre à jour les constantes") then
        local success, message = core.update_jsfx_constants()
        if not success then
            reaper.ShowMessageBox(message, "Erreur", 0)
        end
    end
    
    reaper.ImGui_PopStyleColor(ctx, 3)
end

--------------------------------------------------------------------------------
-- Fonction pour calculer la hauteur nécessaire
--------------------------------------------------------------------------------
local function calculateRequiredHeight()
    local base_height = 18  -- Hauteur de base pour les éléments fixes
    local item_height = 22   -- Hauteur approximative par élément
    local content_height = base_height
    
    -- Vérifier si la take existe toujours et est valide
    if current_take and reaper.ValidatePtr2(0, current_take, "MediaItem_Take*") and reaper.TakeIsMIDI(current_take) then
        local loop_type = loop_types[selected_loop_type_index + 1]
        
        -- Ajouter la hauteur pour les éléments communs
        content_height = content_height + (3 * item_height)  -- Note MIDI, séparateur, nombre d'éléments
        
        -- Ajouter la hauteur selon le type de loop
        if loop_type == "RECORD" then
            content_height = content_height + (6 * item_height)  -- Type, Nom, Mono/Stereo, Pan, Vol, Monitoring
        elseif loop_type == "PLAY" or loop_type == "OVERDUB" then
            content_height = content_height + (7 * item_height)  -- Type, Réf, Mono/Stereo, Pan, Vol, Monitoring, Pitch
        elseif loop_type == "MONITOR" then
            content_height = content_height + (5 * item_height)  -- Type, Mono/Stereo, Pan, Vol, Monitoring
        end
        
        -- Ajouter la hauteur pour la section modulation
        content_height = content_height + (2 * item_height)  -- Séparateur et bouton Modulation
        if show_modulation then
            content_height = content_height + (#modulation_params * item_height)  -- Faders de modulation
        end
        
        -- Ajouter la hauteur pour le bouton Appliquer et le message de progression
        content_height = content_height + (2 * item_height)
    else
        -- Si aucun take n'est sélectionné
        content_height = content_height + item_height
    end
    
    -- Ajouter une marge et s'assurer d'une hauteur minimale
    return math.max(270, content_height)
    
end

--------------------------------------------------------------------------------
-- Fenêtre principale
--------------------------------------------------------------------------------
local function DrawMainWindow()
    -- Charger les valeurs depuis gmem au début de chaque frame
    record_monitor_loops = get_record_monitor_loops_mode()
    playback_mode = get_playback_mode()

    -- Ajuster la hauteur uniquement pour Loop Editor
    if current_tab == "Loop Editor" then
        local required_height = calculateRequiredHeight()
        if required_height ~= window_height then
            window_height = required_height
            reaper.ImGui_SetNextWindowSize(ctx, window_width, window_height, reaper.ImGui_Cond_Always())
        end
    end

    if current_tab == "Tools" then
        reaper.ImGui_SetNextWindowSize(ctx, window_width, TOOLS_TAB_HEIGHT, reaper.ImGui_Cond_Always())
    end

    reaper.ImGui_SetNextWindowPos(ctx, 100, 50, reaper.ImGui_Cond_FirstUseEver())
    
    local visible, open = reaper.ImGui_Begin(ctx, "PoulpyLoopy v" .. VERSION, true)
    if visible then
        -- Sauvegarder la largeur de la fenêtre si elle a été redimensionnée
        local current_width = reaper.ImGui_GetWindowWidth(ctx)
        if current_width ~= window_width then
            window_width = current_width
            reaper.SetExtState("PoulpyLoopy", "window_width", tostring(window_width), true)
        end

        -- Détecter le changement d'onglet
        local old_tab = current_tab
        
        if reaper.ImGui_BeginTabBar(ctx, "MainTabs") then
            -- Onglet "Loop Editor"
            if reaper.ImGui_BeginTabItem(ctx, "Loop Editor") then
                current_tab = "Loop Editor"
                DrawLoopEditor()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Options"
            if reaper.ImGui_BeginTabItem(ctx, "Options") then
                current_tab = "Options"
                DrawOptions()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Tools"
            if reaper.ImGui_BeginTabItem(ctx, "Tools") then
                current_tab = "Tools"
                
                DrawTools()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Stats"
            if reaper.ImGui_BeginTabItem(ctx, "Stats") then
                current_tab = "Stats"
                DrawStats()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Debug"
            if reaper.ImGui_BeginTabItem(ctx, "Debug") then
                current_tab = "Debug"
                DrawDebug()
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
M.RenderSelection = RenderSelection

return M 