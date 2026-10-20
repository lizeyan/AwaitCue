# Contributing to AwaitCue

## Branch workflow

1. Branch from `master`.
2. Make one focused change.
3. Add or update behavior tests at a documented public seam.
4. Run `./Scripts/check.sh`.
5. Open a Pull Request against `master`.
6. Resolve every review conversation and wait for all required checks.

Direct pushes and force pushes to `master` are prohibited, including for maintainers.

## Tests

- Swift tests use Swift Testing.
- Chromium extension tests use Vitest.
- Tests assert public behavior, not private implementation details.
- Swift and TypeScript line, function, statement, and branch coverage gates are 90% where the tool reports those dimensions.
- Real integration requirements must not be replaced by mocks. Unit fakes are allowed for transport errors, retries, and deterministic state behavior.

## Code style

- Keep changes surgical and avoid speculative abstraction.
- Public functions and types need Chinese documentation comments explaining intent.
- Non-obvious performance, stability, privacy, and permission trade-offs need Chinese comments.
- Never log credentials, screenshots, DOM text, complete URLs with query strings, or model payloads.

## Commit style

Use concise Conventional Commit-style subjects, for example:

```text
feat(core): add stable condition confirmation
test(model): cover incomplete Responses output
ci: enforce extension coverage gate
```

## License

By submitting a contribution, you agree that it may be distributed under the repository's Apache License 2.0 unless you explicitly mark it as not being a contribution.
