# Execution
1. Inspect generated schema and official sources, compare native interfaces.
2. Build Rust prototype with bounded parser, approval correlation and repeatable scenario runner.
3. Run real CLI end to end, record failures without claiming passes; verify approval before/after via markers, denial, cancellation, next turn and fresh-process resume.
4. Check framing and approval stale/duplicate/competition guard behavior with focused tests.
5. Review sanitized samples and docs, run cargo fmt/check/test/clippy as available. Do not commit.
User explicitly requested implementation and empirical verification this turn; planning reviewed against that scope before activation.
