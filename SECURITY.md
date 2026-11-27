# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use **Report a vulnerability** under this repository's
*Security* tab (GitHub private vulnerability reporting). Say what is affected, how to reproduce it and what an
attacker gains. You will get an answer within a week.

## What to know before exposing the server

- **There is no authentication.** `./serve` listens on 127.0.0.1 by default. If you start it with `--host 0.0.0.0`,
  anyone who can reach the port can use it; put a reverse proxy with authentication in front. In Docker, publish
  the port on 127.0.0.1 (as the README does) unless you put authentication in front.
- **No rate limiting.** One client can occupy the engine.
- At install, the script clones llama.cpp from GitHub, downloads the model weights from Hugging Face over HTTPS, and
  may install build tools with apt or pip. `--bin-url` downloads and runs a prebuilt binary: only use a tarball you
  trust. `--prebuilt` downloads the engine attached to the latest release of this repository and checks it against
  that release's `SHA256SUMS`; the checksum comes from the same release, so it detects a damaged download, not a
  tampered release. `get.sh` (the one-command installer) downloads the sources of a release and runs that
  release's `install.sh --prebuilt`; read it before piping it to a shell if you do not know this project. Nothing is fetched after install.
- **Prompt states on disk.** With resume on (the default), the server keeps up to 8 prefix states built from your
  prompts in `~/.openset-llm/state`. Delete the folder to clear them, or run `./serve --no-resume`.
- Until the first tagged release, only the latest commit on `main` is supported with fixes.
