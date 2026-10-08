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
#    synthetic catalog row (field 32, a number held for a later type),
#    which is exactly how the rule must already hold when one is added.
# 3. `Clouds` refuses a duplicate id and an illegal declaration at add, and
#    `resolve` refuses an id that is not built in, suggesting the closest.
# 4. `CloudId` compares by value.
# 5. THE BUCKET ROW: PORTABLE, exposes NAME and ADDRESS, accepts READ, WRITE
#    and READ_WRITE (not CALL), retention default KEEP, primary role
#    `bucket`; a service and a container job take no retention and land on
#    `run` (the worker's row is in test_cloud_compute_rules). The
#    effective retention is the written one, else the default; a reference
#    to a resource lands on its primary node.
# 6. THE TABLE ROW: PORTABLE, exposes NAME only, accepts READ, WRITE,
#    READ_WRITE and DESCRIBE (not CALL), retention default KEEP, primary
#    role `table`; it is the fourth body arm, field 13.
# 7. THE MESSAGING ROWS: a queue (field 15, the sixth arm) and a topic (21,
#    the tenth) are PORTABLE, expose NAME and ADDRESS, take retention with
#    the default DELETE, and land on `queue` / `topic`; a queue accepts SEND
#    and RECEIVE, a topic SEND only. A subscription (28, the seventeenth) exposes
#    and accepts nothing, takes no retention, and lands on `sub` (a role
#    word is 8 bytes at most).
#    SEND and RECEIVE are values of the generated `Access`.
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
    FIELD_CONTAINER_JOB,
    FIELD_TABLE,
    FIELD_BUCKET,
    FIELD_SERVICE_ACCOUNT,
    FIELD_GRANT,
    FIELD_QUEUE,
    FIELD_TOPIC,
    FIELD_SUBSCRIPTION,
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
    # The tag is a varint: one byte up to field 15, two from field 16.
    var tag = (field << 3) | 2
    while tag >= 0x80:
        b.append(UInt8((tag & 0x7F) | 0x80))
        tag >>= 7
    b.append(UInt8(tag))
    b.append(UInt8(0))
    return b^


def test_catalog_arms_match_the_wire() raises:
    var c = Catalog.v1()
    assert_equal(
        len(c.types),
        20,
        "v1 declares service, container_job, worker, table, bucket, queue, secret, dns_zone, service_account,"
        + " topic, schedule, network, registry, grant, dns_record, certificate, subscription, subnet, ip_address"
        + " and event_trigger",
    )
    for i in range(len(c.types)):
        var field = c.types[i].field
        var r = decode_proto[Resource](_resource_with_body(field))
        assert_equal(body_field(r), field, c.types[i].name + " maps back to its field")
    var none = decode_proto[Resource](_resource_with_body(32))
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
    assert_false(c.types[c.index_of(FIELD_CONTAINER_JOB)].exposes_output("URL"))
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
    c.add(CatalogType(32, String("bound_thing"), CLOUD_BOUND, List[String](), List[String]()))
    return c^


def _entry(
    complete: Bool, var implemented: List[Int], var absences: List[Absence]
) -> CloudEntry:
    return CloudEntry(CloudId(String("p")), complete, implemented^, absences^)


def _ints(
    a: Int, b: Int = -1, c: Int = -1, d: Int = -1, e: Int = -1, f: Int = -1
) -> List[Int]:
    """The fields given, then the messaging fields (15 queue, 21 topic, 28
    subscription), 16 secret, the name fields (18 DNS zone, 26 DNS record,
    27 certificate), 12 worker, the triggers (22 schedule, 31 event
    trigger), the networks (23 network, 29 subnet, 30 IP address) and 24
    registry, which every entry in these tests implements."""
    var l: List[Int] = [15, 21, 28, 16, 18, 26, 27, 12, 22, 31, 23, 29, 30, 24]
    l.append(a)
    if b >= 0:
        l.append(b)
    if c >= 0:
        l.append(c)
    if d >= 0:
        l.append(d)
    if e >= 0:
        l.append(e)
    if f >= 0:
        l.append(f)
    return l^


def test_artifact_rules() raises:
    var c = _with_bound()

    # legal: complete, hosts every portable type, bound type absent by design
    var ok = List[Absence]()
    ok.append(Absence(32, ABSENT_BY_DESIGN, String("no such service here")))
    assert_equal(len(artifact_problems(c, _entry(True, _ints(10, 11, 13, 14, 20, 25), ok^))), 0)

    # legal: not complete, a portable type not yet
    var later = List[Absence]()
    later.append(Absence(11, NOT_YET, String("no runner")))
    later.append(Absence(32, ABSENT_BY_DESIGN, String("none")))
    assert_equal(len(artifact_problems(c, _entry(False, _ints(10, 13, 14, 20, 25), later^))), 0)

    # a type nobody decided about
    var p = _joined(artifact_problems(c, _entry(True, _ints(10, 11, 13, 14, 20, 25), List[Absence]())))
    assert_true(_has(p, "'bound_thing' is neither implemented nor declared absent"), p)

    # ABSENT_BY_DESIGN on a portable type
    var a1 = List[Absence]()
    a1.append(Absence(11, ABSENT_BY_DESIGN, String("x")))
    a1.append(Absence(32, ABSENT_BY_DESIGN, String("x")))
    p = _joined(artifact_problems(c, _entry(False, _ints(10, 13, 14, 20, 25), a1^)))
    assert_true(_has(p, "'container_job' is PORTABLE; ABSENT_BY_DESIGN is legal only"), p)

    # NOT_YET on a bound type
    var a2 = List[Absence]()
    a2.append(Absence(32, NOT_YET, String("x")))
    p = _joined(artifact_problems(c, _entry(False, _ints(10, 11, 13, 14, 20, 25), a2^)))
    assert_true(_has(p, "'bound_thing' is CLOUD_BOUND; NOT_YET is legal only"), p)

    # complete, yet a portable type is not yet
    var a3 = List[Absence]()
    a3.append(Absence(11, NOT_YET, String("x")))
    a3.append(Absence(32, ABSENT_BY_DESIGN, String("x")))
    p = _joined(artifact_problems(c, _entry(True, _ints(10, 13, 14, 20, 25), a3^)))
    assert_true(_has(p, "claims to be complete but does not host PORTABLE type 'container_job'"), p)

    # declared twice
    var a4 = List[Absence]()
    a4.append(Absence(11, NOT_YET, String("x")))
    a4.append(Absence(32, ABSENT_BY_DESIGN, String("x")))
    p = _joined(artifact_problems(c, _entry(False, _ints(10, 11, 13, 14, 20, 25), a4^)))
    assert_true(_has(p, "'container_job' is declared more than once"), p)

    # outside the catalog
    var a5 = List[Absence]()
    a5.append(Absence(32, ABSENT_BY_DESIGN, String("x")))
    a5.append(Absence(77, NOT_YET, String("x")))
    p = _joined(artifact_problems(c, _entry(True, _ints(10, 11, 13, 14, 20, 25), a5^)))
    assert_true(_has(p, "declares field 77 absent, which is not in the catalog"), p)
    var a6 = List[Absence]()
    a6.append(Absence(32, ABSENT_BY_DESIGN, String("x")))
    var impl = _ints(10, 11, 13, 14, 20, 25)
    impl.append(40)
    p = _joined(artifact_problems(c, _entry(True, impl^, a6^)))
    assert_true(_has(p, "implements field 40, which is not in the catalog"), p)
    print("  test_artifact_rules: PASS")


def test_clouds_refuse_at_add() raises:
    var reg = Clouds(Catalog.v1())
    reg.add(CloudEntry(CloudId(String("a")), True, _ints(10, 11, 13, 14, 20, 25), List[Absence]()))
    var raised = False
    try:
        reg.add(CloudEntry(CloudId(String("a")), True, _ints(10, 11, 13, 14, 20, 25), List[Absence]()))
    except e:
        raised = True
        assert_true(_has(String(e), "built in twice"), String(e))
    assert_true(raised, "a duplicate id is refused")
    raised = False
    try:
        reg.add(CloudEntry(CloudId(String("b")), True, _ints(10), List[Absence]()))
    except e:
        raised = True
        assert_true(_has(String(e), "'container_job' is neither implemented"), String(e))
    assert_true(raised, "an illegal declaration is refused at start-up")
    assert_equal(len(reg.entries), 1)
    assert_equal(len(reg.implementers(FIELD_CONTAINER_JOB)), 1)
    assert_equal(reg.implementers(FIELD_CONTAINER_JOB)[0], "a")
    print("  test_clouds_refuse_at_add: PASS")


def test_resolve_names_the_built_in_clouds() raises:
    """There is no plugin path: an id that is not built in is refused, naming
    every built-in cloud and the closest one when it is within two edits."""
    var clouds = Clouds(Catalog.v1())
    clouds.add(CloudEntry(CloudId(String("fake")), True, _ints(10, 11, 13, 14, 20, 25), List[Absence]()))
    var limited = List[Absence]()
    limited.append(Absence(11, NOT_YET, String("no runner")))
    limited.append(Absence(13, NOT_YET, String("no tables")))
    limited.append(Absence(14, NOT_YET, String("no object store")))
    limited.append(Absence(20, NOT_YET, String("no identities")))
    limited.append(Absence(25, NOT_YET, String("no grants")))
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
    ref job = c.types[c.index_of(FIELD_CONTAINER_JOB)]
    assert_false(svc.takes_retention(), "a service takes no retention")
    assert_false(job.takes_retention(), "a container_job takes no retention")
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


def test_the_identity_rows() raises:
    var c = Catalog.v1()
    ref a = c.types[c.index_of(FIELD_SERVICE_ACCOUNT)]
    assert_equal(a.name, "service_account")
    assert_equal(a.portability, PORTABLE)
    assert_equal(len(a.exposes), 1, "a service account exposes NAME only")
    assert_true(a.exposes_output("NAME"))
    assert_equal(len(a.accepts), 1, "a service account accepts DESCRIBE only")
    assert_true(a.accepts_access("DESCRIBE"))
    assert_false(a.accepts_access("CALL"), "an identity is not called")
    assert_false(a.takes_retention(), "an identity is deleted with its resource")
    assert_equal(a.primary_role, "identity")
    ref g = c.types[c.index_of(FIELD_GRANT)]
    assert_equal(g.name, "grant")
    assert_equal(g.portability, PORTABLE)
    assert_equal(len(g.exposes), 0, "a grant exposes nothing")
    assert_equal(len(g.accepts), 0, "a grant accepts nothing")
    assert_false(g.takes_retention())
    assert_equal(g.primary_role, "grant")
    # DESCRIBE is accepted by nothing else but a table (its definition).
    for i in range(len(c.types)):
        if c.types[i].field != FIELD_SERVICE_ACCOUNT and c.types[i].field != FIELD_TABLE:
            assert_false(c.types[i].accepts_access("DESCRIBE"), c.types[i].name + " takes no DESCRIBE")
    var l = _list(String('{"resource":[{"id":"runner","serviceAccount":{}}]}'))
    assert_equal(primary_node(c, l, String("runner")), "runner/identity")
    print("  test_the_identity_rows: PASS")


def test_the_table_row() raises:
    var c = Catalog.v1()
    ref t = c.types[c.index_of(FIELD_TABLE)]
    assert_equal(t.field, 13)
    assert_equal(t.name, "table")
    assert_equal(t.portability, PORTABLE)
    assert_equal(len(t.exposes), 1, "a table exposes NAME only")
    assert_true(t.exposes_output("NAME"))
    assert_equal(len(t.accepts), 4)
    for v in ["READ", "WRITE", "READ_WRITE", "DESCRIBE"]:
        assert_true(t.accepts_access(String(v)), String("a table accepts ") + String(v))
    assert_false(t.accepts_access("CALL"), "a table is not called")
    assert_equal(t.retention_default, RETENTION_KEEP, "a table is kept by default")
    assert_equal(t.primary_role, "table")
    assert_equal(body_arms()[3].field, FIELD_TABLE, "the fourth arm, by declaration order")
    var l = _list(
        String('{"resource":[{"id":"orders","table":{}},')
        + String('{"id":"cache","retention":"DELETE","table":{}}]}')
    )
    assert_equal(body_field(l[0]), FIELD_TABLE)
    assert_equal(effective_retention(c, l[0]), RETENTION_KEEP, "unset: KEEP")
    assert_equal(effective_retention(c, l[1]), RETENTION_DELETE, "written DELETE")
    assert_equal(primary_node(c, l, String("orders")), "orders/table")
    print("  test_the_table_row: PASS")


def test_the_messaging_rows() raises:
    var c = Catalog.v1()
    var arms = body_arms()
    var fields = [FIELD_QUEUE, FIELD_TOPIC, FIELD_SUBSCRIPTION]
    var names = ["queue", "topic", "subscription"]
    var positions = [5, 9, 16]
    for i in range(3):
        ref t = c.types[c.index_of(fields[i])]
        assert_equal(t.name, String(names[i]))
        assert_equal(t.portability, PORTABLE)
        var role = String("sub") if i == 2 else String(names[i])
        assert_equal(t.primary_role, role, "a reference lands on its own role")
        assert_equal(arms[positions[i]].field, fields[i], String(names[i]) + " by declaration order")
        assert_false(t.accepts_access("CALL"), "messaging is not called")
        assert_false(t.accepts_access("READ"), "messaging is not READ")
    assert_equal(FIELD_QUEUE, 15)
    assert_equal(FIELD_TOPIC, 21)
    assert_equal(FIELD_SUBSCRIPTION, 28)
    ref q = c.types[c.index_of(FIELD_QUEUE)]
    ref t = c.types[c.index_of(FIELD_TOPIC)]
    ref s = c.types[c.index_of(FIELD_SUBSCRIPTION)]
    for o in ["NAME", "ADDRESS"]:
        assert_true(q.exposes_output(String(o)) and t.exposes_output(String(o)), String(o))
    assert_equal(len(q.exposes), 2)
    assert_equal(len(t.exposes), 2)
    assert_equal(len(q.accepts), 2, "a queue accepts SEND and RECEIVE")
    assert_true(q.accepts_access("SEND") and q.accepts_access("RECEIVE"))
    assert_equal(len(t.accepts), 1, "a topic accepts SEND only")
    assert_true(t.accepts_access("SEND"))
    assert_false(t.accepts_access("RECEIVE"), "a topic is received from through a queue")
    assert_equal(len(s.exposes), 0, "a subscription exposes nothing")
    assert_equal(len(s.accepts), 0, "a subscription accepts nothing")
    assert_equal(q.retention_default, RETENTION_DELETE, "a queue is deleted by default")
    assert_equal(t.retention_default, RETENTION_DELETE, "a topic is deleted by default")
    assert_false(s.takes_retention(), "a subscription is deleted with its resource")
    assert_equal(Access.from_json_name("SEND").value, Access.SEND)
    assert_equal(Access.from_json_name("RECEIVE").value, Access.RECEIVE)
    var l = _list(
        String('{"resource":[{"id":"work","queue":{}},{"id":"ev","retention":"KEEP","topic":{}},')
        + String('{"id":"fan","subscription":{"topic":{"resource":"ev"},"queue":{"resource":"work"}}}]}')
    )
    assert_equal(effective_retention(c, l[0]), RETENTION_DELETE, "unset: DELETE")
    assert_equal(effective_retention(c, l[1]), RETENTION_KEEP, "written KEEP")
    assert_equal(effective_retention(c, l[2]), RETENTION_NONE, "a subscription takes none")
    assert_equal(primary_node(c, l, String("work")), "work/queue")
    assert_equal(primary_node(c, l, String("ev")), "ev/topic")
    assert_equal(primary_node(c, l, String("fan")), "fan/sub")
    print("  test_the_messaging_rows: PASS")


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
    test_the_identity_rows()
    test_the_table_row()
    test_the_messaging_rows()
    print("ALL kci_cloud CATALOG AND CLOUDS TESTS PASSED")
