# Race fixture

A one-file project used by `fleet demo`:

- `src/value.txt` starts at `0`;
- `check.js` exits 0 only when it holds `42`.

Each race candidate runs a shell command that rewrites the file and then runs
the verifier; only the Branch whose verifier passes may publish.
