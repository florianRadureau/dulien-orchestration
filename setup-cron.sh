#!/bin/bash
# setup-cron.sh - Configuration cron pour orchestrateur automatique

ORCHESTRATOR_DIR="/home/florian/projets/dulien-orchestration"
CRON_USER="florian"

echo "🔧 Configuration cron pour orchestrateur Dulien..."

# Créer les entrées cron
CRON_ENTRIES="# Orchestrateur Dulien - Détection nouvelles épics toutes les 15min
*/15 * * * * cd $ORCHESTRATOR_DIR && ./orchestrator-dulien.sh check-epics >> logs/cron.log 2>&1

# Orchestrateur Dulien - Exécution tâches toutes les 5min  
*/5 * * * * cd $ORCHESTRATOR_DIR && ./orchestrator-dulien.sh execute-tasks >> logs/cron.log 2>&1

# Orchestrateur Dulien - Nettoyage logs hebdomadaire
0 2 * * 0 find $ORCHESTRATOR_DIR/logs -name '*.log' -mtime +7 -delete"

# Ajouter au crontab
(crontab -l 2>/dev/null | grep -v "Orchestrateur Dulien"; echo "$CRON_ENTRIES") | crontab -

echo "✅ Cron configuré avec succès !"
echo ""
echo "📋 Tâches programmées :"
echo "• Détection épics : toutes les 15 minutes"  
echo "• Exécution tâches : toutes les 5 minutes"
echo "• Nettoyage logs : dimanche 2h"
echo ""
echo "🔍 Vérifiez avec : crontab -l | grep Dulien"
echo "📊 Monitoring : ./monitor.sh"
echo ""
echo "⚠️ Assurez-vous que :"
echo "1. GITHUB_TOKEN est défini dans l'environnement"
echo "2. Claude Code CLI est installé globalement"  
echo "3. Les permissions GitHub sont correctes"