# =============================================================================
# test_cloud_refusal.mojo
# =============================================================================
#
# `engine_refusal` (refusal.mojo): the one place kci_cloud reads the
# engine's refusal text, structurally.
#
# 1. A REFUSAL OF SEVERAL NODES is one Refusal, by the engine, with one
#    FINDING_OWNERSHIP finding per problem line, in order: the node's owner,
#    the node, the reason after the first ": ".
# 2. NOT A REFUSAL: text that splits into problem lines but is not what the
#    engine renders for this scope and verb (another verb, another cell, a
#    header edited), and a refusal whose problem line names no node.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_reconciler import CellScope, Provenance
from kci_reconciler.ownership import refusal_text as engine_refusal_text

from kci_cloud import FINDING_OWNERSHIP, engine_refusal


def _scope() -> CellScope:
    return CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1")))


def test_a_refusal_of_several_nodes() raises:
    var problems: List[String] = [String("api/run: foreign: x: y"), String("db/table: conflict"), String("web: cannot stamp")]
    var text = engine_refusal_text(_scope(), String("apply"), problems)
    var r = engine_refusal(_scope(), String("apply"), text)
    assert_true(Bool(r), "a refusal")
    assert_true(r.value().by_engine)
    assert_equal(r.value().text, text)
    var got = String("")
    for f in r.value().findings:
        assert_equal(f.kind, FINDING_OWNERSHIP)
        got += f.resource_id + String(" | ") + f.field_path + String(" | ") + f.reason + String("\n")
    assert_equal(got, "api | api/run | foreign: x: y\ndb | db/table | conflict\nweb | web | cannot stamp\n")


def test_what_is_not_a_refusal() raises:
    var problems: List[String] = [String("api/run: foreign"), String("db/table: conflict")]
    var plan = engine_refusal_text(_scope(), String("plan"), problems)
    assert_false(Bool(engine_refusal(_scope(), String("apply"), plan)), "another verb")
    var other = CellScope(String("shop"), String("green"), Provenance(String("run-1"), String("rev-1")))
    assert_false(Bool(engine_refusal(other, String("plan"), plan)), "another cell")
    assert_false(Bool(engine_refusal(_scope(), String("plan"), String("x") + plan)), "an edited header")
    assert_false(Bool(engine_refusal(_scope(), String("plan"), String("timed out\n  api/run: foreign"))), "an error")
    var no_node: List[String] = [String("api/run: foreign"), String(": no node")]
    var t = engine_refusal_text(_scope(), String("plan"), no_node)
    assert_false(Bool(engine_refusal(_scope(), String("plan"), t)), "a line that names no node")
    var no_colon: List[String] = [String("api/run foreign")]
    t = engine_refusal_text(_scope(), String("plan"), no_colon)
    assert_false(Bool(engine_refusal(_scope(), String("plan"), t)), "a line with no reason")


def main() raises:
    test_a_refusal_of_several_nodes()
    test_what_is_not_a_refusal()
