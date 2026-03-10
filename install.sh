#!/bin/sh
# memoryco install script
# Usage: curl -fsSL https://memoryco.ai/install.sh | sh
#
# Detects OS and architecture, downloads the appropriate binary,
# and installs it to ~/.local/bin (or /usr/local/bin with sudo).
#
# Environment variables:
#   MEMORYCO_VERSION  - specific version to install (default: latest)
#   MEMORYCO_DIR      - install directory (default: ~/.local/bin)
#   MEMORYCO_BASE_URL - override download base URL

set -e

# ─── Configuration ──────────────────────────────────────────────────────────

REPO="MemoryCo/memoryco"
BINARY_NAME="memoryco"
DEFAULT_INSTALL_DIR="$HOME/.local/bin"

BASE_URL="${MEMORYCO_BASE_URL:-https://github.com/${REPO}/releases}"
INSTALL_DIR="${MEMORYCO_DIR:-$DEFAULT_INSTALL_DIR}"

# Companion binaries are released from the dist repo
RELEASES_BASE_URL="${MEMORYCO_BASE_URL:-https://github.com/MemoryCo/memoryco/releases}"

# ─── Colors (if terminal supports them) ─────────────────────────────────────

if [ -t 2 ]; then
    RED=$(printf '\033[0;31m')
    GREEN=$(printf '\033[0;32m')
    YELLOW=$(printf '\033[0;33m')
    BLUE=$(printf '\033[0;34m')
    DIM=$(printf '\033[0;90m')
    BOLD=$(printf '\033[1m')
    RESET=$(printf '\033[0m')
else
    RED='' GREEN='' YELLOW='' BLUE='' DIM='' BOLD='' RESET=''
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

info()  { printf "${BLUE}▸${RESET} %s\n" "$1" >&2; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1" >&2; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$1" >&2; }
fail()  { printf "${RED}✗${RESET} %s\n" "$1" >&2; exit 1; }

# ─── Detect platform ────────────────────────────────────────────────────────

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        *)       fail "Unsupported operating system: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64" ;;
        arm64|aarch64) echo "aarch64" ;;
        *)             fail "Unsupported architecture: $(uname -m)" ;;
    esac
}

detect_target() {
    local os="$1"
    local arch="$2"

    case "${arch}-${os}" in
        aarch64-darwin) echo "aarch64-apple-darwin" ;;
        x86_64-darwin)  fail "Intel Mac is not supported. macOS requires Apple Silicon (M1+)." ;;
        x86_64-linux)   echo "x86_64-unknown-linux-gnu" ;;
        aarch64-linux)  echo "aarch64-unknown-linux-gnu" ;;
        *)              fail "Unsupported platform: ${arch}-${os}" ;;
    esac
}

# ─── Detect download tool ───────────────────────────────────────────────────

detect_downloader() {
    if command -v curl > /dev/null 2>&1; then
        echo "curl"
    elif command -v wget > /dev/null 2>&1; then
        echo "wget"
    else
        fail "Neither curl nor wget found. Please install one and try again."
    fi
}

download() {
    local url="$1"
    local output="$2"

    case "$DOWNLOADER" in
        curl) curl -fsSL --progress-bar -o "$output" "$url" ;;
        wget) wget -q --show-progress -O "$output" "$url" ;;
    esac
}

# Fetch text content (for version detection)
fetch() {
    local url="$1"

    case "$DOWNLOADER" in
        curl) curl -fsSL "$url" ;;
        wget) wget -qO- "$url" ;;
    esac
}

# ─── Version resolution ─────────────────────────────────────────────────────

resolve_version() {
    if [ -n "$MEMORYCO_VERSION" ]; then
        # Strip leading 'v' if present for consistency, then add it back
        echo "v${MEMORYCO_VERSION#v}"
        return
    fi

    info "Fetching latest version..."

    # GitHub redirects /latest to the actual tag URL
    local latest_url="${BASE_URL}/latest"
    local resolved

    if [ "$DOWNLOADER" = "curl" ]; then
        resolved=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null)
    else
        resolved=$(wget --max-redirect=0 -q -O /dev/null --server-response "$latest_url" 2>&1 \
            | grep -i "Location:" | tail -1 | awk '{print $2}' | tr -d '\r')
    fi

    if [ -z "$resolved" ]; then
        fail "Could not determine latest version. Set MEMORYCO_VERSION and try again."
    fi

    # Extract tag from URL: .../releases/tag/v1.0.0 -> v1.0.0
    echo "$resolved" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9._-]*' | tail -1
}

# ─── Checksum verification ──────────────────────────────────────────────────

verify_checksum() {
    local file="$1"
    local checksums_file="$2"
    local archive_name="$3"

    if [ ! -f "$checksums_file" ]; then
        warn "No checksums file found — skipping verification"
        return 0
    fi

    local expected
    expected=$(grep "$archive_name" "$checksums_file" | awk '{print $1}')

    if [ -z "$expected" ]; then
        warn "No checksum found for $archive_name — skipping verification"
        return 0
    fi

    local actual
    if command -v sha256sum > /dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum > /dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "No sha256 tool found — skipping verification"
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        fail "Checksum verification failed!\n  Expected: ${expected}\n  Got:      ${actual}"
    fi

    ok "Checksum verified"
}

# ─── Companion installers ────────────────────────────────────────────────────
#
# resolve_companion_version BINARY
#   Uses the GitHub releases API to find the latest tag for the given binary.
#   Falls back to MEMORYCO_FS_VERSION / MEMORYCO_AGENTS_VERSION env vars.

resolve_companion_version() {
    local binary="$1"
    local version_override

    case "$binary" in
        memoryco_fs)     version_override="${MEMORYCO_FS_VERSION:-}" ;;
        memoryco_agents) version_override="${MEMORYCO_AGENTS_VERSION:-}" ;;
        *)               version_override="" ;;
    esac

    if [ -n "$version_override" ]; then
        echo "v${version_override#v}"
        return 0
    fi

    info "Fetching latest ${binary} version..."

    local api_url="https://api.github.com/repos/MemoryCo/memoryco/releases"
    local tag

    if [ "$DOWNLOADER" = "curl" ]; then
        tag=$(curl -fsSL "$api_url" 2>/dev/null \
            | grep -o "\"tag_name\" *: *\"${binary}-v[^\"]*\"" \
            | head -1 \
            | grep -oE "${binary}-v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9._-]*")
    else
        tag=$(wget -qO- "$api_url" 2>/dev/null \
            | grep -o "\"tag_name\" *: *\"${binary}-v[^\"]*\"" \
            | head -1 \
            | grep -oE "${binary}-v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9._-]*")
    fi

    if [ -z "$tag" ]; then
        return 1
    fi

    echo "v${tag##*-v}"
}

# install_companion_binary BINARY
#   Downloads, verifies, and installs a companion binary into INSTALL_DIR.
#   Runs in a subshell so failures don't abort the parent script.

install_companion_binary() {
    local binary="$1"
    local companion_version

    companion_version=$(resolve_companion_version "$binary") || {
        warn "Could not determine latest version for ${binary} — skipping"
        return 0
    }

    info "Version:  ${BOLD}${companion_version}${RESET}"

    local archive_name="${binary}-${companion_version}-${TARGET}.tar.gz"
    local checksums_name="${binary}-${companion_version}-checksums.sha256"
    local download_url="${RELEASES_BASE_URL}/download/${companion_version}/${archive_name}"
    local checksums_url="${RELEASES_BASE_URL}/download/${companion_version}/${checksums_name}"

    local tmp
    tmp=$(mktemp -d)
    # Clean up on exit from this subshell
    trap 'rm -rf "$tmp"' EXIT

    info "Downloading ${archive_name}..."
    download "$download_url" "${tmp}/${archive_name}" 2>/dev/null || {
        warn "Download of ${binary} failed — skipping"
        return 0
    }

    download "$checksums_url" "${tmp}/${checksums_name}" 2>/dev/null || true
    verify_checksum "${tmp}/${archive_name}" "${tmp}/${checksums_name}" "$archive_name"

    info "Extracting..."
    tar xzf "${tmp}/${archive_name}" -C "$tmp"

    local bin_path
    bin_path=$(find "$tmp" -name "$binary" -type f -perm -u+x 2>/dev/null | head -1)
    if [ -z "$bin_path" ]; then
        bin_path=$(find "$tmp" -name "$binary" -type f | head -1)
    fi

    if [ -z "$bin_path" ]; then
        warn "Could not find ${binary} binary in archive — skipping"
        return 0
    fi

    chmod +x "$bin_path"

    if [ -w "$INSTALL_DIR" ]; then
        mv "$bin_path" "${INSTALL_DIR}/${binary}"
    else
        sudo mv "$bin_path" "${INSTALL_DIR}/${binary}"
    fi

    ok "Installed ${binary} to ${BOLD}${INSTALL_DIR}/${binary}${RESET}"

    # Configure MCP clients
    "${INSTALL_DIR}/${binary}" install --yes 2>&1 || true
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    # ── Parse arguments ───────────────────────────────────────────────────
    WITH_FS=0
    WITH_AGENTS=0

    for arg in "$@"; do
        case "$arg" in
            --with-fs)     WITH_FS=1 ;;
            --with-agents) WITH_AGENTS=1 ;;
            --all)         WITH_FS=1; WITH_AGENTS=1 ;;
        esac
    done

    printf "\n${BOLD}memoryco${RESET} ${DIM}— cognitive memory for AI${RESET}\n\n"

    # Detect environment
    DOWNLOADER=$(detect_downloader)
    OS=$(detect_os)
    ARCH=$(detect_arch)
    TARGET=$(detect_target "$OS" "$ARCH")
    VERSION=$(resolve_version)

    info "Platform: ${BOLD}${ARCH}-${OS}${RESET} (${TARGET})"
    info "Version:  ${BOLD}${VERSION}${RESET}"

    # Build download URLs
    ARCHIVE_NAME="${BINARY_NAME}-${VERSION}-${TARGET}.tar.gz"
    CHECKSUMS_NAME="${BINARY_NAME}-${VERSION}-checksums.sha256"
    DOWNLOAD_URL="${BASE_URL}/download/${VERSION}/${ARCHIVE_NAME}"
    CHECKSUMS_URL="${BASE_URL}/download/${VERSION}/${CHECKSUMS_NAME}"

    # Create temp directory
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    # Download archive
    info "Downloading ${ARCHIVE_NAME}..."
    download "$DOWNLOAD_URL" "${TMP_DIR}/${ARCHIVE_NAME}" \
        || fail "Download failed. Check that ${VERSION} exists for ${TARGET}."

    # Download and verify checksum
    download "$CHECKSUMS_URL" "${TMP_DIR}/${CHECKSUMS_NAME}" 2>/dev/null || true
    verify_checksum "${TMP_DIR}/${ARCHIVE_NAME}" "${TMP_DIR}/${CHECKSUMS_NAME}" "$ARCHIVE_NAME"

    # Extract
    info "Extracting..."
    tar xzf "${TMP_DIR}/${ARCHIVE_NAME}" -C "$TMP_DIR"

    # Find the binary (might be in a subdirectory)
    local binary_path
    binary_path=$(find "$TMP_DIR" -name "$BINARY_NAME" -type f -perm -u+x 2>/dev/null | head -1)
    if [ -z "$binary_path" ]; then
        # Try without execute bit (tar might not preserve it)
        binary_path=$(find "$TMP_DIR" -name "$BINARY_NAME" -type f | head -1)
    fi

    if [ -z "$binary_path" ]; then
        fail "Could not find ${BINARY_NAME} binary in archive"
    fi

    chmod +x "$binary_path"

    # Install
    mkdir -p "$INSTALL_DIR"

    if [ -w "$INSTALL_DIR" ]; then
        mv "$binary_path" "${INSTALL_DIR}/${BINARY_NAME}"
    else
        info "Requesting sudo to install to ${INSTALL_DIR}..."
        sudo mv "$binary_path" "${INSTALL_DIR}/${BINARY_NAME}"
    fi

    ok "Installed to ${BOLD}${INSTALL_DIR}/${BINARY_NAME}${RESET}"

    # Verify it runs
    if "${INSTALL_DIR}/${BINARY_NAME}" --version > /dev/null 2>&1; then
        local installed_version
        installed_version=$("${INSTALL_DIR}/${BINARY_NAME}" --version 2>/dev/null || echo "unknown")
        ok "${installed_version} is ready"
    else
        ok "Installed successfully"
    fi

    # Check if install dir is in PATH
    case ":$PATH:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            printf "\n"
            warn "${INSTALL_DIR} is not in your PATH"
            printf "\n  Add it to your shell config:\n\n"

            if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
                printf "    ${DIM}echo 'export PATH=\"%s:\$PATH\"' >> ~/.zshrc${RESET}\n" "$INSTALL_DIR"
                printf "    ${DIM}source ~/.zshrc${RESET}\n"
            else
                printf "    ${DIM}echo 'export PATH=\"%s:\$PATH\"' >> ~/.bashrc${RESET}\n" "$INSTALL_DIR"
                printf "    ${DIM}source ~/.bashrc${RESET}\n"
            fi
            ;;
    esac

    # ── First-run setup ──────────────────────────────────────────────────
    # Cache the embedding model so first MCP launch isn't slow.

    printf "\n"
    info "Preparing cognitive engine (first-time only)..."

    if "${INSTALL_DIR}/${BINARY_NAME}" cache 2>/dev/null; then
        ok "Embedding model cached"
    else
        printf "  ${DIM}Embedding model will download on first use${RESET}\n"
    fi

    # Auto-detect and configure MCP clients
    printf "\n"
    info "Detecting MCP clients..."
    "${INSTALL_DIR}/${BINARY_NAME}" install --yes 2>&1 || true

    # Next steps
    printf "\n${DIM}─────────────────────────────────────────${RESET}\n\n"
    printf "  ${BOLD}Quick start:${RESET}\n\n"
    printf "  Your MCP clients have been auto-configured.\n"
    printf "  Just restart your AI client and start chatting.\n\n"
    printf "  Your AI now remembers. ${GREEN}◆${RESET}\n\n"
    printf "  ${DIM}Docs:   https://memoryco.ai/docs${RESET}\n"
    printf "  ${DIM}Data:   ~/.memoryco/${RESET}\n"
    printf "  ${DIM}Health: memoryco doctor${RESET}\n\n"

    # ── Companion installs ────────────────────────────────────────────────
    if [ "$WITH_FS" = "1" ]; then
        printf "${DIM}─────────────────────────────────────────${RESET}\n\n"
        printf "${BOLD}memoryco_fs${RESET} ${DIM}— filesystem tools for AI${RESET}\n\n"
        info "Platform: ${BOLD}${ARCH}-${OS}${RESET} (${TARGET})"
        (install_companion_binary "memoryco_fs") \
            || warn "memoryco_fs installation failed — memoryco is still installed and working"
    fi

    if [ "$WITH_AGENTS" = "1" ]; then
        printf "${DIM}─────────────────────────────────────────${RESET}\n\n"
        printf "${BOLD}memoryco_agents${RESET} ${DIM}— AI agent management${RESET}\n\n"
        info "Platform: ${BOLD}${ARCH}-${OS}${RESET} (${TARGET})"
        (install_companion_binary "memoryco_agents") \
            || warn "memoryco_agents installation failed — memoryco is still installed and working"
    fi
}

main "$@"
