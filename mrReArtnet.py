import sys
from reaper_python import RPR_ShowMessageBox

def main():
    # Affiche une boîte de dialogue dans Reaper,
    # qui mentionne la version de Python en cours d'utilisation.
    python_version = sys.version
    message = f"Hello! Reaper utilise actuellement Python {python_version}"
    RPR_ShowMessageBox(message, "Test Python/Reaper", 0)

main() 