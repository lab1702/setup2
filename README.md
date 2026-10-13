# setup2

A bash script that sets up an Ubuntu machine for data science and software development.

## Usage

Run as your normal user (not with `sudo`). The script calls `sudo` itself when needed.

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
| General shell tools | wget, curl, gpg, unzip, ripgrep, fd-find, fzf, tree, dos2unix |
| Web dev | nodejs, npm |
| Data | sqlite3, sqlite3-tools, jq, DuckDB CLI (latest release, in `~/bin`) |
| System | openssh-server, btop, nvtop, vim |

## What else it does

- Enables amd64v3-optimized packages if the CPU supports x86-64-v3.
- Runs `apt-get update` and `apt-get full-upgrade` before installing.
- Sets the npm global prefix to `~/.npm-global`.
- Adds these lines to `~/.bashrc` if they are not already there:

  ```bash
  export PIP_REQUIRE_VIRTUALENV=1
  export PATH="$HOME/.npm-global/bin:$PATH"
  export PATH="$HOME/go/bin:$PATH"
  export PATH="$HOME/.cargo/bin:$PATH"
  export PATH="$HOME/.local/bin:$PATH"
  ```

- Adds you to the `docker` group so you can run docker without `sudo`.
- Tells you at the end whether a reboot is needed.

The script is safe to run again: it skips `.bashrc` lines that already exist and updates DuckDB to the latest release.

## Notes

- Log out and back in after the first run for the `docker` group and `~/bin` on your PATH to take effect.
- `fd-find` installs its command as `fdfind`.
- Installing `openssh-server` starts SSH on port 22 with password logins allowed.

## Requirements

Ubuntu 26.04 or later (amd64 or arm64).

## License

[MIT](LICENSE)
