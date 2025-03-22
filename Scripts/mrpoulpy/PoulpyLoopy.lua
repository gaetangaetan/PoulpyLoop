--[[------------------------------------------------------------------------------
  PoulpyLoopy + ALK2REAPER (Version avec Assignation de Notes Uniques)
  ------------------------------------------------------------------------------
  FONCTIONNALITES :

  A) Importation d'un projet ALK :
     - Creer des pistes
     - Creer des items MIDI
     - P_EXT:loop_type = RECORD / PLAY / MONITOR ( etc. )
     - P_EXT:loop_name = "02 HH1", p.ex.
     - P_EXT:pitch = pitchChgSemis
     => Les noms des takes incluent le prefixe piste ("02 HH1"), etc.

  B) Bouton "Ajouter Looper" (mono ou stéréo) :
     - Crée un folder "LOOPER" 
     - Déplace les pistes sélectionnées en children
     - Armer rec, monitoring ON
     - Mémorise looperUsage[trackGUID] = "mono"/"stereo"

  C) "Préparer pour PoulpyLoopy" :
     - Parcourt tous les items MIDI, par ordre de folder / par ordre temps
     - Pour chaque folder, on maintient un compteur de notes unique
       initialisé à 1 (note MIDI #1 => C#-1).
       Si on change de folder, on réinitialise ce compteur.
     - Pour un item RECORD -> on attribue la note du compteur => vélocité=1, puis on incrémente
     - Pour un item PLAY -> on retrouve la note de la loop RECORD correspondante => vélocité=2
     - Pour un item OVERDUB -> idem, note de la ref => vélocité=3
     - Pour un item MONITOR -> on attribue la note du compteur => vélocité=4, puis on incrémente
     - La note 0 (C-1) est réservée pour usage futur
     - La note s'étend sur toute la durée (start..end) du media item

  D) Fenêtre "Options de loop" (ImGui) :
     - Permet de modifier loop_type, loop_name, pitch, reference_loop, etc.
     - Si loop_type = PLAY ou OVERDUB, on affiche un combo "Loop de référence" 
       qui liste les loops RECORD situées "avant" dans le folder
--]]------------------------------------------------------------------------------

local reaper = reaper
local ctx = reaper.ImGui_CreateContext("PoulpyLoopy")

--------------------------------------------------------------------------------
-- Contrôle de l'affichage des messages dans la console
--------------------------------------------------------------------------------
-- Même constante que dans PoulpyLoopyService.lua
local GMEM_AFFICHAGE_CONSOLE_DEBUG = 17100

-- Fonction pour afficher des messages dans la console uniquement si activé
local function debug_console(message)
    if reaper.gmem_read(GMEM_AFFICHAGE_CONSOLE_DEBUG) == 1 then
        reaper.ShowConsoleMsg(message)
    end
end

--------------------------------------------------------------------------------
-- Vérification et démarrage du service
--------------------------------------------------------------------------------
local service_running = reaper.GetExtState("PoulpyLoopyService", "running")
if service_running ~= "1" then
  -- Le service n'est pas en cours d'exécution, on le démarre
  debug_console("PoulpyLoopy: Tentative de démarrage de PoulpyLoopyService...\n")
  
  -- Lancer le script de service en tant que script séparé
  local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/PoulpyLoopyService.lua"
  debug_console("Chemin du script: " .. script_path .. "\n")
  
  -- Vérifier si ReaScriptAPI est disponible
  if reaper.APIExists("ReaScriptAPI_LoadScript") then
    debug_console("Méthode de lancement: ReaScriptAPI_LoadScript\n")
    local result = reaper.ReaScriptAPI_LoadScript(script_path, true) -- true = async (en arrière-plan)
    debug_console("Résultat du lancement: " .. tostring(result) .. "\n")
  else
    -- Méthode alternative si ReaScriptAPI n'est pas disponible
    debug_console("Méthode de lancement: AddRemoveReaScript\n")
    
    -- Obtenir le Command ID dynamiquement
    local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
    if cmd_id > 0 then
      debug_console("Command ID obtenu: " .. tostring(cmd_id) .. "\n")
      reaper.Main_OnCommand(cmd_id, 0)
    else
      debug_console("ERREUR: Impossible d'obtenir le Command ID pour " .. script_path .. "\n")
      debug_console("Vérifiez que le fichier existe et que SWS est installé.\n")
    end
  end
  
  -- Vérifier après un court délai si le service a démarré
  reaper.defer(function()
    local timeout = 30 -- Attendre maximum 3 secondes (10 vérifications/seconde)
    local check_interval = 0.1
    
    local function check_service_started()
      timeout = timeout - 1
      local is_running = reaper.GetExtState("PoulpyLoopyService", "running")
      
      if is_running == "1" then
        debug_console("PoulpyLoopyService démarré avec succès!\n")
      elseif timeout > 0 then
        reaper.defer(check_service_started)
      else
        debug_console("ERREUR: PoulpyLoopyService n'a pas démarré après 3 secondes.\n")
        debug_console("Vérifiez que le fichier existe et que SWS/ReaScriptAPI est installé.\n")
      end
    end
    
    reaper.defer(check_service_started)
  end)
else
  debug_console("PoulpyLoopy: PoulpyLoopyService est déjà en cours d'exécution.\n")
end

-- Pour les opérations locales, on se connecte aussi à gmem
reaper.gmem_attach("PoulpyLoopy")

--------------------------------------------------------------------------------
-- Constantes globales
--------------------------------------------------------------------------------
local VERSION = "0014"

--------------------------------------------------------------------------------
-- Variables globales pour Options de Loop
--------------------------------------------------------------------------------
local loop_types = {"RECORD", "OVERDUB", "PLAY", "MONITOR", "UNUSED"}
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
local selected_click_track_index = 0  -- Pour le menu déroulant des pistes de clic

--------------------------------------------------------------------------------
-- Variables globales pour le Mode
--------------------------------------------------------------------------------
local record_monitor_loops = false  -- Par défaut, on n'enregistre pas les loops MONITOR
local playback_mode = false         -- Par défaut, on est en mode LIVE (false = LIVE, true = PLAYBACK)
local last_message_check = 0        -- Pour limiter la fréquence de lecture des messages
local message_history = {}          -- Table pour stocker l'historique des messages
local MAX_HISTORY_LINES = 20        -- Nombre maximum de lignes à conserver

-- Indices gmem pour les modes
local GMEM_RECORD_MONITOR_MODE = 0  -- gmem[0] pour le mode d'enregistrement des loops MONITOR
local GMEM_PLAYBACK_MODE = 1        -- gmem[1] pour le mode LIVE/PLAYBACK
local GMEM_STATS_BASE = 2           -- gmem[2] à gmem[2+64*3-1] pour les statistiques (64 instances max)
local GMEM_NEXT_INSTANCE_ID = 194   -- gmem[194] pour le prochain ID d'instance disponible
local GMEM_MONITORING_STOP_BASE = 195  -- gmem[195] à gmem[195+64-1] pour le monitoring à l'arrêt (64 instances max)
local GMEM_NOTE_START_POS_BASE = 259  -- gmem[259] à gmem[259+64*128-1] pour les positions de début des notes (64 instances * 128 notes)
local GMEM_LOOP_LENGTH_BASE = 8451    -- gmem[8451] à gmem[8451+64*128-1] pour les longueurs des boucles en secondes (64 instances * 128 notes)

-- Nouveaux indices pour la synchronisation MIDI
local GMEM_FORCE_ANALYZE = 16000     -- gmem[16000] pour forcer l'analyse des offsets (1 = forcer)
local GMEM_MIDI_SYNC_DATA_BASE = 16001 -- gmem[16001] à gmem[16001+64*3-1] pour les données de synchronisation MIDI (64 pistes max)

-- Contrôle de l'affichage console du service
local GMEM_AFFICHAGE_CONSOLE_DEBUG = 17100  -- gmem[17100] pour contrôler l'affichage des messages dans la console (0 = désactivé, 1 = activé)

-- Espace pour les messages dans gmem
local GMEM_MESSAGE_BASE = 17000      -- gmem[17000] à gmem[17000+9999] pour les messages (10000 caractères)
local GMEM_MESSAGE_LENGTH = 16999     -- gmem[16999] pour la longueur du message actuel

-- Fonction pour charger le mode d'enregistrement des loops MONITOR depuis la mémoire de Reaper
local function loadRecordMonitorLoopsMode()
    record_monitor_loops = reaper.gmem_read(GMEM_RECORD_MONITOR_MODE) == 1
end

-- Fonction pour sauvegarder le mode d'enregistrement des loops MONITOR dans la mémoire de Reaper
local function saveRecordMonitorLoopsMode()
  reaper.gmem_write(GMEM_RECORD_MONITOR_MODE, record_monitor_loops and 1 or 0)
end

-- Fonction pour charger le mode LIVE/PLAYBACK depuis la mémoire de Reaper
local function loadPlaybackMode()
    playback_mode = reaper.gmem_read(GMEM_PLAYBACK_MODE) == 1
end

-- Fonction pour sauvegarder le mode LIVE/PLAYBACK dans la mémoire de Reaper
local function savePlaybackMode()
    reaper.gmem_write(GMEM_PLAYBACK_MODE, playback_mode and 1 or 0)
end

-- Fonction pour récupérer le mode LIVE/PLAYBACK
local function get_playback_mode()
    return reaper.gmem_read(GMEM_PLAYBACK_MODE) == 1
end

-- Charger les valeurs au démarrage
loadRecordMonitorLoopsMode()
loadPlaybackMode()

--------------------------------------------------------------------------------
-- Données globales : looperUsage[trackGUID]="mono"/"stereo"
--------------------------------------------------------------------------------
local looperUsage = {}

--------------------------------------------------------------------------------
-- A) Menu d'entrées audio
--------------------------------------------------------------------------------
local recInputOptions = {}
local selectedRecInputOption = 1

local function buildRecInputOptions()
  recInputOptions = {}
  -- Option "None"
  table.insert(recInputOptions, { label="None", iRecInput=0 })

  local maxAudioCh = reaper.GetNumAudioInputs()
  if maxAudioCh <= 0 then
    return
  end

  local channelNames = {}
  for i=0, maxAudioCh-1 do
    local retval, chName = reaper.GetInputChannelName(i, 0)
    if not retval or chName == "" then
      chName = "ch " .. (i+1)
    end
    channelNames[i] = chName
  end

  -- Mono
  for i=0, maxAudioCh-1 do
    local label = "Mono: " .. (channelNames[i] or ("ch " .. (i+1)))
    local iRec  = i
    table.insert(recInputOptions,{
      label=label, 
      iRecInput=iRec, 
      isMono=true
    })
  end

  -- Stéréo
  for i=0, maxAudioCh-2 do
    local c1= channelNames[i]   or ("ch " .. (i+1))
    local c2= channelNames[i+1] or ("ch " .. (i+2))
    local label = "Stereo: " .. c1 .. " / " .. c2
    local iRec  = (i | 1024)
    table.insert(recInputOptions,{
      label=label,
      iRecInput=iRec,
      isStereo=true
    })
  end
end

buildRecInputOptions()

local function getCurrentRecInputOption()
  return recInputOptions[selectedRecInputOption] or recInputOptions[1]
end

local function getCurrentRecInputLabel()
  return getCurrentRecInputOption().label
end

local function drawRecInputCombo()
  local label = getCurrentRecInputLabel()
  if reaper.ImGui_BeginCombo(ctx, "Entrée Audio", label) then
    for i,opt in ipairs(recInputOptions) do
      local isSel=(selectedRecInputOption==i)
      if reaper.ImGui_Selectable(ctx,opt.label, isSel) then
        selectedRecInputOption= i
      end
      if isSel then
        reaper.ImGui_SetItemDefaultFocus(ctx)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
end

--------------------------------------------------------------------------------
-- B) Couleurs & Utilitaires
--------------------------------------------------------------------------------
local colorRecord     = reaper.ColorToNative(235,64,52)  + 0x1000000
local colorPlay       = reaper.ColorToNative(49,247,108) + 0x1000000
local colorMonitorRef = reaper.ColorToNative(255,165,0)  + 0x1000000

local colorOverdub    = reaper.ColorToNative(32,241,245) + 0x1000000
local colorMonitor    = reaper.ColorToNative(247,188,49) + 0x1000000
local colorUnused     = reaper.ColorToNative(0,0,0)      + 0x1000000
local colorAutomation = reaper.ColorToNative(128,128,128)+ 0x1000000

local colorClickMuted = reaper.ColorToNative(0,0,255)    + 0x1000000  -- Bleu
local colorClickActive= reaper.ColorToNative(255,192,203)+ 0x1000000  -- Rose
local colorClickNoAuto= reaper.ColorToNative(0,0,0)     + 0x1000000  -- Noir

local customColors = {
  [0] = colorOverdub,
  [1] = colorOverdub,
  [2] = colorPlay,
  [3] = colorMonitor,
  [4] = colorUnused,
  [5] = colorAutomation
}

-- Partition de la timeline
local signatureSections = {
  { startBeat=0,   endBeat=840,   sigNum=3, sigDenom=4 },
  { startBeat=840, endBeat=1200,  sigNum=4, sigDenom=4 },
  { startBeat=1200,endBeat=999999,sigNum=4, sigDenom=4 }
}

local function ComputeMeasureBeatFromGlobalBeat(globalBeat, sections)
  local leftover = globalBeat
  local measureCount=0
  for _,sec in ipairs(sections) do
    local sectionLen= sec.endBeat - sec.startBeat
    if leftover < sectionLen then
      local fullM= math.floor(leftover/sec.sigNum)
      measureCount= measureCount+fullM
      local beatIn= leftover % sec.sigNum
      return measureCount, beatIn, sec.sigNum, sec.sigDenom
    else
      local f= math.floor(sectionLen / sec.sigNum)
      measureCount= measureCount+ f
      leftover= leftover - sectionLen
    end
  end
  local last= sections[#sections]
  local measureSize= last.sigNum
  local f= math.floor(leftover / measureSize)
  measureCount= measureCount+ f
  local b= leftover % measureSize
  return measureCount, b, last.sigNum, last.sigDenom
end

local function readFile(path)
  local f= io.open(path,"r")
  if not f then return nil, "Impossible d'ouvrir le fichier" end
  local c= f:read("*all")
  f:close()
  return c
end

--------------------------------------------------------------------------------
-- Fonctions d'aide de base
--------------------------------------------------------------------------------
local function IsStringEmptyOrWhitespace(str)
    return str == nil or str:match("^%s*$") ~= nil
end

function string.trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function containsValue(tbl, val)
    for _, v in ipairs(tbl) do
        if v == val then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- MÉTADONNÉES DU PROJET
--------------------------------------------------------------------------------
local function SetProjectMetadata(section, key, value)
    reaper.SetProjExtState(0, section, key, value)
end

local function GetProjectMetadata(section, key)
    local _, value = reaper.GetProjExtState(0, section, key)
    return value
end

--------------------------------------------------------------------------------
-- MÉTADONNÉES DE TAKE (avec préfixe "P_EXT:")
--------------------------------------------------------------------------------
local function SetTakeMetadata(take, key, value)
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:" .. key, tostring(value), true)
end

local function GetTakeMetadata(take, key)
    local retval, val = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:" .. key, "", false)
    return retval and val or nil
end


local function ProcessMIDINotes()
  local noteCounters = {}         -- par piste (clé = track_id)
  local recordLoopPitches = {}    -- par piste: mapping { loop_name -> pitch }
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
                          table.insert(allTakes, { take = take, item = item, start_time = reaper.GetMediaItemInfo_Value(item, "D_POSITION"), loop_type = loop_type, track = track })
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
  
  -- Dernière étape : déplier les loops PLAY/OVERDUB qui sont plus longues que leur référence
  local loopsToUnfold = {}
  local referenceLoopLengths = {}
  
  -- 1. Collecte des informations sur toutes les loops RECORD pour référence
  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      if item then
        for j = 0, reaper.CountTakes(item) - 1 do
          local take = reaper.GetTake(item, j)
          if take and reaper.TakeIsMIDI(take) then
            local loop_type = GetTakeMetadata(take, "loop_type")
            local loop_name = GetTakeMetadata(take, "loop_name") or ""
            if loop_type == "RECORD" and loop_name ~= "" then
              local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
              referenceLoopLengths[loop_name] = item_length
            end
          end
        end
      end
    end
  end
  
  -- 2. Identifier les loops PLAY/OVERDUB qui sont plus longues que leur référence
  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      if item then
        for j = 0, reaper.CountTakes(item) - 1 do
          local take = reaper.GetTake(item, j)
          if take and reaper.TakeIsMIDI(take) then
            local loop_type = GetTakeMetadata(take, "loop_type")
            if loop_type == "PLAY" or loop_type == "OVERDUB" then
              local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
              if reference_loop ~= "" and referenceLoopLengths[reference_loop] then
                local play_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                local ref_length = referenceLoopLengths[reference_loop]
                
                -- Si la loop PLAY est plus longue que sa référence (sans aucune tolérance)
                if play_length > ref_length then
                  table.insert(loopsToUnfold, {
                    item = item,
                    take = take,
                    track = track,
                    ref_length = ref_length,
                    play_length = play_length,
                    play_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                    loop_type = loop_type,
                    reference_loop = reference_loop
                  })
                end
              end
            end
          end
        end
      end
    end
  end
  
  -- 3. Déplier les loops identifiées
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  
  local createdItems = {} -- Garder la trace des items créés pour éviter la boucle infinie
  
  -- ID de commande pour l'action "Duplicate items"
  local DUPLICATE_ITEMS_COMMAND_ID = 41295
  
  for _, loop in ipairs(loopsToUnfold) do
    local ratio = loop.play_length / loop.ref_length
    local full_copies = math.floor(ratio)
    local partial_length = loop.play_length - (full_copies * loop.ref_length)
    local current_position = loop.play_position
    
    -- Réduire la taille de la loop originale
    reaper.SetMediaItemInfo_Value(loop.item, "D_LENGTH", loop.ref_length)
    
    -- Pour chaque copie complète (sauf la première qui est déjà l'item original)
    for i = 1, full_copies - 1 do
      current_position = current_position + loop.ref_length
      
      -- Méthode alternative pour dupliquer l'item en utilisant l'action de REAPER
      local new_item = nil
      
      -- Sauvegarder la sélection actuelle
      local old_sel_items = {}
      for s = 0, reaper.CountSelectedMediaItems(0) - 1 do
        old_sel_items[s+1] = reaper.GetSelectedMediaItem(0, s)
      end
      
      -- Désélectionner tous les items
      for _, item in ipairs(old_sel_items) do
        reaper.SetMediaItemSelected(item, false)
      end
      
      -- Sélectionner l'item à dupliquer
      reaper.SetMediaItemSelected(loop.item, true)
      
      -- Dupliquer en utilisant la commande native de REAPER
      reaper.Main_OnCommand(DUPLICATE_ITEMS_COMMAND_ID, 0)
      
      -- Récupérer l'item dupliqué (c'est maintenant le seul item sélectionné)
      if reaper.CountSelectedMediaItems(0) > 0 then
        new_item = reaper.GetSelectedMediaItem(0, 0)
        table.insert(createdItems, new_item)
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_position)
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", loop.ref_length)
      else
        -- Fallback si la duplication échoue
        new_item = reaper.AddMediaItemToTrack(loop.track)
        local new_take = reaper.AddTakeToMediaItem(new_item)
        -- Copier les métadonnées
        SetTakeMetadata(new_take, "loop_type", loop.loop_type)
        SetTakeMetadata(new_take, "reference_loop", loop.reference_loop)
        SetTakeMetadata(new_take, "pan", GetTakeMetadata(loop.take, "pan") or "0")
        SetTakeMetadata(new_take, "volume_db", GetTakeMetadata(loop.take, "volume_db") or "0")
        SetTakeMetadata(new_take, "pitch", GetTakeMetadata(loop.take, "pitch") or "0")
        SetTakeMetadata(new_take, "monitoring", GetTakeMetadata(loop.take, "monitoring") or "0")
        SetTakeMetadata(new_take, "is_mono", GetTakeMetadata(loop.take, "is_mono") or "false")
        
        -- Couleur personnalisée
        local color = loop.loop_type == "PLAY" and colorPlay or colorOverdub
        reaper.SetMediaItemTakeInfo_Value(new_take, "I_CUSTOMCOLOR", color)
        
        -- Nom de la loop
        reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", loop.reference_loop, true)
        
        table.insert(createdItems, new_item)
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_position)
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", loop.ref_length)
      end
      
      -- Restaurer la sélection originale
      reaper.SetMediaItemSelected(new_item, false)
      for _, item in ipairs(old_sel_items) do
        reaper.SetMediaItemSelected(item, true)
      end
    end
    
    -- Ajouter la dernière portion partielle si nécessaire
    if partial_length > 0 then
      current_position = current_position + loop.ref_length
      
      -- Même méthode pour la partie partielle
      local new_item = nil
      
      -- Sauvegarder la sélection actuelle
      local old_sel_items = {}
      for s = 0, reaper.CountSelectedMediaItems(0) - 1 do
        old_sel_items[s+1] = reaper.GetSelectedMediaItem(0, s)
      end
      
      -- Désélectionner tous les items
      for _, item in ipairs(old_sel_items) do
        reaper.SetMediaItemSelected(item, false)
      end
      
      -- Sélectionner l'item à dupliquer
      reaper.SetMediaItemSelected(loop.item, true)
      
      -- Dupliquer en utilisant la commande native de REAPER
      reaper.Main_OnCommand(DUPLICATE_ITEMS_COMMAND_ID, 0)
      
      -- Récupérer l'item dupliqué
      if reaper.CountSelectedMediaItems(0) > 0 then
        new_item = reaper.GetSelectedMediaItem(0, 0)
        table.insert(createdItems, new_item)
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_position)
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", partial_length)
      else
        -- Fallback si la duplication échoue
        new_item = reaper.AddMediaItemToTrack(loop.track)
        local new_take = reaper.AddTakeToMediaItem(new_item)
        -- Copier les métadonnées
        SetTakeMetadata(new_take, "loop_type", loop.loop_type)
        SetTakeMetadata(new_take, "reference_loop", loop.reference_loop)
        SetTakeMetadata(new_take, "pan", GetTakeMetadata(loop.take, "pan") or "0")
        SetTakeMetadata(new_take, "volume_db", GetTakeMetadata(loop.take, "volume_db") or "0")
        SetTakeMetadata(new_take, "pitch", GetTakeMetadata(loop.take, "pitch") or "0")
        SetTakeMetadata(new_take, "monitoring", GetTakeMetadata(loop.take, "monitoring") or "0")
        SetTakeMetadata(new_take, "is_mono", GetTakeMetadata(loop.take, "is_mono") or "false")
        
        -- Couleur personnalisée
        local color = loop.loop_type == "PLAY" and colorPlay or colorOverdub
        reaper.SetMediaItemTakeInfo_Value(new_take, "I_CUSTOMCOLOR", color)
        
        -- Nom de la loop
        reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", loop.reference_loop, true)
        
        table.insert(createdItems, new_item)
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_position)
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", partial_length)
      end
      
      -- Restaurer la sélection originale
      reaper.SetMediaItemSelected(new_item, false)
      for _, item in ipairs(old_sel_items) do
        reaper.SetMediaItemSelected(item, true)
      end
    end
  end
  
  -- Si des loops ont été dépliées, appliquer MIDI_SetAllEvts uniquement aux items créés
  if #loopsToUnfold > 0 then
    -- Traiter d'abord les items originaux qui ont été redimensionnés
    for _, loop in ipairs(loopsToUnfold) do
      local take = loop.take
      if take and reaper.ValidatePtr2(0, take, "MediaItem_Take*") then
        local item = reaper.GetMediaItemTake_Item(take)
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_start + item_length
        local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_start)
        local end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_end)
        
        -- Vider les événements MIDI existants
        reaper.MIDI_SetAllEvts(take, "")
        
        -- Trouver la note à utiliser
        local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
        local velocity = (loop.loop_type == "PLAY") and 2 or 3
        local refNote = 0
        
        -- Récupérer le pitch correct à partir des recordLoopPitches
        for t = 0, reaper.CountTracks(0) - 1 do
          local track = reaper.GetTrack(0, t)
          for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local checkItem = reaper.GetTrackMediaItem(track, i)
            local checkTake = reaper.GetActiveTake(checkItem)
            if checkTake and reaper.TakeIsMIDI(checkTake) then
              local check_loop_type = GetTakeMetadata(checkTake, "loop_type")
              local check_loop_name = GetTakeMetadata(checkTake, "loop_name") or ""
              if check_loop_type == "RECORD" and check_loop_name == reference_loop then
                -- On a trouvé la loop de référence, extraire sa note
                local ok, midi = reaper.MIDI_GetAllEvts(checkTake, "")
                if ok and midi ~= "" then
                  local stringPos = 1
                  while stringPos < #midi do
                    local offset, flags, msg, nextPos = string.unpack("i4Bs4", midi, stringPos)
                    -- Si c'est une note on (0x90)
                    if #msg >= 3 and (msg:byte(1) & 0xF0) == 0x90 and msg:byte(3) > 0 then
                      refNote = msg:byte(2) -- La hauteur de la note (pitch)
                      break
                    end
                    stringPos = nextPos
                  end
                end
                break
              end
            end
          end
          if refNote > 0 then break end
        end
        
        -- Insérer la note avec le pitch correct
        reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, refNote, velocity, false)
        
        -- Ajouter les CCs
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
        
        reaper.MIDI_Sort(take)
      end
    end
    
    -- Puis traiter les nouveaux items créés
    for _, item in ipairs(createdItems) do
      if reaper.ValidatePtr2(0, item, "MediaItem*") then
        for j = 0, reaper.CountTakes(item) - 1 do
          local take = reaper.GetTake(item, j)
          if take and reaper.TakeIsMIDI(take) then
            local loop_type = GetTakeMetadata(take, "loop_type")
            if loop_type == "PLAY" or loop_type == "OVERDUB" then
              local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
              local velocity = (loop_type == "PLAY") and 2 or 3
              local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
              local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
              local item_end = item_start + item_length
              local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_start)
              local end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_end)
              
              -- Trouver la note à utiliser (même logique que pour les items originaux)
              local refNote = 0
              for t = 0, reaper.CountTracks(0) - 1 do
                local track = reaper.GetTrack(0, t)
                for i = 0, reaper.CountTrackMediaItems(track) - 1 do
                  local checkItem = reaper.GetTrackMediaItem(track, i)
                  local checkTake = reaper.GetActiveTake(checkItem)
                  if checkTake and reaper.TakeIsMIDI(checkTake) then
                    local check_loop_type = GetTakeMetadata(checkTake, "loop_type")
                    local check_loop_name = GetTakeMetadata(checkTake, "loop_name") or ""
                    if check_loop_type == "RECORD" and check_loop_name == reference_loop then
                      local ok, midi = reaper.MIDI_GetAllEvts(checkTake, "")
                      if ok and midi ~= "" then
                        local stringPos = 1
                        while stringPos < #midi do
                          local offset, flags, msg, nextPos = string.unpack("i4Bs4", midi, stringPos)
                          if #msg >= 3 and (msg:byte(1) & 0xF0) == 0x90 and msg:byte(3) > 0 then
                            refNote = msg:byte(2)
                            break
                          end
                          stringPos = nextPos
                        end
                      end
                      break
                    end
                  end
                end
                if refNote > 0 then break end
              end
              
              -- Insérer la note
              reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, refNote, velocity, false)
              
              -- Ajouter les CCs
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
              
              reaper.MIDI_Sort(take)
            end
          end
        end
      end
    end
  end
  
  reaper.Undo_EndBlock("Déplier les loops PLAY/OVERDUB", -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

-- Version de ProcessMIDINotes sans dépliement (pour éviter la récursion infinie)
local function _ProcessMIDINotesWithoutUnfolding()
  local noteCounters = {}         -- par piste (clé = track_id)
  local recordLoopPitches = {}    -- par piste: mapping { loop_name -> pitch }
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
                          table.insert(allTakes, { take = take, item = item, start_time = reaper.GetMediaItemInfo_Value(item, "D_POSITION"), loop_type = loop_type, track = track })
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
end

--------------------------------------------------------------------------------
-- Fonction pour définir mono/stereo sur les loops
--------------------------------------------------------------------------------
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
-- FONCTIONS POUR TRAITER LES TRACKS DANS LE MÊME FOLDER
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

--------------------------------------------------------------------------------
-- FONCTIONS SPÉCIFIQUES AU LIVE LOOPING
--------------------------------------------------------------------------------
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
  
  -- Ne traiter que la piste actuelle, pas toutes les pistes du dossier
  local nb = reaper.CountTrackMediaItems(base_track)
  for i=0, nb-1 do
    local it = reaper.GetTrackMediaItem(base_track, i)
    local st = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    -- Ne considérer que les items qui sont en amont du clip sélectionné
    if st < curStart then
      for tk=0, reaper.CountTakes(it)-1 do
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
  
  -- Trier par ordre alphabétique pour faciliter la sélection
  table.sort(result)
  
  return result
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

local function IsLoopNameValid(take, new_name)
    new_name = string.trim(new_name)
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



--------------------------------------------------------------------------------
-- C) Parsing ALK
--------------------------------------------------------------------------------
local alkData
local selectedTrackTypeIndex=0
local selectedTrackIndex=nil
local selectedLoopIndex=nil
local errorMessage=""

local function parseALK(content)
  if not content then return nil,"Contenu vide" end

  local data={
    tracks={},
    trackTypes={
      [0]={ name="Piste Audio", tracks={} },
      [1]={ name="Piste Instrument", tracks={} },
      [2]={ name="Piste MIDI", tracks={} },
      [3]={ name="Command", tracks={} },
      [4]={ name="Control", tracks={} }
    },
    transport={}
  }

  local tAttr= content:match('<transport%s+([^>]+)>')
  if tAttr then
    data.transport.id   = tAttr:match('id="([^"]*)"')   or ""
    data.transport.bpm  = tonumber(tAttr:match('bpm="([^"]*)"') or "0")
    data.transport.position = tonumber(tAttr:match('position="([^"]*)"') or "0")
  end

  for trackAttr, trackBody in content:gmatch('<track%s+([^>]+)>(.-)</track>') do
    local track={ loops={} }
    track.name      = trackAttr:match('name="([^"]*)"') or "Sans nom"
    track.id        = trackAttr:match('id="([^"]*)"')   or ""
    track.trackType = tonumber(trackAttr:match('trackType="([^"]*)"') or "0")
    track.color     = trackAttr:match('color="([^"]*)"') or ""
    track.enabled   = (trackAttr:match('enabled="([^"]*)"')=="1")
    track.solo      = (trackAttr:match('solo="([^"]*)"')=="1")

    local loopCount=0
    for loopAttr, loopInner in trackBody:gmatch('<loop%s+([^>]+)>(.-)</loop>') do
      loopCount= loopCount+1
      local lp={}
      lp.name= loopAttr:match('name="([^"]*)"') or ("Region "..loopCount)
      lp.id  = loopAttr:match('id="([^"]*)"') or ""
      lp.regionType= tonumber(loopAttr:match('regionType="([^"]*)"') or "0")
      lp.playLooped= (loopAttr:match('playLooped="([^"]*)"')=="1")
      lp.tempoAdjust= (loopAttr:match('tempoAdjust="([^"]*)"')=="1")
      lp.pitchChgSemis= tonumber(loopAttr:match('pitchChgSemis="([^"]*)"') or "0")
      lp.recordLoopName= loopAttr:match('recordLoopName="([^"]*)"') or ""

      local dAttr= loopInner:match('<[Dd]oubleinterval%s+([^>]+)/>')
      if dAttr then
        lp.beginTime= tonumber(dAttr:match('begin="([^"]*)"') or "0")
        lp.endTime  = tonumber(dAttr:match('end="([^"]*)"')   or "0")
        lp.duration = lp.endTime - lp.beginTime
      else
        lp.beginTime=0; lp.endTime=0; lp.duration=0
      end

      local destBlock= loopInner:match('<destinations>(.-)</destinations>')
      if destBlock then
        lp.destinations={}
        for line in destBlock:gmatch('<destination%s+([^>]+)') do
          local d={}
          d.type   = line:match('type="([^"]*)"')
          d.object = line:match('object="([^"]*)"')
          d.arg    = line:match('arg="([^"]*)"')
          d.value  = tonumber(line:match('value="([^"]*)"') or "0")
          d.min    = tonumber(line:match('min="([^"]*)"') or "0")
          d.max    = tonumber(line:match('max="([^"]*)"') or "1")
          table.insert(lp.destinations,d)
        end
        if lp.regionType==3 then
          for _, dd in ipairs(lp.destinations) do
            if dd.object==data.transport.id then
              if dd.arg=="0" then
                lp.tempoBpm= dd.value*170 +60
              elseif dd.arg=="5" then
                lp.signature= math.floor(dd.value*23 +1+0.5)
              end
            end
          end
        end
      end

      table.insert(track.loops, lp)
    end
    table.insert(data.tracks, track)
    local tt= track.trackType or 0
    if tt>=0 and tt<=4 then
      table.insert(data.trackTypes[tt].tracks, track)
    end
  end

  return data
end

--------------------------------------------------------------------------------
-- D) Importation Automations & Régions
--------------------------------------------------------------------------------
local function importAutomation()
  if not alkData then return end

  local tempoTr
  for _, tr in ipairs(alkData.trackTypes[3].tracks) do
    if (tr.name or ""):upper()=="TEMPO" then
      tempoTr= tr
      break
    end
  end
  if not tempoTr then
    debug_console("Aucune piste TEMPO trouvée dans l'ALK\n")
    return
  end
  for _, lp in ipairs(tempoTr.loops or {}) do
    if lp.regionType==3 then
      local meas, beatIn, sN, sD = ComputeMeasureBeatFromGlobalBeat(lp.beginTime, signatureSections)
      local newBpm= alkData.transport.bpm
      if lp.tempoBpm then newBpm= lp.tempoBpm end
      if lp.signature then sN= lp.signature; sD=4 end
      reaper.SetTempoTimeSigMarker(0, -1, -1, meas, beatIn, newBpm, sN, sD, false)
    end
  end
end

-- On crée un item MIDI par loop (sauf automation).
-- On stocke loop_type, loop_name, pitch etc. dans P_EXT
local function importRegions()
  if not alkData then return end
  local totalTracks= #alkData.tracks
  local startIdx= reaper.CountTracks(0)- totalTracks

  for i, alkTrack in ipairs(alkData.tracks) do
    if alkTrack.trackType~=3 then
      local track = reaper.GetTrack(0, startIdx + i -1)
      if track then
        -- On commence par identifier les loops RECORD qui sont référencées
        local referencedLoops = {}
        if alkTrack.trackType==0 then
          for _, lp in ipairs(alkTrack.loops) do
            if lp.regionType==1 and lp.recordLoopName~="" then
              referencedLoops[lp.recordLoopName] = true
            end
          end
        end

        -- Création item MIDI
        for _,lp in ipairs(alkTrack.loops) do
          if lp.regionType~=3 then
            local tStart= reaper.TimeMap2_beatsToTime(0, lp.beginTime)
            local tEnd  = reaper.TimeMap2_beatsToTime(0, lp.endTime)
            local item= reaper.CreateNewMIDIItemInProj(track, tStart, tEnd,false)
            if item then
              local take= reaper.GetActiveTake(item)
              local finalLoopType
              local regionName= lp.name
              
              -- Détermination du type de loop
              if lp.regionType==0 then
                -- Si c'est une région RECORD, on vérifie si elle est référencée
                if referencedLoops[lp.name] then
                  finalLoopType = "RECORD"
                else
                  finalLoopType = "MONITOR"  -- RECORD non référencée -> MONITOR
                end
              elseif lp.regionType==1 then
                finalLoopType = "PLAY"
                if lp.recordLoopName~="" then
                  regionName = lp.recordLoopName
                end
              end

              local trackNum= startIdx + i
              local prefix= string.format("%02d", trackNum)
              local finalName= prefix.." "..regionName
              reaper.GetSetMediaItemTakeInfo_String(take,"P_NAME", finalName,true)

              -- Couleur
              if alkTrack.trackType==0 then
                local itemColor
                if finalLoopType=="PLAY" then
                  itemColor= colorPlay
                elseif finalLoopType=="RECORD" then
                  itemColor= colorRecord
                else
                  itemColor= colorMonitor  -- Pour les loops MONITOR
                end
                reaper.SetMediaItemInfo_Value(item,"I_CUSTOMCOLOR", itemColor)
              end

              -- Stocker P_EXT
              reaper.GetSetMediaItemTakeInfo_String(take,"P_EXT:loop_type", finalLoopType,true)
              reaper.GetSetMediaItemTakeInfo_String(take,"P_EXT:loop_name", finalName,true)
              reaper.GetSetMediaItemTakeInfo_String(take,"P_EXT:pitch", tostring(lp.pitchChgSemis or 0), true)
              
              -- Initialisation du monitoring en fonction du type de loop
              local monitoring = "1"  -- Par défaut ON pour RECORD, MONITOR et OVERDUB
              if finalLoopType == "PLAY" then
                monitoring = "0"  -- OFF pour PLAY
              end
              reaper.GetSetMediaItemTakeInfo_String(take,"P_EXT:monitoring", monitoring, true)
              
              -- Pour les loops PLAY, on stocke aussi la référence à la loop RECORD
              if finalLoopType == "PLAY" and lp.recordLoopName ~= "" then
                local refName = prefix .. " " .. lp.recordLoopName
                reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:reference_loop", refName, true)
              end
            end
          end
        end
      end
    end
  end
  reaper.UpdateArrange()
end

--------------------------------------------------------------------------------
-- Importation des données du métronome
--------------------------------------------------------------------------------
local function importMetronome()
    if not alkData then return end
    
    -- Recherche de la piste METRONON
    local metronomeTrack = nil
    for _, tr in ipairs(alkData.trackTypes[3].tracks or {}) do
        if tr.name:upper() == "METRONON" then
            metronomeTrack = tr
            break
        end
    end
    
    if not metronomeTrack then
        reaper.ShowMessageBox("Aucune piste METRONON trouvée dans le projet ALK.", "Information", 0)
        return
    end
    
    -- Désélectionner toutes les pistes existantes
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        reaper.SetTrackSelected(tr, false)
    end
    
    -- Création de la piste métronome dans Reaper
    local trackIndex = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(trackIndex, true)
    local track = reaper.GetTrack(0, trackIndex)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "METRONON", true)
    
    -- Sélectionner la piste METRONON
    reaper.SetTrackSelected(track, true)
    reaper.CSurf_OnTrackSelection(track) -- Force la mise à jour de la sélection
    reaper.UpdateArrange() -- Rafraîchit l'affichage
    
    -- Insertion de la source de clic
    reaper.Main_OnCommand(40013, 0) -- Insert click source
    
    -- Récupération de l'item créé
    local itemCount = reaper.CountTrackMediaItems(track)
    if itemCount > 0 then
        local clickItem = reaper.GetTrackMediaItem(track, 0)
        
        -- Trouver la fin du projet (dernière note)
        local lastTime = 0
        local numTracks = reaper.CountTracks(0)
        for i = 0, numTracks - 1 do
            local tr = reaper.GetTrack(0, i)
            local numItems = reaper.CountTrackMediaItems(tr)
            for j = 0, numItems - 1 do
                local item = reaper.GetTrackMediaItem(tr, j)
                local itemEnd = reaper.GetMediaItemInfo_Value(item, "D_POSITION") + 
                              reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                if itemEnd > lastTime then
                    lastTime = itemEnd
                end
            end
        end
        
        -- Étendre l'item click jusqu'à la fin du projet
        reaper.SetMediaItemInfo_Value(clickItem, "D_LENGTH", lastTime)
        
        -- Découper et muter les sections selon les données ALK
        for _, lp in ipairs(metronomeTrack.loops or {}) do
            if lp.beginTime and lp.endTime then
                local startTime = reaper.TimeMap2_beatsToTime(0, lp.beginTime)
                local endTime = reaper.TimeMap2_beatsToTime(0, lp.endTime)
                
                -- Découper aux points de début et fin
                reaper.SetEditCurPos(startTime, false, false)
                reaper.Main_OnCommand(40012, 0) -- Split items at edit cursor
                reaper.SetEditCurPos(endTime, false, false)
                reaper.Main_OnCommand(40012, 0) -- Split items at edit cursor
                
                -- Trouver l'item correspondant à cette section
                local numItems = reaper.CountTrackMediaItems(track)
                for i = 0, numItems - 1 do
                    local item = reaper.GetTrackMediaItem(track, i)
                    local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                    
                    if math.abs(itemStart - startTime) < 0.001 and math.abs(itemEnd - endTime) < 0.001 then
                        -- Vérifier si la section doit être mutée
                        if lp.destinations then
                            for _, dest in ipairs(lp.destinations) do
                                if dest.type == "click" and dest.value == 0 then
                                    reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
                                    break
                                end
                            end
                        end
                        break
                    end
                end
            end
        end
    end
end

local function importProject()
  if not alkData then return end

  reaper.Undo_BeginBlock()
    local count0 = reaper.CountTracks(0)
  for i,alkTrack in ipairs(alkData.tracks) do
    reaper.InsertTrackAtIndex(count0 + i -1, true)
    local tr = reaper.GetTrack(0, count0 + i -1)
    reaper.GetSetMediaTrackInfo_String(tr,"P_NAME", alkTrack.name,true)
        local c = customColors[alkTrack.trackType] or customColors[5]
    reaper.SetMediaTrackInfo_Value(tr,"I_CUSTOMCOLOR", c)
  end
  reaper.Undo_EndBlock("Importer les pistes ALK",-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.SetMasterTrackVisibility(1)

  importAutomation()
  importRegions()
end

--------------------------------------------------------------------------------
-- E) Ajouter Looper (mono/stéréo)
--------------------------------------------------------------------------------
local function makeFolder(folderTrack,childTracks)
  reaper.SetMediaTrackInfo_Value(folderTrack,"I_FOLDERDEPTH",1)
  for i,tr in ipairs(childTracks) do
    if i< #childTracks then
      reaper.SetMediaTrackInfo_Value(tr,"I_FOLDERDEPTH",0)
    else
      reaper.SetMediaTrackInfo_Value(tr,"I_FOLDERDEPTH",-1)
    end
  end
end

local function addLooperBase(isMono)
    local selCount = reaper.CountSelectedTracks(0)
    if selCount == 0 then
        -- Créer une nouvelle piste si aucune n'est sélectionnée
        reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
        reaper.TrackList_AdjustWindows(false)
        
        -- Sélectionner la piste nouvellement créée
        local newTrack = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
        reaper.SetTrackSelected(newTrack, true)
        
        -- Mettre à jour le comptage
        selCount = 1
    end

    local opt = recInputOptions[selectedRecInputOption]
    local iRec = opt and opt.iRecInput or 0

    -- Garder une liste des pistes traitées pour les désélectionner ensuite
    local processedTracks = {}
    
    for i = 0, selCount - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if track then
            -- Stocker la piste pour la désélectionner plus tard
            table.insert(processedTracks, track)
            
            -- Assigner l'entrée audio sélectionnée
            reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", iRec)
            -- Ajouter l'effet PoulpyLoop
            reaper.TrackFX_AddByName(track, "PoulpyLoop", false, -1)
            -- Armer la piste et activer le monitoring
            reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
            reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)

            -- Stocker l'usage (mono/stereo)
            local usage = isMono and "mono" or "stereo"
            local guid = reaper.GetTrackGUID(track)
            looperUsage[guid] = usage
        end
    end
    
    -- Désélectionner toutes les pistes traitées
    for _, track in ipairs(processedTracks) do
        reaper.SetTrackSelected(track, false)
    end
    
    reaper.UpdateArrange()
end

local function addLooperMono()   addLooperBase(true) end
local function addLooperStereo() addLooperBase(false) end

local function addLooper()   
  -- Utiliser false pour toujours passer en mode stéréo
  addLooperBase(false) 
end

--------------------------------------------------------------------------------
-- F) Fonctions PoulpyLoopy
--------------------------------------------------------------------------------
local function IsStringEmptyOrWhitespace(str)
  return (not str) or (str:match("^%s*$")~=nil)
end
function string.trim(s) return (s:gsub("^%s*(.-)%s*$","%1")) end

local function SetTakeMetadata(take, key, val)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:"..key, tostring(val), true)
end
local function GetTakeMetadata(take, key)
  local _, v= reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:"..key, "", false)
  return v or ""
end

-- On veut un "folder index" : si la piste a un parent, on prend IP_TRACKNUMBER(parent),
-- sinon IP_TRACKNUMBER(self). On s'en sert pour regrouper les notes RECORD.
local function GetFolderIndex(track)
  local parent= reaper.GetParentTrack(track)
  if parent then
    return math.floor(reaper.GetMediaTrackInfo_Value(parent,"IP_TRACKNUMBER"))
  end
  return math.floor(reaper.GetMediaTrackInfo_Value(track,"IP_TRACKNUMBER"))
end

-- Liste les loops RECORD existant avant itemStart
local function GetPreviousRecordLoopsInFolder(take)
  local base_track = reaper.GetMediaItemTake_Track(take)
  local curItem = reaper.GetMediaItemTake_Item(take)
  local curStart = reaper.GetMediaItemInfo_Value(curItem, "D_POSITION")

  local recordLoops = {}
  
  -- Ne traiter que la piste actuelle, pas toutes les pistes du dossier
  local nb = reaper.CountTrackMediaItems(base_track)
  for i=0, nb-1 do
    local it = reaper.GetTrackMediaItem(base_track, i)
    local st = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    -- Ne considérer que les items qui sont en amont du clip sélectionné
    if st < curStart then
      for tk=0, reaper.CountTakes(it)-1 do
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
  
  -- Trier par ordre alphabétique pour faciliter la sélection
  table.sort(result)
  
  return result
end

-- Insère la note MIDI unique
local function InsertMIDINoteForLoop(take, startPPQ, endPPQ, note, velocity)
  reaper.MIDI_DisableSort(take)
  reaper.MIDI_InsertNote(take, false,false, startPPQ,endPPQ, 0, note, velocity, false)
  reaper.MIDI_Sort(take)
end

local function createPoulpyLoopMIDI(take, item, loopName, loopType, usage, pitchSemis, itemStart, itemEnd, noteNumber, velocity)
  -- On insère une note occupant [start..end].
  reaper.MIDI_DisableSort(take)
  local startQN= reaper.TimeMap2_timeToQN(0, itemStart)
  local endQN  = reaper.TimeMap2_timeToQN(0, itemEnd)
  local startPPQ= reaper.MIDI_GetPPQPosFromProjQN(take, startQN)
  local endPPQ  = reaper.MIDI_GetPPQPosFromProjQN(take, endQN)
  if endPPQ<=startPPQ then 
    endPPQ= startPPQ+120 
  end

  -- Insert note
  reaper.MIDI_InsertNote(take, false,false, startPPQ,endPPQ, 0, noteNumber, velocity, false)

  -- Récupération des paramètres de la loop depuis les métadonnées
  local volume_db = tonumber(GetTakeMetadata(take, "volume_db")) or 0
  local is_mono = GetTakeMetadata(take, "is_mono") == "true"
  local pan = tonumber(GetTakeMetadata(take, "pan")) or 0
  local monitoring = tonumber(GetTakeMetadata(take, "monitoring")) or (loopType == "PLAY" and 0 or 1)

  -- CC7 : Volume (0-127)
  local cc07 = math.floor(((volume_db + 20) / 40) * 127 + 0.5)
  reaper.MIDI_InsertCC(take, false, false, startPPQ, 0xB0, 0, 7, cc07, false)

  -- CC8 : Mono/Stereo (0=mono, 1=stereo)
  local cc08 = is_mono and 0 or 1
  reaper.MIDI_InsertCC(take, false, false, startPPQ, 0xB0, 0, 8, cc08, false)

  -- CC10 : Pan (0-127, 64=center)
  local cc10 = math.floor(64 + pan * 63 + 0.5)
  reaper.MIDI_InsertCC(take, false, false, startPPQ, 0xB0, 0, 10, cc10, false)

  -- CC9 : Pitch (0-127, 64=center)
  local cc09 = math.floor(64 + (pitchSemis or 0) + 0.5)
  reaper.MIDI_InsertCC(take, false, false, startPPQ, 0xB0, 0, 9, cc09, false)

  -- CC11 : Monitoring (0=OFF, 1=ON)
  reaper.MIDI_InsertCC(take, false, false, startPPQ, 0xB0, 0, 11, monitoring, false)

  -- Pitch Bend si nécessaire
  if pitchSemis and pitchSemis~=0 then
    local center=8192
    local step= math.floor(8192/12)
    local val= center+(pitchSemis*step)
    if val<0 then val=0 elseif val>16383 then val=16383 end
    local pbLSB= val & 0x7F
    local pbMSB= (val>>7)&0x7F
    reaper.MIDI_InsertCC(take,false,false, startPPQ+40, 0xE0, 0, pbLSB, pbMSB)
  end

  reaper.MIDI_Sort(take)
  local extKey= "Loop_".. (loopName or "?")
  local extVal= string.format("loopType=%s; usage=%s; pitch=%d; start=%.3f; end=%.3f; note=%d",
    loopType, usage, pitchSemis or 0, itemStart, itemEnd, noteNumber)
  reaper.SetProjExtState(0, "PoulpyLoopy", extKey, extVal)
end

-- On veut stocker un <folderIndex -> nextRecordNote, recordLoopNotes>, faire un tri global
local function prepareForPoulpyLoopy()
  reaper.Undo_BeginBlock()

  local allItems= {}

  local trackCount= reaper.CountTracks(0)
  for t=0, trackCount-1 do
    local track= reaper.GetTrack(0,t)
    local folderIdx= GetFolderIndex(track)
    local usage= looperUsage[ reaper.GetTrackGUID(track) ] or "mono"
    local itemCount= reaper.CountTrackMediaItems(track)
    for i=0, itemCount-1 do
      local item= reaper.GetTrackMediaItem(track,i)
      local pos= reaper.GetMediaItemInfo_Value(item,"D_POSITION")
      local take= reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local loopType= GetTakeMetadata(take,"loop_type") or "MONITOR"
        local loopName= GetTakeMetadata(take,"loop_name") or ""
        local pitchS  = tonumber(GetTakeMetadata(take,"pitch") or "0") or 0
        table.insert(allItems,{
          track=track, item=item, take=take,
          folderIdx= folderIdx, usage=usage,
          loopType= loopType, loopName= loopName, pitch= pitchS,
          pos= pos
        })
      end
    end
  end

  -- On trie par folderIdx, puis par pos
  table.sort(allItems, function(a,b)
    if a.folderIdx==b.folderIdx then
      return a.pos< b.pos
    end
    return a.folderIdx< b.folderIdx
  end)

  -- Premier passage : traiter toutes les loops MONITOR
  for _, ent in ipairs(allItems) do
    if ent.loopType == "MONITOR" then
      local itemStart = reaper.GetMediaItemInfo_Value(ent.item, "D_POSITION")
      local itemLen = reaper.GetMediaItemInfo_Value(ent.item, "D_LENGTH")
      local itemEnd = itemStart + itemLen
      createPoulpyLoopMIDI(ent.take, ent.item, ent.loopName, "MONITOR", ent.usage, ent.pitch, itemStart, itemEnd, 0, 4)
    end
  end

  -- Deuxième passage : traiter les autres types de loops avec le système de compteur
  local recordLoopNotes= {}  -- recordLoopNotes[ folderIdx ][ loopName ]= note
  local nextRecordNote= {}   -- nextRecordNote[ folderIdx ]= 1 (C#-1) initial

  for _, ent in ipairs(allItems) do
    if ent.loopType ~= "MONITOR" then  -- On ignore les loops MONITOR dans ce passage
      local fIdx = ent.folderIdx
      if not recordLoopNotes[fIdx] then
        recordLoopNotes[fIdx] = {}
        nextRecordNote[fIdx] = 1  -- C#-1
      end

      local loopType = ent.loopType
      local loopName = ent.loopName
      local pitchSemis = ent.pitch
      local usage = ent.usage
      local item = ent.item
      local take = ent.take
      local itemStart = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
      local itemLen = reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
      local itemEnd = itemStart + itemLen

      if loopType=="RECORD" then
        local assignedNote = nextRecordNote[fIdx]
        nextRecordNote[fIdx] = nextRecordNote[fIdx]+1
        recordLoopNotes[fIdx][loopName] = assignedNote
        createPoulpyLoopMIDI(take, item, loopName, "RECORD", usage, pitchSemis, itemStart, itemEnd, assignedNote, 1)

      elseif loopType=="PLAY" then
        local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
        -- Extraire le nom sans préfixe pour la recherche
        local ref_name = reference_loop:match("%d%d%s+(.*)")
        local refNote = 0
        
        -- Chercher d'abord avec le nom complet
        if recordLoopPitches[folder_id][reference_loop] then
            refNote = recordLoopPitches[folder_id][reference_loop]
        -- Puis chercher avec le nom sans préfixe
        elseif ref_name and recordLoopPitches[folder_id][ref_name] then
            refNote = recordLoopPitches[folder_id][ref_name]
        -- Enfin, chercher dans toutes les entrées pour une correspondance sans préfixe
        else
            for name, pitch in pairs(recordLoopPitches[folder_id]) do
                local name_without_prefix = name:match("%d%d%s+(.*)")
                if name_without_prefix and name_without_prefix == ref_name then
                    refNote = pitch
                    break
                end
            end
        end
        
        createPoulpyLoopMIDI(take, item, loopName, "PLAY", usage, pitchSemis, itemStart, itemEnd, refNote, 2)

      elseif loopType=="OVERDUB" then
        local reference_loop = GetTakeMetadata(take, "reference_loop") or ""
        local refNote = recordLoopNotes[fIdx][reference_loop] or 0
        createPoulpyLoopMIDI(take, item, loopName, "OVERDUB", usage, pitchSemis, itemStart, itemEnd, refNote, 3)

      elseif loopType=="UNUSED" then
        debug_console("\nLoop "..loopName.." ignorée (type="..loopType..")")
      end
    end
  end

  reaper.Undo_EndBlock("Préparer pour PoulpyLoopy",-1)
end

--------------------------------------------------------------------------------
-- G) Fenêtre "Options de Loop"
--------------------------------------------------------------------------------
local showLoopOptionsUI= false

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
        
        -- Mise à jour des autres données du take
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

local function DrawLoopOptionsWindow()
  if not showLoopOptionsUI then return end

    if reaper.ImGui_Begin(ctx, "Options de Loop", true) then
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
          end
          if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
        end
        reaper.ImGui_EndCombo(ctx)
      end

            -- Options spécifiques selon le type de loop
            if loop_type == "RECORD" then
                local changed, new_name = reaper.ImGui_InputText(ctx, "Nom de la Loop", loop_name, 256)
                if changed then loop_name = new_name:trim() end

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
                    local ref_trimmed = reference_loop:trim():lower()
                    for i, name in ipairs(prev_loops) do
                        if name:trim():lower() == ref_trimmed then
                            sel_idx = i
                            break
                        end
                        
                        local name_without_prefix = name:match("%d%d%s+(.*)")
                        if name_without_prefix and name_without_prefix:trim():lower() == ref_trimmed then
                            sel_idx = i
                            break
                        end
                        
                        local ref_without_prefix = ref_trimmed:match("%d%d%s+(.*)")
                        if ref_without_prefix and name:trim():lower() == ref_without_prefix then
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

            -- Boutons d'action
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
                        reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorRecord)
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
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorOverdub)
                    ProcessMIDINotes()

                elseif loop_type == "PLAY" then
                    SetTakeMetadata(take, "loop_type", loop_type)
                    SetTakeMetadata(take, "reference_loop", reference_loop)
                    SetTakeMetadata(take, "pan", tostring(pan))
                    SetTakeMetadata(take, "volume_db", tostring(volume_db))
                    SetTakeMetadata(take, "pitch", tostring(pitch))
                    SetTakeMetadata(take, "monitoring", tostring(monitoring))
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorPlay)
                    ProcessMIDINotes()

                elseif loop_type == "MONITOR" then
                    SetTakeMetadata(take, "loop_type", loop_type)
                    SetTakeMetadata(take, "pan", tostring(pan))
                    SetTakeMetadata(take, "volume_db", tostring(volume_db))
                    SetTakeMetadata(take, "is_mono", tostring(is_mono))
                    SetTakeMetadata(take, "monitoring", "1")  -- Toujours ON
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorMonitor)
                    ProcessMIDINotes()

                elseif loop_type == "UNUSED" then
                    SetTakeMetadata(take, "loop_type", "UNUSED")
                    SetTakeMetadata(take, "reference_loop", "")
                    SetTakeMetadata(take, "pan", "0")
                    SetTakeMetadata(take, "volume_db", "0")
                    SetTakeMetadata(take, "pitch", "0")
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "(Unused)", true)
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorUnused)
                    ProcessMIDINotes()
                end
            end

      reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Fermer") then
                showLoopOptionsUI = false
      end

    else
      reaper.ImGui_Text(ctx, "Aucun item MIDI sélectionné.")
            if reaper.ImGui_Button(ctx, "Fermer") then
                showLoopOptionsUI = false
      end
    end

    reaper.ImGui_End(ctx)
  else
        showLoopOptionsUI = false
  end
end

--------------------------------------------------------------------------------
-- H) Fenêtre Principale
--------------------------------------------------------------------------------
local function mainWindow()
  -- Charger les valeurs depuis gmem au début de chaque frame
  record_monitor_loops = reaper.gmem_read(GMEM_RECORD_MONITOR_MODE) == 1
  playback_mode = reaper.gmem_read(GMEM_PLAYBACK_MODE) == 1

  reaper.ImGui_SetNextWindowPos(ctx, 100,50, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSize(ctx,700,500, reaper.ImGui_Cond_FirstUseEver())

  local visible= reaper.ImGui_Begin(ctx, "PoulpyLoopy v" .. VERSION, true)
  if visible then
    -- Création des onglets
    if reaper.ImGui_BeginTabBar(ctx, "MainTabs") then
      -- Onglet "Loop Editor" (ancien "Options de Loop")
      if reaper.ImGui_BeginTabItem(ctx, "Loop Editor") then
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
                    end
                    if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
                end
                reaper.ImGui_EndCombo(ctx)
            end

            -- Options spécifiques selon le type de loop
            if loop_type == "RECORD" then
                local changed, new_name = reaper.ImGui_InputText(ctx, "Nom de la Loop", loop_name, 256)
                if changed then loop_name = new_name:trim() end

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
                    local ref_trimmed = reference_loop:trim():lower()
                    for i, name in ipairs(prev_loops) do
                        if name:trim():lower() == ref_trimmed then
                            sel_idx = i
                            break
                        end
                        
                        local name_without_prefix = name:match("%d%d%s+(.*)")
                        if name_without_prefix and name_without_prefix:trim():lower() == ref_trimmed then
                            sel_idx = i
                            break
                        end
                        
                        local ref_without_prefix = ref_trimmed:match("%d%d%s+(.*)")
                        if ref_without_prefix and name:trim():lower() == ref_without_prefix then
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
                        reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorRecord)
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
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorOverdub)
                    ProcessMIDINotes()

                elseif loop_type == "PLAY" then
                    SetTakeMetadata(take, "loop_type", loop_type)
                    SetTakeMetadata(take, "reference_loop", reference_loop)
                    SetTakeMetadata(take, "pan", tostring(pan))
                    SetTakeMetadata(take, "volume_db", tostring(volume_db))
                    SetTakeMetadata(take, "pitch", tostring(pitch))
                    SetTakeMetadata(take, "monitoring", tostring(monitoring))
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", reference_loop, true)
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorPlay)
                    ProcessMIDINotes()

                elseif loop_type == "MONITOR" then
                    SetTakeMetadata(take, "loop_type", loop_type)
                    SetTakeMetadata(take, "pan", tostring(pan))
                    SetTakeMetadata(take, "volume_db", tostring(volume_db))
                    SetTakeMetadata(take, "is_mono", tostring(is_mono))
                    SetTakeMetadata(take, "monitoring", "1")  -- Toujours ON
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorMonitor)
                    ProcessMIDINotes()

                elseif loop_type == "UNUSED" then
                    SetTakeMetadata(take, "loop_type", "UNUSED")
                    SetTakeMetadata(take, "reference_loop", "")
                    SetTakeMetadata(take, "pan", "0")
                    SetTakeMetadata(take, "volume_db", "0")
                    SetTakeMetadata(take, "pitch", "0")
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "(Unused)", true)
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", colorUnused)
                    ProcessMIDINotes()
                end
            end

        else
            reaper.ImGui_Text(ctx, "Aucun item MIDI sélectionné.")
        end
        reaper.ImGui_EndTabItem(ctx)
      end

      -- Onglet "Options" (fusion de "Mode" et "Monitoring")
      if reaper.ImGui_BeginTabItem(ctx, "Options") then
        -- Partie 1: Options d'enregistrement (ancien onglet "Mode")
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
            saveRecordMonitorLoopsMode()
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
            savePlaybackMode()
        end

        reaper.ImGui_Separator(ctx)

        -- Partie 2: Monitoring à l'arrêt (ancien onglet "Monitoring")
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
            local monitoring_stop = reaper.gmem_read(GMEM_MONITORING_STOP_BASE + i) == 1
            if reaper.ImGui_Checkbox(ctx, "##monitoring_stop_" .. i, monitoring_stop) then
              reaper.gmem_write(GMEM_MONITORING_STOP_BASE + i, monitoring_stop and 0 or 1)
            end
            
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, "Lorsque cette option est activée, le signal d'entrée est routé vers les sorties lorsque la lecture est à l'arrêt.")
            end
          end
        end

        reaper.ImGui_EndTable(ctx)

        reaper.ImGui_EndTabItem(ctx)
      end

      -- Onglet "Tools" (avec contenu de "Importation ALK")
      if reaper.ImGui_BeginTabItem(ctx, "Tools") then
        -- Partie 1: Outils de base
        reaper.ImGui_Text(ctx, "Outils de base :")
        reaper.ImGui_Separator(ctx)
        
        reaper.ImGui_Text(ctx, "Entrée audio pour Looper :")
        drawRecInputCombo()

        if reaper.ImGui_Button(ctx,"Ajouter looper") then
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
        
        -- Partie 2: Importation ALK (ancien onglet)
        reaper.ImGui_Text(ctx, "Importation ALK :")
        reaper.ImGui_Separator(ctx)
        
        reaper.ImGui_Text(ctx, "Fichier ALK: ".. ((alkData and "(chargé)") or "aucun"))
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx,"Ouvrir .alk") then
          local ret, file= reaper.GetUserFileNameForRead("", "Fichier ALK", "alk")
          if ret then
            local c, err= readFile(file)
            if not c then
              errorMessage= err
            else
              alkData, errorMessage= parseALK(c)
              selectedTrackTypeIndex=0
              selectedTrackIndex=nil
              selectedLoopIndex=nil
            end
          end
        end

        if alkData and reaper.ImGui_Button(ctx,"Importer le projet ALK") then
          importProject()
        end

        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx,"Préparer pour PoulpyLoopy") then
          prepareForPoulpyLoopy()
        end

        if errorMessage and #errorMessage>0 then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF0000FF)
          reaper.ImGui_Text(ctx,"Erreur: ".. errorMessage)
          reaper.ImGui_PopStyleColor(ctx)
        end

        reaper.ImGui_Separator(ctx)

        -- Affichage détaillé ALK
        if alkData then
          if reaper.ImGui_BeginCombo(ctx, "TrackType", alkData.trackTypes[selectedTrackTypeIndex].name) then
            for i=0,4 do
              local tt= alkData.trackTypes[i]
              local isSel= (selectedTrackTypeIndex==i)
              local lbl= tt.name.." ("..#tt.tracks..")"
              if reaper.ImGui_Selectable(ctx,lbl,isSel) then
                selectedTrackTypeIndex= i
                selectedTrackIndex=nil
                selectedLoopIndex=nil
              end
              if isSel then reaper.ImGui_SetItemDefaultFocus(ctx) end
            end
            reaper.ImGui_EndCombo(ctx)
          end

          local tracks= alkData.trackTypes[selectedTrackTypeIndex].tracks or {}
          local trackLabel= (#tracks>0 and tracks[1].name) or "Aucune piste"
          if reaper.ImGui_BeginCombo(ctx,"Tracks", trackLabel) then
            for i,tr in ipairs(tracks) do
              local isSel=(selectedTrackIndex==i)
              if reaper.ImGui_Selectable(ctx, tr.name, isSel) then
                selectedTrackIndex=i
                selectedLoopIndex=nil
              end
              if isSel then reaper.ImGui_SetItemDefaultFocus(ctx) end
            end
            reaper.ImGui_EndCombo(ctx)
          end

          if selectedTrackIndex and tracks[selectedTrackIndex] then
            local theTr= tracks[selectedTrackIndex]
            local loops= theTr.loops or {}
            local firstLoopName= (#loops>0 and loops[1].name) or "Aucune loop"
            if reaper.ImGui_BeginCombo(ctx,"Loops", firstLoopName) then
              for i,lp in ipairs(loops) do
                local isSel=(selectedLoopIndex==i)
                if reaper.ImGui_Selectable(ctx, lp.name, isSel) then
                  selectedLoopIndex=i
                end
                if isSel then reaper.ImGui_SetItemDefaultFocus(ctx) end
              end
              reaper.ImGui_EndCombo(ctx)
            end

            if selectedLoopIndex and loops[selectedLoopIndex] then
              local lp= loops[selectedLoopIndex]
              reaper.ImGui_Separator(ctx)
              reaper.ImGui_Text(ctx, "Nom: "..(lp.name or ""))
              reaper.ImGui_Text(ctx, string.format("regionType=%d (begin=%.1f, end=%.1f)", 
                lp.regionType or -1, lp.beginTime or 0, lp.endTime or 0))
            end
          end
        end

        reaper.ImGui_Separator(ctx)

        -- Partie 3: Automation du clic (déjà présent dans Tools)
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
                local item = reaper.GetSelectedMediaItem(0, 0)
                if item then
                    local selectedTrack = commandTracks[selected_click_track_index + 1]
                    if selectedTrack and selectedTrack.loops then
                        local track = reaper.GetMediaItemTrack(item)
                        
                        -- Marquer tous les items comme "sans automation" initialement
                        local numItems = reaper.CountTrackMediaItems(track)
                        for i = 0, numItems - 1 do
                            local existingItem = reaper.GetTrackMediaItem(track, i)
                            reaper.SetMediaItemInfo_Value(existingItem, "I_CUSTOMCOLOR", colorClickNoAuto)
                        end
                        
                        -- Découper et muter les sections selon les données ALK
                        for _, lp in ipairs(selectedTrack.loops or {}) do
                            if lp.beginTime and lp.endTime and lp.regionType == 3 then
                                local startTime = reaper.TimeMap2_beatsToTime(0, lp.beginTime)
                                local endTime = reaper.TimeMap2_beatsToTime(0, lp.endTime)
                                
                                -- Découper aux points de début et fin
                                reaper.SetEditCurPos(startTime, false, false)
                                reaper.Main_OnCommand(40012, 0) -- Split items at edit cursor
                                reaper.SetEditCurPos(endTime, false, false)
                                reaper.Main_OnCommand(40012, 0) -- Split items at edit cursor
                                
                                -- Trouver l'item correspondant à cette section
                                numItems = reaper.CountTrackMediaItems(track)
                                for i = 0, numItems - 1 do
                                    local splitItem = reaper.GetTrackMediaItem(track, i)
                                    local itemStart = reaper.GetMediaItemInfo_Value(splitItem, "D_POSITION")
                                    local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(splitItem, "D_LENGTH")
                                    
                                    if math.abs(itemStart - startTime) < 0.001 and math.abs(itemEnd - endTime) < 0.001 then
                                        -- Vérifier si la section doit être mutée
                                        if lp.destinations then
                                            for _, dest in ipairs(lp.destinations) do
                                                if dest.type == "parameter" then
                                                    if dest.value == 0 then
                                                        reaper.SetMediaItemInfo_Value(splitItem, "B_MUTE", 1)
                                                        reaper.SetMediaItemInfo_Value(splitItem, "I_CUSTOMCOLOR", colorClickMuted)
                                                    else
                                                        reaper.SetMediaItemInfo_Value(splitItem, "I_CUSTOMCOLOR", colorClickActive)
                                                    end
                                                    break
                                                end
                                            end
                                        end
                                        break
                                    end
                                end
                            end
                        end

                        -- Première étape : supprimer les segments noirs qui suivent un segment bleu
                        local i = 0
                        while i < reaper.CountTrackMediaItems(track) - 1 do
                            local currentItem = reaper.GetTrackMediaItem(track, i)
                            local nextItem = reaper.GetTrackMediaItem(track, i + 1)
                            local currentColor = reaper.GetMediaItemInfo_Value(currentItem, "I_CUSTOMCOLOR")
                            local nextColor = reaper.GetMediaItemInfo_Value(nextItem, "I_CUSTOMCOLOR")
                            
                            if currentColor == colorClickMuted and nextColor == colorClickNoAuto then
                                reaper.DeleteTrackMediaItem(track, nextItem)
                            else
                                i = i + 1
                            end
                        end

                        -- Deuxième étape : supprimer tous les segments bleus
                        i = 0
                        while i < reaper.CountTrackMediaItems(track) do
                            local currentItem = reaper.GetTrackMediaItem(track, i)
                            local currentColor = reaper.GetMediaItemInfo_Value(currentItem, "I_CUSTOMCOLOR")
                            
                            if currentColor == colorClickMuted then
                                reaper.DeleteTrackMediaItem(track, currentItem)
                            else
                                i = i + 1
                            end
                        end

                        reaper.UpdateArrange()
                    else
                        reaper.ShowMessageBox("La piste sélectionnée ne contient pas de régions.", "Erreur", 0)
                    end
                else
                    reaper.ShowMessageBox("Veuillez sélectionner un item à découper.", "Erreur", 0)
                end
            end
        else
            reaper.ImGui_Text(ctx, "Chargez d'abord un fichier ALK pour accéder aux pistes d'automation.")
        end

        reaper.ImGui_EndTabItem(ctx)
      end
      
      -- Onglet "Stats" pour afficher les statistiques des instances de PoulpyLoop
      if reaper.ImGui_BeginTabItem(ctx, "Stats") then
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
          local stats_base = GMEM_STATS_BASE + i * 3
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
        
        -- Ajouter une ligne de total
        if total_instances > 0 then
          reaper.ImGui_TableNextRow(ctx)
          
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_Text(ctx, "TOTAL")
          
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_Text(ctx, string.format("%.1f MB", total_memory))
          
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_Text(ctx, "")
          
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_Text(ctx, string.format("%d", total_notes))
        end
        
        reaper.ImGui_EndTable(ctx)
        
        -- Informations supplémentaires
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, string.format("Nombre total d'instances actives : %d", total_instances))
        reaper.ImGui_Text(ctx, "Note : Les statistiques sont mises à jour en temps réel par chaque instance active de PoulpyLoop.")
        
        reaper.ImGui_EndTabItem(ctx)
      end

      -- Onglet "Debug" pour afficher les informations de débogage
      if reaper.ImGui_BeginTabItem(ctx, "Debug") then
        -- Section de gauche : Messages de débogage actuels
        reaper.ImGui_Text(ctx, "Messages de débogage actuels :")
        reaper.ImGui_Separator(ctx)
        
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
        local playback_mode = get_playback_mode()
        reaper.ImGui_Text(ctx, "Mode: ")
        reaper.ImGui_SameLine(ctx)
        if playback_mode == 1 then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF5555FF) -- Rouge pour PLAYBACK
          reaper.ImGui_Text(ctx, "PLAYBACK")
        else
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55FF55FF) -- Vert pour LIVE
          reaper.ImGui_Text(ctx, "LIVE")
        end
        reaper.ImGui_PopStyleColor(ctx)
        
        -- État de la synchronisation
        reaper.ImGui_Text(ctx, "Synchronisation: ")
        reaper.ImGui_SameLine(ctx)
        
        -- Vérifier si les offsets sont actifs
        local using_offsets = false
        
        -- Parcourir les données de synchronisation pour voir s'il y a des données valides
        for i = 0, 63 do
          local sync_base = GMEM_MIDI_SYNC_DATA_BASE + i * 3
          local track_id = reaper.gmem_read(sync_base)
          if track_id >= 0 and reaper.gmem_read(sync_base + 2) > 0 then
            using_offsets = true
            break
          end
        end
        
        if using_offsets then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55FF55FF) -- Vert pour actif
          reaper.ImGui_Text(ctx, "OFFSETS ACTIFS")
        else
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF5555FF) -- Rouge pour inactif
          reaper.ImGui_Text(ctx, "OFFSETS INACTIFS")
        end
        reaper.ImGui_PopStyleColor(ctx)
        
        -- Informations détaillées
        reaper.ImGui_Separator(ctx)
        
        -- Créer un tableau pour afficher les informations de synchronisation
        if reaper.ImGui_BeginTable(ctx, "sync_info", 6, reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg()) then
            -- En-têtes du tableau
            reaper.ImGui_TableSetupColumn(ctx, "ID Piste")
            reaper.ImGui_TableSetupColumn(ctx, "Nom Piste")
            reaper.ImGui_TableSetupColumn(ctx, "Loop Active")
            reaper.ImGui_TableSetupColumn(ctx, "Longueur (s)")
            reaper.ImGui_TableSetupColumn(ctx, "Position (s)")
            reaper.ImGui_TableSetupColumn(ctx, "Offset (s)")  -- Nouvelle colonne
            reaper.ImGui_TableHeadersRow(ctx)
            
            -- Parcourir toutes les pistes avec des données de synchronisation
            for i = 0, 63 do
                local sync_base = GMEM_MIDI_SYNC_DATA_BASE + i * 3
                local track_id = reaper.gmem_read(sync_base)
                
                if track_id >= 0 then
                    local offset = reaper.gmem_read(sync_base + 1)
                    local measure_duration = reaper.gmem_read(sync_base + 2)
                    
                    -- Obtenir les informations de la piste
                    local track = reaper.GetTrack(0, track_id)
                    if track then
                        local _, track_name = reaper.GetTrackName(track)
                        
                        -- Trouver la loop active
                        local active_loop = "Aucune"
                        local loop_length = 0
                        local item_count = reaper.CountTrackMediaItems(track)
                        local cur_pos = reaper.GetPlayPosition()
                        local current_item = nil
                        
                        for j = 0, item_count - 1 do
                            local item = reaper.GetTrackMediaItem(track, j)
                            local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                            local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                            local item_end = item_pos + item_len
                            
                            if cur_pos >= item_pos and cur_pos < item_end then
                                local take = reaper.GetActiveTake(item)
                                if take and reaper.TakeIsMIDI(take) then
                                    active_loop = reaper.GetTakeName(take)
                                    loop_length = item_len
                                    current_item = item
                                    break
                                end
                            end
                        end
                        
                        -- Ajouter une ligne au tableau
                        reaper.ImGui_TableNextRow(ctx)
                        
                        -- ID de piste
                        reaper.ImGui_TableNextColumn(ctx)
                        reaper.ImGui_Text(ctx, tostring(track_id))
                        
                        -- Nom de piste
                        reaper.ImGui_TableNextColumn(ctx)
                        reaper.ImGui_Text(ctx, track_name)
                        
                        -- Nom de la loop active
                        reaper.ImGui_TableNextColumn(ctx)
                        reaper.ImGui_Text(ctx, active_loop)
                        
                        -- Longueur de la loop
                        reaper.ImGui_TableNextColumn(ctx)
                        if loop_length > 0 then
                            reaper.ImGui_Text(ctx, string.format("%.2f", loop_length))
                        else
                            reaper.ImGui_Text(ctx, "---")
                        end
                        
                        -- Position dans la loop
                        reaper.ImGui_TableNextColumn(ctx)
                        if current_item and loop_length > 0 then
                            local item_pos = reaper.GetMediaItemInfo_Value(current_item, "D_POSITION")
                            local current_offset = cur_pos - item_pos
                            reaper.ImGui_Text(ctx, string.format("%.2f", current_offset))
                        else
                            reaper.ImGui_Text(ctx, "---")
                        end
                        
                        -- Offset stocké dans gmem
                        reaper.ImGui_TableNextColumn(ctx)
                        if offset > 0 then
                            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55FF55FF) -- Vert si offset > 0
                            reaper.ImGui_Text(ctx, string.format("%.3f", offset))
                            reaper.ImGui_PopStyleColor(ctx)
                        else
                            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF5555FF) -- Rouge si offset = 0
                            reaper.ImGui_Text(ctx, "0.000")
                            reaper.ImGui_PopStyleColor(ctx)
                        end
                    end
                end
            end
            
            reaper.ImGui_EndTable(ctx)
        end
        
        -- Section de droite : Messages du service
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, "Messages de PoulpyLoopyService :")
        reaper.ImGui_Separator(ctx)
        
        -- Message d'information
        reaper.ImGui_TextWrapped(ctx, "Les messages du service sont maintenant visibles dans la console de REAPER.")
        reaper.ImGui_TextWrapped(ctx, "Ouvrez la console via Actions → Show console (ou Ctrl+Alt+C)")
        
        -- Boutons d'action
        reaper.ImGui_Separator(ctx)
        
        -- Checkbox pour activer/désactiver l'affichage dans la console
        local console_debug = reaper.gmem_read(GMEM_AFFICHAGE_CONSOLE_DEBUG) == 1
        local clicked, new_console_debug = reaper.ImGui_Checkbox(ctx, "Afficher les messages dans la console", console_debug)
        if clicked then
            reaper.gmem_write(GMEM_AFFICHAGE_CONSOLE_DEBUG, new_console_debug and 1 or 0)
        end
        
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Forcer l'analyse des offsets") then
            reaper.gmem_write(GMEM_FORCE_ANALYZE, 1)
            debug_console("Demande d'analyse forcée des offsets envoyée\n")
        end
        
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Redémarrer le service") then
            -- Exécuter le script de redémarrage du service
            local restart_script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/RestartPoulpyLoopyService.lua"
            if reaper.APIExists("ReaScriptAPI_LoadScript") then
                reaper.ReaScriptAPI_LoadScript(restart_script_path, true)
            end
        end

        reaper.ImGui_EndTabItem(ctx)
      end

      reaper.ImGui_EndTabBar(ctx)
    end

    if reaper.ImGui_Button(ctx,"Fermer la fenêtre") then
      visible=false
    end
  end
  reaper.ImGui_End(ctx)

  return visible
end

local function main()
  if mainWindow() then
    reaper.defer(main)
  else
    -- Détruire le contexte ImGui pour permettre au script de se terminer
  --  reaper.ImGui_DestroyContext(ctx)
  end
end

main()

