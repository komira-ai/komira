# =============================================================================
# test_cloud_catalog_and_clouds.mojo
# =============================================================================
#
# 1. The catalog table agrees with the generated code where generated code can
#    answer: a body decoded from wire field N maps back to N, every exposed
#    output is a value of `Output`, every accepted access a value of `Access`.
# 2. The declaration rule: every catalog type implemented or declared absent,
#    exactly once; ABSENT_BY_DESIGN only for CLOUD_BOUND; NOT_YET only for
#    PORTABLE; a complete cloud has no NOT_YET; nothing outside the
#    catalog. v1 has no CLOUD_BOUND type, so the bound rows here are a
#    synthetic catalog row (field 18, a number held for a later type),
#    which is exactly how the rule must already hold when one is added.
# 3. `Clouds` refuses a duplicate id and an illegal declaration at add, and
#    `resolve` refuses an id that is not built in, suggesting the closest.
# 4. `CloudId` compares by value.
# 5. THE BUCKET ROW: PORTABLE, exposes NAME and ADDRESS, accepts READ, WRITE
#    and READ_WRITE (not CALL), retention default KEEP, primary role
#    `bucket`; a service and a job take no retention and land on `run`. The
#    effective retention is the written one, else the default; a reference
#    to a resource lands on its primary node.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import decode_json, decode_proto
from kci_resource_proto.resource import Access, Output, Resource, ResourceList

from kci_cloud import (
    Absence,
    Catalog,
    CatalogType,
    CloudEntry,
    CloudId,
    Clouds,
    ABSENT_BY_DESIGN,
    NOT_YET,
    PORTABLE,
    CLOUD_BOUND,
    FIELD_SERVICE,
    FIELD_JOB,
    FIELD_BUCKET,
    RETENTION_NONE,
    RETENTION_DELETE,
    RETENTION_KEEP,
    effective_retention,
    primary_node,
    body_arms,
    body_field,
    artifact_problems,
)


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _joined(lines: List[String]) -> String:
    var s = String("")
    for i in range(len(lines)):
        s += lines[i] + String("\n")
    return s^


def _resource_with_body(field: Int) -> List[UInt8]:
    """`Resource{id: "r", <field>: {}}` as wire bytes."""
    var b = List[UInt8]()
    b.append(UInt8(0x0A))  # field 1, length-delimited
    b.append(UInt8(1))
    b.append(UInt8(ord("r")))
    b.append(UInt8((field << 3) | 2))
    b.append(UInt8(0))
    return b^


def test_catalog_arms_match_the_wire() raises:
    var c = Catalog.v1()
    assert_equal(len(c.types), 3, "v1 declares service, job and bucket")
    for i in range(len(c.types)):
        var field = c.types[i].field
        var r = decode_proto[Resource](_resource_with_body(field))
        assert_equal(body_field(r), field, c.types[i].name + " maps back to its field")
    var none = decode_proto[Resource](_resource_with_body(12))
    var raised = False
    try:
        _ = body_field(none)
    except e:
        raised = True
        assert_true(_has(String(e), "has no type"), String(e))
    assert_true(raised, "a held, undeclared arm decodes to no type and is refused")

    # The position -> field table: one row per catalog type, same names, and
    # a position beyond it is refused, never mapped to some other type.
    var arms = body_arms()
    assert_equal(len(arms), len(c.types), "one arm row per catalog type")
    for k in range(len(arms)):
        var at = c.index_of(arms[k].field)
        assert_true(at >= 0, String("arm field ") + String(arms[k].field) + " is a catalog type")
        assert_equal(arms[k].name, c.types[at].name, "the arm row and the catalog row agree")
    var beyond = decode_proto[Resource](_resource_with_body(FIELD_SERVICE))
    beyond._oneof0_case = len(arms) + 1
    var refused = False
    try:
        _ = body_field(beyond)
    except e:
        refused = True
        assert_true(_has(String(e), "is not in this kci's catalog table"), String(e))
    assert_true(refused, "an arm position beyond the table is refused")
    print("  test_catalog_arms_match_the_wire: PASS")


def test_catalog_names_are_generated_enum_values() raises:
    var c = Catalog.v1()
    for i in range(len(c.types)):
        ref t = c.types[i]
        assert_true(t.portability == PORTABLE or t.portability == CLOUD_BOUND)
        for k in range(len(t.exposes)):
            assert_true(
                Output.is_known_json_name(t.exposes[k]) and t.exposes[k] != "OUTPUT_UNSET",
                t.name + " exposes a real Output: " + t.exposes[k],
            )
        for k in range(len(t.accepts)):
            assert_true(
                Access.is_known_json_name(t.accepts[k]) and t.accepts[k] != "ACCESS_UNSET",
                t.name + " accepts a real Access: " + t.accepts[k],
            )
    assert_true(c.types[c.index_of(FIELD_SERVICE)].exposes_output("URL"))
    assert_false(c.types[c.index_of(FIELD_JOB)].exposes_output("URL"))
    print("  test_catalog_names_are_generated_enum_values: PASS")


def test_catalog_refuses_unset_and_duplicates() raises:
    var c = Catalog()
    var raised = False
    try:
        c.add(CatalogType(10, String("x"), 0, List[String](), List[String]()))
    except e:
        raised = True
        assert_true(_has(String(e), "UNSET is never legal"), String(e))
    assert_true(raised, "an UNSET portability is refused")
    c.add(CatalogType(10, String("x"), PORTABLE, List[String](), List[String]()))
    raised = False
    try:
        c.add(CatalogType(10, String("y"), PORTABLE, List[String](), List[String]()))
    except:
        raised = True
    assert_true(raised, "a field declared twice is refused")
    print("  test_catalog_refuses_unset_and_duplicates: PASS")


def _with_bound() raises -> Catalog:
    var c = Catalog.v1()
    c.add(CatalogType(18, String("bound_thing"), CLOUD_BOUND, List[String](), List[String]()))
    return c^


def _entry(
    complete: Bool, var implemented: List[Int], var absences: List[Absence]
) -> CloudEntry:
    return CloudEntry(CloudId(String("p")), complete, implemented^, absences^)


def _ints(a: Int, b: Int = -1, c: Int = -1) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    if b >= 0:
        l.append(b)
    if c >= 0:
        l.append(c)
    return l^


def test_artifact_rules() raises:
    var c = _with_bound()

    # legal: complete, hosts every portable type, bound type absent by design
    var ok = List[Absence]()
    ok.append(Absence(18, ABSENT_BY_DESIGN, String("no such service here")))
    assert_equal(len(artifact_problems(c, _entry(True, _ints(10, 11, 14), ok^))), 0)

    # legal: not complete, a portable type not yet
    var later = List[Absence]()
    later.append(Absence(11, NOT_YET, String("no runner")))
    later.append(Absence(18, ABSENT_BY_DESIGN, String("none")))
    assert_equal(len(artifact_problems(c, _entry(False, _ints(10, 14), later^))), 0)

    # a type nobody decided about
    var p = _joined(artifact_problems(c, _entry(True, _ints(10, 11, 14), List[Absence]())))
    assert_true(_has(p, "'bound_thing' is neither implemented nor declared absent"), p)

    # ABSENT_BY_DESIGN on a portable type
    var a1 = List[Absence]()
    a1.append(Absence(11, ABSENT_BY_DESIGN, String("x")))
    a1.append(Absence(18, ABSENT_BY_DESIGN, String("x")))
    p = _joined(artifact_problems(c, _entry(False, _ints(10, 14), a1^)))
    assert_true(_has(p, "'job' is PORTABLE; ABSENT_BY_DESIGN is legal only"), p)

    # NOT_YET on a bound type
    var a2 = List[Absence]()
    a2.append(Absence(18, NOT_YET, String("x")))
    p = _joined(artifact_problems(c, _entry(False, _ints(10, 11, 14), a2^)))
    assert_true(_has(p, "'bound_thing' is CLOUD_BOUND; NOT_YET is legal only"), p)

    # complete, yet a portable type is not yet
    var a3 = List[Absence]()
    a3.append(Absence(11, NOT_YET, String("x")))
    a3.append(Absence(18, ABSENT_BY_DESIGN, String("x")))
    p = _joined(artifact_problems(c, _entry(True, _ints(10, 14), a3^)))
    assert_true(_has(p, "claims to be complete but does not host PORTABLE type 'job'"), p)

    # declared twice
    var a4 = List[Absence]()
    a4.append(Absence(11, NOT_YET, String("x")))
    a4.append(Absence(18, ABSENT_BY_DESIGN, String("x")))
    p = _joined(artifact_problems(c, _entry(False, _ints(10, 11, 14), a4^)))
    assert_true(_has(p, "'job' is declared more than once"), p)

    # outside the catalog
    var a5 = List[Absence]()
    a5.append(Absence(18, ABSENT_BY_DESIGN, String("x")))
    a5.append(Absence(77, NOT_YET, String("x")))
    p = _joined(artifact_problems(c, _entry(True, _ints(10, 11, 14), a5^)))
    assert_true(_has(p, "declares field 77 absent, which is not in the catalog"), p)
    var a6 = List[Absence]()
    a6.append(Absence(18, ABSENT_BY_DESIGN, String("x")))
    var impl = _ints(10, 11, 14)
    impl.append(40)
    p = _joined(artifact_problems(c, _entry(True, impl^, a6^)))
    assert_true(_has(p, "implements field 40, which is not in the catalog"), p)
    print("  test_artifact_rules: PASS")


def test_clouds_refuse_at_add() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(CloudEntry(CloudId(String("a")), True, _ints(10, 11, 14), List[Absence]()))
    var raised = False
    try:
        reg.add(CloudEntry(CloudId(String("a")), True, _ints(10, 11, 14), List[Absence]()))
    except e:
        raised = True
        assert_true(_has(String(e), "built in twice"), String(e))
    assert_true(raised, "a duplicate id is refused")
    raised = False
    try:
        reg.add(CloudEntry(CloudId(String("b")), True, _ints(10), List[Absence]()))
    except e:
        raised = True
        assert_true(_has(String(e), "'job' is neither implemented"), String(e))
    assert_true(raised, "an illegal declaration is refused at start-up")
    assert_equal(len(reg.entries), 1)
    assert_equal(len(reg.implementers(FIELD_JOB)), 1)
    assert_equal(reg.implementers(FIELD_JOB)[0], "a")
    print("  test_clouds_refuse_at_add: PASS")


def test_resolve_names_the_built_in_clouds() raises:
    """There is no plugin path: an id that is not built in is refused, naming
    every built-in cloud and the closest one when it is within two edits."""
    var clouds = Clouds(Catalog.v1())
    clouds.add(CloudEntry(CloudId(String("fake")), True, _ints(10, 11, 14), List[Absence]()))
    var limited = List[Absence]()
    limited.append(Absence(11, NOT_YET, String("no runner")))
    limited.append(Absence(14, NOT_YET, String("no object store")))
    clouds.add(CloudEntry(CloudId(String("fake-limited")), False, _ints(10), limited^))
    assert_true(clouds.resolve(String("fake-limited")) == CloudId(String("fake-limited")))
    assert_equal(clouds.ids()[1], "fake-limited")

    var raised = False
    try:
        _ = clouds.resolve(String("faek"))
    except e:
        raised = True
        var t = String(e)
        assert_true(
            _has(t, 'kci: "faek" is not a cloud built into this kci (built in: fake, fake-limited)'),
            t,
        )
        assert_true(_has(t, 'did you mean "fake"?'), t)
    assert_true(raised, "a typo is refused")

    raised = False
    try:
        _ = clouds.resolve(String("gcp"))
    except e:
        raised = True
        var t = String(e)
        assert_true(_has(t, "(built in: fake, fake-limited)"), t)
        assert_false(_has(t, "did you mean"), "no suggestion when nothing is close: " + t)
    assert_true(raised, "a cloud this kci was not built with is refused")
    print("  test_resolve_names_the_built_in_clouds: PASS")


def test_cloud_id_compares_by_value() raises:
    assert_true(CloudId(String("x")) == CloudId(String("x")))
    assert_true(CloudId(String("x")) != CloudId(String("y")))
    assert_equal(CloudId(String("x")).text(), "x")
    print("  test_cloud_id_compares_by_value: PASS")


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def test_the_bucket_row_retention_and_primary_role() raises:
    var c = Catalog.v1()
    ref b = c.types[c.index_of(FIELD_BUCKET)]
    assert_equal(b.name, "bucket")
    assert_equal(b.portability, PORTABLE)
    assert_true(b.exposes_output("NAME") and b.exposes_output("ADDRESS"))
    assert_false(b.exposes_output("URL"), "a bucket has no URL")
    assert_true(b.accepts_access("READ") and b.accepts_access("WRITE"))
    assert_true(b.accepts_access("READ_WRITE"))
    assert_false(b.accepts_access("CALL"), "a bucket is not called")
    assert_equal(b.retention_default, RETENTION_KEEP, "a bucket is kept by default")
    assert_true(b.takes_retention())
    assert_equal(b.primary_role, "bucket")
    ref svc = c.types[c.index_of(FIELD_SERVICE)]
    ref job = c.types[c.index_of(FIELD_JOB)]
    assert_false(svc.takes_retention(), "a service takes no retention")
    assert_false(job.takes_retention(), "a job takes no retention")
    assert_equal(svc.primary_role, "run")
    assert_equal(job.primary_role, "run")
    assert_false(svc.accepts_access("READ"), "READ is not a service verb")
    assert_false(svc.exposes_output("NAME"), "a service has no NAME")

    var l = _list(
        String('{"resource":[')
        + String('{"id":"kept","bucket":{}},')
        + String('{"id":"scratch","retention":"DELETE","bucket":{}},')
        + String('{"id":"pinned","retention":"KEEP","bucket":{}},')
        + String('{"id":"api","service":{}}')
        + String("]}")
    )
    assert_equal(effective_retention(c, l[0]), RETENTION_KEEP, "unset: the default")
    assert_equal(effective_retention(c, l[1]), RETENTION_DELETE, "written DELETE")
    assert_equal(effective_retention(c, l[2]), RETENTION_KEEP, "written KEEP")
    assert_equal(effective_retention(c, l[3]), RETENTION_NONE, "a service: none")
    assert_equal(primary_node(c, l, String("kept")), "kept/bucket")
    assert_equal(primary_node(c, l, String("api")), "api/run")
    var raised = False
    try:
        _ = primary_node(c, l, String("ghost"))
    except e:
        raised = True
        assert_true(_has(String(e), "names no resource"), String(e))
    assert_true(raised, "a reference to no resource is refused")
    print("  test_the_bucket_row_retention_and_primary_role: PASS")


def main() raises:
    print("test_cloud_catalog_and_clouds")
    test_catalog_arms_match_the_wire()
    test_catalog_names_are_generated_enum_values()
    test_catalog_refuses_unset_and_duplicates()
    test_artifact_rules()
    test_clouds_refuse_at_add()
    test_resolve_names_the_built_in_clouds()
    test_cloud_id_compares_by_value()
    test_the_bucket_row_retention_and_primary_role()
    print("ALL kci_cloud CATALOG AND CLOUDS TESTS PASSED")
