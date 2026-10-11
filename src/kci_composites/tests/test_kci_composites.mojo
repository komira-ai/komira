# =============================================================================
# test_kci_composites.mojo
# =============================================================================
#
# THE DEFINITIONS KCI SHIPS ARE ORDINARY DATA.
#
# 1. THEY READ STRICTLY: `read_kci_definitions` decodes each file with the
#    strict decoder an author's file goes through; they are `kci.job@1` and
#    `kci.app@1`, in that order.
# 2. EACH IS PINNED: its digest (`definition_digest`) is the one kci_cloud's
#    `shipped_definitions` names for its name and version, and every row
#    there has a file. An edited file without a new row is red here, and red
#    at load wherever it is used (the kci namespace rule).
# 3. THEY LOAD: `expand` with both and an empty list has no finding (every
#    load rule of composite.proto holds for them).
# 4. NO SPECIAL CASE: each file's bytes renamed into an author's namespace
#    (`acme.job`, `acme.app`) expand an instance to the same primitives as
#    the shipped one, field for field; only the name differs.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, encode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Catalog, Expansion, definition_digest, expand, shipped_definitions
from kci_composites import read_kci_definitions


def _findings(x: Expansion) -> String:
    var s = String("")
    for i in range(len(x.findings)):
        s += x.findings[i].resource_id + String(" | ") + x.findings[i].field_path + String(" | ") + x.findings[i].reason + String("\n")
    return s^


def test_they_read_strictly() raises:
    """Catches: a file that names a field or enum value the schema does not
    have (the strict decoder refuses it), a file missing, and the order of
    the list changed."""
    var defs = read_kci_definitions()
    assert_equal(len(defs), 2, "two definitions")
    assert_equal(defs[0].name + "@" + defs[0].version, "kci.job@1")
    assert_equal(defs[1].name + "@" + defs[1].version, "kci.app@1")
    print("  test_they_read_strictly: PASS")


def test_each_is_pinned() raises:
    """Catches: a shipped file edited without a new version and row (N20:
    its digest no longer matches), a row with no file, and a file with no
    row (it would be refused at load as a stand-in)."""
    var defs = read_kci_definitions()
    var rows = shipped_definitions()
    assert_equal(len(rows), len(defs), "one row per shipped file")
    var wrong = String("")
    for i in range(len(defs)):
        var found = False
        var digest = definition_digest(defs[i])
        for k in range(len(rows)):
            if rows[k].name == defs[i].name and rows[k].version == defs[i].version:
                found = True
                if rows[k].digest != digest:
                    wrong += String("\n  ") + defs[i].name + String("@") + defs[i].version + String(": the row says ") + rows[k].digest + String(", the file is ") + digest
        if not found:
            wrong += String("\n  ") + defs[i].name + String(" has no row")
    assert_equal(wrong, String(""), "every shipped file matches its row")
    print("  test_each_is_pinned: PASS")


def test_they_load() raises:
    """Catches: a shipped definition that breaks a load rule (a binding to a
    field its type cannot take, a presence on an input that is always set,
    a reserved component id)."""
    var x = expand(Catalog.v1(), read_kci_definitions(), List[Resource]())
    assert_equal(len(x.findings), 0, _findings(x))
    print("  test_they_load: PASS")


comptime _JOB = '{"id":"nightly","composite":{"definition":"<D>","version":"1","input":{"cron":{"literal":"0 3 * * *"},"max_retries":{"literal":"2"}},"imageInput":{"image":{"digest":"sha256:a1"}},"mapInput":{"env":{"value":{"LEVEL":{"literal":"info"}}}}}}'
comptime _APP = '{"id":"web","composite":{"definition":"<D>","version":"1","input":{"public":{"literal":"true"},"port":{"literal":"8081"},"domain":{"literal":"www.example.com"},"zone":{"ref":{"resource":"www"}}},"imageInput":{"image":{"digest":"sha256:b2"}}}}'


def _expanded(defs: List[CompositeDefinition], job: String, app: String) raises -> String:
    var text = String('{"resource":[{"id":"www","dnsZone":{"name":"example.com"}},') + job + String(",") + app + String("]}")
    var x = expand(Catalog.v1(), defs, decode_json[ResourceList](text).resource.copy())
    assert_equal(len(x.findings), 0, _findings(x))
    var s = String("")
    for i in range(len(x.resources)):
        s += encode_json(x.resources[i]) + String("\n")
    return s^


def test_no_special_case() raises:
    """Catches: expansion treating a `kci.` definition differently from the
    same bytes in an author's namespace (N21)."""
    var shipped = read_kci_definitions()
    var renamed = List[CompositeDefinition]()
    for i in range(len(shipped)):
        var d = shipped[i].copy()
        d.name = d.name.replace("kci.", "acme.")
        renamed.append(d^)
    var a = _expanded(shipped, String(_JOB).replace("<D>", "kci.job"), String(_APP).replace("<D>", "kci.app"))
    var b = _expanded(renamed, String(_JOB).replace("<D>", "acme.job"), String(_APP).replace("<D>", "acme.app"))
    assert_equal(a, b, "the same primitives")
    assert_true(a.find('"id":"web/host"') >= 0 and a.find('"id":"nightly/timer"') >= 0, a)
    print("  test_no_special_case: PASS")


def main() raises:
    print("test_kci_composites: the definitions kci ships are ordinary data")
    test_they_read_strictly()
    test_each_is_pinned()
    test_they_load()
    test_no_special_case()
    print("ALL kci_composites TESTS PASSED")
