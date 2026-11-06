# Contributing

Thanks for helping. anj-cloud is household file sync and inference access with
a self-hosted gateway and matching clients. Read [docs/overview.md](docs/overview.md)
first, then [docs/development.md](docs/development.md) to set up a checkout.

## Ground rules

- Open an issue before a large change, so the direction is agreed first.
- Keep a change small and focused; one pull request, one idea.
- Add or update tests with the change. Tests use placeholder values
  (`gateway.example.com`, `alex`, `sam`); never put a real hostname, address,
  account name, key or token into the repository, a test or a screenshot.
- Household specifics live in a deployment profile
  (`deploy/profile.example.toml`), not in code.
- Do not commit generated files: `deploy/.local/`, the release public key file,
  the Android signer pin file, build output.
- Be kind: see the [code of conduct](CODE_OF_CONDUCT.md).

## Before you open a pull request

```bash
python3 deploy/checks.py --deps     # once: pinned Python dependencies, tooling check
python3 deploy/checks.py            # server tests, then client analysis and tests
```

The client checks need the pinned Flutter SDK (see docs/development.md). If you
only changed the server or the deployment tooling, running the Python tests is
enough, and say so in the pull request.

## Tests that need a maintainer seat

CI runs the checks that pass on a stock Ubuntu runner. These suites were written against the maintainer's Linux
seat (its filesystem identity, OpenSSL build, free-space measurements and timing) and are skipped in CI; the
maintainers run them before a release with `python3 deploy/checks.py` on that seat:

- Python: `test_backup` (Preflights, Window, StaleAlerts, HousekeepingWindow), `test_permanent_credentials`
  (OperatorReissueTests), `test_prod_tooling` (ProductionTrustTests), `test_vm_prompts_pty` (WholeInstall),
  `test_console_backend` (OccArgvTests). The list lives in `tool/ci_python_tests.py`.
- Flutter, in `apps/client/test`: `root_identity`, `identity_shares`, `no_openssl_cli`, `edit_completion`,
  `identity_cloud_moves`, `recover_dismiss`, `recent_new`, `incremental_index` and `device_crypto`, including the
  copies of them that `tool/android_variant_suites.sh` runs. The list lives in `ANJ_TEST_EXCLUDE` in
  `.github/workflows/ci.yml`.
- Real devices and hosts (macOS and Windows seats, Android emulator and phone, live gateway runs) are never in CI.

If your change touches one of these areas, say in the pull request that you could not run them.

## Pull requests

Describe what changed and why, and how you tested it. CI runs the same checks
on Linux; a pull request needs to be green. Security problems go through
[SECURITY.md](SECURITY.md), not a public issue.

## License

By contributing you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE).
