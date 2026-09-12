# Windows Test Grid

Generic encrypted MetaTrader 5 single-test runner for controlled CI experiments.

This repository intentionally contains no project payloads, no private test inputs, and no plaintext test results. Runtime payloads are supplied only as encrypted, short-lived assets and outputs are encrypted before upload.

## Security model

- Manual dispatch only.
- Public workflow contains no project-specific names, symbols, parameters, dates, broker details, or result values.
- Runtime package is AES-256 encrypted with encrypted archive headers.
- Session key is provided only through the repository Actions secret `GRID_SESSION_KEY`.
- Plaintext exists only inside the ephemeral GitHub-hosted Windows runner while the test is executed.
- Only the compiled Expert Advisor and tester configuration are accepted; auxiliary executable/script payloads and DLL import are rejected in this POC.
- Output is encrypted before upload.
- Artifact retention is one day as a fallback; the controller should delete it immediately after successful local validation.

## POC payload

The encrypted archive root contains only:

- `worker.ex5`
- `tester.ini`
- optional `worker.set`

The tester configuration must run a single test (`Optimization=0`), use the neutral runtime Expert name `worker`, write `Report=report`, allow overwrite, and shut the terminal down after completion.

See `docs/PAYLOAD_CONTRACT.md` for the exact contract.

No private payload or plaintext result should ever be committed to Git history.
