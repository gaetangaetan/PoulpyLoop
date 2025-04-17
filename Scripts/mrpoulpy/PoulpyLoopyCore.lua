--[[------------------------------------------------------------------------------
  PoulpyLoopyCore.lua
  Module contenant les fonctions et constantes de base pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper

--------------------------------------------------------------------------------
-- Constantes globales
--------------------------------------------------------------------------------
local VERSION = "0020"

-- Couleurs
local COLORS = {
    RECORD = reaper.ColorToNative(235,64,52) + 0x1000000,
    PLAY = reaper.ColorToNative(49,247,108) + 0x1000000,
    MONITOR_REF = reaper.ColorToNative(255,165,0) + 0x1000000,
    OVERDUB = reaper.ColorToNative(32,241,245) + 0x1000000,
    MONITOR = reaper.ColorToNative(247,188,49) + 0x1000000,
    UNUSED = reaper.ColorToNative(0,0,0) + 0x1000000,
    AUTOMATION = reaper.ColorToNative(128,128,128) + 0x1000000,
    CLICK_MUTED = reaper.ColorToNative(0,0,255) + 0x1000000,
    CLICK_ACTIVE = reaper.ColorToNative(255,192,203) + 0x1000000,
    CLICK_NO_AUTO = reaper.ColorToNative(0,0,0) + 0x1000000,
    CLICK = reaper.ColorToNative(136,39,255) + 0x1000000
}

local LOOP_TYPES = {"RECORD", "OVERDUB", "PLAY", "MONITOR", "UNUSED"}

-- Indices gmem
local GMEM = {
    RECORD_MONITOR_MODE = 0,
    PLAYBACK_MODE = 1,
    STATS_BASE = 2,
    NEXT_INSTANCE_ID = 194,
    MONITORING_STOP_BASE = 195,
    NOTE_START_POS_BASE = 259,
    LOOP_LENGTH_BASE = 8451,
    FORCE_ANALYZE = 16000,
    MIDI_SYNC_DATA_BASE = 16001,
    AFFICHAGE_CONSOLE_DEBUG = 17100,
    MESSAGE_BASE = 17000,
    MESSAGE_LENGTH = 16999
}

--------------------------------------------------------------------------------
-- Fonctions utilitaires
--------------------------------------------------------------------------------
local function IsStringEmptyOrWhitespace(str)
    return str == nil or str:match("^%s*$") ~= nil
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function containsValue(tbl, val)
    for _, v in ipairs(tbl) do
        if v == val then return true end
    end
    return false
end

local function debug_console(message)
    if reaper.gmem_read(GMEM.AFFICHAGE_CONSOLE_DEBUG) == 1 then
        reaper.ShowConsoleMsg(message)
    end
end

--------------------------------------------------------------------------------
-- Fonctions de métadonnées
--------------------------------------------------------------------------------
local function SetProjectMetadata(section, key, value)
    reaper.SetProjExtState(0, section, key, value)
end

local function GetProjectMetadata(section, key)
    local _, value = reaper.GetProjExtState(0, section, key)
    return value
end

local function SetTakeMetadata(take, key, value)
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:" .. key, tostring(value), true)
end

local function GetTakeMetadata(take, key)
    local retval, val = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:" .. key, "", false)
    return retval and val or nil
end

--------------------------------------------------------------------------------
-- Fonctions de gestion des loops
--------------------------------------------------------------------------------
local function GetTracksInSameFolder(base_track)
    local tracks = {}
    local parent = reaper.GetParentTrack(base_track)
    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks - 1 do
        local tr = reaper.GetTrack(0, t)
        if parent then
            if reaper.GetParentTrack(tr) == parent then
                table.insert(tracks, tr)
            end
        else
            if tr == base_track then
                table.insert(tracks, tr)
            end
        end
    end
    return tracks
end

local function GetRecordLoopsInFolder(take)
    local base_track = reaper.GetMediaItemTake_Track(take)
    local tracks = GetTracksInSameFolder(base_track)
    local loops = {}
    for _, track in ipairs(tracks) do
        local count = reaper.CountTrackMediaItems(track)
        for i = 0, count - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item then
                for j = 0, reaper.CountTakes(item) - 1 do
                    local other_take = reaper.GetTake(item, j)
                    if other_take then
                        local loop_type = GetTakeMetadata(other_take, "loop_type")
                        local loop_name = GetTakeMetadata(other_take, "loop_name")
                        if loop_type == "RECORD" and not IsStringEmptyOrWhitespace(loop_name) then
                            table.insert(loops, loop_name)
                        end
                    end
                end
            end
        end
    end
    table.sort(loops)
    return loops
end

local function GetPreviousRecordLoopsInFolder(take)
    local base_track = reaper.GetMediaItemTake_Track(take)
    local curItem = reaper.GetMediaItemTake_Item(take)
    local curStart = reaper.GetMediaItemInfo_Value(curItem, "D_POSITION")

    local recordLoops = {}
    
    local nb = reaper.CountTrackMediaItems(base_track)
    for i = 0, nb - 1 do
        local it = reaper.GetTrackMediaItem(base_track, i)
        local st = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if st < curStart then
            for tk = 0, reaper.CountTakes(it) - 1 do
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

local function IsLoopNameValid(take, new_name)
    new_name = trim(new_name)
    if IsStringEmptyOrWhitespace(new_name) then
        return false, "Le nom de la loop ne peut pas être vide."
    end
    local existing_loops = GetRecordLoopsInFolder(take)
    local current_take_name = GetTakeMetadata(take, "loop_name")
    for _, existing_name in ipairs(existing_loops) do
        if existing_name == new_name and existing_name ~= current_take_name then
            return false, "Ce nom de loop existe déjà dans ce folder."
        end
    end
    return true, ""
end

local function UpdateDependentLoops(record_take, old_name, new_name)
    local base_track = reaper.GetMediaItemTake_Track(record_take)
    local tracks = GetTracksInSameFolder(base_track)
    for _, track in ipairs(tracks) do
        local count = reaper.CountTrackMediaItems(track)
        for i = 0, count - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item then
                for j = 0, reaper.CountTakes(item) - 1 do
                    local other_take = reaper.GetTake(item, j)
                    if other_take then
                        local loop_type = GetTakeMetadata(other_take, "loop_type")
                        if loop_type == "OVERDUB" or loop_type == "PLAY" then
                            local ref = GetTakeMetadata(other_take, "reference_loop")
                            if ref == old_name then
                                SetTakeMetadata(other_take, "reference_loop", new_name)
                                reaper.GetSetMediaItemTakeInfo_String(other_take, "P_NAME", new_name, true)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function UnfoldPlayLoop(take)
    local item = reaper.GetMediaItemTake_Item(take)
    if not item then return end
    
    -- Vérifier que c'est bien une loop PLAY
    local loop_type = GetTakeMetadata(take, "loop_type")
    if loop_type ~= "PLAY" then return end
    
    -- Obtenir la référence
    local reference_loop = GetTakeMetadata(take, "reference_loop")
    if not reference_loop or reference_loop == "" then return end
    
    -- Trouver la loop de référence et sa longueur
    local track = reaper.GetMediaItemTake_Track(take)
    local ref_length = nil
    local num_items = reaper.CountTrackMediaItems(track)
    
    for i = 0, num_items - 1 do
        local check_item = reaper.GetTrackMediaItem(track, i)
        local check_take = reaper.GetActiveTake(check_item)
        if check_take and reaper.TakeIsMIDI(check_take) then
            local check_type = GetTakeMetadata(check_take, "loop_type")
            local check_name = GetTakeMetadata(check_take, "loop_name")
            if check_type == "RECORD" and check_name == reference_loop then
                ref_length = reaper.GetMediaItemInfo_Value(check_item, "D_LENGTH")
                break
            end
        end
    end
    
    if not ref_length then return end
    
    -- Vérifier si la loop PLAY est plus longue que sa référence
    local play_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if play_length <= ref_length then return end
    
    -- Calculer le nombre de copies nécessaires
    local ratio = play_length / ref_length
    local full_copies = math.floor(ratio)
    local partial_length = play_length - (full_copies * ref_length)
    local current_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    
    -- Réduire la taille de la loop originale
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", ref_length)
    
    -- Commencer l'opération d'unfolding
    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock()
    
    -- Pour chaque copie complète (sauf la première qui est déjà l'item original)
    for i = 1, full_copies - 1 do
        current_position = current_position + ref_length
        
        -- Sauvegarder la sélection actuelle
        local old_sel_items = {}
        for s = 0, reaper.CountSelectedMediaItems(0) - 1 do
            old_sel_items[s+1] = reaper.GetSelectedMediaItem(0, s)
        end
        
        -- Désélectionner tous les items
        for _, sel_item in ipairs(old_sel_items) do
            reaper.SetMediaItemSelected(sel_item, false)
        end
        
        -- Sélectionner l'item à dupliquer
        reaper.SetMediaItemSelected(item, true)
        
        -- Dupliquer en utilisant la commande native de REAPER
        reaper.Main_OnCommand(41295, 0)  -- Duplicate items
        
        -- Récupérer l'item dupliqué
        local new_item = reaper.GetSelectedMediaItem(0, 0)
        if new_item then
            reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_position)
            reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", ref_length)
        end
        
        -- Restaurer la sélection originale
        reaper.SetMediaItemSelected(new_item, false)
        for _, sel_item in ipairs(old_sel_items) do
            reaper.SetMediaItemSelected(sel_item, true)
        end
    end
    
    -- Ajouter la dernière portion partielle si nécessaire
    if partial_length > 0 then
        current_position = current_position + ref_length
        
        -- Même processus que pour les copies complètes
        local old_sel_items = {}
        for s = 0, reaper.CountSelectedMediaItems(0) - 1 do
            old_sel_items[s+1] = reaper.GetSelectedMediaItem(0, s)
        end
        
        for _, sel_item in ipairs(old_sel_items) do
            reaper.SetMediaItemSelected(sel_item, false)
        end
        
        reaper.SetMediaItemSelected(item, true)
        reaper.Main_OnCommand(41295, 0)
        
        local new_item = reaper.GetSelectedMediaItem(0, 0)
        if new_item then
            reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_position)
            reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", partial_length)
        end
        
        reaper.SetMediaItemSelected(new_item, false)
        for _, sel_item in ipairs(old_sel_items) do
            reaper.SetMediaItemSelected(sel_item, true)
        end
    end
    
    reaper.Undo_EndBlock("Déplier la loop PLAY", -1)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
end

--------------------------------------------------------------------------------
-- Fonctions de gestion des notes MIDI
--------------------------------------------------------------------------------
local function ProcessMIDINotes(track_filter, return_data)
    local noteCounters = {}         -- par piste (clé = track_id)
    local recordLoopPitches = {}    -- par piste: mapping { loop_name -> pitch }
    local allTakes = {}

    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, t)
        -- Si un filtre de piste est spécifié, ignorer les autres pistes
        if not track_filter or track == track_filter then
            for i = 0, reaper.CountTrackMediaItems(track) - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                if item then
                    for j = 0, reaper.CountTakes(item) - 1 do
                        local take = reaper.GetTake(item, j)
                        if take and reaper.TakeIsMIDI(take) then
                            local loop_type = GetTakeMetadata(take, "loop_type")
                            if loop_type then
                                table.insert(allTakes, { take = take, item = item, start_time = reaper.GetMediaItemInfo_Value(item, "D_POSITION"), loop_type = loop_type, track = track })
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(allTakes, function(a, b)
        -- Tri par piste, puis par position de début
        local trackA_id = reaper.GetMediaTrackInfo_Value(a.track, "IP_TRACKNUMBER")
        local trackB_id = reaper.GetMediaTrackInfo_Value(b.track, "IP_TRACKNUMBER")
        if trackA_id == trackB_id then
            return a.start_time < b.start_time
        else
            return trackA_id < trackB_id
        end
    end)

    for _, entry in ipairs(allTakes) do
        local take = entry.take
        local item = entry.item
        local loop_type = entry.loop_type
        local track = entry.track
        local track_id = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
        
        if not noteCounters[track_id] then
            noteCounters[track_id] = 1  -- Commence à 1 (C#-1)
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
            -- Extraire le nom sans préfixe pour la recherche
            local ref_name = reference_loop:match("%d%d%s+(.*)")
            local refNote = 0
            
            -- Chercher d'abord avec le nom complet
            if recordLoopPitches[track_id][reference_loop] then
                refNote = recordLoopPitches[track_id][reference_loop]
            -- Puis chercher avec le nom sans préfixe
            elseif ref_name and recordLoopPitches[track_id][ref_name] then
                refNote = recordLoopPitches[track_id][ref_name]
            -- Enfin, chercher dans toutes les entrées pour une correspondance sans préfixe
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
            local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
            -- Même logique que pour PLAY
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

        -- Insertion des MIDI CC pour représenter les paramètres de la loop
        if loop_type ~= "UNUSED" then
            local volume_db_val = tonumber(GetTakeMetadata(take, "volume_db")) or 0
            local cc07 = math.floor(((volume_db_val + 20) / 40) * 127 + 0.5)
            local is_mono_str = GetTakeMetadata(take, "is_mono") or "false"
            local cc08 = (is_mono_str == "true") and 0 or 1
            local pan_val = tonumber(GetTakeMetadata(take, "pan")) or 0
            local cc10 = math.floor(64 + pan_val * 63 + 0.5)
            local pitch_val = tonumber(GetTakeMetadata(take, "pitch")) or 0
            local cc09 = math.floor(64 + pitch_val + 0.5)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 7, cc07, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 8, cc08, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 10, cc10, false)
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 9, cc09, false)
            local monitoring_val = tonumber(GetTakeMetadata(take, "monitoring")) or 0
            reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, 11, monitoring_val, false)
        end

        reaper.MIDI_Sort(take)
        ::continue::
    end
    
    -- Si demandé, retourner les données collectées
    if return_data then
        return {
            noteCounters = noteCounters,
            recordLoopPitches = recordLoopPitches
        }
    end
end

--------------------------------------------------------------------------------
-- Fonctions de gestion des modes
--------------------------------------------------------------------------------
local function get_record_monitor_loops_mode()
    return reaper.gmem_read(GMEM.RECORD_MONITOR_MODE) == 1
end

local function get_playback_mode()
    return reaper.gmem_read(GMEM.PLAYBACK_MODE) == 1
end

local function save_record_monitor_loops_mode(value)
    reaper.gmem_write(GMEM.RECORD_MONITOR_MODE, value and 1 or 0)
end

local function save_playback_mode(value)
    reaper.gmem_write(GMEM.PLAYBACK_MODE, value and 1 or 0)
end

-- Fonction auxiliaire pour trouver la hauteur de note référencée pour un bloc PLAY ou OVERDUB
local function FindReferenceNote(reference_loop, recordPitches)
    if not recordPitches then return 0 end
    
    local refNote = 0
    
    -- Extraire le nom sans préfixe pour la recherche
    local ref_name = reference_loop:match("%d%d%s+(.*)")
    
    -- Chercher d'abord avec le nom complet
    if recordPitches[reference_loop] then
        refNote = recordPitches[reference_loop]
    -- Puis chercher avec le nom sans préfixe
    elseif ref_name and recordPitches[ref_name] then
        refNote = recordPitches[ref_name]
    -- Enfin, chercher dans toutes les entrées pour une correspondance sans préfixe
    else
        for name, pitch in pairs(recordPitches) do
            local name_without_prefix = name:match("%d%d%s+(.*)")
            if name_without_prefix and name_without_prefix == ref_name then
                refNote = pitch
                break
            end
        end
    end
    
    return refNote
end

-- Fonction pour appliquer directement les modifications MIDI sans appeler ProcessMIDINotes
local function ApplyMIDIChanges(take, item, midi_data)
    if not take or not item or not midi_data then return end
    
    -- Obtenir les informations nécessaires sur l'item et le take
    local loop_type = GetTakeMetadata(take, "loop_type") or "UNUSED"
    if loop_type == "UNUSED" then return end
    
    local track = reaper.GetMediaItemTake_Track(take)
    local track_id = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    
    -- Effacer les événements MIDI existants
    reaper.MIDI_SetAllEvts(take, "")
    
    -- Calcul des temps en PPQ
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_start + item_length
    local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_start)
    local end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_end)
    
    -- Insérer la note MIDI selon le type
    local note_val = 0
    local vel_val = 0
    
    if loop_type == "PLAY" then
        -- Pour PLAY, trouver la référence
        local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
        note_val = FindReferenceNote(reference_loop, midi_data.recordLoopPitches[track_id])
        vel_val = 2  -- vélocité pour PLAY
        
    elseif loop_type == "OVERDUB" then
        -- Pour OVERDUB, même logique que PLAY
        local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
        note_val = FindReferenceNote(reference_loop, midi_data.recordLoopPitches[track_id])
        vel_val = 3  -- vélocité pour OVERDUB
        
    elseif loop_type == "MONITOR" then
        -- Pour MONITOR, utiliser la valeur de noteCounters
        if midi_data.noteCounters[track_id] then
            note_val = midi_data.noteCounters[track_id]
            midi_data.noteCounters[track_id] = midi_data.noteCounters[track_id] + 1
        end
        vel_val = 4  -- vélocité pour MONITOR
    end
    
    -- Insérer la note
    reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, note_val, vel_val, false)
    
    -- Insérer les CC
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
    
    -- Insérer les CC pour la modulation
    for i = 1, 8 do  -- 8 paramètres de modulation
        local start_value = tonumber(GetTakeMetadata(take, "mod_" .. i .. "_start")) or 0
        local end_value = tonumber(GetTakeMetadata(take, "mod_" .. i .. "_end")) or 0
        local start_cc = 20 + (i - 1) * 2  -- CCs 20, 22, 24, etc.
        local end_cc = 21 + (i - 1) * 2    -- CCs 21, 23, 25, etc.
        reaper.MIDI_InsertCC(take, false, false, start_ppq, 0xB0, 0, start_cc, start_value, false)
        reaper.MIDI_InsertCC(take, false, false, end_ppq, 0xB0, 0, end_cc, end_value, false)
    end
    
    reaper.MIDI_Sort(take)
end

--------------------------------------------------------------------------------
-- Export des fonctions
--------------------------------------------------------------------------------
return {
    -- Constantes
    VERSION = VERSION,
    COLORS = COLORS,
    LOOP_TYPES = LOOP_TYPES,
    GMEM = GMEM,

    -- Fonctions utilitaires
    IsStringEmptyOrWhitespace = IsStringEmptyOrWhitespace,
    trim = trim,
    containsValue = containsValue,
    debug_console = debug_console,

    -- Fonctions de métadonnées
    SetProjectMetadata = SetProjectMetadata,
    GetProjectMetadata = GetProjectMetadata,
    SetTakeMetadata = SetTakeMetadata,
    GetTakeMetadata = GetTakeMetadata,

    -- Fonctions de gestion des loops
    GetTracksInSameFolder = GetTracksInSameFolder,
    GetRecordLoopsInFolder = GetRecordLoopsInFolder,
    GetPreviousRecordLoopsInFolder = GetPreviousRecordLoopsInFolder,
    IsLoopNameValid = IsLoopNameValid,
    UpdateDependentLoops = UpdateDependentLoops,
    UnfoldPlayLoop = UnfoldPlayLoop,
    ProcessMIDINotes = ProcessMIDINotes,

    -- Fonctions de gestion des modes
    get_record_monitor_loops_mode = get_record_monitor_loops_mode,
    get_playback_mode = get_playback_mode,
    save_record_monitor_loops_mode = save_record_monitor_loops_mode,
    save_playback_mode = save_playback_mode,
    FindReferenceNote = FindReferenceNote,
    ApplyMIDIChanges = ApplyMIDIChanges
} 