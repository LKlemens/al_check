# AlCheck

[![Hex.pm](https://img.shields.io/hexpm/v/al_check.svg)](https://hex.pm/packages/al_check)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/al_check)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/al_check.svg)](https://hex.pm/packages/al_check)
[![CI](https://github.com/LKlemens/al_check/actions/workflows/ci.yml/badge.svg)](https://github.com/LKlemens/al_check/actions/workflows/ci.yml)
[![Coverage](https://raw.githubusercontent.com/LKlemens/al_check/coverage_do_not_delete/current_coverage.svg)](https://github.com/LKlemens/al_check)
<img src="https://raw.githubusercontent.com/LKlemens/al_check/coverage_do_not_delete/casts/02-green-full.gif" alt="check --green run" width="950" />

A parallel code quality checker for Elixir projects. Runs format, compile, credo, dialyzer, and tests concurrently with smart test partitioning.

> Check out how it works in the [live showcase](https://al-check-demo.fly.dev/apps/al-check-demo)

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

## Quick Start

```bash
check                    # Run default checks
check --init             # Create .check.json with defaults
check --fast             # Run only fast checks (format, compile, credo)
check --only format,test # Run specific checks
check --failed           # Re-run only failed tests
check --fix              # Apply auto-fixes
check --coverage         # Show coverage report
check -v                 # Show version
check --help             # Show all options
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

## Guides

- **[Configuration](guides/configuration.md)** - `.check.json` reference, custom checks, coverage, fix commands
- **[Test Partitioning](guides/test-partitioning.md)** - database setup, connection limits, scheduler tuning
- **[Workflows](guides/workflows.md)** - failed tests, auto-fix, modified tests, coverage, watch mode

## Documentation

Full API documentation is available at [https://hexdocs.pm/al_check](https://hexdocs.pm/al_check).

## Requirements

- Elixir ~> 1.18
- Mix build tool

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
