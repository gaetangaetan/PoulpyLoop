from reaper_python import *
import os
import time
import tempfile

try:
    from stupidArtnet import StupidArtnet
    ARTNET_AVAILABLE = True
except ImportError:
    ARTNET_AVAILABLE = False
    RPR_ShowMessageBox("Module stupidArtnet non trouvé.", "Erreur", 0)

# Configuration Artnet
ARTNET_IP = '192.168.0.14'
ARTNET_PORT = 6454
ARTNET_UNIVERSE = 0
DMX_SIZE = 512

# Variables globales
artnet = None
dmx_file = None
last_dmx_values = bytearray([0] * DMX_SIZE)
is_running = False
is_cleaning = False

def log(message):
    RPR_ShowConsoleMsg(f"{message}\n")

def create_dmx_file():
    # Utiliser le dossier temporaire du système
    file_path = os.path.join(tempfile.gettempdir(), "mrReArtnetMemory")
    log(f"Création du fichier DMX dans: {file_path}")
    
    try:
        # Si le fichier existe déjà, le supprimer
        if os.path.exists(file_path):
            os.remove(file_path)
            log("Ancien fichier DMX supprimé")
        
        # Créer/ouvrir le fichier en mode binaire
        f = open(file_path, "wb+")
        # Initialiser avec des zéros
        f.write(bytearray([0] * DMX_SIZE))
        f.flush()
        os.fsync(f.fileno())  # Forcer l'écriture sur le disque
        log("Fichier DMX initialisé avec succès")
        return f
    except Exception as e:
        log(f"Erreur création fichier DMX: {str(e)}")
        return None

def cleanup():
    global artnet, dmx_file, is_running, is_cleaning
    
    if is_cleaning:
        return
        
    is_cleaning = True
    log("Début du nettoyage...")
    
    is_running = False
    
    if artnet:
        try:
            # Éteindre tous les canaux
            artnet.set(bytearray([0] * DMX_SIZE))
            time.sleep(0.05)  # Attendre l'envoi
            
            log("Arrêt d'Artnet...")
            artnet.stop()
            time.sleep(0.1)  # Délai critique pour la libération
            artnet = None
        except Exception as e:
            log(f"Erreur arrêt Artnet: {str(e)}")
    
    if dmx_file:
        try:
            dmx_file.close()
            # Supprimer le fichier
            file_path = os.path.join(tempfile.gettempdir(), "mrReArtnetMemory")
            if os.path.exists(file_path):
                os.remove(file_path)
                log("Fichier DMX supprimé")
        except Exception as e:
            log(f"Erreur fermeture fichier DMX: {str(e)}")
    
    log("Nettoyage terminé")

def check_dmx_changes():
    global last_dmx_values, dmx_file
    
    try:
        # Lire le fichier
        dmx_file.seek(0)
        current_values = bytearray(dmx_file.read(DMX_SIZE))
        
        # Debug: afficher les 3 premières valeurs
        debug_values = [current_values[i] for i in range(3)]
        if debug_values != [0, 0, 0]:
            log(f"Valeurs DMX lues: {debug_values}")
        
        # Vérifier les changements
        if current_values != last_dmx_values:
            if artnet:
                artnet.set(current_values)
                log(f"Nouvelles valeurs DMX envoyées: {debug_values}")
            last_dmx_values = current_values.copy()
            
    except Exception as e:
        log(f"Erreur lecture/envoi DMX: {str(e)}")
        return cleanup()
    
    if is_running:
        time.sleep(0.02)  # ~50Hz refresh rate
        RPR_defer("check_dmx_changes()")

def init():
    global artnet, dmx_file, is_running, is_cleaning
    
    log("Initialisation du service ReaArtnet...")
    is_cleaning = False
    is_running = True
    
    try:
        # Créer le fichier DMX
        dmx_file = create_dmx_file()
        if not dmx_file:
            raise Exception("Impossible de créer le fichier DMX")
        log("Fichier DMX créé")
        
        if ARTNET_AVAILABLE:
            # Initialiser Artnet
            artnet = StupidArtnet(ARTNET_IP, ARTNET_UNIVERSE, DMX_SIZE, ARTNET_PORT)
            artnet.start()
            log(f"Artnet initialisé sur {ARTNET_IP}:{ARTNET_PORT}, univers {ARTNET_UNIVERSE}")
        
        # Démarrer la boucle de vérification
        RPR_defer("check_dmx_changes()")
        
    except Exception as e:
        log(f"Erreur initialisation: {str(e)}")
        cleanup()

# Point d'entrée
log("Démarrage du service ReaArtnet")
RPR_defer("init()") 
