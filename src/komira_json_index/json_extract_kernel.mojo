# =============================================================================
# json_extract_kernel.mojo — Stage-2-skip walker for `json_extract`
# =============================================================================
#
# Implements the path-extract kernel
# behind `EXPR_JSON_EXTRACT` (the core packages' expression tag 19) for the SQL `->` / `->>`
# operators and the `json_extract(payload, path)` function.
#
# Mechanism (a) — per-row path-aware fast-path:
#   1. Build the Stage 1 structural index over THIS row's JSON-bytes only
#      (per-row, so the cost is bounded by the row's payload size).
#   2. Walk the tape: at depth-1 look for the first path segment as a key;
#      when found, descend into its value; repeat at depth-2, depth-3, ...
#      until all segments matched.
#   3. At the leaf, slice out the value bytes (still in JSON text form).
#   4. For `->` (preserve_extension_metadata=True), return the raw JSON
#      text slice (so `{"x": "alice"}` -> `"alice"` quoted; `{"x": 42}`
#      -> `42` unquoted).
#   5. For `->>` (preserve_extension_metadata=False), unquote+unescape
#      strings (so `{"x": "alice"}` -> `alice`); unquoted scalars pass
#      through identically.
#
# Public surface:
#   - `fn extract_column(parent: Column, path_segments: List[String],
#                        output_type: ArrowType, preserve_extension_metadata: Bool)
#         raises -> Column`
#     — column-level driver. Parent must be Arrow STRING. Output is
#     Arrow STRING (extension metadata attachment is the caller's job;
#     this kernel returns the bytes-correct Column).
#
# Encapsulation:
#   - Public surface accepts/returns `Column` + `List[String]` + `ArrowType`
#     + `Bool` — no `UnsafePointer` in any signature.
#   - Internal helpers (`_extract_one_row`, `_skip_value_at`,
#     `_walk_to_segment`) accept `Span[UInt8, _]` (origin-poly view) +
#     StructuralIndex.
#
# Precedent: the EXPR_STRUCT_FIELD / EXPR_MAP_GET column evaluators.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_json_index.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_OPEN_BRACKET,
    TAG_CLOSE_BRACKET,
    TAG_COLON,
    TAG_COMMA,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)
from komira_json_index.structural_index import StructuralIndex, build_structural_index
from komira_json_index.parse_string import (
    parse_string_raw,
    parse_string_with_escapes,
)
from komira_json_index.utf8_check import check_utf8


# =============================================================================
# _RowResult — kernel return discriminator
# =============================================================================
#
# A single row's extract result is one of:
#   - missing path  (row->null in output column)
#   - value present (carries the bytes-correct String)
#
# Encoded as a tiny Movable struct (NOT a tuple — a tuple-return
# `def f() -> (A, B)` doesn't typecheck against non-Copyable elements).


struct _RowResult(Movable):
    var found: Bool
    var value: String

    @always_inline
    def __init__(out self, found: Bool, var value: String):
        self.found = found
        self.value = value^

    @staticmethod
    @always_inline
    def miss() -> _RowResult:
        return _RowResult(False, String(""))

    @staticmethod
    @always_inline
    def hit(var v: String) -> _RowResult:
        return _RowResult(True, v^)

    @always_inline
    def take_value(var self) -> String:
        """Consume self, return owned `value`. Drops `found` (Bool, POD).
        Whole-self consume via `var self` + stdlib `swap` avoids the
        partial-move-via-field rule."""
        var out = String("")
        swap(self.value, out)
        return out^


# =============================================================================
# extract_column — public column-level driver (the eval-arm entry point)
# =============================================================================


def extract_column(
    parent: Column[HeapRegion],
    path_segments: List[String],
    output_type: ArrowType,
    preserve_extension_metadata: Bool,
) raises -> Column[HeapRegion]:
    """Driver: extract `path_segments` from every row of `parent`.

    `parent` MUST be an Arrow STRING column whose values are JSON text.
    `output_type` MUST be Arrow STRING (typed extract is not supported).
    `preserve_extension_metadata` discriminates `->` (True, raw JSON
    text slice) vs `->>` (False, unquoted+unescaped string).

    Returns a STRING Column with `parent.length()` rows. Rows where the
    path is missing OR where the row's parent value is null are emitted
    as null (validity bit clear). So is a row whose extracted value is not
    well-formed UTF-8 (`utf8_check`), the same as a row that is not JSON.

    ⚠ AND, WHEN `preserve_extension_metadata` IS FALSE (`->>`), rows whose
    extracted value is the JSON literal `null` — see the scalar arm of
    `_extract_scalar_value`. That is THREE distinct document conditions
    collapsing onto one SQL NULL, which is what DuckDB's `->>` does; `->`
    keeps them apart by returning the text `null` for the third.

    NOTE on extension metadata: the `->` / `->>` discriminator lives at
    the FIELD level in Arrow (`ARROW:extension:name = "komira.ext.json"`).
    This kernel produces the bytes-correct Column; the eval-arm caller
    is responsible for attaching extension metadata to the surrounding
    Field after this kernel returns. The kernel reads
    `preserve_extension_metadata` only to decide whether to unquote
    leaf string values (Mojo `->>` semantics drop quotes; `->` returns
    raw JSON-text bytes).
    """
    # Validate inputs.
    if Int(parent.arrow_type.type_id) != Int(ArrowType.STRING.type_id):
        raise Error(
            "extract_column: parent must be Arrow STRING column, got type_id="
            + String(Int(parent.arrow_type.type_id))
        )
    if Int(output_type.type_id) != Int(ArrowType.STRING.type_id):
        raise Error(
            "extract_column: only STRING output is supported (typed"
            " json_extract[T] is not); got output_type_id="
            + String(Int(output_type.type_id))
        )

    var n_rows = parent.length()
    var parent_sa = parent.as_string()

    var out_strs = List[String](capacity=n_rows)
    var validity = Bitmap.create_all_valid(n_rows)
    var null_count = 0

    for r in range(n_rows):
        # Parent row null? Result is null.
        if parent._validity:
            if not parent._validity.value().test(r):
                out_strs.append(String(""))
                validity.clear(r)
                null_count += 1
                continue
        # Fetch the row's JSON-bytes payload. parent_sa.get(r) copies
        # bytes into a fresh String; this is the same shape the
        # EXPR_MAP_GET eval-arm uses for its per-row probe (there is no
        # zero-copy Span-into-StringArray API).
        var payload = parent_sa.get(r)
        var payload_bytes = payload.as_bytes()
        # Per-row extract via the stage-2-skip walker (mechanism (a)).
        var found: Bool
        var value_str: String
        # Trivial path: zero segments = whole-document extract.
        # Return the whole payload verbatim.
        if len(path_segments) == 0:
            # The whole payload is the value, so it is checked whole; a row
            # that is not well-formed UTF-8 is nulled like malformed JSON.
            try:
                check_utf8(payload_bytes, 0, len(payload_bytes), "extract_column")
                found = True
                value_str = payload.copy()
            except:
                found = False
                value_str = String("")
        else:
            # Build Stage 1 structural index for this row's payload.
            # Per mechanism (a), this is bounded by the payload
            # size; for 1KB rows the cost is ~0.05-0.1 µs.
            try:
                var idx = build_structural_index(payload_bytes)
                var result = _extract_one_row(
                    payload_bytes,
                    idx,
                    path_segments,
                    preserve_extension_metadata,
                )
                found = result.found
                value_str = result^.take_value()
            except e:
                # Malformed JSON (e.g. unterminated string in payload).
                # Row becomes null: LENIENT is the default at the
                # json_extract surface (json_extract is a scalar function;
                # the SDK plumbs STRICT vs LENIENT at the schema level —
                # here the default is LENIENT, surfaced as null, matching
                # DuckDB's json_extract semantics).
                found = False
                value_str = String("")
        if found:
            out_strs.append(value_str^)
        else:
            out_strs.append(String(""))
            validity.clear(r)
            null_count += 1

    var out_sa = StringArray.from_strings(out_strs)
    if null_count > 0:
        out_sa.validity = validity^
        out_sa.null_count = null_count
    return Column.from_string(out_sa^)


# =============================================================================
# _extract_one_row — per-row stage-2-skip walker
# =============================================================================


def _extract_one_row(
    bytes: Span[UInt8, _],
    idx: StructuralIndex,
    path_segments: List[String],
    preserve_extension_metadata: Bool,
) raises -> _RowResult:
    """Walk the structural-index tape, descend into nested objects per
    `path_segments`, and return the leaf value.

    Returns `(found, value_str)`. `found=False` indicates the path
    didn't match (row should be null in output); `value_str` is empty.

    Walker semantics:
      - At depth 0, find the outer OPEN_BRACE.
      - Inside an object, walk key-value pairs:
        - KEY: TAG_QUOTE_OPEN ... TAG_QUOTE_CLOSE -> compare bytes to
          path_segments[depth].
        - COLON: TAG_COLON.
        - VALUE: dispatch on tag.
        - If key matches and there are more segments to descend,
          recurse into the value's OPEN_BRACE; else extract the value
          bytes verbatim.
        - If key mismatches, skip-walk the value via depth-counter.
      - At any close-brace at depth 0, the search is exhausted: return
        (False, "").

    `preserve_extension_metadata=True` (= `->` semantics) means leaf
    string values are returned WITH their surrounding quotes (raw JSON
    text slice). `False` (= `->>` semantics) means strings are unquoted
    + unescaped, but non-string scalars (numbers, true/false/null) pass
    through verbatim.
    """
    var tape_len = idx.size()
    var input_len = len(bytes)
    if tape_len == 0:
        return _RowResult.miss()
    var t: Int = 0
    # Find first OPEN_BRACE at depth 0.
    while t < tape_len and idx.tags[t] != TAG_OPEN_BRACE:
        t += 1
    if t >= tape_len:
        return _RowResult.miss()
    t += 1  # consume OPEN_BRACE
    return _walk_object(bytes, idx, t, path_segments, 0, preserve_extension_metadata, input_len)


def _walk_object(
    bytes: Span[UInt8, _],
    idx: StructuralIndex,
    start_t: Int,
    path_segments: List[String],
    seg_depth: Int,
    preserve_extension_metadata: Bool,
    input_len: Int,
) raises -> _RowResult:
    """Walk an open object at tape position `start_t`, looking for
    `path_segments[seg_depth]`. On match, either recurse into the value
    (if seg_depth+1 < total) or extract the value (if at leaf).
    """
    var tape_len = idx.size()
    var t = start_t
    var target_key = path_segments[seg_depth].as_bytes()
    var target_len = len(target_key)

    while t < tape_len:
        var tag = idx.tags[t]
        if tag == TAG_CLOSE_BRACE:
            # End of object; key not found.
            return _RowResult.miss()
        if tag == TAG_COMMA:
            t += 1
            continue
        if tag != TAG_QUOTE_OPEN:
            # Malformed (or skip non-quote structural).
            t += 1
            continue
        var quote_open_offset = Int(idx.offsets[t])
        t += 1
        if t >= tape_len or idx.tags[t] != TAG_QUOTE_CLOSE:
            return _RowResult.miss()
        var quote_close_offset = Int(idx.offsets[t])
        t += 1
        var key_start = quote_open_offset + 1
        var key_end = quote_close_offset
        var key_len = key_end - key_start
        # Compare key bytes to target.
        #
        # ⛔ THE COMPARISON IS AGAINST THE **DECODED** KEY; COMPARING THE
        #   RAW BYTES IS A SILENT WRONG ANSWER. A JSON key carries its
        #   escapes on the tape exactly as written — `{"a\"b":11}` stores the
        #   FOUR bytes `a`, `\`, `"`, `b` between the quotes — while a path
        #   segment is already decoded (`a"b`, three bytes). A raw memcmp
        #   cannot match ANY key containing an escape, and it does not raise
        #   or narrow: `json_extract` would answer SQL NULL, i.e. "that key
        #   is absent", for a key that is present.
        #   DuckDB v1.5.3:
        #     json_extract('{"a\"b":4}',  '$.a"b')      = 4
        #     json_extract('{"a\\tb":1}', '$."a\\tb"')  = 1
        #   ⇒ DuckDB matches on the DECODED key, so this does too.
        #
        # ⚠ THE FAST PATH IS THE POINT: keys with no backslash — every key in
        #   almost every document — still take the plain byte compare and
        #   allocate nothing. Only a key that actually carries an escape pays
        #   for a decode, and only until it either matches or is skipped.
        var key_matches = False
        var key_has_escape = False
        for j in range(key_start, key_end):
            if bytes[j] == UInt8(0x5C):
                key_has_escape = True
                break
        if key_has_escape:
            # ⚠ A MALFORMED ESCAPE IS A MISS, NOT A RAISE. `parse_string_with_
            #   escapes` raises on a lone surrogate / short `\u` / non-hex
            #   digit, and this kernel is LENIENT everywhere else — a row it
            #   cannot parse is nulled, never thrown. Raising here would make
            #   ONE key's encoding decide whether the whole query errors,
            #   which is a different contract from the one every other arm of
            #   this file keeps.
            try:
                var decoded = parse_string_with_escapes(bytes, key_start, key_end)
                var dk = decoded.as_bytes()
                if len(dk) == target_len:
                    key_matches = True
                    for j in range(target_len):
                        if dk[j] != target_key[j]:
                            key_matches = False
                            break
            except:
                key_matches = False
        elif key_len == target_len:
            key_matches = True
            for j in range(target_len):
                if bytes[key_start + j] != target_key[j]:
                    key_matches = False
                    break
        # Expect TAG_COLON after key.
        if t >= tape_len or idx.tags[t] != TAG_COLON:
            return _RowResult.miss()
        t += 1
        if t >= tape_len:
            return _RowResult.miss()
        # Peek value.
        var value_tag = idx.tags[t]
        if key_matches:
            # This is the matching key — either recurse or extract.
            if seg_depth + 1 < len(path_segments):
                # Must recurse: value must be an OPEN_BRACE.
                if value_tag != TAG_OPEN_BRACE:
                    # Path expects an object here but the value is a
                    # leaf (scalar, string, or array). Treat as
                    # "path not present" (DuckDB semantics — extract
                    # past a scalar returns NULL).
                    return _RowResult.miss()
                t += 1  # consume OPEN_BRACE
                return _walk_object(
                    bytes, idx, t, path_segments, seg_depth + 1,
                    preserve_extension_metadata, input_len,
                )
            else:
                # Leaf — extract value bytes.
                return _extract_value_at(
                    bytes, idx, t, preserve_extension_metadata, input_len,
                )
        else:
            # Skip this value via depth counter; continue to next key.
            t = _skip_value_at(idx, t, input_len)
    # Ran off the end without close-brace; treat as not found.
    return _RowResult.miss()


def _extract_value_at(
    bytes: Span[UInt8, _],
    idx: StructuralIndex,
    value_t: Int,
    preserve_extension_metadata: Bool,
    input_len: Int,
) raises -> _RowResult:
    """Extract the value starting at tape position `value_t` (the value's
    first tape entry).

    Dispatch:
      - STRING (TAG_QUOTE_OPEN): bytes between the two quotes.
        If preserve_extension_metadata: include the surrounding quotes
        (raw JSON text). Else: unquote + unescape.
      - OBJECT (TAG_OPEN_BRACE): bytes from '{' to matching '}'.
        Include the braces; raw JSON-text slice regardless of mode.
      - ARRAY (TAG_OPEN_BRACKET): bytes from '[' to matching ']'.
        Include the brackets; raw JSON-text slice regardless of mode.
      - SCALAR (number / true / false / null): bytes from after-colon
        (or whitespace-trimmed start) to next structural.
    """
    var tape_len = idx.size()
    if value_t >= tape_len:
        return _RowResult.miss()
    var value_tag = idx.tags[value_t]
    if value_tag == TAG_QUOTE_OPEN:
        var v_start = Int(idx.offsets[value_t])
        if value_t + 1 >= tape_len or idx.tags[value_t + 1] != TAG_QUOTE_CLOSE:
            return _RowResult.miss()
        var v_end = Int(idx.offsets[value_t + 1])
        if preserve_extension_metadata:
            # `->`: raw JSON text — include the quotes. Bytes are
            # bytes[v_start..v_end+1] inclusive of the closing quote.
            var raw = _slice_to_string(bytes, v_start, v_end + 1)
            return _RowResult.hit(raw^)
        else:
            # `->>`: unquoted + unescaped. v_start+1 .. v_end exclusive
            # of both quotes. Detect escapes by scanning for '\\'.
            var has_escapes = False
            for j in range(v_start + 1, v_end):
                if bytes[j] == UInt8(0x5C):
                    has_escapes = True
                    break
            var s: String
            if has_escapes:
                s = parse_string_with_escapes(bytes, v_start + 1, v_end)
            else:
                s = parse_string_raw(bytes, v_start + 1, v_end)
            return _RowResult.hit(s^)
    elif value_tag == TAG_OPEN_BRACE or value_tag == TAG_OPEN_BRACKET:
        # Nested object / array — raw JSON text slice including delimiters.
        var v_start = Int(idx.offsets[value_t])
        var end_t = _find_close_for(idx, value_t, input_len)
        if end_t < 0:
            return _RowResult.miss()
        var v_end_exclusive = Int(idx.offsets[end_t]) + 1
        var s = _slice_to_string(bytes, v_start, v_end_exclusive)
        return _RowResult.hit(s^)
    else:
        # Scalar (number / true / false / null). The value bytes are
        # between the colon's offset+1 (the byte after the colon) and
        # the next structural-token's offset, with whitespace trimmed
        # both ends. Stage 1 doesn't tag scalars, so we walk between
        # tape positions.
        #
        # `value_t` here is the tape position of the next structural
        # AFTER the value's bytes (since scalars don't emit a tape
        # tag). We need: scalar starts AFTER the prior tape entry's
        # offset (the colon), and ends AT bytes[value_t]'s offset.
        # But the caller passed `value_t` BEFORE consuming it — it's
        # actually the FIRST tape entry that could either be a scalar's
        # successor structural OR the colon-after-key's successor
        # (which is what we got from `_walk_object`). The COLON has
        # been consumed; `value_t` is the next entry, which for a
        # scalar value is the COMMA / CLOSE_BRACE that follows.
        #
        # So the scalar bytes are between (colon_offset + 1) and
        # (idx.offsets[value_t]) exclusive — but we need the colon
        # offset, which is one tape entry back. Walk back to find it.
        if value_t == 0:
            return _RowResult.miss()
        var prior_offset = Int(idx.offsets[value_t - 1])
        var next_offset: Int
        if value_t < tape_len:
            next_offset = Int(idx.offsets[value_t])
        else:
            next_offset = input_len
        # The colon byte at prior_offset is part of the prior token;
        # scalar bytes start at prior_offset+1.
        var s_start = prior_offset + 1
        var s_end = next_offset
        # Trim whitespace.
        while s_start < s_end and _is_json_ws(bytes[s_start]):
            s_start += 1
        while s_end > s_start and _is_json_ws(bytes[s_end - 1]):
            s_end -= 1
        if s_start >= s_end:
            return _RowResult.miss()
        # ★ THE ONE SCALAR SHAPE WHERE `->` AND `->>` DIVERGE.
        #
        # The JSON literal `null` has no VARCHAR form, so `->>`
        # (`json_extract_string`) answers **SQL NULL** — the row's validity
        # bit clear — where `->` (`json_extract`) answers the JSON value
        # `null`, i.e. the three-byte text. DuckDB v1.5.3 behaves this way;
        # Postgres `jsonb ->>` agrees.
        #
        # ⚠ THE BYTE COMPARISON IS A TYPE TEST **HERE AND ONLY HERE**, and the
        # reason is the branch it sits on. This is the `else` arm — the one
        # the walker reaches when the value's tape tag is NOT `TAG_QUOTE_OPEN`,
        # `TAG_OPEN_BRACE` or `TAG_OPEN_BRACKET` — so the four bytes `null`
        # here can only be the JSON literal. The STRING value `"null"` leaves
        # through the `TAG_QUOTE_OPEN` branch above and is untouched: it is a
        # VARCHAR whose content is `null`, and DuckDB answers it VALID.
        # ⛔ SO DO NOT "SIMPLIFY" THIS BY TESTING THE RETURNED STRING AFTER
        # UNQUOTING. That spelling is one line shorter, looks equivalent, and
        # silently nulls every `{"k":"null"}` row.
        # `test_diff_string_value_null_TEXT_is_not_SQL_NULL` is the arm that
        # fires on exactly that mistake.
        #
        # ⚠ `->` IS DELIBERATELY UNCHANGED. Its contract is the raw JSON-text
        # slice, and `null` IS that slice. Nulling it there would lose the
        # distinction between "the document holds JSON null" and "the path is
        # missing", which is a distinction `->` is the operator that keeps.
        if (
            not preserve_extension_metadata
            and s_end - s_start == 4
            and bytes[s_start] == UInt8(0x6E)      # 'n'
            and bytes[s_start + 1] == UInt8(0x75)  # 'u'
            and bytes[s_start + 2] == UInt8(0x6C)  # 'l'
            and bytes[s_start + 3] == UInt8(0x6C)  # 'l'
        ):
            return _RowResult.miss()
        var s = _slice_to_string(bytes, s_start, s_end)
        return _RowResult.hit(s^)


def _skip_value_at(idx: StructuralIndex, value_t: Int, input_len: Int) raises -> Int:
    """Skip-walk the value starting at tape position `value_t`. Returns
    the tape position AFTER the value (the next structural to process).

    Dispatch:
      - STRING (TAG_QUOTE_OPEN..TAG_QUOTE_CLOSE): skip 2 tape entries.
      - OBJECT (TAG_OPEN_BRACE): depth-counter walk to matching close.
      - ARRAY  (TAG_OPEN_BRACKET): depth-counter walk to matching close.
      - SCALAR: 0 tape entries consumed (scalars aren't tagged); just
        return `value_t` unchanged — the caller's next iteration will
        consume the COMMA / CLOSE_BRACE structural after the scalar.
    """
    var tape_len = idx.size()
    if value_t >= tape_len:
        return value_t
    var tag = idx.tags[value_t]
    if tag == TAG_QUOTE_OPEN:
        # Skip past TAG_QUOTE_CLOSE.
        if value_t + 1 < tape_len:
            return value_t + 2
        return tape_len
    elif tag == TAG_OPEN_BRACE or tag == TAG_OPEN_BRACKET:
        var depth: Int = 1
        var t = value_t + 1
        while t < tape_len and depth > 0:
            var tg = idx.tags[t]
            if tg == TAG_OPEN_BRACE or tg == TAG_OPEN_BRACKET:
                depth += 1
            elif tg == TAG_CLOSE_BRACE or tg == TAG_CLOSE_BRACKET:
                depth -= 1
            t += 1
        return t
    else:
        # Scalar — no tape entries to skip. The walker's next iteration
        # will consume the COMMA / CLOSE_BRACE structural that follows.
        return value_t


def _find_close_for(idx: StructuralIndex, open_t: Int, input_len: Int) -> Int:
    """Given a tape position of an OPEN_BRACE / OPEN_BRACKET, return the
    tape position of the matching CLOSE token. Returns -1 if mismatched.
    """
    var tape_len = idx.size()
    if open_t >= tape_len:
        return -1
    var open_tag = idx.tags[open_t]
    var close_target_a: UInt8
    var close_target_b: UInt8
    if open_tag == TAG_OPEN_BRACE:
        close_target_a = TAG_CLOSE_BRACE
        close_target_b = TAG_CLOSE_BRACE
    elif open_tag == TAG_OPEN_BRACKET:
        close_target_a = TAG_CLOSE_BRACKET
        close_target_b = TAG_CLOSE_BRACKET
    else:
        return -1
    var depth: Int = 1
    var t = open_t + 1
    while t < tape_len:
        var tg = idx.tags[t]
        if tg == TAG_OPEN_BRACE or tg == TAG_OPEN_BRACKET:
            depth += 1
        elif tg == close_target_a or tg == close_target_b:
            depth -= 1
            if depth == 0:
                return t
        t += 1
    return -1


def _slice_to_string(bytes: Span[UInt8, _], start: Int, end: Int) raises -> String:
    """Build a String from bytes[start..end). Mirrors
    parse_string._string_from_bytes pattern — NUL-terminate + ctor.
    Raises `_slice_to_string: invalid UTF-8 at byte <i>: <reason>` when the
    range is not well-formed UTF-8."""
    if end < start:
        raise Error("_slice_to_string: end < start")
    check_utf8(bytes, start, end, "_slice_to_string")
    var n = end - start
    var buf = List[UInt8](capacity=n + 1)
    for i in range(start, end):
        buf.append(bytes[i])
    buf.append(UInt8(0))
    # SAFETY: buf is alive through the ctor call; the ptr it passes is
    # a NUL-terminated buffer, checked well-formed UTF-8 above, that String
    # copies out immediately.
    return String(unsafe_from_utf8_ptr=buf.unsafe_ptr())


@always_inline
def _is_json_ws(b: UInt8) -> Bool:
    """True if `b` is a JSON whitespace byte (space / tab / CR / LF)."""
    return b == UInt8(0x20) or b == UInt8(0x09) or b == UInt8(0x0A) or b == UInt8(0x0D)
