#!/bin/sh
# setup-secrets.sh — Configure GitHub secrets for the dist release workflow.
#
# One-time setup. Generates SSH deploy keys for each private source repo,
# sets them as secrets on the dist repo, and prints instructions for adding
# the public keys to each source repo.
#
# Prerequisites:
#   - gh CLI installed and authenticated (`gh auth login`)
#   - Write access to the dist repo (MemoryCo/memoryco)
#   - Admin access to each source repo (to add deploy keys)
#
# Usage:
#   ./scripts/setup-secrets.sh
#
# What it does:
#   1. Generates an Ed25519 SSH key pair per source repo
#   2. Sets the private key + clone URL as secrets on the dist repo
#   3. Prints the public key for you to add as a deploy key on each source repo
#
# Secrets created:
#   MEMORY_REPO, MEMORY_REPO_SSH_KEY
#   FILESYSTEM_REPO, FILESYSTEM_REPO_SSH_KEY
#   AGENTS_REPO, AGENTS_REPO_SSH_KEY

set -e

# ─── Configuration ──────────────────────────────────────────────────────────

DIST_REPO="MemoryCo/memoryco"

# Source repos
MEMORY_REPO_URL="git@github.com:MemoryCo/memory.git"
FILESYSTEM_REPO_URL="git@github.com:MemoryCo/filesystem.git"
AGENTS_REPO_URL="git@github.com:MemoryCo/agents.git"

KEY_DIR="$HOME/.memoryco/deploy-keys"

# ─── Colors ─────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    GREEN=$(printf '\033[0;32m')
    YELLOW=$(printf '\033[0;33m')
    BLUE=$(printf '\033[0;34m')
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[0;90m')
    RESET=$(printf '\033[0m')
else
    GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

info()  { printf "${BLUE}▸${RESET} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$1"; }

# ─── Preflight ──────────────────────────────────────────────────────────────

if ! command -v gh > /dev/null 2>&1; then
    echo "Error: gh CLI not found. Install from https://cli.github.com"
    exit 1
fi

if ! gh auth status > /dev/null 2>&1; then
    echo "Error: gh not authenticated. Run 'gh auth login' first."
    exit 1
fi

printf "\n${BOLD}memoryco release setup${RESET}\n"
printf "${DIM}Configuring deploy keys and secrets for ${DIST_REPO}${RESET}\n\n"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# ─── Generate keys and set secrets ──────────────────────────────────────────

setup_binary() {
    local name="$1"           # e.g., "memory"
    local repo_url="$2"       # e.g., "git@github.com:MemoryCo/memory.git"
    local secret_repo="$3"    # e.g., "MEMORY_REPO"
    local secret_key="$4"     # e.g., "MEMORY_REPO_SSH_KEY"

    # Extract "MemoryCo/memory" from the git URL
    local source_repo
    source_repo=$(echo "$repo_url" | sed 's|git@github.com:||;s|\.git$||')

    info "Setting up ${BOLD}${name}${RESET} (${source_repo})..."

    local key_path="${KEY_DIR}/${name}_deploy_key"

    # Generate key if it doesn't exist
    if [ -f "$key_path" ]; then
        warn "Key already exists at ${key_path} — reusing"
    else
        ssh-keygen -t ed25519 -f "$key_path" -N "" -C "memoryco-dist-deploy-${name}" -q
        ok "Generated deploy key: ${key_path}"
    fi

    # Set the repo URL secret on the dist repo
    gh secret set "$secret_repo" --repo "$DIST_REPO" -b "$repo_url"
    ok "Set secret ${secret_repo}"

    # Set the SSH key secret on the dist repo
    gh secret set "$secret_key" --repo "$DIST_REPO" < "$key_path"
    ok "Set secret ${secret_key}"

    # Add the public key as a deploy key on the source repo
    local pub_key
    pub_key=$(cat "${key_path}.pub")

    # Check if a deploy key with this title already exists
    local existing_key_id
    existing_key_id=$(gh api "repos/${source_repo}/keys" --jq '.[] | select(.title == "memoryco-dist-deploy") | .id' 2>/dev/null || true)

    if [ -n "$existing_key_id" ]; then
        # Remove the old one so we can replace it
        gh api --method DELETE "repos/${source_repo}/keys/${existing_key_id}" --silent 2>/dev/null || true
    fi

    if gh api --method POST "repos/${source_repo}/keys" \
        -f title="memoryco-dist-deploy" \
        -f key="${pub_key}" \
        -F read_only=true \
        --silent 2>/dev/null; then
        ok "Deploy key added to ${source_repo}"
    else
        warn "Could not add deploy key to ${source_repo} — add it manually:"
        printf "  ${DIM}Go to: https://github.com/%s/settings/keys${RESET}\n" "$source_repo"
        printf "  ${DIM}Key:${RESET} %s\n\n" "$pub_key"
    fi
}

setup_binary "memory"     "$MEMORY_REPO_URL"     "MEMORY_REPO"     "MEMORY_REPO_SSH_KEY"
setup_binary "filesystem" "$FILESYSTEM_REPO_URL"  "FILESYSTEM_REPO" "FILESYSTEM_REPO_SSH_KEY"
setup_binary "agents"     "$AGENTS_REPO_URL"      "AGENTS_REPO"     "AGENTS_REPO_SSH_KEY"

# ─── Verify ─────────────────────────────────────────────────────────────────

printf "${DIM}─────────────────────────────────────────${RESET}\n\n"
info "Verifying secrets on ${DIST_REPO}..."
gh secret list --repo "$DIST_REPO"

printf "\n${GREEN}✓${RESET} All done! Secrets set and deploy keys added.\n"
printf "${DIM}Keys stored locally in: ${KEY_DIR}${RESET}\n\n"
