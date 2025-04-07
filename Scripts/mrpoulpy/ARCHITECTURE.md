# PoulpyLoopy - Architecture Technique
**Version**: 0.0.15  
**Dernière mise à jour**: 2024-03-19  
**Statut**: Document de référence technique actif

> **Note**: Ce document est une référence technique destinée à fournir une vue d'ensemble rapide de l'architecture de PoulpyLoopy. Il est particulièrement utile pour comprendre rapidement le contexte du projet lors des sessions de développement.

## 1. Vue d'ensemble

PoulpyLoopy est un système de "scripted looping" pour REAPER composé de deux parties principales :
- Un plugin JSFX (PoulpyLoop) gérant l'audio
- Un ensemble de scripts Lua gérant l'interface et le contrôle

### 1.1 Architecture globale

```ascii
+------------------------+     GMEM      +----------------------+
|    Scripts Lua        |<-------------->|    PoulpyLoop JSFX   |
| - Interface (UI)      |   Contrôle    | - Audio processing   |
| - Gestion MIDI       |               | - Buffer management  |
| - Service background |               | - Monitoring        |
+------------------------+              +----------------------+
         ^                                       ^
         |                                       |
         v                                       v
    REAPER MIDI                             REAPER Audio
```

## 2. Composants principaux

### 2.1 Plugin JSFX (PoulpyLoop)

- **Gestion mémoire**
  - Limite : 32MB par instance
  - Unités de 262144 échantillons
  - Format : valeurs 64-bit (double)
  - Modes : mono/stéréo

- **Types de blocs**
  - RECORD : Enregistrement initial
  - PLAY : Lecture d'un bloc RECORD
  - OVERDUB : Superposition sur un bloc RECORD
  - MONITOR : Monitoring sans enregistrement
  - UNUSED : État invalide/inutilisé

### 2.2 Scripts Lua

- **PoulpyLoopyUI.lua**
  - Interface ImGui multi-onglets
  - Édition des paramètres de blocs
  - Gestion des commandes MIDI

- **PoulpyLoopyService.lua**
  - Maintien de la connexion GMEM
  - Service persistant en arrière-plan

### 2.3 Communication inter-processus

- **GMEM (Mémoire partagée)**
  - Contrôle des instances
  - Échange de données audio
  - Synchronisation des états

- **MIDI**
  - Une note par bloc
  - Vélocités spécifiques :
    - 1 = RECORD
    - 2 = PLAY
    - 3 = OVERDUB
    - 4 = MONITOR

## 3. Flux de travail

### 3.1 Création et gestion des blocs

1. **Création**
   - Insertion d'un bloc MIDI dans REAPER
   - Configuration via l'interface PoulpyLoopy
   - Paramètres par défaut initiaux

2. **Édition**
   - Sélection du bloc dans REAPER
   - Modification des paramètres dans Loop Editor
   - Application via le bouton "Appliquer"

3. **Référencement**
   - Blocs PLAY/OVERDUB référencent des blocs RECORD
   - Gestion automatique des références lors des suppressions
   - Pas de références circulaires possibles

### 3.2 Monitoring

- **États possibles**
  1. Arrêt : contrôlé par "Monitoring à l'arrêt"
  2. Lecture : selon paramètre "Monitoring" du bloc
  3. MONITOR : toujours actif

## 4. Limitations et contraintes

- Maximum 64 instances de PoulpyLoop
- 32MB de mémoire par instance
- Un seul événement MIDI par bloc
- Taille des unités fixée à 262144 échantillons

## 5. Développement futur

- Optimisation du système de sauvegarde/chargement
- Possible retrait du système de modulation
- Correction des bugs de référencement

## 6. Points critiques pour le développement

### 6.1 Zones de mémoire GMEM importantes
- GMEM_DATA_BUFFER (30000-59999) : Buffer de transfert pour sauvegarde/chargement
- GMEM_STATS_BASE : Statistiques des instances (3 valeurs par instance)
- GMEM_MONITORING_STOP_BASE : États de monitoring à l'arrêt
- GMEM_NOTE_START_POS_BASE : Positions de début des notes

### 6.2 Workflow de modification de code
- Les modifications de PoulpyLoop (JSFX) nécessitent un rechargement des instances
- Les modifications des scripts Lua prennent effet au prochain lancement
- Attention aux dépendances entre les fichiers Lua (ordre de chargement)

### 6.3 Points d'attention particuliers
- La synchronisation GMEM est critique pour la stabilité
- Les modifications de blocs RECORD peuvent impacter les blocs qui y font référence
- Le service d'arrière-plan doit rester actif pour la persistance GMEM

### 6.4 Structure des blocs MIDI
```lua
-- Format des métadonnées de bloc
{
    loop_type = "RECORD|PLAY|OVERDUB|MONITOR|UNUSED",
    loop_name = "nom_unique",  -- Pour RECORD uniquement
    reference_loop = "nom_ref",  -- Pour PLAY/OVERDUB
    is_mono = "true|false",
    pan = "-1.0 to 1.0",
    volume_db = "-20.0 to 10.0",
    pitch = "-24 to 24",  -- Pour PLAY uniquement
    monitoring = "0|1"
}
```

### 6.5 Dépendances des fichiers
PoulpyLoopy.lua
├─ PoulpyLoopyCore1.lua
├─ PoulpyLoopyUI.lua
│ ├─ PoulpyLoopyCore0.lua
│ ├─ PoulpyLoopyCore1.lua
│ └─ PoulpyLoopyCore2.lua
└─ PoulpyLoopyService.lua