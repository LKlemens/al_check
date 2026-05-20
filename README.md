# AlCheck

A parallel code quality checker for Elixir projects. AlCheck runs multiple code quality checks (format, compile, credo, dialyzer, and tests) concurrently with smart test partitioning.

## Features

- **Parallel Execution**: Runs all checks concurrently to maximize CPU utilization
- **Test Partitioning**: Splits test suite across multiple partitions for parallel execution
- **Smart Test Management**: Re-run only failed tests, monitor test progress in real-time
- **Auto-fix Support**: Apply credo fixes automatically from stored outputs
- **Real-time Progress**: Visual feedback with test counts and status updates
- **Flexible Filtering**: Run specific checks or use fast mode for quick feedback

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
# if u use asdf
asdf reshim
```

## Usage

### CLI Usage

Run all checks:

```bash
check
```

### Common Options

```bash
# Run only fast checks (format, compile, credo)
check --fast

# Run specific checks only
check --only format,test
check --only credo

# Run tests with custom partition count
check --partitions 4

# Run tests from specific directory
check --dir test/my_app/feature/

# Re-run only failed tests from previous run
check --failed

# Apply auto-fixes from stored credo output
check --fix

# Monitor test partition files in real-time
check --watch
```

### Available Checks

- **format** - `mix format --check-formatted`
- **compile** - `mix compile --warnings-as-errors`
- **compile_test** - `MIX_ENV=test mix compile --warnings-as-errors`
- **dialyzer** - `mix dialyzer`
- **credo** - `mix credo --all`
- **credo_strict** - `mix credo --strict --only readability --all`
- **test** - `mix test` (with parallel partitioning)

## Workflows

### Failed Test Workflow

When tests fail, failed test locations are automatically saved:

```bash
check --only test     # Run tests and save failures
cat check/failed_tests.txt    # View failed tests
check --failed        # Re-run only the failed tests
```

### Auto-fix Workflow

Credo output is stored for later use with `--fix`:

```bash
check --only credo    # Run checks and store output
check --fix           # Apply fixes from stored output
```

### Test Partitioning

Tests run in parallel partitions (default: 3). Each partition uses its own database.
Customize based on your CPU cores:

```bash
check --partitions 3  # Run with 3 partitions
```

## Output Files

AlCheck creates a `check/` directory with the following files:

- `check/credo.txt` - Credo output for auto-fix
- `check/credo_strict.txt` - Strict credo output for auto-fix
- `check/check_tests.txt` - Merged test output from all partitions
- `check/test_partition_N.txt` - Individual partition outputs
- `check/failed_tests.txt` - List of failed test locations

## Configuration

Create a `.check.json` in your project root to customize behavior:

```json
{
  "fast": ["format", "compile", "compile_test", "credo"],
  "partitions": 3,
  "max_concurrency": 10,
  "test_args": "--warnings-as-errors",
  "default_repeat": 100,
  "coverage": {"mod": "native", "limit": 80},
  "checks": {
    "format": {"name": "Formatting", "run": "mix format --check-formatted"},
    "credo": {"name": "Credo", "run": "mix credo --all"}
  }
}
```

All fields are optional. CLI flags override config values.

Override the config path via the `CHECK_CONFIG` environment variable.

### Custom checks

Each check is defined with a `run` string (the shell command to execute) and an optional `name` for display. If `name` is omitted, it defaults to a capitalized version of the key (e.g. `"compile_test"` → `"Compile Test"`).

When `checks` is provided, it replaces all built-in checks (test partitions are always added).

### Coverage

Configure coverage merging across partitions:

```json
"coverage": {"mod": "native", "limit": 80}
```

- `mod` — `"native"` (built-in `mix test --cover`) or `"coveralls"` (excoveralls)
- `limit` — optional minimum coverage %. Fails the check if below this value

## Requirements

- Elixir ~> 1.18
- Mix build tool

## Documentation

Full documentation is available at [https://hexdocs.pm/al_check](https://hexdocs.pm/al_check).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

