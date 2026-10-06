# =============================================================================
# parse_list — JSON array → ListArray value parser (Tier 2 nested)
# =============================================================================
#
# Column kind LIST<inner>:
#   - JSON input grammar: `[v0, v1, ...]`.
#   - Column builder: `Column.from_list(child_column, offsets)`.
#   - Required metadata: child Field for inner type (carried via the parent
#     Field's `_child_names[0]` / `_child_types[0]` slots).
#   - Validity rule: absent or null → clear bit (offsets unchanged).
#
# Public surface (this module):
#   - `parse_list_one_value(bytes, idx, mut tape_pos, child_arrow_type,
#                           mut child_int_vals, mut child_float_vals,
#                           mut child_bool_vals, mut child_string_vals,
#                           mut child_date_vals, mut child_nulls,
#                           depth) raises -> Int32`
#       Parse ONE JSON array starting at `tape_pos` (which MUST be at a
#       TAG_OPEN_BRACKET). Walks elements, dispatching each through the
#       appropriate scalar parser; appends inner values to the child-level
#       accumulator lists. Returns the count of child elements appended.
#       `tape_pos` is advanced past the matching TAG_CLOSE_BRACKET.
#
# Encapsulation discipline:
#   - `Span[UInt8, _]` input, `StructuralIndex` read-only ref input. No raw
#     `UnsafePointer` in any public surface.
#   - Recursion via runtime `depth` parameter (free-function recursion;
#     depth > 20 raises).
#
# Scope:
#   - Inner type: INT64 / FLOAT64 / BOOL / STRING / DATE32 (the scalar
#     parsers).
#   - Inner LIST / STRUCT / MAP (recursive nested) RAISES — single-level
#     nesting only.
# =============================================================================

from komira_arrow.arrow_types import ArrowType

from komira_json_index.simd_primitives import (
    TAG_OPEN_BRACKET,
    TAG_CLOSE_BRACKET,
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
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


def parse_list_one_value(
    bytes: Span[UInt8, _],
    idx: StructuralIndex,
    mut tape_pos: Int,
    child_arrow_type: ArrowType,
    mut child_int_vals: List[Int64],
    mut child_float_vals: List[Float64],
    mut child_bool_vals: List[Bool],
    mut child_string_vals: List[String],
    mut child_date_vals: List[Int32],
    mut child_nulls: List[Bool],
    depth: Int,
) raises -> Int32:
    """Parse one JSON array starting at `tape_pos`.

    On entry: `idx.tags[tape_pos]` MUST be `TAG_OPEN_BRACKET`.
    On exit: `tape_pos` points to the first tape position AFTER the matching
    `TAG_CLOSE_BRACKET`. Returns the number of inner elements appended to
    the child accumulators.

    `child_arrow_type` selects which child-accumulator List receives the
    parsed values; the OTHER child lists are unmodified. `child_nulls`
    accumulates per-child-element validity (True = null).

    Raises on:
      * `depth > DEPTH_LIMIT`.
      * Inner element is LIST / STRUCT / MAP (recursive nesting).
      * Unbalanced / malformed array (no matching TAG_CLOSE_BRACKET).
      * Inner scalar parse error (overflow, bad literal, etc.).
    """
    if depth > DEPTH_LIMIT:
        raise Error(
            "parse_list_one_value: nested JSON exceeds depth limit "
            + String(DEPTH_LIMIT)
        )

    var tape_len = idx.size()
    if tape_pos >= tape_len:
        raise Error("parse_list_one_value: tape position out of range")
    if idx.tags[tape_pos] != TAG_OPEN_BRACKET:
        raise Error(
            "parse_list_one_value: expected TAG_OPEN_BRACKET at tape pos "
            + String(tape_pos) + ", got tag=" + String(Int(idx.tags[tape_pos]))
        )
    var open_offset = Int(idx.offsets[tape_pos])
    tape_pos += 1  # consume '['

    var elem_count: Int32 = 0
    # `prev_offset` is the byte offset of the LAST consumed structural
    # ('[' or ','). Used to compute the byte range of an interior scalar
    # element (digits / true / false / null) which is NOT structural and
    # has no tape entry.
    var prev_offset = open_offset

    while tape_pos < tape_len:
        var tag = idx.tags[tape_pos]

        # Before dispatching on the next structural, peek whether there is a
        # scalar value between `prev_offset+1` and the offset of this tag.
        # That covers `[42]`, `[1, 2]`, `[null]` etc. — JSON numbers / true /
        # false / null are not emitted as structural tokens by Stage 1.
        var next_off = Int(idx.offsets[tape_pos])
        var seg_start = prev_offset + 1
        while seg_start < next_off and _is_ws(bytes[seg_start]):
            seg_start += 1
        var seg_end = next_off
        while seg_end > seg_start and _is_ws(bytes[seg_end - 1]):
            seg_end -= 1
        if seg_end > seg_start:
            # Interior scalar element.
            if (seg_end - seg_start) == 4 and bytes[seg_start] == UInt8(0x6E):
                parse_null(bytes, seg_start, seg_end)
                if child_arrow_type == ArrowType.INT64:
                    child_int_vals.append(Int64(0))
                elif child_arrow_type == ArrowType.FLOAT64:
                    child_float_vals.append(Float64(0.0))
                elif child_arrow_type == ArrowType.BOOL:
                    child_bool_vals.append(False)
                elif child_arrow_type == ArrowType.STRING:
                    child_string_vals.append(String(""))
                elif child_arrow_type == ArrowType.DATE32:
                    child_date_vals.append(Int32(0))
                else:
                    raise Error(
                        "parse_list_one_value: child arrow_type "
                        + String(Int(child_arrow_type.type_id))
                        + " not supported"
                    )
                child_nulls.append(True)
                elem_count += Int32(1)
            elif child_arrow_type == ArrowType.INT64:
                var v = parse_int_i64(bytes, seg_start, seg_end)
                child_int_vals.append(v)
                child_nulls.append(False)
                elem_count += Int32(1)
            elif child_arrow_type == ArrowType.FLOAT64:
                var v = parse_float_f64(bytes, seg_start, seg_end)
                child_float_vals.append(v)
                child_nulls.append(False)
                elem_count += Int32(1)
            elif child_arrow_type == ArrowType.BOOL:
                var v = parse_bool(bytes, seg_start, seg_end)
                child_bool_vals.append(v)
                child_nulls.append(False)
                elem_count += Int32(1)
            else:
                # STRING / DATE32 in interior-scalar position is a type error.
                raise Error(
                    "parse_list_one_value: child arrow_type "
                    + String(Int(child_arrow_type.type_id))
                    + " expected a quoted form but got unquoted scalar at byte "
                    + String(seg_start)
                )

        if tag == TAG_CLOSE_BRACKET:
            tape_pos += 1
            return elem_count
        if tag == TAG_COMMA:
            prev_offset = next_off
            tape_pos += 1
            continue

        # Element value at tape_pos with a structural tag. Dispatch by tag.
        if tag == TAG_QUOTE_OPEN:
            # STRING element.
            var v_start = Int(idx.offsets[tape_pos])
            tape_pos += 1
            if tape_pos >= tape_len or idx.tags[tape_pos] != TAG_QUOTE_CLOSE:
                raise Error(
                    "parse_list_one_value: missing TAG_QUOTE_CLOSE for string"
                    " element at byte " + String(v_start)
                )
            var v_end = Int(idx.offsets[tape_pos])
            tape_pos += 1
            if child_arrow_type == ArrowType.STRING:
                # Detect escapes by scanning for '\\' within the byte range.
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
                child_string_vals.append(s^)
                child_nulls.append(False)
            elif child_arrow_type == ArrowType.DATE32:
                var d = parse_date32(bytes, v_start + 1, v_end)
                child_date_vals.append(d)
                child_nulls.append(False)
            else:
                raise Error(
                    "parse_list_one_value: child arrow_type "
                    + String(Int(child_arrow_type.type_id))
                    + " does not accept a JSON string element"
                )
            prev_offset = v_end
            elem_count += Int32(1)
        elif tag == TAG_OPEN_BRACKET or tag == TAG_OPEN_BRACE:
            # Nested array / object — recursive nesting is not supported.
            raise Error(
                "parse_list_one_value: nested LIST/STRUCT/MAP elements are"
                " not supported (single-level nesting only)"
            )
        else:
            # Should not reach — interior scalars handled above; structural
            # CLOSE_BRACKET / COMMA / QUOTE_OPEN already dispatched. Other
            # tags (CLOSE_BRACE for arrays would be a structural mismatch).
            raise Error(
                "parse_list_one_value: unexpected structural tag inside array: "
                + String(Int(tag))
            )
    raise Error(
        "parse_list_one_value: unterminated array — no matching TAG_CLOSE_BRACKET"
        " for TAG_OPEN_BRACKET at byte " + String(open_offset)
    )
