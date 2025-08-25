#!/bin/bash
WORK_DIR="/home/florian/projets/dulien-orchestration"
EPIC_NUM="1"
claude --print --mcp-config "$WORK_DIR/agents/tech-lead.json" --append-system-prompt "$(cat "$WORK_DIR/temp/system-prompt-$EPIC_NUM.txt")" < "$WORK_DIR/temp/prompt-sent-$EPIC_NUM.txt"
