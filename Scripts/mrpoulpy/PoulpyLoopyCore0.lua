--[[------------------------------------------------------------------------------
  PoulpyLoopyCore0.lua
  Module contenant les constantes et types de base pour PoulpyLoopy
------------------------------------------------------------------------------]]

local reaper = reaper

-- Module à exporter
local M = {}

--------------------------------------------------------------------------------
-- Version
--------------------------------------------------------------------------------
M.VERSION = "0015"

--------------------------------------------------------------------------------
-- Debug et développement
--------------------------------------------------------------------------------
M.DEBUG = {
    DEV = false,  -- Mode développement, mettre à true seulement pour déboguer
    AFFICHAGE_CONSOLE = 17100  -- Contrôle de l'affichage console
}

--------------------------------------------------------------------------------
-- Couleurs
--------------------------------------------------------------------------------
M.COLORS = {
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

--------------------------------------------------------------------------------
-- Types de loops
--------------------------------------------------------------------------------
M.LOOP_TYPES = {"RECORD", "OVERDUB", "PLAY", "MONITOR", "UNUSED"}

--------------------------------------------------------------------------------
-- Indices gmem
--------------------------------------------------------------------------------
M.GMEM = {
    -- Modes de fonctionnement
    RECORD_MONITOR_MODE = 0,     -- Mode d'enregistrement des loops MONITOR
    PLAYBACK_MODE = 1,          -- Mode LIVE/PLAYBACK
    
    -- Statistiques et gestion des instances
    STATS_BASE = 2,             -- Base pour les statistiques (64 instances * 3 valeurs)
    NEXT_INSTANCE_ID = 194,     -- Prochain ID d'instance disponible
    MONITORING_STOP_BASE = 195, -- Base pour le monitoring à l'arrêt (64 instances)
    
    -- Données des notes
    NOTE_START_POS_BASE = 259,  -- Base pour les positions de début des notes (64 instances * 128 notes)
    LOOP_LENGTH_BASE = 8451,    -- Base pour les longueurs des boucles (64 instances * 128 notes)
    
    -- Synchronisation et debug
    FORCE_ANALYZE = 16000,      -- Force l'analyse des offsets
    MIDI_SYNC_DATA_BASE = 16001,-- Base pour les données de synchronisation MIDI (64 pistes * 3 valeurs)
    
    -- Messages et journalisation
    AFFICHAGE_CONSOLE_DEBUG = 16998, -- Activation/désactivation du debug console
    MESSAGE_WRITE_POS = 16999,  -- Position d'écriture actuelle des messages
    MESSAGE_BASE = 17000,       -- Base pour les messages (10000 caractères)
    MESSAGE_END = 18000,        -- Fin de la mémoire des messages (juste pour information)
    -- Communication UI-JSFX
    UI_COMMAND = 29000,         -- Commande de l'UI (0=normal, 1=sauvegarde, 2=chargement)
    INSTANCE_ID = 29001,        -- ID de l'instance sollicitée
    DATA_LENGTH = 29002,        -- Longueur des données
    WRITING_RIGHT = 29003,      -- Qui a le droit d'écrire (0=PoulpyLoopy, 1=PoulpyLoop)
    TOTAL_LENGTH = 29004,       -- Taille totale des données
    SAVE_COMPLETE = 29005,      -- Signal de fin de sauvegarde
    DEBUG_CODE = 29006,         -- Code de débogage
    DEBUG_VALUE = 29007,        -- Valeur associée au code de débogage
    LOG_START = 29008,          -- Début du journal
    LOG_LENGTH = 29009,         -- Nombre d'entrées dans le journal
    LOG_DATA = 29010,           -- Début des données du journal
    DATA_SIZE = 29011,          -- Taille totale de la mémoire utilisée par une instance 
    DATA_BUFFER = 30000,        -- Début du buffer de données
    DATA_BUFFER_END = 59999     -- Fin du buffer de données
}

--------------------------------------------------------------------------------
-- Types de messages du journal
--------------------------------------------------------------------------------
M.LOG = {
    NOTE_LENGTH = 1,    -- Longueur d'une note (value1=note_id, value2=length)
    NOTE_FOUND = 2,     -- Note trouvée (value1=note_id, value2=data_size)
    TOTAL_SIZE = 3,     -- Taille totale calculée (value1=size, value2=0)
    SEARCH_START = 4,   -- Début de recherche (value1=start_from, value2=0)
    NO_NOTE = 5,        -- Aucune note trouvée (value1=0, value2=0)
    STATE = 6          -- Changement d'état (value1=old_state, value2=new_state)
}

--------------------------------------------------------------------------------
-- Constantes de base
--------------------------------------------------------------------------------
M.CONSTANTS = {
    NUM_NOTES = 128,
    UNIT_SIZE = 4096 * 64,
    BLOCK_SIZE = 1024,           -- Taille des blocs de données pour la sauvegarde
    MODULATION_COUNT = 10,       -- Nombre de paires de valeurs (début/fin)
    MODULATION_SIZE = 20         -- Taille totale du tableau (10 paires * 2)
}

--------------------------------------------------------------------------------
-- Codes de débogage
--------------------------------------------------------------------------------
M.DEBUG_CODES = {
    NONE = 0,              -- Pas de message
    FIND_NOTE_START = 1,   -- Début de recherche de note
    FIND_NOTE_FOUND = 2,   -- Note trouvée
    FIND_NOTE_NONE = 3,    -- Aucune note trouvée
    SAVE_START = 4,        -- Début de sauvegarde
    SAVE_NO_DATA = 5,      -- Rien à sauvegarder
    SAVE_NOTE_START = 6,   -- Début sauvegarde d'une note
    SAVE_NOTE_DATA = 7,    -- Envoi données d'une note
    SAVE_NOTE_END = 8      -- Fin sauvegarde d'une note
}

--------------------------------------------------------------------------------
-- Fonction pour générer les définitions JSFX
--------------------------------------------------------------------------------
function M.generate_jsfx_constants()
    local output = "// GENERATED_CONSTANTS_START\n\n"
    output = output .. "// Ce code a été généré automatiquement par PoulpyLoopyCore0.lua\n"
    output = output .. "// Ne pas modifier manuellement\n\n"
    
    -- Générer les constantes de base
    output = output .. "// Constantes de base\n"
    local sorted_constants = {}
    for name, value in pairs(M.CONSTANTS) do
        table.insert(sorted_constants, {name = name, value = value})
    end
    table.sort(sorted_constants, function(a, b) return a.value < b.value end)
    for _, item in ipairs(sorted_constants) do
        local jsfx_name = item.name:upper()
        output = output .. string.format("%s = %d;\n", jsfx_name, item.value)
    end
    output = output .. "\n"
    
    -- Générer les définitions GMEM
    output = output .. "// Indices GMEM\n"
    local sorted_gmem = {}
    for name, value in pairs(M.GMEM) do
        table.insert(sorted_gmem, {name = name, value = value})
    end
    table.sort(sorted_gmem, function(a, b) return a.value < b.value end)
    for _, item in ipairs(sorted_gmem) do
        local jsfx_name = "GMEM_" .. item.name:upper()
        output = output .. string.format("%s = %d;\n", jsfx_name, item.value)
    end
    output = output .. "\n"
    
    -- Générer les définitions pour les types de loops
    output = output .. "// Types de loops\n"
    for i, loop_type in ipairs(M.LOOP_TYPES) do
        local jsfx_name = "LOOP_TYPE_" .. loop_type
        output = output .. string.format("%s = %d;\n", jsfx_name, i - 1)
    end
    output = output .. "\n"
    
    -- Générer les codes de débogage
    output = output .. "// Codes de débogage\n"
    local sorted_debug = {}
    for name, value in pairs(M.DEBUG_CODES) do
        table.insert(sorted_debug, {name = name, value = value})
    end
    table.sort(sorted_debug, function(a, b) return a.value < b.value end)
    for _, item in ipairs(sorted_debug) do
        local jsfx_name = "DEBUG_" .. item.name
        output = output .. string.format("%s = %d;\n", jsfx_name, item.value)
    end
    output = output .. "\n"
    
    -- Générer la version
    output = output .. "// Version\n"
    output = output .. string.format("VERSION = \"%s\";\n", M.VERSION)
    output = output .. "\n"
    
    -- Générer les constantes de debug
    output = output .. "// Debug\n"
    local sorted_debug_const = {}
    for name, value in pairs(M.DEBUG) do
        -- Convertir les booléens en nombres
        local numeric_value = type(value) == "boolean" and (value and 1 or 0) or value
        table.insert(sorted_debug_const, {name = name, value = numeric_value})
    end
    table.sort(sorted_debug_const, function(a, b) return a.value < b.value end)
    for _, item in ipairs(sorted_debug_const) do
        local jsfx_name = "DEBUG_" .. item.name:upper()
        output = output .. string.format("%s = %d;\n", jsfx_name, item.value)
    end
    
    output = output .. "\n// GENERATED_CONSTANTS_END\n"
    return output
end

--------------------------------------------------------------------------------
-- Fonction pour normaliser une chaîne de texte (supprime les espaces superflus)
--------------------------------------------------------------------------------
function M.normalize_string(str)
    -- Supprimer les espaces en début et fin de ligne
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    -- Remplacer les séquences d'espaces par un seul espace
    str = str:gsub("%s+", " ")
    -- Supprimer les espaces avant les points-virgules
    str = str:gsub("%s+;", ";")
    return str
end

-- Fonction pour mettre à jour le fichier JSFX
function M.update_jsfx_constants()
    -- Remonter de deux niveaux depuis le dossier Scripts/mrpoulpy et aller dans Effects
    local jsfx_path = reaper.GetResourcePath() .. "/Effects/PoulpyLoop"
    
    -- Ouvrir d'abord le fichier en lecture seule
    local file = io.open(jsfx_path, "r")
    if not file then
        return false, "Impossible d'ouvrir le fichier JSFX en lecture : " .. jsfx_path
    end
    
    -- Lire le contenu actuel
    local content = file:read("*all")
    file:close()
    
    -- Chercher les marqueurs de début et fin
    local start_marker = "// GENERATED_CONSTANTS_START"
    local end_marker = "// GENERATED_CONSTANTS_END"
    
    local start_pos = content:find(start_marker)
    local end_pos = content:find(end_marker)
    
    if not start_pos or not end_pos then
        return false, "Marqueurs non trouvés dans le fichier JSFX"
    end
    
    -- Extraire le bloc de constantes actuel
    local current_constants = content:sub(start_pos, end_pos + #end_marker)
    
    -- Générer le nouveau bloc de constantes
    local new_constants = M.generate_jsfx_constants()
    
    -- Si les blocs sont identiques, ne rien faire
    local normalized_current = M.normalize_string(current_constants)
    local normalized_new = M.normalize_string(new_constants)
    
    if normalized_current == normalized_new then
        return true, "Les constantes JSFX sont déjà à jour"
    end
    
    -- Les blocs sont différents, mettre à jour le fichier
    -- Ouvrir le fichier en écriture
    file = io.open(jsfx_path, "w")
    if not file then
        return false, "Impossible d'ouvrir le fichier JSFX en écriture : " .. jsfx_path
    end
    
    -- Remplacer la section entre les marqueurs
    local new_content = content:sub(1, start_pos - 1) 
        .. new_constants
        .. content:sub(end_pos + #end_marker + 1)
    
    -- Écrire le nouveau contenu
    file:write(new_content)
    file:close()
    
    -- Notifier l'utilisateur de la mise à jour
    reaper.ShowMessageBox("Le bloc de constantes dans PoulpyLoop a été mis à jour.", "Mise à jour des constantes", 0)
    
    return true, "Constantes JSFX mises à jour avec succès"
end

return M 