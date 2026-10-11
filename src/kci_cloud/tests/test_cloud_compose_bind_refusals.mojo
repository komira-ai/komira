# =============================================================================
# test_cloud_compose_bind_refusals.mojo
# =============================================================================
#
# THE RULES OF BINDINGS, PRESENCES, THE TYPED INPUTS AND THE KCI NAMESPACE,
# when a definition or an instance is LOADED (compose_load.mojo,
# compose_bind.mojo, compose_kci.mojo). Pure: no cloud. Each case is one
# small definition (or list) with one defect, and requires EXACTLY one
# finding, on the named definition or resource, at the named field, with
# the named reason: a missing check, a check on the wrong thing, and noise
# from a second check all go red.
#
# 1. TYPED INPUTS: a default on an IMAGE or a VALUE_MAP input, an INT
#    default that is not an integer (a leading zero, a bare `-`, 19
#    digits), a BOOL default that is not true or false; an INT default of
#    exactly 18 digits, negative, is accepted.
# 2. A BINDING: of no component, of an undeclared input, of a REF input;
#    two of one field; a field outside the component's type; a field the
#    input's type cannot be written to (a STRING into a port, an INT into a
#    flag-free message); a field inside a reference (a STRING into
#    `run_as.resource`, which would name a resource outside the closed
#    definition); a field with an empty segment (`service..port`,
#    `service.`); a field below a scalar the component writes (a STRING
#    into `service.port.x`); a VALUE_MAP into a string the component
#    writes; on a nested instance: a plain input (it passes down as
#    `composite.input`), an IMAGE not under `composite.image_input.`, an
#    input the nested definition does not declare or declares of another
#    type, and one the instance binds too.
# 3. A PRESENCE: of no component, of an undeclared input, of a required
#    input or one with a default (always set), and two of one component.
# 4. A COMPONENT'S VALUE OR REFERENCE: `Value.input` naming an IMAGE input,
#    `Ref.input` naming an INT input.
# 5. AN INSTANCE: an INT that is not an integer, a BOOL that is not true or
#    false, an INT bound to a parameter, an IMAGE input bound in `input`, an
#    `image_input` key that is not an IMAGE input, an image with no source,
#    a `map_input` key that is not a VALUE_MAP input, a map value with
#    nothing in it, a required IMAGE input unbound, and (nested) an INT
#    input passed a STRING input of the enclosing definition, an INT input
#    or a map value passed an IMAGE input of the enclosing definition, and
#    a map value that is a reference naming no output.
# 6. THE KCI NAMESPACE: a definition named `kci.job` whose digest is not
#    the one kci ships is refused (the shipped list is named), and so is
#    `kci.other`, which kci does not ship; `acme.job`, the same bytes in the
#    author's namespace, is accepted.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Catalog, Finding, expand


def _defs(texts: List[String]) raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    for i in range(len(texts)):
        out.append(decode_json[CompositeDefinition](texts[i]))
    return out^


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _all(fs: List[Finding]) -> String:
    var s = String("")
    for i in range(len(fs)):
        s += String("\n  ") + fs[i].resource_id + String(" | ") + fs[i].field_path + String(" | ") + fs[i].reason
    return s^


def _one(defs: List[String], list: String, rid: String, field: String, needle: String) raises:
    """Exactly one finding: on `rid`, at `field`, its reason holding `needle`."""
    var x = expand(Catalog.v1(), _defs(defs), _list(list))
    var got = _all(x.findings)
    assert_equal(len(x.findings), 1, String("one finding (") + needle + String("), got:") + got)
    assert_equal(x.findings[0].resource_id, rid, got)
    assert_equal(x.findings[0].field_path, field, got)
    assert_true(x.findings[0].reason.find(needle) >= 0, String("reason holds ") + needle + String(":") + got)
    assert_equal(len(x.resources), 0, "nothing is expanded once a definition is refused")


def _x(body: String) -> String:
    return String('{"name":"acme.x","version":"1",') + body + String("}")


comptime _EMPTY = '{"resource":[]}'
comptime _B = '{"id":"b","bucket":{}}'
comptime _SVC = '{"id":"api","service":{"image":{"digest":"sha256:a1"}}}'


# ---- 1. typed inputs ------------------------------------------------------------------------


def test_typed_input_defaults() raises:
    """Catches: a default accepted on an IMAGE or VALUE_MAP input (it has no
    literal form), an INT default that is not an integer, a BOOL default
    that is not true or false (N11); a bare `-` taken as an integer (N26:
    the digit count not checked once the sign is skipped); a 19-digit INT
    taken (N27: the 18-digit bound dropped); and an 18-digit negative INT
    refused (an off-by-one in the bound or the sign)."""
    var comp = String('"component":[') + _B + "],"
    var cases: List[String] = [
        comp + '"input":[{"name":"n","type":"INPUT_IMAGE","default":{"literal":"x"}}]',
        comp + '"input":[{"name":"n","type":"INPUT_VALUE_MAP","default":{"literal":"x"}}]',
        comp + '"input":[{"name":"n","type":"INPUT_INT","default":{"literal":"08"}}]',
        comp + '"input":[{"name":"n","type":"INPUT_BOOL","default":{"literal":"yes"}}]',
        comp + '"input":[{"name":"n","type":"INPUT_INT","default":{"literal":"-"}}]',
        comp + '"input":[{"name":"n","type":"INPUT_INT","default":{"literal":"1234567890123456789"}}]',
    ]
    var needles: List[String] = [
        "an IMAGE input has no default",
        "a VALUE_MAP input has no default",
        "an INT input is a decimal integer",
        "a BOOL input is true or false",
        "an INT input is a decimal integer",
        "an INT input is a decimal integer of at most 18 digits",
    ]
    for i in range(len(cases)):
        var d: List[String] = [_x(cases[i])]
        _one(d, String(_EMPTY), "acme.x@1", "input[n].default", needles[i])
    # The bound itself is accepted: a mutant that counts the sign as a
    # digit, or bounds at 17, refuses this one.
    var edge: List[String] = [_x(comp + '"input":[{"name":"n","type":"INPUT_INT","default":{"literal":"-123456789012345678"}}]')]
    var x = expand(Catalog.v1(), _defs(edge), _list(String(_EMPTY)))
    assert_equal(len(x.findings), 0, _all(x.findings))
    print("  test_typed_input_defaults: PASS")


# ---- 2. a binding -------------------------------------------------------------------------------


def _bound(inputs: String, binds: String, comps: String = String(_SVC)) -> String:
    return _x(String('"input":[') + inputs + String('],"component":[') + comps + String('],"bind":[') + binds + String("]"))


def test_a_binding() raises:
    """Catches: each binding rule missing (N12: no field check, so a typo
    would bind nothing; N13: the reference check, so a STRING could name a
    resource outside the definition; N28: the empty-segment check, so
    `service..port` would write a member named "" and `service.` the
    message itself). The last two cases pin the reason the writer gives
    for a field below a scalar and for a map merged into a string."""
    var s = String('{"name":"s","type":"INPUT_STRING"}')
    var i = String('{"name":"i","type":"INPUT_INT"}')
    var r = String('{"name":"r","type":"INPUT_REF"}')
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    cases.append(_bound(s, '{"component":"nope","field":"service.health_path","input":"s"}'))
    fields.append("bind[0].component")
    needles.append("has no component \"nope\"")
    cases.append(_bound(s, '{"component":"api","field":"service.health_path","input":"nope"}'))
    fields.append("bind[0].input")
    needles.append("declares no input \"nope\"")
    cases.append(_bound(r, '{"component":"api","field":"service.health_path","input":"r"}'))
    fields.append("bind[0].input")
    needles.append("a REF input is not bound")
    cases.append(_bound(s, '{"component":"api","field":"service.health_path","input":"s"},{"component":"api","field":"service.health_path","input":"s"}'))
    fields.append("bind[1]")
    needles.append("a second binding of api.service.health_path")
    cases.append(_bound(s, '{"component":"api","field":"container_job.args","input":"s"}'))
    fields.append("bind[0].field")
    needles.append("a binding writes a field of its component, which is a service")
    cases.append(_bound(s, '{"component":"api","field":"service.port","input":"s"}'))
    fields.append("bind[0].field")
    needles.append("a STRING input cannot be written to service.port")
    cases.append(_bound(i, '{"component":"api","field":"service.size","input":"i"}'))
    fields.append("bind[0].field")
    needles.append("an INT input cannot be written to service.size")
    cases.append(_bound(s, '{"component":"api","field":"service.run_as.resource","input":"s"}'))
    fields.append("bind[0].field")
    needles.append("a binding writes a plain field, never a reference")
    cases.append(_bound(s, '{"component":"api","field":"service.nope","input":"s"}'))
    fields.append("bind[0].field")
    needles.append("a STRING input cannot be written to service.nope")
    cases.append(_bound(i, '{"component":"api","field":"service..port","input":"i"}'))
    fields.append("bind[0].field")
    needles.append("a binding's field is a path of non-empty segments, service.<field>")
    cases.append(_bound(s, '{"component":"api","field":"service.","input":"s"}'))
    fields.append("bind[0].field")
    needles.append("a binding's field is a path of non-empty segments, service.<field>")
    var port = String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":8080}}')
    cases.append(_bound(s, '{"component":"api","field":"service.port.x","input":"s"}', port))
    fields.append("bind[0].field")
    needles.append("a STRING input cannot be written to service.port.x: \"port\" is not a message or a map")
    var path = String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"healthPath":"/h"}}')
    var m = String('{"name":"m","type":"INPUT_VALUE_MAP"}')
    cases.append(_bound(m, '{"component":"api","field":"service.health_path","input":"m"}', path))
    fields.append("bind[0].field")
    needles.append("a VALUE_MAP input cannot be written to service.health_path: \"health_path\" is not a map")
    for k in range(len(cases)):
        var d: List[String] = [cases[k]]
        _one(d, String(_EMPTY), "acme.x@1", fields[k], needles[k])
    print("  test_a_binding: PASS")


comptime _INNER = (
    '{"name":"acme.in","version":"1",'
    + '"input":[{"name":"img","type":"INPUT_IMAGE"},{"name":"env","type":"INPUT_VALUE_MAP"},{"name":"n","type":"INPUT_INT"}],'
    + '"component":[{"id":"job","containerJob":{}}],'
    + '"bind":[{"component":"job","field":"container_job.image","input":"img"},'
    + '{"component":"job","field":"container_job.env","input":"env"},'
    + '{"component":"job","field":"container_job.max_retries","input":"n"}]}'
)


def test_a_binding_into_a_nested_instance() raises:
    """Catches: a plain input bound into an instance (it has `Value.input`),
    an IMAGE written anywhere but `composite.image_input.`, a nested input
    the inner definition does not declare or declares of another type, and
    an input bound both by the instance and by a binding (N14)."""
    var nested = String('{"id":"in","composite":{"definition":"acme.in","version":"1"}}')
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    cases.append(_bound('{"name":"k","type":"INPUT_INT"}', '{"component":"in","field":"composite.input.n","input":"k"}', nested))
    fields.append("bind[0].field")
    needles.append("an INT input passes down as composite.input.<name>")
    cases.append(_bound('{"name":"m","type":"INPUT_IMAGE"}', '{"component":"in","field":"composite.map_input.env","input":"m"}', nested))
    fields.append("bind[0].field")
    needles.append("an IMAGE input passes down to an instance as composite.image_input.<name>")
    cases.append(_bound('{"name":"m","type":"INPUT_IMAGE"}', '{"component":"in","field":"composite.image_input.nope","input":"m"}', nested))
    fields.append("bind[0].field")
    needles.append("acme.in@1 declares no input \"nope\"")
    cases.append(_bound('{"name":"m","type":"INPUT_VALUE_MAP"}', '{"component":"in","field":"composite.map_input.img","input":"m"}', nested))
    fields.append("bind[0].field")
    needles.append("input \"img\" of acme.in@1 is an IMAGE input, and \"m\" is a VALUE_MAP input")
    var both = String('{"id":"in","composite":{"definition":"acme.in","version":"1","imageInput":{"img":{"digest":"sha256:a1"}}}}')
    cases.append(_bound('{"name":"m","type":"INPUT_IMAGE"}', '{"component":"in","field":"composite.image_input.img","input":"m"}', both))
    fields.append("bind[0].field")
    needles.append("input \"img\" is bound twice")
    for k in range(len(cases)):
        var d: List[String] = [String(_INNER), cases[k]]
        _one(d, String(_EMPTY), "acme.x@1", fields[k], needles[k])
    print("  test_a_binding_into_a_nested_instance: PASS")


# ---- 3. a presence --------------------------------------------------------------------------------


def test_a_presence() raises:
    """Catches: each presence rule missing (N15: a presence on an input that
    is always set, which could never make the component absent)."""
    var comps = String('"component":[') + _B + "],"
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    var opt = String('"input":[{"name":"o","type":"INPUT_STRING"}],')
    cases.append(_x(opt + comps + '"presence":[{"component":"nope","ifInput":"o"}]'))
    fields.append("presence[0].component")
    needles.append("has no component \"nope\"")
    cases.append(_x(opt + comps + '"presence":[{"component":"b","ifInput":"nope"}]'))
    fields.append("presence[0].if_input")
    needles.append("declares no input \"nope\"")
    cases.append(_x(String('"input":[{"name":"o","type":"INPUT_STRING","required":true}],') + comps + '"presence":[{"component":"b","ifInput":"o"}]'))
    fields.append("presence[0].if_input")
    needles.append("is always set")
    cases.append(_x(String('"input":[{"name":"o","type":"INPUT_STRING","default":{"literal":"x"}}],') + comps + '"presence":[{"component":"b","ifInput":"o"}]'))
    fields.append("presence[0].if_input")
    needles.append("is always set")
    cases.append(_x(opt + comps + '"presence":[{"component":"b","ifInput":"o"},{"component":"b","ifInput":"o"}]'))
    fields.append("presence[1]")
    needles.append("a second presence of \"b\"")
    for k in range(len(cases)):
        var d: List[String] = [cases[k]]
        _one(d, String(_EMPTY), "acme.x@1", fields[k], needles[k])
    print("  test_a_presence: PASS")


# ---- 4. a component's value or reference -------------------------------------------------------


def test_a_value_or_reference_naming_a_typed_input() raises:
    """Catches: an IMAGE input named where a value stands (it has no value
    form) and an INT input named where a reference stands (N16)."""
    var ins = String('"input":[{"name":"m","type":"INPUT_IMAGE"},{"name":"k","type":"INPUT_INT"}],')
    var env = _x(ins + '"component":[{"id":"api","service":{"env":{"E":{"input":"m"}}}}]')
    var d1: List[String] = [env]
    _one(d1, String(_EMPTY), "acme.x@1", "component[api].service.env.E", "input \"m\" is an IMAGE input: a binding writes it")
    var ref_ = _x(ins + '"component":[' + _B + ',{"id":"g","grant":{"principal":{"input":"k"},"target":{"local":"b"},"access":"READ"}}]')
    var d2: List[String] = [ref_]
    _one(d2, String(_EMPTY), "acme.x@1", "component[g].grant.principal", "input \"k\" is an INT input, not a REF input")
    print("  test_a_value_or_reference_naming_a_typed_input: PASS")


# ---- 5. an instance -----------------------------------------------------------------------------


comptime _TYPED = (
    '{"name":"acme.t","version":"1",'
    + '"input":[{"name":"img","type":"INPUT_IMAGE","required":true},{"name":"env","type":"INPUT_VALUE_MAP"},'
    + '{"name":"n","type":"INPUT_INT"},{"name":"on","type":"INPUT_BOOL"},{"name":"s","type":"INPUT_STRING"}],'
    + '"component":[{"id":"api","service":{}}],'
    + '"bind":[{"component":"api","field":"service.image","input":"img"},'
    + '{"component":"api","field":"service.env","input":"env"},'
    + '{"component":"api","field":"service.port","input":"n"},'
    + '{"component":"api","field":"service.public","input":"on"},'
    + '{"component":"api","field":"service.health_path","input":"s"}]}'
)


def _t(rest: String) -> String:
    return String('{"resource":[{"id":"t","composite":{"definition":"acme.t","version":"1",') + rest + String("}}]}")


comptime _IMG = '"imageInput":{"img":{"digest":"sha256:a1"}}'


def test_an_instance_of_typed_inputs() raises:
    """Catches: each instance rule of the typed inputs missing (N17: an INT
    literal not checked, so `8o80` reaches a port; N18: a required IMAGE
    input left unbound accepted). Nested: an IMAGE input of the enclosing
    definition passed as a plain value, to an INT input or into a map
    (N29: the type of the passed input not checked, so an image has no
    value to write), and a map value naming a resource but none of its
    outputs (N30: a whole resource, which has no value, written into the
    env)."""
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    cases.append(_t(String('"input":{"n":{"literal":"8o80"}},') + _IMG))
    fields.append("composite.input.n")
    needles.append("an INT input is a decimal integer")
    cases.append(_t(String('"input":{"on":{"literal":"TRUE"}},') + _IMG))
    fields.append("composite.input.on")
    needles.append("a BOOL input is true or false")
    cases.append(_t(String('"input":{"n":{"param":"port"}},') + _IMG))
    fields.append("composite.input.n")
    needles.append("an INT input takes a literal")
    cases.append(_t(String('"input":{"img":{"literal":"sha256:a1"}},') + _IMG))
    fields.append("composite.input.img")
    needles.append("an IMAGE input is bound in image_input")
    cases.append(_t(String('"imageInput":{"img":{"digest":"sha256:a1"},"s":{"digest":"sha256:a1"}}')))
    fields.append("composite.image_input.s")
    needles.append("acme.t@1 declares no IMAGE input \"s\"")
    cases.append(_t(String('"imageInput":{"img":{"platform":"linux/amd64"}}')))
    fields.append("composite.image_input.img")
    needles.append("an image is a build step's output or a digest")
    cases.append(_t(String('"mapInput":{"n":{"value":{}}},') + _IMG))
    fields.append("composite.map_input.n")
    needles.append("acme.t@1 declares no VALUE_MAP input \"n\"")
    cases.append(_t(String('"mapInput":{"env":{"value":{"E":{}}}},') + _IMG))
    fields.append("composite.map_input.env.E")
    needles.append("has no value")
    cases.append(_t(String('"input":{"s":{"literal":"/h"}}')))
    fields.append("composite.input")
    needles.append("required input \"img\" of acme.t@1 is not bound")
    for k in range(len(cases)):
        var d: List[String] = [String(_TYPED)]
        _one(d, cases[k], "t", fields[k], needles[k])
    var outer = String(
        '{"name":"acme.o","version":"1","input":[{"name":"s","type":"INPUT_STRING"},{"name":"i","type":"INPUT_IMAGE"}],'
        + '"component":[{"id":"t","composite":{"definition":"acme.t","version":"1","input":{"n":{"input":"s"}}}}],'
        + '"bind":[{"component":"t","field":"composite.image_input.img","input":"i"}]}'
    )
    var d3: List[String] = [String(_TYPED), outer]
    _one(d3, String(_EMPTY), "acme.o@1", "component[t].composite.input.n", "input \"s\" is a STRING input; this one takes an INT")
    var head = String(
        '{"name":"acme.o","version":"1","input":[{"name":"i","type":"INPUT_IMAGE"}],"component":[' + _B + ','
        + '{"id":"t","composite":{"definition":"acme.t","version":"1",'
    )
    var tail = String('}}],"bind":[{"component":"t","field":"composite.image_input.img","input":"i"}]}')
    var d4: List[String] = [String(_TYPED), head + '"input":{"n":{"input":"i"}}' + tail]
    _one(d4, String(_EMPTY), "acme.o@1", "component[t].composite.input.n", "input \"i\" is an IMAGE input: a binding passes it down")
    var d5: List[String] = [String(_TYPED), head + '"mapInput":{"env":{"value":{"E":{"input":"i"}}}}' + tail]
    _one(d5, String(_EMPTY), "acme.o@1", "component[t].composite.map_input.env.E", "input \"i\" is an IMAGE input: a binding passes it down")
    var d6: List[String] = [String(_TYPED), head + '"mapInput":{"env":{"value":{"E":{"ref":{"local":"b"}}}}}' + tail]
    _one(d6, String(_EMPTY), "acme.o@1", "component[t].composite.map_input.env.E", "a value names an output of the resource (standard or named)")
    print("  test_an_instance_of_typed_inputs: PASS")


# ---- 6. the kci namespace ---------------------------------------------------------------------------


def test_the_kci_namespace() raises:
    """Catches: an author's definition accepted under a name kci ships (N19:
    it would stand in for kci's own), and a `kci.` name kci does not ship."""
    var body = String('"version":"1","component":[') + _B + "]}"
    var k1: List[String] = [String('{"name":"kci.job",') + body]
    _one(k1, String(_EMPTY), "kci.job@1", "name", "is not one of them (kci ships: kci.job@1 sha256:")
    var k2: List[String] = [String('{"name":"kci.other",') + body]
    _one(k2, String(_EMPTY), "kci.other@1", "name", "the kci namespace holds the definitions kci ships")
    var k3: List[String] = [String('{"name":"acme.job",') + body]
    var x = expand(Catalog.v1(), _defs(k3), _list(String(_EMPTY)))
    assert_equal(len(x.findings), 0, _all(x.findings))
    print("  test_the_kci_namespace: PASS")


def main() raises:
    print("test_cloud_compose_bind_refusals: bindings, presences, typed inputs, the kci namespace")
    test_typed_input_defaults()
    test_a_binding()
    test_a_binding_into_a_nested_instance()
    test_a_presence()
    test_a_value_or_reference_naming_a_typed_input()
    test_an_instance_of_typed_inputs()
    test_the_kci_namespace()
    print("ALL kci_cloud COMPOSE BIND REFUSAL TESTS PASSED")
