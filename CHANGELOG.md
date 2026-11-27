# Changelog

All notable changes to openset-llm. Dates are YYYY-MM-DD.

## Unreleased

Added

- One-command install: `curl -fsSL https://raw.githubusercontent.com/opensetlabs/openset-llm/main/get.sh | bash`.
  No clone and no compiler: it installs the latest release with its prebuilt engine and adds an `openset-llm`
  command (`openset-llm`, `openset-llm serve`, `check`, `version`, `update`). A failed install leaves the previous
  version in place.
- Container image on every release: publishing a release builds the Dockerfile and pushes
  `ghcr.io/opensetlabs/openset-llm:<tag>` and `:latest`.

## 0.3.3 (2026-11-27)

Install without a compiler: releases now carry a prebuilt engine.

Added

- Prebuilt engine on every release: publishing a release now builds the portable x86-64 engine and attaches
  `openset-llm-linux-x86_64.tar.gz` and `SHA256SUMS` to it. `./install.sh --prebuilt` installs it without a compiler:
  it verifies the checksum and refuses an engine built from other patches or kernels than the checkout. Builds on
  the packaging workflow contributed in #22.
- `docs`: the README and CONTRIBUTING point to the smoke test, the deployment guide and how to run the tests (#136).

Changed

- `install.sh` changed, so the next `./install.sh` rebuilds the engine once.

Thank you to @cioffivictor for the packaging workflow.

## 0.3.2 (2026-11-27)

A small bug-fix release. Speed and the model file are unchanged.

Fixed

- Model grafting: a failed graft no longer truncates an existing output model; the new file is written beside it and
  published with one rename (#91).
- Benchmark grader (`bench/evaluate.py`): binary output from a generated program no longer aborts the batch (#128),
  and backticks inside a fenced Python reply are kept (#129).
- Long-context benchmark (`bench/ctxrun.py`): each job stops its own server process group on every exit, and no longer
  kills other `llama-server` processes on the machine (#133).

Added

- `docs/deployment.md`: giving WSL2 enough memory, and running `./serve` as a systemd user service (#9).

Changed

- The README no longer links to a repository that is not public yet (#132).

Thank you to @Afloat16 and @PhilJHolland for these.

## 0.3.1 (2026-11-27)

A bug-fix release: 20 fixes from the community, no change in speed or in the model file.

Fixed

- Engine: the attention fast path frees its per-thread workspaces when worker threads exit (#100) and keeps
  split-mode scratch inside each graph's own workspace (#103); adaptive speculation depth is bounded before it
  indexes its tables (#117).
- Resume from disk: saved prefix states are invalidated when the model file is replaced (#101), are not used or
  written while a LoRA adapter is active (#116), and a failed save no longer leaves a temporary file behind (#119).
- Model grafting (`scripts/graft_mtp.py`): metadata types and string bytes are kept as they are (#90), big-endian
  files keep their byte order (#102), and an incompatible MTP sidecar is rejected before any output is written (#118).
- `install.sh`: the check for numpy and pyyaml now looks the same way the graft runs, so modules installed with
  `pip install --user` get a venv instead of a failed graft (#78); a native build is staged before it replaces a
  working engine (#109); a cached engine is rebuilt when `install.sh` or `patches/apply.sh` change (#110).
- `./serve` rejects `--ctx`, `--multi`, `--threads`, `--port` and `--spec-depth` values outside the 32-bit range
  the server accepts (#108).
- Benchmark tools: owned server processes are stopped on every exit path (#84, #85); failed or incomplete response
  streams are reported as failures (#86) and left out of identity comparisons (#111); multi-stream ratios are
  compared within one CPU class (#87); a failed phase in `bench/jobs.sh` stays resumable (#106); `main`-guard
  examples inside Python strings are preserved (#107).

Added

- `scripts/smoke-test.sh`, a three-check smoke test for a running server (#24), a `.gitattributes` that keeps LF line endings (#20),
  and a dependabot config for GitHub Actions (#33).

Thank you to @Afloat16, @Johnbjoseph-cybersec, @stevenmessinger, @shivanipoddariiith and @kcalvinaIvin for these
changes.

## 0.3.0 (2026-11-27)

Added

- 256-bit kernels for the ternary weights on CPUs without AVX-512 (AVX2, and AVX-VNNI where the CPU has it): Intel
  Core, 12th gen and newer included, and AMD Zen 1 to 3. `./install.sh` and `--portable` builds pick them by
  themselves; before, these CPUs ran the fork's own kernel. Measured on Ice Lake server VMs with AVX-512 disabled:
  plain decoding 6.1–7.7 tok/s, 3.5× the old path and 0.7× of the AVX-512 path; prompt reading
  6.7× the old path. Speculation stays off by default on these CPUs (it speeds up code and JSON and slows down prose);
  `./serve --spec` turns it on and drafts 2 tokens ahead there. AVX-512 machines are unchanged. See "CPUs without AVX-512" in the README.
- `scripts/verify-dispatch.sh` checks the 256-bit kernels too (alone, inside the AVX-512 build, and in the build for
  AVX-512 CPUs without VNNI); `tests/` gained a kernel test against a scalar reference.

Fixed

- In 0.2.0 and earlier, a `--portable` build could not start on a CPU without AVX-512; the Docker image and
  `--bin-url` binaries are made from that build. Fixed in this release. Found and checked under emulated Haswell and
  Alder Lake CPUs.

Thank you to everyone who told us openset-llm was slow on laptops and desktops without AVX-512. This change is for you.

## 0.2.0 (2026-11-26)

Added

- `./serve --multi N`: a system prompt the streams share is read once and loaded from disk afterwards (the prefix part
  of agent-loop resume; it was off with `--multi`). Same replies as `--no-resume`, no extra memory. `--multi` now
  writes prefix states to `~/.openset-llm/state` like the single-stream server does. (#17)
- `bench/quick.sh`: a 3-minute speed check that prints a block to paste into a "Measurement on my machine" issue. (#7)
- `docker-compose.yml`: `docker compose up` builds the image, keeps the model in a named volume and waits on
  `/health`. (#8)
- `./install.sh --check` is mentioned in the quick start. (#6)
- Unit tests for the installer, `serve`, `start`, the model graft and the benchmark harness (`tests/`,
  `bench/test_*.py`), run by CI.

Fixed: engine and install

- A prefix state file that was cut short on disk (for example by a full disk) made the server abort when a request
  tried to load it. Such a file is now detected, removed and written again. (#17)
- `patches/apply.sh` reported success and carried on after a patch failed to apply. It now stops at the first
  failure. (#36)
- `install.sh --bin-url`: a broken or unusable prebuilt archive no longer replaces a working engine; the new binaries
  are unpacked and checked in a staging folder first. (#72)
- `install.sh`: a download from a mirror that ignores resume requests restarts from the beginning. (#74)
- `install.sh`: checks for git before downloading weights when the speculation head has to be attached (#58), clears
  the plain-model marker after the head is attached (#60), and skips the Python setup when the model is already
  there (#62).
- `scripts/graft_mtp.py`: refuses an output path that is one of its inputs (#68) and keeps the tensor alignment the
  model file declares (#70).
- `./serve`: numbers with leading zeros (`--ctx 08192`) are read as decimal. (#64)
- `./start`: honours `--host` when it waits for the server and opens the page, and does not open a page with
  `--no-webui`. (#66)

Fixed: benchmark harness (no published number changes)

- `bench/quick.sh` exits with an error, and without a report, when a measurement fails. (#54)
- `bench/bench2.py`, `bench/multi.py`: memory samplers stop on every exit path (#38, #56); a failed stream is
  reported; `--rounds` above 3 keeps four prompts per round (#44); an interrupted last result line is repaired on
  resume (#52).
- `bench/rrun.py`: starts and stops only its own server (#46) and fails when the server never becomes ready (#48).
- `bench/evaluate.py`: keeps decorators when grading code (#40) and stops child processes of a timed-out
  program (#50).
- `bench/analyze.py`: load-only probes are listed separately from throughput rows. (#42)

Thanks to Afloat16 for #36–#74, revaldianggara for #6 and recranvvi5c for #8.

## 0.1.0 (2026-11-25)

First public release.

- A 27B LLM (Qwen3.8-27B as PrismML's ternary Bonsai-2-27B) at 17–20 tokens per second on a CPU-only machine with
  8 cores and 8 GB of RAM: new AVX-512 kernels for the ternary weights, speculative decoding with the model's own
  multi-token-prediction head, a fused attention kernel, several requests in one pass (`--multi`), agent-loop resume.
- One-command install and start (`./start`), a chat page, an OpenAI-compatible server (`./serve`), a Dockerfile, and
  the benchmark harness behind every number in the README (`bench/`).
- `./serve --kv6` and `--kv5` (experimental): 6- and 5-bit attention caches. On an 8 GB machine speculation stays on
  to 12k / 16k context and plain decoding reaches 32k / 64k. Not exact; needs AVX-512; see the README's memory section.
- `./serve` refuses two cache flags together and contexts that cannot fit with `--kv6` / `--kv5` under 12 GB.
- LoRA adapters load through `./serve -- --lora <file>` (documented with measured cost; #1, #2).

Known limits: Linux x86-64 only; the fast path needs AVX-512 VNNI + VBMI; one model; measured on cloud VMs
(Intel Ice Lake, AMD Zen 4 / Zen 5). See the README's Limits section.
