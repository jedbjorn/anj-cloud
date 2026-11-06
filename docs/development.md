# Development and testing

## Prerequisites

- Linux x86_64 (the qualified development seat), Python 3.14, Docker (rootless is fine) for the dev stack and
  release packaging.
- For the client: the pinned Flutter 3.47.9 / Dart 3.13.7 SDK, `clang`, `cmake`, `ninja`, `pkg-config`, GTK 3
  and libsecret development packages, and `openssl`.

```bash
# Install the pinned SDK (checksum in .github/workflows/ci.yml) to the default location, or set FLUTTER_SDK:
#   ~/.local/share/anj-cloud/toolchains/flutter-3.47.9
python3 deploy/checks.py --deps     # pinned Python deps into deploy/.local/access-venv, tooling check, locked client packages
```

## Run the checks

```bash
python3 deploy/checks.py            # server tests, then apps/client/tool/check.sh
```

- Python tests only:
  `ANJ_PROFILE=deploy/profile.example.toml deploy/.local/access-venv/bin/python -m unittest discover -s tests`.
  Tests run against the placeholder profile and never read a real one; `deploy/checks.py` sets `ANJ_PROFILE`
  for you.
- Client only: `apps/client/tool/check.sh`: native boundary build, layer checks, `flutter analyze`, then the
  Flutter tests one file at a time.
- Checks that need real devices or hosts are separate: the macOS and Windows seats under
  `apps/client/tool/macos/` and `apps/client/tool/windows*`, the Android emulator and phone runs under
  `apps/client/tool/android/`, and the live-gateway runs in `deploy/`.

CI (`.github/workflows/ci.yml`) runs `apps/client/tool/check.sh` and the seat-independent subset of the Python
tests (`tool/ci_python_tests.py`) on Ubuntu for every pull request (the client run skips nine test files that depend on the seat's filesystem and OpenSSL, via `ANJ_TEST_EXCLUDE` in the workflow). The excluded Python test classes were written
against the maintainer's seat (OpenSSL build, free-space measurements, a pseudo-terminal flow); they are listed in
that script and run with `python3 deploy/checks.py` on a matching seat.

## A development gateway

`deploy/dev.py` runs a synthetic, isolated stack (Nextcloud, PostgreSQL, Redis and the access service) bound to
`127.0.0.1`, with fixture users Alice and Bob. It never touches production.

```bash
export SC_DEV_PORT=8834
python3 deploy/dev.py deps && python3 deploy/dev.py setup && python3 deploy/dev.py up
python3 deploy/dev.py check
python3 deploy/dev.py stop
```

`deploy/README.md` describes the stack, pairing against it, fixtures and cleanup.

## Running a client against it

`apps/client/README.md` explains how to run a disposable profile, the code layout, and the evidence boundaries.
`apps/client/ARCHITECTURE.md` documents the ports and adapters, the native boundary and each platform.

## The deployment profile in development

`deploy/profile.example.toml` holds placeholders and is used when no real profile exists. A client built without a
profile has no release key (so no desktop self-update) and a placeholder server address; type your server in the
pair dialog. To build as your own household, put real values in `~/.local/share/anj-cloud/profile.toml`;
`apps/client/tool/apply_profile.py` applies them to the tree.

## Conventions

- Tests use placeholder values; never commit real hostnames, addresses, account names, keys or tokens.
- Do not commit generated files: `deploy/.local/`, `apps/client/assets/release/household-release-key.pub`,
  `apps/client/android/release-signer.sha256`, `apps/client/anj-defines.env`.
- Code comments may cite internal ticket numbers from the project's history (for example "spec #31"); they refer
  to the maintainer's private tracker and can be ignored.
