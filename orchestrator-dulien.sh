#!/bin/bash
# orchestrator-dulien.sh
# Orchestrateur automatique des agents Dulien via Claude Code CLI
set -e

# Configuration PATH pour cron (assurer accès à claude CLI)
export PATH="/home/florian/.nvm/versions/node/v22.18.0/bin:$PATH"

# Configuration
WORK_DIR="/home/florian/projets/dulien-orchestration"
WORKFLOW_FILE="$WORK_DIR/workflow.json"
AGENTS_DIR="$WORK_DIR/agents"
LOG_FILE="$WORK_DIR/logs/orchestrator.log"
ORG="mentorize-app"
REPO="infrastructure"

# GitHub App Authentication
source "$WORK_DIR/github-auth.sh"

get_github_token() {
    # Utiliser GitHub App au lieu du token personnel
    get_installation_token
}

# Initialiser le token GitHub pour MCP
GITHUB_TOKEN=$(get_github_token)
export GITHUB_TOKEN

# Créer structure si nécessaire
mkdir -p "$WORK_DIR"/{agents,logs,temp}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === CONFIGURATION AGENTS MCP ===

init_agents_config() {
    log "🔧 Initialisation configuration agents..."
    
    # Tech Lead Agent - avec chemin correct vers business-context-mcp et token dynamique
    cat > "$AGENTS_DIR/tech-lead.json" << EOF
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
    
    # Filtrer les épics non traitées (vérifier dans workflow.json au lieu des labels)
    NEW_EPICS=$(echo "$ALL_EPICS" | jq -c --slurpfile workflow "$WORKFLOW_FILE" '
        .[] | 
        select(.title | test("\\[EPIC\\]"; "i")) |
        select(($workflow[0].epics[.number | tostring] // null) == null)
    ' 2>/dev/null || echo "$ALL_EPICS" | jq -c '.[] | select(.title | test("\\[EPIC\\]"; "i"))')
    
    if [ -z "$NEW_EPICS" ]; then
        log "📭 Aucune nouvelle épic à traiter"
        return 0
    fi
    
    # Trier par numéro croissant et traiter
    echo "$NEW_EPICS" | jq -s 'sort_by(.number)' | jq -c '.[]' | while read -r epic; do
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
    
    # Method 1: Extraction depuis le nouveau format Claude Code --output-format json
    if echo "$input" | jq . >/dev/null 2>&1; then
        # Vérifier si c'est une réponse Claude Code avec succès
        if echo "$input" | jq -e '.subtype == "success"' >/dev/null 2>&1; then
            # Extraire le champ "result" et chercher le JSON dedans
            result=$(echo "$input" | jq -r '.result' 2>/dev/null | sed -n '/```json/,/```/p' | sed '1d;$d' | head -c 10000)
            if [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
                echo "$result"
                return 0
            fi
        elif echo "$input" | jq -e '.subtype == "error_during_execution"' >/dev/null 2>&1; then
            log "❌ Claude a rencontré une erreur d'exécution (probablement MCP)"
            return 1
        fi
    fi
    
    # Method 2: Simple sed extraction entre ```json markers (ancien format)
    result=$(echo "$input" | sed -n '/```json/,/```/p' | sed '1d;$d' | head -c 10000)
    if [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi
    
    # Method 3: awk extraction
    result=$(echo "$input" | awk '/```json/,/```/ {if (!/```/) print}' | head -c 10000)
    if [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi
    
    # Method 4: JSON pur après lignes de log (pour create_github_issues)
    result=$(echo "$input" | awk '/^{/ {p=1} p {print}' | head -c 10000)
    if [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi
    
    log "❌ Échec extraction JSON avec toutes les méthodes"
    return 1
}

# === BUSINESS CONTEXT ===

load_business_context() {
    local context_dir="/home/florian/projets/business-context-mcp/src/data"
    local business_context=""
    
    # Charger les règles métier
    if [ -f "$context_dir/business-rules.json" ]; then
        business_context="$business_context

=== RÈGLES MÉTIER DULIEN/MENTORIZE ===
$(jq -r '.domains | to_entries[] | "## \(.key | ascii_upcase)\n\(.value.description)\n\n" + (.value.rules | to_entries[] | "### \(.key)\n- **Description**: \(.value.description)\n- **Conditions**: \(.value.conditions | join(", "))\n- **Actions**: \(.value.actions | join(", "))\n")' "$context_dir/business-rules.json" 2>/dev/null || echo "Business rules disponibles")"
    fi
    
    # Charger les patterns techniques
    if [ -f "$context_dir/patterns.json" ]; then
        business_context="$business_context

=== PATTERNS TECHNIQUES DULIEN ===
$(jq -r '.patterns | to_entries[] | "## \(.key | ascii_upcase)\n\(.value.description)\n\n" + (.value.patterns | to_entries[] | "### \(.value.name)\n\(.value.description)\n**Tech**: \(.value.technology // "N/A")\n")' "$context_dir/patterns.json" 2>/dev/null || echo "Patterns techniques disponibles")"
    fi
    
    # Charger le glossaire
    if [ -f "$context_dir/glossary.json" ]; then
        business_context="$business_context

=== GLOSSAIRE MÉTIER ===
$(jq -r '.glossary | to_entries[] | "**\(.key)**: \(.value.definition)"' "$context_dir/glossary.json" 2>/dev/null || echo "Glossaire métier disponible")"
    fi
    
    echo "$business_context"
}

# === AGENT TECH LEAD ===

analyze_epic() {
    local epic_number="$1"
    log "🤖 Démarrage analyse Tech Lead pour épic #$epic_number"
    
    # Récupérer détails de l'épic
    EPIC_DATA=$(gh issue view "$epic_number" --repo "$ORG/$REPO" --json title,body,labels)
    
    # Récupérer les données de l'épic
    local epic_title=$(echo "$EPIC_DATA" | jq -r '.title')
    local epic_body=$(echo "$EPIC_DATA" | jq -r '.body')
    
    # Prompt Tech Lead Agent
    TECH_LEAD_PROMPT="Tu es le Tech Lead Agent de Dulien. Tu dois analyser cette épic et planifier les tâches techniques.

EPIC #$epic_number: $epic_title

DESCRIPTION:
$epic_body

IMPORTANT:
1. Tu dois SEULEMENT analyser et planifier - ne crée pas d'issues GitHub
2. Tu DOIS retourner le résultat au format JSON exact ci-dessous  
3. Utilise le business-context MCP pour comprendre le contexte métier
4. Les numéros d'issues seront générés automatiquement après ton analyse

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
  \"tasks_to_create\": [
    {\"repo\": \"webapp\", \"title\": \"Titre de la tâche\", \"agent\": \"webapp\"},
    {\"repo\": \"tenant-specific-api\", \"title\": \"Autre tâche\", \"agent\": \"tenant-api\"}
  ],
  \"workflow\": [
    {\"task_id\": \"webapp-TBD\", \"depends_on\": [], \"priority\": 1},
    {\"task_id\": \"tenant-api-TBD\", \"depends_on\": [\"webapp-TBD\"], \"priority\": 2}
  ]
}
\`\`\`

Commence maintenant l'analyse et la création des tâches."

    # Récupérer le token GitHub pour Tech Lead Agent
    if [ -z "$GITHUB_TOKEN" ]; then
        export GITHUB_TOKEN=$(get_github_token)
        if [ -z "$GITHUB_TOKEN" ]; then
            log "❌ Impossible de récupérer GITHUB_TOKEN pour Tech Lead Agent"
            return 1
        fi
    fi
    
    # === INSTRUMENTATION DIAGNOSTIC ===
    log "🔍 DEBUG: Sauvegarde contexte avant appel Claude Code"
    echo "$TECH_LEAD_PROMPT" > "$WORK_DIR/temp/prompt-sent-$epic_number.txt"
    echo "$EPIC_DATA" > "$WORK_DIR/temp/epic-data-$epic_number.json" 
    env | grep -E "(GITHUB|PATH)" > "$WORK_DIR/temp/environment-$epic_number.txt"
    log "🔍 DEBUG: Prompt length: $(echo "$TECH_LEAD_PROMPT" | wc -c) characters"
    
    # Charger le business context et le sauvegarder dans un fichier
    log "🔍 DEBUG: Création system prompt simplifié avec MCP"
    
    # Créer un system prompt SIMPLIFIÉ utilisant les MCP directement  
    cat > "$WORK_DIR/temp/system-prompt-$epic_number.txt" << 'EOF'
Tu es le Tech Lead Agent Dulien. Tu analyses les épics et crées les tâches techniques distribuées.

AVANT DE RÉPONDRE, tu DOIS obligatoirement :
1. Utiliser technical_context__get_page_structure pour analyser la page concernée
2. Utiliser technical_context__search_similar_components pour identifier les composants existants
3. Utiliser business_context__search_glossary si nécessaire pour le contexte métier

ℹ️ Tu as accès aux serveurs MCP Dulien pour obtenir dynamiquement le contexte technique et métier.

INSTRUCTIONS CRITIQUES OBLIGATOIRES:

1. **CRÉER UNE SEULE TÂCHE PAR ÉPIC** (pas 4 ou 5 tâches séparées!)
2. **ANALYSER LE CODE EXISTANT** avant de proposer des solutions
3. **RÉUTILISER LES COMPOSANTS EXISTANTS** (AuthInterceptor, EmptyStateComponent, etc.)
4. **BODY DÉTAILLÉ OBLIGATOIRE** avec sous-tâches techniques numérotées

RÈGLES STRICTES:
- Maximum 1-2 tâches dans "tasks_to_create" (idéalement 1 seule)
- Le champ "body" est OBLIGATOIRE et doit contenir :
  - Contexte technique avec fichiers existants à modifier
  - Liste de sous-tâches numérotées (minimum 5-10 sous-tâches)
  - Références précises aux composants/services existants
  - Acceptance criteria techniques

Structure JSON OBLIGATOIRE:
{
  "analysis": "Description technique détaillée de l'épic avec contexte architectural",
  "tasks_to_create": [
    {
      "repo": "webapp",
      "title": "Titre résumant TOUT le besoin fonctionnel", 
      "agent": "webapp",
      "body": "## 🎯 Objectif\n[Description du besoin]\n\n## 📝 Contexte technique\n[Composants existants, architecture]\n\n## ✅ Sous-tâches à réaliser\n\n- [ ] 1. [Première sous-tâche avec fichier spécifique]\n- [ ] 2. [Deuxième sous-tâche]\n- [ ] 3. [Troisième sous-tâche]\n[...minimum 5-10 sous-tâches...]\n\n## 📁 Fichiers à modifier\n- `path/to/file1.ts` : [description]\n- `path/to/file2.ts` : [description]\n\n## 🔍 Acceptance Criteria\n- [Critère 1]\n- [Critère 2]\n\n## ⚠️ Points d'attention\n[Risques, dépendances, etc.]"
    }
  ],
  "workflow": [
    {
      "task_id": "webapp-TBD",
      "depends_on": [],
      "priority": 1
    }
  ]
}

RÉPONDS UNIQUEMENT AVEC CE JSON, RIEN D'AUTRE.
EOF
    
    # Sauvegarder le prompt dans un fichier pour éviter les problèmes d'échappement
    echo "$TECH_LEAD_PROMPT" > "$WORK_DIR/temp/prompt-sent-$epic_number.txt"
    
    # Validation du prompt envoyé
    if grep -q "CRÉER UNE SEULE TÂCHE PAR ÉPIC" "$WORK_DIR/temp/system-prompt-$epic_number.txt"; then
        log "✅ Validation: Instructions '1 tâche par épic' présentes dans le prompt"
    else
        log "❌ ERREUR: Instructions '1 tâche par épic' MANQUANTES dans le prompt!"
        echo "PROMPT_VALIDATION_FAILED: Missing task limit instruction" >> "$WORK_DIR/temp/validation-error.txt"
    fi
    
    # Créer un script temporaire avec syntaxe Claude Code correcte
    cat > "$WORK_DIR/temp/claude-cmd-$epic_number.sh" << 'EOF'
#!/bin/bash
WORK_DIR="/home/florian/projets/dulien-orchestration"
EPIC_NUM="1"

# Combiner system prompt et user prompt
COMBINED_PROMPT="$(cat "$WORK_DIR/temp/system-prompt-$EPIC_NUM.txt")

$(cat "$WORK_DIR/temp/prompt-sent-$EPIC_NUM.txt")"

# Utiliser la syntaxe Claude Code correcte AVEC MCP et bypass permissions
claude "$COMBINED_PROMPT" -p --output-format "json" --permission-mode "bypassPermissions"
EOF
    
    # Remplacer le numéro d'épic dynamiquement
    sed -i "s/EPIC_NUM=\"1\"/EPIC_NUM=\"$epic_number\"/g" "$WORK_DIR/temp/claude-cmd-$epic_number.sh"
    chmod +x "$WORK_DIR/temp/claude-cmd-$epic_number.sh"
    
    # Exécuter Tech Lead Agent via script temporaire
    log "🔍 DEBUG: Démarrage appel Claude Code avec business context intégré (timeout 60s)"
    TECH_LEAD_RESULT=$(timeout 60 "$WORK_DIR/temp/claude-cmd-$epic_number.sh" 2> "$WORK_DIR/temp/claude-error-$epic_number.log" \
        || {
            echo "CLAUDE_TIMEOUT_OR_FAILED" > "$WORK_DIR/temp/claude-status-$epic_number.txt"
            echo "Exit code: $?" >> "$WORK_DIR/temp/claude-status-$epic_number.txt"
            echo "Timestamp: $(date)" >> "$WORK_DIR/temp/claude-status-$epic_number.txt"
            log "❌ Claude Code timeout/échec pour épic #$epic_number - voir temp/claude-error-$epic_number.log"
            echo "EXECUTION_ERROR"
        })
    
    # Sauvegarde et analyse du résultat
    echo "$TECH_LEAD_RESULT" > "$WORK_DIR/temp/claude-result-$epic_number.txt"
    log "🔍 DEBUG: Claude result length: $(echo "$TECH_LEAD_RESULT" | wc -c) characters"
    log "🔍 DEBUG: Claude result preview: $(echo "$TECH_LEAD_RESULT" | head -c 100)..."
    
    # Diagnostic automatique si erreur détectée
    if [ "$TECH_LEAD_RESULT" = "Execution error" ] || [ "$TECH_LEAD_RESULT" = "EXECUTION_ERROR" ]; then
        log "🔍 DIAGNOSTIC: Execution error détectée - démarrage tests en cascade"
        echo "EXECUTION_ERROR_DETECTED" > "$WORK_DIR/temp/diagnosis-$epic_number.txt"
        echo "Prompt length: $(echo "$TECH_LEAD_PROMPT" | wc -c)" >> "$WORK_DIR/temp/diagnosis-$epic_number.txt"
        echo "MCP config: $AGENTS_DIR/tech-lead.json" >> "$WORK_DIR/temp/diagnosis-$epic_number.txt"
        ls -la "$AGENTS_DIR/tech-lead.json" >> "$WORK_DIR/temp/diagnosis-$epic_number.txt"
        
        # Démarrer tests en cascade
        run_diagnostic_cascade "$epic_number" "$TECH_LEAD_PROMPT"
    fi
    
    log "📄 Résultat analyse Tech Lead reçu"
    
    # Extraire le JSON du résultat avec fallbacks robustes
    if WORKFLOW_JSON=$(extract_json "$TECH_LEAD_RESULT"); then
        # Créer les issues GitHub réellement
        UPDATED_JSON_RAW=$(create_github_issues "$WORKFLOW_JSON")
        
        # Extraire uniquement le JSON final (après les logs)
        UPDATED_JSON=$(echo "$UPDATED_JSON_RAW" | awk '/^{/ {p=1} p {print}')
        
        # Ajouter au workflow global avec les vrais numéros d'issues
        add_to_workflow "$epic_number" "$UPDATED_JSON"
        
        # Marquer épic comme analysée (commentaire au lieu de label inexistant)
        log "✅ Épic #$epic_number marquée comme analysée"
        
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

# === DIAGNOSTIC CASCADE ===

run_diagnostic_cascade() {
    local epic_number="$1"
    local prompt="$2"
    
    log "🔍 DIAGNOSTIC CASCADE: Test Business Context MCP seul"
    
    # Créer config Business Context seulement
    cat > "$WORK_DIR/temp/business-only.json" << EOF
{
  "mcpServers": {
    "business-context": {
      "command": "node",
      "args": ["/home/florian/projets/business-context-mcp/dist/index.js"]
    }
  }
}
EOF
    
    # Test 1: Business Context MCP seulement (avec timeout 30s)
    local business_result=$(timeout 30 bash -c "echo '$prompt' | GITHUB_TOKEN='$GITHUB_TOKEN' claude --print --permission-mode "bypassPermissions" \
        --mcp-config '$WORK_DIR/temp/business-only.json' \
        --allowed-tools 'business_context__*' \
        2> '$WORK_DIR/temp/business-only-error-$epic_number.log'" \
        || echo "BUSINESS_MCP_TIMEOUT")
    
    echo "$business_result" > "$WORK_DIR/temp/business-only-result-$epic_number.txt"
    log "🔍 DIAGNOSTIC: Business Context result length: $(echo "$business_result" | wc -c)"
    
    # Test 2: Sans MCP du tout
    log "🔍 DIAGNOSTIC CASCADE: Test sans MCP"
    local no_mcp_result=$(echo "$prompt" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print --permission-mode "bypassPermissions" \
        2> "$WORK_DIR/temp/no-mcp-error-$epic_number.log" \
        || echo "NO_MCP_FAILED")
    
    echo "$no_mcp_result" > "$WORK_DIR/temp/no-mcp-result-$epic_number.txt"
    log "🔍 DIAGNOSTIC: Sans MCP result length: $(echo "$no_mcp_result" | wc -c)"
    
    # Test 3: Vérifier les serveurs MCP
    log "🔍 DIAGNOSTIC CASCADE: Test des serveurs MCP"
    echo "=== MCP SERVER TESTS ===" > "$WORK_DIR/temp/mcp-server-test-$epic_number.txt"
    
    # Test Business Context MCP accessibility
    timeout 3 node /home/florian/projets/business-context-mcp/dist/index.js > "$WORK_DIR/temp/business-mcp-test.txt" 2>&1 &
    local mcp_pid=$!
    sleep 1
    if kill -0 $mcp_pid 2>/dev/null; then
        echo "✅ Business Context MCP server démarre correctement" >> "$WORK_DIR/temp/mcp-server-test-$epic_number.txt"
        kill $mcp_pid 2>/dev/null
    else
        echo "❌ Business Context MCP server failed to start" >> "$WORK_DIR/temp/mcp-server-test-$epic_number.txt"
    fi
    
    # Test GitHub MCP
    echo "Testing GitHub MCP..." >> "$WORK_DIR/temp/mcp-server-test-$epic_number.txt"
    timeout 3 npx -y @modelcontextprotocol/server-github > "$WORK_DIR/temp/github-mcp-test.txt" 2>&1 &
    local github_mcp_pid=$!
    sleep 1
    if kill -0 $github_mcp_pid 2>/dev/null; then
        echo "✅ GitHub MCP server accessible" >> "$WORK_DIR/temp/mcp-server-test-$epic_number.txt"
        kill $github_mcp_pid 2>/dev/null
    else
        echo "❌ GitHub MCP server inaccessible" >> "$WORK_DIR/temp/mcp-server-test-$epic_number.txt"
    fi
    
    # Générer rapport consolidé
    generate_error_report "$epic_number" "$business_result" "$no_mcp_result"
    
    log "📊 DIAGNOSTIC TERMINÉ: Voir temp/diagnostic-report-$epic_number.md"
}

generate_error_report() {
    local epic_number="$1"
    local business_result="$2" 
    local no_mcp_result="$3"
    local report_file="$WORK_DIR/temp/diagnostic-report-$epic_number.md"
    
    cat > "$report_file" << EOF
# Rapport de Diagnostic Épic #$epic_number

**Date:** $(date)
**Épic:** #$epic_number

## 📊 Résumé des Tests

| Test | Résultat | Status |
|------|----------|--------|
| MCP Complet | $([ -f "$WORK_DIR/temp/claude-error-$epic_number.log" ] && echo "❌ ÉCHEC" || echo "⚠️ INCONNU") | Voir claude-error-$epic_number.log |
| Business Context | $(echo "$business_result" | head -c 20)... | $([ "$business_result" = "BUSINESS_MCP_FAILED" ] && echo "❌ ÉCHEC" || echo "✅ OK") |
| Sans MCP | $(echo "$no_mcp_result" | head -c 20)... | $([ "$no_mcp_result" = "NO_MCP_FAILED" ] && echo "❌ ÉCHEC" || echo "✅ OK") |

## 🔍 Logs d'Erreur

### Claude Code MCP Complet
\`\`\`
$(cat "$WORK_DIR/temp/claude-error-$epic_number.log" 2>/dev/null || echo "Pas d'erreur capturée")
\`\`\`

### Business Context MCP  
\`\`\`
$(cat "$WORK_DIR/temp/business-only-error-$epic_number.log" 2>/dev/null || echo "Pas d'erreur")
\`\`\`

### Sans MCP
\`\`\`
$(cat "$WORK_DIR/temp/no-mcp-error-$epic_number.log" 2>/dev/null || echo "Pas d'erreur")
\`\`\`

## 🔧 Serveurs MCP
\`\`\`
$(cat "$WORK_DIR/temp/mcp-server-test-$epic_number.txt" 2>/dev/null || echo "Tests serveurs non disponibles")
\`\`\`

## 📁 Fichiers Générés
- prompt-sent-$epic_number.txt
- epic-data-$epic_number.json
- environment-$epic_number.txt
- claude-result-$epic_number.txt
- business-only-result-$epic_number.txt  
- no-mcp-result-$epic_number.txt

## 🎯 Recommandations

$(if [ "$business_result" != "BUSINESS_MCP_FAILED" ] && [ "$business_result" != "Execution error" ]; then
    echo "✅ **Business Context MCP fonctionne** - Utiliser cette config"
elif [ "$no_mcp_result" != "NO_MCP_FAILED" ] && [ "$no_mcp_result" != "Execution error" ]; then
    echo "⚠️ **Fallback Sans MCP requis** - MCP servers défaillants"
else
    echo "❌ **Problème critique Claude Code** - Investigation approfondie requise"
fi)
EOF

    log "📋 Rapport diagnostic généré: $report_file"
}

# === GESTION WORKFLOW ===

create_github_issues() {
    local workflow_json="$1"
    local updated_json="$workflow_json"
    
    # Obtenir token GitHub
    local github_token=$(get_github_token)
    if [ -z "$github_token" ]; then
        log "❌ Token GitHub indisponible - utilisation numéros fictifs"
        echo "$workflow_json" | jq '
            if .tasks_to_create then
                .tasks_created = (.tasks_to_create | map({repo: .repo, issue_number: 999, title: .title, agent: .agent})) |
                .workflow = (.workflow | map(.task_id |= gsub("-TBD"; "-999"))) |
                del(.tasks_to_create)
            else . end'
        return 0
    fi
    
    # Compter les tâches à créer
    local task_count=$(echo "$workflow_json" | jq '.tasks_to_create | length // 0')
    
    if [ "$task_count" -eq 0 ]; then
        log "🔧 Aucune tâche à créer"
        echo "$updated_json"
        return 0
    fi
    
    # ⚠️ VALIDATION STRICTE : Refuser plus de 2 tâches par épic
    if [ "$task_count" -gt 2 ]; then
        log "❌ ERREUR: Tech Lead Agent a créé $task_count tâches (>2) - VIOLATION des consignes!"
        log "❌ Refus de création des issues - Tech Lead doit respecter '1 tâche par épic'"
        
        # Sauvegarder l'erreur pour diagnostic
        echo "VALIDATION_FAILED: $task_count tasks > 2 limit" > "$WORK_DIR/temp/validation-error.txt"
        echo "Timestamp: $(date)" >> "$WORK_DIR/temp/validation-error.txt"
        echo "$workflow_json" > "$WORK_DIR/temp/rejected-workflow.json"
        
        # Retourner le JSON original sans créer les issues
        echo "$updated_json"
        return 1
    fi
    
    # Vérifier que chaque tâche a un body détaillé
    for i in $(seq 0 $((task_count-1))); do
        local body_content=$(echo "$workflow_json" | jq -r ".tasks_to_create[$i].body // \"\"")
        if [ -z "$body_content" ] || [ "$body_content" = "null" ] || [ ${#body_content} -lt 100 ]; then
            log "❌ ERREUR: Tâche #$i sans body détaillé (${#body_content} caractères < 100)"
            echo "BODY_VALIDATION_FAILED: Task $i missing detailed body" >> "$WORK_DIR/temp/validation-error.txt"
            echo "$updated_json"
            return 1
        fi
    done
    
    log "🔧 Validation OK: $task_count tâches avec body détaillé - Création des issues GitHub..."
    
    # Utiliser un fichier temporaire pour éviter le bug sous-shell
    local temp_file="/tmp/issues-created-$$.json"
    echo '[]' > "$temp_file"
    
    # Traiter chaque tâche individuellement
    for i in $(seq 0 $((task_count-1))); do
        local task=$(echo "$workflow_json" | jq -c ".tasks_to_create[$i]")
        local repo=$(echo "$task" | jq -r '.repo')
        local title=$(echo "$task" | jq -r '.title')
        local agent=$(echo "$task" | jq -r '.agent')
        
        log "🔧 Création issue: $title dans $repo"
        
        # Récupérer le body détaillé si présent
        local body_content=$(echo "$task" | jq -r '.body // ""')
        
        # Si pas de body détaillé, utiliser le template par défaut
        if [ -z "$body_content" ] || [ "$body_content" = "null" ]; then
            body_content="**Tâche créée automatiquement par Tech Lead Agent**

Cette tâche fait partie du workflow orchestré Dulien.

**Agent assigné**: $agent
**Repo**: $repo

---
*Généré automatiquement par l'orchestrateur Dulien*"
        else
            # Ajouter l'en-tête et le pied de page au body détaillé
            body_content="**Tâche créée automatiquement par Tech Lead Agent**

Cette tâche fait partie du workflow orchestré Dulien.

**Agent assigné**: $agent
**Repo**: $repo

## 📋 Description détaillée

$body_content

---
*Généré automatiquement par l'orchestrateur Dulien*"
        fi
        
        # Créer l'issue dans GitHub
        local issue_url=$(GITHUB_TOKEN="$github_token" gh issue create \
            --repo "mentorize-app/$repo" \
            --title "$title" \
            --body "$body_content" \
            --label "agent:$agent" \
            2>/dev/null)
        
        if [ -n "$issue_url" ]; then
            local issue_number=$(echo "$issue_url" | grep -o '[0-9]*$')
            log "✅ Issue #$issue_number créée dans $repo"
            
            # Ajouter au fichier temporaire
            jq --argjson task "{\"repo\": \"$repo\", \"issue_number\": $issue_number, \"title\": \"$title\", \"agent\": \"$agent\"}" \
                '. += [$task]' "$temp_file" > "$temp_file.tmp"
            mv "$temp_file.tmp" "$temp_file"
        else
            log "❌ Échec création issue: $title dans $repo - utilisation numéro fictif"
            jq --argjson task "{\"repo\": \"$repo\", \"issue_number\": 999, \"title\": \"$title\", \"agent\": \"$agent\"}" \
                '. += [$task]' "$temp_file" > "$temp_file.tmp"
            mv "$temp_file.tmp" "$temp_file"
        fi
    done
    
    # Construire le JSON final
    local tasks_created=$(cat "$temp_file")
    rm -f "$temp_file" "$temp_file.tmp"
    
    # Créer le JSON de sortie simplifié - logique JQ complexe buggée
    # Remplacer TBD par les vrais numéros dans une approche plus simple
    updated_json="$workflow_json"
    
    # Pour chaque tâche créée, remplacer les TBD par les vrais numéros
    while IFS= read -r task_line; do
        local repo=$(echo "$task_line" | jq -r '.repo')
        local issue_num=$(echo "$task_line" | jq -r '.issue_number')
        
        # Remplacer dans updated_json tous les "repo-TBD" par "repo-issue_num"
        updated_json=$(echo "$updated_json" | sed "s/${repo}-TBD/${repo}-${issue_num}/g")
    done < <(echo "$tasks_created" | jq -c '.[]')
    
    # Créer le JSON final simplement
    echo "{
        \"analysis\": $(echo "$workflow_json" | jq -r '.analysis // empty' | jq -R .),
        \"workflow\": $(echo "$updated_json" | jq '.workflow // []'),
        \"tasks_created\": $tasks_created
    }"
}

add_to_workflow() {
    local epic_number="$1"
    local workflow_json="$2"
    
    # Debug: vérifier le JSON reçu
    if ! echo "$workflow_json" | jq . >/dev/null 2>&1; then
        log "❌ JSON invalide reçu pour épic #$epic_number"
        echo "$workflow_json" > "$WORK_DIR/temp/invalid-json-$epic_number.txt"
        return 1
    fi
    
    # Créer workflow.json s'il n'existe pas
    if [ ! -f "$WORKFLOW_FILE" ]; then
        echo '{"epics": {}}' > "$WORKFLOW_FILE"
    fi
    
    # Ajouter l'épic au workflow
    if jq --arg epic "$epic_number" --argjson workflow "$workflow_json" \
        '.epics[$epic] = $workflow' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp"; then
        mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"
        log "📝 Workflow mis à jour pour épic #$epic_number"
    else
        log "❌ Erreur JQ lors de la mise à jour workflow pour épic #$epic_number"
        return 1
    fi
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

execute_mention_tasks() {
    if [ ! -f "$WORKFLOW_FILE" ]; then
        return 0
    fi
    
    log "💬 Vérification tâches mention en attente..."
    
    # Chercher tâches mention prêtes à exécuter
    MENTION_TASKS=$(jq -r '
        .epics | to_entries | .[] | 
        .value.tasks_created[] as $task |
        .value.workflow[] | 
        select(.task_id == ($task.repo + "-" + ($task.issue_number | tostring))) |
        select(.status == "mention_triggered") |
        {task_id: .task_id, repo: $task.repo, issue: $task.issue_number, agent: $task.agent}
    ' "$WORKFLOW_FILE")
    
    if [ -z "$MENTION_TASKS" ]; then
        return 0
    fi
    
    echo "$MENTION_TASKS" | jq -c '.' | while read -r task; do
        TASK_ID=$(echo "$task" | jq -r '.task_id')
        REPO=$(echo "$task" | jq -r '.repo') 
        ISSUE=$(echo "$task" | jq -r '.issue')
        AGENT=$(echo "$task" | jq -r '.agent')
        
        log "🚀 Exécution tâche mention $TASK_ID"
        
        # Récupérer détails de la tâche depuis GitHub
        TASK_DATA=$(gh issue view "$ISSUE" --repo "mentorize-app/$REPO" --json title,body 2>/dev/null)
        
        if [ -n "$TASK_DATA" ]; then
            case "$AGENT" in
                "webapp")
                    execute_webapp_agent "$REPO" "$ISSUE" "$TASK_DATA" "$TASK_ID"
                    ;;
                "tenant-api")
                    execute_tenant_api_agent "$REPO" "$ISSUE" "$TASK_DATA" "$TASK_ID"
                    ;;
                "referencial")
                    execute_referencial_agent "$REPO" "$ISSUE" "$TASK_DATA" "$TASK_ID"
                    ;;
                "infrastructure")
                    execute_infrastructure_agent "$REPO" "$ISSUE" "$TASK_DATA" "$TASK_ID"
                    ;;
                "mail-server")
                    execute_mail_server_agent "$REPO" "$ISSUE" "$TASK_DATA" "$TASK_ID"
                    ;;
                "landing-page")
                    execute_landing_page_agent "$REPO" "$ISSUE" "$TASK_DATA" "$TASK_ID"
                    ;;
                *)
                    log "⚠️ Agent mention $AGENT non supporté pour exécution"
                    ;;
            esac
        fi
    done
}

execute_pending_tasks() {
    if [ ! -f "$WORKFLOW_FILE" ]; then
        return 0
    fi
    
    log "⚙️ Vérification tâches en attente..."
    
    # Chercher tâches prêtes à exécuter (statut pending uniquement)
    READY_TASKS=$(jq -r '
        . as $root |
        .epics | to_entries | .[] | 
        .value.tasks_created[] as $task |
        .value.workflow[] | 
        select(.task_id == ($task.repo + "-" + ($task.issue_number | tostring))) |
        select((.status // "pending") == "pending") |
        select((.depends_on // []) | length == 0 or 
               all(. as $dep | $dep | . as $dep_id | 
                   ($root.epics | .. | objects | select(.task_id? == $dep_id) | .status? == "completed"))) |
        {task_id: .task_id, repo: $task.repo, issue: $task.issue_number, agent: $task.agent, epic: (.key | tostring)}
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

    # Récupérer le token GitHub App
    local github_token=$(get_github_token)
    if [ -z "$github_token" ]; then
        log "❌ Impossible de récupérer token GitHub App"
        return 1
    fi
    
    # Exécuter Webapp Agent avec token GitHub App
    WEBAPP_RESULT=$(echo "$WEBAPP_PROMPT" | GITHUB_TOKEN="$github_token" claude --print --permission-mode "bypassPermissions" \
        \
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
    API_RESULT=$(echo "$API_PROMPT" | claude --print --permission-mode "bypassPermissions" \
        \
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
        export GITHUB_TOKEN=$(get_github_token)
    fi

    # Exécuter Security Agent
    SECURITY_RESULT=$(echo "$SECURITY_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print --permission-mode "bypassPermissions" \
        \
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

    MAIL_RESULT=$(echo "$MAIL_PROMPT" | claude --print --permission-mode "bypassPermissions" \
        \
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

    LANDING_RESULT=$(echo "$LANDING_PROMPT" | claude --print --permission-mode "bypassPermissions" \
        \
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

    INFRA_RESULT=$(echo "$INFRA_PROMPT" | claude --print --permission-mode "bypassPermissions" \
        \
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
        export GITHUB_TOKEN=$(get_github_token)
    fi
    
    SECURITY_RESULT=$(echo "$SECURITY_REVIEW_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print --permission-mode "bypassPermissions" \
        \
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
        export GITHUB_TOKEN=$(get_github_token)
    fi
    
    TECH_LEAD_RESULT=$(echo "$TECH_LEAD_REVIEW_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print --permission-mode "bypassPermissions" \
        \
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
    RGAA_RESULT=$(echo "$RGAA_REVIEW_PROMPT" | GITHUB_TOKEN="$GITHUB_TOKEN" claude --print --permission-mode "bypassPermissions" \
        \
        --append-system-prompt "Tu es le RGAA Agent automatique spécialisé accessibilité. Tu postes des reviews RGAA sur les PRs." \
        --add-dir "/home/florian/projets/$repo" \
        --allowed-tools "Read,Bash")
    
    log "♿ RGAA review terminée pour PR #$pr_number"  
    echo "$RGAA_RESULT" >> "$WORK_DIR/logs/rgaa-reviews.log"
}

# === SYSTÈME DE MENTIONS INTERACTIVES ===

# Mapping agents vers repositories
declare -A AGENT_REPOS=(
    ["webapp"]="webapp"
    ["tenant-api"]="tenant-specific-api" 
    ["referencial"]="referencial"
    ["infrastructure"]="infrastructure"
    ["mail-server"]="mail-server"
    ["landing-page"]="landing-page"
    ["security"]="webapp"  # Reviews postées sur webapp mais peuvent créer tâches ailleurs
    ["tech-lead"]="webapp"
    ["rgaa"]="webapp"
)

check_pr_mentions() {
    log "💬 Vérification mentions dans commentaires PR..."
    
    # Lock file pour éviter l'exécution concurrente  
    local LOCK_FILE="$WORK_DIR/mentions.lock"
    
    # Vérifier si un autre processus traite déjà les mentions
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log "⚠️ Un autre processus traite déjà les mentions (PID: $lock_pid)"
            return 0
        else
            log "🗑️ Suppression lock file obsolète"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Créer lock file avec notre PID
    echo $$ > "$LOCK_FILE"
    
    # Fonction de nettoyage appelée à la sortie
    cleanup_mentions_lock() {
        rm -f "$LOCK_FILE"
        log "🔓 Lock file mentions supprimé"
    }
    trap cleanup_mentions_lock EXIT INT TERM
    
    # Cache des mentions traitées pour éviter les doublons
    local PROCESSED_MENTIONS_FILE="$WORK_DIR/logs/processed-mentions.log"
    touch "$PROCESSED_MENTIONS_FILE"
    
    # Scanner toutes les PRs ouvertes sur tous les repos
    for agent in "${!AGENT_REPOS[@]}"; do
        local repo="${AGENT_REPOS[$agent]}"
        
        # Récupérer PRs ouvertes pour ce repo
        local open_prs=$(gh pr list --repo mentorize-app/$repo --state open --json number,title 2>/dev/null || echo "[]")
        
        if [ "$open_prs" != "[]" ]; then
            echo "$open_prs" | jq -c '.[]' | while read -r pr; do
                local pr_number=$(echo "$pr" | jq -r '.number')
                local pr_title=$(echo "$pr" | jq -r '.title')
                
                log "🔍 Scan mentions PR mentorize-app/$repo #$pr_number"
                
                # Récupérer commentaires de la PR
                local pr_comments=$(gh pr view $pr_number --repo mentorize-app/$repo --comments 2>/dev/null || echo "")
                
                if [ -n "$pr_comments" ]; then
                    # Filtrer les commentaires de bots et ne traiter que ceux des humains
                    echo "$pr_comments" | grep -v "Dulien Orchestrator\[bot\]" | grep -v "🤖.*Dulien" | while IFS= read -r line; do
                        # Détecter mentions uniquement des commentaires humains
                        if echo "$line" | grep -Eq "@(webapp|tenant-api|referencial|infrastructure|mail-server|landing-page|tech-lead)"; then
                            # Extraire la mention avec son contexte
                            local mention=$(echo "$line" | grep -Eo "@(webapp|tenant-api|referencial|infrastructure|mail-server|landing-page|tech-lead)[^@]*")
                            if [ -n "$mention" ]; then
                                # Vérifier si déjà traité (simple déduplication)
                                local mention_hash=$(echo "$mention$repo$pr_number" | md5sum | cut -d' ' -f1)
                                if ! grep -q "$mention_hash" "$PROCESSED_MENTIONS_FILE" 2>/dev/null; then
                                    echo "$mention_hash" >> "$PROCESSED_MENTIONS_FILE"
                                    process_mention "$mention" "$repo" "$pr_number" "$pr_title"
                                fi
                            fi
                        fi
                    done
                fi
            done
        fi
    done
}

process_mention() {
    local mention="$1"
    local source_repo="$2"  
    local source_pr="$3"
    local pr_title="$4"
    
    # Parser la mention: @agent action description
    local mentioned_agent=$(echo "$mention" | grep -Eo "@[a-z-]+" | sed 's/@//')
    local action_text=$(echo "$mention" | sed 's/@[a-z-]+\s*//')
    
    log "💬 Mention détectée: @$mentioned_agent → '$action_text'"
    
    # Logique révisée: Correction PR vs Nouvelle Tâche
    if [ "$mentioned_agent" = "tech-lead" ]; then
        # @tech-lead = création nouvelle tâche
        log "🎯 Tech Lead: création nouvelle tâche"
        create_new_task_from_tech_lead "$action_text" "$source_repo" "$source_pr" "$pr_title"
    else
        # @agent = correction de la PR courante
        log "🔧 Correction PR: demande à @$mentioned_agent"
        request_pr_correction "$mentioned_agent" "$source_repo" "$source_pr" "$action_text"
    fi
}

request_pr_correction() {
    local agent="$1"
    local source_repo="$2" 
    local source_pr="$3"
    local action_text="$4"
    
    log "🔧 Demande correction PR à @$agent"
    
    # Obtenir token GitHub App
    local github_token=$(get_github_token)
    if [ -z "$github_token" ]; then
        log "❌ Impossible de récupérer token GitHub App"
        return 1
    fi
    
    # Commenter sur la PR pour demander correction
    GITHUB_TOKEN="$github_token" gh pr comment "$source_pr" --repo "mentorize-app/$source_repo" --body "🔧 **Demande de Correction**

@$agent, peux-tu corriger cette PR :

**Action demandée:** $action_text

Cette demande concerne la PR actuelle, pas une nouvelle tâche.

---
*Dulien Orchestrator - Demande de correction automatique*" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log "✅ Demande de correction envoyée à @$agent"
    else
        log "❌ Erreur envoi demande correction à @$agent"
    fi
}

create_new_task_from_tech_lead() {
    local action_text="$1"
    local source_repo="$2"
    local source_pr="$3" 
    local pr_title="$4"
    
    log "🎯 Tech Lead: analyse pour création tâche"
    
    # Obtenir token GitHub App
    local github_token=$(get_github_token)
    if [ -z "$github_token" ]; then
        log "❌ Impossible de récupérer token GitHub App"
        return 1
    fi
    
    # Parser le repository cible s'il est spécifié
    local target_repo=""
    if [[ "$action_text" =~ dans[[:space:]]+([a-zA-Z-]+) ]]; then
        target_repo="${BASH_REMATCH[1]}"
        # Mapper noms courts vers noms complets
        case "$target_repo" in
            "tenant-api") target_repo="tenant-specific-api" ;;
            "webapp"|"referencial"|"infrastructure"|"mail-server"|"landing-page") ;;
            *) target_repo="" ;;  # Repo non reconnu
        esac
    fi
    
    # Si pas de repo spécifié ou non reconnu, demander clarification
    if [ -z "$target_repo" ]; then
        GITHUB_TOKEN="$github_token" gh pr comment "$source_pr" --repo "mentorize-app/$source_repo" --body "🤔 **Tech Lead - Clarification Nécessaire**

J'ai reçu la demande : \"$action_text\"

**Question :** Dans quel repository dois-je créer cette tâche ?
- webapp (interface utilisateur Angular)
- tenant-specific-api (API backend tenant)
- referencial (API données partagées)
- infrastructure (DevOps, déploiement)
- mail-server (service messagerie)
- landing-page (pages marketing)

Peux-tu préciser : \`@tech-lead crée une tâche dans [REPO] pour ...\`

---
*Dulien Orchestrator - Tech Lead Agent*" 2>/dev/null
        
        log "❓ Tech Lead demande clarification du repository cible"
        return 0
    fi
    
    # Créer l'issue dans le repository cible
    local issue_title="[TECH-LEAD] $(echo "$action_text" | cut -c1-50)..."
    local issue_body="🎯 **Tâche créée par Tech Lead**

**Demande originale:** $action_text

**Contexte:**
- Demandée depuis PR mentorize-app/$source_repo #$source_pr
- Titre PR: \"$pr_title\"
- Analysée et routée par Tech Lead

**Instructions:**
$action_text

---
*Tâche créée automatiquement par Tech Lead Agent Dulien*"

    # Créer l'issue GitHub
    local new_issue=$(GITHUB_TOKEN="$github_token" gh issue create \
        --repo "mentorize-app/$target_repo" \
        --title "$issue_title" \
        --body "$issue_body" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        log "✅ Tâche créée par Tech Lead: $new_issue"
        
        # Confirmer sur la PR source
        GITHUB_TOKEN="$github_token" gh pr comment "$source_pr" --repo "mentorize-app/$source_repo" --body "🎯 **Tech Lead - Tâche Créée**

✅ Nouvelle tâche créée: $new_issue
📂 Repository: mentorize-app/$target_repo
🤖 Sera traitée par l'agent approprié dans le prochain cycle

**Action:** $action_text

---
*Tech Lead Agent - Création de tâche automatique*" 2>/dev/null
        
        # Ajouter au workflow
        add_tech_lead_task_to_workflow "$target_repo" "$new_issue" "$source_repo" "$source_pr" "$action_text"
    else
        log "❌ Erreur création tâche Tech Lead"
        
        # Signaler l'erreur
        GITHUB_TOKEN="$github_token" gh pr comment "$source_pr" --repo "mentorize-app/$source_repo" --body "❌ **Tech Lead - Erreur**

Impossible de créer la tâche dans mentorize-app/$target_repo.

Vérifiez:
- Les permissions du bot sur ce repository
- Que le repository existe
- La syntaxe de la demande

---
*Tech Lead Agent - Erreur création tâche*" 2>/dev/null
    fi
}

add_tech_lead_task_to_workflow() {
    local target_repo="$1"
    local issue_url="$2"
    local source_repo="$3"
    local source_pr="$4" 
    local action_text="$5"
    
    # Extraire numéro d'issue de l'URL  
    local issue_number=$(echo "$issue_url" | grep -Eo '[0-9]+$')
    
    # Créer entrée workflow pour tâche Tech Lead
    local epic_id="tech-lead-$(date +%s)"
    
    if [ -f "$WORKFLOW_FILE" ]; then
        # Déterminer agent approprié selon le repo
        local agent=""
        case "$target_repo" in
            "webapp") agent="webapp" ;;
            "tenant-specific-api") agent="tenant-api" ;;
            "referencial") agent="referencial" ;;
            "infrastructure") agent="infrastructure" ;;
            "mail-server") agent="mail-server" ;;
            "landing-page") agent="landing-page" ;;
            *) agent="unknown" ;;
        esac
        
        # Ajouter à workflow
        jq --arg epic_id "$epic_id" \
           --arg analysis "Tâche créée par Tech Lead depuis PR $source_repo #$source_pr: $action_text" \
           --arg repo "$target_repo" \
           --arg issue "$issue_number" \
           --arg title "Tech Lead: $action_text" \
           --arg agent "$agent" \
           '.epics[$epic_id] = {
               "analysis": $analysis,
               "tasks_created": [{
                   "repo": $repo,
                   "issue_number": ($issue | tonumber),
                   "title": $title,
                   "agent": $agent
               }],
               "workflow": [{
                   "task_id": ($repo + "-" + $issue),
                   "depends_on": [],
                   "priority": 1,
                   "status": "pending"
               }]
           }' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp"
        mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"
        
        log "📝 Tâche Tech Lead ajoutée au workflow: $epic_id"
    fi
}

create_mention_task() {
    local agent="$1"
    local target_repo="$2" 
    local action_text="$3"
    local source_repo="$4"
    local source_pr="$5"
    local pr_title="$6"
    
    log "🎯 Création tâche mention: @$agent dans $target_repo"
    
    # Générer template selon l'agent
    local task_template
    case "$agent" in
        "webapp")
            task_template="[WEBAPP-MENTION] Interface utilisateur Angular"
            ;;
        "tenant-api")
            task_template="[API-MENTION] Backend tenant et business logic"
            ;;
        "referencial")
            task_template="[REF-MENTION] API référentiel données partagées"
            ;;
        "infrastructure")
            task_template="[INFRA-MENTION] DevOps et infrastructure"
            ;;
        "mail-server")
            task_template="[MAIL-MENTION] Service messagerie et notifications"
            ;;
        "landing-page")
            task_template="[LANDING-MENTION] Pages marketing et SEO"
            ;;
        "security"|"tech-lead"|"rgaa")
            task_template="[REVIEW-MENTION] Suivi de recommandation review"
            ;;
    esac
    
    # Corps de l'issue avec référence
    local issue_body="🎯 **Tâche créée par mention interactive**

**Action demandée:** $action_text

**Contexte:**
- Mentionné dans PR mentorize-app/$source_repo #$source_pr
- Titre PR: \"$pr_title\"
- Agent cible: @$agent

**Instructions:**
$action_text

---
*Tâche générée automatiquement par système de mentions Dulien*
*Agent assigné: @$agent*"

    # Créer l'issue GitHub
    local new_issue=$(gh issue create \
        --repo "mentorize-app/$target_repo" \
        --title "$task_template: ${action_text:0:50}..." \
        --body "$issue_body" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        log "✅ Issue créée: $new_issue"
        
        # Ajouter au workflow JSON
        add_mention_to_workflow "$agent" "$target_repo" "$new_issue" "$source_repo" "$source_pr"
        
        # Commenter sur la PR source pour confirmer
        gh pr comment "$source_pr" --repo "mentorize-app/$source_repo" --body "🤖 **Mention Traitée**

✅ Tâche créée automatiquement: $new_issue
🎯 Agent: @$agent 
📂 Repository: mentorize-app/$target_repo

La tâche sera traitée dans le prochain cycle de l'orchestrateur.

*Système de mentions interactives Dulien*" 2>/dev/null
    else
        log "❌ Erreur création issue pour mention @$agent"
    fi
}

add_mention_to_workflow() {
    local agent="$1"
    local target_repo="$2"
    local issue_url="$3"
    local source_repo="$4"
    local source_pr="$5"
    
    # Extraire numéro d'issue de l'URL  
    local issue_number=$(echo "$issue_url" | grep -Eo '[0-9]+$')
    
    # Créer entrée workflow pour mention
    local epic_id="mention-$(date +%s)"
    
    if [ -f "$WORKFLOW_FILE" ]; then
        # Ajouter à workflow existant
        jq --arg epic_id "$epic_id" \
           --arg analysis "Tâche créée par mention @$agent depuis PR $source_repo #$source_pr" \
           --arg repo "$target_repo" \
           --arg issue "$issue_number" \
           --arg title "Mention @$agent: action demandée" \
           --arg agent "$agent" \
           '.epics[$epic_id] = {
               "analysis": $analysis,
               "tasks_created": [{
                   "repo": $repo,
                   "issue_number": ($issue | tonumber),
                   "title": $title,
                   "agent": $agent
               }],
               "workflow": [{
                   "task_id": ($repo + "-" + $issue),
                   "depends_on": [],
                   "priority": 2,
                   "status": "mention_triggered"
               }]
           }' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp"
        mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"
        
        log "📝 Mention ajoutée au workflow: $epic_id"
    fi
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
        "check-mentions")
            check_pr_mentions
            ;;
        "execute-mentions")
            execute_mention_tasks
            ;;
        "full")
            log "🚀 Démarrage cycle complet orchestrateur Dulien"
            check_new_epics
            execute_pending_tasks
            check_pr_mentions
            execute_mention_tasks
            check_prs_for_review
            check_completed_reviews
            log "✅ Cycle terminé"
            ;;
        *)
            echo "Usage: $0 [init|check-epics|execute-tasks|check-prs|check-reviews|check-mentions|execute-mentions|full]"
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