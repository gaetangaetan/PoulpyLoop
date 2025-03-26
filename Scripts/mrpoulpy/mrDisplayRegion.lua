-- @description Affiche la région actuelle dans une fenêtre non bloquante
-- @author mrpoulpy
-- @version 1.0

-- Configuration
local config = {
  -- Paramètres généraux
  update_interval = 0.1, -- 100ms
  window_width = 400,
  window_height = 350,
  background_color = {r = 40, g = 40, b = 40},
  font_name = "Segoe UI Bold", -- Police commune pour tous les textes
  
  -- Paramètres pour la région actuelle
  current_region = {
    font_size = 100,
    text_color = {r = 255, g = 20, b = 91}
  },
  
  -- Paramètres pour les autres régions (précédentes et suivantes)
  other_regions = {
    font_size = 60,
    text_color = {r = 255, g = 250, b = 107}
  }
}

-- Variables pour la gestion de la mise à jour
local last_update_time = 0
local last_regions = {previous2 = "", previous1 = "", current = "", next1 = "", next2 = ""}
local last_window_width = 0
local last_window_height = 0

-- Vérifier si une instance est déjà en cours d'exécution
local script_name = "mrDisplayRegion"
local is_running = reaper.GetExtState(script_name, "is_running")
if is_running == "1" then
  -- Vérifier si la fenêtre existe réellement
  local window_exists = reaper.JS_Window_Find("Régions", true)
  if window_exists then
    reaper.ShowMessageBox("Une instance du script est déjà en cours d'exécution.", "Attention", 0)
    return
  else
    -- Si la fenêtre n'existe pas, réinitialiser l'état
    reaper.SetExtState(script_name, "is_running", "0", true)
  end
end

-- Fonction pour obtenir les régions (deux précédentes, actuelle, et deux suivantes)
function get_regions()
  local regions = {previous2 = "", previous1 = "", current = "", next1 = "", next2 = ""}
  
  -- Obtenir la position actuelle (lecture ou édition)
  local current_pos
  if reaper.GetPlayState() > 0 then
    current_pos = reaper.GetPlayPosition()
  else
    current_pos = reaper.GetCursorPosition()
  end
  
  -- Récupérer toutes les régions du projet
  local all_regions = {}
  local count = reaper.CountProjectMarkers(0)
  
  for i = 0, count-1 do
    local retval, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    
    if isrgn then
      table.insert(all_regions, {
        name = name or "",
        start = pos,
        ['end'] = rgnend
      })
    end
  end
  
  -- Trier les régions par position de début
  table.sort(all_regions, function(a, b) return a.start < b.start end)
  
  -- Trouver la région actuelle, les précédentes et les suivantes
  local current_region_index = nil
  
  -- Trouver d'abord la région actuelle
  for i, region in ipairs(all_regions) do
    if current_pos >= region.start and current_pos < region['end'] then
      current_region_index = i
      regions.current = region.name
      break
    end
  end
  
  -- Si une région actuelle est trouvée
  if current_region_index then
    -- Récupérer les deux régions précédentes si elles existent
    if current_region_index > 1 then
      regions.previous1 = all_regions[current_region_index - 1].name
      
      if current_region_index > 2 then
        regions.previous2 = all_regions[current_region_index - 2].name
      end
    end
    
    -- Récupérer les deux régions suivantes si elles existent
    if current_region_index < #all_regions then
      regions.next1 = all_regions[current_region_index + 1].name
      
      if current_region_index + 1 < #all_regions then
        regions.next2 = all_regions[current_region_index + 2].name
      end
    end
  else
    -- Si aucune région actuelle, trouver les suivantes
    local next_region_index = nil
    
    for i, region in ipairs(all_regions) do
      if current_pos < region.start then
        next_region_index = i
        regions.next1 = region.name
        break
      end
    end
    
    if next_region_index then
      -- Trouver les régions précédentes de la suivante
      if next_region_index > 1 then
        regions.previous1 = all_regions[next_region_index - 1].name
        
        if next_region_index > 2 then
          regions.previous2 = all_regions[next_region_index - 2].name
        end
      end
      
      -- Trouver la deuxième région suivante
      if next_region_index < #all_regions then
        regions.next2 = all_regions[next_region_index + 1].name
      end
    else
      -- Si nous n'avons pas trouvé de suivante mais qu'il y a des régions,
      -- alors nous sommes après toutes les régions
      if #all_regions > 0 then
        regions.previous1 = all_regions[#all_regions].name
        
        if #all_regions > 1 then
          regions.previous2 = all_regions[#all_regions - 1].name
        end
      end
    end
  end
  
  return regions
end

-- Fonction pour dessiner le texte centré
function draw_centered_text(text, y_pos, style_config)
  gfx.setfont(1, config.font_name, style_config.font_size)
  gfx.set(style_config.text_color.r/255, style_config.text_color.g/255, style_config.text_color.b/255, 1)
  
  local text_w, text_h = gfx.measurestr(text)
  local x = (gfx.w - text_w) / 2
  
  gfx.x, gfx.y = x, y_pos
  gfx.drawstr(text)
  
  return text_h
end

-- Fonction de rafraîchissement
function refresh()
  -- Vérifier si la fenêtre est fermée
  local char = gfx.getchar()
  if char == 27 or char < 0 then -- Échap ou fenêtre fermée
    -- Sauvegarder l'état de dockage
    local dock_state = gfx.dock(-1)
    reaper.SetExtState(script_name, "dock_state", tostring(dock_state), true)
    -- Marquer le script comme arrêté
    reaper.SetExtState(script_name, "is_running", "0", true)
    return
  end
  
  -- Vérifier si la taille de la fenêtre a changé
  if gfx.w ~= last_window_width or gfx.h ~= last_window_height then
    last_window_width = gfx.w
    last_window_height = gfx.h
    -- Forcer un rafraîchissement immédiat
    last_regions = {previous2 = "", previous1 = "", current = "", next1 = "", next2 = ""}
  end
  
  -- Contrôle de la fréquence de mise à jour pour économiser le CPU
  local current_time = reaper.time_precise()
  if current_time - last_update_time < config.update_interval then
    reaper.defer(refresh)
    return
  end
  
  -- Obtenir les informations des régions
  local regions = get_regions()
  
  -- Vérifier si quelque chose a changé
  if regions.previous2 ~= last_regions.previous2 or
     regions.previous1 ~= last_regions.previous1 or 
     regions.current ~= last_regions.current or 
     regions.next1 ~= last_regions.next1 or
     regions.next2 ~= last_regions.next2 then
     
    -- Effacer la fenêtre
    gfx.set(config.background_color.r/255, config.background_color.g/255, config.background_color.b/255, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    
    -- Calculer les positions verticales pour chaque ligne
    -- Mesurer d'abord la hauteur de chaque texte
    gfx.setfont(1, config.font_name, config.other_regions.font_size)
    local _, other_h = gfx.measurestr("Texte")
    
    gfx.setfont(1, config.font_name, config.current_region.font_size)
    local _, current_h = gfx.measurestr("Texte")
    
    local total_height = 2 * other_h + current_h + 2 * other_h
    local y_start = (gfx.h - total_height) / 2
    
    -- Dessiner la deuxième région précédente
    local y_pos = y_start
    draw_centered_text(regions.previous2, y_pos, config.other_regions)
    
    -- Dessiner la première région précédente
    y_pos = y_pos + other_h
    draw_centered_text(regions.previous1, y_pos, config.other_regions)
    
    -- Dessiner la région actuelle
    y_pos = y_pos + other_h
    draw_centered_text(regions.current, y_pos, config.current_region)
    
    -- Dessiner la première région suivante
    y_pos = y_pos + current_h
    draw_centered_text(regions.next1, y_pos, config.other_regions)
    
    -- Dessiner la deuxième région suivante
    y_pos = y_pos + other_h
    draw_centered_text(regions.next2, y_pos, config.other_regions)
    
    -- Mettre à jour l'affichage
    gfx.update()
    
    -- Mémoriser les régions affichées
    last_regions = regions
  end
  
  -- Enregistrer le temps de la dernière mise à jour
  last_update_time = current_time
  
  -- Planifier la prochaine mise à jour
  reaper.defer(refresh)
end

-- Fonction d'initialisation
function init()
  -- Récupérer l'état de dockage sauvegardé
  local dock_state = tonumber(reaper.GetExtState(script_name, "dock_state")) or 0
  
  -- Initialiser la fenêtre avec l'état de dockage sauvegardé
  gfx.init("Régions", config.window_width, config.window_height, dock_state, 100, 100)
  
  -- Marquer le script comme en cours d'exécution
  reaper.SetExtState(script_name, "is_running", "1", true)
  
  -- Initialiser le temps
  last_update_time = reaper.time_precise()
  
  -- Démarrer la boucle de rafraîchissement
  refresh()
end

-- Lancer le script
init()
