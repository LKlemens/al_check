# Workflows

## Failed Test Workflow

When tests fail, failed test locations are automatically saved. Re-run only the failures:

```bash
check --only test     # Run tests, failures saved to .check/failed_tests.txt
check --failed        # Re-run still-failing tests
check --all-failed    # Re-run all originally failed tests
check --failed --repeat 10  # Re-run with repeat
```

AlCheck maintains two files:
- `.check/failed_tests.txt` — original full list from the last check run (never modified by `--failed`)
- `.check/still_failing.txt` — updated after each `--failed` run, contains only tests that still fail

`--failed` reads from `still_failing.txt` (falls back to `failed_tests.txt` if it doesn't exist).
As tests pass, they are removed from the still-failing list. When all pass, `still_failing.txt` is deleted.

`--all-failed` always reads from `failed_tests.txt` to re-run the full original list.

## Auto-fix Workflow

Run checks first to store output, then apply fixes:

```bash
check --only format,credo  # Run checks and store output
check --fix                # Apply fixes from stored output
```

Fix commands are configurable in `.check.json`:

```json
"fix": [
  {"run": "mix format"},
  {"run": "mix recode", "files": ".check/credo*.txt"}
]
```

## Modified Tests Workflow

Run only tests that changed on your branch vs the base branch:

```bash
check --only modified_tests           # Run only changed test lines
check --only modified_test_modules    # Run whole changed test files
check --only modified_tests --repeat 5  # Repeat modified tests
```

`modified_tests` uses granular detection:
- **Module-level setup changed** → runs the whole file
- **Setup inside describe changed** → runs that describe block
- **Describe line changed** → runs that describe block
- **Test body changed** → runs only that specific test line

`modified_test_modules` is simpler - runs the entire file for any changed test module.

Detection compares committed changes against the base branch; uncommitted
working-tree changes are ignored. When run on the base branch itself, it
compares against the latest commit (`HEAD~1...HEAD`).

## Coverage Workflow

Show coverage report (cached if `cover/` data hasn't changed):

```bash
check --coverage       # Show coverage report (cached if cover/ unchanged)
check --no-coverage    # Run checks without coverage (overrides .check.json)
```

Coverage is also merged automatically after partitioned test runs. Configure in `.check.json`:

```json
"coverage": {
  "mod": "native",
  "limit": 80,
  "html": false,
  "baseline_cmd": "git show origin/main:coverage.txt"
}
```

The summary line prints a clickable `file://` link to the HTML report. When
`baseline_cmd` is set, it also shows the delta vs baseline:
```
✓ Coverage: 85.5% | file:///path/to/project/cover
  Coverage: +2.3% vs baseline (83.2%)
```

### New/modified file breakdown

After a full run (and with `check --coverage`), coverage for files added or
modified vs the base branch is reported separately, grouped into "new files"
and "modified files" with per-group averages. The per-module HTML reports for
those files are copied into `.check/cover_modified/` and a `file://` link to
that directory is printed, so you can open just the changed files' coverage.

## Database Setup for Partitions

Set up or drop databases for all test partitions in parallel:

```bash
check --setup-db                          # mix ecto.setup for each partition
check --drop-db                           # mix ecto.drop for each partition
check --setup-db --partitions 6           # with custom partition count
check --for-partitions 'mix ecto.reset'   # any command across partitions
check --for-partitions 'mix ecto.migrate' --partitions 4
```

`--db-setup` and `--db-drop` are also accepted as aliases.

Commands are configurable in `.check.json`:

```json
"db_setup": "mix ecto.setup",
"db_drop": "mix ecto.drop"
```

Each partition runs with `MIX_ENV=test MIX_TEST_PARTITION=N` prepended.

## Updating AlCheck

```bash
mix check.update
```

Runs the commands defined in `"update"` in `.check.json`, or defaults to:
1. `mix deps.update al_check`
2. `mix check.install`

Add your version manager's reshim command:

```json
"update": [
  "mix deps.update al_check",
  "mix check.install",
  "asdf reshim"
]
```

## Watch Mode

Monitor test partition output files in real-time while tests run in another terminal:

```bash
check --watch
```
