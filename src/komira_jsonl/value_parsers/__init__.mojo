# =============================================================================
# value_parsers — per-Arrow-type JSON value parsers for the Stage 2 walker.
# =============================================================================
#
# Each parser turns a byte-range from the JSON input (located by Stage 1's
# structural-token tape) into a typed Arrow column entry.
#
# 9 parsers across two tiers:
#
#   Tier 1 (primitive + variable-length):
#     - `parse_int`       — JSON number → Int64 (or schema-narrowed Int*).
#     - `parse_float`     — JSON number → Float64 (scalar).
#     - `parse_string`    — JSON string (with unescape) → StringArray (in `komira_json_index`).
#     - `parse_bool`      — JSON true/false → Bool.
#     - `parse_date`      — ISO 8601 string → Int32 days-since-epoch.
#     - `parse_decimal`   — JSON number/string → Decimal128(p, s).
#     - `parse_list`      — JSON array → ListArray (recursive).
#
#   Tier 2 (nested):
#     - `parse_struct`    — JSON object → StructArray (recursive; per-key).
#     - `parse_map`       — JSON object → MapArray (uniform value type).
#
# Each module exports a `parse_<type>` function that returns either the
# parsed value (`raises` on malformed input) OR a `(value, bytes_consumed)`
# pair when the caller is interleaving with the structural tape (the
# walker calls into the parser at a specific tape position; the parser
# advances byte cursor and returns).
#
# Encapsulation discipline:
#   - All public surfaces take `Span[UInt8, _]` for byte input and
#     return typed values; no `UnsafePointer` in any public signature.
#   - Internal SIMD usage stays inside each parser module behind
#     `comptime if CompilationTarget.is_arm64()` arms.
# =============================================================================
