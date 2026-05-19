# Contributing to SwiftS3M

Thanks for the interest. This is a small, focused library — the bar is "ships clean, doesn't regress, stays minimal." Patches that match that bar are very welcome.

## Running the tests

```sh
swift test
```

The test target uses Swift Testing (the `import Testing` framework), not XCTest. Tests live in `Tests/SwiftS3MTests/`. Add a test for any behavioral change — the suite is small enough that adding one or two cases is cheap and forces you to articulate intent.

```sh
swift build       # release-ish smoke check
swift build -c release
```

## Commit style

Commits follow conventional commits in `action(noun): verb` form, lowercase, imperative mood:

```
feat(mixer): implement vibrato effect (H)
fix(parser): handle truncated pattern data without crashing
docs(readme): clarify AVAudioEngine bridge example
test(mixer): cover sample offset clamping at end of sample
refactor(parser): hoist parapointer math into a helper
```

Keep the subject under ~72 characters. Use the body for the *why*. Group related changes in one commit; split unrelated changes across commits.

## Pull requests

For anything non-trivial — a new effect implementation, a parser change, a public API change — **open an issue first** so we can agree on shape and scope before you spend time on code. Typos, small doc fixes, and obvious bug fixes don't need an issue.

When opening a PR, ensure:

- `swift test` passes locally
- New public symbols have `///` doc comments
- No new dependencies (Foundation only, by design)
- The public API of `S3MFile`, `S3MMixer`, and `S3MError` is unchanged unless explicitly discussed

## Code of conduct

Be kind. Disagree about code, not people. Maintainers reserve the right to close threads that go off the rails.
