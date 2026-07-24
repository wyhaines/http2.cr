# Release Policy

## Versioning

This shard follows Semantic Versioning. The documented `HTTP2::Client`,
`Request`, `Response`, `Headers`, `Cancellation`, timeout, replay, and
connection-configuration surfaces form the supported API. A breaking change
to those types requires a major release after 1.0. Frame and low-level
connection types are advanced protocol APIs; items marked `:nodoc:` remain
internal and are not compatibility guarantees.

Prereleases such as `1.0.0-rc.1` may still change in response to release
testing. Patch releases contain compatible fixes, minor releases add
compatible behavior, and major releases may break the supported API.

Support covers the Crystal versions in CI: currently 1.20 and 1.21, in normal
and multi-threaded builds.

## Release Checklist

1. Update `CHANGELOG.md`, `shard.yml`, `src/version.cr`, and the version spec
   to the same SemVer value.
2. Run the complete local gate:

   ```sh
   crystal tool format --check
   bin/ameba
   crystal spec -t -s
   crystal spec -Dpreview_mt -t -s
   spec/interop/run_nghttp2.sh
   spec/interop/run_nghttp2.sh -Dpreview_mt
   crystal build src/http2.cr
   crystal docs
   ```

3. Confirm CI passes on every supported Crystal version. The interoperability
   runner requires local `nghttpd`; it never contacts a public HTTP server.
4. Commit the release and create an annotated `v<version>` tag.
5. A maintainer pushes the commit and tag, confirms the tag's CI run, then
   creates the GitHub release from the matching changelog entry.

Do not publish a final `1.0.0` until at least one release candidate has
completed this matrix and received downstream testing.
