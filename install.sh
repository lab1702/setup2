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

    # Stop before changing anything on a system the package list (and the
    # DuckDB download) wasn't written for
    local OS ARCH
    # shellcheck source=/dev/null disable=SC2154
    OS="$( (. /etc/os-release && echo "$ID $VERSION_ID") 2> /dev/null || true)"
    ARCH="$(dpkg --print-architecture 2> /dev/null || true)"
    if [[ "$OS" != "ubuntu "* ]] ||
        ! dpkg --compare-versions "${OS#ubuntu }" ge 26.04 2> /dev/null ||
        [[ "$ARCH" != amd64 && "$ARCH" != arm64 ]]; then
        echo "This script needs Ubuntu 26.04 or later on amd64 or arm64" \
            "(found: ${OS:-unknown OS} on ${ARCH:-unknown architecture})." >&2
        exit 1
    fi

    local PACKAGES=(
        # Build tools and C/C++/Fortran
        build-essential gcc g++ gfortran cmake

        # Python
        python3 python3-pip python3-venv python3-dev

        # R
        r-base r-base-dev r-cran-tidyverse

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

        # Fonts
        fonts-jetbrains-mono fonts-jetbrains-mono-web

        # System
        openssh-server btop nvtop vim hx
    )

    apt_get update
    apt_get full-upgrade
    apt_get install "${PACKAGES[@]}"

    # Let the invoking user run docker without sudo (takes effect after re-login).
    # Do it right after the apt steps, while sudo still has the password cached,
    # so a long install doesn't leave the script waiting for it at the end
    local USER_NAME
    USER_NAME="$(id -un)"
    sudo usermod -aG docker "$USER_NAME"
    echo "Added $USER_NAME to the docker group. Log out and back in for it to take effect."

    # Install the stable Rust toolchain (rustc, cargo, etc.) for the invoking user
    rustup default stable

    # Install global npm packages under the user's home instead of system dirs
    npm config set prefix "$HOME/.npm-global"

    # Print a file's non-comment lines with comments at the end of a line
    # and surrounding whitespace trimmed
    config_lines() {
        sed -e 's/^[[:space:]]*//' -e '/^#/d' -e 's/[[:space:]]#.*$//' \
            -e 's/[[:space:]]*$//' "$1"
    }

    # Append a line to a file unless it is already there (ignoring comments
    # and surrounding whitespace) or a non-comment line matches the optional
    # extended regex, which catches the same setting written another way.
    # Warn instead of failing when the file can't be written (say, a
    # read-only file that a dotfile manager links to).
    add_line() {
        local file="$1" line="$2" pattern="${3:-}" content newline=''
        # Only create a missing file: don't bump the mtime of one we may not change
        if [[ ! -e "$file" ]] && ! touch "$file" 2> /dev/null; then
            echo "Warning: could not create $file to add '$line' to it." >&2
            return 0
        fi
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
            newline=$'\n'
        fi
        if ! printf '%s%s\n' "$newline" "$line" 2> /dev/null >> "$file"; then
            echo "Warning: could not add '$line' to $file." >&2
        fi
    }

    # Count the non-comment lines of a file that match an extended regex
    count_matches() {
        local content
        content="$(config_lines "$1")"
        grep -cE -- "$2" <<< "$content" || true
    }

    # Remove every line that exactly matches, rewriting the file in place
    # (through a symlink, keeping its permissions). -a keeps grep printing
    # lines when the file has bytes it considers binary (a NUL or non-UTF-8
    # text), and a temp file rather than a variable keeps NULs and trailing
    # blank lines. Leave the file alone, with a warning, if it can't be
    # written or removing the line would change what the rest of it does:
    # - the line before continues onto it (ends in &&, ||, | or \), so the
    #   next command would take its place;
    # - the rest would stop parsing, e.g. when the line was the only command
    #   inside an if block. Parse with extglob on, as files that enable it
    #   use its patterns, and only compare against the original: bash -n can
    #   reject files that source fine, and those must not block the removal.
    remove_line() {
        local file="$1" line="$2" kept status=0
        grep -aqxF -- "$line" "$file" 2> /dev/null || return 0
        if LINE="$line" awk '
            $0 == ENVIRON["LINE"] && prev ~ /(&&|\||\\)[[:space:]]*$/ { found = 1 }
            $0 !~ /^[[:space:]]*$/ { prev = $0 }
            END { exit !found }' "$file"; then
            echo "Warning: not removing '$line' from $file because the line" \
                "before it continues onto it." >&2
            return 0
        fi
        kept="$(mktemp)"
        grep -avxF -- "$line" "$file" > "$kept" || status=$?
        if (( status > 1 )); then
            echo "Warning: could not read $file to remove '$line' from it." >&2
        elif bash -O extglob -n "$file" 2> /dev/null &&
            ! bash -O extglob -n "$kept" 2> /dev/null; then
            echo "Warning: not removing '$line' from $file because the rest" \
                "of the file would not parse without it." >&2
        elif ! cat "$kept" 2> /dev/null > "$file"; then
            echo "Warning: could not remove '$line' from $file." >&2
        fi
        rm -f "$kept"
    }

    # Environment settings go in ~/.profile so login and non-interactive
    # shells get them too (Ubuntu's .bashrc returns early for those)
    # The patterns that catch a directory already added to PATH match only
    # PATH assignments, not other lines that mention the directory (a GOBIN
    # line, an alias, Ubuntu's -d test) or a later command on the same line.
    # They match the directory itself, not a subdirectory, and only under
    # $HOME, not under another variable whose name ends in HOME.
    local ASSIGNS_PATH='(^|[[:space:];])PATH\+?=[^;]*'
    local IN_HOME='(\$HOME|\$\{HOME\}|~|/home/[^/]+)"?/'
    local DIR_END='/?(["'\'':;}$[:space:]]|$)'
    add_line "$HOME/.profile" 'export PIP_REQUIRE_VIRTUALENV=1' \
        'PIP_REQUIRE_VIRTUALENV='
    add_line "$HOME/.profile" 'export PATH="$HOME/.npm-global/bin:$PATH"' \
        "${ASSIGNS_PATH}${IN_HOME}\.npm-global/bin${DIR_END}"
    add_line "$HOME/.profile" 'export PATH="$HOME/go/bin:$PATH"' \
        "${ASSIGNS_PATH}(${IN_HOME}go/bin${DIR_END}|go env GOPATH)"
    # Sourcing ~/.cargo/env, as rustup's own installer does, also adds it
    add_line "$HOME/.profile" 'export PATH="$HOME/.cargo/bin:$PATH"' \
        "${ASSIGNS_PATH}${IN_HOME}\.cargo/bin${DIR_END}|(^|[[:space:];])(\.|source)[[:space:]][^;]*\.cargo/env"

    # Ubuntu's default ~/.profile adds ~/.local/bin, but only if it exists at
    # login, so create it now. Older versions of this script also exported it;
    # drop that line when something else in ~/.profile already adds the
    # directory, and add it only if nothing does.
    mkdir -p "$HOME/.local/bin"
    local LOCAL_BIN_LINE='export PATH="$HOME/.local/bin:$PATH"'
    local LOCAL_BIN_PATTERN="${ASSIGNS_PATH}${IN_HOME}\.local/bin${DIR_END}"
    if (( $(count_matches "$HOME/.profile" "$LOCAL_BIN_PATTERN") > 1 )); then
        remove_line "$HOME/.profile" "$LOCAL_BIN_LINE"
    fi
    add_line "$HOME/.profile" "$LOCAL_BIN_LINE" "$LOCAL_BIN_PATTERN"

    # bash login shells read only the first of these that exists, so if it
    # doesn't source ~/.profile (or link to it), the settings above never
    # reach them. Only a line that sources it counts, not any mention of it.
    local LOGIN_FILE PROFILE_IS_READ=1
    local SOURCES_PROFILE='(^|[[:space:];&|{(])(\.|source)[[:space:]]+["'\'']?(\$HOME|\$\{HOME\}|~|/home/[^/]+)["'\'']?/\.profile["'\'']?([[:space:];&|)}]|$)'
    for LOGIN_FILE in "$HOME/.bash_profile" "$HOME/.bash_login"; do
        if [[ -f "$LOGIN_FILE" ]]; then
            if [[ ! "$LOGIN_FILE" -ef "$HOME/.profile" ]] &&
                (( $(count_matches "$LOGIN_FILE" "$SOURCES_PROFILE") == 0 )); then
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
    # work, when ~/.bashrc is the same file as ~/.profile, and when
    # ~/.profile can't be written, as the settings may not have reached it.
    if (( PROFILE_IS_READ )) && [[ -w "$HOME/.profile" ]] &&
        [[ ! "$HOME/.bashrc" -ef "$HOME/.profile" ]]; then
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
    # Global, not local: the EXIT trap runs after main returns
    DUCKDB_TMP="$(mktemp -d)"
    trap 'rm -rf "$DUCKDB_TMP"' EXIT
    curl -fsSL -o "$DUCKDB_TMP/duckdb.gz" \
        "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-${ARCH}.gz"
    gunzip "$DUCKDB_TMP/duckdb.gz"
    install -m 755 "$DUCKDB_TMP/duckdb" "$HOME/.local/bin/duckdb"
    # Run it on its own line so set -e stops the script if it doesn't work
    local DUCKDB_VERSION
    DUCKDB_VERSION="$("$HOME/.local/bin/duckdb" --version)"
    echo "Installed $DUCKDB_VERSION to $HOME/.local/bin/duckdb"
    # Older versions of this script installed it into ~/bin
    rm -f "$HOME/bin/duckdb"

    echo "Done."

    if [[ -f /var/run/reboot-required ]]; then
        echo "A reboot is required to finish applying updates."
    else
        echo "No reboot is required."
    fi
}

main "$@"
