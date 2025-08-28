#!/usr/bin/env python3
"""
Configuration pour l'orchestrateur Dulien avec Mistral et Claude
"""

import os
from pathlib import Path

# Chemins
PROJECT_ROOT = Path(__file__).parent.parent
LOGS_DIR = PROJECT_ROOT / "logs"
CACHE_DIR = PROJECT_ROOT / "cache"

# Créer les dossiers si nécessaire
LOGS_DIR.mkdir(exist_ok=True)
CACHE_DIR.mkdir(exist_ok=True)

# Configuration Mistral
MISTRAL_CONFIG = {
    "model": "mistral:7b",
    "options": {
        "temperature": 0.1,      # Très bas pour décisions déterministes
        "top_p": 0.95,
        "repeat_penalty": 1.1,   # Évite les répétitions
        "seed": 42,              # Reproductibilité
        "num_ctx": 8192,         # Contexte suffisant pour états GitHub
        "num_predict": 1000,     # Limite de génération
        "stop": ["```", "\n\n"]  # Stop sur code blocks ou double newline
    }
}

# Prompts Mistral en français
MISTRAL_PROMPTS = {
    "analyze_state": """Tu es un orchestrateur de tâches GitHub expert.

État actuel du système :
{state}

Règles de priorité STRICTES :
1. TOUJOURS traiter les PRs ouvertes en premier (fin du pipeline)
2. Ensuite les tâches sans label 'processing'
3. En dernier les épics sans sous-tâches

Contraintes :
- Maximum 3 actions en parallèle
- Ne pas traiter deux fois la même tâche
- Les tâches avec label 'processing' sont déjà en cours

Retourne UNIQUEMENT un JSON valide avec cette structure exacte :
{{
  "actions": [
    {{"type": "review_pr", "repo": "webapp", "number": 12, "priority": 1}},
    {{"type": "implement_task", "repo": "webapp", "number": 55, "priority": 2}},
    {{"type": "decompose_epic", "repo": "infrastructure", "number": 5, "priority": 3}}
  ],
  "reasoning": "Brève explication des choix"
}}

Types d'actions possibles :
- review_pr : Reviewer et merger une PR
- implement_task : Implémenter une tâche
- decompose_epic : Décomposer un épic en sous-tâches
- monitor_task : Surveiller une tâche en processing

JSON :""",

    "classify_task": """Classifie cette tâche GitHub.

Tâche : {title}
Description : {body}
Labels : {labels}
État : {state}
A une PR : {has_pr}

Retourne UN SEUL MOT parmi :
- implement : tâche à implémenter (pas de label processing)
- monitor : tâche en cours (a le label processing)
- review : tâche avec PR à reviewer
- skip : tâche à ignorer

Réponse :""",

    "should_create_tasks": """Un épic nécessite-t-il des sous-tâches ?

Épic : {title}
Description : {body}
Créé il y a : {days_ago} jours
Sous-tâches existantes : {subtask_count}

Réponds par OUI ou NON uniquement.

Réponse :"""
}

# Templates de prompts Claude
CLAUDE_PROMPTS = {
    "review_pr": """Review cette Pull Request GitHub.

Repository : {repo}
PR #{pr_number} : {title}

Instructions :
1. Utilise 'gh pr view {pr_number} --repo mentorize-app/{repo}' pour voir les détails
2. Vérifie la qualité du code et l'alignement avec la tâche originale
3. Si tout est correct : approuve avec 'gh pr review {pr_number} --approve' et merge
4. Sinon : demande des corrections avec 'gh pr review {pr_number} --request-changes'

Sois rigoureux mais constructif dans tes commentaires.""",

    "implement_task": """Implémente cette tâche GitHub.

Repository : {repo}
Tâche #{task_number} : {title}

Description :
{body}

Instructions STRICTES :
1. Ajoute IMMÉDIATEMENT le label 'processing' avec 'gh issue edit {task_number} --add-label processing'
2. Analyse le contexte du projet avec les MCP servers disponibles
3. Implémente la solution complète avec tests
4. Crée une PR propre avec description détaillée
5. Ajoute le label 'status:review-requested' à la fin

Important : Utilise les patterns et conventions existants du projet.""",

    "decompose_epic": """Décompose cet épic en tâches techniques concrètes.

Repository : {repo}
Épic #{epic_number} : {title}

Description :
{body}

Instructions :
1. Analyse l'épic et identifie 3-5 tâches atomiques
2. Chaque tâche doit être :
   - Implémentable indépendamment
   - Testable avec critères clairs
   - Estimable (quelques heures à 2 jours max)
3. Crée les issues avec 'gh issue create' en incluant :
   - Titre clair et actionnable
   - Description avec contexte et critères d'acceptation
   - Label 'agent:webapp' ou 'agent:infrastructure' selon le domaine
   - Référence à l'épic parent (#{epic_number})
4. Ordonne les tâches par dépendance logique

Ne crée PAS plus de 5 tâches.""",

    "monitor_task": """Vérifie l'état d'avancement de cette tâche.

Repository : {repo}
Tâche #{task_number} : {title}

Cette tâche est marquée 'processing'. Vérifie :
1. Y a-t-il une PR ouverte liée ?
2. L'agent travaille-t-il toujours dessus ?
3. Y a-t-il des blocages ?

Si la tâche est bloquée depuis plus de 2 heures :
- Retire le label 'processing'
- Ajoute un commentaire expliquant le problème"""
}

# Configuration de l'orchestrateur
ORCHESTRATOR_CONFIG = {
    "loop_interval": 600,        # 10 minutes entre chaque cycle
    "max_parallel_actions": 3,    # Maximum d'actions en parallèle
    "action_timeout": 600,        # Timeout par action (10 min)
    "retry_attempts": 2,          # Tentatives en cas d'échec
    "retry_delay": 30,           # Délai entre tentatives (secondes)
}

# Configuration des logs
LOGGING_CONFIG = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "standard": {
            "format": "[%(asctime)s] %(levelname)s [%(name)s] %(message)s",
            "datefmt": "%Y-%m-%d %H:%M:%S"
        },
        "detailed": {
            "format": "[%(asctime)s] %(levelname)s [%(name)s:%(lineno)d] %(message)s",
            "datefmt": "%Y-%m-%d %H:%M:%S"
        }
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "level": "INFO",
            "formatter": "standard",
            "stream": "ext://sys.stdout"
        },
        "file": {
            "class": "logging.handlers.RotatingFileHandler",
            "level": "DEBUG",
            "formatter": "detailed",
            "filename": str(LOGS_DIR / "orchestrator.log"),
            "maxBytes": 10485760,  # 10MB
            "backupCount": 5
        }
    },
    "loggers": {
        "": {  # Root logger
            "level": "DEBUG",
            "handlers": ["console", "file"]
        }
    }
}

# Organisation GitHub
GITHUB_CONFIG = {
    "org": "mentorize-app",
    "repos": ["webapp", "infrastructure", "tenant-api", "referential"],
    "default_labels": {
        "epic": "type:epic",
        "webapp_agent": "agent:webapp",
        "infra_agent": "agent:infrastructure",
        "techlead_agent": "agent:tech-lead",
        "processing": "processing",
        "review_requested": "status:review-requested",
        "completed": "status:completed"
    }
}

# Filtres pour ignorer certaines tâches
TASK_FILTERS = {
    "ignore_old_tasks_before_number": 50,  # Ignorer les tâches < #50
    "ignore_closed_without_pr_days": 7,     # Ignorer les fermées sans PR depuis X jours
    "max_epic_age_days": 30,               # Ignorer les épics trop vieux
}

# Messages d'erreur et de statut
MESSAGES = {
    "no_actions": "✅ Aucune action nécessaire pour le moment",
    "starting_action": "🚀 Démarrage action : {action_type} sur {repo}#{number}",
    "action_complete": "✅ Action terminée : {action_type} sur {repo}#{number}",
    "action_failed": "❌ Échec action : {action_type} sur {repo}#{number} - {error}",
    "cycle_start": "🔄 Début du cycle d'orchestration",
    "cycle_end": "✅ Fin du cycle d'orchestration"
}