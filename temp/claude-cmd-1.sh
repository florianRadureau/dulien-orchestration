#!/bin/bash
WORK_DIR="/home/florian/projets/dulien-orchestration"
EPIC_NUM="1"
claude --print --append-system-prompt "$(cat "$WORK_DIR/temp/system-prompt-$EPIC_NUM.txt")" < "$WORK_DIR/temp/prompt-sent-$EPIC_NUM.txt"
