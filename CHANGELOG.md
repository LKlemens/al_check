# Changelog

## [0.1.26] - 2026-07-01

### Changed
- Default test partitions is now `1` (was `3`). Running more than one
  partition requires per-partition project config, so a single partition
  works out of the box; raise `partitions` in `.check.json` (or pass
  `--partitions N`) once that config is in place

### Added
- Warning shown after a failed multi-partition test run, explaining that
  parallel tests need per-partition config (separate DB + HTTP port) and
  linking the test-partitioning guide. Printed only on a partition failure —
  silent when partitions pass or when a single partition fails
- `check --init` now writes a `"// update"` comment above `"update"` in the
  generated `.check.json`, hinting to add your version manager's reshim
  (`asdf reshim` / `mise reshim` / `rtx reshim`). Comment-keys starting with
  `//` are ignored by config validation
- Test-partitioning guide: new "Endpoint / server port" section showing how
  to offset the endpoint port per partition via `MIX_TEST_PARTITION`, so
  tests that boot a server don't collide across partitions

## [0.1.24] - 2026-06-28

### Added
- Coverage report after a passing `check --failed` / `--all-failed`: when the
  re-run goes green, coverage is merged and the new/modified-file breakdown is
  shown, just like a full run. Gated only on coverage being configured
  (`coverage.mod`); `--no-coverage` skips it
- The report is shown only when the *complete* failed set ran — `--all-failed`,
  or the first `--failed` before any `.check/still_failing.txt` exists. A later
  `--failed` re-runs only the still-failing subset (which overwrites
  `cover/failed.coverdata` with partial data), so it instead prints a hint to
  re-run `check --all-failed` for a full report

### Fixed
- Spinner no longer animates when stdout is not a TTY (piped/redirected to a
  file or CI log): the cursor-control escapes were no-ops there, so every frame
  piled up as literal `⠙ Running` leftovers. It now detects a terminal via
  `:io.columns/0` and stays silent otherwise
- Spinner no longer leaks past the streamed run into later output (e.g. the
  coverage merge): the live spinner is now stopped when the port exits, in both
  `Check.Failed` and `Check.Runner` streamers, instead of only the original
  (already-stopped) one

## [0.1.23] - 2026-06-13

### Added
- Modified-file coverage report: after running tests, coverage for newly
  added and modified files (vs. base branch) is shown grouped into
  "new files" and "modified files" with per-group averages
- Per-module HTML coverage reports for new/modified files are copied to
  `.check/cover_modified/` (together with the shared CSS/JS assets so they
  render standalone), and a `file://` link to that directory is printed
- `Runner.stream_and_capture_port/1` - streams port output to stdout
  while also capturing it for downstream inspection
- Modified-test runs now print a note clarifying that only committed
  changes (vs. base branch) are considered; uncommitted/working-tree
  changes are ignored
- `check --coverage` now also reports coverage of new/modified modules
  (the per-file "new files" / "modified files" breakdown), matching the
  full run
- `--full-coverage-output` flag prints the entire per-module coverage table
  (otherwise only the total and the new/modified breakdown are shown)
- `--with-html` flag forces the HTML coverage report for a single run,
  overriding `"html": false` in `.check.json`. Used on its own it implies
  `--coverage` (like `--full-coverage-output`)

### Changed
- `modified_tests` no longer reports coverage: it runs only the selected
  test lines, so per-file coverage numbers were misleadingly low.
  `modified_test_modules` (whole files) still reports coverage

### Fixed
- Builtin checks (`modified_tests`, `modified_test_modules`) no longer have
  their output clobbered by the parallel status UI: their stdout (including
  the "no modified test files found" warning) was being erased by the
  in-place `[OK]` cursor redraw. Builtin output is now captured during the
  run and reprinted below the finalized status lines
- Failure detection regex now matches doctests and property-based test
  failures, not only regular `test` blocks
- `coverage_threshold_failure?/1` handles the alternative
  `"Coverage test failed, threshold not met"` message
- Coverage threshold failures are no longer surfaced as errors during
  modified-test runs (superseded by the per-file report)
- Modified-file coverage report now works when committing directly to the
  base branch: the three-dot `base...HEAD` diff collapses to nothing on
  the base branch, so it now diffs against `HEAD~1` there (and includes
  uncommitted working-tree changes on feature branches)
- New/modified file detection now matches top-level files: the git pathspec
  `lib/**/*.ex` (and `test/**/*_test.exs`) silently matched nothing for files
  directly under `lib/`/`test/` (e.g. `lib/check.ex`); switched to `:(glob)`
  magic so `**` spans zero or more directories. This is why the per-file
  coverage breakdown could come back empty
- Per-file coverage breakdown now matches module names exactly, so a
  top-level module like `Check` no longer pulls in every `Check.*` row
- `check --coverage` and the full run now show the new/modified breakdown on
  a coverage-threshold failure too, but suppress it when tests failed (the
  coverage numbers would be incomplete and misleading)
- `modified_tests` and `modified_test_modules` now work on the base branch:
  the same empty `base...HEAD` range meant `check --only modified_test_modules`
  found nothing on `main`; they now compare against the latest commit
  (`HEAD~1...HEAD`) there. Diff-range resolution is shared via the new
  `Check.Git` module
- "Tests now pass" notification color changed from green to yellow

## [0.1.22] - ...

See git log for earlier history.
