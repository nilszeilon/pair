#!/usr/bin/env bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}pair installer${RESET}\n"

# ── Prerequisites ────────────────────────────────────────────────
MISSING=""

if ! command -v go &>/dev/null; then
    echo -e "  ${RED}✗${RESET} Go — install from https://go.dev/dl/"
    MISSING=1
fi

if ! command -v tmux &>/dev/null; then
    echo -e "  ${RED}✗${RESET} tmux — brew install tmux / apt install tmux"
    MISSING=1
fi

if ! command -v ttyd &>/dev/null; then
    echo -e "  ${RED}✗${RESET} ttyd — brew install ttyd / apt install ttyd"
    MISSING=1
fi

if [ -n "$MISSING" ]; then
    echo -e "\n${RED}Install missing prerequisites and re-run.${RESET}"
    exit 1
fi

echo -e "${GREEN}All prerequisites found.${RESET}\n"

# ── Install ──────────────────────────────────────────────────────
echo -e "${BOLD}Installing...${RESET}"
go install github.com/nilszeilon/pair@latest 2>&1

echo ""
echo -e "${GREEN}${BOLD}Done.${RESET}"
echo ""
echo "  pair server               start the orchestrator"
echo "  pair                      start a shell session"
echo "  pair pi                   start a specific command"
echo "  open http://localhost:4242 dashboard"
