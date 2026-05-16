#!/usr/bin/env bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}pair installer${RESET}\n"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Prerequisites ────────────────────────────────────────────────
MISSING=""

if ! command -v elixir &>/dev/null; then
    echo -e "  ${RED}✗${RESET} Elixir — install from https://elixir-lang.org/install.html"
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

# ── Build ────────────────────────────────────────────────────────
echo -e "${BOLD}Building...${RESET}"

cd "$SCRIPT_DIR/pair"
mix local.hex --force 2>&1 | tail -1
mix local.rebar --force 2>&1 | tail -1
mix deps.get --only prod 2>&1 | tail -1
mix compile 2>&1 | tail -1

echo ""
echo -e "${GREEN}${BOLD}Done.${RESET}"
echo ""
echo "  cd pair && mix pair server    start the orchestrator"
echo "  open http://localhost:4242    manage sessions in the browser"
