# =============================================================================
# test_cloud_reference_cycles.mojo
# =============================================================================
#
# `reference_cycle_findings` (cycles.mojo): a reference cycle between
# resources is one FINDING_GRAPH finding, on its smallest id, printed from
# that id, with the reference position of its first step as the field.
#
# 1. A CYCLE IS FOUND: two services reading each other's URL; three
#    resources in a ring, met by the walk from the middle and printed from
#    the smallest id; a pair whose second reads the first twice, reported
#    once; two cycles in one list, in the order the walk meets them.
# 2. WHAT IS NOT AN EDGE: `uses` lines and a grant's ends (two services that
#    call each other), a dead-letter pair, a reference to the resource
#    itself, to a resource not in the list, or from a second resource of an
#    id already listed; a literal or a parameter.
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import FINDING_GRAPH, reference_cycle_findings


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](String('{"resource":[') + json + String("]}")).resource.copy()


def _svc(id: String, env: String) -> String:
    """A service `id` whose env is `env` (a JSON object body)."""
    return String('{"id":"') + id + String('","service":{"image":{"digest":"sha256:a1"},"env":{') + env + String("}}}")


def _ref(key: String, to: String) -> String:
    return String('"') + key + String('":{"ref":{"resource":"') + to + String('","standard":"URL"}}')


def _cycles(json: String) raises -> String:
    var out = String("")
    for f in reference_cycle_findings(_list(json)):
        assert_equal(f.kind, FINDING_GRAPH)
        out += f.resource_id + String(" ") + f.field_path + String(": ") + f.reason + String("\n")
    return out^


comptime _TAIL = "; each resource reads an output of the next, so no order can create them\n"


def test_a_cycle_is_found_once_from_its_smallest_id() raises:
    assert_equal(
        _cycles(_svc(String("b"), _ref(String("A_URL"), String("a"))) + String(",") + _svc(String("a"), _ref(String("B_URL"), String("b")))),
        String("a service.env.B_URL: a reference cycle: a -> b -> a") + _TAIL,
    )
    # The walk starts at y and meets the ring as y, c, x; it prints from c.
    var ring = (
        _svc(String("y"), _ref(String("C"), String("c"))) + String(",") + _svc(String("c"), _ref(String("X"), String("x")))
        + String(",") + _svc(String("x"), _ref(String("Y"), String("y")))
    )
    assert_equal(_cycles(ring), String("c service.env.X: a reference cycle: c -> x -> y -> c") + _TAIL)
    # q reads p twice: the walk closes the cycle twice, and it is reported once.
    var twice = (
        _svc(String("p"), _ref(String("Q"), String("q"))) + String(",")
        + _svc(String("q"), _ref(String("P1"), String("p")) + String(",") + _ref(String("P2"), String("p")))
    )
    assert_equal(_cycles(twice), String("p service.env.Q: a reference cycle: p -> q -> p") + _TAIL)
    var two = ring + String(",") + _svc(String("m"), _ref(String("N"), String("n"))) + String(",") + _svc(String("n"), _ref(String("M"), String("m")))
    assert_equal(
        _cycles(two),
        String("c service.env.X: a reference cycle: c -> x -> y -> c") + _TAIL
        + String("m service.env.N: a reference cycle: m -> n -> m") + _TAIL,
    )


def test_what_is_not_an_edge() raises:
    var calls = String(
        '{"id":"a","service":{"image":{"digest":"sha256:a1"}},"uses":[{"target":{"resource":"b"},"access":"CALL"}]},'
        + '{"id":"b","service":{"image":{"digest":"sha256:b1"}},"uses":[{"target":{"resource":"a"},"access":"CALL"}]},'
        + '{"id":"g","grant":{"principal":{"resource":"a"},"target":{"resource":"g2"},"access":"CALL"}},'
        + '{"id":"g2","grant":{"principal":{"resource":"g"},"target":{"resource":"g"},"access":"CALL"}},'
        + '{"id":"q1","queue":{"deadLetter":{"resource":"q2"}}},{"id":"q2","queue":{"deadLetter":{"resource":"q1"}}}'
    )
    assert_equal(_cycles(calls), "")
    var self_and_gone = (
        _svc(String("s"), _ref(String("ME"), String("s")) + String(",") + _ref(String("GONE"), String("gone"))
        + String(',"LIT":{"literal":"x"},"PARAM":{"param":"p"}'))
    )
    assert_equal(_cycles(self_and_gone), "")
    # The second "d" is not walked: only the first resource of an id is.
    var dup = (
        _svc(String("d"), _ref(String("E"), String("e"))) + String(",") + _svc(String("e"), String(""))
        + String(",") + _svc(String("d"), String("")) + String(",") + _svc(String("e2"), _ref(String("D"), String("d")))
    )
    assert_equal(_cycles(dup), "")


def main() raises:
    test_a_cycle_is_found_once_from_its_smallest_id()
    test_what_is_not_an_edge()
