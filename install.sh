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
    # Per-user setup (rustup, npm, shell config, DuckDB, docker group) must
    # target the real user, not root.
    if [[ $EUID -eq 0 ]]; then
        echo "Run this script as your normal user, not as root or with sudo." >&2
        exit 1
    fi

    # Temp files and directories to delete on exit, even when interrupted.
    # Global, not local: the EXIT trap runs after main returns
    CLEANUP=()
    trap 'rm -rf "${CLEANUP[@]}"' EXIT

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
    # and surrounding whitespace trimmed. Skip alias and env lines: they
    # don't change the shell's own settings, even when they mention one.
    config_lines() {
        sed -e 's/^[[:space:]]*//' -e '/^#/d' -e 's/[[:space:]]#.*$//' \
            -e 's/[[:space:]]*$//' -e '/^alias[[:space:]]/d' \
            -e '/^env[[:space:]]/d' "$1"
    }

    # Succeed if a file has a line (ignoring comments and surrounding
    # whitespace), or a non-comment line matches the optional extended
    # regex, which catches the same setting written another way
    has_setting() {
        local file="$1" line="$2" pattern="${3:-}" content
        [[ -e "$file" ]] || return 1
        # Read into a variable: grep -q in a pipeline can SIGPIPE sed and,
        # with pipefail, turn a match into a failure
        content="$(config_lines "$file")"
        grep -qxF -- "$line" <<< "$content" && return 0
        [[ -n "$pattern" ]] && grep -qE -- "$pattern" <<< "$content" && return 0
        return 1
    }

    # Append a line to a file unless has_setting finds it there. Warn
    # instead of failing when the file can't be written (say, a read-only
    # file that a dotfile manager links to).
    add_line() {
        local file="$1" line="$2" pattern="${3:-}" newline=''
        # Only create a missing file: don't bump the mtime of one we may not change
        if [[ ! -e "$file" ]] && ! touch "$file" 2> /dev/null; then
            echo "Warning: could not create $file to add '$line' to it." >&2
            return 0
        fi
        if has_setting "$file" "$line" "$pattern"; then
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

    # Remove every line that exactly matches. Write the rest to a temp file
    # next to the real file (following a symlink), give it the same
    # permissions and rename it over the original, so an interrupted or
    # failed write (Ctrl-C, a full disk) leaves the original as it was.
    # -a keeps grep printing lines when the file has bytes it considers
    # binary (a NUL or non-UTF-8 text). Leave the file alone, with a
    # warning, if it can't be rewritten or removing the line would change
    # what the rest of it does:
    # - the command before continues onto it, so the next command would
    #   take its place: the last line of code before it ends in &&, || or |
    #   (bash skips comments and blank lines in between), or the line right
    #   before it ends in an unescaped backslash;
    # - the rest would stop parsing, e.g. when the line was the only command
    #   inside an if block. Parse with extglob on, as files that enable it
    #   use its patterns, and only compare against the original: bash -n can
    #   reject files that source fine, and those must not block the removal.
    remove_line() {
        local file="$1" line="$2" target kept status=0
        grep -aqxF -- "$line" "$file" 2> /dev/null || return 0
        if LINE="$line" awk '
            {
                if ($0 == ENVIRON["LINE"] && (op || bs)) found = 1
                bs = 0
                s = $0
                sub(/^[[:space:]]+/, "", s)
                if (s == "" || s ~ /^#/) next
                # A backslash only continues a line it ends, outside a comment
                if (!sub(/[[:space:]]+#.*$/, "", s) && match(s, /\\+$/))
                    bs = RLENGTH % 2
                sub(/[[:space:]]+$/, "", s)
                op = s ~ /(&&|\|)$/
            }
            END { exit !found }' "$file"; then
            echo "Warning: not removing '$line' from $file because the line" \
                "before it continues onto it." >&2
            return 0
        fi
        # Renaming needs only the directory to be writable: check the file
        # is too, so a read-only one stays as it is
        target="$(readlink -f -- "$file")"
        if [[ ! -w "$target" ]]; then
            echo "Warning: could not remove '$line' from $file." >&2
            return 0
        fi
        # Queue the temp file for cleanup before creating it, so Ctrl-C
        # can't leave it behind. umask keeps it private until the chmod.
        kept="$target.setup2-tmp"
        CLEANUP+=("$kept")
        (umask 077 && grep -avxF -- "$line" "$file" > "$kept") 2> /dev/null ||
            status=$?
        if (( status > 1 )); then
            echo "Warning: could not remove '$line' from $file." >&2
        elif bash -O extglob -n "$file" 2> /dev/null &&
            ! bash -O extglob -n "$kept" 2> /dev/null; then
            echo "Warning: not removing '$line' from $file because the rest" \
                "of the file would not parse without it." >&2
        elif ! { chmod --reference="$target" "$kept" &&
            mv -f "$kept" "$target"; } 2> /dev/null; then
            echo "Warning: could not remove '$line' from $file." >&2
        fi
        rm -f "$kept"
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
    local GO_PATTERN="${ASSIGNS_PATH}(${IN_HOME}go/bin${DIR_END}|go env GOPATH)"
    # Sourcing ~/.cargo/env, as rustup's own installer does, also adds it
    local CARGO_LINE='export PATH="$HOME/.cargo/bin:$PATH"'
    local CARGO_PATTERN="${ASSIGNS_PATH}${IN_HOME}\.cargo/bin${DIR_END}|(^|[[:space:];])(\.|source)[[:space:]]+[^[:space:];&|]*\.cargo/env[\"']?([[:space:];&|)}]|$)"
    add_line "$HOME/.profile" "$PIP_LINE" "$PIP_PATTERN"
    add_line "$HOME/.profile" "$NPM_LINE" "$NPM_PATTERN"
    add_line "$HOME/.profile" "$GO_LINE" "$GO_PATTERN"
    add_line "$HOME/.profile" "$CARGO_LINE" "$CARGO_PATTERN"

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
    # work, and when ~/.bashrc is the same file as ~/.profile.
    if (( PROFILE_IS_READ )) && [[ ! "$HOME/.bashrc" -ef "$HOME/.profile" ]]; then
        # Check each setting really is in ~/.profile first: adding it can
        # fail even when the file is writable (say, on a full disk)
        drop_from_bashrc() {
            if has_setting "$HOME/.profile" "$1" "$2"; then
                remove_line "$HOME/.bashrc" "$1"
            fi
        }
        local BASHRC_BEFORE
        BASHRC_BEFORE="$(cat "$HOME/.bashrc" 2> /dev/null || true)"
        drop_from_bashrc "$PIP_LINE" "$PIP_PATTERN"
        drop_from_bashrc "$NPM_LINE" "$NPM_PATTERN"
        drop_from_bashrc "$GO_LINE" "$GO_PATTERN"
        drop_from_bashrc "$CARGO_LINE" "$CARGO_PATTERN"
        drop_from_bashrc "$LOCAL_BIN_LINE" "$LOCAL_BIN_PATTERN"
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
    local DUCKDB_TMP
    DUCKDB_TMP="$(mktemp -d)"
    CLEANUP+=("$DUCKDB_TMP")
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
