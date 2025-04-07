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
    reaper.ShowConsoleMsg("GMEM_BUFFER = " .. constants.GMEM.DATA_BUFFER .. "\n")
    for i, id in ipairs(active_instances) do
        reaper.ShowConsoleMsg("  Instance #" .. i .. " : ID=" .. id .. "\n")
    end
    
    -- Écrire le nombre d'instances
    file:write(string.pack("<l", #active_instances))
    
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
        
        local instance_data_size = reaper.gmem_read(constants.GMEM.DATA_SIZE)
        reaper.ShowConsoleMsg("\ninstance_data_size: " .. instance_data_size)
        
        -- Écrire la taille dans le fichier
        file:write(string.pack("<d", instance_data_size))

                -- Attendre que l'instance soit prête avec un timeout de 5 secondes
                start_time = os.clock()
                while reaper.gmem_read(constants.GMEM.WRITING_RIGHT) == 1 do
                    reaper.defer(function() end)
                    if os.clock() - start_time > 5.0 then  -- 5 secondes de timeout
                        reaper.ShowMessageBox("Timeout lors de la sauvegarde. L'instance ne répond pas.", "Erreur", 0)
                        file:close()
                        return
                    end
                end
        -- Lire et écrire les données par blocs de 30000 valeurs
        local remaining_values = instance_data_size -- On initialise le nombre de valeurs à restantes à la taille totale de la mémoire utilisée par l'instance
        local current_pos = constants.GMEM.DATA_BUFFER
        
        while remaining_values > 0 do
            local block_size = math.min(30000, remaining_values)
            
            reaper.ShowConsoleMsg("remaining values = " .. remaining_values .. "\n")
            
            
            -- Lire le bloc de données
            --local data = {}
            --for i = 0, block_size - 1 do
            --    data[i + 1] = reaper.gmem_read(current_pos + i)
            --end
            
            -- Écrire le bloc dans le fichier
            --for _, value in ipairs(data) do
            --    file:write(string.pack("<d", value))
            --end
            
            -- Lire les données dans le buffer et les recopier dans le fichier
            
            for i = 0, block_size - 1 do
                value = reaper.gmem_read(current_pos + i)
                file:write(string.pack("<d", value))
            end
                        
            
            remaining_values = remaining_values - block_size
            current_pos = constants.GMEM.DATA_BUFFER -- on retourne au début du buffer
            
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
    local retval, filepath = reaper.JS_Dialog_BrowseForOpenFiles("Charger les données audio", "", "", "PoulpyLoop Audio (*.pla)\0*.pla\0",0)
    if not retval then return end
    
    -- Lire le fichier de sauvegarde
    local file = io.open(filepath, "rb")
    if not file then
        reaper.ShowConsoleMsg("Erreur: Impossible d'ouvrir le fichier de sauvegarde\n")
        return
    end

    -- Lire l'en-tête pour obtenir le nombre d'instances
    local num_instances = file:read(4)
    if not num_instances then
        reaper.ShowConsoleMsg("Erreur: Impossible de lire le nombre d'instances\n")
        file:close()
        return
    end
    num_instances = string.unpack("<I4", num_instances)
    reaper.ShowConsoleMsg(string.format("Nombre d'instances dans la sauvegarde: %d\n", num_instances))

    -- Pour chaque instance
    for i = 0, num_instances - 1 do
        -- Lire la taille des données de cette instance (8 octets, double précision)
        local instance_size_data = file:read(8)
        if not instance_size_data then
            reaper.ShowConsoleMsg(string.format("Erreur: Impossible de lire la taille de l'instance %d\n", i))
            break
        end
        local instance_size = string.unpack("<d", instance_size_data)
        reaper.ShowConsoleMsg(string.format("Instance %d: taille des données = %d octets\n", i, instance_size))

        -- Lire les données de l'instance
        local instance_data = file:read(instance_size)
        if not instance_data then
            reaper.ShowConsoleMsg(string.format("Erreur: Impossible de lire les données de l'instance %d\n", i))
            break
        end

        -- Écrire la taille dans gmem
        reaper.gmem_write(constants.GMEM.DATA_SIZE, instance_size)
        reaper.ShowConsoleMsg(string.format("Instance %d: taille communiquée à PoulpyLoop = %d\n", i, instance_size))

        -- Copier les données dans gmem par blocs
        local pos = 1
        while pos <= instance_size do
            local block_size = math.min(30000, instance_size - pos + 1)
            local block = instance_data:sub(pos, pos + block_size - 1)
            
            -- Copier le bloc dans gmem
            for j = 1, block_size do
                reaper.gmem_write(constants.GMEM.DATA_BUFFER + j - 1, string.byte(block, j))
            end
            
            -- Signaler à PoulpyLoop qu'il peut lire le bloc
            reaper.gmem_write(constants.GMEM.WRITING_RIGHT, 1)
            reaper.gmem_write(constants.GMEM.UI_COMMAND, 2)
            reaper.gmem_write(constants.GMEM.INSTANCE_ID, i)
            
            -- Attendre que PoulpyLoop ait lu le bloc
            while reaper.gmem_read(constants.GMEM.WRITING_RIGHT) == 1 do
                reaper.defer(function() end)
            end
            
            pos = pos + block_size
            reaper.ShowConsoleMsg(string.format("Instance %d: %d/%d octets lus\n", i, pos - 1, instance_size))
        end
    end

    file:close()
    reaper.ShowConsoleMsg("Chargement terminé\n")
    reaper.ShowConsoleMsg("---------- Fin LoadAudioData() ----------\n")
    reaper.ShowMessageBox("Chargement terminé", "Succès", 0)
end

return M 