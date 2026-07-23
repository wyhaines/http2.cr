# Repository Guidelines

## Project Structure & Module Organization

This repository is a Crystal shard providing HTTP/2 protocol building blocks; it does not implement a complete client or server. The public entry point is `src/http2.cr`. Core connection, stream, request, and error types live directly under `src/`; individual HTTP/2 frame implementations are in `src/frame/`, and stream-specific errors are in `src/stream/`. Specs mirror the implementation in `spec/`, with shared setup in `spec/spec_helper.cr`. Package metadata and dependencies are declared in `shard.yml`.

## Build, Test, and Development Commands

- `shards install` installs `hpack` and development-tool sources into `lib/`.
- `shards build ameba -Dpreview_mt` builds the linter as `bin/ameba`.
- `crystal spec -t -s` runs the complete spec suite with timing and a summary, matching CI.
- `crystal spec spec/data_frame_spec.cr` runs one focused spec file during development.
- `bin/ameba` performs the static-analysis checks used by CI.
- `crystal tool format --check` verifies Crystal formatting without modifying files; run `crystal tool format` to apply it.
- `crystal docs` generates API documentation in the ignored `docs/` directory.
- `crystal build src/http2.cr` provides a quick compilation check for the shard entry point.

## Coding Style & Naming Conventions

Follow `.editorconfig`: UTF-8, LF line endings, a final newline, trimmed trailing whitespace, and two-space indentation for Crystal files. Use Crystal conventions: `snake_case` for files, methods, and local variables; `CamelCase` for types and modules; and `SCREAMING_SNAKE_CASE` for constants and enum members. Keep frame behavior within its corresponding `src/frame/<name>.cr` file and favor small, protocol-focused methods.

## Testing Guidelines

Tests use Crystal's built-in `spec` framework. Name files `<subject>_spec.cr`, require `spec_helper`, group behavior with `describe`, and use descriptive `it` examples. Add regression coverage for fixes and exercise protocol details such as flags, stream IDs, payload boundaries, and padding. There is no stated numeric coverage threshold; all specs and Ameba checks must pass.

## Commit & Pull Request Guidelines

History favors concise, single-line, sentence-style commit subjects. Keep new messages short and direct, describing one logical change. Pull requests should explain the behavior changed, identify relevant HTTP/2 semantics, link any issue, and list validation commands run. Include new or updated specs for observable behavior; screenshots are generally unnecessary for this library.
