#!/bin/bash
# orchestrator-dulien.sh
# Orchestrateur automatique des agents Dulien via Claude Code CLI
set -e

# Configuration
WORK_DIR="/home/florian/projets/dulien-orchestration"
WORKFLOW_FILE="$WORK_DIR/workflow.json"
AGENTS_DIR="$WORK_DIR/agents"
LOG_FILE="$WORK_DIR/logs/orchestrator.log"
ORG="mentorize-app"
REPO="infrastructure"

# Créer structure si nécessaire
mkdir -p "$WORK_DIR"/{agents,logs,temp}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === CONFIGURATION AGENTS MCP ===

init_agents_config() {
    log "🔧 Initialisation configuration agents..."
    
    # Tech Lead Agent - avec chemin correct vers business-context-mcp
    cat > "$AGENTS_DIR/tech-lead.json" << 'EOF'
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "business-context": {
      "command": "node",
      "args": ["${HOME}/projets/business-context-mcp/dist/index.js"]
    }
  }
}
EOF

    # Webapp Agent  
    cat > "$AGENTS_DIR/webapp.json" << 'EOF'
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "business-context": {
      "command": "node", 
      "args": ["../business-context-mcp/dist/index.js"]
    },
    "accessibility": {
      "command": "npx",
      "args": ["-y", "a11y-mcp"]
    }
  }
}
EOF

    # Tenant API Agent
    cat > "$AGENTS_DIR/tenant-api.json" << 'EOF' 
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "business-context": {
      "command": "node",
      "args": ["../business-context-mcp/dist/index.js"]
    }
  }
}
EOF

    # Security Agent
    cat > "$AGENTS_DIR/security.json" << 'EOF'
{
  "mcpServers": {
    "github": {
      "command": "npx", 
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
EOF

    log "✅ Configuration agents initialisée"
}

# === DÉTECTION NOUVELLES ÉPICS ===

check_new_epics() {
    log "🔍 Vérification nouvelles épics..."
    
    # Test connectivité GitHub d'abord
    if ! gh auth status >/dev/null 2>&1; then
        log "❌ GitHub CLI non authentifié. Lancez: gh auth login"
        return 1
    fi
    
    # Test accès au repo
    if ! gh repo view "$ORG/$REPO" >/dev/null 2>&1; then
        log "❌ Repo $ORG/$REPO inaccessible. Vérifiez les permissions."
        return 1
    fi
    
    # Récupérer toutes les issues épics d'abord (plus permissif)
    log "🔎 Recherche des épics dans $ORG/$REPO..."
    
    ALL_EPICS=$(gh issue list \
        --repo "$ORG/$REPO" \
        --state open \
        --json number,title,labels,createdAt 2>/dev/null)
    
    if [ "$?" -ne 0 ] || [ -z "$ALL_EPICS" ] || [ "$ALL_EPICS" = "null" ]; then
        log "📭 Aucune issue trouvée dans le repo"
        return 0
    fi
    
    log "📊 $(echo "$ALL_EPICS" | jq length) issues trouvées au total"
    
    # Filtrer les épics non traitées
    NEW_EPICS=$(echo "$ALL_EPICS" | jq -c '
        .[] | 
        select(.title | test("\\[EPIC\\]"; "i")) |
        select(
            (.labels | map(.name) | contains(["status:analyzed"]) | not) and
            (.labels | map(.name) | contains(["status:completed"]) | not)
        )
    ')
    
    if [ -z "$NEW_EPICS" ]; then
        log "📭 Aucune nouvelle épic à traiter"
        return 0
    fi
    
    echo "$NEW_EPICS" | while read -r epic; do
        EPIC_NUMBER=$(echo "$epic" | jq -r '.number')
        EPIC_TITLE=$(echo "$epic" | jq -r '.title')
        
        log "📋 Nouvelle épic détectée: #$EPIC_NUMBER - $EPIC_TITLE"
        
        # Déclencher analyse Tech Lead
        analyze_epic "$EPIC_NUMBER"
    done
}

# === EXTRACTION JSON ROBUSTE ===

extract_json() {
    local input="$1"
    local result=""
    
    # Method 1: sed extraction entre ```json markers
    result=$(echo "$input" | sed -n '/```json/,/```/p' | sed '1d;$d' | head -c 10000)
    if [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi
    
    # Method 2: awk extraction
    result=$(echo "$input" | awk '/```json/,/```/ {if (!/```/) print}' | head -c 10000)
    if [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi
    
    # Method 3: grep + tail/head extraction  
    result=$(echo "$input" | grep -A 1000 '```json' | grep -B 1000 '```' | head -n -1 | tail -n +2 | head -c 10000)
    if [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi
    
    # Method 4: Python fallback si disponible
    if command -v python3 >/dev/null 2>&1; then
        result=$(echo "$input" | python3 -c "
import sys, json
lines = sys.stdin.read().splitlines()
in_json = False
json_lines = []
for line in lines:
    if '```json' in line:
        in_json = True
        continue
    elif '```' in line and in_json:
        break
    elif in_json:
        json_lines.append(line)
        
if json_lines:
    json_str = '\n'.join(json_lines).strip()
    try:
        json.loads(json_str)
        print(json_str)
    except:
        pass
" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
    fi
    
    log "❌ Échec extraction JSON avec toutes les méthodes"
    return 1
}

# === AGENT TECH LEAD ===

analyze_epic() {
    local epic_number="$1"
    log "🤖 Démarrage analyse Tech Lead pour épic #$epic_number"
    
    # Récupérer détails de l'épic
    EPIC_DATA=$(gh issue view "$epic_number" --repo "$ORG/$REPO" --json title,body,labels)
    
    # Prompt Tech Lead Agent
    TECH_LEAD_PROMPT="Tu es le Tech Lead Agent de Dulien. Tu dois analyser cette épic et créer les tâches techniques.

EPIC #$epic_number: $(echo "$EPIC_DATA" | jq -r '.title')

DESCRIPTION:
$(echo "$EPIC_DATA" | jq -r '.body')

IMPORTANT:
1. Tu DOIS utiliser l'outil mcp__github__create_issue pour créer les tâches dans les repos appropriés
2. Tu DOIS retourner le résultat au format JSON exact ci-dessous
3. Utilise le business-context MCP pour comprendre le contexte métier

REPOS DISPONIBLES:
- webapp (Angular/TypeScript) → agent: webapp
- tenant-specific-api (NestJS) → agent: tenant-api  
- referencial (NestJS) → agent: referencial
- mail-server (Node.js) → agent: mail-server
- landing-page (Next.js) → agent: landing-page
- infrastructure (DevOps) → agent: infrastructure

Tu DOIS terminer ta réponse par ce JSON exact:

\`\`\`json
{
  \"analysis\": \"Description technique de l'impact\",
  \"tasks_created\": [
    {\"repo\": \"webapp\", \"issue_number\": 456, \"title\": \"Titre de la tâche\", \"agent\": \"webapp\"},
    {\"repo\": \"tenant-specific-api\", \"issue_number\": 789, \"title\": \"Autre tâche\", \"agent\": \"tenant-api\"}
  ],
  \"workflow\": [
    {\"task_id\": \"webapp-456\", \"depends_on\": [], \"priority\": 1},
    {\"task_id\": \"tenant-api-789\", \"depends_on\": [\"webapp-456\"], \"priority\": 2}
  ]
}
\`\`\`

Commence maintenant l'analyse et la création des tâches."

    # Récupérer le token GitHub pour Tech Lead Agent
    if [ -z "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN=$(gh auth token 2>/dev/null || echo "")
        if [ -z "$GITHUB_TOKEN" ]; then
            log "❌ Impossible de récupérer GITHUB_TOKEN pour Tech Lead Agent"
            return 1
        fi
    fi
    
    # Exécuter Tech Lead Agent via pipe avec token d'environnement
    TECH_LEAD_RESULT=$(echo "$TECH_LEAD_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print \
        --mcp-config "$AGENTS_DIR/tech-lead.json" \
        --append-system-prompt "Tu es le Tech Lead Agent Dulien. Tu analyses les épics et crées les tâches techniques distribuées." \
        --allowed-tools "mcp__github__*,business_context__*")
    
    log "📄 Résultat analyse Tech Lead reçu"
    
    # Extraire le JSON du résultat avec fallbacks robustes
    if WORKFLOW_JSON=$(extract_json "$TECH_LEAD_RESULT"); then
        # Ajouter au workflow global
        add_to_workflow "$epic_number" "$WORKFLOW_JSON"
        
        # Marquer épic comme analysée
        gh issue edit "$epic_number" --repo "$ORG/$REPO" --add-label "status:analyzed"
        
        # Commenter sur l'épic
        gh issue comment "$epic_number" --repo "$ORG/$REPO" --body "🤖 **Tech Lead Agent - Analyse Terminée**

$TECH_LEAD_RESULT

---
*Tâches techniques créées et ajoutées au workflow d'orchestration automatique.*"
        
        log "✅ Epic #$epic_number analysée et workflow mis à jour"
    else
        log "❌ Erreur: impossible d'extraire le JSON du résultat Tech Lead"
        # Sauvegarder résultat brut pour debug
        echo "$TECH_LEAD_RESULT" > "$WORK_DIR/temp/failed-analysis-$epic_number.txt"
        
        # Marquer épic comme échouée
        gh issue edit "$epic_number" --repo "$ORG/$REPO" --add-label "status:analysis-failed" --add-label "needs:attention"
        gh issue comment "$epic_number" --repo "$ORG/$REPO" --body "❌ **Tech Lead Agent - Erreur d'Analyse**

L'extraction du plan JSON a échoué. Résultat sauvegardé pour investigation.

**Action requise**: Vérification manuelle du format de réponse Claude Code.

---
*Debug info sauvé dans: temp/failed-analysis-$epic_number.txt*"
    fi
}

# === GESTION WORKFLOW ===

add_to_workflow() {
    local epic_number="$1"
    local workflow_json="$2"
    
    # Créer workflow.json s'il n'existe pas
    if [ ! -f "$WORKFLOW_FILE" ]; then
        echo '{"epics": {}}' > "$WORKFLOW_FILE"
    fi
    
    # Ajouter l'épic au workflow
    jq --arg epic "$epic_number" --argjson workflow "$workflow_json" \
        '.epics[$epic] = $workflow' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp"
    mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"
    
    log "📝 Workflow mis à jour pour épic #$epic_number"
}

# === DÉTECTION PRs POUR REVIEW ===

check_prs_for_review() {
    if [ ! -f "$WORKFLOW_FILE" ]; then
        return 0
    fi
    
    log "🔍 Vérification PRs prêtes pour review..."
    
    # Chercher tâches avec status review_requested
    REVIEW_TASKS=$(jq -r '
        .epics | to_entries[] | 
        .value.tasks_created[] as $task |
        .value.workflow[] | 
        select(.task_id == ($task.repo + "-" + ($task.issue_number | tostring))) |
        select(.status == "review_requested") |
        {task_id: .task_id, repo: $task.repo, issue: $task.issue_number, agent: $task.agent, epic: .key}
    ' "$WORKFLOW_FILE")
    
    if [ -z "$REVIEW_TASKS" ]; then
        log "📭 Aucune tâche en attente de review"
        return 0
    fi
    
    echo "$REVIEW_TASKS" | jq -c '.' | while read -r task; do
        TASK_ID=$(echo "$task" | jq -r '.task_id')
        REPO=$(echo "$task" | jq -r '.repo') 
        ISSUE=$(echo "$task" | jq -r '.issue')
        AGENT=$(echo "$task" | jq -r '.agent')
        
        log "🔍 Vérification PR pour tâche $TASK_ID"
        
        # Chercher PR associée à cette tâche
        PR_NUMBER=$(gh pr list --repo mentorize-app/$REPO --state open --json number,headRefName --jq '.[] | select(.headRefName | contains("'$TASK_ID'") or contains("alerte-test") or contains("bouton-test")) | .number' | head -1)
        
        if [ -n "$PR_NUMBER" ]; then
            log "📋 PR #$PR_NUMBER trouvée pour $TASK_ID - Déclenchement review"
            
            # Déclencher agents de review
            trigger_review_agents "$REPO" "$PR_NUMBER" "$TASK_ID"
            
            # Marquer comme en cours de review
            mark_task_status "$TASK_ID" "under_review"
        fi
    done
}

trigger_review_agents() {
    local repo="$1"
    local pr_number="$2"
    local task_id="$3"
    
    log "🚀 Déclenchement agents review pour PR #$pr_number"
    
    # Déclencher Security Agent
    execute_security_review "$repo" "$pr_number" "$task_id" &
    
    # Déclencher Tech Lead Review Agent
    execute_tech_lead_review "$repo" "$pr_number" "$task_id" &
    
    # Si webapp, déclencher aussi RGAA Agent  
    if [ "$repo" = "webapp" ]; then
        execute_rgaa_review "$repo" "$pr_number" "$task_id" &
    fi
    
    # Attendre que tous les agents terminent
    wait
}

# === EXÉCUTION TÂCHES ===

execute_pending_tasks() {
    if [ ! -f "$WORKFLOW_FILE" ]; then
        return 0
    fi
    
    log "⚙️ Vérification tâches en attente..."
    
    # Chercher tâches prêtes à exécuter (dépendances satisfaites)
    READY_TASKS=$(jq -r '
        .epics | to_entries | .[] | 
        .value.tasks_created[] as $task |
        .value.workflow[] | 
        select(.task_id == ($task.repo + "-" + ($task.issue_number | tostring))) |
        select(.status // "pending" == "pending") |
        select((.depends_on // []) | length == 0 or 
               all(. as $dep | $dep | . as $dep_id | 
                   (.epics | .. | objects | select(.task_id? == $dep_id) | .status? == "completed"))) |
        {task_id: .task_id, repo: $task.repo, issue: $task.issue_number, agent: $task.agent, epic: .key}
    ' "$WORKFLOW_FILE")
    
    if [ -z "$READY_TASKS" ]; then
        log "📭 Aucune tâche prête à exécuter"
        return 0
    fi
    
    echo "$READY_TASKS" | jq -c '.' | while read -r task; do
        TASK_ID=$(echo "$task" | jq -r '.task_id')
        REPO=$(echo "$task" | jq -r '.repo') 
        ISSUE=$(echo "$task" | jq -r '.issue')
        AGENT=$(echo "$task" | jq -r '.agent')
        EPIC=$(echo "$task" | jq -r '.epic')
        
        log "🚀 Exécution tâche $TASK_ID"
        
        # Exécuter l'agent approprié
        execute_agent "$AGENT" "$REPO" "$ISSUE" "$TASK_ID"
    done
}

execute_agent() {
    local agent="$1"
    local repo="$2" 
    local issue="$3"
    local task_id="$4"
    
    log "🤖 Démarrage agent $agent pour tâche $repo#$issue"
    
    # Récupérer détails de la tâche
    TASK_DATA=$(gh issue view "$issue" --repo "$ORG/$repo" --json title,body,labels)
    
    case "$agent" in
        "webapp")
            execute_webapp_agent "$repo" "$issue" "$TASK_DATA" "$task_id"
            ;;
        "tenant-api")
            execute_api_agent "$repo" "$issue" "$TASK_DATA" "$task_id" "tenant-api"
            ;;
        "referencial")
            execute_api_agent "$repo" "$issue" "$TASK_DATA" "$task_id" "referencial"  
            ;;
        "mail-server")
            execute_mail_server_agent "$repo" "$issue" "$TASK_DATA" "$task_id"
            ;;
        "landing-page")
            execute_landing_page_agent "$repo" "$issue" "$TASK_DATA" "$task_id"
            ;;
        "infrastructure")
            execute_infrastructure_agent "$repo" "$issue" "$TASK_DATA" "$task_id"
            ;;
        "security")
            execute_security_agent "$repo" "$issue" "$TASK_DATA" "$task_id"
            ;;
        *)
            log "⚠️ Agent $agent non reconnu"
            ;;
    esac
}

execute_webapp_agent() {
    local repo="$1"
    local issue="$2"
    local task_data="$3"
    local task_id="$4"
    
    WEBAPP_PROMPT="TÂCHE: Créer composant alerte-test + PR automatique

ÉTAPES REQUISES:
1. Crée AlerteTestComponent dans src/app/shared/components/alerte-test/
2. Code Angular 20 (@if, signals, standalone)
3. Message \"Alerte Orchestrateur\" rouge + bouton X fermer
4. Tests unitaires .spec.ts
5. git add + git commit + git push
6. UTILISE Bash pour exécuter: gh pr create --title \"feat: AlerteTestComponent\" --body \"Composant créé par agent\"

IMPORTANT: Utilise l'outil Bash pour créer la PR, pas MCP GitHub."

    # Récupérer le token GitHub
    if [ -z "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN=$(gh auth token 2>/dev/null || echo "")
        if [ -z "$GITHUB_TOKEN" ]; then
            log "❌ Impossible de récupérer GITHUB_TOKEN"
            return 1
        fi
    fi
    
    # Exécuter Webapp Agent avec token d'environnement
    WEBAPP_RESULT=$(echo "$WEBAPP_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print \
        --mcp-config "$AGENTS_DIR/webapp.json" \
        --append-system-prompt "Tu es le Webapp Agent Dulien spécialisé Angular/TypeScript. Tu développes des interfaces utilisateur accessibles et performantes." \
        --add-dir "/home/florian/projets/webapp" \
        --allowed-tools "Read,Write,Edit,Bash,mcp__github__*")
    
    log "📄 Webapp Agent terminé pour $task_id"
    
    # Marquer comme complété et passer en review
    mark_task_completed "$task_id" "review_requested"
    
    # Commenter sur la tâche
    gh issue comment "$issue" --repo "$ORG/$repo" --body "🤖 **Webapp Agent - Développement Terminé**

$WEBAPP_RESULT

---
*Tâche développée automatiquement. PR créée et en attente de review.*"
}

execute_api_agent() {
    local repo="$1"
    local issue="$2" 
    local task_data="$3"
    local task_id="$4"
    local api_type="$5"
    
    API_PROMPT="Tu es l'Agent API $api_type spécialisé NestJS/TypeScript pour Dulien.

TÂCHE: $repo#$issue
$(echo "$task_data" | jq -r '.title')

DESCRIPTION:
$(echo "$task_data" | jq -r '.body')

INSTRUCTIONS:
1. Analyse la tâche et le contexte métier via Business Context MCP
2. Développe les endpoints API NestJS nécessaires
3. Crée les entities, DTOs, controllers, services
4. Implémente la validation des données et la sécurité
5. Crée les tests unitaires et d'intégration
6. Met à jour la documentation OpenAPI
7. Crée une PR avec description détaillée

IMPORTANT: Respecte les patterns NestJS et la cohérence avec les APIs existantes."

    # Exécuter API Agent
    API_RESULT=$(echo "$API_PROMPT" | claude --print \
        --mcp-config "$AGENTS_DIR/$api_type.json" \
        --append-system-prompt "Tu es l'Agent API $api_type Dulien spécialisé NestJS/TypeScript. Tu développes des APIs robustes et sécurisées." \
        --add-dir "../$repo" \
        --allowed-tools "Edit,Bash,github_create_pull_request")
    
    log "📄 API Agent $api_type terminé pour $task_id"
    
    # Marquer comme complété et demander security review
    mark_task_completed "$task_id" "security_review_requested"
}

execute_security_agent() {
    local repo="$1"
    local issue="$2"
    local task_data="$3" 
    local task_id="$4"
    
    SECURITY_PROMPT="AUDIT SÉCURITÉ PR #3 - AlerteTestComponent

MISSION: Audit de sécurité de la PR mentorize-app/webapp #3

ACTIONS REQUISES:
1. Utilise Bash pour: gh pr view 3 --repo mentorize-app/webapp --json files
2. Analyse les fichiers modifiés pour vulnérabilités OWASP Top 10
3. Vérifie: XSS, injection, gestion d'erreurs, données sensibles
4. Vérifie l'accessibilité et la sécurité frontend
5. Poste ton rapport via: gh pr comment 3 --repo mentorize-app/webapp --body \"RAPPORT_SÉCURITÉ\"

FORMAT RAPPORT:
# 🔒 Security Review - AlerteTestComponent
## ✅ Points validés
## ⚠️ Recommandations 
## 📋 Score sécurité: X/10"

    # Récupérer le token GitHub pour Security Agent  
    if [ -z "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN=$(gh auth token 2>/dev/null || echo "")
    fi

    # Exécuter Security Agent
    SECURITY_RESULT=$(echo "$SECURITY_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print \
        --mcp-config "$AGENTS_DIR/security.json" \
        --append-system-prompt "Tu es le Security Agent Dulien. Tu audites la sécurité du code et postes des comments sur les PRs." \
        --add-dir "/home/florian/projets/webapp" \
        --allowed-tools "Read,Bash")
    
    log "📄 Security Agent terminé pour $task_id"
    
    # Marquer comme review terminée
    mark_task_completed "$task_id" "completed"
}

execute_mail_server_agent() {
    local repo="$1"
    local issue="$2"
    local task_data="$3"
    local task_id="$4"
    
    MAIL_PROMPT="Tu es l'Agent Mail Server spécialisé Node.js pour Dulien.

TÂCHE: $repo#$issue
$(echo "$task_data" | jq -r '.title')

DESCRIPTION:
$(echo "$task_data" | jq -r '.body')

INSTRUCTIONS:
1. Analyse la tâche et le contexte métier via Business Context MCP
2. Développe les services email Node.js nécessaires
3. Crée les templates d'emails et systèmes de queues
4. Implémente la gestion d'erreurs et retry logic
5. Crée les tests unitaires
6. Crée une PR avec description détaillée

IMPORTANT: Respecte les patterns Node.js et l'architecture microservices."

    MAIL_RESULT=$(echo "$MAIL_PROMPT" | claude --print \
        --mcp-config "$AGENTS_DIR/mail-server.json" \
        --append-system-prompt "Tu es l'Agent Mail Server Dulien spécialisé Node.js. Tu développes des services email robustes." \
        --add-dir "../$repo" \
        --allowed-tools "Edit,Bash,mcp__github__create_pull_request")
    
    log "📄 Mail Server Agent terminé pour $task_id"
    mark_task_completed "$task_id" "review_requested"
}

execute_landing_page_agent() {
    local repo="$1"
    local issue="$2"
    local task_data="$3"
    local task_id="$4"
    
    LANDING_PROMPT="Tu es l'Agent Landing Page spécialisé Next.js pour Dulien.

TÂCHE: $repo#$issue
$(echo "$task_data" | jq -r '.title')

DESCRIPTION:
$(echo "$task_data" | jq -r '.body')

INSTRUCTIONS:
1. Analyse la tâche et le contexte métier via Business Context MCP
2. Développe les pages Next.js nécessaires
3. Optimise pour le SEO et les performances
4. Assure la responsivité et l'accessibilité
5. Crée les tests lighthouse
6. Crée une PR avec description détaillée

IMPORTANT: Optimise pour conversion et performance web."

    LANDING_RESULT=$(echo "$LANDING_PROMPT" | claude --print \
        --mcp-config "$AGENTS_DIR/landing-page.json" \
        --append-system-prompt "Tu es l'Agent Landing Page Dulien spécialisé Next.js. Tu développes des pages marketing performantes." \
        --add-dir "../$repo" \
        --allowed-tools "Edit,Bash,mcp__github__create_pull_request")
    
    log "📄 Landing Page Agent terminé pour $task_id"
    mark_task_completed "$task_id" "review_requested"
}

execute_infrastructure_agent() {
    local repo="$1"
    local issue="$2"
    local task_data="$3"
    local task_id="$4"
    
    INFRA_PROMPT="Tu es l'Agent Infrastructure spécialisé DevOps pour Dulien.

TÂCHE: $repo#$issue
$(echo "$task_data" | jq -r '.title')

DESCRIPTION:
$(echo "$task_data" | jq -r '.body')

INSTRUCTIONS:
1. Analyse la tâche et le contexte technique
2. Développe les configurations Docker/Docker Compose
3. Configure les services de monitoring
4. Implémente les scripts de déploiement
5. Assure la sécurité infrastructure
6. Crée une PR avec description détaillée

IMPORTANT: Assure haute disponibilité et scalabilité."

    INFRA_RESULT=$(echo "$INFRA_PROMPT" | claude --print \
        --mcp-config "$AGENTS_DIR/infrastructure.json" \
        --append-system-prompt "Tu es l'Agent Infrastructure Dulien spécialisé DevOps. Tu configures des infrastructures robustes." \
        --add-dir "../$repo" \
        --allowed-tools "Edit,Bash,mcp__github__create_pull_request")
    
    log "📄 Infrastructure Agent terminé pour $task_id"
    mark_task_completed "$task_id" "review_requested"
}

mark_task_completed() {
    local task_id="$1"
    local status="$2"
    
    # Mettre à jour le statut dans workflow.json
    jq --arg task_id "$task_id" --arg status "$status" '
        (.epics | .. | objects | select(.task_id? == $task_id) | .status) = $status
    ' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp"
    mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"
    
    log "✅ Tâche $task_id marquée comme $status"
}

mark_task_status() {
    local task_id="$1"
    local status="$2"
    
    # Mettre à jour le statut dans workflow.json
    jq --arg task_id "$task_id" --arg status "$status" '
        (.epics | .. | objects | select(.task_id? == $task_id) | .status) = $status
    ' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp"
    mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"
    
    log "🔄 Statut $task_id mis à jour: $status"
}

# === AGENTS DE REVIEW ===

execute_security_review() {
    local repo="$1"
    local pr_number="$2" 
    local task_id="$3"
    
    log "🔒 Security Agent - Review PR #$pr_number"
    
    SECURITY_REVIEW_PROMPT="AUDIT SÉCURITÉ AUTOMATIQUE

MISSION: Review sécurité PR mentorize-app/$repo #$pr_number

ACTIONS:
1. Utilise Bash: gh pr view $pr_number --repo mentorize-app/$repo --json files
2. Analyse vulnérabilités OWASP Top 10 dans les fichiers modifiés
3. Vérifie XSS, injection, validation input, gestion erreurs
4. Poste rapport: gh pr comment $pr_number --repo mentorize-app/$repo --body \"RAPPORT\"

FORMAT RAPPORT:
# 🔒 Security Review Automatique
## ✅ Validé: [liste points OK] 
## ⚠️ Recommandations: [si nécessaire]
## 📊 Score: X/10
*Review automatique par Security Agent Dulien*"

    # Récupérer token et exécuter
    if [ -z "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN=$(gh auth token 2>/dev/null)
    fi
    
    SECURITY_RESULT=$(echo "$SECURITY_REVIEW_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print \
        --mcp-config "$AGENTS_DIR/security.json" \
        --append-system-prompt "Tu es le Security Agent automatique. Tu postes des reviews de sécurité sur les PRs." \
        --add-dir "/home/florian/projets/$repo" \
        --allowed-tools "Read,Bash")
    
    log "🔒 Security review terminée pour PR #$pr_number"
    echo "$SECURITY_RESULT" >> "$WORK_DIR/logs/security-reviews.log"
}

execute_tech_lead_review() {
    local repo="$1"
    local pr_number="$2" 
    local task_id="$3"
    
    log "👔 Tech Lead Agent - Review technique PR #$pr_number"
    
    TECH_LEAD_REVIEW_PROMPT="REVIEW TECHNIQUE TECH LEAD

MISSION: Review technique approfondie PR mentorize-app/$repo #$pr_number

ACTIONS:
1. Utilise Bash: gh pr view $pr_number --repo mentorize-app/$repo --json files
2. Analyse qualité code: architecture, patterns, conventions
3. Vérifie conformité Angular 20, signals, control flow moderne
4. Contrôle tests unitaires, performance, maintenabilité
5. Poste rapport: gh pr comment $pr_number --repo mentorize-app/$repo --body \"RAPPORT\"

FORMAT RAPPORT:
# 👔 Tech Lead Review - Analyse Technique
## ✅ Conformité Technique: [points validés]
## 🏗️ Architecture: [évaluation structure]
## 🧪 Tests & Qualité: [couverture et pertinence]
## ⚠️ Améliorations: [si nécessaire]
## 📊 Score Technique: X/10
*Review technique par Tech Lead Agent Dulien*"

    # Récupérer token et exécuter
    if [ -z "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN=$(gh auth token 2>/dev/null)
    fi
    
    TECH_LEAD_RESULT=$(echo "$TECH_LEAD_REVIEW_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print \
        --mcp-config "$AGENTS_DIR/tech-lead.json" \
        --append-system-prompt "Tu es le Tech Lead Agent spécialisé qualité code. Tu postes des reviews techniques approfondies." \
        --add-dir "/home/florian/projets/$repo" \
        --allowed-tools "Read,Bash")
    
    log "👔 Tech Lead review terminée pour PR #$pr_number"
    echo "$TECH_LEAD_RESULT" >> "$WORK_DIR/logs/tech-lead-reviews.log"
}

execute_rgaa_review() {
    local repo="$1"
    local pr_number="$2"
    local task_id="$3"
    
    log "♿ RGAA Agent - Review accessibilité PR #$pr_number"
    
    RGAA_REVIEW_PROMPT="AUDIT ACCESSIBILITÉ RGAA

MISSION: Review accessibilité PR mentorize-app/$repo #$pr_number

ACTIONS:
1. Utilise Bash: gh pr view $pr_number --repo mentorize-app/$repo --json files
2. Vérifie conformité RGAA/WCAG sur les composants Angular
3. Contrôle: aria-labels, focus, contraste, keyboard navigation
4. Poste rapport: gh pr comment $pr_number --repo mentorize-app/$repo --body \"RAPPORT\"

FORMAT RAPPORT:
# ♿ RGAA Review Automatique  
## ✅ Conformité: [critères OK]
## ⚠️ Améliorations: [si nécessaire] 
## 📊 Score RGAA: X/10
*Review automatique par RGAA Agent Dulien*"

    # Exécuter RGAA Agent
    RGAA_RESULT=$(echo "$RGAA_REVIEW_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print \
        --mcp-config "$AGENTS_DIR/webapp.json" \
        --append-system-prompt "Tu es le RGAA Agent automatique spécialisé accessibilité. Tu postes des reviews RGAA sur les PRs." \
        --add-dir "/home/florian/projets/$repo" \
        --allowed-tools "Read,Bash")
    
    log "♿ RGAA review terminée pour PR #$pr_number"  
    echo "$RGAA_RESULT" >> "$WORK_DIR/logs/rgaa-reviews.log"
}

# === FINALISATION REVIEWS ===

check_completed_reviews() {
    if [ ! -f "$WORKFLOW_FILE" ]; then
        return 0
    fi
    
    log "🔍 Vérification reviews terminées..."
    
    # Chercher tâches en cours de review
    UNDER_REVIEW_TASKS=$(jq -r '
        .epics | to_entries[] | 
        .value.tasks_created[] as $task |
        .value.workflow[] | 
        select(.task_id == ($task.repo + "-" + ($task.issue_number | tostring))) |
        select(.status == "under_review") |
        {task_id: .task_id, repo: $task.repo, issue: $task.issue_number}
    ' "$WORKFLOW_FILE")
    
    if [ -z "$UNDER_REVIEW_TASKS" ]; then
        return 0
    fi
    
    echo "$UNDER_REVIEW_TASKS" | jq -c '.' | while read -r task; do
        TASK_ID=$(echo "$task" | jq -r '.task_id')
        REPO=$(echo "$task" | jq -r '.repo')
        ISSUE=$(echo "$task" | jq -r '.issue')
        
        # Vérifier si des reviews sont présentes sur la PR
        PR_NUMBER=$(gh pr list --repo mentorize-app/$REPO --state open --json number,headRefName --jq '.[] | select(.headRefName | contains("'$TASK_ID'") or contains("alerte-test") or contains("bouton-test")) | .number' | head -1)
        
        if [ -n "$PR_NUMBER" ]; then
            # Compter commentaires de review via gh pr view
            PR_COMMENTS=$(gh pr view $PR_NUMBER --repo mentorize-app/$REPO --comments)
            SECURITY_REVIEWS=$(echo "$PR_COMMENTS" | grep -c "Security Review Automatique" || echo "0")
            TECH_LEAD_REVIEWS=$(echo "$PR_COMMENTS" | grep -c "Tech Lead Review" || echo "0")
            RGAA_REVIEWS=$(echo "$PR_COMMENTS" | grep -c "RGAA Review Automatique" || echo "0")
            
            # Vérifier si toutes les reviews requises sont présentes
            REQUIRED_REVIEWS_COUNT=2  # Security + Tech Lead
            if [ "$REPO" = "webapp" ]; then
                REQUIRED_REVIEWS_COUNT=3  # Security + Tech Lead + RGAA
            fi
            
            COMPLETED_REVIEWS=$((SECURITY_REVIEWS + TECH_LEAD_REVIEWS + RGAA_REVIEWS))
            
            # Si toutes reviews présentes, marquer comme prêt à merge
            if [ "$COMPLETED_REVIEWS" -ge "$REQUIRED_REVIEWS_COUNT" ]; then
                log "✅ Reviews complètes pour $TASK_ID - Prêt à merge"
                mark_task_status "$TASK_ID" "ready_to_merge"
                
                # Commentaire final sur l'issue
                # Construire message selon les reviews effectuées
                REVIEW_MESSAGE="✅ Code développé par Webapp Agent\n✅ PR créée: #$PR_NUMBER\n"
                
                if [ "$SECURITY_REVIEWS" -gt 0 ]; then
                    REVIEW_MESSAGE="${REVIEW_MESSAGE}✅ Review sécurité terminée\n"
                fi
                if [ "$TECH_LEAD_REVIEWS" -gt 0 ]; then
                    REVIEW_MESSAGE="${REVIEW_MESSAGE}✅ Review technique Tech Lead terminée\n"
                fi
                if [ "$RGAA_REVIEWS" -gt 0 ]; then
                    REVIEW_MESSAGE="${REVIEW_MESSAGE}✅ Review accessibilité RGAA terminée\n"
                fi
                
                gh issue comment "$ISSUE" --repo "mentorize-app/$REPO" --body "🎉 **Développement Terminé**

${REVIEW_MESSAGE}
**PR prête à être mergée manuellement.**

---
*Workflow orchestrateur Dulien terminé avec succès.*"
            fi
        fi
    done
}

# === FONCTION PRINCIPALE ===

main() {
    local action="${1:-full}"
    
    case "$action" in
        "init")
            init_agents_config
            ;;
        "check-epics")
            check_new_epics
            ;;
        "execute-tasks")
            execute_pending_tasks
            ;;
        "check-prs")
            check_prs_for_review
            ;;
        "check-reviews")
            check_completed_reviews
            ;;
        "full")
            log "🚀 Démarrage cycle complet orchestrateur Dulien"
            check_new_epics
            execute_pending_tasks
            check_prs_for_review
            check_completed_reviews
            log "✅ Cycle terminé"
            ;;
        *)
            echo "Usage: $0 [init|check-epics|execute-tasks|check-prs|check-reviews|full]"
            exit 1
            ;;
    esac
}

# Vérifier prérequis
if ! command -v claude &> /dev/null; then
    echo "❌ Claude Code CLI non trouvé"
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI non trouvé"  
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "❌ jq non trouvé"
    exit 1
fi

# Exécuter
main "$@"