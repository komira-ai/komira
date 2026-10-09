# =============================================================================
# test_cloud_registry_rules.mojo
# =============================================================================
#
# The registry rules (registry.mojo) and the registry's catalog row, through
# `graph_findings`, the cloud-independent half of validate. No cloud is
# needed: the fakes in kci_cloud_fake run these graphs on every shape.
#
# 1. EVERY REGISTRY REFUSAL, IN ONE PASS, each pinned by resource, field path
#    and reason: a registry with no format, one whose format is a number
#    this kci does not know (5, decoded from bytes), `uses` on a registry,
#    a registry as a grant's principal, DESCRIBE, SEND and CALL asked of a
#    registry, and NAME asked of one (it exposes ADDRESS only). Nothing else
#    is reported.
# 2. A GOOD REGISTRY GRAPH IS CLEAN: registries kept, deleted and at their
#    default; a container job that pushes (WRITE) and reads the ADDRESS, a
#    service that pulls and pushes (READ_WRITE), an identity granted READ.
# 3. THE CATALOG ROW: `registry` (24) is PORTABLE, exposes ADDRESS only,
#    accepts READ, WRITE and READ_WRITE and nothing else, takes retention
#    with the default KEEP, lands on `registry`, and is the thirteenth arm.
#    And the helpers: `format_word`, `registry_format`, and
#    `registry_findings` on another type.
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    FIELD_BUCKET,
    FIELD_REGISTRY,
    FORMAT_OCI,
    PORTABLE,
    RETENTION_DELETE,
    RETENTION_KEEP,
    Catalog,
    Finding,
    body_arms,
    effective_retention,
    format_word,
    graph_findings,
    primary_node,
    registry_findings,
    registry_format,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(findings: List[Finding]) -> List[String]:
    var out = List[String]()
    for i in range(len(findings)):
        out.append(findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason)
    return out^


def _expect(lines: List[String], prefix: String, reason: String) raises:
    """Exactly one finding starts with `prefix` (`id|path|`) and holds
    `reason`."""
    var n = 0
    var all = String("")
    for i in range(len(lines)):
        all += lines[i] + String("\n")
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + all)


def _unknown_format(id: String, format: Int) raises -> Resource:
    """A registry whose format is `format`, from bytes: a later schema's
    value, which JSON names cannot spell here."""
    var b = List[UInt8]()
    b.append(0x0A)  # 1: id
    b.append(UInt8(id.byte_length()))
    for c in id.as_bytes():
        b.append(c)
    b.append(0xC2)  # 24: registry, length-delimited
    b.append(0x01)
    b.append(2)
    b.append(0x08)  # 1: format
    b.append(UInt8(format))
    return decode_proto[Resource](b^)


comptime IMG = '"image":{"digest":"sha256:0011"}'


# ---- 1. every refusal, in one pass ------------------------------------------------


def test_every_registry_refusal_in_one_pass() raises:
    """Catches: the format rule dropped (an unset format lowered as some
    default), a format from a later schema lowered as OCI, `uses` on a
    registry taken (it runs as no identity), a registry taken as a grant's
    principal, a verb the registry does not accept taken (DESCRIBE, SEND,
    CALL), NAME taken from a registry, and a rule that fires on a good
    resource (the total)."""
    var g = _list(
        String('{"resource":[')
        + String('{"id":"images","registry":{"format":"OCI"}},')
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{},')
        + String('"env":{"REG":{"ref":{"resource":"images","standard":"NAME"}}}}},')
        + String('{"id":"r-none","registry":{}},')
        + String('{"id":"r-uses","registry":{"format":"OCI"},')
        + String('"uses":[{"target":{"resource":"api"},"access":"CALL"}]},')
        + String('{"id":"g-from-reg","grant":{"principal":{"resource":"images"},"target":{"resource":"api"},')
        + String('"access":"CALL"}},')
        + String('{"id":"looker","serviceAccount":{},"uses":[{"target":{"resource":"images"},"access":"DESCRIBE"}]},')
        + String('{"id":"sender","serviceAccount":{},"uses":[{"target":{"resource":"images"},"access":"SEND"}]},')
        + String('{"id":"caller","serviceAccount":{},"uses":[{"target":{"resource":"images"},"access":"CALL"}]}')
        + String("]}")
    )
    g.append(_unknown_format(String("r-later"), 5))
    var l = _lines(graph_findings(Catalog.v1(), g))
    _expect(l, "r-none|registry.format|", "no format: a registry names the format of what it holds (OCI)")
    _expect(l, "r-later|registry.format|", "format 5 is not a format this kci knows (OCI)")
    _expect(l, "r-uses|uses|", "a registry runs as no identity, so it cannot use another resource")
    _expect(l, "g-from-reg|grant.principal|", "the principal must be a service_account")
    _expect(l, "looker|uses[0]|", 'registry "images" does not accept access DESCRIBE')
    _expect(l, "sender|uses[0]|", 'registry "images" does not accept access SEND')
    _expect(l, "caller|uses[0]|", 'registry "images" does not accept access CALL')
    _expect(l, "api|service.env.REG|", '"images" (registry) does not expose NAME')
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 8, String("nothing else is reported:\n") + all)
    print("  test_every_registry_refusal_in_one_pass: PASS")


# ---- 2. a good registry graph is clean ----------------------------------------------


def test_a_good_registry_graph_is_clean() raises:
    """Catches: a valid registry refused (its format, retention either way
    or at its default), a verb a registry accepts refused (READ, WRITE,
    READ_WRITE, by `uses` or by a grant), and its ADDRESS refused as a
    value."""
    var g = _list(
        String('{"resource":[')
        + String('{"id":"images","registry":{"format":"OCI"}},')
        + String('{"id":"kept","retention":"KEEP","registry":{"format":"OCI"}},')
        + String('{"id":"scratch","retention":"DELETE","registry":{"format":"OCI"}},')
        + String('{"id":"builder","uses":[{"target":{"resource":"images"},"access":"WRITE"}],')
        + String('"containerJob":{') + String(IMG)
        + String(',"env":{"REGISTRY":{"ref":{"resource":"images","standard":"ADDRESS"}}}}},')
        + String('{"id":"api","uses":[{"target":{"resource":"scratch"},"access":"READ_WRITE"}],')
        + String('"service":{') + String(IMG) + String(',"internal":{}}},')
        + String('{"id":"puller","serviceAccount":{}},')
        + String('{"id":"pull-kept","grant":{"principal":{"resource":"puller"},"target":{"resource":"kept"},')
        + String('"access":"READ"}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 0, String("a good registry graph is clean:\n") + all)
    print("  test_a_good_registry_graph_is_clean: PASS")


# ---- 3. the catalog row and the helpers ------------------------------------------


def test_the_registry_row() raises:
    """Catches: the row at another field or arm position (a decoded registry
    would map to another type), a portability other than PORTABLE, an
    output other than ADDRESS, a verb set other than READ, WRITE and
    READ_WRITE, no retention or a default other than KEEP (deleting a
    registry deletes every artifact in it), a primary role other than
    `registry`, and the helpers reading the wrong field."""
    assert_equal(FIELD_REGISTRY, 24)
    assert_equal(FORMAT_OCI, 1)
    var c = Catalog.v1()
    ref t = c.types[c.index_of(FIELD_REGISTRY)]
    assert_equal(t.name, "registry")
    assert_equal(t.portability, PORTABLE)
    assert_equal(len(t.exposes), 1, "a registry exposes one output")
    assert_equal(t.exposes[0], "ADDRESS")
    assert_equal(len(t.accepts), 3, "a registry accepts three verbs")
    for verb in ["READ", "WRITE", "READ_WRITE"]:
        assert_true(t.accepts_access(String(verb)), String(verb))
    assert_true(t.takes_retention(), "a registry takes retention")
    assert_equal(t.retention_default, RETENTION_KEEP, "KEEP by default")
    assert_equal(t.primary_role, "registry")
    assert_true(t.primary_role.byte_length() <= 8, "a role word is 8 bytes at most")
    var arms = body_arms()
    assert_equal(arms[12].field, FIELD_REGISTRY, "the thirteenth arm, after the network")
    assert_equal(arms[12].name, "registry")
    var l = _list(
        String('{"resource":[{"id":"images","registry":{"format":"OCI"}},')
        + String('{"id":"scratch","retention":"DELETE","registry":{"format":"OCI"}},')
        + String('{"id":"b","bucket":{}}]}')
    )
    assert_equal(effective_retention(c, l[0]), RETENTION_KEEP, "unset is KEEP")
    assert_equal(effective_retention(c, l[1]), RETENTION_DELETE, "a written DELETE wins")
    assert_equal(primary_node(c, l, String("images")), "images/registry")
    assert_equal(format_word(FORMAT_OCI), "OCI")
    assert_equal(format_word(7), "7", "an unknown format is its number")
    assert_equal(registry_format(l[0]), FORMAT_OCI)
    assert_equal(registry_format(l[2]), 0, "not a registry")
    assert_equal(len(registry_findings(FIELD_BUCKET, l[2])), 0, "another type has no registry findings")
    print("  test_the_registry_row: PASS")


def main() raises:
    print("test_cloud_registry_rules")
    test_every_registry_refusal_in_one_pass()
    test_a_good_registry_graph_is_clean()
    test_the_registry_row()
    print("ALL kci_cloud REGISTRY RULE TESTS PASSED")
