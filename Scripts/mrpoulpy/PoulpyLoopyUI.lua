--[[------------------------------------------------------------------------------
  PoulpyLoopyUI.lua
  Module contenant les fonctions de l'interface utilisateur pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper

-- Charger le module Core
local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/"
local core = dofile(script_path .. "PoulpyLoopyCore.lua")


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
local GetPreviousRecordLoopsInFolder = core.GetPreviousRecordLoopsInFolder
local UnfoldPlayLoop = core.UnfoldPlayLoop
local get_record_monitor_loops_mode = core.get_record_monitor_loops_mode
local get_playback_mode = core.get_playback_mode
local save_record_monitor_loops_mode = core.save_record_monitor_loops_mode
local save_playback_mode = core.save_playback_mode
local debug_console = core.debug_console
local ApplyMIDIChanges = core.ApplyMIDIChanges
local reset_poulpyloop_plugin = core.reset_poulpyloop_plugin


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

-- Variables pour l'automation de pitch
local show_automation_dialog = false
local automation_success_mode = false  -- true = afficher le message de succès, false = afficher le formulaire
local selected_fx_index = 0
local selected_param_index = 0
local pitch_sensitivity = 5.0  -- % par demi-ton (défaut: 5%)
local fx_list = {}
local param_list = {}
local automation_track = nil


local current_midi_note = nil
local current_midi_velocity = nil

local last_cursor_pos = -1
local title_font = nil
local progress_message = ""
local processing_items = {}

local window_height = 500  -- Nouvelle variable pour la hauteur de la fenêtre
local window_width = 700   -- Nouvelle variable pour la largeur de la fenêtre
local render_realtime = true  -- true = realtime (idle), false = full speed

-- Variables pour les notifications des outils
local tools_notification_message = ""  -- Message à afficher
local tools_notification_type = "success"  -- "success", "error", "info"
local tools_notification_visible = false  -- true si une notification est visible
local tools_confirmation_pending = ""  -- Action en attente de confirmation



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



-- Préparation des variables pour les sélections multiples
local midi_data = nil  -- Pour stocker les données MIDI entre les appels

--------------------------------------------------------------------------------
-- Fonctions locales
--------------------------------------------------------------------------------
-- GetPreviousRecordLoopsInFolder : importe depuis le Core (M5, doublon supprime).

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
    if reaper.ImGui_BeginCombo(ctx, "Audio input", label) then
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
        reaper.ShowMessageBox("No track selected.", "Error", 0)
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
    -- Attribuer les identifiants d'instance stables aux plugins (C3/C4)
    core.AssignInstanceIds()
    -- Restaurer la largeur de la fenêtre
    local saved_width = reaper.GetExtState("PoulpyLoopy", "window_width")
    if saved_width ~= "" then
        window_width = tonumber(saved_width)
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
-- Fonctions d'automation de pitch
--------------------------------------------------------------------------------

-- Fonctions pour sauvegarder/restaurer les préférences d'automation par piste
local function SaveAutomationPrefs(track, fx_index, param_index)
    if not track then return end
    
    local track_guid = reaper.GetTrackGUID(track)
    if track_guid then
        local guid_str = reaper.guidToString(track_guid, "")
        reaper.SetProjExtState(0, "PoulpyLoopy_AutomationPrefs", "fx_" .. guid_str, tostring(fx_index))
        reaper.SetProjExtState(0, "PoulpyLoopy_AutomationPrefs", "param_" .. guid_str, tostring(param_index))
    end
end

local function LoadAutomationPrefs(track)
    if not track then return nil, nil end
    
    local track_guid = reaper.GetTrackGUID(track)
    if track_guid then
        local guid_str = reaper.guidToString(track_guid, "")
        local _, fx_str = reaper.GetProjExtState(0, "PoulpyLoopy_AutomationPrefs", "fx_" .. guid_str)
        local _, param_str = reaper.GetProjExtState(0, "PoulpyLoopy_AutomationPrefs", "param_" .. guid_str)
        
        if fx_str ~= "" and param_str ~= "" then
            return tonumber(fx_str), tonumber(param_str)
        end
    end
    
    return nil, nil
end

-- Fonction pour rafraîchir la liste des FX
function RefreshFXList()
    fx_list = {}
    param_list = {}
    
    if not automation_track then return end
    
    local fx_count = reaper.TrackFX_GetCount(automation_track)
    for i = 0, fx_count - 1 do
        local retval, fx_name = reaper.TrackFX_GetFXName(automation_track, i, "")
        if retval then
            fx_list[i] = {index = i, name = fx_name}
        end
    end
    
    -- Restaurer les préférences sauvegardées pour cette piste
    local saved_fx, saved_param = LoadAutomationPrefs(automation_track)
    if saved_fx and fx_list[saved_fx] then
        selected_fx_index = saved_fx
        RefreshParamList(saved_fx)
        if saved_param and param_list[saved_param] then
            selected_param_index = saved_param
        else
            selected_param_index = 0
        end
    else
        selected_fx_index = 0
        selected_param_index = 0
                end
            end
            
-- Fonction pour rafraîchir la liste des paramètres d'un FX
function RefreshParamList(fx_index)
    param_list = {}
    
    if not automation_track or fx_index < 0 then return end
    
    local param_count = reaper.TrackFX_GetNumParams(automation_track, fx_index)
    for i = 0, param_count - 1 do
        local retval, param_name = reaper.TrackFX_GetParamName(automation_track, fx_index, i, "")
        if retval then
            param_list[i] = {index = i, name = param_name}
                    end
                end
            end
            
-- Fonction pour générer l'automation de pitch
function GeneratePitchAutomation(fx_index, param_index, sensitivity)
    if not automation_track then return false end
    
    -- Obtenir l'envelope d'automation pour ce paramètre
    local envelope = reaper.GetFXEnvelope(automation_track, fx_index, param_index, true)
    if not envelope then return false end
    
    -- Effacer tous les points existants
    reaper.DeleteEnvelopePointRange(envelope, 0, reaper.GetProjectLength(0))
    
    -- Collecter tous les blocs MIDI de la piste sélectionnée avec leurs positions et métadonnées
    local project_blocks = {}
    local num_items = reaper.CountTrackMediaItems(automation_track)
    
    for i = 0, num_items - 1 do
        local item = reaper.GetTrackMediaItem(automation_track, i)
        local take = reaper.GetActiveTake(item)
        
        if take and reaper.TakeIsMIDI(take) then
            local loop_type = GetTakeMetadata(take, "loop_type")
            if loop_type and loop_type ~= "UNUSED" then
                local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local pitch_val = tonumber(GetTakeMetadata(take, "pitch")) or 0
                
                table.insert(project_blocks, {
                    start_time = item_start,
                    end_time = item_start + item_length,
                    pitch = pitch_val
                })
            end
        end
    end
    
    -- Trier les blocs par position temporelle
    table.sort(project_blocks, function(a, b) return a.start_time < b.start_time end)
    
    -- Générer les points d'automation
    local project_length = reaper.GetProjectLength(0)
    local current_time = 0
    local current_pitch = 0
    
    -- Point initial à 50% (pitch neutre)
    reaper.InsertEnvelopePoint(envelope, current_time, 0.5, 0, 0, false, true)
    
    for _, block in ipairs(project_blocks) do
        -- Si il y a un gap avant ce bloc, maintenir le pitch précédent
        if block.start_time > current_time then
            local pitch_value = 0.5 + (current_pitch * sensitivity / 100.0)
            pitch_value = math.max(0, math.min(1, pitch_value))  -- Clamper entre 0 et 1
            reaper.InsertEnvelopePoint(envelope, block.start_time, pitch_value, 0, 0, false, true)
        end
        
        -- Point au début du bloc avec le nouveau pitch
        local new_pitch_value = 0.5 + (block.pitch * sensitivity / 100.0)
        new_pitch_value = math.max(0, math.min(1, new_pitch_value))
        reaper.InsertEnvelopePoint(envelope, block.start_time, new_pitch_value, 0, 0, false, true)
        
        -- Point à la fin du bloc (maintenir le pitch)
        reaper.InsertEnvelopePoint(envelope, block.end_time, new_pitch_value, 0, 0, false, true)
        
        current_time = block.end_time
        current_pitch = block.pitch
    end
    
    -- Point final jusqu'à la fin du projet
    if current_time < project_length then
        local final_pitch_value = 0.5 + (current_pitch * sensitivity / 100.0)
        final_pitch_value = math.max(0, math.min(1, final_pitch_value))
        reaper.InsertEnvelopePoint(envelope, project_length, final_pitch_value, 0, 0, false, true)
    end
    
    -- Trier les points et actualiser l'affichage
    reaper.Envelope_SortPoints(envelope)
    reaper.UpdateArrange()
    
    return true
end

-- Fonction pour dessiner le dialogue d'automation
function DrawAutomationDialog()
    if not show_automation_dialog then return end
    
    local dialog_flags = reaper.ImGui_WindowFlags_AlwaysAutoResize() | 
                        reaper.ImGui_WindowFlags_NoCollapse()
    
    local visible, open = reaper.ImGui_Begin(ctx, "Pitch Automation Setup", true, dialog_flags)
    if visible then
        if automation_success_mode then
            -- Mode succès : afficher le message de confirmation
            reaper.ImGui_Dummy(ctx, 20, 20)  -- Espace en haut
            
            -- Centrer le texte
            local window_width = reaper.ImGui_GetWindowWidth(ctx)
            local text_width = reaper.ImGui_CalcTextSize(ctx, "Automation generated successfully!")
            reaper.ImGui_SetCursorPosX(ctx, (window_width - text_width) * 0.5)
            
            -- Texte de succès avec couleur verte
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x00AA00FF)  -- Vert
            reaper.ImGui_Text(ctx, "✅ Automation generated successfully!")
            reaper.ImGui_PopStyleColor(ctx)
            
            reaper.ImGui_Dummy(ctx, 20, 20)  -- Espace entre le texte et le bouton
            
            -- Centrer le bouton
            local button_width = 80
            reaper.ImGui_SetCursorPosX(ctx, (window_width - button_width) * 0.5)
            
            if reaper.ImGui_Button(ctx, "Close", button_width, 0) then
                show_automation_dialog = false
                automation_success_mode = false  -- Remettre en mode formulaire pour la prochaine fois
            end
            
            reaper.ImGui_Dummy(ctx, 20, 10)  -- Espace en bas
            
        else
            -- Mode formulaire : interface normale
            reaper.ImGui_Text(ctx, "Configure pitch automation for track:")
            if automation_track then
                local _, track_name = reaper.GetTrackName(automation_track)
                reaper.ImGui_Text(ctx, "  " .. (track_name or "Unnamed Track"))
            end
            
            reaper.ImGui_Separator(ctx)
            
            -- Sélection de l'effet
            reaper.ImGui_Text(ctx, "Select FX:")
            if reaper.ImGui_BeginCombo(ctx, "##fx_combo", fx_list[selected_fx_index] and fx_list[selected_fx_index].name or "No FX") then
                for i, fx in pairs(fx_list) do
                    if reaper.ImGui_Selectable(ctx, fx.name, i == selected_fx_index) then
                        selected_fx_index = i
                        RefreshParamList(i)
                        selected_param_index = 0
                        -- Sauvegarder immédiatement le changement d'effet
                        SaveAutomationPrefs(automation_track, selected_fx_index, selected_param_index)
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            
            -- Sélection du paramètre
            reaper.ImGui_Text(ctx, "Select Parameter:")
            if reaper.ImGui_BeginCombo(ctx, "##param_combo", param_list[selected_param_index] and param_list[selected_param_index].name or "No Parameter") then
                for i, param in pairs(param_list) do
                    if reaper.ImGui_Selectable(ctx, param.name, i == selected_param_index) then
                        selected_param_index = i
                        -- Sauvegarder immédiatement le changement de paramètre
                        SaveAutomationPrefs(automation_track, selected_fx_index, selected_param_index)
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            
            -- Configuration de la sensibilité
            reaper.ImGui_Text(ctx, "Sensitivity (% per semitone):")
            local changed
            changed, pitch_sensitivity = reaper.ImGui_SliderDouble(ctx, "##sensitivity", pitch_sensitivity, 0.1, 20.0, "%.1f%%")
            
            reaper.ImGui_Separator(ctx)
            
            -- Aperçu des valeurs
            reaper.ImGui_Text(ctx, "Preview:")
            reaper.ImGui_Text(ctx, string.format("  Pitch +12: %.1f%%", 50 + (12 * pitch_sensitivity)))
            reaper.ImGui_Text(ctx, string.format("  Pitch   0: %.1f%%", 50))
            reaper.ImGui_Text(ctx, string.format("  Pitch -12: %.1f%%", 50 - (12 * pitch_sensitivity)))
            
            reaper.ImGui_Separator(ctx)
            
            -- Boutons d'action
            if reaper.ImGui_Button(ctx, "Generate Automation") then
                if fx_list[selected_fx_index] and param_list[selected_param_index] then
                    local success = GeneratePitchAutomation(selected_fx_index, selected_param_index, pitch_sensitivity)
                    if success then
                        -- Sauvegarder les préférences pour cette piste
                        SaveAutomationPrefs(automation_track, selected_fx_index, selected_param_index)
                        -- Passer en mode succès au lieu d'afficher ShowMessageBox
                        automation_success_mode = true
                    else
                        reaper.ShowMessageBox("Failed to generate automation. Check FX and parameter selection.", "Error", 0)
                    end
                else
                    reaper.ShowMessageBox("Please select both an FX and a parameter.", "Error", 0)
                end
            end

            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Cancel") then
                show_automation_dialog = false
                automation_success_mode = false  -- S'assurer qu'on revient en mode formulaire
            end
        end
    end
    
    -- IMPORTANT: Toujours appeler End() après Begin(), même si visible est false
    reaper.ImGui_End(ctx)
    
    if not open then
        show_automation_dialog = false
        automation_success_mode = false  -- Remettre en mode formulaire si la fenêtre est fermée
    end
end

--------------------------------------------------------------------------------
-- Fonction pour afficher les notifications dans l'onglet Tools
--------------------------------------------------------------------------------
local function DrawToolsNotification()
    if not tools_notification_visible then return end
    
    reaper.ImGui_Separator(ctx)
    
    -- Déterminer la couleur selon le type
    local color
    if tools_notification_type == "success" then
        color = 0x00AA00FF  -- Vert
    elseif tools_notification_type == "error" then
        color = 0xFF0000FF  -- Rouge
    else
        color = 0x0080FFFF  -- Bleu (info)
    end
    
    -- Afficher le message avec la couleur appropriée
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
    reaper.ImGui_Text(ctx, tools_notification_message)
    reaper.ImGui_PopStyleColor(ctx)
    
    -- Boutons selon le contexte
    if tools_confirmation_pending == "update_all_blocks" then
        -- Boutons de confirmation pour l'update
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x127349FF)  -- Vert
        if reaper.ImGui_Button(ctx, "Confirm Update") then
            tools_notification_visible = false
            tools_confirmation_pending = ""
            UpdateAllBlocks()
        end
        reaper.ImGui_PopStyleColor(ctx)
        
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel") then
            tools_notification_visible = false
            tools_confirmation_pending = ""
            tools_notification_message = ""
        end
    else
        -- Bouton OK normal
        if reaper.ImGui_Button(ctx, "OK") then
            tools_notification_visible = false
            tools_notification_message = ""
        end
    end
    
    reaper.ImGui_Separator(ctx)
end

-- Fonction pour afficher une notification
local function ShowToolsNotification(message, type)
    tools_notification_message = message
    tools_notification_type = type or "success"
    tools_notification_visible = true
end

--------------------------------------------------------------------------------
-- Fonctions de dessin des onglets
--------------------------------------------------------------------------------
local function DrawLoopEditor()
    local item = reaper.GetSelectedMediaItem(0, 0)
    local take = item and reaper.GetActiveTake(item)
    local is_midi = take and reaper.TakeIsMIDI(take)
    
    -- Bouton pour basculer entre LIVE et PLAYBACK
    -- Définir les couleurs pour le bouton
    local button_color
    local button_text
    
    if playback_mode then
        -- Mode PLAYBACK: vert
        button_color = 0x22CC66EE -- Format ABGR: vert
        button_text = "PLAYBACK"
    else
        -- Mode LIVE: rouge
        --button_color = 0xFF0000EE -- Format ABGR: rouge
        button_color = 0xEB3440EE -- Format ABGR: rouge
        button_text = "LIVE"
    end
    
    -- Centrer le bouton et utiliser toute la largeur disponible
    local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
    local button_width = avail_width
    
    -- Définir la couleur du bouton
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), button_color)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), button_color + 0x00303030) -- Légèrement plus clair au survol
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), button_color + 0x00505050) -- Encore plus clair quand cliqué
    
    -- Rendre le bouton plus grand
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 10, 5)
    
    -- Créer le bouton
    if reaper.ImGui_Button(ctx, button_text, button_width, 0) then
        playback_mode = not playback_mode
        save_playback_mode(playback_mode)
    end
    
    -- Restaurer les styles
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    -- Ajouter un tooltip
    if reaper.ImGui_IsItemHovered(ctx) then
        if playback_mode then
            reaper.ImGui_SetTooltip(ctx, "Currently in PLAYBACK mode (read-only). Click to switch to LIVE mode.")
        else
            reaper.ImGui_SetTooltip(ctx, "Currently in LIVE mode. Click to switch to PLAYBACK mode (read-only).")
        end
    end
    
    reaper.ImGui_Separator(ctx)
    
    -- N'afficher l'éditeur que si on a un item MIDI
    if is_midi then
        if take ~= current_take then
            UpdateTakeData(take)
        end

        -- Affichage des informations MIDI
        if current_midi_note then
            reaper.ImGui_Text(ctx, string.format("MIDI note : %d (Velocity: %d)", current_midi_note, current_midi_velocity))
        else
            reaper.ImGui_Text(ctx, "No MIDI note found")
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
        
        reaper.ImGui_Text(ctx, string.format("Selected items : %d", #selected_items))
        if #selected_items > 1 and not all_same_track then
            reaper.ImGui_TextColored(ctx, 0xFF0000FF, "Warning : All the selected items must be on the same track!")
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
            local changed, new_name = reaper.ImGui_InputText(ctx, "Name", loop_name, 256)
            if changed then loop_name = trim(new_name) end

            if reaper.ImGui_RadioButton(ctx, "Mono", is_mono) then is_mono = true end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_RadioButton(ctx, "Stereo", not is_mono) then is_mono = false end

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Pan", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Vol (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            if reaper.ImGui_Checkbox(ctx, "Monitoring", monitoring == 1) then
                monitoring = (monitoring == 1) and 0 or 1
            end

        elseif loop_type == "PLAY" or loop_type == "OVERDUB" then
            local prev_loops = GetPreviousRecordLoopsInFolder(take)
            
            table.insert(prev_loops, 1, "(None)")
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
            
            if reaper.ImGui_BeginCombo(ctx, "Ref", prev_loops[sel_idx] or "(None)") then
                for i, name in ipairs(prev_loops) do
                    local is_sel = (sel_idx == i)
                    if reaper.ImGui_Selectable(ctx, name, is_sel) then
                        sel_idx = i
                        reference_loop = (name == "(None)") and "" or name
                    end
                    if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
                end
                reaper.ImGui_EndCombo(ctx)
            end

            if loop_type == "OVERDUB" then
                if reaper.ImGui_RadioButton(ctx, "Mono", is_mono) then is_mono = true end
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_RadioButton(ctx, "Stereo", not is_mono) then is_mono = false end
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
            if reaper.ImGui_RadioButton(ctx, "Stereo", not is_mono) then is_mono = false end

            local pan_changed, new_pan = reaper.ImGui_SliderDouble(ctx, "Pan", pan, -1.0, 1.0, "%.2f")
            if pan_changed then pan = new_pan end

            local vol_changed, new_vol = reaper.ImGui_SliderDouble(ctx, "Vol (dB)", volume_db, -20.0, 10.0, "%.2f")
            if vol_changed then volume_db = new_vol end

            monitoring = 1  -- Toujours ON pour MONITOR
            if reaper.ImGui_Checkbox(ctx, "Monitoring", true) then
                monitoring = 0
            end

        elseif loop_type == "UNUSED" then
            reaper.ImGui_Text(ctx, "This clip is labeled as UNUSED.")
        end


        -- Bouton Appliquer
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x127349FF )  -- Vert
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x1AA368FF)  -- Vert plus clair pour le hover
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xF7E47EFF)  -- Vert encore plus clair pour le clic
        
        if reaper.ImGui_Button(ctx, "Apply") then
            if #selected_items > 1 and not all_same_track then
                reaper.ShowMessageBox("All selected blocks must be on the same track.", "Error", 0)
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
                    reaper.ShowMessageBox("The selected items must be of the same type.", "Error", 0)
                    reaper.ImGui_PopStyleColor(ctx, 3)  -- Restaurer les couleurs avant de retourner
                    return
                end

                if not all_valid_type then
                    reaper.ShowMessageBox("Group modification is only allowed for PLAY and MONITOR types.", "Error", 0)
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
                        progress_message = string.format("Processing... (%d/%d)", current_item_index, #processing_items)
                        
                        if item_type == "PLAY" then
                            SetTakeMetadata(take, "loop_type", item_type)
                            SetTakeMetadata(take, "reference_loop", reference_loop)
                            SetTakeMetadata(take, "pan", tostring(pan))
                            SetTakeMetadata(take, "volume_db", tostring(volume_db))
                            SetTakeMetadata(take, "pitch", tostring(pitch))
                            SetTakeMetadata(take, "monitoring", tostring(monitoring))
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
                        -- Traitement terminé - déclencher la réinitialisation du plugin et effacer le message
                        if #processing_items > 0 then
                            local track = processing_items[1].track  -- Toutes les items sont sur la même piste
                            reset_poulpyloop_plugin(track)
                        end
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
                    reaper.ShowMessageBox(message, "Error", 0)
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
                    local track = reaper.GetMediaItemTake_Track(take)
                    ProcessMIDINotes(track)
                    -- Réinitialiser le plugin après modification
                    reset_poulpyloop_plugin(track)
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
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)
                -- Réinitialiser le plugin après modification
                reset_poulpyloop_plugin(track)

            elseif loop_type == "PLAY" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "reference_loop", reference_loop)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "pitch", tostring(pitch))
                SetTakeMetadata(take, "monitoring", tostring(monitoring))
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.PLAY)
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)
                UnfoldPlayLoop(take)
                -- Réinitialiser le plugin après modification
                reset_poulpyloop_plugin(track)

            elseif loop_type == "MONITOR" then
                SetTakeMetadata(take, "loop_type", loop_type)
                SetTakeMetadata(take, "pan", tostring(pan))
                SetTakeMetadata(take, "volume_db", tostring(volume_db))
                SetTakeMetadata(take, "is_mono", tostring(is_mono))
                SetTakeMetadata(take, "monitoring", "1")  -- Toujours ON
                -- Sauvegarder les valeurs des paramètres de modulation

                reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLORS.MONITOR)
                local track = reaper.GetMediaItemTake_Track(take)
                ProcessMIDINotes(track)
                -- Réinitialiser le plugin après modification
                reset_poulpyloop_plugin(track)

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
                -- Réinitialiser le plugin après modification
                reset_poulpyloop_plugin(track)
            end
        end
        reaper.ImGui_PopStyleColor(ctx, 3)  -- Restaurer les couleurs

        -- Bouton "Insérer clic" à droite du bouton "Appliquer"
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xAB47BCFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00AA40FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x008000FF)
        
        if reaper.ImGui_Button(ctx, "Insert click") then
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

        -- Bouton "Update Pitch Automation" à droite du bouton "Insert click"
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00BFFFEE)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x40CAFFEE)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x008BFFEE)
        
        if reaper.ImGui_Button(ctx, "Update Pitch Automation") then
            if item and take and is_midi then
                automation_track = reaper.GetMediaItemTake_Track(take)
                RefreshFXList()
                show_automation_dialog = true
            end
        end
        
        reaper.ImGui_PopStyleColor(ctx, 3)

        -- Afficher le message de progression s'il existe
        if progress_message ~= "" then
            reaper.ImGui_Text(ctx, progress_message)
        end
    else
        reaper.ImGui_Text(ctx, "No MIDI item selected.")
    end
end

local function DrawOptions()
    -- S'assurer que les id d'instance restent alignes avec la numerotation utilisee
    -- ci-dessous pour le monitoring a l'arret (C3/C4). N'ecrit que si un id a change.
    core.AssignInstanceIds()

    -- Partie 1: Options d'enregistrement
    reaper.ImGui_Text(ctx, "Recording options :")
    reaper.ImGui_Separator(ctx)

    -- Radio buttons pour l'enregistrement des loops MONITOR
    reaper.ImGui_Text(ctx, "Record MONITOR blocks :")
    local changed = false
    local new_record_monitor_loops = record_monitor_loops
    if reaper.ImGui_RadioButton(ctx, "ON", record_monitor_loops) then
        new_record_monitor_loops = true
        changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "MONITOR blocks are recorded as RECORD blocks. Useful for later mix.")
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "OFF", not record_monitor_loops) then
        new_record_monitor_loops = false
        changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "MONITOR blocks are not recorded. Ideal for live performances to save memory.")
    end

    -- Si le mode a changé, on le sauvegarde
    if changed then
        record_monitor_loops = new_record_monitor_loops
        save_record_monitor_loops_mode(record_monitor_loops)
    end

    reaper.ImGui_Separator(ctx)

    -- Radio buttons pour le mode LIVE/PLAYBACK
    reaper.ImGui_Text(ctx, "Operation mode :")
    local mode_changed = false
    local new_playback_mode = playback_mode
    if reaper.ImGui_RadioButton(ctx, "LIVE", not playback_mode) then
        new_playback_mode = false
        mode_changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Normal recording and playback mode. Loops can be modified.")
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "PLAYBACK", playback_mode) then
        new_playback_mode = true
        mode_changed = true
    end
    
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "All loops are read-only. No recording is possible. Ideal for replaying a project.")
    end

    -- Si le mode a changé, on le sauvegarde
    if mode_changed then
        playback_mode = new_playback_mode
        save_playback_mode(playback_mode)
    end

    reaper.ImGui_Separator(ctx)

    -- Partie 2: Monitoring à l'arrêt
    reaper.ImGui_Text(ctx, "Monitoring when stopped for PoulpyLoop tracks :")
    reaper.ImGui_Separator(ctx)

    -- Tableau pour afficher les pistes avec PoulpyLoop
    reaper.ImGui_BeginTable(ctx, "monitoring_table", 2, reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg())
    reaper.ImGui_TableSetupColumn(ctx, "Piste", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Monitoring when stopped", reaper.ImGui_TableColumnFlags_WidthFixed(), 150)
    reaper.ImGui_TableHeadersRow(ctx)

    -- Parcourir toutes les pistes
    local num_tracks = reaper.CountTracks(0)
    local poulpy_track_index = 0  -- Nouveau compteur pour les pistes avec PoulpyLoop
    
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if track then  -- Vérifier que la piste existe
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

            -- Afficher la piste même si elle n'a pas de PoulpyLoop
            reaper.ImGui_TableNextRow(ctx)
            
            -- Nom de la piste
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, track_name)

            -- Case à cocher pour le monitoring à l'arrêt
            reaper.ImGui_TableNextColumn(ctx)
            local monitoring_stop = false
            
            -- Ne lire la valeur de gmem que pour les pistes avec PoulpyLoop
            if has_poulpyloop then
                monitoring_stop = reaper.gmem_read(GMEM.MONITORING_STOP_BASE + poulpy_track_index) == 1
            end
            
            local checkbox_id = "##monitoring_stop_" .. i
            
            -- Si la piste n'a pas de PoulpyLoop, désactiver la case à cocher
            if not has_poulpyloop then
                reaper.ImGui_BeginDisabled(ctx)
            end
            
            if reaper.ImGui_Checkbox(ctx, checkbox_id, monitoring_stop) then
                -- Mettre à jour slider3 pour toutes les instances de PoulpyLoop sur cette piste
                if has_poulpyloop then  -- Ne mettre à jour que si la piste a PoulpyLoop
                    local new_value = monitoring_stop and 0 or 1
                    -- Mettre à jour la valeur dans gmem
                    reaper.gmem_write(GMEM.MONITORING_STOP_BASE + poulpy_track_index, new_value)
                    
                    -- Mettre à jour le paramètre du plugin
                    local fx_count = reaper.TrackFX_GetCount(track)
                    for j = 0, fx_count - 1 do
                        local retval, fx_name = reaper.TrackFX_GetFXName(track, j, "")
                        if fx_name:find("PoulpyLoop") then
                            reaper.TrackFX_SetParam(track, j, 2, new_value) -- slider3 est le paramètre d'index 2
                        end
                    end
                end
            end
            
            if not has_poulpyloop then
                reaper.ImGui_EndDisabled(ctx)
                if reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx, "This track does not contain a PoulpyLoop plugin")
                end
            else
                if reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx, "When this option is enabled, the input signal is routed to the outputs when playback is stopped.")
                end
                poulpy_track_index = poulpy_track_index + 1  -- Incrémenter le compteur uniquement pour les pistes avec PoulpyLoop
            end
        end
    end

    reaper.ImGui_EndTable(ctx)
end

local function RenderSelection()
    -- Vérifier qu'il y a au moins un item sélectionné
    local sel_count = reaper.CountSelectedMediaItems(0)
    if sel_count == 0 then
        reaper.ShowMessageBox("No block selected.", "Error", 0)
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
        reaper.SNM_SetIntConfigVar("projrendersrate", 2)     -- 2 = stereo (attention: nom trompeur!)
        reaper.SNM_SetIntConfigVar("projrendernch", 0)       -- 0 = project sample rate (attention: nom trompeur!)
        reaper.SNM_SetIntConfigVar("projrenderlimit", render_realtime and 4 or 0)  -- 4 = offline render (idle), 0 = full speed
        reaper.SNM_SetIntConfigVar("renderclosewhendone", 1) -- 1 = close when done
        reaper.SNM_SetIntConfigVar("renderaddtoproj", 1)     -- 1 = add rendered items to project
        
        -- Options supplémentaires pour assurer un bon rendu
        reaper.SNM_SetIntConfigVar("projrenderrateinternal", 1) -- 1 = use project sample rate for mixing
        reaper.SNM_SetIntConfigVar("projrenderresample", 4)     -- 4 = better quality (384pt Sinc)

                
        reaper.PreventUIRefresh(-1)


        -- Lancer le rendu
        reaper.Main_OnCommand(41824, 0) -- Render project, using the most recent render settings
        
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
    -- Vérifier que le take est valide
    if not take or not reaper.ValidatePtr2(0, take, "MediaItem_Take*") then
        return
    end
    
    local item = reaper.GetMediaItemTake_Item(take)
    if not item then
        return
    end
    
    -- Récupérer directement les métadonnées sans passer par les variables globales
        local loop_type = GetTakeMetadata(take, "loop_type")
    if not loop_type or loop_type == "" then
        return
    end
    
                local track = reaper.GetMediaItemTake_Track(take)
    if not track then
        return
    end
    
    -- Appliquer directement ProcessMIDINotes sur la piste pour régénérer les MIDI
    ProcessMIDINotes(track)
end

-- Fonction pour mettre à jour tous les blocs du projet
local function UpdateAllBlocks()
    -- I4 : refuser pendant la lecture/enregistrement (reecriture MIDI lourde)
    if core.IsTransportActive() then
        ShowToolsNotification("⚠️ Stop playback/recording before updating all blocks.", "error")
        return
    end
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
                if item then
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
    end
    
    -- Si aucun bloc à traiter, on s'arrête
    if #blocks_to_process == 0 then
        ShowToolsNotification("ℹ️ No blocks to update.", "info")
        return
    end
    
    -- Variables pour le suivi de la progression
    local total_blocks = #blocks_to_process
    local processed_blocks = 0
    
    -- Fonction pour traiter le prochain bloc
    local function ProcessNextBlock()
        if processed_blocks >= total_blocks then
            -- Traitement terminé
            progress_message = ""
            ShowToolsNotification("✅ Update completed! All blocks have been updated successfully.", "success")
            -- Restaurer la sélection originale
            for _, sel_item in ipairs(old_sel_items) do
                reaper.SetMediaItemSelected(sel_item, true)
            end
            return
        end
        
        -- Traiter le bloc actuel
        local block = blocks_to_process[processed_blocks + 1]
        if block and block.take then
        UpdateBlock(block.take)
        end
        
        -- Mettre à jour le compteur et le message
        processed_blocks = processed_blocks + 1
        progress_message = string.format("Updating blocks... (%d/%d)", processed_blocks, total_blocks)
        
        -- Programmer le traitement du prochain bloc
        reaper.defer(ProcessNextBlock)
    end
    
    -- Démarrer le traitement
    progress_message = "Starting update..."
    ProcessNextBlock()
end

local function DrawTools()
    -- Partie 1: Outils de base
    reaper.ImGui_Text(ctx, "Basic tools :")
    reaper.ImGui_Separator(ctx)
    
    reaper.ImGui_Text(ctx, "Audio input for Looper :")
    drawRecInputCombo()

    if reaper.ImGui_Button(ctx, "Add looper") then
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
    reaper.ImGui_Text(ctx, "Audio rendering :")
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
    
    -- Partie 3: Préparation MIDI
    reaper.ImGui_Text(ctx, "MIDI preparation :")
    reaper.ImGui_Separator(ctx)
    
    if reaper.ImGui_Button(ctx, "Prepare for PoulpyLoopy") then
        if core.IsTransportActive() then
            ShowToolsNotification("⚠️ Stop playback/recording before preparing (heavy MIDI rewrite).", "error")
        else
            core.ProcessMIDINotes()
            ShowToolsNotification("✅ PoulpyLoopy preparation completed successfully!", "success")
        end
    end

    reaper.ImGui_Separator(ctx)
    
    -- Partie 5: Mise à jour globale
    reaper.ImGui_Text(ctx, "Global update :")
    reaper.ImGui_Separator(ctx)
    
    -- Bouton avec style spécial pour la mise à jour globale
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xAB47BCFF)  -- Violet
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xBA68C8FF)  -- Violet plus clair
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x9C27B0FF)  -- Violet plus foncé
    
    if reaper.ImGui_Button(ctx, "Update all blocks") then
        -- Demander confirmation via ImGui
        ShowToolsNotification(
            "⚠️ This operation will update all project blocks to be compatible with the latest version.\n" ..
            "This can take some time depending on project size.\n\n" ..
            "Click 'Confirm Update' below to proceed.",
            "info"
        )
        -- Marquer qu'on attend une confirmation pour l'update
        tools_confirmation_pending = "update_all_blocks"
    end
    
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    if progress_message ~= "" then
        reaper.ImGui_Text(ctx, progress_message)
    end
    
    reaper.ImGui_Separator(ctx)
    
    -- Afficher les notifications s'il y en a
    DrawToolsNotification()
end



--------------------------------------------------------------------------------
-- Fonctions pour calculer la hauteur nécessaire pour chaque onglet
-- (calculateRequiredHeight et calculateTabsHeight, doublons inutilises, retires - M5)
--------------------------------------------------------------------------------
local function calculateLoopEditorHeight()
    local base_height = 55  -- Hauteur de base pour les éléments fixes
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
        

        
        -- Ajouter la hauteur pour le bouton Appliquer et le message de progression
        content_height = content_height + (2 * item_height)
    else
        -- Si aucun take n'est sélectionné
        content_height = content_height + item_height
    end
    
    return math.max(270, content_height)
end

local function calculateOptionsHeight()
    local base_height = 60
    local item_height = 22
    local content_height = base_height
    
    -- Radio buttons et séparateurs de base
    content_height = content_height + (6 * item_height)
    
    -- Ajouter de l'espace pour chaque piste du projet
    local num_tracks = reaper.CountTracks(0)
    content_height = content_height + (num_tracks * item_height)
    
    -- Ajouter une marge supplémentaire pour la lisibilité
    content_height = content_height + 50
    
    return math.max(200, content_height)
end

local function calculateToolsHeight()
    local base_height = 150
    local item_height = 22
    local content_height = base_height
    
    -- Boutons, séparateurs et contrôles
    content_height = content_height + (12 * item_height)
    
    return math.max(300, content_height)
end

--------------------------------------------------------------------------------
-- Fenêtre principale
--------------------------------------------------------------------------------
local function DrawMainWindow()
    -- Charger les valeurs depuis gmem au début de chaque frame
    record_monitor_loops = get_record_monitor_loops_mode()
    playback_mode = get_playback_mode()

    reaper.ImGui_SetNextWindowPos(ctx, 100, 50, reaper.ImGui_Cond_FirstUseEver())
    
    local visible, open = reaper.ImGui_Begin(ctx, "PoulpyLoopy v" .. VERSION, true)
    if visible then
        -- Vérifier si un champ de texte est actif
        local textInputActive = reaper.ImGui_IsAnyItemActive(ctx)
        
        -- Si aucun champ de texte n'est actif, transmettre les touches
        if not textInputActive then
            -- Barre d'espace pour Play/Stop
            if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
                reaper.Main_OnCommand(40044, 0) -- Play/stop
            end
            
            -- Touche Home
            if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Home()) then
                reaper.Main_OnCommand(40042, 0) -- Aller au début
            end

            -- Touche 1 start of loop
            if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Keypad1()) then
                reaper.Main_OnCommand(40632, 0) -- Aller au début de la boucle
            end

            -- Touche 2 end of loop
            if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Keypad2()) then
                reaper.Main_OnCommand(40633, 0) -- Aller à la fin de la boucle
            end
            
            -- Autres touches de contrôle courantes
            if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
                reaper.Main_OnCommand(1016, 0) -- Stop
            end
            

        end
    
        -- Sauvegarder la largeur de la fenêtre si elle a été redimensionnée
        local current_width = reaper.ImGui_GetWindowWidth(ctx)
        if current_width ~= window_width then
            window_width = current_width
            reaper.SetExtState("PoulpyLoopy", "window_width", tostring(window_width), true)
        end
        
        -- Déterminer l'onglet actif et calculer la hauteur
        local active_tab = "Loop Editor"  -- Onglet par défaut
        local new_height
        
        if reaper.ImGui_BeginTabBar(ctx, "MainTabs") then
            -- Onglet "Loop Editor"
            if reaper.ImGui_BeginTabItem(ctx, "Loop Editor") then
                active_tab = "Loop Editor"
                DrawLoopEditor()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Options"
            if reaper.ImGui_BeginTabItem(ctx, "Options") then
                active_tab = "Options"
                DrawOptions()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglet "Tools"
            if reaper.ImGui_BeginTabItem(ctx, "Tools") then
                active_tab = "Tools"
                DrawTools()
                reaper.ImGui_EndTabItem(ctx)
            end
            
            -- Onglets masqués temporairement
            --[[
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
            ]]--
            
            reaper.ImGui_EndTabBar(ctx)
            
            -- Calculer la hauteur après avoir déterminé l'onglet actif
            if active_tab == "Loop Editor" then
                new_height = calculateLoopEditorHeight()
            elseif active_tab == "Options" then
                new_height = calculateOptionsHeight()
            elseif active_tab == "Tools" then
                new_height = calculateToolsHeight()
            end
            
            -- Appliquer la nouvelle hauteur si nécessaire
            if new_height and new_height ~= window_height then
                window_height = new_height
                reaper.ImGui_SetWindowSize(ctx, window_width, window_height)
            end
        end
        
        if reaper.ImGui_Button(ctx, "Close window") then
            open = false
        end
    end
    
    reaper.ImGui_End(ctx)
    
    -- Dessiner le dialogue d'automation (fenêtre séparée)
    DrawAutomationDialog()
    
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