# Instructions Orchestrateur Dulien

## Priorités d'exécution (STRICTES)

1. **PRs ouvertes** (fin du pipeline) → `review_pr`
   - Reviewer le code
   - Vérifier les tests
   - Merger si OK ou demander corrections

2. **Tâches sans label 'processing'** → `implement_task`
   - Ajouter immédiatement le label 'processing'
   - Implémenter avec tests
   - Créer une PR
   - Ajouter label 'status:review-requested'

3. **Épics sans sous-tâches** → `decompose_epic`
   - Créer le MINIMUM de tâches nécessaires (1-3 max)
   - Découper SEULEMENT si justifié : 
     * Repos différents (webapp vs infrastructure)
     * Technologies différentes (frontend vs backend)
     * Équipes différentes
   - Chaque tâche doit être complète : analyse + dev + tests
   - Ne PAS découper par couche technique (pas de tâche "tests" séparée)
   - Labels : agent:webapp ou agent:infrastructure + priority selon l'épic

## Règles d'orchestration

- **Maximum 3 actions en parallèle**
- **Ne jamais traiter 2x la même chose** (vérifier last-actions.json)
- **Toujours marquer 'processing' avant de commencer une tâche**
- **Les tâches avec 'processing' sont en cours, ne pas y toucher**
- **Traiter TOUS les épics ouverts** (peu importe le numéro)
- **Pour les tâches** : Traiter toutes celles avec state=open

## Repos à surveiller

- `mentorize-app/webapp` : Frontend Angular
- `mentorize-app/infrastructure` : Scripts, CI/CD, infra
- `mentorize-app/tenant-api` : Backend API multi-tenant
- `mentorize-app/referential` : Service référentiel

## Labels importants

- `type:epic` : Épic à décomposer
- `agent:webapp` : Tâche pour agent webapp
- `agent:infrastructure` : Tâche pour agent infrastructure
- `agent:tech-lead` : Tâche pour tech lead
- `processing` : Tâche en cours de traitement
- `status:review-requested` : PR créée, en attente review
- `status:completed` : Tâche terminée

## Format des commandes Claude pour les agents

```bash
# Pour implémenter une tâche
claude "Implémente la tâche #XX du repo YY : [titre]
[Instructions spécifiques...]" -p --permission-mode bypassPermissions &

# Pour reviewer une PR
claude "Review et merge la PR #XX du repo YY
Vérifie code, tests et alignement avec la tâche originale" -p --permission-mode bypassPermissions &

# Pour décomposer un épic
claude "Décompose l'épic #XX du repo YY en MINIMUM de tâches (1-3)
Découpe seulement si repos/technologies différents
Chaque tâche = feature complète avec tests
Pas de découpage technique artificiel
Utilise gh CLI pour créer les issues" -p --permission-mode bypassPermissions &
```

## Gestion des erreurs

- Si une action échoue, la logger mais continuer
- Si 'processing' depuis > 2h, retirer le label et retraiter
- Si PR ouverte depuis > 1 jour, relancer review

## Structure last-actions.json

```json
[
  {
    "timestamp": "2025-01-27T16:45:00Z",
    "type": "implement_task",
    "repo": "webapp",
    "number": 61,
    "status": "started"
  }
]
```

Garder maximum 10 entrées, les plus récentes en dernier.