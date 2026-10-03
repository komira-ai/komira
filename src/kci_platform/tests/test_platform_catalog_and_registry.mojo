# =============================================================================
# test_platform_catalog_and_registry.mojo
# =============================================================================
#
# 1. The catalog table agrees with the generated code where generated code can
#    answer: a body decoded from wire field N maps back to N, every exposed
#    output is a value of `Output`, every accepted access a value of `Access`.
# 2. The declaration rule: every catalog type implemented or declared absent,
#    exactly once; ABSENT_BY_DESIGN only for PLATFORM_BOUND; NOT_YET only for
#    PORTABLE; a complete platform has no NOT_YET; nothing outside the
#    catalog. v1 has no PLATFORM_BOUND type, so the bound rows here are a
#    synthetic catalog row (field 19, the number held for a later bound type),
#    which is exactly how the rule must already hold when one is added.
# 3. The registry refuses a duplicate id and an illegal declaration at add.
# 4. `PlatformId` compares by value.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import decode_proto
from kci_resource_proto.resource import Access, Output, Resource

from kci_platform import (
    Absence,
    Catalog,
    CatalogType,
    PlatformEntry,
    PlatformId,
    Registry,
    ABSENT_BY_DESIGN,
    NOT_YET,
    PORTABLE,
    PLATFORM_BOUND,
    FIELD_SERVICE,
    FIELD_JOB,
    body_field,
    declaration_problems,
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
    assert_equal(len(c.types), 2, "v1 declares service and job")
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
    print("  test_catalog_arms_match_the_wire: PASS")


def test_catalog_names_are_generated_enum_values() raises:
    var c = Catalog.v1()
    for i in range(len(c.types)):
        ref t = c.types[i]
        assert_true(t.portability == PORTABLE or t.portability == PLATFORM_BOUND)
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
    c.add(CatalogType(19, String("bound_thing"), PLATFORM_BOUND, List[String](), List[String]()))
    return c^


def _entry(
    complete: Bool, var implemented: List[Int], var absences: List[Absence]
) -> PlatformEntry:
    return PlatformEntry(PlatformId(String("p")), complete, implemented^, absences^)


def _ints(a: Int, b: Int = -1) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    if b >= 0:
        l.append(b)
    return l^


def test_declaration_rules() raises:
    var c = _with_bound()

    # legal: complete, hosts both portable types, bound type absent by design
    var ok = List[Absence]()
    ok.append(Absence(19, ABSENT_BY_DESIGN, String("no such service here")))
    assert_equal(len(declaration_problems(c, _entry(True, _ints(10, 11), ok^))), 0)

    # legal: not complete, a portable type not yet
    var later = List[Absence]()
    later.append(Absence(11, NOT_YET, String("no runner")))
    later.append(Absence(19, ABSENT_BY_DESIGN, String("none")))
    assert_equal(len(declaration_problems(c, _entry(False, _ints(10), later^))), 0)

    # a type nobody decided about
    var p = _joined(declaration_problems(c, _entry(True, _ints(10, 11), List[Absence]())))
    assert_true(_has(p, "'bound_thing' is neither implemented nor declared absent"), p)

    # ABSENT_BY_DESIGN on a portable type
    var a1 = List[Absence]()
    a1.append(Absence(11, ABSENT_BY_DESIGN, String("x")))
    a1.append(Absence(19, ABSENT_BY_DESIGN, String("x")))
    p = _joined(declaration_problems(c, _entry(False, _ints(10), a1^)))
    assert_true(_has(p, "'job' is PORTABLE; ABSENT_BY_DESIGN is legal only"), p)

    # NOT_YET on a bound type
    var a2 = List[Absence]()
    a2.append(Absence(19, NOT_YET, String("x")))
    p = _joined(declaration_problems(c, _entry(False, _ints(10, 11), a2^)))
    assert_true(_has(p, "'bound_thing' is PLATFORM_BOUND; NOT_YET is legal only"), p)

    # complete, yet a portable type is not yet
    var a3 = List[Absence]()
    a3.append(Absence(11, NOT_YET, String("x")))
    a3.append(Absence(19, ABSENT_BY_DESIGN, String("x")))
    p = _joined(declaration_problems(c, _entry(True, _ints(10), a3^)))
    assert_true(_has(p, "claims to be complete but does not host PORTABLE type 'job'"), p)

    # declared twice
    var a4 = List[Absence]()
    a4.append(Absence(11, NOT_YET, String("x")))
    a4.append(Absence(19, ABSENT_BY_DESIGN, String("x")))
    p = _joined(declaration_problems(c, _entry(False, _ints(10, 11), a4^)))
    assert_true(_has(p, "'job' is declared more than once"), p)

    # outside the catalog
    var a5 = List[Absence]()
    a5.append(Absence(19, ABSENT_BY_DESIGN, String("x")))
    a5.append(Absence(77, NOT_YET, String("x")))
    p = _joined(declaration_problems(c, _entry(True, _ints(10, 11), a5^)))
    assert_true(_has(p, "declares field 77 absent, which is not in the catalog"), p)
    var a6 = List[Absence]()
    a6.append(Absence(19, ABSENT_BY_DESIGN, String("x")))
    var impl = _ints(10, 11)
    impl.append(40)
    p = _joined(declaration_problems(c, _entry(True, impl^, a6^)))
    assert_true(_has(p, "implements field 40, which is not in the catalog"), p)
    print("  test_declaration_rules: PASS")


def test_registry_refuses_at_add() raises:
    var reg = Registry(Catalog.v1())
    reg.add(PlatformEntry(PlatformId(String("a")), True, _ints(10, 11), List[Absence]()))
    var raised = False
    try:
        reg.add(PlatformEntry(PlatformId(String("a")), True, _ints(10, 11), List[Absence]()))
    except e:
        raised = True
        assert_true(_has(String(e), "linked twice"), String(e))
    assert_true(raised, "a duplicate id is refused")
    raised = False
    try:
        reg.add(PlatformEntry(PlatformId(String("b")), True, _ints(10), List[Absence]()))
    except e:
        raised = True
        assert_true(_has(String(e), "'job' is neither implemented"), String(e))
    assert_true(raised, "an illegal declaration is refused at start-up")
    assert_equal(len(reg.entries), 1)
    assert_equal(len(reg.implementers(FIELD_JOB)), 1)
    assert_equal(reg.implementers(FIELD_JOB)[0], "a")
    print("  test_registry_refuses_at_add: PASS")


def test_platform_id_compares_by_value() raises:
    assert_true(PlatformId(String("x")) == PlatformId(String("x")))
    assert_true(PlatformId(String("x")) != PlatformId(String("y")))
    assert_equal(PlatformId(String("x")).text(), "x")
    print("  test_platform_id_compares_by_value: PASS")


def main() raises:
    print("test_platform_catalog_and_registry")
    test_catalog_arms_match_the_wire()
    test_catalog_names_are_generated_enum_values()
    test_catalog_refuses_unset_and_duplicates()
    test_declaration_rules()
    test_registry_refuses_at_add()
    test_platform_id_compares_by_value()
    print("ALL kci_platform CATALOG AND REGISTRY TESTS PASSED")
