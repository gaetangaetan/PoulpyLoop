from reaper_python import *
import time

try:
    from stupidArtnet import StupidArtnet
    ARTNET_AVAILABLE = True
except ImportError:
    ARTNET_AVAILABLE = False
    RPR_ShowMessageBox("Module stupidArtnet non trouvé. Installez-le avec 'pip install stupidArtnet'", "mrReArtnet - Erreur", 0)

# Configuration
ARTNET_IP = '192.168.0.14'  # Adresse de l'interface Artnet
ARTNET_UNIVERSE = 0         # Premier univers
DMX_CHANNEL = 1            # Canal DMX à contrôler (1-512)
BLINK_INTERVAL = 2         # Intervalle de clignotement en secondes
TOTAL_DURATION = 30        # Durée totale en secondes

def log(message):
    """Affiche un message dans la console REAPER"""
    RPR_ShowConsoleMsg(f"{message}\n")

def main():
    if not ARTNET_AVAILABLE:
        log("Module stupidArtnet non disponible")
        return
    
    try:
        # Initialiser Artnet
        artnet = StupidArtnet(ARTNET_IP, ARTNET_UNIVERSE, 512)
        artnet.start()
        log(f"Artnet initialisé sur {ARTNET_IP}")
        
        # Créer l'univers DMX
        dmx_universe = bytearray([0] * 512)
        
        # Temps de début
        start_time = time.time()
        is_on = False
        last_change = start_time
        
        log(f"Début du clignotement sur le canal {DMX_CHANNEL} pendant {TOTAL_DURATION} secondes...")
        
        # Boucle principale
        while (time.time() - start_time) < TOTAL_DURATION:
            current_time = time.time()
            
            # Vérifier s'il faut changer d'état
            if (current_time - last_change) >= BLINK_INTERVAL:
                is_on = not is_on
                dmx_universe[DMX_CHANNEL - 1] = 255 if is_on else 0
                artnet.set(dmx_universe)
                
                state = "ON" if is_on else "OFF"
                elapsed = int(current_time - start_time)
                remaining = TOTAL_DURATION - elapsed
                log(f"Canal {DMX_CHANNEL} {state} (temps restant: {remaining}s)")
                
                last_change = current_time
            
            time.sleep(0.1)  # Petit délai pour ne pas surcharger le CPU
        
        # Éteindre à la fin
        dmx_universe[DMX_CHANNEL - 1] = 0
        artnet.set(dmx_universe)
        time.sleep(0.1)  # Attendre que le dernier paquet soit envoyé
        
        artnet.stop()
        log("Test terminé")
        
    except Exception as e:
        log(f"Erreur: {str(e)}")
        if 'artnet' in locals():
            artnet.stop()

# Lancer le test
main() 