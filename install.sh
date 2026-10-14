#!/usr/bin/env bash
# Install Ubuntu packages for data science and software development.
set -euo pipefail

# Run apt-get without prompts, keeping existing config files on upgrade and
# waiting for the dpkg lock (unattended-upgrades often holds it after boot).
# Input comes from /dev/null so nothing can read the script when piped to bash.
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o DPkg::Lock::Timeout=600 \
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

    local PACKAGES=(
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

    # Use amd64v3-optimized packages if the CPU supports x86-64-v3, and stop
    # using them if it doesn't (e.g. the disk moved to an older machine)
    local AMD64V3_CONF=/etc/apt/apt.conf.d/99enable-amd64v3 LD_SO_HELP
    LD_SO_HELP="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"
    if [[ "$(dpkg --print-architecture)" == "amd64" ]]; then
        if [[ "$LD_SO_HELP" == *"x86-64-v3 (supported"* ]]; then
            if [[ ! -f "$AMD64V3_CONF" ]]; then
                echo 'APT::Architecture-Variants "amd64v3";' | sudo tee "$AMD64V3_CONF" > /dev/null
            fi
            echo "CPU supports x86-64-v3: using amd64v3 packages."
        else
            if [[ -f "$AMD64V3_CONF" ]]; then
                sudo rm -f "$AMD64V3_CONF"
            fi
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
        # Only create a missing file: don't bump the mtime of one we may not change
        [[ -e "$file" ]] || touch "$file"
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

    # Count the non-comment lines of a file that match an extended regex
    count_matches() {
        local content
        content="$(config_lines "$1")"
        grep -cE -- "$2" <<< "$content" || true
    }

    # Remove every line that exactly matches, rewriting the file in place.
    # -a keeps grep printing lines when the file has bytes it considers
    # binary (a NUL or non-UTF-8 text); otherwise those lines would be lost.
    # Leave the file alone if removing the line would stop it parsing, e.g.
    # when the line was the only command inside an if block. Only compare
    # against the original: bash -n can reject files that source fine (say,
    # ones that enable extglob), and those must not block the removal.
    remove_line() {
        local file="$1" line="$2" kept
        grep -aqxF -- "$line" "$file" 2> /dev/null || return 0
        kept="$(grep -avxF -- "$line" "$file" || true)"
        if bash -n "$file" 2> /dev/null && ! bash -n <<< "$kept" 2> /dev/null; then
            echo "Warning: not removing '$line' from $file because the rest" \
                "of the file would not parse without it." >&2
            return 0
        fi
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
    # Match only PATH assignments: a GOBIN or GOPATH line doesn't add it
    add_line "$HOME/.profile" 'export PATH="$HOME/go/bin:$PATH"' \
        '(^|[[:space:];])PATH\+?=.*((HOME\}?|~|/home/[^/]+)/go/bin|go env GOPATH)'
    # rustup's own installer sources ~/.cargo/env instead
    add_line "$HOME/.profile" 'export PATH="$HOME/.cargo/bin:$PATH"' \
        '\.cargo/(bin|env)'

    # Ubuntu's default ~/.profile adds ~/.local/bin, but only if it exists at
    # login, so create it now. Older versions of this script also exported it;
    # drop that line when something else in ~/.profile already adds the
    # directory, and add it only if nothing does. Match only PATH assignments,
    # not other lines that mention the directory (like Ubuntu's -d test).
    mkdir -p "$HOME/.local/bin"
    local LOCAL_BIN_LINE='export PATH="$HOME/.local/bin:$PATH"'
    local LOCAL_BIN_PATTERN='(^|[[:space:];])PATH\+?=.*(HOME\}?|~|/home/[^/]+)/\.local/bin'
    if (( $(count_matches "$HOME/.profile" "$LOCAL_BIN_PATTERN") > 1 )); then
        remove_line "$HOME/.profile" "$LOCAL_BIN_LINE"
    fi
    add_line "$HOME/.profile" "$LOCAL_BIN_LINE" "$LOCAL_BIN_PATTERN"

    # bash login shells read only the first of these that exists, so if it
    # doesn't source ~/.profile (or link to it), the settings above never
    # reach them
    local LOGIN_FILE PROFILE_IS_READ=1
    for LOGIN_FILE in "$HOME/.bash_profile" "$HOME/.bash_login"; do
        if [[ -f "$LOGIN_FILE" ]]; then
            if [[ ! "$LOGIN_FILE" -ef "$HOME/.profile" ]] &&
                (( $(count_matches "$LOGIN_FILE" '\.profile') == 0 )); then
                PROFILE_IS_READ=0
                echo "Warning: $LOGIN_FILE exists and does not source ~/.profile," \
                    "so login shells will miss the settings added to ~/.profile." >&2
            fi
            break
        fi
    done

    # Older versions of this script put these settings in ~/.bashrc instead.
    # Now that ~/.profile covers them, drop those exact lines so interactive
    # shells don't add each directory to PATH twice. Keep them when login
    # shells skip ~/.profile, because ~/.bashrc is then the only place they
    # work, and when ~/.bashrc is the same file as ~/.profile.
    if (( PROFILE_IS_READ )) && [[ ! "$HOME/.bashrc" -ef "$HOME/.profile" ]]; then
        local OLD_BASHRC_LINE BASHRC_BEFORE
        BASHRC_BEFORE="$(cat "$HOME/.bashrc" 2> /dev/null || true)"
        for OLD_BASHRC_LINE in \
            'export PIP_REQUIRE_VIRTUALENV=1' \
            'export PATH="$HOME/.npm-global/bin:$PATH"' \
            'export PATH="$HOME/go/bin:$PATH"' \
            'export PATH="$HOME/.cargo/bin:$PATH"' \
            "$LOCAL_BIN_LINE"; do
            remove_line "$HOME/.bashrc" "$OLD_BASHRC_LINE"
        done
        # Until the user logs in again, new terminals only see ~/.bashrc
        if [[ "$(cat "$HOME/.bashrc" 2> /dev/null || true)" != "$BASHRC_BEFORE" ]]; then
            echo "Moved settings from ~/.bashrc to ~/.profile." \
                "Log out and back in for new terminals to pick them up."
        fi
    fi

    # Interactive prompt setup goes in ~/.bashrc
    add_line "$HOME/.bashrc" 'eval "$(starship init bash)"' \
        'starship init bash'

    # Install the latest DuckDB CLI release into ~/.local/bin
    local DUCKDB_ARCH
    DUCKDB_ARCH="$(dpkg --print-architecture)"
    # Global, not local: the EXIT trap runs after main returns
    DUCKDB_TMP="$(mktemp -d)"
    trap 'rm -rf "$DUCKDB_TMP"' EXIT
    curl -fsSL -o "$DUCKDB_TMP/duckdb.gz" \
        "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-${DUCKDB_ARCH}.gz"
    gunzip "$DUCKDB_TMP/duckdb.gz"
    install -m 755 "$DUCKDB_TMP/duckdb" "$HOME/.local/bin/duckdb"
    echo "Installed $("$HOME/.local/bin/duckdb" --version) to $HOME/.local/bin/duckdb"
    # Older versions of this script installed it into ~/bin
    rm -f "$HOME/bin/duckdb"

    # Let the invoking user run docker without sudo (takes effect after re-login)
    local USER_NAME
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
