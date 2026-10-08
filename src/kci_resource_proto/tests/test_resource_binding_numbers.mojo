# =============================================================================
# test_resource_binding_numbers.mojo
# =============================================================================
#
# THE BINDINGS OF A COMPOSITE, AS WIRE BYTES: `CompositeDefinition` 5 bind
# and 9 presence, `Binding`, `Presence`, `CompositeInstance` 5 image_input
# and 7 map_input, `ValueMap`, and the `InputType` values 2 INPUT_INT, 3
# INPUT_BOOL, 6 INPUT_IMAGE and 9 INPUT_VALUE_MAP. The template of
# test_resource_composite_numbers.mojo, in a file of its own.
#
# 1. KEPT, BY BYTES ONLY. Only `CompositeDefinition` and `Resource` are
#    decoded, nothing is read by name: a definition with a `Binding` (5) and
#    a `Presence` (9), and an instance with an `image_input` (5) entry and a
#    `map_input` (7) entry, survive decode then encode. Every failure is
#    collected, so the red run against the earlier schema names each.
# 2. BINDING. 1 component, 2 field, 3 input; JSON names the same; 4 is not a
#    field.
# 3. PRESENCE. 1 component, 2 if_input (JSON `ifInput`); 3 is not a field.
# 4. THE INSTANCE'S TYPED INPUTS. 5 image_input (string to `Image`), 7
#    map_input (string to `ValueMap`, whose 1 `value` is string to
#    `Value`); JSON `imageInput`, `mapInput`; 6 stays held.
# 5. THE DEFINITION. 5 bind and 9 presence are repeated, JSON `bind` and
#    `presence`; 8 stays held.
# 6. INPUTTYPE. 2 INPUT_INT, 3 INPUT_BOOL, 6 INPUT_IMAGE, 9 INPUT_VALUE_MAP
#    by number and by name, as `Input.type` on the wire.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.composite import Binding, CompositeDefinition, Input, InputType, Presence
from kci_resource_proto.resource import CompositeInstance, Resource, ValueMap


# ---- a hand-written wire stream (as in test_resource_field_numbers) -------------

comptime _VARINT = 0
comptime _LEN = 2


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    _varint(b, UInt64((field << 3) | _VARINT))
    _varint(b, v)


def _str(mut b: List[UInt8], field: Int, s: String):
    _varint(b, UInt64((field << 3) | _LEN))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    _varint(b, UInt64((field << 3) | _LEN))
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4 : (v >> 4) + 1])
        out += String(digits[byte = v & 15 : (v & 15) + 1])
    return out^


def _read_varint(b: List[UInt8], mut pos: Int, mut ok: Bool) -> UInt64:
    var v: UInt64 = 0
    var shift = 0
    while pos < len(b) and shift < 64:
        var c = b[pos]
        pos += 1
        v |= UInt64(c & 0x7F) << UInt64(shift)
        if c < 0x80:
            return v
        shift += 7
    ok = False
    return 0


def _canon(b: List[UInt8], mut out: List[UInt8]) -> Bool:
    """`b` with every zero-valued record dropped, recursively, and its records
    sorted stably by field number (this codec writes zero values and writes
    plain fields before oneof fields; neither is the catalog's business).
    False when `b` does not parse as a message (varint and length-delimited
    records only: no field here is fixed-width)."""
    var fields = List[Int]()
    var records = List[List[UInt8]]()
    var pos = 0
    var ok = True
    while pos < len(b):
        var tag = _read_varint(b, pos, ok)
        if not ok or (tag >> 3) == 0:
            return False
        var rec = List[UInt8]()
        if Int(tag & 7) == _VARINT:
            var v = _read_varint(b, pos, ok)
            if not ok:
                return False
            if v == 0:
                continue
            _varint(rec, tag)
            _varint(rec, v)
        elif Int(tag & 7) == _LEN:
            var n = Int(_read_varint(b, pos, ok))
            if not ok or pos + n > len(b):
                return False
            var content = List[UInt8]()
            for k in range(n):
                content.append(b[pos + k])
            pos += n
            var inner = List[UInt8]()
            if not _canon(content, inner):
                inner = content^
            if len(inner) == 0:
                continue
            _varint(rec, tag)
            _varint(rec, UInt64(len(inner)))
            for k in range(len(inner)):
                rec.append(inner[k])
        else:
            return False
        var j = len(fields)
        fields.append(Int(tag >> 3))
        records.append(rec^)
        while j > 0 and fields[j - 1] > fields[j]:
            var f = fields[j]
            fields[j] = fields[j - 1]
            fields[j - 1] = f
            var r = records[j].copy()
            records[j] = records[j - 1].copy()
            records[j - 1] = r^
            j -= 1
    for k in range(len(records)):
        for x in range(len(records[k])):
            out.append(records[k][x])
    return True


def _kept(got: List[UInt8], want: List[UInt8]) -> Bool:
    var cg = List[UInt8]()
    var cw = List[UInt8]()
    if not _canon(got, cg) or not _canon(want, cw):
        return False
    return _hex(cg) == _hex(cw)


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_true(
        _kept(got, want),
        what + ": re-encoding the decoded message does not give the hand-written records back\n  want "
        + _hex(want) + "\n  got  " + _hex(got),
    )


def _bytes_equal(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(_hex(a), _hex(b), what)


def _entry(key: String, value: List[UInt8]) -> List[UInt8]:
    """One map entry: 1 the key, 2 the value message."""
    var b = List[UInt8]()
    _str(b, 1, key)
    _msg(b, 2, value)
    return b^


def _lit(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, s)
    return b^


# ---- the messages, as bytes ------------------------------------------------------------


def _binding() -> List[UInt8]:
    """Binding { 1 "api", 2 "service.port", 3 "port" }."""
    var b = List[UInt8]()
    _str(b, 1, "api")
    _str(b, 2, "service.port")
    _str(b, 3, "port")
    return b^


def _presence() -> List[UInt8]:
    """Presence { 1 "host", 2 "domain" }."""
    var b = List[UInt8]()
    _str(b, 1, "host")
    _str(b, 2, "domain")
    return b^


def _definition() -> List[UInt8]:
    """CompositeDefinition { 1 "acme.app", 2 "1", 5 Binding, 9 Presence }."""
    var b = List[UInt8]()
    _str(b, 1, "acme.app")
    _str(b, 2, "1")
    _msg(b, 5, _binding())
    _msg(b, 9, _presence())
    return b^


def _image() -> List[UInt8]:
    """Image { 2 digest "sha256:ab" }."""
    var b = List[UInt8]()
    _str(b, 2, "sha256:ab")
    return b^


def _value_map() -> List[UInt8]:
    """ValueMap { 1 { "LEVEL": Value { 1 literal "debug" } } }."""
    var b = List[UInt8]()
    _msg(b, 1, _entry("LEVEL", _lit("debug")))
    return b^


def _instance() -> List[UInt8]:
    """CompositeInstance { 1 "acme.app", 2 "1", 5 { "image": Image }, 7 {
    "env": ValueMap } }."""
    var b = List[UInt8]()
    _str(b, 1, "acme.app")
    _str(b, 2, "1")
    _msg(b, 5, _entry("image", _image()))
    _msg(b, 7, _entry("env", _value_map()))
    return b^


def _instance_resource() -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, "web")
    _msg(b, 80, _instance())
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_binding_numbers_are_kept() raises:
    """Catches: `CompositeDefinition` 5 or 9, any field of `Binding` or
    `Presence`, `CompositeInstance` 5 or 7, or `ValueMap` 1 undeclared,
    renumbered or of another wire type (each is dropped or misread on
    re-encode). Collects every failure, so the red run against the earlier
    schema names all of them."""
    var bad = List[String]()
    var d = _definition()
    if not _kept(encode_proto(decode_proto[CompositeDefinition](d.copy())), d):
        bad.append("CompositeDefinition 5 bind (Binding 1, 2, 3) / 9 presence (Presence 1, 2)")
    var r = _instance_resource()
    if not _kept(encode_proto(decode_proto[Resource](r.copy())), r):
        bad.append("CompositeInstance 5 image_input / 7 map_input (ValueMap 1)")
    var names = String("")
    for i in range(len(bad)):
        names += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("not kept as the bindings declare them:") + names)
    print("  test_added_binding_numbers_are_kept: PASS")


# ---- 2. Binding -------------------------------------------------------------------


def test_binding() raises:
    """Catches: a field at another number or wire type, a JSON name other
    than the proto3 one, and a field declared at 4."""
    var b = decode_proto[Binding](_binding())
    assert_equal(b.component, "api", "1 is `component`")
    assert_equal(b.field, "service.port", "2 is `field`")
    assert_equal(b.input, "port", "3 is `input`")
    _same(encode_proto(b), _binding(), "Binding")
    var text = encode_json(b)
    assert_equal(text, '{"component":"api","field":"service.port","input":"port"}', "Binding JSON")
    _bytes_equal(encode_proto(decode_json[Binding](text)), encode_proto(b), "Binding: JSON round trip")
    var probe = _binding()
    _str(probe, 4, "not-a-field")
    _same(encode_proto(decode_proto[Binding](probe.copy())), _binding(), "Binding has no field 4")
    print("  test_binding: PASS")


# ---- 3. Presence ------------------------------------------------------------------


def test_presence() raises:
    """Catches: a field at another number or wire type, the JSON name
    `ifInput` spelled otherwise, and a field declared at 3."""
    var p = decode_proto[Presence](_presence())
    assert_equal(p.component, "host", "1 is `component`")
    assert_equal(p.if_input, "domain", "2 is `if_input`")
    _same(encode_proto(p), _presence(), "Presence")
    var text = encode_json(p)
    assert_equal(text, '{"component":"host","ifInput":"domain"}', "Presence JSON")
    _bytes_equal(encode_proto(decode_json[Presence](text)), encode_proto(p), "Presence: JSON round trip")
    _bytes_equal(
        encode_proto(decode_json[Presence]('{"component":"host","if_input":"domain"}')),
        encode_proto(p),
        "the .proto name reads too",
    )
    var probe = _presence()
    _str(probe, 3, "not-a-field")
    _same(encode_proto(decode_proto[Presence](probe.copy())), _presence(), "Presence has no field 3")
    print("  test_presence: PASS")


# ---- 4. the instance's typed inputs ----------------------------------------------------


def test_instance_typed_inputs() raises:
    """Catches: `image_input` or `map_input` at another number, a map's key
    or value swapped, `ValueMap.value` at another number, a JSON name other
    than the proto3 one, and 6 declared (it stays held)."""
    var c = decode_proto[CompositeInstance](_instance())
    assert_equal(len(c.image_input), 1, "5 is `image_input`")
    assert_equal(c.image_input["image"].digest.value(), "sha256:ab", "string to Image")
    assert_equal(len(c.map_input), 1, "7 is `map_input`")
    assert_equal(c.map_input["env"].value["LEVEL"].literal.value(), "debug", "string to ValueMap, string to Value")
    _same(encode_proto(c), _instance(), "CompositeInstance typed inputs")
    var text = encode_json(c)
    assert_true(
        '"imageInput":{"image":{"digest":"sha256:ab"' in text
        and '"mapInput":{"env":{"value":{"LEVEL":{"literal":"debug"}}}}' in text,
        "CompositeInstance JSON: " + text,
    )
    _bytes_equal(encode_proto(decode_json[CompositeInstance](text)), encode_proto(c), "JSON round trip")
    var vm = decode_proto[ValueMap](_value_map())
    _same(encode_proto(vm), _value_map(), "ValueMap")
    var probe = _value_map()
    _str(probe, 2, "not-a-field")
    _same(encode_proto(decode_proto[ValueMap](probe.copy())), _value_map(), "ValueMap has no field 2")
    print("  test_instance_typed_inputs: PASS")


# ---- 5. the definition ---------------------------------------------------------------


def test_definition_bind_and_presence() raises:
    """Catches: `bind` or `presence` read as a single field, at another
    number, or under another JSON name."""
    var two = _definition()
    _msg(two, 5, _binding())
    _msg(two, 9, _presence())
    var d = decode_proto[CompositeDefinition](two^)
    assert_equal(len(d.bind), 2, "5 is the repeated `bind`")
    assert_equal(len(d.presence), 2, "9 is the repeated `presence`")
    var text = encode_json(decode_proto[CompositeDefinition](_definition()))
    assert_true('"bind":[{"component":"api"' in text and '"presence":[{"component":"host"' in text, "JSON: " + text)
    print("  test_definition_bind_and_presence: PASS")


# ---- 6. InputType ------------------------------------------------------------------


def test_input_types() raises:
    """Catches: a type renumbered or renamed (the number is what is stored),
    read from `Input.type` on the wire."""
    var nums: List[Int] = [2, 3, 6, 9]
    var names: List[String] = ["INPUT_INT", "INPUT_BOOL", "INPUT_IMAGE", "INPUT_VALUE_MAP"]
    for k in range(len(nums)):
        var b = List[UInt8]()
        _str(b, 1, "x")
        _uint(b, 2, UInt64(nums[k]))
        var i = decode_proto[Input](b.copy())
        assert_equal(i.type.json_name(), names[k], String("InputType ") + String(nums[k]))
        assert_equal(InputType.from_json_name(names[k]).value, nums[k], names[k])
        _same(encode_proto(i), b, names[k])
    print("  test_input_types: PASS")


def main() raises:
    print("test_resource_binding_numbers: Binding, Presence, the instance's typed inputs, InputType")
    test_added_binding_numbers_are_kept()
    test_binding()
    test_presence()
    test_instance_typed_inputs()
    test_definition_bind_and_presence()
    test_input_types()
    print("ALL kci.resource.v1 BINDING-NUMBER TESTS PASSED")
