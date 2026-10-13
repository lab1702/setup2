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
| R | r-base, r-base-dev |
| Go | golang |
| Rust | rustup (plus the stable toolchain) |
| Containers | docker.io, docker-buildx, docker-compose-v2 |
| GitHub | git, gh |
| General shell tools | wget, curl, gpg, unzip, ripgrep, fd-find, fzf, tree, dos2unix, starship, shellcheck |
| Web dev | nodejs, npm |
| Data | sqlite3, sqlite3-tools, jq, DuckDB CLI (latest release, in `~/.local/bin`) |
| System | openssh-server, btop, nvtop, vim |

## What else it does

- Enables amd64v3-optimized packages on amd64 if the CPU supports x86-64-v3, and disables them if it doesn't.
- Runs `apt-get update` and `apt-get full-upgrade` before installing, waiting up to 10 minutes for the package lock if something else (like unattended-upgrades) holds it.
- Sets the npm global prefix to `~/.npm-global`.
- Adds these lines to `~/.profile` unless that setting is already there (commented-out lines don't count):

  ```bash
  export PIP_REQUIRE_VIRTUALENV=1
  export PATH="$HOME/.npm-global/bin:$PATH"
  export PATH="$HOME/go/bin:$PATH"       # skipped if ~/.profile already adds ~/go/bin
  export PATH="$HOME/.cargo/bin:$PATH"   # skipped if ~/.profile already sources ~/.cargo/env
  export PATH="$HOME/.local/bin:$PATH"   # skipped if ~/.profile already adds ~/.local/bin (Ubuntu's default does)
  ```

- Creates `~/.local/bin` so Ubuntu's default `~/.profile` puts it on your PATH.
- Adds `eval "$(starship init bash)"` to `~/.bashrc` to turn on the starship prompt, unless `~/.bashrc` already initializes starship.
- Warns you if a `~/.bash_profile` or `~/.bash_login` would stop login shells from reading `~/.profile`.
- Adds you to the `docker` group so you can run docker without `sudo`.
- Tells you at the end whether a reboot is needed.

The script is safe to run again: it skips `~/.profile` and `~/.bashrc` settings that already exist, leaves those files untouched when there is nothing to add or remove, removes the `~/.local/bin` line from `~/.profile` that older versions added when Ubuntu's default already covers it, moves the settings that the earliest versions put in `~/.bashrc` to `~/.profile` (removing the old `~/.bashrc` lines, unless login shells skip `~/.profile`), and updates DuckDB to the latest release (removing the old copy in `~/bin` that earlier versions installed).

## Notes

- Log out and back in after the first run for the `docker` group and the `~/.profile` PATH changes to take effect.
- `fd-find` installs its command as `fdfind`.
- Installing `openssh-server` starts SSH on port 22 with password logins allowed.

## Requirements

Ubuntu 26.04 or later (amd64 or arm64).

## License

[MIT](LICENSE)
