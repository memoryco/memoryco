#!/bin/sh
# release.sh — Interactive release workflow for MemoryCo binaries.
#
# Walks you through the full release process:
#   1. Pick a binary (or pass it as an arg)
#   2. Show current version from Cargo.toml
#   3. Ask for the new version
#   4. Update Cargo.toml
#   5. Commit + push the version bump
#   6. Tag + push the release tag (triggers CI)
#   7. Optionally watch the CI workflow
#
# Usage:
#   ./scripts/release.sh                    # fully interactive
#   ./scripts/release.sh memoryco           # skip binary selection
#   ./scripts/release.sh memoryco 0.9.1     # skip prompts (non-interactive)
#   ./scripts/release.sh --dry-run          # preview without changes

set -e

# ─── Configuration ──────────────────────────────────────────────────────────

DIST_REPO="MemoryCo/memoryco"

# Binary → source directory mapping (relative to workspace root)
# Format: "binary:source_dir"
BINARY_MAP="memoryco:memory memoryco_fs:filesystem memoryco_agents:agents"

# ─── Colors ─────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    GREEN=$(printf '\033[0;32m')
    RED=$(printf '\033[0;31m')
    YELLOW=$(printf '\033[0;33m')
    BLUE=$(printf '\033[0;34m')
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[0;90m')
    RESET=$(printf '\033[0m')
else
    GREEN='' RED='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

info()  { printf "${BLUE}▸${RESET} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$1"; }
fail()  { printf "${RED}✗${RESET} %s\n" "$1" >&2; exit 1; }
ask()   { printf "${BLUE}?${RESET} %s " "$1"; }

# ─── Helpers ────────────────────────────────────────────────────────────────

# Get the source directory for a binary name.
source_dir_for() {
    local binary="$1"
    for entry in $BINARY_MAP; do
        local name="${entry%%:*}"
        local dir="${entry##*:}"
        if [ "$name" = "$binary" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Get all binary names.
all_binaries() {
    for entry in $BINARY_MAP; do
        echo "${entry%%:*}"
    done
}

# Read the current version from a Cargo.toml.
cargo_version() {
    local toml="$1"
    grep '^version' "$toml" | head -1 | sed 's/version = "//;s/"//'
}

# Bump a version string. Supports: patch, minor, major, or explicit version.
suggest_next() {
    local current="$1"
    local major minor patch
    major=$(echo "$current" | cut -d. -f1)
    minor=$(echo "$current" | cut -d. -f2)
    patch=$(echo "$current" | cut -d. -f3)
    patch=$((patch + 1))
    echo "${major}.${minor}.${patch}"
}

# Validate semver format.
validate_version() {
    case "$1" in
        [0-9]*.[0-9]*.[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Parse arguments ────────────────────────────────────────────────────────

DRY_RUN=0
BINARY=""
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*)        fail "Unknown option: $arg" ;;
        *)
            if [ -z "$BINARY" ]; then
                BINARY="$arg"
            elif [ -z "$VERSION" ]; then
                VERSION="$arg"
            else
                fail "Too many arguments"
            fi
            ;;
    esac
done

# ─── Workspace root ────────────────────────────────────────────────────────

# We need to find the workspace root (parent of dist/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$(cd "$DIST_DIR/.." && pwd)"

if [ ! -f "$DIST_DIR/.github/workflows/release.yml" ]; then
    fail "Can't find release.yml. Run from the dist repo or its scripts/ dir."
fi

# ─── Step 1: Select binary ─────────────────────────────────────────────────

printf "\n${BOLD}memoryco release${RESET}\n\n"

if [ -z "$BINARY" ]; then
    info "Which binary are you releasing?\n"
    i=1
    for name in $(all_binaries); do
        src=$(source_dir_for "$name")
        toml="${WORKSPACE}/${src}/Cargo.toml"
        if [ -f "$toml" ]; then
            ver=$(cargo_version "$toml")
            printf "  ${BOLD}%d)${RESET} %-20s ${DIM}(current: %s)${RESET}\n" "$i" "$name" "$ver"
        else
            printf "  ${BOLD}%d)${RESET} %-20s ${DIM}(Cargo.toml not found)${RESET}\n" "$i" "$name"
        fi
        i=$((i + 1))
    done
    printf "\n"
    ask "Enter number or name:"
    read -r choice

    # Resolve number to name
    case "$choice" in
        1) BINARY="memoryco" ;;
        2) BINARY="memoryco_fs" ;;
        3) BINARY="memoryco_agents" ;;
        *) BINARY="$choice" ;;
    esac
fi

# Validate binary
SOURCE_DIR=$(source_dir_for "$BINARY") || fail "Unknown binary: $BINARY"
CARGO_TOML="${WORKSPACE}/${SOURCE_DIR}/Cargo.toml"

if [ ! -f "$CARGO_TOML" ]; then
    fail "Cargo.toml not found at $CARGO_TOML"
fi

CURRENT_VERSION=$(cargo_version "$CARGO_TOML")
SUGGESTED=$(suggest_next "$CURRENT_VERSION")

printf "\n"
ok "Binary:          ${BOLD}${BINARY}${RESET}"
ok "Source:          ${DIM}${WORKSPACE}/${SOURCE_DIR}${RESET}"
ok "Current version: ${BOLD}${CURRENT_VERSION}${RESET}"

# ─── Step 2: Choose new version ────────────────────────────────────────────

if [ -z "$VERSION" ]; then
    printf "\n"
    ask "New version [${SUGGESTED}]:"
    read -r VERSION

    # Default to suggested if empty
    if [ -z "$VERSION" ]; then
        VERSION="$SUGGESTED"
    fi
fi

# Strip leading 'v' if present
VERSION="${VERSION#v}"

validate_version "$VERSION" || fail "Invalid version: $VERSION (expected X.Y.Z)"

if [ "$VERSION" = "$CURRENT_VERSION" ]; then
    fail "New version is the same as current ($CURRENT_VERSION)"
fi

TAG="${BINARY}-v${VERSION}"

printf "\n"
info "Will release: ${BOLD}${BINARY} v${VERSION}${RESET}"
info "Tag:          ${BOLD}${TAG}${RESET}"
info "Cargo.toml:   ${BOLD}${CURRENT_VERSION} → ${VERSION}${RESET}"

# ─── Dry run bail ───────────────────────────────────────────────────────────

if [ "$DRY_RUN" = "1" ]; then
    printf "\n${YELLOW}DRY RUN${RESET} — would execute:\n\n"
    printf "  1. Update %s version %s → %s\n" "$CARGO_TOML" "$CURRENT_VERSION" "$VERSION"
    printf "  2. cd %s && git add Cargo.toml && git commit\n" "${WORKSPACE}/${SOURCE_DIR}"
    printf "  3. git push\n"
    printf "  4. cd %s && git tag %s && git push origin %s\n" "$DIST_DIR" "$TAG" "$TAG"
    printf "\n"
    exit 0
fi

# ─── Confirm ────────────────────────────────────────────────────────────────

printf "\n"
ask "Proceed? [Y/n]"
read -r confirm
case "$confirm" in
    n|N|no|No) echo "Aborted."; exit 0 ;;
esac

# ─── Step 3: Update Cargo.toml ─────────────────────────────────────────────

printf "\n"
info "Updating Cargo.toml..."

# Replace the first version line only (portable — works on macOS and Linux)
awk -v old="$CURRENT_VERSION" -v new="$VERSION" '
    !done && /^version = "/ { sub("version = \"" old "\"", "version = \"" new "\""); done=1 }
    { print }
' "$CARGO_TOML" > "${CARGO_TOML}.tmp" && mv "${CARGO_TOML}.tmp" "$CARGO_TOML"

# Verify the change
NEW_VERSION=$(cargo_version "$CARGO_TOML")
if [ "$NEW_VERSION" != "$VERSION" ]; then
    fail "Cargo.toml update failed (got $NEW_VERSION, expected $VERSION)"
fi
ok "Cargo.toml updated: ${CURRENT_VERSION} → ${VERSION}"

# ─── Step 4: Update Cargo.lock ─────────────────────────────────────────────

info "Updating Cargo.lock..."
(cd "${WORKSPACE}/${SOURCE_DIR}" && /Users/bsneed/.cargo/bin/cargo check --quiet 2>/dev/null) || true
ok "Cargo.lock updated"

# ─── Step 5: Commit + push ─────────────────────────────────────────────────

info "Committing version bump..."
(
    cd "${WORKSPACE}/${SOURCE_DIR}"
    git add Cargo.toml Cargo.lock
    git commit -m "Bump ${BINARY} to v${VERSION}" --quiet
)
ok "Committed"

info "Pushing to origin..."
(cd "${WORKSPACE}/${SOURCE_DIR}" && git push --quiet)
ok "Pushed"

# ─── Step 6: Tag + push (in dist repo) ─────────────────────────────────────

info "Creating release tag ${TAG}..."
(
    cd "$DIST_DIR"
    git tag "$TAG"
)
ok "Tag created"

info "Pushing tag to trigger CI..."
(cd "$DIST_DIR" && git push origin "$TAG" --quiet)
ok "Tag pushed — CI workflow triggered"

# ─── Step 7: Watch CI ──────────────────────────────────────────────────────

printf "\n"
ask "Watch the CI workflow? [Y/n]"
read -r watch_choice
case "$watch_choice" in
    n|N|no|No)
        printf "\n  ${DIM}Watch later: gh run watch --repo ${DIST_REPO}${RESET}\n"
        printf "  ${DIM}Releases:    https://github.com/${DIST_REPO}/releases${RESET}\n\n"
        ;;
    *)
        printf "\n"
        info "Waiting for workflow to start..."
        sleep 5

        RUN_ID=$(gh run list --repo "$DIST_REPO" --limit 5 --json databaseId,headBranch \
            --jq ".[] | select(.headBranch == \"${TAG}\") | .databaseId" 2>/dev/null | head -1)

        if [ -n "$RUN_ID" ]; then
            info "Watching workflow run ${RUN_ID}..."
            gh run watch "$RUN_ID" --repo "$DIST_REPO" --exit-status

            printf "\n"
            ok "Release ${BOLD}${BINARY} v${VERSION}${RESET} published!"
            printf "\n  ${DIM}https://github.com/${DIST_REPO}/releases/tag/${TAG}${RESET}\n\n"
        else
            warn "Could not find workflow run for tag ${TAG}"
            printf "  ${DIM}Check: https://github.com/${DIST_REPO}/actions${RESET}\n\n"
        fi
        ;;
esac
