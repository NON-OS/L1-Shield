# Security policy

## Reporting a vulnerability

Report a vulnerability privately, and never in a public issue or pull request.

- Email: `team@nonos.systems`
- GitHub: "Report a vulnerability", under the Security tab of this repository

Include the affected contract and function, the commit, a test or the steps that reproduce the
issue, and its impact. Every report is acknowledged, and a fix or a decision is shared with the
reporter before anything is published.

## Scope

In scope: the contracts under `contracts/shield`.

Out of scope: `contracts/faucet`, tests, scripts, the fixtures under `spec/`, the libraries under
`lib/`, and third-party services.

## Known limitations

The current limitations are listed in [docs/20-security-status.md](docs/20-security-status.md).
A report that repeats one of them is not a new finding, unless it shows an impact the document
does not describe.
