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

    # Append lines to a file unless each is already present
    add_lines() {
        local file="$1" line
        shift
        touch "$file"
        for line in "$@"; do
            grep -qxF "$line" "$file" || echo "$line" >> "$file"
        done
    }

    # Environment settings go in ~/.profile so login and non-interactive
    # shells get them too (Ubuntu's .bashrc returns early for those)
    add_lines "$HOME/.profile" \
        'export PIP_REQUIRE_VIRTUALENV=1' \
        'export PATH="$HOME/.npm-global/bin:$PATH"' \
        'export PATH="$HOME/go/bin:$PATH"' \
        'export PATH="$HOME/.cargo/bin:$PATH"' \
        'export PATH="$HOME/.local/bin:$PATH"'

    # Interactive prompt setup goes in ~/.bashrc
    add_lines "$HOME/.bashrc" \
        'eval "$(starship init bash)"'

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

    echo "Done."

    if [[ -f /var/run/reboot-required ]]; then
        echo "A reboot is required to finish applying updates."
    else
        echo "No reboot is required."
    fi
}

main "$@"
