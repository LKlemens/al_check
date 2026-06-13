# Changelog

## [0.1.23] - 2026-06-13

### Added
- Modified-file coverage report: after running tests, coverage for newly
  added and modified files (vs. base branch) is shown grouped into
  "new files" and "modified files" with per-group averages
- Module names in coverage output are rendered as OSC 8 terminal
  hyperlinks pointing to the HTML report when available
- `Runner.stream_and_capture_port/1` — streams port output to stdout
  while also capturing it for downstream inspection
- Modified-test runs now print a note clarifying that only committed
  changes (vs. base branch) are considered; uncommitted/working-tree
  changes are ignored

### Fixed
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
- "Tests now pass" notification color changed from green to yellow

## [0.1.22] - ...

See git log for earlier history.
