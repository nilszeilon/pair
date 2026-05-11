#!/usr/bin/env bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}pair installer${RESET}\n"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Prerequisites ────────────────────────────────────────────────
MISSING=""

if ! command -v go &>/dev/null; then
    echo -e "  ${RED}✗${RESET} Go — install from https://go.dev/dl/"
    MISSING=1
fi

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

# ── Server (Elixir) ──────────────────────────────────────────────
echo -e "${BOLD}Installing server...${RESET}"

cd "$SCRIPT_DIR/pair"
mix deps.get --only prod 2>&1 | tail -1
mix compile 2>&1 | tail -1
echo -e "  ${GREEN}✓${RESET} Server ready"

# ── Client (Go) ──────────────────────────────────────────────────
echo -e "${BOLD}Building client...${RESET}"

GOBIN="${HOME}/go/bin"
mkdir -p "$GOBIN"

cd "$SCRIPT_DIR/pair-client"
go build -ldflags="-s -w" -o "$GOBIN/pair" .
echo -e "  ${GREEN}✓${RESET} Client built → ${GOBIN}/pair"

# ── PATH check ───────────────────────────────────────────────────
if ! echo "$PATH" | grep -q "$GOBIN"; then
    echo -e "\n${YELLOW}Add ~/go/bin to your PATH:${RESET}"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if ! grep -q "$GOBIN" "$rc" 2>/dev/null; then
            echo "export PATH=\"\$HOME/go/bin:\$PATH\"" >> "$rc"
            echo -e "  Added to $rc"
        fi
    done
    echo -e "  Then run: source ~/.bashrc (or ~/.zshrc)"
fi

# ── Done ─────────────────────────────────────────────────────────
# Record project location for the client to find later
mkdir -p "$HOME/.pair"
# Record the parent directory (pair/ is the mix project)
if [ -f "$SCRIPT_DIR/pair/mix.exs" ]; then
    echo "$SCRIPT_DIR" > "$HOME/.pair/project"
elif [ -f "$SCRIPT_DIR/mix.exs" ]; then
    echo "$(dirname "$SCRIPT_DIR")" > "$HOME/.pair/project"
fi

echo ""
echo -e "${GREEN}${BOLD}Done.${RESET}"
echo ""
echo "  pair pi              start coding locally"
echo "  pair connect <host>  set a remote server"
echo "  pair remote pi       start coding on the remote server"
