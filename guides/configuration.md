# Configuration

Create a `.check.json` in your project root (`check --init` generates one with defaults).

## Full example

```json
{
  "run": ["format", "compile", "compile_test", "dialyzer", "credo", "credo_strict", "test"],
  "fast": ["format", "compile", "compile_test", "credo", "credo_strict"],
  "partitions": 1,
  "max_concurrency": 10,
  "test_args": "--warnings-as-errors",
  "default_repeat": 100,
  "test_output": "status",
  "base_branch": "main",
  "coverage": {
    "mod": "native",
    "limit": 80,
    "html": false,
    "baseline_cmd": "git show origin/main:coverage.txt"
  },
  "fix": [
    {"run": "mix format"},
    {"run": "mix recode", "files": ".check/credo*.txt"}
  ],
  "checks": {
    "format": {"name": "Formatting", "run": "mix format --check-formatted"},
    "compile": {"name": "Compile", "run": "mix compile --warnings-as-errors"},
    "credo": {"name": "Credo", "run": "mix credo --all"},
    "modified_tests": {"name": "Modified Tests", "run": "builtin:modified_tests"},
    "modified_test_modules": {"name": "Modified Test Modules", "run": "builtin:modified_test_modules"}
  }
}
```

All fields are optional. CLI flags override config values.

## Config options

| Key | Description |
|-----|-------------|
| `run` | Checks to run by default (without `--only` or `--fast`) |
| `fast` | Checks to run with `--fast` |
| `partitions` | Number of test partitions (default: 1) |
| `max_concurrency` | Max parallel checks (default: 10) |
| `test_args` | Default args for `mix test` (default: `--warnings-as-errors`) |
| `default_repeat` | Default `--repeat` value when flag is used without a number |
| `test_output` | How task output is shown (default: `"status"`) - see below |
| `base_branch` | Git branch for modified test detection (auto-detects `main`/`master` if not set) |
| `checks` | Custom check definitions (replaces built-in checks, test partitions always added) |
| `fix` | Commands to run with `--fix` |
| `coverage` | Coverage merging settings |
| `db_setup` | Command for `--setup-db` / `--db-setup` (default: `mix ecto.setup`) |
| `db_drop` | Command for `--drop-db` / `--db-drop` (default: `mix ecto.drop`) |
| `update` | Commands for `mix check.update` (default: `["mix deps.update al_check", "mix check.install"]`) |

## Test output

`test_output` controls how each task's output is shown. Because tasks run
concurrently, live-streaming everything (`verbose`) interleaves output from
different partitions. The `sections` modes instead print each task's **full**
output as a contiguous block once it finishes, so nothing interleaves.

| Value | Behaviour |
|-------|-----------|
| `"status"` (default) | Live status board; failed test partitions show the summary line plus a pointer to `.check/check_tests.txt` |
| `"verbose"` | Stream every task's output live (equivalent to `--verbose`) |
| `"sections"` | Shorthand for `{"sections": "on_failure"}` |
| `{"sections": "on_failure"}` | Status board during the run; print the full output block for each **failed** section at the end (equivalent to `--verbose-sections`) |
| `{"sections": "always"}` | Status board during the run; print the full output block for **every** section at the end (equivalent to `--verbose-sections-always`) |

```json
"test_output": {"sections": "on_failure"}
```

CLI flags override this: `--verbose` forces `verbose`, `--verbose-sections` forces
`{"sections": "on_failure"}`, and `--verbose-sections-always` forces
`{"sections": "always"}`.

## Custom checks

Each check has a `run` string (shell command) and optional `name`:

```json
"sobelow": {"name": "Security", "run": "mix sobelow --config"}
```

If `name` is omitted, it defaults to a capitalized version of the key (e.g. `"compile_test"` → `"Compile Test"`).

### Builtin checks

Use the `builtin:` prefix for checks that need Elixir logic:

```json
"modified_tests": {"run": "builtin:modified_tests"}
```

Available builtins:
- `builtin:modified_tests` - runs only changed test lines vs base branch
- `builtin:modified_test_modules` - runs whole modified test files vs base branch

### Placeholders

Use `{base_branch}` in shell commands - replaced at runtime with the configured or auto-detected base branch:

```json
"my_check": {"run": "git diff {base_branch}... --stat"}
```

## Coverage

```json
"coverage": {
  "mod": "native",
  "limit": 80,
  "html": false,
  "baseline_cmd": "git show origin/main:coverage.txt"
}
```

| Key | Description |
|-----|-------------|
| `mod` | `"native"` (built-in `--cover`) or `"coveralls"` (excoveralls) |
| `limit` | Minimum coverage %. Fails the check if below this value |
| `html` | Generate full HTML report (default: `false`, kills early after getting %) |
| `baseline_cmd` | Shell command returning baseline coverage % for delta comparison |

Use `--no-coverage` to disable coverage for a single run (overrides this config).

### Coverage after failed-test reruns

When coverage is configured, a passing failed-test rerun also prints coverage - but only
when the data is complete. `--failed` re-runs only the *still-failing subset*
(`.check/still_failing.txt`) and each rerun overwrites `cover/failed.coverdata` with that
shrinking subset, so its coverage would be misleading. The full original failed list runs
only on `--all-failed` and on the **first** `--failed` (before any `still_failing.txt`
exists). So:

- `--all-failed` passes → coverage report.
- first `--failed` passes → coverage report.
- a later `--failed` passes → info hint to re-run `check --all-failed` for a full report.

Coverage and the hint appear only on a passing run, and only when coverage is enabled
(`--no-coverage` skips both).

Coverage results are cached based on `cover/*.coverdata` hashes. Re-running `check --coverage` is instant if test data hasn't changed.

## Fix commands

```json
"fix": [
  {"run": "mix format"},
  {"run": "mix recode", "files": ".check/credo*.txt"}
]
```

Each entry can have:
- `run` - the command to execute
- `files` (optional) - glob pointing to output files from previous checks. File paths are extracted from their contents and passed as arguments to the command.

## Output files

AlCheck creates a `.check/` directory:

| File | Description |
|------|-------------|
| `.check/credo.txt` | Credo output for auto-fix |
| `.check/credo_strict.txt` | Strict credo output for auto-fix |
| `.check/check_tests.txt` | Merged test output from all partitions |
| `.check/test_partition_N.txt` | Individual partition outputs |
| `.check/failed_tests.txt` | Original failed test locations (from last check run) |
| `.check/still_failing.txt` | Tests still failing after `--failed` runs |
| `.check/coverage_cache.*` | Cached coverage results |
| `.check/cover_modified/` | Per-module HTML coverage reports for new/modified files (with shared assets) |
| `.check/test_args.txt` | Saved test args for `--failed` |
