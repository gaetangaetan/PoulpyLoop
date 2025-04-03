--[[------------------------------------------------------------------------------
  PoulpyLoopyCore2.lua
  Module contenant les fonctions de sauvegarde et chargement audio pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper

-- Charger les constantes
local script_path = reaper.GetResourcePath() .. "/Scripts/mrpoulpy/"
local constants = dofile(script_path .. "PoulpyLoopyCore0.lua")

-- Module à exporter
local M = {}

-- Fonction pour lire et interpréter le journal
local function read_debug_log()
    local length = reaper.gmem_read(constants.GMEM.LOG_LENGTH)
    if length > 0 then
        reaper.ShowConsoleMsg("\n  Journal de débogage (" .. length .. " entrées) :\n")
        
        -- Variables pour suivre les statistiques
        local notes_found = 0
        local total_data_size = 0
        
        for i = 0, length - 1 do
            local offset = constants.GMEM.LOG_DATA + i * 3
            local msg_type = reaper.gmem_read(offset)
            local value1 = reaper.gmem_read(offset + 1)
            local value2 = reaper.gmem_read(offset + 2)
            
            local message = "    "
            if msg_type == constants.LOG.NOTE_LENGTH then
                if value2 > 0 then
                    message = message .. "Note " .. value1 .. " : longueur = " .. value2
                    notes_found = notes_found + 1
                end
            elseif msg_type == constants.LOG.NOTE_FOUND then
                message = message .. "Note " .. value1 .. " trouvée : taille = " .. value2
                total_data_size = total_data_size + value2
            elseif msg_type == constants.LOG.TOTAL_SIZE then
                message = message .. "Taille totale calculée : " .. value1
            elseif msg_type == constants.LOG.SEARCH_START then
                message = message .. "Début recherche à partir de la note " .. value1
            elseif msg_type == constants.LOG.NO_NOTE then
                message = message .. "Aucune note trouvée"
            elseif msg_type == constants.LOG.STATE then
                message = message .. "État : " .. value1 .. " -> " .. value2
            else
                message = message .. "Message inconnu : type=" .. msg_type .. ", value1=" .. value1 .. ", value2=" .. value2
            end
            reaper.ShowConsoleMsg(message .. "\n")
        end
        
        -- Afficher les statistiques
        reaper.ShowConsoleMsg("\n  Résumé:\n")
        reaper.ShowConsoleMsg("    Notes trouvées: " .. notes_found .. "\n")
        reaper.ShowConsoleMsg("    Taille totale des données: " .. total_data_size .. "\n")
        reaper.ShowConsoleMsg("\n")
    end
end

-- Fonction pour sauvegarder les données audio
function M.SaveAudioData()
    reaper.ShowConsoleMsg("\n---------- Début SaveAudioData() ----------\n")
    
    -- Demander le chemin du fichier à l'utilisateur
    local retval, filepath = reaper.JS_Dialog_BrowseForSaveFile("Sauvegarder les données audio", "", "", "Fichiers audio (*.pla)\0*.pla\0Tous les fichiers (*.*)\0*.*\0\0")
    if not retval then
        reaper.ShowConsoleMsg("Opération annulée par l'utilisateur.\n")
        return
    end
    
    -- Créer le fichier
    local file = io.open(filepath, "wb")
    if not file then
        reaper.ShowConsoleMsg("ERREUR: Impossible d'ouvrir le fichier pour écriture.\n")
        reaper.ShowMessageBox("Erreur lors de la création du fichier", "Erreur", 0)
        return
    end
    
    -- Trouver toutes les instances actives de PoulpyLoop
    local active_instances = {}
    for i = 0, 63 do
        local stats_base = constants.GMEM.STATS_BASE + i * 3
        local memory_used = reaper.gmem_read(stats_base)
        if memory_used > 0 then
            table.insert(active_instances, i)
        end
    end
    
    reaper.ShowConsoleMsg("Instances actives trouvées: " .. #active_instances .. "\n")
    for i, id in ipairs(active_instances) do
        reaper.ShowConsoleMsg("  Instance #" .. i .. " : ID=" .. id .. "\n")
    end
    
    -- Écrire le nombre d'instances
    file:write(string.pack("<I4", #active_instances))
    
    -- Variables pour le traitement asynchrone
    local current_instance = 1
    local current_state = "init"  -- États possibles: init, waiting_response, processing_data
    local last_action_time = 0
    local timeout_duration = 1.0  -- 1 seconde de timeout
    
    local function process_next_step()
        if current_instance > #active_instances then
            -- Toutes les instances ont été traitées
            file:close()
            reaper.ShowConsoleMsg("\nFichier fermé. Opération terminée.\n")
            reaper.ShowConsoleMsg("---------- Fin SaveAudioData() ----------\n")
            reaper.ShowMessageBox("Sauvegarde terminée", "Succès", 0)
            return
        end
        
        local instance_id = active_instances[current_instance]
        local current_time = reaper.time_precise()
        
        if current_state == "init" then
            -- Initialiser la commande de sauvegarde
            reaper.ShowConsoleMsg("\nTraitement de l'instance ID=" .. instance_id .. "\n")
            reaper.gmem_write(constants.GMEM.UI_COMMAND, 1)  -- Commande de sauvegarde
            reaper.gmem_write(constants.GMEM.INSTANCE_ID, instance_id)
            reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)  -- Donner le contrôle à PoulpyLoop
            reaper.gmem_write(constants.GMEM.SAVE_COMPLETE, 0)  -- Réinitialiser le signal de fin
            current_state = "waiting_response"
            last_action_time = current_time
            reaper.ShowConsoleMsg("  Envoi de la commande de sauvegarde\n")
            
        elseif current_state == "waiting_response" then
            -- Vérifier si l'instance a répondu
            if reaper.gmem_read(constants.GMEM.WRITING_RIGHT) == 0 then
                -- L'instance a répondu
                local data_length = reaper.gmem_read(constants.GMEM.DATA_LENGTH)
                local save_complete = reaper.gmem_read(constants.GMEM.SAVE_COMPLETE)
                local total_length = reaper.gmem_read(constants.GMEM.TOTAL_LENGTH)
                
                reaper.ShowConsoleMsg(string.format("  Réponse reçue: length=%d, complete=%d, total=%d\n", 
                    data_length, save_complete, total_length))
                
                if data_length > 0 then
                    -- Si c'est un bloc de metadata (4 valeurs)
                    if data_length == 4 then
                        local note_id = reaper.gmem_read(constants.GMEM.DATA_START)
                        local note_mode = reaper.gmem_read(constants.GMEM.DATA_START + 1)
                        local note_length = reaper.gmem_read(constants.GMEM.DATA_START + 2)
                        local note_units = reaper.gmem_read(constants.GMEM.DATA_START + 3)
                        reaper.ShowConsoleMsg(string.format("    Metadata: note=%d, mode=%d, length=%d, units=%d\n",
                            note_id, note_mode, note_length, note_units))
                        
                        -- Écrire les metadata dans le fichier
                        file:write(string.pack("<I4I4I4I4", note_id, note_mode, note_length, note_units))
                    else
                        reaper.ShowConsoleMsg(string.format("    Données audio: %d échantillons\n", data_length))
                        -- Écrire les données audio dans le fichier
                        for i = 0, data_length - 1 do
                            local value = reaper.gmem_read(constants.GMEM.DATA_START + i)
                            file:write(string.pack("<f", value))
                        end
                    end
                    
                    -- Continuer avec la même instance
                    reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)
                    last_action_time = current_time
                    
                elseif save_complete ~= 0 then
                    -- L'instance a terminé
                    reaper.ShowConsoleMsg("  Instance terminée (save_complete = " .. save_complete .. ")\n")
                    read_debug_log()
                    current_instance = current_instance + 1
                    current_state = "init"
                    
                else
                    -- data_length = 0 mais pas de signal de fin
                    -- Attendre plus longtemps avant de décider qu'il y a un problème
                    if current_time - last_action_time > timeout_duration then
                        reaper.ShowConsoleMsg("  TIMEOUT: Aucune donnée reçue après " .. timeout_duration .. " secondes\n")
                        -- Vérifier l'état des variables de communication
                        reaper.ShowConsoleMsg(string.format("  État: command=%d, instance=%d, writing=%d\n",
                            reaper.gmem_read(constants.GMEM.UI_COMMAND),
                            reaper.gmem_read(constants.GMEM.INSTANCE_ID),
                            reaper.gmem_read(constants.GMEM.WRITING_RIGHT)))
                        current_instance = current_instance + 1
                        current_state = "init"
                    else
                        -- Continuer d'attendre
                        reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)
                    end
                end
                
            elseif current_time - last_action_time > timeout_duration * 2 then
                -- Timeout - passer à l'instance suivante
                reaper.ShowConsoleMsg("  TIMEOUT: l'instance n'a pas répondu après " .. (timeout_duration * 2) .. " secondes\n")
                current_instance = current_instance + 1
                current_state = "init"
            end
        end
        
        -- Programmer la prochaine itération
        reaper.defer(process_next_step)
    end
    
    -- Démarrer le traitement asynchrone
    reaper.defer(process_next_step)
end

-- Fonction pour charger les données audio
function M.LoadAudioData()
    reaper.ShowConsoleMsg("\n---------- Début LoadAudioData() ----------\n")
    local retval, filepath = reaper.JS_Dialog_BrowseForOpenFiles("Charger les données audio", reaper.GetProjectPath(), "save.pla","PoulpyLoop audio data (*.pla)\0*.pla\0Tous les fichiers (*.*)\0*.*\0\0", 0)
    if retval then
        local file = io.open(filepath, "rb")  -- Mode binaire
        if file then
            -- Lecture du nombre d'instances
            local num_instances = string.unpack("I", file:read(4))
            reaper.ShowConsoleMsg("Nombre d'instances dans le fichier: " .. num_instances .. "\n")
            
            -- Pour l'instant, on se contente d'afficher les données
            local content = "Nombre d'instances: " .. num_instances .. "\n\n"
            
            for i = 1, num_instances do
                -- Lire l'ID de l'instance
                local instance_id = string.unpack("I", file:read(4))
                
                -- Lire la taille totale des données
                local total_length = string.unpack("I", file:read(4))
                
                content = content .. "Instance " .. instance_id .. " : " .. total_length .. " échantillons\n"
                
                -- Sauter les données de cette instance (pour l'instant)
                if total_length > 0 then
                    -- Format de chaque échantillon: double (8 octets)
                    file:seek("cur", total_length * 8)
                end
            end
            
            file:close()
            reaper.ShowConsoleMsg("---------- Fin LoadAudioData() ----------\n")
            reaper.ShowMessageBox(content, "Contenu du fichier", 0)
        else
            reaper.ShowConsoleMsg("ERREUR: Impossible d'ouvrir le fichier pour lecture.\n")
            reaper.ShowMessageBox("Erreur lors de la lecture du fichier.", "Erreur", 0)
        end
    else
        reaper.ShowConsoleMsg("Opération annulée par l'utilisateur.\n")
    end
end

return M 