#!/usr/bin/env python3
"""
Client GitHub pour l'orchestrateur Dulien
Gère les interactions avec l'API GitHub via gh CLI
"""

import subprocess
import json
import logging
from typing import List, Dict, Any, Optional
from datetime import datetime, timedelta

logger = logging.getLogger(__name__)


class GitHubClient:
    """Interface simplifiée avec l'API GitHub via gh CLI"""
    
    def __init__(self):
        self.org = "mentorize-app"
        self.repos = ["webapp", "infrastructure", "tenant-api", "referential"]
        
    def _run_gh_command(self, args: List[str]) -> Dict[str, Any]:
        """Exécute une commande gh et retourne le JSON"""
        try:
            result = subprocess.run(
                ["gh"] + args + ["--json"],
                capture_output=True,
                text=True,
                check=True
            )
            return json.loads(result.stdout) if result.stdout else {}
        except subprocess.CalledProcessError as e:
            logger.error(f"Erreur gh command: {e.stderr}")
            return {}
        except json.JSONDecodeError as e:
            logger.error(f"Erreur parsing JSON: {e}")
            return {}
    
    def list_prs(self, state: str = "open") -> List[Dict[str, Any]]:
        """Liste toutes les PRs ouvertes de l'organisation"""
        all_prs = []
        
        for repo in self.repos:
            cmd = [
                "pr", "list",
                "--repo", f"{self.org}/{repo}",
                "--state", state,
                "--json", "number,title,state,createdAt,author,labels,isDraft,reviewDecision"
            ]
            
            result = subprocess.run(
                ["gh"] + cmd,
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0 and result.stdout:
                try:
                    prs = json.loads(result.stdout)
                    for pr in prs:
                        pr["repo"] = repo
                    all_prs.extend(prs)
                except json.JSONDecodeError:
                    logger.error(f"Erreur parsing PRs pour {repo}")
        
        return all_prs
    
    def list_issues(self, labels: Optional[List[str]] = None, state: str = "open") -> List[Dict[str, Any]]:
        """Liste les issues avec filtres optionnels"""
        all_issues = []
        
        for repo in self.repos:
            cmd = [
                "issue", "list",
                "--repo", f"{self.org}/{repo}",
                "--state", state,
                "--json", "number,title,state,createdAt,labels,body,assignees"
            ]
            
            # Ajouter les filtres de labels si spécifiés
            if labels:
                for label in labels:
                    # Support des wildcards dans les labels
                    if "*" in label:
                        # Pour agent:*, on récupère tout et filtre après
                        pass
                    else:
                        cmd.extend(["--label", label])
            
            result = subprocess.run(
                ["gh"] + cmd,
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0 and result.stdout:
                try:
                    issues = json.loads(result.stdout)
                    
                    # Filtrage post-récupération pour les wildcards
                    if labels:
                        filtered_issues = []
                        for issue in issues:
                            issue_labels = [l["name"] for l in issue.get("labels", [])]
                            
                            # Vérifier si l'issue a au moins un label correspondant
                            for label_filter in labels:
                                if "*" in label_filter:
                                    # Wildcard matching
                                    prefix = label_filter.replace("*", "")
                                    if any(l.startswith(prefix) for l in issue_labels):
                                        filtered_issues.append(issue)
                                        break
                                elif label_filter in issue_labels:
                                    filtered_issues.append(issue)
                                    break
                        issues = filtered_issues
                    
                    # Ajouter le repo et extraire les infos utiles
                    for issue in issues:
                        issue["repo"] = repo
                        issue["has_epic_label"] = any(
                            l["name"] == "type:epic" 
                            for l in issue.get("labels", [])
                        )
                        issue["has_processing_label"] = any(
                            l["name"] == "processing" 
                            for l in issue.get("labels", [])
                        )
                        issue["agent_label"] = next(
                            (l["name"] for l in issue.get("labels", []) 
                             if l["name"].startswith("agent:")),
                            None
                        )
                    
                    all_issues.extend(issues)
                except json.JSONDecodeError:
                    logger.error(f"Erreur parsing issues pour {repo}")
        
        return all_issues
    
    def get_epics(self) -> List[Dict[str, Any]]:
        """Récupère uniquement les épics ouverts"""
        return self.list_issues(labels=["type:epic"], state="open")
    
    def get_tasks(self) -> List[Dict[str, Any]]:
        """Récupère les tâches (issues avec label agent:*)"""
        tasks = self.list_issues(labels=["agent:*"], state="open")
        
        # Filtrer pour exclure les épics qui auraient aussi un label agent
        return [t for t in tasks if not t.get("has_epic_label")]
    
    def add_label(self, repo: str, issue_number: int, label: str) -> bool:
        """Ajoute un label à une issue"""
        cmd = [
            "issue", "edit",
            str(issue_number),
            "--repo", f"{self.org}/{repo}",
            "--add-label", label
        ]
        
        result = subprocess.run(["gh"] + cmd, capture_output=True)
        return result.returncode == 0
    
    def remove_label(self, repo: str, issue_number: int, label: str) -> bool:
        """Retire un label d'une issue"""
        cmd = [
            "issue", "edit", 
            str(issue_number),
            "--repo", f"{self.org}/{repo}",
            "--remove-label", label
        ]
        
        result = subprocess.run(["gh"] + cmd, capture_output=True)
        return result.returncode == 0
    
    def create_issue(self, repo: str, title: str, body: str, labels: List[str]) -> Optional[int]:
        """Crée une nouvelle issue et retourne son numéro"""
        cmd = [
            "issue", "create",
            "--repo", f"{self.org}/{repo}",
            "--title", title,
            "--body", body
        ]
        
        for label in labels:
            cmd.extend(["--label", label])
        
        result = subprocess.run(
            ["gh"] + cmd,
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0 and result.stdout:
            # Le numéro est généralement dans l'output
            try:
                # Format: https://github.com/org/repo/issues/123
                url = result.stdout.strip()
                issue_number = int(url.split("/")[-1])
                return issue_number
            except (ValueError, IndexError):
                logger.error(f"Impossible d'extraire le numéro d'issue: {result.stdout}")
        
        return None
    
    def epic_has_tasks(self, epic: Dict[str, Any]) -> bool:
        """Vérifie si un épic a déjà des sous-tâches"""
        # Rechercher les tâches qui référencent cet épic
        epic_ref = f"#{epic['number']}"
        tasks = self.get_tasks()
        
        for task in tasks:
            if task["repo"] == epic["repo"]:
                # Vérifier si le body de la tâche référence l'épic
                if epic_ref in task.get("body", ""):
                    return True
                # Ou si le titre contient une référence
                if epic_ref in task.get("title", ""):
                    return True
        
        return False
    
    def close_issue(self, repo: str, issue_number: int, reason: str = "completed") -> bool:
        """Ferme une issue avec une raison"""
        cmd = [
            "issue", "close",
            str(issue_number),
            "--repo", f"{self.org}/{repo}",
            "--reason", reason
        ]
        
        result = subprocess.run(["gh"] + cmd, capture_output=True)
        return result.returncode == 0


if __name__ == "__main__":
    # Test basique
    client = GitHubClient()
    
    print("=== PRs ouvertes ===")
    prs = client.list_prs()
    for pr in prs:
        print(f"  {pr['repo']} #{pr['number']}: {pr['title']}")
    
    print("\n=== Épics ouverts ===")
    epics = client.get_epics()
    for epic in epics:
        print(f"  {epic['repo']} #{epic['number']}: {epic['title']}")
    
    print("\n=== Tâches ouvertes ===")
    tasks = client.get_tasks()
    for task in tasks[:5]:  # Limiter l'affichage
        status = "processing" if task.get("has_processing_label") else "pending"
        print(f"  {task['repo']} #{task['number']} [{status}]: {task['title']}")