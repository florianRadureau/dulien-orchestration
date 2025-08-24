#!/bin/bash
# monitor.sh - Script de monitoring en temps réel de l'orchestrateur Dulien

WORK_DIR="/home/florian/projets/dulien-orchestration"
WORKFLOW_FILE="$WORK_DIR/workflow.json"
LOG_FILE="$WORK_DIR/logs/orchestrator.log"

show_dashboard() {
    clear
    echo "🚀 === ORCHESTRATEUR DULIEN - DASHBOARD TEMPS RÉEL ==="
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════"
    
    if [ -f "$WORKFLOW_FILE" ]; then
        echo "📊 ÉPICS EN COURS:"
        jq -r '.epics | to_entries[] | "Epic #\(.key): \(.value.tasks_created | length) tâche(s)"' "$WORKFLOW_FILE"
        echo ""
        
        echo "📋 TÂCHES PAR STATUT:"
        jq -r '
            [.epics | .. | objects | select(.task_id?) | .status // "pending"] |
            group_by(.) | 
            map({status: .[0], count: length}) |
            .[] | 
            "\(.status): \(.count)"
        ' "$WORKFLOW_FILE" 2>/dev/null
        echo ""
        
        echo "🔄 TÂCHES DÉTAILLÉES:"
        jq -r '
            .epics | to_entries[] | 
            .value.tasks_created[] as $task |
            .value.workflow[] |
            select(.task_id == ($task.repo + "-" + ($task.issue_number | tostring))) |
            "[\(.status // "pending")] \($task.repo)#\($task.issue_number): \($task.title)"
        ' "$WORKFLOW_FILE" 2>/dev/null
    else
        echo "❌ Aucun workflow en cours"
    fi
    
    echo ""
    echo "📝 DERNIÈRES ACTIVITÉS:"
    if [ -f "$LOG_FILE" ]; then
        tail -n 5 "$LOG_FILE"
    else
        echo "Aucun log disponible"
    fi
    
    echo ""
    echo "🔧 ACTIONS: [R]afraîchir [Q]uitter [L]ogs [W]orkflow"
}

show_logs() {
    clear
    echo "📝 === LOGS TEMPS RÉEL ==="
    echo "Appuyez sur 'q' pour quitter"
    echo "═══════════════════════════"
    tail -f "$LOG_FILE" 2>/dev/null &
    TAIL_PID=$!
    
    read -n 1 -s
    kill $TAIL_PID 2>/dev/null
}

show_workflow() {
    clear
    echo "📊 === WORKFLOW JSON ==="
    echo "Appuyez sur une touche pour revenir"
    echo "═══════════════════════════"
    if [ -f "$WORKFLOW_FILE" ]; then
        jq . "$WORKFLOW_FILE"
    else
        echo "Aucun workflow disponible"
    fi
    
    read -n 1 -s
}

main() {
    while true; do
        show_dashboard
        
        read -n 1 -s input
        case $input in
            'q'|'Q')
                echo "Au revoir ! 👋"
                exit 0
                ;;
            'r'|'R'|'')
                # Rafraîchir (par défaut)
                ;;
            'l'|'L')
                show_logs
                ;;
            'w'|'W')
                show_workflow
                ;;
        esac
        
        sleep 2
    done
}

# Vérifications
if [ ! -d "$WORK_DIR" ]; then
    echo "❌ Dossier orchestrateur non trouvé: $WORK_DIR"
    exit 1
fi

main