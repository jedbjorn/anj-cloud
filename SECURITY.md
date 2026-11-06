# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

Use GitHub's private vulnerability reporting: open the **Security** tab of this
repository and choose **Report a vulnerability**. Include what you found, the
version or commit, and steps to reproduce. You will get an acknowledgement, and
we will keep you informed until the problem is fixed or we explain why it is
not one.

## Scope

anj-cloud is software that a household runs for itself: the gateway, the
deployment tooling and the clients. A report about a copy you run is welcome.
Because each household hosts its own gateway, there is no central service to
test: do not probe servers you do not own.

## What helps

- A short description of the impact and who it affects.
- A minimal reproduction against your own deployment or the test stack
  (`deploy/dev.py`).
- Whether you want to be credited.

## Supported versions

Only the latest release on the main branch is supported. The project is young;
expect fixes to ship as new releases.
