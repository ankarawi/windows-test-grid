# Encrypted MT5 Payload Contract

The public repository never receives plaintext Expert Advisor files, tester inputs, account data, or test results.

## Input archive

The controller creates a temporary `.7z` archive with AES-256 encryption and encrypted archive headers (`-mhe=on`). The archive root may contain only:

- `worker.ex5` — the compiled Expert Advisor, renamed to the neutral runtime name.
- `tester.ini` — the private MetaTrader 5 tester configuration.
- `worker.set` — optional Expert Advisor input preset.

The archive itself must use an opaque random filename. Do not commit the archive to Git history.

Executable or script payloads other than `worker.ex5` are rejected. DLL import is not allowed in the POC.

## Required tester configuration

`tester.ini` must contain a `[Tester]` section compatible with the fixed public runner. At minimum:

```ini
[Experts]
AllowDllImport=0

[Tester]
Expert=worker
Symbol=<private value>
Period=<private value>
Optimization=0
Report=report
ReplaceReport=1
ShutdownTerminal=1
```

If `worker.set` is included, add:

```ini
ExpertParameters=worker.set
```

Private test parameters such as dates, symbol, timeframe, model, deposit, leverage, broker/server information, and Expert inputs remain only inside this encrypted archive.

## Session key

The archive encryption/decryption key is supplied through the repository Actions secret `GRID_SESSION_KEY`. Generate a new cryptographically random key for each batch. After all encrypted results are downloaded, decrypted, validated, and saved locally, rotate or delete that key.

Never place the session key in a workflow input, commit, issue, release name, artifact name, or log.

## Public metadata

Do not place project names, Expert names, symbols, timeframes, parameters, test dates, broker details, or result values in:

- workflow inputs
- release or asset names
- artifact names
- commit messages
- Actions logs

Use only opaque random identifiers.

## Result archive

The GitHub-hosted runner saves the tester report and a generic `exit.txt`, encrypts them with the same session key using AES-256 plus encrypted headers, and uploads only the encrypted `o.bin` artifact.

## Cleanup order

The local controller must:

1. Download the encrypted result.
2. Verify that it can be decrypted.
3. Parse and validate the result against the expected test contract.
4. Save the validated result locally.
5. Only then delete the remote input asset, output artifact/run when desired, and rotate/delete the session key.

Artifact retention is one day only as a fallback. Immediate controller cleanup is preferred after successful local validation.
