# =============================================================================
# test_resource_composite_numbers.mojo
# =============================================================================
#
# THE COMPOSITES OF `kci.resource.v1`, AS WIRE BYTES: the new bases of `Ref`
# (4 path, 5 local, 6 input), `Value.input` 5, the `composite` arm 80 of
# `Resource.body` and its `CompositeInstance`, and composite.proto's
# `CompositeDefinition`, `Input`, `InputType` and `OutputDecl`. The field
# template of test_resource_field_numbers.mojo, in a file of its own (that
# file is past the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Only `Resource` is decoded, nothing is read by
#    name: a grant whose principal is `Ref{5 local, 4 path}` and whose target
#    is `Ref{6 input}`, a service env value `Value{5 input}`, and a
#    `Resource` 80 holding a `CompositeInstance` with all four fields survive
#    decode then encode, and so does an empty `composite` arm (its tag must
#    be written). Every failure is collected, so the red run against the
#    earlier schema names all of them.
# 2. REF. 4 path, 5 local, 6 input: optional strings, by name, binary, JSON
#    (`path`, `local`, `input`); absent is None and a written empty one is
#    present (so a graph that writes none encodes as before, and expansion
#    can refuse an empty one). They are not a oneof: `resource` and `local`
#    written together are both kept (expansion refuses the pair; a oneof
#    would silently keep the last). 7 is not a field.
# 3. VALUE. 5 input is the fourth arm of the oneof `v` (position 4), JSON
#    `input`; a literal followed by an input keeps the input (one arm).
# 4. COMPOSITEINSTANCE. 1 definition, 2 version, 3 digest (optional: absent
#    is None, a written empty digest is Some("")), 4 input (a map of string
#    to `Value`); JSON `definition`, `version`, `digest`, `input`; 8 is not a
#    field (5 and 7 are test_resource_binding_numbers', and 6 stays held:
#    test_resource_held_numbers). As
#    `Resource.body` 80 it is the 21st arm, JSON name `composite`.
# 5. COMPOSITEDEFINITION. 1 name, 2 version, 3 input (repeated `Input`), 4
#    component (repeated `Resource`), 6 output (repeated `OutputDecl`), 7
#    export (repeated string), 10 doc; JSON names the same; 11 is not a field
#    (5 and 9 are test_resource_binding_numbers', and 8 stays held).
# 6. INPUT. 1 name, 2 type (an `InputType`), 3 required, 4 default (a
#    `Value`), 5 doc; JSON `default` (`required`, `type`); 6 is not a field.
# 7. INPUTTYPE. Every value by number AND by name: 0 INPUT_TYPE_UNSET, 1
#    INPUT_STRING, 2 INPUT_INT, 3 INPUT_BOOL, 5 INPUT_REF, 6 INPUT_IMAGE, 9
#    INPUT_VALUE_MAP; 4, 7 and 8 are no value (held).
# 8. OUTPUTDECL. 1 name, 2 from (a `Ref`; JSON `from`, the Mojo field
#    `from_`); 3 is not a field.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.composite import CompositeDefinition, Input, InputType, OutputDecl
from kci_resource_proto.refs import Output, Ref, Value
from kci_resource_proto.resource import CompositeInstance, Resource




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


def _local_path_ref() -> List[UInt8]:
    """Ref { 5 local = "web", 4 path = "identity" }."""
    var b = List[UInt8]()
    _str(b, 5, "web")
    _str(b, 4, "identity")
    return b^


def _input_ref() -> List[UInt8]:
    """Ref { 6 input = "zone" }."""
    var b = List[UInt8]()
    _str(b, 6, "zone")
    return b^


def _grant_resource() -> List[UInt8]:
    """Resource { 1 "g", 25 grant { 1 principal local+path, 2 target input,
    3 access READ } }."""
    var g = List[UInt8]()
    _msg(g, 1, _local_path_ref())
    _msg(g, 2, _input_ref())
    _uint(g, 3, 2)
    var b = List[UInt8]()
    _str(b, 1, "g")
    _msg(b, 25, g)
    return b^


def _env_input_resource() -> List[UInt8]:
    """Resource { 1 "api", 10 service { 2 port 80, 4 env { "HOST": Value { 5
    input = "domain" } } } }."""
    var v = List[UInt8]()
    _str(v, 5, "domain")
    var s = List[UInt8]()
    _uint(s, 2, 80)
    _msg(s, 4, _entry("HOST", v))
    var b = List[UInt8]()
    _str(b, 1, "api")
    _msg(b, 10, s)
    return b^


def _instance() -> List[UInt8]:
    """CompositeInstance { 1 "acme.shop", 2 "3", 3 "sha256:ab", 4 { "domain":
    Value { 1 literal "shop.example.com" } } }."""
    var b = List[UInt8]()
    _str(b, 1, "acme.shop")
    _str(b, 2, "3")
    _str(b, 3, "sha256:ab")
    _msg(b, 4, _entry("domain", _lit("shop.example.com")))
    return b^


def _instance_resource(body: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, "store")
    _msg(b, 80, body)
    return b^


def _input_decl() -> List[UInt8]:
    """Input { 1 "port", 2 type INPUT_STRING, 3 required true, 4 default {
    literal "8080" }, 5 doc "the port" } (required with a default is refused
    by expansion, not by the wire)."""
    var b = List[UInt8]()
    _str(b, 1, "port")
    _uint(b, 2, 1)
    _uint(b, 3, 1)
    _msg(b, 4, _lit("8080"))
    _str(b, 5, "the port")
    return b^


def _output_decl() -> List[UInt8]:
    """OutputDecl { 1 "url", 2 from Ref { 5 local "api", 2 standard URL } }."""
    var r = List[UInt8]()
    _str(r, 5, "api")
    _uint(r, 2, 1)
    var b = List[UInt8]()
    _str(b, 1, "url")
    _msg(b, 2, r)
    return b^


def _definition() -> List[UInt8]:
    """CompositeDefinition { 1 "acme.shop", 2 "3", 3 Input, 4 Resource { 1
    "api", 10 service { 2 port 80 } }, 6 OutputDecl, 7 "api", 10 "doc" }."""
    var svc = List[UInt8]()
    _uint(svc, 2, 80)
    var comp = List[UInt8]()
    _str(comp, 1, "api")
    _msg(comp, 10, svc)
    var b = List[UInt8]()
    _str(b, 1, "acme.shop")
    _str(b, 2, "3")
    _msg(b, 3, _input_decl())
    _msg(b, 4, comp)
    _msg(b, 6, _output_decl())
    _str(b, 7, "api")
    _str(b, 10, "a shop")
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_composite_numbers_are_kept() raises:
    """Catches: `Ref` 4, 5 or 6 undeclared, renumbered or of another wire
    type, `Value` 5 undeclared, `Resource` 80 undeclared or renumbered, any
    `CompositeInstance` field undeclared (each is dropped or misread on
    re-encode), and an empty `composite` arm dropped by the encoder.
    Collects every failure, so the red run against the earlier schema names
    all of them."""
    var bad = List[String]()
    var g = _grant_resource()
    if not _kept(encode_proto(decode_proto[Resource](g.copy())), g):
        bad.append("Ref 4 path / 5 local / 6 input (in a grant's principal and target)")
    var e = _env_input_resource()
    if not _kept(encode_proto(decode_proto[Resource](e.copy())), e):
        bad.append("Value 5 input (in a service's env)")
    var c = _instance_resource(_instance())
    if not _kept(encode_proto(decode_proto[Resource](c.copy())), c):
        bad.append("Resource 80 (CompositeInstance 1 definition, 2 version, 3 digest, 4 input)")
    # `_kept` drops an empty record as a zero value: the arm's tag (80,
    # length-delimited: 0x82 0x05) must be there.
    var empty = _instance_resource(List[UInt8]())
    var back = encode_proto(decode_proto[Resource](empty.copy()))
    if not _kept(back, empty) or _hex(back).find("8205") < 0:
        bad.append("Resource 80 (an empty composite record): got " + _hex(back))
    var names = String("")
    for i in range(len(bad)):
        names += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("not kept as the composites declare them:") + names)
    print("  test_added_composite_numbers_are_kept: PASS")


# ---- 2. Ref -----------------------------------------------------------------------


def test_ref_bases_and_path() raises:
    """Catches: `path`, `local` or `input` at another number or wire type, a
    JSON name other than the proto3 one, a field without presence (an
    unwritten one would be written as empty, and every stored graph's bytes
    would change; a written empty one would read as absent), the bases made
    a oneof (the pair below would keep one), and a field declared at 7."""
    var r = decode_proto[Ref](_local_path_ref())
    assert_equal(r.local.value(), "web", "field 5 is `local`")
    assert_equal(r.path.value(), "identity", "field 4 is `path`")
    assert_equal(r.resource, "", "absent: no resource")
    assert_false(Bool(r.input), "absent: no input")
    _same(encode_proto(r), _local_path_ref(), "Ref local + path")
    var i = decode_proto[Ref](_input_ref())
    assert_equal(i.input.value(), "zone", "field 6 is `input`")
    assert_false(Bool(i.local), "absent: no local")
    assert_false(Bool(i.path), "absent: no path")
    # Presence: none written is no bytes at all; a written empty one is kept.
    var plain = List[UInt8]()
    _str(plain, 1, "db")
    _bytes_equal(encode_proto(decode_proto[Ref](plain.copy())), plain, "a Ref with none of them writes none")
    var empty = List[UInt8]()
    _str(empty, 5, "")
    var e = decode_proto[Ref](empty.copy())
    assert_equal(e.local.value(), "", "a written empty local is present")
    var eh = _hex(encode_proto(e))
    assert_true(eh.find("2a00") >= 0, "and re-encodes as written (5, length 0): " + eh)
    var text = encode_json(r)
    assert_true('"local":"web"' in text and '"path":"identity"' in text, "Ref JSON: " + text)
    assert_true('"input":"zone"' in encode_json(i), "Ref JSON names the input")
    _bytes_equal(encode_proto(decode_json[Ref](text)), encode_proto(r), "Ref: JSON round trip")

    var both = List[UInt8]()
    _str(both, 1, "store")
    _str(both, 5, "web")
    var b = decode_proto[Ref](both.copy())
    assert_equal(b.resource, "store", "not a oneof: resource is kept")
    assert_equal(b.local.value(), "web", "not a oneof: local is kept beside it")
    _same(encode_proto(b), both, "Ref with two bases")

    var probe = _input_ref()
    _str(probe, 7, "not-a-field")
    _same(encode_proto(decode_proto[Ref](probe.copy())), _input_ref(), "Ref has no field 7")
    print("  test_ref_bases_and_path: PASS")


# ---- 3. Value ---------------------------------------------------------------------


def test_value_input() raises:
    """Catches: `input` at another number, outside the oneof `v` (a literal
    and an input would both be kept), at another position in it, or under
    another JSON name."""
    var v = List[UInt8]()
    _str(v, 5, "domain")
    var d = decode_proto[Value](v.copy())
    assert_equal(d._oneof0_case, 4, "input is the fourth arm")
    assert_equal(d.input.value(), "domain")
    _same(encode_proto(d), v, "Value input")
    var text = encode_json(d)
    assert_equal(text, '{"input":"domain"}', "Value JSON")
    _bytes_equal(encode_proto(decode_json[Value](text)), encode_proto(d), "Value: JSON round trip")
    var two = _lit("x")
    _str(two, 5, "domain")
    var last = decode_proto[Value](two.copy())
    assert_equal(last._oneof0_case, 4, "one arm: the last on the wire")
    _same(encode_proto(last), v, "Value keeps only the input")
    print("  test_value_input: PASS")


# ---- 4. CompositeInstance -----------------------------------------------------------


def test_composite_instance() raises:
    """Catches: a field at another number or wire type, `digest` without
    presence (a written empty digest read as absent), the map's key or value
    swapped, a JSON name other than the proto3 one, a field declared at 8,
    and the arm at another number or position."""
    var c = decode_proto[CompositeInstance](_instance())
    assert_equal(c.definition, "acme.shop", "1 is `definition`")
    assert_equal(c.version, "3", "2 is `version`")
    assert_equal(c.digest.value(), "sha256:ab", "3 is `digest`")
    assert_equal(len(c.input), 1)
    assert_equal(c.input["domain"].literal.value(), "shop.example.com", "4 is `input`, string to Value")
    _same(encode_proto(c), _instance(), "CompositeInstance")
    var text = encode_json(c)
    assert_true(
        '"definition":"acme.shop"' in text
        and '"version":"3"' in text
        and '"digest":"sha256:ab"' in text
        and '"input":{"domain":{"literal":"shop.example.com"}}' in text,
        "CompositeInstance JSON: " + text,
    )
    _bytes_equal(encode_proto(decode_json[CompositeInstance](text)), encode_proto(c), "JSON round trip")
    assert_false(Bool(decode_proto[CompositeInstance](List[UInt8]()).digest), "absent: no digest")
    var e = List[UInt8]()
    _str(e, 3, "")
    assert_equal(decode_proto[CompositeInstance](e^).digest.value(), "", "written empty: present")
    var probe = _instance()
    _str(probe, 8, "not-a-field")
    _same(encode_proto(decode_proto[CompositeInstance](probe.copy())), _instance(), "no field 8")

    var r = decode_proto[Resource](_instance_resource(_instance()))
    assert_equal(r._oneof0_case, 21, "the composite is the 21st arm")
    assert_equal(r.id, "store")
    assert_equal(r.composite.value().definition, "acme.shop")
    var rt = encode_json(r)
    assert_true('"composite":{"definition":"acme.shop"' in rt, "Resource JSON names the arm composite: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(r), "Resource: JSON round trip")
    print("  test_composite_instance: PASS")


# ---- 5. CompositeDefinition -----------------------------------------------------------


def test_composite_definition() raises:
    """Catches: any field at another number or wire type, a repeated field
    read as a single one, a JSON name other than the proto3 one, and a field
    declared at 11 (8 is probed by test_resource_held_numbers)."""
    var d = decode_proto[CompositeDefinition](_definition())
    assert_equal(d.name, "acme.shop", "1 is `name`")
    assert_equal(d.version, "3", "2 is `version`")
    assert_equal(len(d.input), 1, "3 is `input`")
    assert_equal(d.input[0].name, "port")
    assert_equal(len(d.component), 1, "4 is `component`")
    assert_equal(d.component[0].id, "api")
    assert_equal(Int(d.component[0].service.value().port), 80, "a component is a Resource")
    assert_equal(len(d.output), 1, "6 is `output`")
    assert_equal(d.output[0].name, "url")
    assert_equal(len(d.export), 1, "7 is `export`")
    assert_equal(d.export[0], "api")
    assert_equal(d.doc, "a shop", "10 is `doc`")
    _same(encode_proto(d), _definition(), "CompositeDefinition")
    var text = encode_json(d)
    assert_true(
        '"name":"acme.shop"' in text
        and '"input":[{' in text
        and '"component":[{"id":"api"' in text
        and '"output":[{"name":"url"' in text
        and '"export":["api"]' in text
        and '"doc":"a shop"' in text,
        "CompositeDefinition JSON: " + text,
    )
    _bytes_equal(encode_proto(decode_json[CompositeDefinition](text)), encode_proto(d), "JSON round trip")
    var two = _definition()
    _str(two, 7, "web")
    assert_equal(len(decode_proto[CompositeDefinition](two^).export), 2, "export is repeated")
    var probe = _definition()
    _str(probe, 11, "not-a-field")
    _same(encode_proto(decode_proto[CompositeDefinition](probe.copy())), _definition(), "no field 11")
    print("  test_composite_definition: PASS")


# ---- 6. Input -----------------------------------------------------------------------


def test_input() raises:
    """Catches: a field at another number or wire type, `default` not a
    `Value`, a JSON name other than the proto3 one, and a field declared at
    6."""
    var i = decode_proto[Input](_input_decl())
    assert_equal(i.name, "port", "1 is `name`")
    assert_equal(i.type.value, InputType.INPUT_STRING, "2 is `type`")
    assert_true(i.required, "3 is `required`")
    assert_equal(i.default.value().literal.value(), "8080", "4 is `default`, a Value")
    assert_equal(i.doc, "the port", "5 is `doc`")
    _same(encode_proto(i), _input_decl(), "Input")
    var text = encode_json(i)
    assert_true(
        '"type":"INPUT_STRING"' in text and '"required":true' in text and '"default":{"literal":"8080"}' in text,
        "Input JSON: " + text,
    )
    _bytes_equal(encode_proto(decode_json[Input](text)), encode_proto(i), "Input: JSON round trip")
    var probe = _input_decl()
    _str(probe, 6, "not-a-field")
    _same(encode_proto(decode_proto[Input](probe.copy())), _input_decl(), "Input has no field 6")
    print("  test_input: PASS")


# ---- 7. InputType -------------------------------------------------------------------


def test_input_type_ordinals() raises:
    """Catches: a type renumbered or renamed (the number is what is stored),
    and a held type declared without its pin."""
    var nums: List[Int] = [0, 1, 2, 3, 5, 6, 9]
    var names: List[String] = [
        "INPUT_TYPE_UNSET",
        "INPUT_STRING",
        "INPUT_INT",
        "INPUT_BOOL",
        "INPUT_REF",
        "INPUT_IMAGE",
        "INPUT_VALUE_MAP",
    ]
    for k in range(len(nums)):
        assert_equal(InputType(nums[k]).json_name(), names[k], String("InputType ") + String(nums[k]))
        assert_equal(InputType.from_json_name(names[k]).value, nums[k], names[k])
    for n in [4, 7, 8]:
        assert_equal(InputType(n).json_name(), String(n), String("InputType ") + String(n) + " is held")
    print("  test_input_type_ordinals: PASS")


# ---- 8. OutputDecl ------------------------------------------------------------------


def test_output_decl() raises:
    """Catches: `name` or `from` at another number or wire type, `from` not a
    `Ref`, the JSON name `from` spelled otherwise, and a field declared at
    3."""
    var o = decode_proto[OutputDecl](_output_decl())
    assert_equal(o.name, "url", "1 is `name`")
    assert_equal(o.from_.value().local.value(), "api", "2 is `from`, a Ref")
    assert_equal(o.from_.value().standard.value().value, Output.URL)
    _same(encode_proto(o), _output_decl(), "OutputDecl")
    var text = encode_json(o)
    assert_true('"from":{' in text and '"standard":"URL"' in text, "OutputDecl JSON: " + text)
    _bytes_equal(encode_proto(decode_json[OutputDecl](text)), encode_proto(o), "OutputDecl: JSON round trip")
    var probe = _output_decl()
    _str(probe, 3, "not-a-field")
    _same(encode_proto(decode_proto[OutputDecl](probe.copy())), _output_decl(), "OutputDecl has no field 3")
    print("  test_output_decl: PASS")


def main() raises:
    print("test_resource_composite_numbers: Ref bases, Value.input, CompositeInstance, composite.proto")
    test_added_composite_numbers_are_kept()
    test_ref_bases_and_path()
    test_value_input()
    test_composite_instance()
    test_composite_definition()
    test_input()
    test_input_type_ordinals()
    test_output_decl()
    print("ALL kci.resource.v1 COMPOSITE FIELD-NUMBER TESTS PASSED")
