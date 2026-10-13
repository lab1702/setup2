#!/usr/bin/env bash
# Install Ubuntu packages for data science and software development.
set -euo pipefail

# Run apt-get without prompts, keeping existing config files on upgrade.
# Input comes from /dev/null so nothing can read the script when piped to bash.
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@" < /dev/null
}

# Everything runs inside main so bash reads the whole script before running
# any of it (safe for wget | bash, even if the download is cut off).
main() {
    # Per-user setup (rustup, npm, shell config, DuckDB, docker group) must
    # target the real user, not root.
    if [[ $EUID -eq 0 ]]; then
        echo "Run this script as your normal user, not as root or with sudo." >&2
        exit 1
    fi

    PACKAGES=(
        # Build tools and C/C++/Fortran
        build-essential gcc g++ gfortran cmake

        # Python
        python3 python3-pip python3-venv python3-dev

        # R
        r-base r-base-dev

        # Go
        golang

        # Rust
        rustup

        # Containers
        docker.io docker-buildx docker-compose-v2

        # GitHub
        git gh

        # General shell tools
        wget curl gpg unzip ripgrep fd-find fzf tree dos2unix starship shellcheck

        # Web dev
        nodejs npm

        # Data
        sqlite3 sqlite3-tools jq

        # System
        openssh-server btop nvtop vim
    )

    # Use amd64v3-optimized packages if the CPU supports x86-64-v3
    AMD64V3_CONF=/etc/apt/apt.conf.d/99enable-amd64v3
    LD_SO_HELP="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"
    if [[ "$(dpkg --print-architecture)" == "amd64" ]]; then
        if [[ "$LD_SO_HELP" == *"x86-64-v3 (supported"* ]]; then
            if [[ ! -f "$AMD64V3_CONF" ]]; then
                echo 'APT::Architecture-Variants "amd64v3";' | sudo tee "$AMD64V3_CONF" > /dev/null
            fi
            echo "CPU supports x86-64-v3: using amd64v3 packages."
        else
            echo "CPU does not support x86-64-v3: using baseline amd64 packages."
        fi
    fi

    apt_get update
    apt_get full-upgrade
    apt_get install "${PACKAGES[@]}"

    # Install the stable Rust toolchain (rustc, cargo, etc.) for the invoking user
    rustup default stable

    # Install global npm packages under the user's home instead of system dirs
    npm config set prefix "$HOME/.npm-global"

    # Print a file's non-comment lines with surrounding whitespace trimmed
    config_lines() {
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' "$1"
    }

    # Append a line to a file unless it is already there (ignoring comments
    # and surrounding whitespace) or a non-comment line matches the optional
    # extended regex, which catches the same setting written another way
    add_line() {
        local file="$1" line="$2" pattern="${3:-}" content
        touch "$file"
        # Read into a variable: grep -q in a pipeline can SIGPIPE sed and,
        # with pipefail, turn a match into a failure
        content="$(config_lines "$file")"
        if grep -qxF -- "$line" <<< "$content"; then
            return 0
        fi
        if [[ -n "$pattern" ]] && grep -qE -- "$pattern" <<< "$content"; then
            return 0
        fi
        # Make sure the file ends with a newline so the new line stays separate
        if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
            echo >> "$file"
        fi
        printf '%s\n' "$line" >> "$file"
    }

    # Remove every line that exactly matches, rewriting the file in place
    remove_line() {
        local file="$1" line="$2" kept
        grep -qxF -- "$line" "$file" 2> /dev/null || return 0
        kept="$(grep -vxF -- "$line" "$file" || true)"
        if [[ -n "$kept" ]]; then
            printf '%s\n' "$kept" > "$file"
        else
            : > "$file"
        fi
    }

    # Environment settings go in ~/.profile so login and non-interactive
    # shells get them too (Ubuntu's .bashrc returns early for those)
    add_line "$HOME/.profile" 'export PIP_REQUIRE_VIRTUALENV=1' \
        'PIP_REQUIRE_VIRTUALENV='
    add_line "$HOME/.profile" 'export PATH="$HOME/.npm-global/bin:$PATH"' \
        '\.npm-global/bin'
    add_line "$HOME/.profile" 'export PATH="$HOME/go/bin:$PATH"' \
        'HOME/go/bin'
    # rustup's own installer sources ~/.cargo/env instead
    add_line "$HOME/.profile" 'export PATH="$HOME/.cargo/bin:$PATH"' \
        '\.cargo/(bin|env)'

    # Ubuntu's default ~/.profile adds ~/.local/bin, but only if it exists at
    # login, so create it now. Older versions of this script also exported it;
    # drop that line and add it back only if nothing else in ~/.profile does.
    mkdir -p "$HOME/.local/bin"
    LOCAL_BIN_LINE='export PATH="$HOME/.local/bin:$PATH"'
    remove_line "$HOME/.profile" "$LOCAL_BIN_LINE"
    add_line "$HOME/.profile" "$LOCAL_BIN_LINE" 'HOME/\.local/bin'

    # Interactive prompt setup goes in ~/.bashrc
    add_line "$HOME/.bashrc" 'eval "$(starship init bash)"' \
        'starship init bash'

    # Install the latest DuckDB CLI release into ~/bin
    DUCKDB_ARCH="$(dpkg --print-architecture)"
    DUCKDB_TMP="$(mktemp -d)"
    trap 'rm -rf "$DUCKDB_TMP"' EXIT
    mkdir -p "$HOME/bin"
    curl -fsSL -o "$DUCKDB_TMP/duckdb.gz" \
        "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-${DUCKDB_ARCH}.gz"
    gunzip "$DUCKDB_TMP/duckdb.gz"
    install -m 755 "$DUCKDB_TMP/duckdb" "$HOME/bin/duckdb"
    echo "Installed $("$HOME/bin/duckdb" --version) to $HOME/bin/duckdb"

    # Let the invoking user run docker without sudo (takes effect after re-login)
    USER_NAME="$(id -un)"
    sudo usermod -aG docker "$USER_NAME"
    echo "Added $USER_NAME to the docker group. Log out and back in for it to take effect."

    # bash login shells read only the first of these that exists
    for LOGIN_FILE in "$HOME/.bash_profile" "$HOME/.bash_login"; do
        if [[ -f "$LOGIN_FILE" ]]; then
            if ! grep -qs '\.profile' "$LOGIN_FILE"; then
                echo "Warning: $LOGIN_FILE exists and does not source ~/.profile," \
                    "so login shells will miss the PATH changes above." >&2
            fi
            break
        fi
    done

    echo "Done."

    if [[ -f /var/run/reboot-required ]]; then
        echo "A reboot is required to finish applying updates."
    else
        echo "No reboot is required."
    fi
}

main "$@"
