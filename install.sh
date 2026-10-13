#!/usr/bin/env bash
# Install Ubuntu packages for data science and software development.
set -euo pipefail

# Run apt-get without prompts, keeping existing config files on upgrade.
# Input comes from /dev/null so nothing can read the script when piped to bash.
apt_get() {
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@" < /dev/null
}

# Everything runs inside main so bash reads the whole script before running
# any of it (safe for curl | bash, even if the download is cut off).
main() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
    else
        SUDO="sudo"
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
        wget curl gpg unzip ripgrep fd-find fzf tree dos2unix starship

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
    if [[ "$(dpkg --print-architecture)" == "amd64" && "$LD_SO_HELP" == *"x86-64-v3 (supported"* ]]; then
        if [[ ! -f "$AMD64V3_CONF" ]]; then
            echo 'APT::Architecture-Variants "amd64v3";' | $SUDO tee "$AMD64V3_CONF" > /dev/null
            echo "CPU supports x86-64-v3: enabled amd64v3 packages."
        fi
    else
        echo "CPU does not support x86-64-v3: using baseline amd64 packages."
    fi

    apt_get update
    apt_get full-upgrade
    apt_get install "${PACKAGES[@]}"

    # Install the stable Rust toolchain (rustc, cargo, etc.) for the invoking user
    rustup default stable

    # Install global npm packages under the user's home instead of system dirs
    npm config set prefix "$HOME/.npm-global"

    # Add environment settings to the invoking user's .bashrc if not already present
    BASHRC_LINES=(
        'export PIP_REQUIRE_VIRTUALENV=1'
        'export PATH="$HOME/.npm-global/bin:$PATH"'
        'export PATH="$HOME/go/bin:$PATH"'
        'export PATH="$HOME/.cargo/bin:$PATH"'
        'export PATH="$HOME/.local/bin:$PATH"'
    )
    touch "$HOME/.bashrc"
    for line in "${BASHRC_LINES[@]}"; do
        grep -qxF "$line" "$HOME/.bashrc" || echo "$line" >> "$HOME/.bashrc"
    done

    # Install the latest DuckDB CLI release into ~/bin
    DUCKDB_ARCH="$(dpkg --print-architecture)"
    DUCKDB_TMP="$(mktemp -d)"
    mkdir -p "$HOME/bin"
    curl -fsSL -o "$DUCKDB_TMP/duckdb.gz" \
        "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-${DUCKDB_ARCH}.gz"
    gunzip "$DUCKDB_TMP/duckdb.gz"
    install -m 755 "$DUCKDB_TMP/duckdb" "$HOME/bin/duckdb"
    rm -rf "$DUCKDB_TMP"
    echo "Installed $("$HOME/bin/duckdb" --version) to $HOME/bin/duckdb"

    # Let the invoking user run docker without sudo (takes effect after re-login)
    if [[ $EUID -ne 0 ]]; then
        $SUDO usermod -aG docker "$USER"
        echo "Added $USER to the docker group. Log out and back in for it to take effect."
    fi

    echo "Done."

    if [[ -f /var/run/reboot-required ]]; then
        echo "A reboot is required to finish applying updates."
    else
        echo "No reboot is required."
    fi
}

main "$@"
