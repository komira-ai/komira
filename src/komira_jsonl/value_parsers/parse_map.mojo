# =============================================================================
# parse_map — JSON object → MapArray value parser (Tier 2 nested)
# =============================================================================
#
# Column kind MAP<keys, values>:
#   - JSON input grammar: `{...}` with a uniform value type (per Arrow Map
#     spec, lowered physically to `List<Struct<key, value>>`).
#   - Column builder: `Column.from_map(keys_column, values_column)`.
#   - Required metadata: child Fields for key + value.
#   - Validity rule: absent or null → clear bit (offsets unchanged).
#   - Arrow Map keys MUST be STRING (Arrow spec restricts non-string keys).
#
# Public surface (this module):
#   - `parse_map_one_value(bytes, idx, mut tape_pos, value_arrow_type,
#                          mut keys_acc, mut value_*_vals, mut value_nulls,
#                          depth) raises -> Int32`
#       Parse ONE JSON object as a single MAP value. Walks (key, value)
#       pairs; appends the STRING key to `keys_acc`; appends the value
#       (per-arrow-type dispatch) to the matching value accumulator List.
#       Returns the number of (key, value) entries parsed.
#       `tape_pos` is advanced past the matching TAG_CLOSE_BRACE.
#
# Encapsulation discipline:
#   - `Span[UInt8, _]` input; no `UnsafePointer` in any public surface.
#   - Per-entry accumulator List refs passed via `mut` parameters.
#
# Scope:
#   - Key arrow_type: STRING (Arrow Map spec).
#   - Value arrow_type: INT64 / FLOAT64 / BOOL / STRING / DATE32.
#   - Nested LIST / STRUCT / MAP value (recursive nested) RAISES (single-level nesting only).
# =============================================================================

from komira_arrow.arrow_types import ArrowType

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
from komira_jsonl.value_parsers.parse_bool import parse_bool, parse_null
from komira_jsonl.value_parsers.parse_date import parse_date32
from komira_jsonl.value_parsers.parse_float import parse_float_f64
from komira_jsonl.value_parsers.parse_int import parse_int_i64
from komira_json_index.parse_string import (
    parse_string_raw,
    parse_string_with_escapes,
)
from komira_buffer.heap_region import HeapRegion


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


def parse_map_one_value(
    bytes: Span[UInt8, _],
    idx: StructuralIndex,
    mut tape_pos: Int,
    value_arrow_type: ArrowType,
    mut keys_acc: List[String],
    mut value_int_vals: List[Int64],
    mut value_float_vals: List[Float64],
    mut value_bool_vals: List[Bool],
    mut value_string_vals: List[String],
    mut value_date_vals: List[Int32],
    mut value_nulls: List[Bool],
    depth: Int,
) raises -> Int32:
    """Parse one JSON object as a single MAP row.

    On entry: `idx.tags[tape_pos]` MUST be `TAG_OPEN_BRACE`.
    On exit: `tape_pos` advanced past the matching `TAG_CLOSE_BRACE`.

    For each (key, value) pair: appends the STRING key to `keys_acc`,
    dispatches the value through the appropriate scalar parser, and
    appends a per-entry validity bit to `value_nulls`. Returns the number
    of entries.

    Raises on:
      * `depth > DEPTH_LIMIT`.
      * Unbalanced object (no matching TAG_CLOSE_BRACE).
      * Value parse error.
      * Value is LIST / STRUCT / MAP (recursive nesting).
    """
    if depth > DEPTH_LIMIT:
        raise Error(
            "parse_map_one_value: nested JSON exceeds depth limit "
            + String(DEPTH_LIMIT)
        )

    var tape_len = idx.size()
    if tape_pos >= tape_len:
        raise Error("parse_map_one_value: tape position out of range")
    if idx.tags[tape_pos] != TAG_OPEN_BRACE:
        raise Error(
            "parse_map_one_value: expected TAG_OPEN_BRACE at tape pos "
            + String(tape_pos)
        )
    var open_offset = Int(idx.offsets[tape_pos])
    tape_pos += 1  # consume '{'

    var entry_count: Int32 = 0

    while tape_pos < tape_len:
        var tag = idx.tags[tape_pos]
        if tag == TAG_CLOSE_BRACE:
            tape_pos += 1
            return entry_count
        if tag == TAG_COMMA:
            tape_pos += 1
            continue
        if tag != TAG_QUOTE_OPEN:
            raise Error(
                "parse_map_one_value: expected TAG_QUOTE_OPEN for key at tape pos "
                + String(tape_pos)
            )

        # Key (always STRING per Arrow Map spec).
        var quote_open = Int(idx.offsets[tape_pos])
        tape_pos += 1
        if tape_pos >= tape_len or idx.tags[tape_pos] != TAG_QUOTE_CLOSE:
            raise Error(
                "parse_map_one_value: missing TAG_QUOTE_CLOSE for key at byte "
                + String(quote_open)
            )
        var quote_close = Int(idx.offsets[tape_pos])
        tape_pos += 1
        var key_start = quote_open + 1
        var key_end = quote_close
        var key_has_escapes = False
        for j in range(key_start, key_end):
            if bytes[j] == UInt8(0x5C):
                key_has_escapes = True
                break
        var key_str: String
        if key_has_escapes:
            key_str = parse_string_with_escapes(bytes, key_start, key_end)
        else:
            key_str = parse_string_raw(bytes, key_start, key_end)
        keys_acc.append(key_str^)

        # Colon.
        if tape_pos >= tape_len or idx.tags[tape_pos] != TAG_COLON:
            raise Error(
                "parse_map_one_value: expected TAG_COLON after key at byte "
                + String(quote_open)
            )
        var colon_offset = Int(idx.offsets[tape_pos])
        tape_pos += 1

        # Value.
        if tape_pos >= tape_len:
            raise Error(
                "parse_map_one_value: truncated input (expected value after key)"
            )
        var value_tag = idx.tags[tape_pos]

        if value_tag == TAG_QUOTE_OPEN:
            var v_start = Int(idx.offsets[tape_pos])
            tape_pos += 1
            if tape_pos >= tape_len or idx.tags[tape_pos] != TAG_QUOTE_CLOSE:
                raise Error(
                    "parse_map_one_value: missing TAG_QUOTE_CLOSE for value at byte "
                    + String(v_start)
                )
            var v_end = Int(idx.offsets[tape_pos])
            tape_pos += 1
            if value_arrow_type == ArrowType.STRING:
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
                value_string_vals.append(s^)
                value_nulls.append(False)
            elif value_arrow_type == ArrowType.DATE32:
                var d = parse_date32(bytes, v_start + 1, v_end)
                value_date_vals.append(d)
                value_nulls.append(False)
            else:
                raise Error(
                    "parse_map_one_value: value arrow_type "
                    + String(Int(value_arrow_type.type_id))
                    + " does not accept a JSON string value"
                )
        elif value_tag == TAG_OPEN_BRACE or value_tag == TAG_OPEN_BRACKET:
            raise Error(
                "parse_map_one_value: nested LIST/STRUCT/MAP map values are not"
                " supported (single-level nesting only)"
            )
        else:
            # Interior scalar.
            var next_offset = Int(idx.offsets[tape_pos])
            var s_start = colon_offset + 1
            while s_start < next_offset and _is_ws(bytes[s_start]):
                s_start += 1
            var s_end = next_offset
            while s_end > s_start and _is_ws(bytes[s_end - 1]):
                s_end -= 1
            if s_end <= s_start:
                raise Error(
                    "parse_map_one_value: empty scalar value after key at byte "
                    + String(quote_open)
                )
            if (s_end - s_start) == 4 and bytes[s_start] == UInt8(0x6E):
                parse_null(bytes, s_start, s_end)
                if value_arrow_type == ArrowType.INT64:
                    value_int_vals.append(Int64(0))
                elif value_arrow_type == ArrowType.FLOAT64:
                    value_float_vals.append(Float64(0.0))
                elif value_arrow_type == ArrowType.BOOL:
                    value_bool_vals.append(False)
                elif value_arrow_type == ArrowType.STRING:
                    value_string_vals.append(String(""))
                elif value_arrow_type == ArrowType.DATE32:
                    value_date_vals.append(Int32(0))
                else:
                    raise Error(
                        "parse_map_one_value: value arrow_type "
                        + String(Int(value_arrow_type.type_id))
                        + " not supported"
                    )
                value_nulls.append(True)
            elif value_arrow_type == ArrowType.INT64:
                var v = parse_int_i64(bytes, s_start, s_end)
                value_int_vals.append(v)
                value_nulls.append(False)
            elif value_arrow_type == ArrowType.FLOAT64:
                var v = parse_float_f64(bytes, s_start, s_end)
                value_float_vals.append(v)
                value_nulls.append(False)
            elif value_arrow_type == ArrowType.BOOL:
                var v = parse_bool(bytes, s_start, s_end)
                value_bool_vals.append(v)
                value_nulls.append(False)
            else:
                raise Error(
                    "parse_map_one_value: value arrow_type "
                    + String(Int(value_arrow_type.type_id))
                    + " expects quoted form but got unquoted scalar at byte "
                    + String(s_start)
                )
        entry_count += Int32(1)
    raise Error(
        "parse_map_one_value: unterminated object — no matching TAG_CLOSE_BRACE"
        " for TAG_OPEN_BRACE at byte " + String(open_offset)
    )
