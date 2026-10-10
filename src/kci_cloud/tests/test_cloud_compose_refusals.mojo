# =============================================================================
# test_cloud_compose_refusals.mojo
# =============================================================================
#
# EXPANSION REFUSES A MALFORMED DEFINITION OR INSTANCE when it is LOADED
# (compose.mojo steps 1 to 3), before anything is expanded. Pure: no cloud.
# Every case is one small definition (or list) with one defect, and the test
# requires EXACTLY one finding, on the named definition (`<name>@<version>`)
# or resource, at the named field, with the named reason: a check that is
# missing, a check that fires on the wrong thing, and noise from a second
# check all go red.
#
# 1. THE DEFINITION: its name (one '.', lowercase parts) and version; two
#    definitions with one name and version and different bytes (the same
#    bytes twice are one definition, no finding).
# 2. ITS INPUTS: name grammar, a second of one name, a type this kci does
#    not know (4, DURATION, is held), a required input with a default, a default
#    on a REF input, a default that is not a literal.
# 3. ITS COMPONENTS: none at all; a reserved id (`identity`, `u-*`), an id
#    of 13 bytes, an id with `--`, a second of one id.
# 4. ITS REFERENCES, inside a component: `resource` (a definition is
#    closed), a `local` naming no component, an `input` naming no input, a
#    `Ref.input` naming a STRING input, a `Value.input` naming a REF input
#    or no input, and two bases in one reference.
# 5. ITS EXPORTS AND OUTPUTS: an export of no component, one export twice;
#    an output with no `from`, with a base that is not `local`, with no
#    output named, naming no component, reaching below a primitive, asking a
#    primitive for `named`, asking a primitive for an output its type does
#    not expose, reading an instance without `named`; a second output of
#    one name.
# 6. A NESTED INSTANCE: of a definition not given, of a version not given
#    (the given versions are listed), with a digest that is not the
#    definition's, binding an input not declared, leaving a required input
#    unbound, a literal for a REF input, a reference that reads an output
#    (standard or named) for a REF input, an empty value or a resource
#    with no output for a STRING input, a REF input passed down as a
#    value, a value naming an input the enclosing definition does not
#    declare, and `uses`, `retention`, `physical_name`, labels or `adopt`
#    written on it.
# 7. CONTAINMENT CYCLES: A -> A, A -> B -> A (one finding, printed from its
#    smallest name, whichever definition comes first), A -> B -> C -> A; a
#    diamond (A holds two instances of B) is not a cycle.
# 8. THE TOP OF THE LIST: an instance id outside the resource id grammar, an
#    instance id shared with a primitive, an instance of a definition not
#    given, `uses` on a top-level instance, a top-level instance binding
#    an input to `Value.input` (there is no enclosing definition).
# 9. AN AUTHORED ID IS STILL HELD TO THE ID GRAMMAR: `graph_findings`
#    refuses an authored `a/b`, and accepts it only when the expansion says
#    it produced it.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Catalog, Finding, definition_digest, expand, graph_findings


def _defs(texts: List[String]) raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    for i in range(len(texts)):
        out.append(decode_json[CompositeDefinition](texts[i]))
    return out^


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


comptime _TOP = '{"resource":[{"id":"x","composite":{"definition":"acme.x","version":"1"}}]}'


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


comptime _B = '{"id":"b","bucket":{}}'


# ---- 1. the definition --------------------------------------------------------------------


def test_the_definition_name_and_version() raises:
    """Catches: a name without its namespace, a name in capitals, an empty
    version accepted; two different definitions under one name and
    version both kept (an edited definition would pass as the old one);
    the same definition given twice refused."""
    var a: List[String] = [String('{"name":"acme","version":"1","component":[') + _B + "]}"]
    _one(a, '{"resource":[]}', "acme@1", "name", "exactly one '.'")
    var b: List[String] = [String('{"name":"Acme.x","version":"1","component":[') + _B + "]}"]
    _one(b, '{"resource":[]}', "Acme.x@1", "name", "starts with a lowercase letter")
    var c: List[String] = [String('{"name":"acme.x","version":"","component":[') + _B + "]}"]
    _one(c, '{"resource":[]}', "acme.x@", "version", "a definition has a version")
    var two: List[String] = [_x(String('"component":[') + _B + "]"), _x(String('"doc":"edited","component":[') + _B + "]")]
    _one(two, '{"resource":[]}', "acme.x@1", "", "with different contents")
    var same: List[String] = [_x(String('"component":[') + _B + "]"), _x(String('"component":[') + _B + "]")]
    var x = expand(Catalog.v1(), _defs(same), _list(String(_TOP)))
    assert_equal(len(x.findings), 0, _all(x.findings))
    assert_equal(len(x.resources), 1, "the same definition twice is one definition")
    print("  test_the_definition_name_and_version: PASS")


# ---- 2. its inputs ------------------------------------------------------------------------


def test_the_inputs_of_a_definition() raises:
    """Catches: each input rule missing (the name grammar, unique names, a
    known type, required XOR default, no default for a REF input, a literal
    default)."""
    var comp = String('"component":[') + _B + "],"
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    cases.append(comp + '"input":[{"name":"Bad","type":"INPUT_STRING"}]')
    fields.append("input[Bad]")
    needles.append("starts with a lowercase letter")
    cases.append(comp + '"input":[{"name":"a","type":"INPUT_STRING"},{"name":"a","type":"INPUT_REF"}]')
    fields.append("input[a]")
    needles.append("a second input named \"a\"")
    cases.append(comp + '"input":[{"name":"n","type":4}]')
    fields.append("input[n].type")
    needles.append("input type 4 is not one this kci knows")
    cases.append(comp + '"input":[{"name":"n","type":"INPUT_STRING","required":true,"default":{"literal":"1"}}]')
    fields.append("input[n]")
    needles.append("a required input has no default")
    cases.append(comp + '"input":[{"name":"n","type":"INPUT_REF","default":{"literal":"1"}}]')
    fields.append("input[n].default")
    needles.append("a REF input has no default")
    cases.append(comp + '"input":[{"name":"n","type":"INPUT_STRING","default":{"param":"p"}}]')
    fields.append("input[n].default")
    needles.append("a default is a literal")
    for i in range(len(cases)):
        var d: List[String] = [_x(cases[i])]
        _one(d, '{"resource":[]}', "acme.x@1", fields[i], needles[i])
    print("  test_the_inputs_of_a_definition: PASS")


# ---- 3. its components --------------------------------------------------------------------


def test_the_components_of_a_definition() raises:
    """Catches: an empty definition accepted, a reserved word or `u-` id
    accepted (they read as kci's own roles), the 12-byte bound or the `--`
    rule missing, two components of one id."""
    var none: List[String] = [_x(String('"component":[]'))]
    _one(none, '{"resource":[]}', "acme.x@1", "component", "at least one component")
    var ids: List[String] = ["identity", "u-ab", "abcdefghijklm", "a--b"]
    var why: List[String] = ["\"identity\" is reserved", "is reserved (kci's own roles)", "13 bytes; at most 12", "may not contain '--'"]
    for i in range(len(ids)):
        var d: List[String] = [_x(String('"component":[{"id":"') + ids[i] + '","bucket":{}}]')]
        _one(d, '{"resource":[]}', "acme.x@1", String("component[") + ids[i] + "].id", why[i])
    var dup: List[String] = [_x(String('"component":[') + _B + "," + _B + "]")]
    _one(dup, '{"resource":[]}', "acme.x@1", "component[b].id", "a second component with this id")
    print("  test_the_components_of_a_definition: PASS")


# ---- 4. its references -------------------------------------------------------------------


def test_the_references_inside_a_definition() raises:
    """Catches: an absolute `resource` accepted inside a definition (it would
    not be reusable), a `local` or an `input` naming nothing, a reference
    and a value naming an input of the other kind, and two bases."""
    var ins = String('"input":[{"name":"s","type":"INPUT_STRING"},{"name":"r","type":"INPUT_REF"}],')
    var grant_of = String('{"id":"g","grant":{"principal":')
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    cases.append(grant_of + '{"resource":"outside"},"access":"READ"}}')
    fields.append("component[g].grant.principal")
    needles.append("a definition is closed")
    cases.append(grant_of + '{"local":"nope"},"access":"READ"}}')
    fields.append("component[g].grant.principal")
    needles.append("has no component \"nope\"")
    cases.append(grant_of + '{"input":"nope"},"access":"READ"}}')
    fields.append("component[g].grant.principal")
    needles.append("declares no input \"nope\"")
    cases.append(grant_of + '{"input":"s"},"access":"READ"}}')
    fields.append("component[g].grant.principal")
    needles.append("is a STRING input")
    cases.append(grant_of + '{"local":"b","input":"r"},"access":"READ"}}')
    fields.append("component[g].grant.principal")
    needles.append("more than one base")
    var svc = String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"env":{"E":')
    cases.append(svc + '{"input":"r"}}}}')
    fields.append("component[api].service.env.E")
    needles.append("is a REF input")
    cases.append(svc + '{"input":"nope"}}}}')
    fields.append("component[api].service.env.E")
    needles.append("declares no input \"nope\"")
    for i in range(len(cases)):
        var d: List[String] = [_x(ins + String('"component":[') + _B + "," + cases[i] + "]")]
        _one(d, '{"resource":[]}', "acme.x@1", fields[i], needles[i])
    print("  test_the_references_inside_a_definition: PASS")


# ---- 5. its exports and outputs ------------------------------------------------------------


def test_the_exports_and_outputs_of_a_definition() raises:
    """Catches: an export of nothing, an export twice, and each output rule
    missing (a `from`, a local base, an output named, a component that
    exists, nothing below a primitive, no `named` on a primitive, an output
    the type exposes, `named` on an instance, unique names)."""
    var web = String(
        '{"name":"acme.web","version":"1","component":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}}}],'
        '"output":[{"name":"url","from":{"local":"api","standard":"URL"}}]}'
    )
    var comps = String('"component":[') + _B + ',{"id":"w","composite":{"definition":"acme.web","version":"1"}}],'
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    cases.append('"export":["nope"]')
    fields.append("export[0]")
    needles.append("which is not a component of acme.x@1")
    cases.append('"export":["b","b"]')
    fields.append("export[1]")
    needles.append("exports \"b\" twice")
    cases.append('"output":[{"name":"o"}]')
    fields.append("output[o].from")
    needles.append("an output says which value it is")
    cases.append('"output":[{"name":"o","from":{"resource":"b","standard":"NAME"}}]')
    fields.append("output[o].from")
    needles.append("its base is local")
    cases.append('"output":[{"name":"o","from":{"local":"b"}}]')
    fields.append("output[o].from")
    needles.append("write standard or named")
    cases.append('"output":[{"name":"o","from":{"local":"nope","standard":"NAME"}}]')
    fields.append("output[o].from")
    needles.append("has no component \"nope\"")
    cases.append('"output":[{"name":"o","from":{"local":"b","path":"x","standard":"NAME"}}]')
    fields.append("output[o].from")
    needles.append("goes below \"b\", a primitive")
    cases.append('"output":[{"name":"o","from":{"local":"b","named":"n"}}]')
    fields.append("output[o].from")
    needles.append("\"b\" is a primitive")
    cases.append('"output":[{"name":"o","from":{"local":"b","standard":"URL"}}]')
    fields.append("output[o].from")
    needles.append("\"b\" (bucket) does not expose URL")
    cases.append('"output":[{"name":"o","from":{"local":"w","standard":"URL"}}]')
    fields.append("output[o].from")
    needles.append("read one of its declared outputs with named")
    cases.append('"output":[{"name":"o","from":{"local":"b","standard":"NAME"}},{"name":"o","from":{"local":"b","standard":"NAME"}}]')
    fields.append("output[o]")
    needles.append("a second output named \"o\"")
    for i in range(len(cases)):
        var d: List[String] = [web, _x(comps + cases[i])]
        _one(d, '{"resource":[]}', "acme.x@1", fields[i], needles[i])
    print("  test_the_exports_and_outputs_of_a_definition: PASS")


# ---- 6. a nested instance ------------------------------------------------------------------


def test_a_nested_instance() raises:
    """Catches: an instance of a missing definition or version accepted, a
    digest not compared, an input binding not checked by name, by presence
    or by kind, a binding to an input the enclosing definition does not
    declare left for expansion (an unused definition would load clean;
    mutant: drop the `t_in < 0` check), and `uses`, retention or metadata
    accepted on an instance (which has no object to hold them).
    Mutants each case was seen red on: a REF input bound to a reference
    with an output (`standard` or `named`) accepted (drop the output test
    of the REF arm); a STRING input bound to an empty value accepted (drop
    the `arm == 0` finding); `physical_name` or `adopt` on an instance
    accepted (drop it from the metadata test, which labels alone would
    not show); a binding inside a definition that names a missing local,
    a resource or an undeclared input accepted at load (skip the
    reference check for a composite component's sites)."""
    var web_text = String(
        '{"name":"acme.web","version":"1",'
        '"input":[{"name":"domain","type":"INPUT_STRING","required":true},{"name":"reads","type":"INPUT_REF"}],'
        '"component":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}}}]}'
    )
    var ins = String('"input":[{"name":"r","type":"INPUT_REF"}],"component":[') + _B + ","
    var w = String('{"id":"w"')
    var inst = String('"composite":{"definition":"acme.web","version":"1","input":{"domain":{"literal":"d"}')
    var cases = List[String]()
    var fields = List[String]()
    var needles = List[String]()
    cases.append(w + ',"composite":{"definition":"acme.nope","version":"1"}}')
    fields.append("component[w].composite.definition")
    needles.append("no definition acme.nope@1 was given")
    cases.append(w + ',"composite":{"definition":"acme.web","version":"2","input":{"domain":{"literal":"d"}}}}')
    fields.append("component[w].composite.definition")
    needles.append("no definition acme.web@2 was given (given: acme.web@1)")
    cases.append(w + ',"composite":{"definition":"acme.web","version":"1","digest":"sha256:00","input":{"domain":{"literal":"d"}}}}')
    fields.append("component[w].composite.digest")
    needles.append("digest sha256:00 is not the digest of acme.web@1, " + definition_digest(decode_json[CompositeDefinition](web_text)))
    cases.append(w + "," + inst + ',"zz":{"literal":"z"}}}}')
    fields.append("component[w].composite.input.zz")
    needles.append("acme.web@1 declares no input \"zz\" (it declares: domain, reads)")
    cases.append(w + ',"composite":{"definition":"acme.web","version":"1"}}')
    fields.append("component[w].composite.input")
    needles.append("required input \"domain\" of acme.web@1 is not bound")
    cases.append(w + "," + inst + ',"reads":{"literal":"b"}}}}')
    fields.append("component[w].composite.input.reads")
    needles.append("a REF input takes a reference to a resource")
    cases.append(w + "," + inst + ',"reads":{"ref":{"local":"b","standard":"NAME"}}}}}')
    fields.append("component[w].composite.input.reads")
    needles.append("a REF input takes a reference to a resource: ref { ... } with no output")
    cases.append(w + "," + inst + ',"reads":{"ref":{"local":"b","named":"x"}}}}}')
    fields.append("component[w].composite.input.reads")
    needles.append("a REF input takes a reference to a resource: ref { ... } with no output")
    cases.append(w + "," + inst + ',"reads":{"ref":{"local":"nope"}}}}}')
    fields.append("component[w].composite.input.reads")
    needles.append("acme.x@1 has no component \"nope\"")
    cases.append(w + "," + inst + ',"reads":{"ref":{"resource":"x"}}}}}')
    fields.append("component[w].composite.input.reads")
    needles.append("a definition is closed")
    cases.append(w + "," + inst + ',"reads":{"ref":{"input":"s"}}}}}')
    fields.append("component[w].composite.input.reads")
    needles.append("acme.x@1 declares no input \"s\"")
    cases.append(w + ',"composite":{"definition":"acme.web","version":"1","input":{"domain":{}}}}')
    fields.append("component[w].composite.input.domain")
    needles.append("has no value")
    cases.append(w + ',"composite":{"definition":"acme.web","version":"1","input":{"domain":{"ref":{"local":"b"}}}}}')
    fields.append("component[w].composite.input.domain")
    needles.append("a STRING input takes a value")
    cases.append(w + ',"composite":{"definition":"acme.web","version":"1","input":{"domain":{"input":"r"}}}}')
    fields.append("component[w].composite.input.domain")
    needles.append("pass it down as ref { input: ... }")
    cases.append(w + ',"composite":{"definition":"acme.web","version":"1","input":{"domain":{"input":"nope"}}}}')
    fields.append("component[w].composite.input.domain")
    needles.append("acme.x@1 declares no input \"nope\"")
    cases.append(w + ',"uses":[{"target":{"local":"b"},"access":"READ"}],' + inst + "}}}")
    fields.append("component[w].uses")
    needles.append("an instance has no identity of its own")
    cases.append(w + ',"retention":"KEEP",' + inst + "}}}")
    fields.append("component[w].retention")
    needles.append("each component of its definition sets its retention")
    cases.append(w + ',"labels":{"team":"a"},' + inst + "}}}")
    fields.append("component[w].composite")
    needles.append("physical_name, labels and adopt are written on the components")
    cases.append(w + ',"physicalName":"p",' + inst + "}}}")
    fields.append("component[w].composite")
    needles.append("physical_name, labels and adopt are written on the components")
    cases.append(w + ',"adopt":"ADOPT",' + inst + "}}}")
    fields.append("component[w].composite")
    needles.append("physical_name, labels and adopt are written on the components")
    cases.append(w + ',"adopt":"ADOPT_DELETABLE",' + inst + "}}}")
    fields.append("component[w].composite")
    needles.append("physical_name, labels and adopt are written on the components")
    for i in range(len(cases)):
        var d: List[String] = [web_text, _x(ins + cases[i] + "]")]
        _one(d, '{"resource":[]}', "acme.x@1", fields[i], needles[i])
    print("  test_a_nested_instance: PASS")


# ---- 7. containment cycles -----------------------------------------------------------------


def _holds(name: String, others: List[String]) -> String:
    var comps = String('{"id":"b","bucket":{}}')
    for i in range(len(others)):
        comps += String(',{"id":"i') + String(i) + String('","composite":{"definition":"') + others[i] + String('","version":"1"}}')
    return String('{"name":"') + name + String('","version":"1","component":[') + comps + String("]}")


def test_a_containment_cycle_is_refused() raises:
    """Catches: no cycle check (the expansion would recurse forever), a
    cycle reported once per member, a cycle printed from wherever the walk
    began, and a diamond refused as if it were a cycle."""
    var self_: List[String] = [_holds(String("acme.a"), [String("acme.a")])]
    _one(self_, String(_TOP), "acme.a@1", "component", "a containment cycle: acme.a@1 -> acme.a@1")
    var ab: List[String] = [_holds(String("acme.b"), [String("acme.a")]), _holds(String("acme.a"), [String("acme.b")])]
    _one(ab, String(_TOP), "acme.a@1", "component", "a containment cycle: acme.a@1 -> acme.b@1 -> acme.a@1")
    var abc: List[String] = [
        _holds(String("acme.a"), [String("acme.b")]),
        _holds(String("acme.b"), [String("acme.c")]),
        _holds(String("acme.c"), [String("acme.a")]),
    ]
    _one(abc, String(_TOP), "acme.a@1", "component", "acme.a@1 -> acme.b@1 -> acme.c@1 -> acme.a@1")
    var diamond: List[String] = [_holds(String("acme.x"), [String("acme.b"), String("acme.b")]), _holds(String("acme.b"), List[String]())]
    var x = expand(Catalog.v1(), _defs(diamond), _list(String(_TOP)))
    assert_equal(len(x.findings), 0, _all(x.findings))
    assert_equal(len(x.resources), 3, "x/b, x/i0/b, x/i1/b")
    print("  test_a_containment_cycle_is_refused: PASS")


# ---- 8. the top of the list ------------------------------------------------------------------


def test_the_top_of_the_list() raises:
    """Catches: an instance id that skips the id grammar or the duplicate
    check (its primitives would share an owner with another resource), an
    instance of a missing definition expanded as nothing, and `uses` on a
    top-level instance accepted, and a top-level binding to `Value.input`
    left for expansion (mutant: drop the `in_def < 0` finding in
    `check_instance`; expansion then reports a different field reason)."""
    var d: List[String] = [_x(String('"component":[') + _B + "]")]
    _one(d, '{"resource":[{"id":"Store","composite":{"definition":"acme.x","version":"1"}}]}', "Store", "id", "starts with a lowercase letter")
    _one(
        d,
        '{"resource":[{"id":"s","composite":{"definition":"acme.x","version":"1"}},{"id":"s","bucket":{}}]}',
        "s",
        "id",
        "duplicate id",
    )
    _one(d, '{"resource":[{"id":"s","composite":{"definition":"acme.y","version":"1"}}]}', "s", "composite.definition", "no definition acme.y@1 was given")
    _one(
        d,
        '{"resource":[{"id":"q","queue":{}},{"id":"s","uses":[{"target":{"resource":"q"},"access":"SEND"}],"composite":{"definition":"acme.x","version":"1"}}]}',
        "s",
        "uses",
        "an instance has no identity of its own",
    )
    var dn: List[String] = [_x(String('"input":[{"name":"n","type":"INPUT_STRING"}],"component":[') + _B + "]")]
    _one(
        dn,
        '{"resource":[{"id":"s","composite":{"definition":"acme.x","version":"1","input":{"n":{"input":"m"}}}}]}',
        "s",
        "composite.input.n",
        "an input is only for references inside a composite definition",
    )
    print("  test_the_top_of_the_list: PASS")


# ---- 9. an authored id is still held to the id grammar -----------------------------------------


def test_an_authored_path_id_is_refused() raises:
    """Catches: validate accepting `/` in any id once expansion exists (an
    author could then write a resource that claims to be inside an
    instance, under its owner)."""
    var l = _list(String('{"resource":[{"id":"a/b","bucket":{}}]}'))
    var fs = graph_findings(Catalog.v1(), l)
    assert_equal(len(fs), 1, _all(fs))
    assert_equal(fs[0].field_path, "id")
    assert_true(fs[0].reason.find("lowercase letters, digits and '-' only") >= 0, fs[0].reason)
    var produced: List[String] = ["a/b"]
    assert_equal(len(graph_findings(Catalog.v1(), l, produced)), 0, "a produced path is not an authored id")
    var x = expand(Catalog.v1(), List[CompositeDefinition](), l)
    assert_equal(len(x.produced), 0, "expansion produces no id for an authored one")
    print("  test_an_authored_path_id_is_refused: PASS")


def main() raises:
    print("test_cloud_compose_refusals: what expansion refuses when it loads")
    test_the_definition_name_and_version()
    test_the_inputs_of_a_definition()
    test_the_components_of_a_definition()
    test_the_references_inside_a_definition()
    test_the_exports_and_outputs_of_a_definition()
    test_a_nested_instance()
    test_a_containment_cycle_is_refused()
    test_the_top_of_the_list()
    test_an_authored_path_id_is_refused()
    print("ALL kci_cloud COMPOSE REFUSAL TESTS PASSED")
