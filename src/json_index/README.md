# json_index

The JSON structural index and the `json_extract` kernel, split out of `jsonl`.

- `simd_primitives`: the Stage 1 SIMD helpers (16-byte movemask, prefix-XOR, the character-class table, the escape state machine).
- `structural_index`: the structural-token indexer built on them.
- `input_limits`: the input size and column-count limits, checked before an index is built.
- `parse_string`: the JSON string unescaper.
- `json_extract_kernel`: `json_extract` over a string column of an Arrow batch.

## Dependency direction

`json_index` depends on `arrow`, `byte_buffer`, `plan_expr` and `simd_ops` only. `jsonl` depends on it, so a package that needs `json_extract` or the structural index and nothing else (the expression evaluators, for one) no longer pulls in the JSONL readers and writers, `async_rt` and `row_format`.

## Examples

This program builds the structural index of a small JSON document and reads the key back out of it with `parse_string`. The index lists the byte offset and tag of each structural character; the scalar `1` is not one.

```mojo module
from std.testing import assert_equal
from json_index.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)
from json_index.structural_index import build_structural_index
from json_index.parse_string import parse_string


def main() raises:
    var text = String('{"a":1}')
    var data = text.as_bytes()
    var idx = build_structural_index(data)
    assert_equal(idx.size(), 5)
    assert_equal(Int(idx.offsets[1]), 1)
    assert_equal(Int(idx.tags[0]), Int(TAG_OPEN_BRACE))
    assert_equal(Int(idx.tags[1]), Int(TAG_QUOTE_OPEN))
    assert_equal(Int(idx.tags[2]), Int(TAG_QUOTE_CLOSE))
    var key = parse_string(data, Int(idx.offsets[1]) + 1, Int(idx.offsets[2]))
    assert_equal(key, "a")
```

This program decodes a JSON string that has an escape, and checks a byte range for well-formed UTF-8.

```mojo module
from std.testing import assert_equal
from json_index.parse_string import parse_string
from json_index.utf8_check import check_utf8


def main() raises:
    var raw = String("a\\nb")
    var b = raw.as_bytes()
    var decoded = parse_string(b, 0, len(b), True)
    assert_equal(decoded, "a\nb")
    check_utf8(b, 0, len(b), "readme")
```
