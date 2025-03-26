from reaper_python import *
import mmap
import os
import time
import struct

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
shared_mem = None
last_dmx_values = bytearray([0] * DMX_SIZE)
is_running = False
is_cleaning = False

def log(message):
    RPR_ShowConsoleMsg(f"{message}\n")

def create_shared_mem():
    if os.name == 'posix':
        mem = mmap.mmap(os.open('/dev/shm/mrReaArtnetMemory', os.O_CREAT|os.O_RDWR), DMX_SIZE)
    else:  # Windows
        mem = mmap.mmap(-1, DMX_SIZE, "mrReaArtnetMemory")
    mem.write(bytes(DMX_SIZE))  # Initialiser à 0
    return mem

def cleanup():
    global artnet, shared_mem, is_running, is_cleaning
    
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
    
    if shared_mem:
        try:
            shared_mem.close()
        except Exception as e:
            log(f"Erreur fermeture mémoire partagée: {str(e)}")
    
    log("Nettoyage terminé")

def check_dmx_changes():
    global last_dmx_values
    
    try:
        # Lire toute la mémoire partagée
        shared_mem.seek(0)
        current_values = shared_mem.read(DMX_SIZE)
        
        # Vérifier les changements
        if current_values != last_dmx_values:
            if artnet:
                artnet.set(current_values)
            last_dmx_values = bytearray(current_values)
            
    except Exception as e:
        log(f"Erreur lecture/envoi DMX: {str(e)}")
        return cleanup()
    
    if is_running:
        time.sleep(0.02)  # ~50Hz refresh rate
        RPR_defer("check_dmx_changes()")

def init():
    global artnet, shared_mem, is_running, is_cleaning
    
    log("Initialisation du service ReaArtnet...")
    is_cleaning = False
    is_running = True
    
    try:
        # Créer la mémoire partagée
        shared_mem = create_shared_mem()
        log("Mémoire partagée créée")
        
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
