# ARCHITECTURE - PoulpyLoopy

## Vue d'ensemble

**PoulpyLoopy** est un système complet de bouclage audio en temps réel pour REAPER, composé d'un plugin JSFX et d'une interface de contrôle Lua. Le système permet d'enregistrer, de lire et de manipuler des boucles audio via des contrôles MIDI, avec une interface utilisateur graphique avancée pour la gestion des paramètres.

### Version actuelle
- **Core**: v0020
- **Plugin JSFX**: v0618

## Architecture générale

```
PoulpyLoopy System
├── Plugin JSFX (PoulpyLoop)          # Moteur audio temps réel
├── Interface Lua (PoulpyLoopy.lua)   # Point d'entrée principal
├── Core Logic (PoulpyLoopyCore.lua)  # Logique métier et traitement MIDI
├── UI Module (PoulpyLoopyUI.lua)     # Interface utilisateur ImGui
└── Service (PoulpyLoopyService.lua)  # Service de synchronisation
```

## Composants principaux

### 1. Plugin JSFX - PoulpyLoop
**Fichier**: `Effects/PoulpyLoop`

Le cœur du système, un plugin JSFX qui gère :
- **Enregistrement/lecture audio** : Jusqu'à 128 boucles simultanées
- **Gestion mémoire** : 32 MB de mémoire audio partagée
- **Contrôles MIDI** : Réception et traitement des messages MIDI
- **Modes de fonctionnement** :
  - `RECORD` (vélocité 1) : Enregistrement de nouvelles boucles
  - `PLAY` (vélocité 2) : Lecture de boucles existantes
  - `OVERDUB` (vélocité 3) : Superposition sur boucles existantes
  - `MONITOR` (vélocité 4) : Monitoring en temps réel

#### Paramètres du plugin
- **Slider 1** : Fade (0-256 échantillons)
- **Slider 2** : Contrôle de pitch (-24 à +24 demi-tons)
- **Slider 3** : Monitoring à l'arrêt (ON/OFF)

#### Gestion de la mémoire
- **Mémoire audio** : Organisée en unités de 256KB (4096 × 64 échantillons)
- **Maximum** : 32MB total, permettant environ 122 unités
- **Structure** : Stockage mono/stéréo avec gestion automatique de l'allocation

### 2. Interface principale - PoulpyLoopy.lua
**Fichier**: `Scripts/mrpoulpy/PoulpyLoopy.lua`

Point d'entrée du système qui :
- Initialise les modules Core et UI
- Gère la connexion à la mémoire partagée (gmem)
- Lance automatiquement le service de synchronisation
- Orchestre la boucle principale de l'interface

### 3. Logique métier - PoulpyLoopyCore.lua
**Fichier**: `Scripts/mrpoulpy/PoulpyLoopyCore.lua`

Module central contenant :

#### Fonctions de métadonnées
- Gestion des métadonnées de projet et de takes
- Stockage des propriétés des boucles (nom, type, référence, paramètres)

#### Gestion des boucles
- Validation des noms de boucles
- Mise à jour des dépendances entre boucles
- Dépliage des boucles PLAY longues

#### Traitement MIDI
- **ProcessMIDINotes()** : Fonction principale de génération MIDI
- Attribution automatique des notes MIDI par piste
- Génération des contrôleurs CC pour les paramètres
- Support des modes LIVE et PLAYBACK

#### Types de boucles supportés
- **RECORD** : Boucles principales avec nom unique
- **PLAY** : Lecture de boucles existantes avec contrôle de pitch
- **OVERDUB** : Superposition sur boucles de référence
- **MONITOR** : Monitoring temps réel
- **UNUSED** : Boucles désactivées

### 4. Interface utilisateur - PoulpyLoopyUI.lua
**Fichier**: `Scripts/mrpoulpy/PoulpyLoopyUI.lua`

Interface ImGui complète avec :

#### Onglet "Loop Editor"
- **Sélection du type de boucle** : Combo box avec les 5 types
- **Paramètres spécifiques** selon le type :
  - RECORD : Nom, Mono/Stéréo, Pan, Volume, Monitoring
  - PLAY/OVERDUB : Référence, Pan, Volume, Pitch, Monitoring
  - MONITOR : Mono/Stéréo, Pan, Volume
- **Boutons d'action** :
  - Apply : Application des paramètres
  - Insert click : Insertion d'un clic métronome
  - Update Pitch Automation : Génération d'automation de pitch

#### Onglet "Options"
- **Modes globaux** :
  - LIVE vs PLAYBACK (lecture seule)
  - Enregistrement des boucles MONITOR (ON/OFF)
- **Monitoring à l'arrêt** : Configuration par piste avec PoulpyLoop

#### Onglet "Tools"
- **Gestion des loopers** : Ajout de plugins PoulpyLoop aux pistes
- **Configuration audio** : Sélection des entrées mono/stéréo
- **Rendu audio** : Export des sélections en mode temps réel ou accéléré
- **Préparation MIDI** : Génération complète des données MIDI
- **Mise à jour globale** : Régénération de tous les blocs du projet

### 5. Service de synchronisation - PoulpyLoopyService.lua
**Fichier**: `Scripts/mrpoulpy/PoulpyLoopyService.lua`

Service en arrière-plan qui :
- Maintient la synchronisation entre l'interface et les plugins
- Gère la mémoire partagée (gmem)
- Surveille l'état des instances de PoulpyLoop

## Système de communication

### Mémoire partagée (gmem)
Le système utilise la mémoire partagée REAPER pour la communication :

```
gmem[0]     : Mode enregistrement MONITOR (0/1)
gmem[1]     : Mode PLAYBACK (0=LIVE, 1=PLAYBACK)
gmem[2-193] : Statistiques des instances (64 × 3 valeurs)
gmem[194]   : Prochain ID d'instance disponible
gmem[195-258] : États monitoring à l'arrêt (64 instances)
gmem[259-8450] : Positions de début des notes (64 × 128 notes)
gmem[8451-16642] : Longueurs des boucles (64 × 128 notes)
```

### Messages MIDI
Communication via contrôleurs MIDI :
- **CC7** : Volume (0-127, mappé sur -20dB à +10dB)
- **CC8** : Mode mono/stéréo (0=mono, 1=stéréo)
- **CC9** : Pitch (-64 à +63 demi-tons)
- **CC10** : Pan (0-127, mappé sur -1.0 à +1.0)
- **CC11** : Monitoring (0=OFF, 1=ON)
- **CC13/CC14** : Position de début de bloc (mode PLAYBACK uniquement)
- **CC19/CC20** : Durée de bloc (pour MONITOR)

## Modes de fonctionnement

### Mode LIVE
- **Enregistrement actif** : Toutes les fonctions d'enregistrement disponibles
- **Contrôle total** : Modification des boucles en temps réel
- **Monitoring** : Signal d'entrée routé vers la sortie selon les paramètres

### Mode PLAYBACK
- **Lecture seule** : Aucun enregistrement possible
- **Synchronisation temporelle** : Les boucles démarrent selon leur position dans le projet
- **Idéal pour** : Replay de projets, performances live sans risque de modification

## Gestion des couleurs

Le système utilise un code couleur pour identifier visuellement les types de boucles :
- **RECORD** : Rouge (235, 64, 52)
- **PLAY** : Vert (49, 247, 108)
- **OVERDUB** : Cyan (32, 241, 245)
- **MONITOR** : Orange (247, 188, 49)
- **UNUSED** : Noir (0, 0, 0)
- **CLICK** : Violet (136, 39, 255)

## Fonctionnalités avancées

### Automation de pitch
- **Génération automatique** : Création d'envelopes d'automation basées sur les paramètres de pitch des boucles
- **Configuration par piste** : Sélection de l'effet et du paramètre cible
- **Sensibilité réglable** : Contrôle de l'amplitude de l'automation

### Gestion des folders
- **Organisation hiérarchique** : Support des dossiers de pistes REAPER
- **Attribution de notes uniques** : Compteur de notes par folder pour éviter les conflits
- **Synchronisation** : Toutes les boucles d'un même folder partagent le même espace de notes

### Rendu audio
- **Export sélectif** : Rendu des boucles sélectionnées uniquement
- **Modes de rendu** : Temps réel (idle) ou vitesse maximale
- **Organisation automatique** : Création du dossier Media et nommage horodaté

## Sécurité et robustesse

### Validation des données
- **Noms de boucles** : Vérification d'unicité dans le folder
- **Références** : Validation de l'existence des boucles référencées
- **Types compatibles** : Contrôle de cohérence des modifications groupées

### Gestion d'erreurs
- **Mémoire saturée** : Détection et gestion gracieuse des dépassements
- **Takes invalides** : Vérification de la validité des pointeurs
- **Mode PLAYBACK** : Protection contre les modifications accidentelles

### Performance
- **Traitement asynchrone** : Mise à jour progressive des gros projets
- **Optimisation mémoire** : Gestion efficace de la mémoire audio
- **Interface réactive** : Calcul dynamique de la taille des fenêtres

## Extensions et personnalisation

### Intégration avec d'autres systèmes
- **Import ALK** : Support des projets Ableton Live Kit (ALK2REAPER)
- **Contrôleurs MIDI** : Configuration flexible des entrées
- **Plugins tiers** : Automation compatible avec tous les effets REAPER

### Développement
- **Architecture modulaire** : Séparation claire des responsabilités
- **API documentée** : Fonctions exportées pour extension
- **Configuration persistante** : Sauvegarde des préférences utilisateur

## Cas d'usage typiques

### Performance live
1. **Préparation** : Création des pistes avec PoulpyLoop
2. **Configuration** : Réglage des entrées audio et paramètres
3. **Performance** : Enregistrement et lecture de boucles en temps réel
4. **Monitoring** : Contrôle du signal d'entrée selon l'état de lecture

### Production en studio
1. **Import de projet** : Chargement de sessions ALK ou création manuelle
2. **Arrangement** : Organisation des boucles dans la timeline
3. **Mode PLAYBACK** : Lecture fidèle pour mixage et mastering
4. **Export** : Rendu sélectif des stems pour post-production

### Composition créative
1. **Expérimentation** : Enregistrement libre de matériel audio
2. **Layering** : Utilisation du mode OVERDUB pour superpositions
3. **Variations** : Mode PLAY avec contrôle de pitch pour variations
4. **Automation** : Génération d'automation pour évolution temporelle

## Conclusion

PoulpyLoopy représente un système complet et mature pour le bouclage audio dans REAPER, offrant une approche unique combinant la puissance du traitement temps réel JSFX avec la flexibilité des scripts Lua. Son architecture modulaire et ses fonctionnalités avancées en font un outil adapté aussi bien à la performance live qu'à la production en studio.
