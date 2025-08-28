#!/usr/bin/env python3
"""
Orchestrateur principal Dulien avec Mistral pour les décisions et Claude pour l'exécution
"""

import json
import logging
import logging.config
import time
import threading
from datetime import datetime
from typing import List, Dict, Any, Optional
import sys
from pathlib import Path

# Imports locaux
from github_client import GitHubClient
from claude_agent import ClaudeAgent
from config import (
    MISTRAL_CONFIG, 
    MISTRAL_PROMPTS,
    ORCHESTRATOR_CONFIG,
    LOGGING_CONFIG,
    MESSAGES,
    TASK_FILTERS
)

# Configuration des logs
logging.config.dictConfig(LOGGING_CONFIG)
logger = logging.getLogger(__name__)

# Import Ollama
try:
    from ollama import Client
    OLLAMA_AVAILABLE = True
except ImportError:
    logger.warning("Ollama non installé - mode dégradé sans Mistral")
    OLLAMA_AVAILABLE = False


class DulienOrchestrator:
    """Orchestrateur principal avec logique de priorité inversée"""
    
    def __init__(self):
        self.github = GitHubClient()
        self.claude = ClaudeAgent()
        
        # Mistral pour les décisions
        if OLLAMA_AVAILABLE:
            self.ollama = Client()
            self.model = MISTRAL_CONFIG["model"]
        else:
            self.ollama = None
            self.model = None
        
        # État minimal pour éviter les doublons durant le run
        self.current_run_actions = set()
        
    def run_cycle(self) -> Dict[str, Any]:
        """
        Exécute un cycle complet d'orchestration
        
        Returns:
            Résumé du cycle avec actions exécutées
        """
        logger.info(MESSAGES["cycle_start"])
        cycle_start = datetime.now()
        
        # 1. Scanner l'état GitHub
        github_state = self._scan_github_state()
        
        # 2. Décider des actions avec Mistral
        actions = self._decide_actions(github_state)
        
        if not actions:
            logger.info(MESSAGES["no_actions"])
            return {
                "status": "idle",
                "duration": (datetime.now() - cycle_start).seconds,
                "actions_executed": []
            }
        
        # 3. Exécuter les actions via Claude
        results = self._execute_actions(actions)
        
        # 4. Résumé du cycle
        cycle_duration = (datetime.now() - cycle_start).seconds
        logger.info(f"{MESSAGES['cycle_end']} - Durée : {cycle_duration}s")
        
        return {
            "status": "completed",
            "duration": cycle_duration,
            "actions_executed": results
        }
    
    def _scan_github_state(self) -> Dict[str, Any]:
        """Scan l'état actuel de GitHub avec priorité inversée"""
        
        logger.debug("Scan de l'état GitHub...")
        
        # 1. PRs d'abord (fin du pipeline)
        prs = self.github.list_prs(state="open")
        
        # 2. Tâches ouvertes
        all_tasks = self.github.get_tasks()
        
        # Filtrer les tâches selon les règles
        open_tasks = []
        processing_tasks = []
        
        for task in all_tasks:
            # Ignorer les vieilles tâches
            if task["number"] < TASK_FILTERS["ignore_old_tasks_before_number"]:
                continue
            
            if task.get("has_processing_label"):
                processing_tasks.append(task)
            else:
                open_tasks.append(task)
        
        # 3. Épics
        epics = self.github.get_epics()
        epics_without_tasks = []
        
        for epic in epics:
            if not self.github.epic_has_tasks(epic):
                epics_without_tasks.append(epic)
        
        state = {
            "timestamp": datetime.now().isoformat(),
            "prs": {
                "count": len(prs),
                "items": prs
            },
            "tasks": {
                "open_count": len(open_tasks),
                "processing_count": len(processing_tasks),
                "open_items": open_tasks,
                "processing_items": processing_tasks
            },
            "epics": {
                "without_tasks_count": len(epics_without_tasks),
                "items": epics_without_tasks
            }
        }
        
        logger.info(f"État : {len(prs)} PRs, {len(open_tasks)} tâches ouvertes, "
                   f"{len(processing_tasks)} en cours, {len(epics_without_tasks)} épics sans tâches")
        
        return state
    
    def _decide_actions(self, state: Dict[str, Any]) -> List[Dict[str, Any]]:
        """
        Utilise Mistral pour décider des actions à entreprendre
        
        Args:
            state: État actuel de GitHub
            
        Returns:
            Liste des actions prioritaires à exécuter
        """
        
        # Si Mistral n'est pas disponible, logique simple de fallback
        if not self.ollama:
            return self._simple_decision_logic(state)
        
        # Préparer le prompt pour Mistral
        state_summary = {
            "prs": [
                {"repo": pr["repo"], "number": pr["number"], "title": pr["title"]}
                for pr in state["prs"]["items"][:5]  # Limiter pour le contexte
            ],
            "open_tasks": [
                {
                    "repo": t["repo"], 
                    "number": t["number"], 
                    "title": t["title"],
                    "labels": [l["name"] for l in t.get("labels", [])]
                }
                for t in state["tasks"]["open_items"][:10]
            ],
            "processing_tasks": [
                {"repo": t["repo"], "number": t["number"]}
                for t in state["tasks"]["processing_items"]
            ],
            "epics_without_tasks": [
                {"repo": e["repo"], "number": e["number"], "title": e["title"]}
                for e in state["epics"]["items"]
            ]
        }
        
        prompt = MISTRAL_PROMPTS["analyze_state"].format(
            state=json.dumps(state_summary, indent=2, ensure_ascii=False)
        )
        
        try:
            logger.debug("Consultation de Mistral pour décisions...")
            
            response = self.ollama.generate(
                model=self.model,
                prompt=prompt,
                options=MISTRAL_CONFIG["options"],
                format="json"
            )
            
            # Parser la réponse JSON
            decision = json.loads(response["response"])
            actions = decision.get("actions", [])
            reasoning = decision.get("reasoning", "")
            
            logger.info(f"Mistral suggère {len(actions)} actions : {reasoning}")
            
            # Enrichir les actions avec les métadonnées
            enriched_actions = []
            for action in actions[:ORCHESTRATOR_CONFIG["max_parallel_actions"]]:
                # Retrouver les détails complets depuis l'état
                enriched = self._enrich_action(action, state)
                if enriched and self._can_process_action(enriched):
                    enriched_actions.append(enriched)
            
            return enriched_actions
            
        except Exception as e:
            logger.error(f"Erreur Mistral : {e}")
            return self._simple_decision_logic(state)
    
    def _simple_decision_logic(self, state: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Logique de décision simple sans Mistral (fallback)"""
        
        actions = []
        max_actions = ORCHESTRATOR_CONFIG["max_parallel_actions"]
        
        # 1. PRs d'abord
        for pr in state["prs"]["items"][:max_actions]:
            if self._can_process_action({"type": "review_pr", "repo": pr["repo"], "number": pr["number"]}):
                actions.append({
                    "type": "review_pr",
                    "repo": pr["repo"],
                    "number": pr["number"],
                    "title": pr.get("title", ""),
                    "priority": 1
                })
                
                if len(actions) >= max_actions:
                    return actions
        
        # 2. Tâches ouvertes
        for task in state["tasks"]["open_items"][:max_actions - len(actions)]:
            if self._can_process_action({"type": "implement_task", "repo": task["repo"], "number": task["number"]}):
                actions.append({
                    "type": "implement_task",
                    "repo": task["repo"],
                    "number": task["number"],
                    "title": task.get("title", ""),
                    "body": task.get("body", ""),
                    "priority": 2
                })
                
                if len(actions) >= max_actions:
                    return actions
        
        # 3. Épics sans tâches
        for epic in state["epics"]["items"][:max_actions - len(actions)]:
            if self._can_process_action({"type": "decompose_epic", "repo": epic["repo"], "number": epic["number"]}):
                actions.append({
                    "type": "decompose_epic",
                    "repo": epic["repo"],
                    "number": epic["number"],
                    "title": epic.get("title", ""),
                    "body": epic.get("body", ""),
                    "priority": 3
                })
                
                if len(actions) >= max_actions:
                    return actions
        
        logger.info(f"Logique simple : {len(actions)} actions sélectionnées")
        return actions
    
    def _enrich_action(self, action: Dict[str, Any], state: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Enrichit une action avec les métadonnées complètes"""
        
        # Retrouver l'élément complet depuis l'état
        if action["type"] == "review_pr":
            for pr in state["prs"]["items"]:
                if pr["repo"] == action["repo"] and pr["number"] == action["number"]:
                    action["title"] = pr.get("title", "")
                    return action
        
        elif action["type"] == "implement_task":
            for task in state["tasks"]["open_items"]:
                if task["repo"] == action["repo"] and task["number"] == action["number"]:
                    action["title"] = task.get("title", "")
                    action["body"] = task.get("body", "")
                    return action
        
        elif action["type"] == "decompose_epic":
            for epic in state["epics"]["items"]:
                if epic["repo"] == action["repo"] and epic["number"] == action["number"]:
                    action["title"] = epic.get("title", "")
                    action["body"] = epic.get("body", "")
                    return action
        
        elif action["type"] == "monitor_task":
            for task in state["tasks"]["processing_items"]:
                if task["repo"] == action["repo"] and task["number"] == action["number"]:
                    action["title"] = task.get("title", "")
                    return action
        
        logger.warning(f"Impossible d'enrichir l'action : {action}")
        return None
    
    def _can_process_action(self, action: Dict[str, Any]) -> bool:
        """Vérifie si on peut traiter cette action (évite les doublons)"""
        
        action_key = (action["type"], action["repo"], action["number"])
        
        if action_key in self.current_run_actions:
            logger.debug(f"Action déjà en cours : {action_key}")
            return False
        
        self.current_run_actions.add(action_key)
        return True
    
    def _execute_actions(self, actions: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Exécute les actions en parallèle via Claude
        
        Args:
            actions: Liste des actions à exécuter
            
        Returns:
            Liste des résultats
        """
        
        if not actions:
            return []
        
        logger.info(f"Exécution de {len(actions)} actions en parallèle...")
        
        threads = []
        results = []
        
        def execute_with_result(action, result_list):
            """Fonction wrapper pour capturer le résultat"""
            logger.info(MESSAGES["starting_action"].format(
                action_type=action["type"],
                repo=action["repo"],
                number=action["number"]
            ))
            
            result = self.claude.execute_task(action)
            result["action"] = action
            result_list.append(result)
            
            if result["status"] == "success":
                logger.info(MESSAGES["action_complete"].format(
                    action_type=action["type"],
                    repo=action["repo"],
                    number=action["number"]
                ))
            else:
                logger.error(MESSAGES["action_failed"].format(
                    action_type=action["type"],
                    repo=action["repo"],
                    number=action["number"],
                    error=result.get("error", "Unknown")
                ))
        
        # Lancer les threads
        for action in actions:
            thread = threading.Thread(
                target=execute_with_result,
                args=(action, results)
            )
            threads.append(thread)
            thread.start()
        
        # Attendre la fin avec timeout
        timeout = ORCHESTRATOR_CONFIG["action_timeout"]
        for thread in threads:
            thread.join(timeout=timeout)
            if thread.is_alive():
                logger.warning(f"Thread toujours actif après {timeout}s")
        
        return results
    
    def run_continuous(self):
        """Lance l'orchestrateur en mode continu"""
        
        logger.info("🚀 Démarrage de l'orchestrateur Dulien en mode continu")
        
        # Validation de l'environnement
        if not self.claude.validate_environment():
            logger.error("❌ Claude CLI n'est pas configuré - arrêt")
            sys.exit(1)
        
        if not self.ollama:
            logger.warning("⚠️  Mistral non disponible - mode dégradé")
        else:
            logger.info(f"✅ Mistral configuré : {self.model}")
        
        # Boucle principale
        interval = ORCHESTRATOR_CONFIG["loop_interval"]
        
        try:
            while True:
                try:
                    # Reset des actions du run précédent
                    self.current_run_actions.clear()
                    
                    # Exécuter un cycle
                    result = self.run_cycle()
                    
                    # Log du résumé
                    logger.info(f"Cycle terminé : {result['status']} "
                               f"({result.get('duration', 0)}s) "
                               f"- {len(result.get('actions_executed', []))} actions")
                    
                    # Pause avant le prochain cycle
                    logger.info(f"Pause de {interval}s avant le prochain cycle...")
                    time.sleep(interval)
                    
                except KeyboardInterrupt:
                    raise
                except Exception as e:
                    logger.error(f"Erreur dans le cycle : {e}", exc_info=True)
                    logger.info(f"Reprise dans {interval}s...")
                    time.sleep(interval)
                    
        except KeyboardInterrupt:
            logger.info("🛑 Arrêt demandé par l'utilisateur")
            sys.exit(0)


def main():
    """Point d'entrée principal"""
    
    import argparse
    
    parser = argparse.ArgumentParser(description="Orchestrateur Dulien")
    parser.add_argument(
        "--once",
        action="store_true",
        help="Exécuter un seul cycle puis quitter"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Mode simulation - affiche les actions sans les exécuter"
    )
    
    args = parser.parse_args()
    
    orchestrator = DulienOrchestrator()
    
    if args.once:
        logger.info("Exécution unique...")
        result = orchestrator.run_cycle()
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        orchestrator.run_continuous()


if __name__ == "__main__":
    main()