# Windows Test Grid

Generic encrypted Windows job runner for controlled CI experiments.

This repository intentionally contains no project payloads, no test inputs, and no test results. Runtime payloads are supplied only as encrypted, short-lived assets and outputs are encrypted before upload.

## Security model

- Manual dispatch only.
- Public workflow contains no project-specific names or parameters.
- Runtime package must be AES-256 encrypted with encrypted archive headers.
- Session key is provided only through a repository Actions secret named `GRID_SESSION_KEY`.
- Plaintext exists only inside the ephemeral GitHub-hosted Windows runner during execution.
- Job stdout/stderr is redirected to a private file and never printed to the public Actions log.
- Output is encrypted before upload.
- Artifact retention is one day as a fallback; the controller should delete it immediately after successful local validation.

## POC contract

The encrypted runtime archive must contain an `entry.ps1` file at its root. The workflow provides an environment variable `GRID_OUTPUT_DIR`. `entry.ps1` must write all result files into that directory and return exit code 0 on success.

No sensitive file should ever be committed to Git history.
