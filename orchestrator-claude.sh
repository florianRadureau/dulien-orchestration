#!/bin/bash
#
# Orchestrateur Dulien avec Claude
# Remplace Python + Mistral par Claude qui orchestre Claude
#

set -e

# Configuration
ORCHESTRATION_DIR="/home/florian/projets/dulien-orchestration"
LAST_ACTIONS="$ORCHESTRATION_DIR/last-actions.json"
INSTRUCTIONS="$ORCHESTRATION_DIR/instructions.md"
LOG_FILE="$ORCHESTRATION_DIR/logs/orchestrator-claude.log"

# Couleurs pour les logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonction de log
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

# Vérifications initiales
check_requirements() {
    # Vérifier que Claude CLI est installé
    if ! command -v claude &> /dev/null; then
        error "Claude CLI n'est pas installé ou pas dans le PATH"
        exit 1
    fi
    
    # Vérifier que gh CLI est installé
    if ! command -v gh &> /dev/null; then
        error "GitHub CLI (gh) n'est pas installé ou pas dans le PATH"
        exit 1
    fi
    
    # Créer les dossiers nécessaires
    mkdir -p "$ORCHESTRATION_DIR/logs"
    
    # Initialiser last-actions.json si nécessaire
    if [ ! -f "$LAST_ACTIONS" ]; then
        echo "[]" > "$LAST_ACTIONS"
        info "Fichier $LAST_ACTIONS initialisé"
    fi
    
    # Vérifier que instructions.md existe
    if [ ! -f "$INSTRUCTIONS" ]; then
        error "Fichier $INSTRUCTIONS manquant"
        exit 1
    fi
}

# Fonction principale d'orchestration
run_orchestration_cycle() {
    log "🔄 Début du cycle d'orchestration"
    
    # Construire le prompt pour Claude
    PROMPT="
# Orchestrateur Dulien - Cycle $(date '+%Y-%m-%d %H:%M:%S')

## Instructions
$(cat "$INSTRUCTIONS")

## Actions récentes (éviter les doublons)
\`\`\`json
$(cat "$LAST_ACTIONS")
\`\`\`

## Mission pour ce cycle

1. **Scanner l'état GitHub** avec gh CLI
   - PRs ouvertes : \`gh pr list --state open --repo mentorize-app/{repo}\`
   - Issues/tâches : \`gh issue list --state open --label agent:* --repo mentorize-app/{repo}\`
   - Épics : \`gh issue list --state open --label type:epic --repo mentorize-app/{repo}\`
   - Repos à scanner : webapp, infrastructure, tenant-api, referential

2. **Analyser et décider** (max 3 actions)
   - Priorité 1 : PRs à reviewer/merger
   - Priorité 2 : Tâches sans label 'processing'
   - Priorité 3 : Épics sans sous-tâches

3. **Exécuter les actions**
   - Pour chaque action, lancer l'agent Claude approprié
   - Marquer avec label 'processing' avant de commencer
   - Lancer en parallèle si possible (avec & en bash)

4. **Mettre à jour last-actions.json**
   - Ajouter les nouvelles actions avec timestamp
   - Garder seulement les 10 dernières entrées
   - Format : [{\"timestamp\": \"ISO8601\", \"type\": \"...\", \"repo\": \"...\", \"number\": N}]

5. **Logger les résultats**
   - Afficher un résumé des actions entreprises
   - Signaler tout problème rencontré

Execute maintenant ce cycle complet !
"
    
    # Exécuter Claude avec le prompt
    claude "$PROMPT" --continue -p --permission-mode bypassPermissions
    
    if [ $? -eq 0 ]; then
        log "✅ Cycle d'orchestration terminé avec succès"
    else
        error "Échec du cycle d'orchestration"
    fi
}

# Fonction de nettoyage en cas d'interruption
cleanup() {
    echo ""
    log "🛑 Arrêt de l'orchestrateur demandé"
    exit 0
}

# Gérer Ctrl+C proprement
trap cleanup SIGINT SIGTERM

# Programme principal
main() {
    log "🚀 Démarrage de l'orchestrateur Dulien avec Claude"
    
    # Vérifications
    check_requirements
    
    # Mode unique ou continu
    if [ "$1" == "--once" ]; then
        info "Mode exécution unique"
        run_orchestration_cycle
    else
        info "Mode continu - Cycle toutes les 10 minutes"
        info "Appuyez sur Ctrl+C pour arrêter"
        
        # Boucle infinie
        while true; do
            run_orchestration_cycle
            
            info "⏱️  Pause de 10 minutes avant le prochain cycle..."
            sleep 600
        done
    fi
}

# Lancer le programme
main "$@"