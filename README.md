# setup2

A bash script that sets up an Ubuntu machine for data science and software development.

## Usage

Run as your normal user (not as root or with `sudo`; the script refuses to run as root). The script calls `sudo` itself when needed.

```bash
wget -qO- https://raw.githubusercontent.com/lab1702/setup2/main/install.sh | bash
```

## What it installs

| Section | Packages |
| --- | --- |
| Build tools and C/C++/Fortran | build-essential, gcc, g++, gfortran, cmake |
| Python | python3, python3-pip, python3-venv, python3-dev |
| R | r-base, r-base-dev, r-cran-tidyverse |
| Go | golang |
| Rust | rustup (plus the stable toolchain) |
| Containers | docker.io, docker-buildx, docker-compose-v2 |
| GitHub | git, gh |
| General shell tools | wget, curl, gpg, unzip, ripgrep, fd-find, fzf, tree, dos2unix, starship, shellcheck |
| Web dev | nodejs, npm |
| Data | sqlite3, sqlite3-tools, jq, DuckDB CLI (latest release, in `~/.local/bin`) |
| Fonts | fonts-jetbrains-mono, fonts-jetbrains-mono-web |
| System | openssh-server, btop, nvtop, vim, hx (Helix editor) |

## What else it does

- Runs `apt-get update` and `apt-get full-upgrade` before installing. apt runs without prompts and keeps your existing config files when an upgrade ships new versions of them.
- The upgrade and install wait up to 10 minutes for the package lock if something else (like unattended-upgrades) holds it. `apt-get update` doesn't wait: if another update is running (common right after boot), the script stops, and you can run it again.
- Sets the npm global prefix to `~/.npm-global`, on every run, replacing any other prefix in `~/.npmrc`.
- Adds these lines to `~/.profile` unless that setting is already there (commented-out lines don't count, and `PIP_REQUIRE_VIRTUALENV` set to any value counts and is kept):

  ```bash
  export PIP_REQUIRE_VIRTUALENV=1
  export PATH="$HOME/.npm-global/bin:$PATH"   # skipped if ~/.profile already adds ~/.npm-global/bin
  export PATH="$HOME/go/bin:$PATH"       # skipped if ~/.profile already adds ~/go/bin
  export PATH="$HOME/.cargo/bin:$PATH"   # skipped if ~/.profile already adds ~/.cargo/bin or sources ~/.cargo/env
  export PATH="$HOME/.local/bin:$PATH"   # skipped if ~/.profile already adds ~/.local/bin (Ubuntu's default does)
  ```

- Creates `~/.local/bin` so Ubuntu's default `~/.profile` puts it on your PATH.
- Adds `eval "$(starship init bash)"` to `~/.bashrc` to turn on the starship prompt, unless `~/.bashrc` already initializes starship.
- Warns you if a `~/.bash_profile` or `~/.bash_login` would stop login shells from reading `~/.profile`, either because it doesn't source `~/.profile` or because it can't be read.
- Adds you to the `docker` group so you can run docker without `sudo`.
- Tells you at the end whether a reboot is needed.

The script is safe to run again: it skips `~/.profile` and `~/.bashrc` settings that already exist, leaves those files untouched when there is nothing to add, and updates the stable Rust toolchain and DuckDB to their latest releases.

If `~/.profile` or `~/.bashrc` can't be read or written, the script leaves it as it is and prints a warning instead of stopping.

## Notes

- Log out and back in after the first run for the `docker` group and the `~/.profile` PATH changes to take effect.
- In SSH and console logins, Ubuntu's default `~/.profile` runs `~/.bashrc` before it reaches the PATH lines this script adds at the end, so commands in `~/.bashrc` can't use programs from `~/.npm-global/bin`, `~/go/bin` or `~/.cargo/bin` there. Desktop terminals aren't affected. To fix it, move those PATH lines above the part of `~/.profile` that runs `~/.bashrc`.
- `fd-find` installs its command as `fdfind`.
- Installing `openssh-server` starts SSH on port 22 with password logins allowed.

## Requirements

Ubuntu 26.04 or later (amd64 or arm64). The script checks this and stops before changing anything on other systems.

## License

[MIT](LICENSE)
