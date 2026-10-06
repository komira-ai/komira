# komira_protobuf

The Protocol Buffers wire format, with no dependencies and no schema: the
`pb_write_*` functions append fields (varint, zigzag `sint`, fixed-width,
length-delimited, packed repeated, embedded message) to a `List[UInt8]`, and
`PbFieldCursor` reads a message back field by field, so a hand-written decoder
is a loop over tags. Every read is bounds-checked: a truncated or malformed
buffer raises an error that starts `ProtobufError.MALFORMED`, it never reads
past the end. It is the codec under generated message types, and works on its
own for any message you can describe by hand.

## Examples

Encode a field. Field 1 holding 150 is the wire format's classic example:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_protobuf import pb_write_varint_field

var out = List[UInt8]()
pb_write_varint_field(out, 1, 150)
assert_equal(out, [0x08, 0x96, 0x01])
```

Write a message, then read it back with a cursor; a field the reader does not
know is skipped:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_protobuf import PbFieldCursor, pb_write_sint64_field, pb_write_string_field, pb_write_varint_field

var msg = List[UInt8]()
pb_write_string_field(msg, 1, "ada")
pb_write_sint64_field(msg, 2, -42)
pb_write_varint_field(msg, 9, 7)  # a field this reader does not know

var name = String()
var delta = Int64(0)
var cur = PbFieldCursor.over(Span(msg))
while cur.has_next():
    var tag = cur.next_tag()
    if tag.field_number == 1:
        name = cur.read_string()
    elif tag.field_number == 2:
        delta = cur.read_sint64()
    else:
        cur.skip()
assert_equal(name, "ada")
assert_equal(delta, -42)
```

An embedded message and a packed repeated field:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_protobuf import PbFieldCursor, pb_write_message_field, pb_write_packed_varints, pb_write_varint_field

var inner = List[UInt8]()
pb_write_varint_field(inner, 1, 5)
var outer = List[UInt8]()
pb_write_message_field(outer, 3, inner)
pb_write_packed_varints(outer, 4, [UInt64(1), 2, 300])

var cur = PbFieldCursor.over(Span(outer))
_ = cur.next_tag()
var sub = cur.read_message()
_ = sub.next_tag()
assert_equal(sub.read_varint(), 5)
_ = cur.next_tag()
assert_equal(cur.read_packed_varints(), [UInt64(1), 2, 300])
```

A truncated buffer is refused:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_protobuf import pb_read_varint

var truncated: List[UInt8] = [0x96]  # a continuation byte and nothing after it
var message = String()
try:
    _ = pb_read_varint(Span(truncated), 0)
except e:
    message = String(e)
assert_equal(message, "ProtobufError.MALFORMED: varint runs past buffer end")
```
