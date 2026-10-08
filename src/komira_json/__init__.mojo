"""`komira_json`: a small, dependency-free JSON library (RFC 8259).

Modules:
  - value.mojo : `JsonValue`, a tagged value over the six JSON kinds, with
                 typed accessors, positional enumeration, builder verbs and
                 `serialize()`; the `JSON_*` kind tags; the integer text
                 parsers `parse_int64_text` / `parse_uint64_text`.
  - parse.mojo : `parse_json_value` / `parse_json_bytes`, a strict
                 non-recursive parser with a nesting-depth limit
                 (`JSON_DEFAULT_MAX_DEPTH`, capped at `JSON_MAX_DEPTH`).
  - duplicates.mojo : `refuse_duplicate_keys`, which raises if any object
                 in a parsed value names a member twice (for formats such as
                 JWS, JWT and JWK that require duplicates to be refused).
  - write.mojo : direct-byte writers into a `List[UInt8]`:
                 `write_json_string`, `write_json_null`, `write_json_bool`,
                 `write_i64_dec`, `write_u64_dec`, `write_f64_dtoa`.

What the parser accepts is exactly the RFC 8259 grammar, with these
choices (see parse.mojo for the full list):
  - one value, surrounded only by JSON whitespace (space, tab, LF, CR);
    anything after it, a byte-order mark, or an empty document is refused;
  - numbers: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, so a
    leading zero, a leading `+`, a bare `.`, `NaN` and `Infinity` are
    refused; the source text is kept verbatim (`JsonValue.text`);
  - strings: an unescaped control character (< 0x20), an unknown escape,
    a lone or reversed UTF-16 surrogate in `\\u` escapes, and ill-formed
    UTF-8 are refused; a surrogate pair decodes to one 4-byte UTF-8 code
    point;
  - nesting deeper than the depth limit (default 128 arrays/objects,
    `JSON_DEFAULT_MAX_DEPTH`) is refused, and the limit itself may not
    exceed `JSON_MAX_DEPTH` (1000). The parser keeps open containers on an
    explicit stack rather than recursing, but destroying, copying and
    serializing a `JsonValue` recurse once per nesting level; the cap keeps
    a parsed tree shallow enough for those;
  - duplicate object keys are kept in order; `get` returns the first
    (`refuse_duplicate_keys` refuses them after the parse).

Every error raised by this package starts with `JsonError:`; a parse error
ends with the 1-based line and byte column where it was found.

Encapsulation: the public API exposes only owned values (`JsonValue`,
`String`, `List`) and typed scalars. No pointers.
"""

from .value import (
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
    JsonValue,
    parse_int64_text,
    parse_uint64_text,
)
from .parse import (
    JSON_DEFAULT_MAX_DEPTH,
    JSON_MAX_DEPTH,
    parse_json_value,
    parse_json_bytes,
)
from .duplicates import refuse_duplicate_keys
from .write import (
    write_json_string,
    write_json_null,
    write_json_bool,
    write_i64_dec,
    write_u64_dec,
    write_f64_dtoa,
)
