--[[------------------------------------------------------------------------------
  PoulpyLoopyCore1.lua
  Module contenant les fonctions de base pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper

-- Charger les constantes
local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/"
local constants = dofile(script_path .. "PoulpyLoopyCore0.lua")

-- Module à exporter
local M = {}

-- Exporter les constantes
M.VERSION = constants.VERSION
M.COLORS = constants.COLORS
M.LOOP_TYPES = constants.LOOP_TYPES
M.GMEM = constants.GMEM

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
    if reaper.gmem_read(constants.GMEM.AFFICHAGE_CONSOLE_DEBUG) == 1 then
        reaper.ShowConsoleMsg(message)
    end
end

M.debug_console = debug_console

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

M.SetProjectMetadata = SetProjectMetadata
M.GetProjectMetadata = GetProjectMetadata
M.SetTakeMetadata = SetTakeMetadata
M.GetTakeMetadata = GetTakeMetadata

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
    
    -- Ajuster la longueur
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", ref_length)
end

M.GetTracksInSameFolder = GetTracksInSameFolder
M.GetRecordLoopsInFolder = GetRecordLoopsInFolder
M.GetPreviousRecordLoopsInFolder = GetPreviousRecordLoopsInFolder
M.IsLoopNameValid = IsLoopNameValid
M.UpdateDependentLoops = UpdateDependentLoops
M.UnfoldPlayLoop = UnfoldPlayLoop

--------------------------------------------------------------------------------
-- Fonctions de gestion des modes
--------------------------------------------------------------------------------
local function get_record_monitor_loops_mode()
    return reaper.gmem_read(constants.GMEM.RECORD_MONITOR_MODE) == 1
end

local function get_playback_mode()
    return reaper.gmem_read(constants.GMEM.PLAYBACK_MODE) == 1
end

local function save_record_monitor_loops_mode(enabled)
    reaper.gmem_write(constants.GMEM.RECORD_MONITOR_MODE, enabled and 1 or 0)
end

local function save_playback_mode(enabled)
    reaper.gmem_write(constants.GMEM.PLAYBACK_MODE, enabled and 1 or 0)
end

M.get_record_monitor_loops_mode = get_record_monitor_loops_mode
M.get_playback_mode = get_playback_mode
M.save_record_monitor_loops_mode = save_record_monitor_loops_mode
M.save_playback_mode = save_playback_mode

return M 