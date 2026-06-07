-- PoulpyLoopyService.lua
-- Service en arrière-plan pour maintenir gmem actif

local reaper = reaper



-- Se connecter à gmem d'abord
reaper.gmem_attach("PoulpyLoopy")



-- Plan mémoire gmem : lu depuis le module Core (source unique, dérivée du JSFX). Cf. I1.
local core = dofile(reaper.GetResourcePath() .. "/Scripts/mrpoulpy/PoulpyLoopyCore.lua")
local GMEM = core.GMEM



-- Vérifier si une instance du service est déjà en cours d'exécution
local instance_running = reaper.GetExtState("PoulpyLoopyService", "running")
if instance_running == "1" then
  -- Une instance est déjà en cours d'exécution, on quitte silencieusement
  return
end

-- Marquer le service comme en cours d'exécution
reaper.SetExtState("PoulpyLoopyService", "running", "1", false)



-- Initialiser les valeurs dans gmem si elles ne sont pas déjà définies
if reaper.gmem_read(GMEM.RECORD_MONITOR_MODE) == 0 and reaper.gmem_read(GMEM.PLAYBACK_MODE) == 0 then
    reaper.gmem_write(GMEM.RECORD_MONITOR_MODE, 0)  -- Par défaut, pas d'enregistrement des loops MONITOR
    reaper.gmem_write(GMEM.PLAYBACK_MODE, 0)        -- Par défaut, mode LIVE
end

-- Initialiser le compteur d'ID d'instance si nécessaire
if reaper.gmem_read(GMEM.NEXT_INSTANCE_ID) == 0 then
    reaper.gmem_write(GMEM.NEXT_INSTANCE_ID, 0)
end

-- Initialiser l'espace mémoire pour les statistiques (64 instances max)
for i = 0, 63 do
    local stats_base = GMEM.STATS_BASE + i * 3
    -- Initialiser uniquement si la valeur est 0 (pas déjà définie)
    if reaper.gmem_read(stats_base) == 0 then
        reaper.gmem_write(stats_base, 0)      -- Mémoire utilisée (Mo)
        reaper.gmem_write(stats_base + 1, 0)  -- Temps restant (s)
        reaper.gmem_write(stats_base + 2, 0)  -- Nombre de notes
    end
end

-- Initialiser l'espace mémoire pour le monitoring à l'arrêt
for i = 0, 63 do
    if reaper.gmem_read(GMEM.MONITORING_STOP_BASE + i) == 0 then
        reaper.gmem_write(GMEM.MONITORING_STOP_BASE + i, 0)  -- Par défaut, monitoring à l'arrêt désactivé
    end
end

-- Initialiser l'espace mémoire pour les positions de début des notes
for i = 0, 63 do
    for note = 0, 127 do
        local pos_index = GMEM.NOTE_START_POS_BASE + i * 128 + note
        if reaper.gmem_read(pos_index) == 0 then
            reaper.gmem_write(pos_index, -1)  -- -1 signifie qu'aucune note n'est active
        end
        
        -- Initialiser aussi les longueurs des boucles
        local len_index = GMEM.LOOP_LENGTH_BASE + i * 128 + note
        if reaper.gmem_read(len_index) == 0 then
            reaper.gmem_write(len_index, -1)  -- -1 signifie pas de boucle
        end
    end
end



-- Fonction de nettoyage appelée lorsque le script se termine
local function exit()
    -- Marquer le service comme arrêté
    reaper.SetExtState("PoulpyLoopyService", "running", "0", false)
end

-- Enregistrer la fonction de nettoyage
reaper.atexit(exit)

-- Fonction principale simplifiée - juste maintenir la connexion gmem
local function main()
    -- Continuer la boucle pour maintenir le service actif
    reaper.defer(main)
end

-- Démarrer la boucle principale
main()
