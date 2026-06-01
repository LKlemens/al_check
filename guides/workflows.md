# Workflows

## Failed Test Workflow

When tests fail, failed test locations are automatically saved. Re-run only the failures:

```bash
check --only test     # Run tests, failures saved automatically
check --failed        # Re-run only the failed tests
check --failed --repeat 10  # Re-run with repeat
```

Failed tests are saved to `.check/failed_tests.txt`. Failures are extracted from both
test partition outputs and any custom check output (e.g. `modified_tests`).

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

When `baseline_cmd` is set, shows delta vs baseline:
```
✓ Coverage: 85.5% | Report: cover/
  Coverage: +2.3% vs baseline (83.2%)
```

## Watch Mode

Monitor test partition output files in real-time while tests run in another terminal:

```bash
check --watch
```
