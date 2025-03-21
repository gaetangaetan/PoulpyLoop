-- PoulpyLoopyService.lua
-- Service en arrière-plan pour maintenir gmem actif

local reaper = reaper

-- Fonction pour afficher des messages dans la console REAPER
local function debug_console(message)
    reaper.ShowConsoleMsg("[PoulpyLoopyService] " .. message .. "\n")
end

debug_console("Démarrage du service...")

-- Se connecter à gmem
reaper.gmem_attach("PoulpyLoopy")
debug_console("Connexion à gmem:PoulpyLoopy établie")

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
-- Pour chaque piste avec PoulpyLoop:
-- GMEM_MIDI_SYNC_DATA_BASE + track_id*3 + 0 = ID de la piste
-- GMEM_MIDI_SYNC_DATA_BASE + track_id*3 + 1 = Position de début de la note (en secondes)
-- GMEM_MIDI_SYNC_DATA_BASE + track_id*3 + 2 = Durée de la mesure (en secondes)

-- Espace pour les messages dans gmem
local GMEM_MESSAGE_BASE = 17000      -- gmem[17000] à gmem[17000+9999] pour les messages (10000 caractères)
local GMEM_MESSAGE_WRITE_POS = 16999  -- gmem[16999] pour la position d'écriture actuelle

-- S'assurer que les adresses mémoire sont différentes
assert(GMEM_MESSAGE_BASE ~= GMEM_MESSAGE_WRITE_POS, "Les adresses GMEM_MESSAGE_BASE et GMEM_MESSAGE_WRITE_POS doivent être différentes")

-- Fonction pour réinitialiser complètement l'espace de message
local function reset_message_space()
    reaper.gmem_write(GMEM_MESSAGE_WRITE_POS, 0)
    for i = 0, 9999 do
        reaper.gmem_write(GMEM_MESSAGE_BASE + i, 0)
    end
end

-- Fonction pour écrire un message dans la mémoire partagée
local function write_message_to_gmem(message)
    -- S'assurer que le message n'est pas vide
    if not message or message == "" then
        return 0
    end
    
    -- Ajouter un retour à la ligne au message
    message = message .. "\n"
    
    -- Obtenir la position d'écriture actuelle
    local write_pos = reaper.gmem_read(GMEM_MESSAGE_WRITE_POS)
    
    -- Vérifier s'il reste assez d'espace
    if write_pos + #message > 10000 then
        -- Plus d'espace disponible
        return 0
    end
    
    -- Écrire le message
    for i = 1, #message do
        reaper.gmem_write(GMEM_MESSAGE_BASE + write_pos + (i-1), string.byte(message:sub(i,i)))
    end
    
    -- Mettre à jour la position d'écriture
    reaper.gmem_write(GMEM_MESSAGE_WRITE_POS, write_pos + #message)
    
    return #message
end

-- Vérifier si une instance du service est déjà en cours d'exécution
local instance_running = reaper.GetExtState("PoulpyLoopyService", "running")
if instance_running == "1" then
  -- Une instance est déjà en cours d'exécution, on quitte
  debug_console("Une instance est déjà en cours d'exécution, arrêt de cette instance")
  write_message_to_gmem("PoulpyLoopyService est déjà actif")
  return
end

debug_console("Aucune instance en cours d'exécution trouvée, démarrage du service")

-- Marquer le service comme en cours d'exécution
reaper.SetExtState("PoulpyLoopyService", "running", "1", false)
debug_console("État du service marqué comme 'en cours d'exécution'")

-- Fonction pour tester l'écriture et la lecture du message
local function test_message_system()
    debug_console("Test du système de messages...")
    write_message_to_gmem("===== TEST DU SYSTÈME DE MESSAGES =====")
    
    -- Réinitialiser l'espace message
    reset_message_space()
    
    -- Écrire un message de test
    local test_message = "Test de communication à " .. os.date("%H:%M:%S")
    local written_length = write_message_to_gmem(test_message)
    debug_console("Message de test écrit: " .. test_message .. " (" .. written_length .. " octets)")
    
    write_message_to_gmem("Message de test écrit avec succès.\n===== FIN DU TEST =====")
    debug_console("Test du système de messages terminé")
end

-- Initialiser les valeurs dans gmem si elles ne sont pas déjà définies
if reaper.gmem_read(GMEM_RECORD_MONITOR_MODE) == 0 and reaper.gmem_read(GMEM_PLAYBACK_MODE) == 0 then
    reaper.gmem_write(GMEM_RECORD_MONITOR_MODE, 0)  -- Par défaut, pas d'enregistrement des loops MONITOR
    reaper.gmem_write(GMEM_PLAYBACK_MODE, 0)        -- Par défaut, mode LIVE
    write_message_to_gmem("PoulpyLoopyService: Valeurs initialisées")
    debug_console("Valeurs gmem initialisées")
end

-- Initialiser le compteur d'ID d'instance si nécessaire
if reaper.gmem_read(GMEM_NEXT_INSTANCE_ID) == 0 then
    reaper.gmem_write(GMEM_NEXT_INSTANCE_ID, 0)
end

-- Initialiser l'espace mémoire pour les statistiques (64 instances max)
for i = 0, 63 do
    local stats_base = GMEM_STATS_BASE + i * 3
    -- Initialiser uniquement si la valeur est 0 (pas déjà définie)
    if reaper.gmem_read(stats_base) == 0 then
        reaper.gmem_write(stats_base, 0)      -- Mémoire utilisée (Mo)
        reaper.gmem_write(stats_base + 1, 0)  -- Temps restant (s)
        reaper.gmem_write(stats_base + 2, 0)  -- Nombre de notes
    end
end

-- Initialiser l'espace mémoire pour le monitoring à l'arrêt
for i = 0, 63 do
    if reaper.gmem_read(GMEM_MONITORING_STOP_BASE + i) == 0 then
        reaper.gmem_write(GMEM_MONITORING_STOP_BASE + i, 0)  -- Par défaut, monitoring à l'arrêt désactivé
    end
end

-- Initialiser l'espace mémoire pour les positions de début des notes
for i = 0, 63 do
    for note = 0, 127 do
        local pos_index = GMEM_NOTE_START_POS_BASE + i * 128 + note
        if reaper.gmem_read(pos_index) == 0 then
            reaper.gmem_write(pos_index, -1)  -- -1 signifie qu'aucune note n'est active
        end
        
        -- Initialiser aussi les longueurs des boucles
        local len_index = GMEM_LOOP_LENGTH_BASE + i * 128 + note
        if reaper.gmem_read(len_index) == 0 then
            reaper.gmem_write(len_index, -1)  -- -1 signifie pas de boucle
        end
    end
end

-- Initialiser l'état de lecture et les données de synchronisation MIDI
-- Initialiser l'espace pour les données de synchronisation MIDI
for i = 0, 63 do
    local sync_base = GMEM_MIDI_SYNC_DATA_BASE + i * 3
    reaper.gmem_write(sync_base, -1)     -- ID de piste invalide
    reaper.gmem_write(sync_base + 1, 0)  -- Position 0
    reaper.gmem_write(sync_base + 2, 0)  -- Durée 0
end

-- Pause pour s'assurer que toutes les initialisations sont terminées
write_message_to_gmem("Pause de 500ms pour stabilisation...")
debug_console("Pause de 500ms pour stabilisation...")
reaper.defer(function() end)  -- Pause d'un cycle
local start_time = os.clock()
while os.clock() - start_time < 0.5 do
    -- Attendre 500ms
end

-- Tester le système de messages
test_message_system()

-- Variables pour suivre l'état de lecture précédent
local last_play_state = 0
local last_update_time = 0  -- Pour limiter la fréquence des mises à jour
local last_message_time = 0 -- Pour le message périodique

-- Variables globales pour les messages
local pending_message = nil
local pending_message_title = nil

-- Fonction pour trouver les pistes avec PoulpyLoop et analyser les données MIDI
local function scan_tracks_with_poulpy_loop()
    local track_count = reaper.CountTracks(0)
    local poulpy_tracks = {}
    
    write_message_to_gmem("Analyse des pistes avec PoulpyLoop...\nNombre total de pistes: " .. track_count)
    
    -- Parcourir toutes les pistes
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local fx_count = reaper.TrackFX_GetCount(track)
        local _, track_name = reaper.GetTrackName(track)
        
        local message = "Piste " .. i .. ": " .. track_name .. " (FX: " .. fx_count .. ")"
        write_message_to_gmem(message)
        
        local has_poulpy_loop = false
        
        -- Vérifier si la piste contient PoulpyLoop
        for j = 0, fx_count - 1 do
            local retval, fx_name = reaper.TrackFX_GetFXName(track, j, "")
            
            if fx_name:find("PoulpyLoop") then
                write_message_to_gmem("  → PoulpyLoop trouvé à l'index " .. j)
                has_poulpy_loop = true
                
                -- On a trouvé une piste avec PoulpyLoop
                table.insert(poulpy_tracks, {track = track, track_id = i, fx_index = j})
                break
            end
        end
        
        if not has_poulpy_loop then
            write_message_to_gmem("  → Pas de PoulpyLoop trouvé")
        end
    end
    
    write_message_to_gmem("Total des pistes avec PoulpyLoop: " .. #poulpy_tracks)
    
    return poulpy_tracks
end

-- Fonction pour analyser la position MIDI actuelle de chaque piste
local function analyze_midi_position(poulpy_tracks)
    -- Utiliser GetPlayPosition si la lecture est en cours, sinon GetCursorPosition
    local play_state = reaper.GetPlayState()
    local cur_pos = play_state == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    local num_tracks = #poulpy_tracks
    
    write_message_to_gmem(string.format("Analyse des positions MIDI à %.3f secondes (état lecture: %s)", 
                                      cur_pos, 
                                      play_state == 1 and "LECTURE" or "ARRÊT"))
    
    -- Effacer d'abord toutes les entrées pour éviter les données obsolètes
    for i = 0, 63 do
        local sync_base = GMEM_MIDI_SYNC_DATA_BASE + i * 3
        reaper.gmem_write(sync_base, -1)     -- ID de piste invalide
        reaper.gmem_write(sync_base + 1, 0)  -- Offset = 0 par défaut
        reaper.gmem_write(sync_base + 2, 0)  -- Durée = 0 par défaut
    end
    
    local tracks_updated = 0
    
    for i = 1, num_tracks do
        local track_data = poulpy_tracks[i]
        local track = track_data.track
        local track_id = track_data.track_id
        local sync_base = GMEM_MIDI_SYNC_DATA_BASE + track_id * 3  -- Important: utiliser track_id et non (i-1)
        
        -- Stocker l'ID de la piste
        reaper.gmem_write(sync_base, track_id)
        
        -- Déboguer les ID de pistes
        local _, track_name = reaper.GetTrackName(track)
        write_message_to_gmem(string.format("Piste #%d: %s (pos=%.3f)", track_id, track_name, cur_pos))
        
        -- Trouver la position MIDI actuelle
        local item_count = reaper.CountTrackMediaItems(track)
        local found_midi = false
        
        -- Parcourir les items MIDI sur cette piste
        for j = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, j)
            local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local item_end = item_pos + item_len
            
            -- Vérifier si la position de lecture est dans cet item
            if cur_pos >= item_pos and cur_pos < item_end then
                local take = reaper.GetActiveTake(item)
                if take and reaper.TakeIsMIDI(take) then
                    -- Calculer l'offset par rapport au début de l'item
                    local offset = cur_pos - item_pos
                    
                    -- Stocker l'offset et la longueur
                    reaper.gmem_write(sync_base + 1, offset)
                    reaper.gmem_write(sync_base + 2, item_len)
                    
                    write_message_to_gmem(string.format("  Item trouvé: début=%.3f, offset=%.3f, longueur=%.3f", 
                                                      item_pos, offset, item_len))
                    tracks_updated = tracks_updated + 1
                    found_midi = true
                    break
                end
            end
        end
        
        if not found_midi then
            -- Si on n'est pas dans un item MIDI, mettre l'offset à 0
            reaper.gmem_write(sync_base + 1, 0)
            reaper.gmem_write(sync_base + 2, 0)
            write_message_to_gmem("  Aucun item MIDI trouvé - offset mis à 0")
        end
    end
    
    -- Écrire le message dans la mémoire partagée
    if tracks_updated > 0 then
        local message = string.format("Offsets mis à jour pour %d piste(s)\nPosition: %.3f secondes", tracks_updated, cur_pos)
        write_message_to_gmem(message)
    end
end

-- Fonction pour vérifier la connectivité sur demande
local function check_connectivity()
    -- Écrire un message de test dans gmem
    local test_message = "Test de connectivité à " .. os.date("%H:%M:%S")
    local result = write_message_to_gmem(test_message)
    return result == #test_message
end

-- Fonction de nettoyage appelée lorsque le script se termine
local function exit()
    -- Marquer le service comme arrêté
    reaper.SetExtState("PoulpyLoopyService", "running", "0", false)
    -- Écrire un message final
    write_message_to_gmem("PoulpyLoopyService arrêté")
    debug_console("Service arrêté")
end

-- Enregistrer la fonction de nettoyage
reaper.atexit(exit)

-- Fonction principale
local function main()
    -- Obtenir l'état de lecture actuel
    local play_state = reaper.GetPlayState()
    
    -- Vérifier si on force l'analyse
    local force_analyze = reaper.gmem_read(GMEM_FORCE_ANALYZE) == 1
    
    -- Si l'état de lecture a changé ou si on force l'analyse
    if play_state ~= last_play_state or force_analyze then
        if force_analyze then
            debug_console("ANALYSE FORCÉE DES OFFSETS DEMANDÉE")
            write_message_to_gmem("=== ANALYSE FORCÉE DES OFFSETS ===")
        else
            debug_console("État de lecture changé: " .. (play_state == 1 and "LECTURE" or "ARRÊTÉ"))
        end
        
        last_play_state = play_state
        
        -- Analyser les pistes et les offsets
        local poulpy_tracks = scan_tracks_with_poulpy_loop()
        if #poulpy_tracks > 0 then
            analyze_midi_position(poulpy_tracks)
            debug_console(string.format("Analyse effectuée sur %d pistes", #poulpy_tracks))
        else
            debug_console("Aucune piste avec PoulpyLoop trouvée")
        end
        
        -- Réinitialiser le flag de forçage APRÈS l'analyse
        if force_analyze then
            reaper.gmem_write(GMEM_FORCE_ANALYZE, 0)
            debug_console("Flag d'analyse forcée réinitialisé")
            write_message_to_gmem("=== FIN DE L'ANALYSE FORCÉE ===")
        end
    end
    
    -- Continuer la boucle
    reaper.defer(main)
end

-- Démarrer la boucle principale
debug_console("Démarrage de la boucle principale")
main() 