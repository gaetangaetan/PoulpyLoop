from reaper_python import *
import sys
import time

# Ajout du chemin pour ReaImGui
sys.path.append(RPR_GetResourcePath() + "/Scripts/ReaTeam Extensions/API")
import imgui as ImGui

try:
    from stupidArtnet import StupidArtnet
    ARTNET_AVAILABLE = True
except ImportError:
    ARTNET_AVAILABLE = False
    RPR_ShowMessageBox("Module stupidArtnet non trouvé. Installez-le avec 'pip install stupidArtnet'", "mrReArtnet - Module requis", 0)

# Version du script
VERSION = "0.1.0"

# Initialisation du tableau DMX (univers) avec 512 valeurs à 0
dmx_universe = bytearray([0] * 512)  # Changé en bytearray pour compatibilité

# Constantes
DMX_UNIVERSE_SIZE = 512
DMX_MAX_VALUE = 255

# Configuration Artnet par défaut
ARTNET_IP = '192.168.0.14'  # Adresse de l'interface Artnet (ODE Mk2)
ARTNET_UNIVERSE = 0  # Premier univers (univers 0 = Universe 1 dans la plupart des logiciels)
ARTNET_PORT = 6454  # Port standard d'Artnet
ARTNET_FPS = 30  # Taux de rafraîchissement

# Configuration du PAR LED
PAR_ADDRESS = 1  # Adresse DMX du PAR
PAR_MODE_RGB = True  # Mode 3 canaux RGB
PAR_RED = PAR_ADDRESS - 1  # Canal Rouge (0-indexed)
PAR_GREEN = PAR_ADDRESS     # Canal Vert
PAR_BLUE = PAR_ADDRESS + 1  # Canal Bleu

# Variables globales pour l'interface
current_address = 1  # Adresses DMX commencent à 1 (affichage)
current_value = 0
ctx = None
artnet = None
artnet_enabled = False
window_open = True

# Variables pour les couleurs RGB
current_red = 0
current_green = 0
current_blue = 0

def stop_artnet():
    """Arrête proprement la connexion Artnet"""
    global artnet, artnet_enabled
    
    if artnet:
        try:
            # Éteindre tous les canaux
            dmx_universe[:] = bytearray([0] * 512)
            artnet.set(dmx_universe)
            
            # Attendre un peu pour s'assurer que le paquet est envoyé
            time.sleep(0.1)
            
            # Arrêter Artnet
            artnet.stop()
            artnet = None
            RPR_ShowConsoleMsg("Artnet arrêté\n")
        except:
            RPR_ShowConsoleMsg("Erreur lors de l'arrêt d'Artnet\n")
    
    artnet_enabled = False

def cleanup():
    """Nettoie les ressources avant de fermer"""
    global window_open
    
    # Marquer la fenêtre comme fermée pour éviter les appels ultérieurs
    window_open = False
    
    # Arrêter Artnet en premier
    stop_artnet()

def init_artnet():
    """Initialise la connexion Artnet"""
    global artnet, artnet_enabled
    if ARTNET_AVAILABLE:
        try:
            if artnet:
                artnet.stop()
            
            # Créer l'objet Artnet avec toutes les options
            artnet = StupidArtnet(ARTNET_IP, ARTNET_UNIVERSE, DMX_UNIVERSE_SIZE, ARTNET_PORT)
            
            # Configuration supplémentaire
            artnet.fps = ARTNET_FPS
            
            # Démarrer l'artnet
            artnet.start()
            
            # Envoyer une trame noire initiale (tous les canaux à 0)
            init_universe = bytearray([0] * 512)
            artnet.set(init_universe)
            
            RPR_ShowConsoleMsg(f"Artnet initialisé avec succès: IP={ARTNET_IP}, Universe={ARTNET_UNIVERSE}, Port={ARTNET_PORT}\n")
            return True
            
        except Exception as e:
            error_msg = f"Erreur lors de l'initialisation Artnet: {str(e)}"
            RPR_ShowMessageBox(error_msg, "mrReArtnet - Erreur", 0)
            RPR_ShowConsoleMsg(error_msg + "\n")
    return False

def update_dmx_universe():
    """Fonction pour mettre à jour l'univers DMX et gérer l'envoi via Artnet"""
    global artnet, artnet_enabled
    if artnet_enabled and artnet:
        try:
            # Afficher les valeurs RGB actuelles
            debug_msg = f"Envoi Artnet: R={dmx_universe[PAR_RED]}, G={dmx_universe[PAR_GREEN]}, B={dmx_universe[PAR_BLUE]}"
            RPR_ShowConsoleMsg(debug_msg + "\n")
            
            # Vérifier que l'artnet est bien configuré
            debug_msg = f"Config Artnet: IP={ARTNET_IP}, Universe={ARTNET_UNIVERSE}"
            RPR_ShowConsoleMsg(debug_msg + "\n")
            
            # Envoyer les données
            artnet.set(dmx_universe)
            RPR_ShowConsoleMsg("Données envoyées avec succès\n")
            
        except Exception as e:
            error_msg = f"Erreur lors de l'envoi Artnet: {str(e)}"
            RPR_ShowMessageBox(error_msg, "mrReArtnet - Erreur", 0)
            RPR_ShowConsoleMsg(error_msg + "\n")
            artnet_enabled = False

def draw_interface():
    """Dessine l'interface utilisateur"""
    global current_address, current_value, artnet_enabled
    global current_red, current_green, current_blue

    # Titre et infos
    ImGui.Text(ctx, f"Contrôle DMX - Univers 1 (v{VERSION})")
    ImGui.Separator(ctx)

    # Configuration Artnet
    if ImGui.CollapsingHeader(ctx, "Configuration Artnet"):
        # Activer/Désactiver Artnet
        changed, new_artnet_enabled = ImGui.Checkbox(ctx, "Activer Artnet", artnet_enabled)
        if changed:
            if new_artnet_enabled and not ARTNET_AVAILABLE:
                RPR_ShowMessageBox("Module stupidArtnet non disponible", "mrReArtnet - Erreur", 0)
            else:
                artnet_enabled = new_artnet_enabled
        
        # Afficher l'état
        status_color = 0xFF00FF00 if artnet_enabled else 0xFF0000FF  # Vert si actif, Rouge si inactif
        ImGui.TextColored(ctx, status_color, "Artnet " + ("ACTIF" if artnet_enabled else "INACTIF"))
        ImGui.Text(ctx, f"IP: {ARTNET_IP}")
        ImGui.Text(ctx, f"Univers: {ARTNET_UNIVERSE}")
        ImGui.Text(ctx, f"FPS: {ARTNET_FPS}")
    
    ImGui.Separator(ctx)

    # Contrôle RGB du PAR LED
    if ImGui.CollapsingHeader(ctx, "Contrôle PAR LED RGB", True):
        ImGui.Text(ctx, f"PAR LED à l'adresse {PAR_ADDRESS}")
        
        # Curseurs RGB
        changed = False
        
        # Rouge
        value_changed, new_red = ImGui.SliderInt(ctx, "Rouge", current_red, 0, DMX_MAX_VALUE)
        if value_changed:
            current_red = new_red
            dmx_universe[PAR_RED] = current_red
            changed = True
        
        # Vert
        value_changed, new_green = ImGui.SliderInt(ctx, "Vert", current_green, 0, DMX_MAX_VALUE)
        if value_changed:
            current_green = new_green
            dmx_universe[PAR_GREEN] = current_green
            changed = True
        
        # Bleu
        value_changed, new_blue = ImGui.SliderInt(ctx, "Bleu", current_blue, 0, DMX_MAX_VALUE)
        if value_changed:
            current_blue = new_blue
            dmx_universe[PAR_BLUE] = current_blue
            changed = True

        # Boutons de préréglages
        if ImGui.Button(ctx, "Noir"):
            current_red, current_green, current_blue = 0, 0, 0
            dmx_universe[PAR_RED:PAR_BLUE+1] = [0, 0, 0]
            changed = True
        
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Rouge"):
            current_red, current_green, current_blue = 255, 0, 0
            dmx_universe[PAR_RED:PAR_BLUE+1] = [255, 0, 0]
            changed = True
        
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Vert"):
            current_red, current_green, current_blue = 0, 255, 0
            dmx_universe[PAR_RED:PAR_BLUE+1] = [0, 255, 0]
            changed = True
        
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Bleu"):
            current_red, current_green, current_blue = 0, 0, 255
            dmx_universe[PAR_RED:PAR_BLUE+1] = [0, 0, 255]
            changed = True
        
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Blanc"):
            current_red, current_green, current_blue = 255, 255, 255
            dmx_universe[PAR_RED:PAR_BLUE+1] = [255, 255, 255]
            changed = True

        if changed:
            update_dmx_universe()
    
    ImGui.Separator(ctx)
    
    # Contrôle DMX manuel (conservé pour debug)
    if ImGui.CollapsingHeader(ctx, "Contrôle DMX Manuel"):
        # Curseur pour l'adresse DMX (1-512)
        changed, new_address = ImGui.SliderInt(ctx, "Adresse DMX", current_address, 1, DMX_UNIVERSE_SIZE)
        if changed:
            current_address = new_address
            # Mettre à jour la valeur affichée (0-indexed)
            current_value = dmx_universe[current_address - 1]
        
        # Curseur pour la valeur DMX (0-255)
        value_changed, new_value = ImGui.SliderInt(ctx, "Valeur", current_value, 0, DMX_MAX_VALUE)
        if value_changed:
            current_value = new_value
            # Mettre à jour le tableau DMX (0-indexed)
            dmx_universe[current_address - 1] = current_value
            update_dmx_universe()
        
        # Affichage de la valeur actuelle pour référence
        ImGui.Text(ctx, f"DMX[{current_address}] = {current_value}")

def init():
    """Initialisation de l'interface"""
    global ctx, artnet_enabled, window_open
    
    # Mettre la fenêtre comme ouverte
    window_open = True
    
    # Créer le contexte ImGui
    try:
        ctx = ImGui.CreateContext("mrReArtnet")
    except Exception as e:
        RPR_ShowMessageBox(f"Erreur lors de la création du contexte ImGui: {str(e)}", "mrReArtnet - Erreur", 0)
        return
    
    # Initialiser Artnet
    if init_artnet():
        artnet_enabled = True
    
    # Démarrer la boucle
    loop()

def start_main_loop():
    """Démarre la boucle principale en renvoyant à REAPER"""
    if window_open:
        RPR_defer("loop()")

def loop():
    """Boucle principale de l'interface"""
    global window_open, ctx
    
    # Si la fenêtre est fermée, sortir immédiatement
    if not window_open:
        return

    try:
        # Définir la taille initiale de la fenêtre
        ImGui.SetNextWindowSize(ctx, 400, 300, ImGui.Cond_FirstUseEver())
        
        # Commencer la fenêtre
        visible, open = ImGui.Begin(ctx, "mrReArtnet - Contrôleur DMX", True)
        
        # Dessiner l'interface si la fenêtre est visible
        if visible:
            draw_interface()
        
        # Terminer la fenêtre
        ImGui.End(ctx)
        
        # Gérer la fermeture de la fenêtre
        if not open:
            # Fermer proprement
            cleanup()
            
            # Détruire le contexte ImGui après le nettoyage
            if ctx:
                ImGui.DestroyContext(ctx)
                ctx = None
            
            return
        
        # Continuer la boucle principale
        start_main_loop()
    
    except Exception as e:
        RPR_ShowConsoleMsg(f"Erreur dans la boucle principale: {str(e)}\n")
        
        # En cas d'erreur, nettoyer et sortir
        cleanup()
        
        # Détruire le contexte ImGui après le nettoyage
        if ctx:
            try:
                ImGui.DestroyContext(ctx)
                ctx = None
            except:
                pass

# Point d'entrée du script
RPR_defer("init()") 
