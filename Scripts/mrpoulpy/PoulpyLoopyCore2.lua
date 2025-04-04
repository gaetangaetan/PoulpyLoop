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
    
    -- Demander le nom du fichier à l'utilisateur
    local retval, filepath = reaper.JS_Dialog_BrowseForSaveFile("Sauvegarder les données audio", "", "", "PoulpyLoop Audio (*.pla)\0*.pla\0")
    if not retval then return end
    
    -- Créer le fichier
    local file = io.open(filepath, "wb")
    if not file then return end
    
    -- Trouver les instances actives
    local active_instances = {}
    for i = 0, 63 do
        if reaper.gmem_read(constants.GMEM.STATS_BASE + i * 3) > 0 then
            table.insert(active_instances, i)
        end
    end
    
    reaper.ShowConsoleMsg("Instances actives trouvées: " .. #active_instances .. "\n")
    for i, id in ipairs(active_instances) do
        reaper.ShowConsoleMsg("  Instance #" .. i .. " : ID=" .. id .. "\n")
    end
    
    -- Écrire le nombre d'instances
    file:write(string.pack("<I4", #active_instances))
    
    -- Pour chaque instance active
    for _, instance_id in ipairs(active_instances) do
        -- Envoyer la commande de sauvegarde à l'instance
        reaper.gmem_write(constants.GMEM.INSTANCE_ID, instance_id)
        reaper.gmem_write(constants.GMEM.UI_COMMAND, 1)  -- Commande de sauvegarde
        reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)
        
        -- Attendre que l'instance soit prête avec un timeout de 5 secondes
        local start_time = os.clock()
        while reaper.gmem_read(constants.GMEM.WRITING_RIGHT) == 1 do
            reaper.defer(function() end)
            if os.clock() - start_time > 5.0 then  -- 5 secondes de timeout
                reaper.ShowMessageBox("Timeout lors de la sauvegarde. L'instance ne répond pas.", "Erreur", 0)
                file:close()
                return
            end
        end
        
        -- Lire la taille de la mémoire utilisée (en nombre d'unités)
        reaper.ShowConsoleMsg("\nGMEM.DATA_SIZE: " .. constants.GMEM.DATA_SIZE)
        local next_free_unit = reaper.gmem_read(constants.GMEM.DATA_SIZE)
        
        -- Écrire la taille dans le fichier
        file:write(string.pack("<I4", next_free_unit))
        
        -- Lire et écrire les données par blocs de 30000 valeurs
        local total_values = next_free_unit  -- Nombre de valeurs à lire
        local remaining_values = total_values
        local current_pos = constants.GMEM.DATA_BUFFER
        
        while remaining_values > 0 do
            local block_size = math.min(30000, remaining_values)
            
            -- Lire le bloc de données
            local data = {}
            for i = 0, block_size - 1 do
                data[i + 1] = reaper.gmem_read(current_pos + i)
            end
            
            -- Écrire le bloc dans le fichier
            for _, value in ipairs(data) do
                file:write(string.pack("<d", value))
            end
            
            remaining_values = remaining_values - block_size
            current_pos = current_pos + block_size
            
            -- Attendre que l'instance soit prête pour le prochain bloc avec timeout
            reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)
            start_time = os.clock()
            while reaper.gmem_read(constants.GMEM.WRITING_RIGHT) == 1 do
                reaper.defer(function() end)
                if os.clock() - start_time > 5.0 then  -- 5 secondes de timeout
                    reaper.ShowMessageBox("Timeout lors de la sauvegarde. L'instance ne répond pas.", "Erreur", 0)
                    file:close()
                    return
                end
            end
        end
    end
    
    file:close()
    reaper.ShowConsoleMsg("\nFichier fermé. Opération terminée.\n")
    reaper.ShowConsoleMsg("---------- Fin SaveAudioData() ----------\n")
    reaper.ShowMessageBox("Sauvegarde terminée", "Succès", 0)
end

-- Fonction pour charger les données audio
function M.LoadAudioData()
    reaper.ShowConsoleMsg("\n---------- Début LoadAudioData() ----------\n")
    
    -- Demander le fichier à l'utilisateur
    local retval, filepath = reaper.JS_Dialog_BrowseForOpenFile("Charger les données audio", "", "", "PoulpyLoop Audio (*.pla)\0*.pla\0")
    if not retval then return end
    
    -- Ouvrir le fichier
    local file = io.open(filepath, "rb")
    if not file then return end
    
    -- Lire le nombre d'instances
    local num_instances = string.unpack("<I4", file:read(4))
    
    reaper.ShowConsoleMsg("Nombre d'instances dans le fichier: " .. num_instances .. "\n")
    
    -- Pour chaque instance
    for i = 1, num_instances do
        -- Lire le nombre d'unités pour cette instance
        local next_free_unit = string.unpack("<I4", file:read(4))
        
        -- Envoyer la commande de chargement à l'instance
        reaper.gmem_write(constants.GMEM.INSTANCE_ID, i - 1)  -- Les IDs commencent à 0
        reaper.gmem_write(constants.GMEM.UI_COMMAND, 2)  -- Commande de chargement
        reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)
        
        -- Attendre que l'instance soit prête
        while reaper.gmem_read(constants.GMEM.WRITING_RIGHT) == 1 do
            reaper.defer(function() end)
        end
        
        -- Lire et envoyer les données par blocs de 30000 valeurs
        local total_values = next_free_unit  -- Nombre de valeurs à lire
        local remaining_values = total_values
        local current_pos = constants.GMEM.DATA_BUFFER
        
        while remaining_values > 0 do
            local block_size = math.min(30000, remaining_values)
            
            -- Lire le bloc depuis le fichier
            local data = {}
            for j = 1, block_size do
                data[j] = string.unpack("<d", file:read(8))
            end
            
            -- Écrire le bloc dans gmem
            for j, value in ipairs(data) do
                reaper.gmem_write(current_pos + j - 1, value)
            end
            
            remaining_values = remaining_values - block_size
            current_pos = current_pos + block_size
            
            -- Signaler à l'instance qu'on a écrit un bloc
            reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)
            while reaper.gmem_read(constants.GMEM.WRITING_RIGHT) == 1 do
                reaper.defer(function() end)
            end
        end
    end
    
    file:close()
    reaper.ShowConsoleMsg("---------- Fin LoadAudioData() ----------\n")
    reaper.ShowMessageBox("Chargement terminé", "Succès", 0)
end

return M 