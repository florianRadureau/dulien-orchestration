# 🚀 Orchestrateur Dulien - Système d'Automatisation Multi-Agents

## 🎯 Vue d'Ensemble

Système d'orchestration automatique transformant les épics fonctionnelles en développement multi-repos complet via agents Claude Code spécialisés.

### Architecture

```
Epic GitHub → Tech Lead Agent → Tâches techniques → Agents spécialisés → Code production
```

## 📁 Structure Projet

```
dulien-orchestration/
├── orchestrator-dulien.sh     # Script principal orchestration
├── monitor.sh                 # Dashboard temps réel
├── setup-cron.sh             # Configuration automatisation
├── agents/                    # Configurations MCP par agent
│   ├── tech-lead.json         # Tech Lead + Business Context
│   ├── webapp.json           # Angular + Accessibility MCP
│   ├── tenant-api.json       # NestJS + Business Context  
│   ├── referencial.json      # API référentiel
│   ├── mail-server.json      # Service email Node.js
│   ├── landing-page.json     # Next.js marketing
│   ├── infrastructure.json   # DevOps/Docker
│   └── security.json         # Audits sécurité
├── logs/                     # Logs orchestrateur
│   ├── orchestrator.log      # Log principal
│   └── cron.log             # Logs tâches automatiques
├── temp/                     # Fichiers temporaires debug
└── workflow.json            # État global orchestration
```

## 🔧 Installation & Configuration

### Prérequis

```bash
# Outils requis
- Claude Code CLI
- GitHub CLI (gh)
- jq
- Node.js (pour business-context-mcp)

# Variables d'environnement
export GITHUB_TOKEN="ghp_xxxxx"
```

### Setup Initial

```bash
cd /home/florian/projets/dulien-orchestration

# 1. Initialiser configurations agents
./orchestrator-dulien.sh init

# 2. Compiler business-context-mcp si nécessaire
cd ../business-context-mcp && npm run build

# 3. Tester manuellement
./orchestrator-dulien.sh check-epics

# 4. Configurer automatisation (optionnel)
./setup-cron.sh
```

## 🤖 Agents Spécialisés

### Tech Lead Agent
**Rôle** : Orchestrateur principal  
**MCP** : GitHub + Business Context  
**Mission** : Analyse épics → Création tâches techniques

### Webapp Agent  
**Spécialisation** : Angular/TypeScript + RGAA  
**MCP** : GitHub + Business Context + Accessibility  
**Mission** : Développement interfaces utilisateur

### API Agents (Tenant/Referencial)
**Spécialisation** : NestJS/TypeScript + Sécurité  
**Mission** : Endpoints robustes + documentation OpenAPI

### Agents Complémentaires
- **Mail Server** : Service notifications Node.js
- **Landing Page** : Site marketing Next.js optimisé SEO
- **Infrastructure** : Configuration DevOps/Docker
- **Security** : Audits OWASP automatiques

## 📊 Utilisation

### Workflow Standard

1. **Création Epic** → Template GitHub structuré
2. **Détection automatique** → Orchestrateur surveille nouvelles épics
3. **Analyse Tech Lead** → Découpage en tâches techniques
4. **Développement parallèle** → Agents spécialisés implémentent
5. **Quality assurance** → Reviews sécurité/accessibilité
6. **Livraison** → PRs coordonnées prêtes validation

### Commandes Manuelles

```bash
# Cycle complet (défaut)
./orchestrator-dulien.sh

# Actions spécifiques
./orchestrator-dulien.sh check-epics      # Détecter nouvelles épics
./orchestrator-dulien.sh execute-tasks    # Exécuter tâches en attente
./orchestrator-dulien.sh init            # Réinitialiser configs

# Monitoring temps réel
./monitor.sh
```

### Format JSON Workflow

```json
{
  "epics": {
    "123": {
      "analysis": "Description technique impact",
      "tasks_created": [
        {
          "repo": "webapp",
          "issue_number": 456,
          "title": "Composant recommandations IA",
          "agent": "webapp"
        }
      ],
      "workflow": [
        {
          "task_id": "webapp-456",
          "depends_on": [],
          "status": "completed",
          "priority": 1
        }
      ]
    }
  }
}
```

## 🔍 Monitoring

### Dashboard Temps Réel
```bash
./monitor.sh
```

**Fonctionnalités** :
- État épics/tâches en cours
- Statuts par agent (pending/in_progress/completed)
- Logs temps réel
- Vue détaillée workflow JSON

### Logs
- `logs/orchestrator.log` : Log principal avec timestamps
- `logs/cron.log` : Logs tâches automatiques
- `temp/failed-analysis-*.txt` : Debug échecs analyse

## 🔄 Automatisation

### Configuration Cron
```bash
./setup-cron.sh
```

**Planning** :
- **Détection épics** : toutes les 15 minutes
- **Exécution tâches** : toutes les 5 minutes  
- **Nettoyage logs** : hebdomadaire

### Désactivation
```bash
crontab -e
# Commenter/supprimer lignes Orchestrateur Dulien
```

## 🛠️ Personnalisation

### Ajouter Nouveau Repo
1. Créer configuration MCP dans `agents/nouveau-repo.json`
2. Ajouter mapping agent dans `execute_agent()` 
3. Implémenter `execute_nouveau_repo_agent()`

### Modifier Prompts Agents
Les prompts sont dans les fonctions `execute_*_agent()` du script principal. Optimiser selon besoins spécifiques.

### Debugging
- Logs détaillés dans `logs/orchestrator.log`
- Résultats bruts Claude Code dans `temp/` en cas d'échec
- Dashboard monitoring pour suivi temps réel

## 🔧 Dépannage

### Problèmes Courants

**"GITHUB_TOKEN non défini"**
```bash
export GITHUB_TOKEN="ghp_xxxxx"
# Ou ajouter au ~/.bashrc
```

**"Business Context MCP inaccessible"**
```bash
cd ../business-context-mcp
npm run build
```

**"Extraction JSON échoue"**  
→ Voir fichiers debug dans `temp/failed-analysis-*.txt`

**"Agents timeout"**
→ Ajuster timeout dans commandes `claude --print`

### Validation Système

```bash
# Test complet workflow
./orchestrator-dulien.sh check-epics

# Vérifier configurations MCP
ls -la agents/
cat agents/tech-lead.json

# Statut GitHub CLI
gh auth status
```

## 💡 Optimisations Possibles

### Performance
- **Batch processing** : Traitement simultané tâches indépendantes
- **Caching** : Réutilisation analyses similaires
- **Rate limiting** : Optimisation appels GitHub API

### Fonctionnel  
- **Webhooks GitHub** : Réactivité temps réel vs polling
- **Templates dynamiques** : Prompts adaptatifs par domaine
- **Métriques business** : Time to market, quality scores

## 📈 Métriques de Succès

### Technique
- **Time to Market** : Epic → Code < 2h
- **Automation Rate** : 90% tâches sans intervention
- **Quality Score** : 0 bug critique post-déploiement

### Business
- **Developer Productivity** : +300% vélocité
- **Consistency** : 100% respect patterns/conventions  
- **Documentation** : Auto-générée et synchronisée

---

## 🚀 État du Système

### ✅ Opérationnel
- ✅ Orchestrateur bash complet avec parsing JSON robuste
- ✅ 8 agents spécialisés configurés (MCP + prompts)
- ✅ Business Context MCP intégré
- ✅ Workflow JSON avec gestion dépendances
- ✅ Monitoring temps réel + logs détaillés
- ✅ Automatisation cron configurée

### 🔄 Testé avec Succès
- ✅ Détection épics GitHub automatique
- ✅ Analyse Tech Lead + création tâches
- ✅ Workflow JSON généré et validé
- ✅ Dashboard monitoring fonctionnel

L'orchestrateur Dulien est **opérationnel** et prêt pour automatisation complète développement multi-repos ! 🎉