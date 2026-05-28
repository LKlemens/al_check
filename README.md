# AlCheck

[![Hex.pm](https://img.shields.io/hexpm/v/al_check.svg)](https://hex.pm/packages/al_check)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/al_check)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/al_check.svg)](https://hex.pm/packages/al_check)
[![CI](https://github.com/LKlemens/al_check/actions/workflows/ci.yml/badge.svg)](https://github.com/LKlemens/al_check/actions/workflows/ci.yml)

A parallel code quality checker for Elixir projects. Runs format, compile, credo, dialyzer, and tests concurrently with smart test partitioning.

## Features

- **Parallel Execution** - all checks run concurrently to maximize CPU utilization
- **Test Partitioning** - splits test suite across multiple partitions
- **Coverage Merging** - combines partition coverage into a single report with caching
- **Modified Tests** - run only tests changed on your branch (granular line-level or whole modules)
- **Failed Test Rerun** - re-run only previously failed tests
- **Auto-fix** - configurable fix commands for format and credo issues
- **Real-time Progress** - animated status lines with test counts and spinner
- **Configurable** - `.check.json` for all settings, `builtin:` checks for Elixir-powered logic

## Installation

Add `al_check` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:al_check, "~> 0.1.0"}
  ]
end
```

Then install globally:

```bash
mix deps.get
mix check.install
# if you use asdf
asdf reshim
```

## Usage

```bash
check                                # Run default checks
check -v                             # Show version
check --init                         # Create .check.json with defaults
check --help                         # Show help
check --fast                         # Run only fast checks (format, compile, credo)
check --only format,test             # Run specific checks
check --only modified_tests          # Run only modified/new tests vs base branch
check --only modified_test_modules   # Run whole test files modified on branch
check --partitions 4                 # Run tests with 4 partitions
check --dir test/foo,test/bar        # Run tests from specific directories
check --failed                       # Re-run only failed tests from previous run
check --fix                          # Apply auto-fixes
check --watch                        # Monitor test partition files in real-time
check --coverage                     # Show coverage report (cached if unchanged)
check --verbose                      # Print test output directly
check --test-args --exclude slow     # Pass custom args to mix test
check --repeat 10                    # Run tests with --repeat-until-failure
```

### Available Checks

| Check | Command |
|-------|---------|
| `format` | `mix format --check-formatted` |
| `compile` | `mix compile --warnings-as-errors` |
| `compile_test` | `MIX_ENV=test mix compile --warnings-as-errors` |
| `dialyzer` | `mix dialyzer` |
| `credo` | `mix credo --all` |
| `credo_strict` | `mix credo --strict --only readability --all` |
| `test` | `mix test` (with parallel partitioning) |
| `modified_tests` | Runs only changed test lines vs base branch (builtin) |
| `modified_test_modules` | Runs whole modified test files vs base branch (builtin) |

## Workflows

### Failed Test Workflow

```bash
check --only test     # Run tests, failures saved automatically
check --failed        # Re-run only the failed tests
```

### Auto-fix Workflow

```bash
check --only format,credo  # Run checks and store output
check --fix                # Apply fixes from stored output
```

### Modified Tests Workflow

```bash
check --only modified_tests           # Run only changed test lines
check --only modified_test_modules    # Run whole changed test files
check --only modified_tests --repeat 5  # Repeat modified tests
```

`modified_tests` detects:
- Setup/describe changed -> runs the whole file
- Test body changed -> runs only that specific test line
- Module-level change -> runs the whole file

### Coverage Workflow

```bash
check --coverage    # Show coverage report (cached if cover/ unchanged)
```

## Configuration

Create a `.check.json` in your project root (`check --init` generates one with defaults):

```json
{
  "run": ["format", "compile", "compile_test", "dialyzer", "credo", "credo_strict", "test"],
  "fast": ["format", "compile", "compile_test", "credo", "credo_strict"],
  "partitions": 3,
  "max_concurrency": 10,
  "test_args": "--warnings-as-errors",
  "default_repeat": 100,
  "base_branch": "main",
  "coverage": {
    "mod": "native",
    "limit": 80,
    "html": false,
    "baseline_cmd": "git show origin/main:coverage.txt"
  },
  "fix": [
    {"run": "mix format"},
    {"run": "mix recode", "on_credo_files": true}
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

### Key config options

| Key | Description |
|-----|-------------|
| `run` | Checks to run by default (without `--only` or `--fast`) |
| `fast` | Checks to run with `--fast` |
| `base_branch` | Git branch for modified test detection (auto-detects `main`/`master` if not set) |
| `checks` | Custom check definitions (replaces built-in checks, test partitions always added) |
| `fix` | Commands to run with `--fix` |

### Custom checks

Each check has a `run` string (shell command) and optional `name`:

```json
"sobelow": {"name": "Security", "run": "mix sobelow --config"}
```

Use `builtin:` prefix for Elixir-powered checks:

```json
"modified_tests": {"run": "builtin:modified_tests"}
```

Use `{base_branch}` placeholder in shell commands — replaced at runtime:

```json
"my_check": {"run": "git diff {base_branch}... --stat"}
```

### Coverage

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
| `limit` | Minimum coverage %. Fails if below |
| `html` | Generate full HTML report (default: `false`, kills early after getting %) |
| `baseline_cmd` | Shell command returning baseline coverage % for delta comparison |

### Fix commands

```json
"fix": [
  {"run": "mix format"},
  {"run": "mix recode", "on_credo_files": true}
]
```

`on_credo_files: true` runs the command only on files that had credo issues in the previous run.

## Output Files

AlCheck creates a `.check/` directory:

| File | Description |
|------|-------------|
| `.check/credo.txt` | Credo output for auto-fix |
| `.check/credo_strict.txt` | Strict credo output for auto-fix |
| `.check/check_tests.txt` | Merged test output from all partitions |
| `.check/test_partition_N.txt` | Individual partition outputs |
| `.check/failed_tests.txt` | Failed test locations |
| `.check/coverage_cache.*` | Cached coverage results |
| `.check/test_args.txt` | Saved test args for `--failed` |

## Requirements

- Elixir ~> 1.18
- Mix build tool

## Documentation

Full documentation is available at [https://hexdocs.pm/al_check](https://hexdocs.pm/al_check).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
