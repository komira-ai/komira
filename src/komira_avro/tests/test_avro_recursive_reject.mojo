# =============================================================================
# test_avro_recursive_reject.mojo — recursive-schema reject-on-detect.
# =============================================================================
#
# Acceptance:
#   recursive (cyclic) schemas are REJECTED FOREVER (arrow-rs and DuckDB
#   do the same). Detection is via a named-type visit-stack: a field whose type
#   references a record currently on the construction stack is a cycle.
#
# Coverage:
#   T1  self-referential record (linked-list node) -> raises.
#   T2  self-reference inside a union -> raises.
#   T3  mutual recursion (A -> B -> A) -> raises.
#   T4  a NON-recursive record that re-uses a named type by reference
#       (sibling reference, not ancestor) -> does NOT raise.
# =============================================================================

from std.testing import assert_true

from komira_avro import AvroSchema


def _raises(json: String) -> Bool:
    try:
        var _s = AvroSchema.parse(json)
        return False
    except:
        return True


def test_self_referential_record_rejected() raises:
    """T1: a record whose field references itself by name is a cycle."""
    var json = String(
        '{"type":"record","name":"Node","fields":['
        '{"name":"value","type":"int"},'
        '{"name":"next","type":"Node"}]}'
    )
    assert_true(_raises(json), "self-referential record must be rejected")


def test_self_reference_in_union_rejected() raises:
    """T2: a union branch that references the enclosing record is a cycle."""
    var json = String(
        '{"type":"record","name":"Tree","fields":['
        '{"name":"v","type":"int"},'
        '{"name":"children","type":["null","Tree"]}]}'
    )
    assert_true(_raises(json), "self-reference in union must be rejected")


def test_mutual_recursion_rejected() raises:
    """T3: mutual recursion A -> B -> A is a cycle."""
    var json = String(
        '{"type":"record","name":"A","fields":['
        '{"name":"b","type":'
        '{"type":"record","name":"B","fields":['
        '{"name":"a","type":"A"}]}}]}'
    )
    assert_true(_raises(json), "mutual recursion must be rejected")


def test_sibling_reference_not_rejected() raises:
    """T4: re-using a fully-defined named type by reference (NOT an ancestor
    on the visit-stack) is legal and must NOT be rejected."""
    var json = String(
        '{"type":"record","name":"Pair","fields":['
        '{"name":"first","type":'
        '{"type":"record","name":"Inner","fields":['
        '{"name":"x","type":"int"}]}},'
        '{"name":"second","type":"Inner"}]}'
    )
    # Inner is popped off the stack before `second` references it -> legal.
    var ok = True
    try:
        var _s = AvroSchema.parse(json)
    except:
        ok = False
    assert_true(ok, "sibling reference to a sealed named type must parse")


def main() raises:
    test_self_referential_record_rejected()
    test_self_reference_in_union_rejected()
    test_mutual_recursion_rejected()
    test_sibling_reference_not_rejected()
    print("test_avro_recursive_reject: ALL PASS")
