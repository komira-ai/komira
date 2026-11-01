# =============================================================================
# komira_broker_coordinator/tests/test_broker_coordinator_parse_node_id.mojo
#   _parse_node_id: a node_id that is not a Kafka broker.id is NO_LEADER_NODE_ID.
# =============================================================================
#
# A Kafka broker.id is an Int32 in [0, 2147483647]. `_parse_node_id` feeds the
# routing map (nodes[].node_id and leaders[].leader_node_id), so a node_id that
# does not name such an id must map to NO_LEADER_NODE_ID (-1) and must never
# alias another broker's id or the no-leader sentinel itself.
#
# Defects this catches:
#   - an id above 2147483647 narrowed with Int32(acc) wraps onto a real id
#     ("4294967297" -> 1, "2147483648" -> -2147483648);
#   - an id of 20+ digits overflows the Int accumulator before the narrowing
#     ("99999999999999999999" -> 1661992959);
#   - a signed id parses as a negative broker id ("-12" -> -12, "-0" -> 0),
#     and "-1" collides with the sentinel the map uses for "no leader".
# =============================================================================

from std.testing import assert_equal

from komira_broker_coordinator import NO_LEADER_NODE_ID
from komira_broker_coordinator.broker_heartbeat_handler import _parse_node_id


def _check(s: String, want: Int32, label: String) raises:
    assert_equal(_parse_node_id(s), want, label + " (" + s + ")")


def test_in_range_ids_parse() raises:
    _check(String("0"), Int32(0), "zero")
    _check(String("7"), Int32(7), "one digit")
    _check(String("0042"), Int32(42), "leading zeros")
    _check(String("2147483647"), Int32(2147483647), "Int32 maximum")
    _check(
        String("0000000000000000000002147483647"),
        Int32(2147483647),
        "Int32 maximum behind 21 zeros",
    )


def test_ids_above_int32_max_are_no_leader() raises:
    _check(String("2147483648"), NO_LEADER_NODE_ID, "Int32 maximum + 1")
    _check(String("4294967297"), NO_LEADER_NODE_ID, "2^32 + 1 (wraps to 1)")
    _check(String("21474836470"), NO_LEADER_NODE_ID, "maximum times ten")
    _check(
        String("99999999999999999999"),
        NO_LEADER_NODE_ID,
        "20 digits (overflows Int)",
    )
    _check(
        String("18446744073709551617"),
        NO_LEADER_NODE_ID,
        "2^64 + 1 (wraps Int to 1)",
    )


def test_signed_ids_are_no_leader() raises:
    _check(String("-1"), NO_LEADER_NODE_ID, "minus one")
    _check(String("-12"), NO_LEADER_NODE_ID, "negative")
    _check(String("-0"), NO_LEADER_NODE_ID, "minus zero")
    _check(String("-2147483648"), NO_LEADER_NODE_ID, "Int32 minimum")
    _check(String("-"), NO_LEADER_NODE_ID, "lone minus")
    _check(String("+5"), NO_LEADER_NODE_ID, "plus sign")


def test_non_numeric_ids_are_no_leader() raises:
    _check(String(""), NO_LEADER_NODE_ID, "empty")
    _check(String("1a"), NO_LEADER_NODE_ID, "trailing letter")
    _check(String("1 "), NO_LEADER_NODE_ID, "trailing space")


def main() raises:
    test_in_range_ids_parse()
    test_ids_above_int32_max_are_no_leader()
    test_signed_ids_are_no_leader()
    test_non_numeric_ids_are_no_leader()
