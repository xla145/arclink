# Implementation plan

1. Implement native updater integration and frontend state/confirmation using existing bridge and lifecycle conventions.
2. Add updater keys/configuration and extend CI with signed archives, atomic full release metadata, stable DMG links.
3. Add focused tests for update transitions, guards, manifest validation and release failures. Run pnpm tests/build, cargo checks/tests, formatter and workflow validation.
4. Independently review, fix findings, update specs and release documentation. Report any remaining GitHub secret setup and real update smoke test accurately.

Ownership: implementation agent owns desktop source, native dependencies/config and Cargo.lock. Main session owns GitHub workflow, release scripts/docs, key bootstrap, task artifacts and integration. No unrelated user changes reverted. Review updater shutdown and manifest emission carefully; rollback by reverting these scoped changes without modifying app identity or user data.

## Verification record

- Independent desktop review: no confirmed blocker; frontend 25 tests/build, native 6 tests/check/Clippy passed. Existing unrelated Clippy warnings retained.
- CI review fixed incomplete release pagination and empty signature acceptance; 8 release assembly tests passed. Actionlint passed except its outdated runner-label catalog (macos-15-intel validated as current runner).
- Public visibility and rename to xla145/arclink confirmed through GitHub API. Both updater signing Secrets configured and names verified; private values never logged.
- Real cloud build pending branch push. Native two-version update smoke has not been performed.
