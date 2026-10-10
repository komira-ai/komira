# =============================================================================
# test_cloud_compose_paths.mojo
# =============================================================================
#
# EXPANSION REFUSES A REFERENCE IT CANNOT FOLLOW where the reference is used
# (compose.mojo step 5): the definitions load, the reference is judged when
# it is rewritten. Pure: no cloud. Each case requires EXACTLY one finding, on
# the resource that holds the reference (its full path when it is produced),
# at the field the author wrote, with the named reason.
#
# The definitions: `acme.shop@3` holds `web` (an instance of `acme.web@1`,
# exported), `data` (a bucket, not exported) and `logs` (a bucket,
# exported); `acme.web@1` holds `api` (a service) and `files` (a bucket,
# exported), and declares the output `url`. A top-level service `reports`
# holds the reference under test.
#
# 1. A PATH THAT CANNOT BE FOLLOWED: a segment that is not exported (the
#    definition's own changes stay invisible outside), a segment that is
#    not a component (a later version dropped it: the dangling reference),
#    a segment below a primitive, a path below a resource that is not an
#    instance.
# 2. A REFERENCE THAT ENDS ON AN INSTANCE: with no output (an instance has
#    no object to grant to or depend on), with a standard output (it exposes
#    only what it declares), with an output it does not declare.
# 3. THE BASES: `local`, `input` and `Value.input` outside every definition;
#    two bases; a written empty base; an empty path; a path with no base;
#    a `resource` that holds `/` (the full path of a produced resource,
#    which would skip the export check), in a reference, in a value and in
#    a REF input a top-level instance binds.
# 4. INSIDE A DEFINITION, at the instance: a REF input bound to a primitive,
#    with a path below it (only known once the input is bound), refused on
#    the produced resource; a required input bound to an optional input of
#    the enclosing definition that the instance left unbound.
# The control: the same list with a reference that can be followed expands
# with no finding.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Catalog, Finding, expand


comptime _WEB = (
    '{"name":"acme.web","version":"1","component":['
    + '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}}},'
    + '{"id":"files","bucket":{}}],'
    + '"output":[{"name":"url","from":{"local":"api","standard":"URL"}}],'
    + '"export":["files"]}'
)

comptime _SHOP = (
    '{"name":"acme.shop","version":"3","component":['
    + '{"id":"web","composite":{"definition":"acme.web","version":"1"}},'
    + '{"id":"data","bucket":{}},{"id":"logs","bucket":{}}],'
    + '"output":[{"name":"url","from":{"local":"web","named":"url"}}],'
    + '"export":["web","logs"]}'
)


def _defs(texts: List[String]) raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    for i in range(len(texts)):
        out.append(decode_json[CompositeDefinition](texts[i]))
    return out^


def _all(fs: List[Finding]) -> String:
    var s = String("")
    for i in range(len(fs)):
        s += String("\n  ") + fs[i].resource_id + String(" | ") + fs[i].field_path + String(" | ") + fs[i].reason
    return s^


def _reports(uses_target: String, env_value: String) -> String:
    """The list: `store` (acme.shop@3), a bucket `plain`, and `reports`, a
    service whose `uses[0].target` is `uses_target` (READ) and whose env
    `E` is `env_value`; either may be empty (left out)."""
    var uses = String("")
    if uses_target.byte_length() > 0:
        uses = String('"uses":[{"target":') + uses_target + String(',"access":"READ"}],')
    var env = String("")
    if env_value.byte_length() > 0:
        env = String(',"env":{"E":') + env_value + String("}")
    return (
        String('{"resource":[{"id":"store","composite":{"definition":"acme.shop","version":"3"}},')
        + String('{"id":"plain","bucket":{}},')
        + String('{"id":"reports",')
        + uses
        + String('"service":{"image":{"digest":"sha256:c3"},"internal":{}')
        + env
        + String("}}]}")
    )


def _one(list: String, rid: String, field: String, needle: String, extra: String = String("")) raises:
    var defs: List[String] = [String(_WEB), String(_SHOP)]
    if extra.byte_length() > 0:
        defs.append(extra)
    var x = expand(Catalog.v1(), _defs(defs), decode_json[ResourceList](list).resource.copy())
    var got = _all(x.findings)
    assert_equal(len(x.findings), 1, String("one finding (") + needle + String("), got:") + got)
    assert_equal(x.findings[0].resource_id, rid, got)
    assert_equal(x.findings[0].field_path, field, got)
    assert_true(x.findings[0].reason.find(needle) >= 0, String("reason holds ") + needle + String(":") + got)


# ---- the control ------------------------------------------------------------------------------


def test_a_reference_that_can_be_followed_expands() raises:
    """The control of every case below: an exported path two levels down and
    a declared output, from outside, expand with no finding."""
    var defs: List[String] = [String(_WEB), String(_SHOP)]
    var l = _reports(
        String('{"resource":"store","path":"web/files"}'), String('{"ref":{"resource":"store","named":"url"}}')
    )
    var x = expand(Catalog.v1(), _defs(defs), decode_json[ResourceList](l).resource.copy())
    assert_equal(len(x.findings), 0, _all(x.findings))
    ref r = x.resources[len(x.resources) - 1]
    assert_equal(r.uses[0].target.value().resource, "store/web/files")
    assert_equal(r.service.value().env["E"].ref_.value().resource, "store/web/api")
    print("  test_a_reference_that_can_be_followed_expands: PASS")


# ---- 1. a path that cannot be followed ----------------------------------------------------------


def test_a_path_that_cannot_be_followed() raises:
    """Catches: the export check missing (an outsider reaches a private
    component), a dropped component silently resolved, a path accepted
    below a primitive or below a resource that is no instance."""
    var t = String("uses[0].target")
    _one(_reports(String('{"resource":"store","path":"data"}'), String("")), "reports", t, "component \"data\" of acme.shop@3 is not exported")
    _one(_reports(String('{"resource":"store","path":"uploads"}'), String("")), "reports", t, "\"store\" (acme.shop@3) has no component \"uploads\"")
    _one(_reports(String('{"resource":"store","path":"web/api"}'), String("")), "reports", t, "component \"api\" of acme.web@1 is not exported")
    _one(_reports(String('{"resource":"store","path":"logs/x"}'), String("")), "reports", t, "goes below \"store/logs\", a primitive")
    _one(_reports(String('{"resource":"plain","path":"x"}'), String("")), "reports", t, "goes below \"plain\", a primitive")
    _one(_reports(String('{"resource":"nowhere","path":"x"}'), String("")), "reports", t, "goes below \"nowhere\", which is not a composite instance")
    print("  test_a_path_that_cannot_be_followed: PASS")


# ---- 2. a reference that ends on an instance -----------------------------------------------------


def test_a_reference_that_ends_on_an_instance() raises:
    """Catches: an instance accepted as a grant target or a dependency (it
    has no object), a standard output read off an instance, and an
    undeclared output followed to nothing."""
    _one(_reports(String('{"resource":"store"}'), String("")), "reports", "uses[0].target", "which has no object of its own")
    _one(_reports(String('{"resource":"store","path":"web"}'), String("")), "reports", "uses[0].target", "\"store/web\" is an instance of acme.web@1")
    _one(
        _reports(String(""), String('{"ref":{"resource":"store","standard":"URL"}}')),
        "reports",
        "service.env.E",
        "it exposes only the outputs it declares",
    )
    _one(
        _reports(String(""), String('{"ref":{"resource":"store","named":"nope"}}')),
        "reports",
        "service.env.E",
        "acme.shop@3 declares no output \"nope\" (it declares: url)",
    )
    print("  test_a_reference_that_ends_on_an_instance: PASS")


# ---- 3. the bases ----------------------------------------------------------------------------------


def test_the_bases_of_a_reference() raises:
    """Catches: `local` / `input` / `Value.input` accepted outside every
    definition (each names something only a definition has), two bases,
    an empty base, an empty path, and a path with no base accepted."""
    var t = String("uses[0].target")
    _one(_reports(String('{"local":"plain"}'), String("")), "reports", t, "local and input are for references inside a composite definition")
    _one(_reports(String('{"input":"plain"}'), String("")), "reports", t, "local and input are for references inside a composite definition")
    _one(_reports(String(""), String('{"input":"x"}')), "reports", "service.env.E", "an input is only for values inside a composite definition")
    _one(_reports(String('{"resource":"plain","local":"x"}'), String("")), "reports", t, "names more than one base")
    _one(_reports(String('{"local":""}'), String("")), "reports", t, "an empty base")
    _one(_reports(String('{"resource":"store","path":""}'), String("")), "reports", t, "an empty path")
    _one(_reports(String('{"path":"x"}'), String("")), "reports", t, "a path below no base")
    print("  test_the_bases_of_a_reference: PASS")


comptime _GRANT = (
    '{"name":"acme.grant","version":"1",'
    + '"input":[{"name":"src","type":"INPUT_REF","required":true}],'
    + '"component":[{"id":"api","uses":[{"target":{"input":"src"},"access":"READ"}],'
    + '"service":{"image":{"digest":"sha256:a1"},"internal":{}}}]}'
)


def test_a_full_path_is_not_a_base() raises:
    """Catches: an authored `Ref.resource` holding `/` accepted at the top of
    the list. `store/data` is the id expansion produces for the UNEXPORTED
    `data`, so accepting it lets an outsider grant on, depend on or read a
    private component; an exported one (`store/logs`) is refused the same
    way, because the export check runs only on `path` segments. Mutant:
    drop the `/` check in `resolve_ref` (each case then has no finding)."""
    var t = String("uses[0].target")
    _one(_reports(String('{"resource":"store/data"}'), String("")), "reports", t, "\"store/data\" is a path inside an instance: write resource \"store\" with path \"data\"")
    _one(_reports(String('{"resource":"store/logs"}'), String("")), "reports", t, "\"store/logs\" is a path inside an instance")
    _one(_reports(String('{"resource":"store/web/api"}'), String("")), "reports", t, "write resource \"store\" with path \"web/api\"")
    _one(_reports(String(""), String('{"ref":{"resource":"store/data","standard":"NAME"}}')), "reports", "service.env.E", "\"store/data\" is a path inside an instance")
    _one(
        String('{"resource":[{"id":"store","composite":{"definition":"acme.shop","version":"3"}},')
        + String('{"id":"g","composite":{"definition":"acme.grant","version":"1","input":{"src":{"ref":{"resource":"store/data"}}}}}]}'),
        "g",
        "composite.input.src",
        "\"store/data\" is a path inside an instance",
        String(_GRANT),
    )
    print("  test_a_full_path_is_not_a_base: PASS")


# ---- 4. inside a definition, at the instance ---------------------------------------------------------

comptime _READER = (
    '{"name":"acme.reader","version":"1",'
    + '"input":[{"name":"src","type":"INPUT_REF"}],'
    + '"component":[{"id":"api","uses":[{"target":{"input":"src","path":"x"},"access":"READ"}],'
    + '"service":{"image":{"digest":"sha256:a1"},"internal":{}}}]}'
)

comptime _NEEDS = (
    '{"name":"acme.needs","version":"1",'
    + '"input":[{"name":"domain","type":"INPUT_STRING","required":true}],'
    + '"component":[{"id":"b","bucket":{}}]}'
)

comptime _OUTER = (
    '{"name":"acme.outer","version":"1",'
    + '"input":[{"name":"d","type":"INPUT_STRING"}],'
    + '"component":[{"id":"w","composite":{"definition":"acme.needs","version":"1","input":{"domain":{"input":"d"}}}}]}'
)


def test_a_reference_judged_at_the_instance() raises:
    """Catches: a path below a REF input not checked once the input is
    bound (it is refused on the produced resource, where it is used), and a
    required input that an unbound optional input of the enclosing
    definition leaves unset accepted as bound."""
    _one(
        String('{"resource":[{"id":"plain","bucket":{}},{"id":"r","composite":{"definition":"acme.reader","version":"1",')
        + String('"input":{"src":{"ref":{"resource":"plain"}}}}}]}'),
        "r/api",
        "uses[0].target",
        "goes below \"plain\", a primitive",
        String(_READER),
    )
    var defs: List[String] = [String(_NEEDS), String(_OUTER)]
    var x = expand(
        Catalog.v1(),
        _defs(defs),
        decode_json[ResourceList]('{"resource":[{"id":"o","composite":{"definition":"acme.outer","version":"1"}}]}').resource.copy(),
    )
    var got = _all(x.findings)
    assert_equal(len(x.findings), 1, got)
    assert_equal(x.findings[0].resource_id, "o/w", got)
    assert_equal(x.findings[0].field_path, "composite.input.domain", got)
    assert_true(x.findings[0].reason.find("is bound to an input that is not set") >= 0, got)
    print("  test_a_reference_judged_at_the_instance: PASS")


def main() raises:
    print("test_cloud_compose_paths: what expansion refuses where a reference is used")
    test_a_reference_that_can_be_followed_expands()
    test_a_path_that_cannot_be_followed()
    test_a_reference_that_ends_on_an_instance()
    test_the_bases_of_a_reference()
    test_a_full_path_is_not_a_base()
    test_a_reference_judged_at_the_instance()
    print("ALL kci_cloud COMPOSE PATH TESTS PASSED")
