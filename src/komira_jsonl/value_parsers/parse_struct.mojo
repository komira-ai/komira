# =============================================================================
# parse_struct — JSON object → StructArray value parser (Tier 2 nested)
# =============================================================================
#
# Column kind STRUCT<fields...>:
#   - JSON input grammar: `{...}` with key-by-key recursive parse.
#   - Column builder: `Column.from_struct(child_columns, field_names)`.
#   - Required metadata: child Field list (`_child_names` / `_child_types` /
#     `_child_nullables`).
#   - Validity rule: absent or null → clear parent bit; children retain
#     own validity.
#
# Public surface (this module):
#   - `parse_struct_one_value(bytes, idx, mut tape_pos, child_names,
#                             child_arrow_types, child_writers, depth) -> Bool`
#       Parse ONE JSON object starting at `tape_pos` (which MUST be at a
#       TAG_OPEN_BRACE). Walks (key, value) pairs, dispatching each value
#       through the appropriate scalar parser. Per-child writers accumulate
#       per-row values. Returns True iff at least one field was populated
#       (used by the materializer to distinguish empty-object from missing
#       row at struct level).
#
# Encapsulation discipline:
#   - `Span[UInt8, _]` input, `StructuralIndex` ref input. No `UnsafePointer`
#     in any public surface.
#   - Per-field child writes are routed via per-field accumulator List refs
#     passed in by the caller (the materializer owns the per-row vectors).
#
# Scope:
#   - Child field arrow_type: INT64 / FLOAT64 / BOOL / STRING / DATE32.
#   - Child LIST / STRUCT / MAP (recursive nested) RAISES (single-level nesting only).
#     A nested value under a key the struct does not read is skipped.
#   - Keys are matched as the text they spell (escapes decoded,
#     key_unescape.mojo); a child key repeated in one object raises.
#   - Out-of-order JSON keys handled (key→field lookup in child_names).
#   - Partial-fields: any field whose key is NOT present in the JSON object
#     for this row → that field's writer push_null arm fires.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType

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
from komira_json_index.structural_index import StructuralIndex
from komira_jsonl.key_unescape import key_has_escape, unescape_key
from komira_jsonl.value_parsers.parse_bool import parse_bool, parse_null
from komira_jsonl.value_parsers.parse_date import parse_date32
from komira_jsonl.value_parsers.parse_float import parse_float_f64
from komira_jsonl.value_parsers.parse_int import parse_int_i64
from komira_json_index.parse_string import (
    parse_string_raw,
    parse_string_with_escapes,
)


comptime DEPTH_LIMIT: Int = 20


@always_inline
def _is_ws(b: UInt8) -> Bool:
    """RFC 8259 §2 whitespace: space, tab, LF, CR."""
    return (
        b == UInt8(0x20)
        or b == UInt8(0x09)
        or b == UInt8(0x0A)
        or b == UInt8(0x0D)
    )


def _child_field_index(child_names: List[String], key_bytes: Span[UInt8, _]) -> Int:
    """Lookup a child-field index by name. -1 if not found. Same cmp-cascade
    shape as KeyTable.lookup."""
    var kn = len(key_bytes)
    for i in range(len(child_names)):
        var kb = child_names[i].as_bytes()
        var n = len(kb)
        if n != kn:
            continue
        var matches = True
        for j in range(n):
            if kb[j] != key_bytes[j]:
                matches = False
                break
        if matches:
            return i
    return -1


def parse_struct_one_value(
    bytes: Span[UInt8, _],
    idx: StructuralIndex,
    mut tape_pos: Int,
    child_names: List[String],
    child_arrow_types: List[ArrowType],
    mut child_int_vals: List[List[Int64]],
    mut child_float_vals: List[List[Float64]],
    mut child_bool_vals: List[List[Bool]],
    mut child_string_vals: List[List[String]],
    mut child_date_vals: List[List[Int32]],
    mut child_nulls: List[List[Bool]],
    depth: Int,
) raises -> Bool:
    """Parse one JSON object as a STRUCT row.

    On entry: `idx.tags[tape_pos]` MUST be `TAG_OPEN_BRACE`.
    On exit: `tape_pos` points to the first tape position AFTER the matching
    `TAG_CLOSE_BRACE`.

    For each child field (in `child_names`), exactly ONE element is appended
    to its per-child accumulator List — either the parsed value or a null
    (if the key was absent in this JSON object).

    Returns True iff the object had at least one matching key.

    Raises on:
      * `depth > DEPTH_LIMIT`.
      * Unbalanced object (no matching TAG_CLOSE_BRACE).
      * Per-field parse error (type mismatch, overflow, etc.).
      * A child field that is LIST / STRUCT / MAP (recursive nesting).
    """
    if depth > DEPTH_LIMIT:
        raise Error(
            "parse_struct_one_value: nested JSON exceeds depth limit "
            + String(DEPTH_LIMIT)
        )

    var tape_len = idx.size()
    var n_children = len(child_names)
    if tape_pos >= tape_len:
        raise Error("parse_struct_one_value: tape position out of range")
    if idx.tags[tape_pos] != TAG_OPEN_BRACE:
        raise Error(
            "parse_struct_one_value: expected TAG_OPEN_BRACE at tape pos "
            + String(tape_pos)
        )
    var open_offset = Int(idx.offsets[tape_pos])
    tape_pos += 1  # consume '{'

    # Track which child fields have been populated for THIS row.
    var per_field_seen = List[Bool](capacity=n_children)
    for _ in range(n_children):
        per_field_seen.append(False)

    var any_match = False

    while tape_pos < tape_len:
        var tag = idx.tags[tape_pos]
        if tag == TAG_CLOSE_BRACE:
            tape_pos += 1
            # For any child field NOT populated, push null.
            for c in range(n_children):
                if not per_field_seen[c]:
                    var at = child_arrow_types[c]
                    if at == ArrowType.INT64:
                        child_int_vals[c].append(Int64(0))
                    elif at == ArrowType.FLOAT64:
                        child_float_vals[c].append(Float64(0.0))
                    elif at == ArrowType.BOOL:
                        child_bool_vals[c].append(False)
                    elif at == ArrowType.STRING:
                        child_string_vals[c].append(String(""))
                    elif at == ArrowType.DATE32:
                        child_date_vals[c].append(Int32(0))
                    else:
                        raise Error(
                            "parse_struct_one_value: child field "
                            + child_names[c] + " has unsupported arrow_type "
                            + String(Int(at.type_id))
                        )
                    child_nulls[c].append(True)
            return any_match
        if tag == TAG_COMMA:
            tape_pos += 1
            continue
        if tag != TAG_QUOTE_OPEN:
            raise Error(
                "parse_struct_one_value: expected TAG_QUOTE_OPEN at tape pos "
                + String(tape_pos) + ", got tag=" + String(Int(tag))
            )

        # Key.
        var quote_open = Int(idx.offsets[tape_pos])
        tape_pos += 1
        if tape_pos >= tape_len or idx.tags[tape_pos] != TAG_QUOTE_CLOSE:
            raise Error(
                "parse_struct_one_value: missing TAG_QUOTE_CLOSE for key at byte "
                + String(quote_open)
            )
        var quote_close = Int(idx.offsets[tape_pos])
        tape_pos += 1
        var key_start = quote_open + 1
        var key_end = quote_close
        # Looked up as the text the key spells (key_unescape.mojo).
        var field_idx: Int
        if key_has_escape(bytes[key_start:key_end]):
            var key_buf = List[UInt8]()
            unescape_key(bytes[key_start:key_end], key_buf)
            field_idx = _child_field_index(child_names, key_buf)
        else:
            field_idx = _child_field_index(child_names, bytes[key_start:key_end])
        # A child key repeated in one object would push a second value into
        # the child column and shift every later row: refused (the
        # materializer's duplicate-key rule, columnar_materializer.mojo).
        if field_idx >= 0 and per_field_seen[field_idx]:
            raise Error(
                "duplicate key '" + child_names[field_idx]
                + "' in one object (a key the schema reads may appear once)"
            )

        # Colon.
        if tape_pos >= tape_len or idx.tags[tape_pos] != TAG_COLON:
            raise Error(
                "parse_struct_one_value: expected TAG_COLON after key at byte "
                + String(quote_open)
            )
        var colon_offset = Int(idx.offsets[tape_pos])
        tape_pos += 1

        # Value: dispatch by next tag (or interior-scalar between colon
        # and the next structural).
        if tape_pos >= tape_len:
            raise Error(
                "parse_struct_one_value: truncated input (expected value after"
                " key at byte " + String(quote_open) + ")"
            )
        var value_tag = idx.tags[tape_pos]

        if value_tag == TAG_QUOTE_OPEN:
            # STRING-typed value.
            var v_start = Int(idx.offsets[tape_pos])
            tape_pos += 1
            if tape_pos >= tape_len or idx.tags[tape_pos] != TAG_QUOTE_CLOSE:
                raise Error(
                    "parse_struct_one_value: missing TAG_QUOTE_CLOSE for value at byte "
                    + String(v_start)
                )
            var v_end = Int(idx.offsets[tape_pos])
            tape_pos += 1
            if field_idx >= 0:
                var at = child_arrow_types[field_idx]
                if at == ArrowType.STRING:
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
                    child_string_vals[field_idx].append(s^)
                    child_nulls[field_idx].append(False)
                    per_field_seen[field_idx] = True
                    any_match = True
                elif at == ArrowType.DATE32:
                    var d = parse_date32(bytes, v_start + 1, v_end)
                    child_date_vals[field_idx].append(d)
                    child_nulls[field_idx].append(False)
                    per_field_seen[field_idx] = True
                    any_match = True
                else:
                    raise Error(
                        "parse_struct_one_value: child '" + child_names[field_idx]
                        + "' has non-string arrow_type but JSON value is a string"
                    )
        elif value_tag == TAG_OPEN_BRACE or value_tag == TAG_OPEN_BRACKET:
            if field_idx >= 0:
                raise Error(
                    "parse_struct_one_value: nested LIST/STRUCT/MAP child fields are"
                    " not supported (single-level nesting only)"
                )
            # A key the struct does not read: skip its nested value, as the
            # materializer skips an unread top-level key's.
            var depth = 1
            tape_pos += 1
            while tape_pos < tape_len and depth > 0:
                var tg = idx.tags[tape_pos]
                if tg == TAG_OPEN_BRACE or tg == TAG_OPEN_BRACKET:
                    depth += 1
                elif tg == TAG_CLOSE_BRACE or tg == TAG_CLOSE_BRACKET:
                    depth -= 1
                tape_pos += 1
        else:
            # Interior scalar: bytes between colon_offset+1 and next-structural.
            var next_offset = Int(idx.offsets[tape_pos])
            var s_start = colon_offset + 1
            while s_start < next_offset and _is_ws(bytes[s_start]):
                s_start += 1
            var s_end = next_offset
            while s_end > s_start and _is_ws(bytes[s_end - 1]):
                s_end -= 1
            if s_end <= s_start:
                raise Error(
                    "parse_struct_one_value: empty scalar value after key at byte "
                    + String(quote_open)
                )
            if field_idx >= 0:
                var at = child_arrow_types[field_idx]
                # Explicit null first.
                if (s_end - s_start) == 4 and bytes[s_start] == UInt8(0x6E):
                    parse_null(bytes, s_start, s_end)
                    if at == ArrowType.INT64:
                        child_int_vals[field_idx].append(Int64(0))
                    elif at == ArrowType.FLOAT64:
                        child_float_vals[field_idx].append(Float64(0.0))
                    elif at == ArrowType.BOOL:
                        child_bool_vals[field_idx].append(False)
                    elif at == ArrowType.STRING:
                        child_string_vals[field_idx].append(String(""))
                    elif at == ArrowType.DATE32:
                        child_date_vals[field_idx].append(Int32(0))
                    else:
                        raise Error(
                            "parse_struct_one_value: child '" + child_names[field_idx]
                            + "' has unsupported arrow_type "
                            + String(Int(at.type_id))
                        )
                    child_nulls[field_idx].append(True)
                elif at == ArrowType.INT64:
                    var v = parse_int_i64(bytes, s_start, s_end)
                    child_int_vals[field_idx].append(v)
                    child_nulls[field_idx].append(False)
                elif at == ArrowType.FLOAT64:
                    var v = parse_float_f64(bytes, s_start, s_end)
                    child_float_vals[field_idx].append(v)
                    child_nulls[field_idx].append(False)
                elif at == ArrowType.BOOL:
                    var v = parse_bool(bytes, s_start, s_end)
                    child_bool_vals[field_idx].append(v)
                    child_nulls[field_idx].append(False)
                else:
                    raise Error(
                        "parse_struct_one_value: child '" + child_names[field_idx]
                        + "' expects quoted form but got unquoted scalar at byte "
                        + String(s_start)
                    )
                per_field_seen[field_idx] = True
                any_match = True
    raise Error(
        "parse_struct_one_value: unterminated object — no matching TAG_CLOSE_BRACE"
        " for TAG_OPEN_BRACE at byte " + String(open_offset)
    )
