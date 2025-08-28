#!/usr/bin/env python3
"""
Agent Claude pour l'exécution des tâches techniques
Utilise Claude CLI pour implémenter, reviewer et décomposer
"""

import subprocess
import json
import logging
import time
from typing import Dict, Any, Optional, List
from pathlib import Path
import tempfile

from config import CLAUDE_PROMPTS, ORCHESTRATOR_CONFIG

logger = logging.getLogger(__name__)


class ClaudeAgent:
    """Interface avec Claude CLI pour exécution des tâches"""
    
    def __init__(self):
        self.timeout = ORCHESTRATOR_CONFIG["action_timeout"]
        self.retry_attempts = ORCHESTRATOR_CONFIG["retry_attempts"]
        self.retry_delay = ORCHESTRATOR_CONFIG["retry_delay"]
        
    def execute_task(self, action: Dict[str, Any]) -> Dict[str, Any]:
        """
        Point d'entrée principal pour exécuter une action via Claude
        
        Args:
            action: Dict avec type, repo, number, et metadata
            
        Returns:
            Dict avec status (success/failed) et details
        """
        action_type = action["type"]
        
        logger.info(f"Exécution action {action_type} sur {action['repo']}#{action['number']}")
        
        # Dispatcher vers la bonne méthode
        if action_type == "review_pr":
            return self._review_pr(action)
        elif action_type == "implement_task":
            return self._implement_task(action)
        elif action_type == "decompose_epic":
            return self._decompose_epic(action)
        elif action_type == "monitor_task":
            return self._monitor_task(action)
        else:
            logger.error(f"Type d'action inconnu : {action_type}")
            return {"status": "failed", "error": f"Unknown action type: {action_type}"}
    
    def _review_pr(self, action: Dict[str, Any]) -> Dict[str, Any]:
        """Review et potentiellement merge une PR"""
        
        prompt = CLAUDE_PROMPTS["review_pr"].format(
            repo=action["repo"],
            pr_number=action["number"],
            title=action.get("title", "")
        )
        
        return self._run_claude_command(prompt, action)
    
    def _implement_task(self, action: Dict[str, Any]) -> Dict[str, Any]:
        """Implémente une tâche complète"""
        
        # D'abord, marquer la tâche comme processing
        self._add_label(action["repo"], action["number"], "processing")
        
        prompt = CLAUDE_PROMPTS["implement_task"].format(
            repo=action["repo"],
            task_number=action["number"],
            title=action.get("title", ""),
            body=action.get("body", "")
        )
        
        result = self._run_claude_command(prompt, action)
        
        # Si succès, ajouter le label review-requested
        if result["status"] == "success":
            self._add_label(action["repo"], action["number"], "status:review-requested")
        else:
            # En cas d'échec, retirer processing
            self._remove_label(action["repo"], action["number"], "processing")
        
        return result
    
    def _decompose_epic(self, action: Dict[str, Any]) -> Dict[str, Any]:
        """Décompose un épic en sous-tâches"""
        
        prompt = CLAUDE_PROMPTS["decompose_epic"].format(
            repo=action["repo"],
            epic_number=action["number"],
            title=action.get("title", ""),
            body=action.get("body", "")
        )
        
        return self._run_claude_command(prompt, action)
    
    def _monitor_task(self, action: Dict[str, Any]) -> Dict[str, Any]:
        """Vérifie l'état d'une tâche en processing"""
        
        prompt = CLAUDE_PROMPTS["monitor_task"].format(
            repo=action["repo"],
            task_number=action["number"],
            title=action.get("title", "")
        )
        
        return self._run_claude_command(prompt, action, timeout=120)  # Timeout plus court
    
    def _run_claude_command(self, prompt: str, action: Dict[str, Any], 
                           timeout: Optional[int] = None) -> Dict[str, Any]:
        """
        Exécute Claude CLI avec le prompt donné
        
        Args:
            prompt: Le prompt à envoyer à Claude
            action: Contexte de l'action
            timeout: Timeout custom (sinon utilise celui par défaut)
            
        Returns:
            Dict avec status et details
        """
        if timeout is None:
            timeout = self.timeout
        
        # Naviguer vers le bon repo si nécessaire
        repo_path = Path(f"/home/florian/projets/mentorize-app/{action['repo']}")
        
        # Construction de la commande Claude
        cmd = [
            "claude",
            prompt,
            "-p",  # Mode projet pour avoir accès aux MCP et contexte
            "--output-format", "json",
            "--permission-mode", "bypassPermissions"
        ]
        
        # Tentatives avec retry
        for attempt in range(self.retry_attempts):
            try:
                logger.debug(f"Tentative {attempt + 1}/{self.retry_attempts} pour {action['type']}")
                
                # Exécuter dans le bon répertoire si il existe
                cwd = repo_path if repo_path.exists() else None
                
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                    cwd=cwd
                )
                
                # Parser la sortie JSON si possible
                try:
                    output = json.loads(result.stdout) if result.stdout else {}
                except json.JSONDecodeError:
                    output = {"raw_output": result.stdout}
                
                if result.returncode == 0:
                    logger.info(f"✅ Action {action['type']} réussie sur {action['repo']}#{action['number']}")
                    return {
                        "status": "success",
                        "output": output,
                        "attempt": attempt + 1
                    }
                else:
                    error_msg = result.stderr or "Unknown error"
                    logger.warning(f"Tentative {attempt + 1} échouée : {error_msg}")
                    
                    if attempt < self.retry_attempts - 1:
                        time.sleep(self.retry_delay)
                        continue
                    else:
                        return {
                            "status": "failed",
                            "error": error_msg,
                            "output": output,
                            "attempts": self.retry_attempts
                        }
                        
            except subprocess.TimeoutExpired:
                logger.error(f"Timeout après {timeout}s pour {action['type']}")
                return {
                    "status": "failed",
                    "error": f"Command timed out after {timeout} seconds",
                    "attempts": attempt + 1
                }
            except Exception as e:
                logger.error(f"Erreur inattendue : {e}")
                
                if attempt < self.retry_attempts - 1:
                    time.sleep(self.retry_delay)
                    continue
                else:
                    return {
                        "status": "failed",
                        "error": str(e),
                        "attempts": self.retry_attempts
                    }
        
        return {
            "status": "failed",
            "error": "Max retry attempts reached",
            "attempts": self.retry_attempts
        }
    
    def _add_label(self, repo: str, issue_number: int, label: str) -> bool:
        """Ajoute un label via gh CLI"""
        cmd = [
            "gh", "issue", "edit",
            str(issue_number),
            "--repo", f"mentorize-app/{repo}",
            "--add-label", label
        ]
        
        result = subprocess.run(cmd, capture_output=True)
        success = result.returncode == 0
        
        if success:
            logger.debug(f"Label '{label}' ajouté à {repo}#{issue_number}")
        else:
            logger.warning(f"Échec ajout label '{label}' à {repo}#{issue_number}")
        
        return success
    
    def _remove_label(self, repo: str, issue_number: int, label: str) -> bool:
        """Retire un label via gh CLI"""
        cmd = [
            "gh", "issue", "edit",
            str(issue_number),
            "--repo", f"mentorize-app/{repo}",
            "--remove-label", label
        ]
        
        result = subprocess.run(cmd, capture_output=True)
        success = result.returncode == 0
        
        if success:
            logger.debug(f"Label '{label}' retiré de {repo}#{issue_number}")
        else:
            logger.warning(f"Échec retrait label '{label}' de {repo}#{issue_number}")
        
        return success
    
    def validate_environment(self) -> bool:
        """Vérifie que Claude CLI est disponible et configuré"""
        try:
            # Test si Claude est installé
            result = subprocess.run(
                ["claude", "--version"],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode != 0:
                logger.error("Claude CLI n'est pas installé ou pas dans le PATH")
                return False
            
            logger.info(f"Claude CLI détecté : {result.stdout.strip()}")
            
            # Test si les MCP sont disponibles
            result = subprocess.run(
                ["claude", "mcp", "list"],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode == 0:
                logger.info("MCP servers disponibles")
            else:
                logger.warning("MCP servers non configurés - fonctionnalité réduite")
            
            return True
            
        except FileNotFoundError:
            logger.error("Claude CLI introuvable - vérifiez l'installation")
            return False
        except subprocess.TimeoutExpired:
            logger.error("Timeout lors de la vérification de Claude CLI")
            return False
        except Exception as e:
            logger.error(f"Erreur lors de la validation : {e}")
            return False


if __name__ == "__main__":
    # Test de validation
    logging.basicConfig(level=logging.DEBUG)
    
    agent = ClaudeAgent()
    
    print("=== Validation de l'environnement ===")
    if agent.validate_environment():
        print("✅ Claude CLI est prêt")
        
        # Test avec une action factice
        test_action = {
            "type": "monitor_task",
            "repo": "webapp",
            "number": 59,
            "title": "Test monitoring"
        }
        
        print(f"\n=== Test action : {test_action['type']} ===")
        # Décommentez pour tester réellement
        # result = agent.execute_task(test_action)
        # print(f"Résultat : {result}")
    else:
        print("❌ Claude CLI n'est pas configuré correctement")