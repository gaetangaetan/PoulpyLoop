--[[------------------------------------------------------------------------------
Version: 0021
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

-- Charger les modules
local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/"
local core = dofile(script_path .. "PoulpyLoopyCore.lua")
local ui = dofile(script_path .. "PoulpyLoopyUI.lua")

--------------------------------------------------------------------------------
-- Affichage des versions / dates de modification des fichiers (aide aux tests)
--------------------------------------------------------------------------------
-- Lit la date de derniere modification d'un fichier sur le disque.
-- Necessite l'extension js_ReaScriptAPI (JS_File_Stat) ; repli propre sinon.
local function getFileModifiedDate(path)
  if reaper.APIExists("JS_File_Stat") then
    -- Retour : retval (0 = OK), size, accessedTime, modifiedTime, ...
    local retval, _, _, modified = reaper.JS_File_Stat(path)
    if retval == 0 and modified and modified ~= "" then
      return modified  -- format "AAAA.MM.JJ HH:MM:SS"
    end
  end
  if reaper.file_exists(path) then
    return "(date indisponible - installez js_ReaScriptAPI)"
  end
  return "(fichier introuvable)"
end

local function PrintVersionInfo()
  local files = {
    { label = "PoulpyLoopy.lua",          path = script_path .. "PoulpyLoopy.lua" },
    { label = "PoulpyLoopyCore.lua",      path = script_path .. "PoulpyLoopyCore.lua" },
    { label = "PoulpyLoopyUI.lua",        path = script_path .. "PoulpyLoopyUI.lua" },
    { label = "PoulpyLoopyService.lua",   path = script_path .. "PoulpyLoopyService.lua" },
    { label = "Effects/PoulpyLoop (JSFX)", path = reaper.GetResourcePath() .. "/Effects/PoulpyLoop" },
  }
  local lines = {}
  lines[#lines + 1] = "============================================================\n"
  lines[#lines + 1] = "PoulpyLoopy - versions des fichiers (version Core : " .. tostring(core.VERSION) .. ")\n"
  lines[#lines + 1] = "Derniere modification de chaque fichier :\n"
  lines[#lines + 1] = "------------------------------------------------------------\n"
  for _, f in ipairs(files) do
    lines[#lines + 1] = string.format("  %-26s : %s\n", f.label, getFileModifiedDate(f.path))
  end
  lines[#lines + 1] = "============================================================\n"
  reaper.ShowConsoleMsg(table.concat(lines))
end

--------------------------------------------------------------------------------
-- Initialisation
--------------------------------------------------------------------------------
-- Se connecter à gmem
reaper.gmem_attach("PoulpyLoopy")

-- Afficher les versions/dates des fichiers pour savoir exactement ce qui est testé
PrintVersionInfo()

-- Vérification et démarrage du service
local service_running = reaper.GetExtState("PoulpyLoopyService", "running")
if service_running ~= "1" then
  -- Le service n'est pas en cours d'exécution, on le démarre
  core.debug_console("PoulpyLoopy: Tentative de démarrage de PoulpyLoopyService...\n")
  
  -- Lancer le script de service en tant que script séparé
  local service_path = script_path .. "PoulpyLoopyService.lua"
  core.debug_console("Chemin du script: " .. service_path .. "\n")
  
  -- Vérifier si ReaScriptAPI est disponible
  if reaper.APIExists("ReaScriptAPI_LoadScript") then
    core.debug_console("Méthode de lancement: ReaScriptAPI_LoadScript\n")
    local result = reaper.ReaScriptAPI_LoadScript(service_path, true) -- true = async (en arrière-plan)
    core.debug_console("Résultat du lancement: " .. tostring(result) .. "\n")
  else
    -- Méthode alternative si ReaScriptAPI n'est pas disponible
    core.debug_console("Méthode de lancement: AddRemoveReaScript\n")
    
    -- Obtenir le Command ID dynamiquement
    local cmd_id = reaper.AddRemoveReaScript(true, 0, service_path, true)
    if cmd_id > 0 then
      core.debug_console("Command ID obtenu: " .. tostring(cmd_id) .. "\n")
      reaper.Main_OnCommand(cmd_id, 0)
    else
      core.debug_console("ERREUR: Impossible d'obtenir le Command ID pour " .. service_path .. "\n")
      core.debug_console("Vérifiez que le fichier existe et que SWS est installé.\n")
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
        core.debug_console("PoulpyLoopyService démarré avec succès!\n")
      elseif timeout > 0 then
        reaper.defer(check_service_started)
      else
        core.debug_console("ERREUR: PoulpyLoopyService n'a pas démarré après 3 secondes.\n")
        core.debug_console("Vérifiez que le fichier existe et que SWS/ReaScriptAPI est installé.\n")
      end
    end
    
    reaper.defer(check_service_started)
  end)
else
  core.debug_console("PoulpyLoopy: PoulpyLoopyService est déjà en cours d'exécution.\n")
end

--------------------------------------------------------------------------------
-- Fonction principale
--------------------------------------------------------------------------------
local function main()
  -- Initialiser l'interface utilisateur
  local ctx = ui.init()
  
  -- Boucle principale
  local function loop()
    if ui.DrawMainWindow() then
      reaper.defer(loop)
    end
  end
  
  loop()
end

main()

