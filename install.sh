#!/usr/bin/env bash
# Install Ubuntu packages for data science and software development.
set -euo pipefail

# Run apt-get without prompts, keeping existing config files on upgrade and
# waiting for the dpkg lock (unattended-upgrades often holds it after boot).
# Input comes from /dev/null so apt and the package scripts it runs can never
# stop to wait for input.
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
    # Per-user setup (rustup, npm, shell config, docker group) must
    # target the real user, not root.
    if [[ $EUID -eq 0 ]]; then
        echo "Run this script as your normal user, not as root or with sudo." >&2
        exit 1
    fi

    # Stop before changing anything on a system the package list wasn't
    # written for
    local OS ARCH
    # shellcheck source=/dev/null disable=SC2154
    OS="$( (. /etc/os-release && echo "$ID $VERSION_ID") 2> /dev/null || true)"
    ARCH="$(dpkg --print-architecture 2> /dev/null || true)"
    if [[ "$OS" != "ubuntu "* ]] ||
        ! dpkg --compare-versions "${OS#ubuntu }" ge 26.10 2> /dev/null ||
        [[ "$ARCH" != amd64 && "$ARCH" != arm64 ]]; then
        echo "This script needs Ubuntu 26.10 or later on amd64 or arm64" \
            "(found: ${OS:-unknown OS} on ${ARCH:-unknown architecture})." >&2
        exit 1
    fi

    local PACKAGES=(
        # Build tools and C/C++/Fortran
        build-essential gcc g++ gfortran cmake pkg-config

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

        # Git and GitHub
        git gh

        # General shell tools
        wget curl gpg unzip ripgrep fd-find fzf tree dos2unix starship shellcheck

        # Web dev
        nodejs npm

        # Data
        sqlite3 sqlite3-tools jq duckdb

        # Fonts
        fonts-jetbrains-mono fonts-jetbrains-mono-web fonts-firacode fonts-cascadia-code fonts-hack fonts-inconsolata fonts-ibm-plex fonts-iosevka

        # Editors
        vim hx

        # System
        openssh-server btop nvtop vulkan-tools

        # Media and 3D
        ffmpeg mpv imagemagick sox blender
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
    rustup update

    # Install global npm packages under the user's home instead of system dirs
    if ! npm config set prefix "$HOME/.npm-global"; then
        echo "Warning: could not set the npm prefix to ~/.npm-global." >&2
    fi

    # Print a file's non-comment lines with comments at the end of a line
    # and surrounding whitespace trimmed. Skip alias and env lines: they
    # don't change the shell's own settings, even when they mention one.
    config_lines() {
        sed -e 's/^[[:space:]]*//' -e '/^#/d' -e 's/[[:space:]]#.*$//' \
            -e 's/[[:space:]]*$//' -e '/^alias[[:space:]]/d' \
            -e '/^env[[:space:]]/d' "$1"
    }

    # Append a line to a file unless a non-comment line already equals it
    # (ignoring surrounding whitespace) or matches the optional extended
    # regex, which catches the same setting written another way. Warn
    # instead of failing when the file can't be read or written (say, a
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
        if ! content="$(config_lines "$file" 2> /dev/null)"; then
            echo "Warning: could not read $file to add '$line' to it." >&2
            return 0
        fi
        if grep -qxF -- "$line" <<< "$content" ||
            { [[ -n "$pattern" ]] && grep -qE -- "$pattern" <<< "$content"; }; then
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

    # Environment settings go in ~/.profile, which the login session reads,
    # so everything started from it inherits them, including non-interactive
    # shells (Ubuntu's .bashrc returns early for those).
    #
    # The patterns that catch a directory already added to PATH match only
    # the value of a PATH assignment, as one of its :-separated entries, not
    # other lines that mention the directory (a GOBIN line, Ubuntu's -d
    # test) or text after the value (a later command, a command substitution
    # that removes the directory). They match the directory itself, not a
    # subdirectory, under $HOME or /home/<user>, not under another variable
    # whose name ends in HOME.
    local ASSIGNS_PATH='(^|[[:space:];])PATH\+?=["'\'']?([^[:space:];&|]*[:"'\''}(])?'
    local IN_HOME='(\$HOME|\$\{HOME\}|~|/home/[^/]+)"?/'
    local DIR_END='/?(["'\'':;}[:space:]]|\$\{?PATH|$)'
    local PIP_LINE='export PIP_REQUIRE_VIRTUALENV=1'
    local PIP_PATTERN='PIP_REQUIRE_VIRTUALENV='
    local NPM_LINE='export PATH="$HOME/.npm-global/bin:$PATH"'
    local NPM_PATTERN="${ASSIGNS_PATH}${IN_HOME}\.npm-global/bin${DIR_END}"
    local GO_LINE='export PATH="$HOME/go/bin:$PATH"'
    # $GOPATH/bin counts too: GOPATH defaults to ~/go, and setting it
    # explicitly and then adding $GOPATH/bin is the common idiom
    local GOPATH_BIN='(\$GOPATH|\$\{GOPATH\})"?/bin'
    local GO_PATTERN="${ASSIGNS_PATH}((${IN_HOME}go/bin|${GOPATH_BIN})${DIR_END}|go env GOPATH)"
    # Sourcing ~/.cargo/env, as rustup's own installer does, also adds it
    local CARGO_LINE='export PATH="$HOME/.cargo/bin:$PATH"'
    local CARGO_PATTERN="${ASSIGNS_PATH}${IN_HOME}\.cargo/bin${DIR_END}|(^|[[:space:];])(\.|source)[[:space:]]+[^[:space:];&|]*\.cargo/env[\"']?([[:space:];&|)}]|$)"
    add_line "$HOME/.profile" "$PIP_LINE" "$PIP_PATTERN"
    add_line "$HOME/.profile" "$NPM_LINE" "$NPM_PATTERN"
    add_line "$HOME/.profile" "$GO_LINE" "$GO_PATTERN"
    add_line "$HOME/.profile" "$CARGO_LINE" "$CARGO_PATTERN"

    # Ubuntu's default ~/.profile adds ~/.local/bin, but only if it exists at
    # login, so create it now, and add it only if nothing in ~/.profile does
    mkdir -p "$HOME/.local/bin"
    add_line "$HOME/.profile" 'export PATH="$HOME/.local/bin:$PATH"' \
        "${ASSIGNS_PATH}${IN_HOME}\.local/bin${DIR_END}"

    # bash login shells read only the first of these that exists, so if it
    # doesn't source ~/.profile (or link to it), the settings above never
    # reach them. Only a line that sources it counts, not any mention of it.
    # One bash can't read (say, a directory or mode 000) still stops it.
    local LOGIN_FILE LOGIN_CONTENT
    local SOURCES_PROFILE='(^|[[:space:];&|{(])(\.|source)[[:space:]]+["'\'']?(\$HOME|\$\{HOME\}|~|/home/[^/]+)["'\'']?/\.profile["'\'']?([[:space:];&|)}]|$)'
    for LOGIN_FILE in "$HOME/.bash_profile" "$HOME/.bash_login"; do
        [[ -e "$LOGIN_FILE" ]] || continue
        if [[ ! "$LOGIN_FILE" -ef "$HOME/.profile" ]]; then
            if ! LOGIN_CONTENT="$(config_lines "$LOGIN_FILE" 2> /dev/null)"; then
                echo "Warning: $LOGIN_FILE can't be read, so login shells stop" \
                    "at it and skip all of ~/.profile. Fix or remove it." >&2
            elif ! grep -qE -- "$SOURCES_PROFILE" <<< "$LOGIN_CONTENT"; then
                echo "Warning: $LOGIN_FILE exists and does not source ~/.profile," \
                    "so login shells will miss the settings added to ~/.profile." >&2
            fi
        fi
        break
    done

    # Interactive prompt setup goes in ~/.bashrc
    add_line "$HOME/.bashrc" 'eval "$(starship init bash)"' \
        'starship init bash'

    echo "Done."

    if [[ -f /var/run/reboot-required ]]; then
        echo "A reboot is required to finish applying updates."
    else
        echo "No reboot is required."
    fi
}

main "$@"
