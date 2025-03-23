from reaper_python import *

# Initialisation du tableau DMX (univers) avec 512 valeurs à 0
dmx_universe = [0] * 512

# Constantes
VERSION = "0.1.0"
DMX_UNIVERSE_SIZE = 512
DMX_MAX_VALUE = 255

# Variables globales pour l'interface
current_address = 1  # Adresses DMX commencent à 1 (affichage)
current_value = 0

# Initialisation du contexte ReaImGui
ctx = RPR_ImGui_CreateContext("mrReArtnet")

def update_dmx_universe():
    """Fonction pour mettre à jour l'univers DMX et gérer l'envoi via Artnet"""
    # Ici, vous pourriez ajouter le code pour envoyer les données via Artnet
    # Pour l'instant, nous nous contentons de stocker les valeurs
    pass

def loop():
    global current_address, current_value
    
    # Vérifier si la fenêtre est ouverte
    visible, open = RPR_ImGui_Begin(ctx, "mrReArtnet - Contrôleur DMX", True)
    if not open:
        RPR_ImGui_DestroyContext(ctx)
        return
        
    if visible:
        # Titre et infos
        RPR_ImGui_Text(ctx, "Contrôle DMX - Univers 1")
        RPR_ImGui_Separator(ctx)
        
        # Curseur pour l'adresse DMX (1-512)
        changed, new_address = RPR_ImGui_SliderInt(ctx, "Adresse DMX", current_address, 1, DMX_UNIVERSE_SIZE)
        if changed:
            current_address = new_address
            # Mettre à jour la valeur affichée (0-indexed)
            current_value = dmx_universe[current_address - 1]
        
        # Curseur pour la valeur DMX (0-255)
        value_changed, new_value = RPR_ImGui_SliderInt(ctx, "Valeur", current_value, 0, DMX_MAX_VALUE)
        if value_changed:
            current_value = new_value
            # Mettre à jour le tableau DMX (0-indexed)
            dmx_universe[current_address - 1] = current_value
            update_dmx_universe()  # Mise à jour des valeurs pour Artnet
        
        # Affichage de la valeur actuelle pour référence
        RPR_ImGui_Text(ctx, f"DMX[{current_address}] = {current_value}")
        
        # Information supplémentaire
        RPR_ImGui_Separator(ctx)
        RPR_ImGui_Text(ctx, "État du système: en attente d'implémentation Artnet")
        
    RPR_ImGui_End(ctx)
    
    # Continuer la boucle si la fenêtre est ouverte
    if open:
        RPR_defer(loop)

def main():
    # Démarrer la boucle
    RPR_defer(loop)

# Point d'entrée du script
main() 