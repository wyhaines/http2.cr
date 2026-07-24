# HPACK Additions Needed by HTTP/2

These are independent work items for the adjacent `hpack.cr` repository. They
should preserve existing APIs and wire output unless a caller opts into the new
behavior. The HTTP/2 implementation can complete phases 0–2 of its roadmap
while this work is in progress, but both additions should land before phase 3.

## 1. Encoder Dynamic-Table Size Updates

**Status:** available in `hpack.cr` 1.2.0.

### Goal

Add a public encoder operation that changes the dynamic-table capacity and
queues the corresponding
[RFC 7541 §6.3](https://www.rfc-editor.org/rfc/rfc7541.html#section-6.3)
Dynamic Table Size Update for the beginning of the next encoded field block.
Calling `encoder.table.resize(...)` is insufficient: it evicts local entries
without informing the peer decoder.

The HTTP/2 layer remains responsible for SETTINGS state and timing. It will
invoke this API as the peer's `SETTINGS_HEADER_TABLE_SIZE` becomes effective
and ensure the SETTINGS acknowledgement precedes the next field block. HPACK
should not model SETTINGS frames or acknowledgements.

### Required behavior

- Provide a documented API such as `Encoder#resize_table(size : Int32)`.
  Reject negative and unrepresentable sizes.
- Resize the local dynamic table immediately. A decrease must evict entries;
  a later increase must not restore them.
- Prefix the next field block with the pending update, before every header
  representation, for every `encode` and `encode_into` overload.
- Encode the instruction as `001xxxxx` with a five-bit integer prefix.
- Coalesce multiple changes made between field blocks according to
  [RFC 7541 §4.2](https://www.rfc-editor.org/rfc/rfc7541.html#section-4.2):
  emit the smallest requested size, followed by the final size when it differs.
  Emit no more than two updates.
- Treat an unchanged size as a no-op. Clear pending updates after one
  successful field-block encoding, not after an encoding failure.
- Include pending-update state in the encoder's existing locking and
  transactional behavior, including `-Dpreview_mt` builds.
- Do not change existing output when the new API is unused.

Examples:

```text
4096 → 1024 → 2048  emits 1024, then 2048
4096 → 2048 → 1024  emits 1024
4096 → 4096         emits nothing
```

### Tests and acceptance

Add exact wire tests for sizes `0` (`20`), `31` (`3f 00`), and `4096`
(`3f e1 1f`). Cover eviction, decrease-then-increase behavior, every public
encoding path (including an empty field block), one-block-only emission,
failure rollback, and `preview_mt` synchronization. The existing suite must
remain green, and formatting, Ameba, and normal plus `-Dpreview_mt` specs must
pass.

## 2. Bounded, Incremental Decoder Output

**Status:** still required; `hpack.cr` 1.2.0 does not provide `decode_each`,
decoded field-section accounting, or a hard decoded-string cap.

### Goal

Let an HTTP/2 connection consume decoded fields in wire order while enforcing
a decompressed field-section budget without accumulating an unbounded
`HTTP::Headers` and metadata array.

This cannot simply stop decoding at the limit.
[RFC 9113 §4.3](https://www.rfc-editor.org/rfc/rfc9113.html#section-4.3)
requires a discarded field block to be fully decompressed so the connection's
compression context stays synchronized. After the limit is crossed, the
decoder must suppress further retained output but continue parsing
representations and applying dynamic-table changes through the end of the
block.

### Required behavior

- Add an incremental API, for example `Decoder#decode_each`, that yields one
  `DecodedHeader` at a time in wire order. Preserve duplicates and indexing
  metadata.
- Support an optional field-section limit. Use the
  [RFC 9113 §6.5.2](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.5.2)
  accounting rule: add `name.bytesize + value.bytesize + 32` for every decoded
  field, using checked wide-integer arithmetic.
- Report the final decoded byte count and whether the limit was exceeded.
  A distinct `HPack::LimitError` raised *after successful decompression* is
  also acceptable. It must not be reported as malformed compression.
- Once over budget, stop retaining or yielding fields, but finish decoding and
  update the dynamic table. A subsequent block must remain decodable.
- If the remainder of an over-budget block is malformed, report the compression
  error instead of the earlier size violation; the decoder is no longer safe
  to reuse.
- Keep `decode` and `decode_with_metadata` source-compatible and unlimited by
  default. They may share the incremental implementation internally.
- Define callback-exception semantics explicitly; an exception must not leave
  a decoder that appears reusable with ambiguous table state.
- Add a configurable hard cap for a single decoded string literal, or otherwise
  document and test how a caller prevents one literal from exhausting memory.
  Exceeding this hard resource cap may invalidate the decoder and therefore the
  HTTP/2 connection.

One suitable shape is a callback plus a result value:

```crystal
result = decoder.decode_each(encoded, max_field_section_size: 64 * 1024) do |field|
  # Validate or copy the field before the next callback.
end
# result.decoded_size and result.limit_exceeded
```

The exact names are not prescribed; state-preserving behavior and backward
compatibility are.

The API must not contain HTTP/2 error codes. The HTTP/2 layer decides whether
an exceeded budget is a stream rejection, `ENHANCE_YOUR_CALM`, or a connection
shutdown.

### Tests and acceptance

Cover below, exactly at, and above the limit; duplicate and indexed fields;
Huffman and raw literals; callback order; and callback-only operation without
array accumulation. Most importantly, decode an over-limit block that inserts
a dynamic entry, then decode a second block that references that entry.
Malformed input must still raise the existing HPACK error type. Existing APIs
and fixtures, formatting, Ameba, and normal plus `-Dpreview_mt` specs must pass.
