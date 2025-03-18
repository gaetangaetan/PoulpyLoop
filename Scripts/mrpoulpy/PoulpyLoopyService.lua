-- PoulpyLoopyService.lua
-- Service en arrière-plan pour maintenir gmem actif

local reaper = reaper

-- Vérifier si une instance du service est déjà en cours d'exécution
local instance_running = reaper.GetExtState("PoulpyLoopyService", "running")
if instance_running == "1" then
  -- Une instance est déjà en cours d'exécution, on quitte
  reaper.ShowConsoleMsg("PoulpyLoopyService est déjà actif\n")
  return
end

-- Marquer le service comme en cours d'exécution
reaper.SetExtState("PoulpyLoopyService", "running", "1", false)

-- Se connecter à gmem
reaper.gmem_attach("PoulpyLoopy")

-- Indices gmem pour les modes
local GMEM_RECORD_MONITOR_MODE = 0  -- gmem[0] pour le mode d'enregistrement des loops MONITOR
local GMEM_PLAYBACK_MODE = 1        -- gmem[1] pour le mode LIVE/PLAYBACK
local GMEM_STATS_BASE = 2           -- gmem[2] à gmem[2+64*3-1] pour les statistiques (64 instances max)
local GMEM_NEXT_INSTANCE_ID = 194   -- gmem[194] pour le prochain ID d'instance disponible
local GMEM_MONITORING_STOP_BASE = 195  -- gmem[195] à gmem[195+64-1] pour le monitoring à l'arrêt (64 instances max)

-- Initialiser les valeurs dans gmem si elles ne sont pas déjà définies
if reaper.gmem_read(GMEM_RECORD_MONITOR_MODE) == 0 and reaper.gmem_read(GMEM_PLAYBACK_MODE) == 0 then
    reaper.gmem_write(GMEM_RECORD_MONITOR_MODE, 0)  -- Par défaut, pas d'enregistrement des loops MONITOR
    reaper.gmem_write(GMEM_PLAYBACK_MODE, 0)        -- Par défaut, mode LIVE
    reaper.ShowConsoleMsg("PoulpyLoopyService: Valeurs initialisées\n")
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

-- Fonction pour nettoyer à la sortie
local function exit()
    reaper.SetExtState("PoulpyLoopyService", "running", "0", false)
    reaper.ShowConsoleMsg("PoulpyLoopyService arrêté\n")
end

-- Enregistrer la fonction de sortie
reaper.atexit(exit)

-- Fonction principale qui sera exécutée en boucle
local function main()
    -- Le service continue de tourner en arrière-plan
    reaper.defer(main)
end

-- Démarrer le service
reaper.ShowConsoleMsg("PoulpyLoopyService démarré\n")
main() 