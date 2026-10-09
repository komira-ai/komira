# komira_json

A small JSON library (RFC 8259) with no dependencies. `parse_json_value` reads
JSON text into a `JsonValue`, a tagged value over the six JSON kinds with typed
accessors; the builders (`empty_object`, `set_member`, `push`, `from_*`) make
one, and `serialize` writes it back as compact JSON. The parser is strict: it
accepts exactly the RFC 8259 grammar, refuses anything else with an error that
starts `JsonError:` and names the line and byte column, and limits nesting
depth (128 by default). A number keeps its source text, so a 64-bit integer
reads back exactly.

## Examples

Read a document and its fields:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_json import parse_json_value

var doc = parse_json_value('{"name": "ada", "tags": ["x", "y"], "id": 9007199254740993}')
assert_equal(doc.get("name").as_string(), "ada")
assert_equal(doc.get("tags").array_len(), 2)
assert_equal(doc.get("tags").element_at(1).as_string(), "y")
assert_equal(doc.get("id").as_int64(), Int64(9007199254740993))
assert_true(not doc.has("email"))
```

Build a value and write it as JSON:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_json import JsonValue

var point = JsonValue.empty_object()
point.set_member("x", JsonValue.from_i64(3))
point.set_member("y", JsonValue.from_f64(0.25))
var tags = JsonValue.empty_array()
tags.push(JsonValue.from_string('say "hi"'))
tags.push(JsonValue.null())
point.set_member("tags", tags^)
assert_equal(point.serialize(), '{"x":3,"y":0.25,"tags":["say \\"hi\\"",null]}')
```

Malformed input is refused, naming where:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_json import parse_json_value

var message = String()
try:
    _ = parse_json_value("[1, 2,]")
except e:
    message = String(e)
assert_equal(message, "JsonError: unexpected character at the start of a value at line 1, byte column 7")
```

Walk an object's members in order:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_json import parse_json_value

var obj = parse_json_value('{"b": 1, "a": 2}')
var keys = String()
for i in range(obj.num_members()):
    keys += obj.key_at(i)
assert_equal(keys, "ba")
```

Refuse a document that names a member twice (the parser keeps both; formats
such as JWS, JWT and JWK require a reader to refuse them). Names are compared
after unescaping, at every depth:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_json import parse_json_value, refuse_duplicate_keys

refuse_duplicate_keys(parse_json_value('{"a": {"x": 1}, "b": {"x": 2}}'))
var message = String()
try:
    refuse_duplicate_keys(parse_json_value('{"a": 1,\n "\\u0061": 2}'))
except e:
    message = String(e)
assert_equal(message, "JsonError: duplicate object key 'a' at line 2")
```
