# Encrypted Payload Contract

The public repository never receives plaintext job data.

## Input archive

The controller creates a temporary `.7z` archive using AES-256 and encrypted headers (`-mhe=on`). The archive root must contain:

- `entry.ps1` — the private job entry point.
- Any runtime files needed by that job.

The archive itself should use an opaque random filename.

## Runtime contract

The public workflow sets `GRID_OUTPUT_DIR` to a temporary directory. `entry.ps1` must:

1. Run the private workload without writing sensitive content to the parent console.
2. Write all files that must be returned into `$env:GRID_OUTPUT_DIR`.
3. Exit with `0` on success or a nonzero code on failure.

The workflow redirects the entry point's standard output and standard error into private files. These diagnostic files and the output directory are then encrypted into a single result archive before upload.

## Session key

The decryption/encryption key is supplied through the GitHub Actions repository secret `GRID_SESSION_KEY`. Use a new cryptographically random key for each batch and delete/replace it after the batch is safely downloaded and validated.

## Public metadata

Do not place project names, executable names, symbols, parameters, test dates, or result values in:

- workflow inputs
- release names
- artifact names
- commit messages
- Actions logs

Use only opaque random identifiers.

## Cleanup

The controller must download and validate the encrypted result before deleting any remote input/output asset. Artifact retention is only a fallback and should be kept as short as practical.
