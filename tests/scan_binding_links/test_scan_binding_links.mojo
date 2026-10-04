# =============================================================================
# test_scan_binding_links.mojo: each scan kind's SHIPPING binding, encoded,
# equals the wire bytes komira_plan_wire froze for it.
# =============================================================================
#
# komira_plan_wire's `test_plan_wire_golden_bytes.mojo` freezes `topic_live`
# and `index_pinned` from bindings it RESTATES out of komira_core primitives:
# the codec may not import a scan kind. So nothing there can notice a kind
# drifting away from the restatement. A changed identity fold, param set or
# canonical order, gate, orientation, schema or appended `__partition` column
# would leave that golden green over bytes the kind no longer emits.
#
# This test is where that drift goes red. It builds each binding with the
# kind's own constructor, encodes it with the real codec (`plan_to_bytes`),
# and requires the checked-in `.hex`, byte for byte:
#
#   komira.broker.topic   `BrokerScanRuntime.build_binding` (komira_broker)
#                         == `topic_live.hex`
#   komira.search.index   `search_scan_binding` (komira_search_scan)
#                         == `index_pinned.hex`
#
# The inputs are the published values the golden test documents next to its
# restatements; changing one here is a fixture change there.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.logical_plan import LogicalPlan
from komira_core.source.scan_binding import ScanBinding
from komira_core.source.scan_params import ScanParams
from komira_core.source.source_variant import SourceVariant

from komira_plan_wire import plan_to_bytes

from komira_broker.broker_core import BrokerTopicConfig, _topic_config_key
from komira_broker.broker_scan_binding import (
    BROKER_PARAM_PARTITIONS,
    BROKER_PARAM_START_OFFSET,
    BROKER_PARAM_TOPIC,
    BROKER_PARTITION_COLUMN,
    BROKER_SCAN_KIND_NAME,
    broker_topic_binding,
)
from komira_broker.broker_scan_kind import BrokerScanRuntime

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_search_scan.search_scan_kind import (
    SEARCH_SCAN_KIND_NAME,
    search_scan_binding,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _CLUSTER = "links"
# Where the goldens are staged: their repository path (BUCK `data`).
comptime _GOLDEN_DIR = "src/komira_plan_wire/tests/fixtures/golden/"
comptime _REGOLD = (
    " If the kind changed on purpose, update its restatement in"
    + " komira_plan_wire's test_plan_wire_golden_bytes.mojo to match and"
    + " regold per that file's HOW TO REGOLD; if not, this diff IS the bug."
)


# =============================================================================
# helpers
# =============================================================================


def _hex(bytes: List[UInt8]) -> String:
    comptime DIGITS = String("0123456789abcdef")
    var out = String("")
    for i in range(len(bytes)):
        out += String(DIGITS[byte=Int(bytes[i] >> 4)])
        out += String(DIGITS[byte=Int(bytes[i] & 0xF)])
    return out^


def _golden_hex(name: String) raises -> String:
    """The golden's hex digits with every whitespace byte dropped. The line
    width of a `.hex` fixture is a review convention, not part of its
    meaning."""
    var path = String(_GOLDEN_DIR) + name + ".hex"
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except e:
        raise Error(
            "scan binding links: golden `"
            + path
            + "` is not staged ("
            + String(e)
            + "); declare it in this package's BUCK `data`"
        )
    var out = String("")
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c == UInt8(ord(" "))
            or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r"))
            or c == UInt8(ord("\t"))
        ):
            continue
        out += chr(Int(c))
    return out^


def _wire_hex(var b: ScanBinding) raises -> String:
    """The binding as a plan's scan leaf, encoded by the real codec."""
    var schema = b.schema.copy()
    return _hex(
        plan_to_bytes(
            LogicalPlan.scan_from_source(SourceVariant.from_binding(b^), schema^)
        )
    )


# =============================================================================
# komira.broker.topic == topic_live
# =============================================================================


def _orders_relation_schema() raises -> Schema:
    """The relation schema the `orders` topic config declares: the golden's
    topic schema minus the `__partition` column the kind appends."""
    var sb = SchemaBuilder()
    sb.add_field(Field("order_id", ArrowType.INT64, False))
    sb.add_field(Field("amount", ArrowType.INT64, True))
    sb.add_field(Field("note", ArrowType.STRING, True))
    return sb.build()


def _orders_params() -> ScanParams:
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), String("orders"))
    p.put_str(String(BROKER_PARAM_PARTITIONS), String("0,3"))
    p.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(1000))
    return p^


def test_broker_build_binding_encodes_to_the_topic_live_golden() raises:
    assert_equal(String(BROKER_SCAN_KIND_NAME), String("komira.broker.topic"))
    var store = _Store()
    var cfg = BrokerTopicConfig(4, List[String](), _orders_relation_schema())
    _ = store.put(
        Path.parse(_topic_config_key(String(_CLUSTER), String("orders"))),
        cfg.encode(),
    )
    var rt = BrokerScanRuntime[_Store](store.clone(), String(_CLUSTER))
    var want = _golden_hex(String("topic_live"))
    assert_true(want.byte_length() > 0, "topic_live.hex is empty")
    assert_equal(
        _wire_hex(rt.build_binding(_orders_params())),
        want,
        "BrokerScanRuntime.build_binding no longer emits the frozen"
        + " topic_live bytes."
        + _REGOLD,
    )
    # The plan-level constructor over the same whole schema (relation, then
    # `__partition`) folds the same identity: `build_binding` adds only the
    # column, never a different fold.
    var whole = SchemaBuilder()
    var rel = _orders_relation_schema()
    for i in range(rel.num_columns()):
        whole.add_field(rel.field_at(i))
    whole.add_field(
        Field(String(BROKER_PARTITION_COLUMN), ArrowType.INT64, nullable=False)
    )
    assert_equal(
        _wire_hex(broker_topic_binding(_orders_params(), whole.build())),
        want,
        "broker_topic_binding over build_binding's schema must encode to the"
        + " same topic_live bytes."
        + _REGOLD,
    )


# =============================================================================
# komira.search.index == index_pinned
# =============================================================================


def test_search_scan_binding_encodes_to_the_index_pinned_golden() raises:
    assert_equal(String(SEARCH_SCAN_KIND_NAME), String("komira.search.index"))
    var want = _golden_hex(String("index_pinned"))
    assert_true(want.byte_length() > 0, "index_pinned.hex is empty")
    var b = search_scan_binding(
        String("docs"),
        String("body"),
        String("error timeout"),
        UInt64(0x5EA2C4),
        generation=Optional(Int64(42)),
    )
    assert_equal(
        _wire_hex(b^),
        want,
        "search_scan_binding no longer emits the frozen index_pinned bytes."
        + _REGOLD,
    )


def test_the_two_goldens_are_different_bytes() raises:
    """A link test over two copies of one file would pass for one kind by
    accident; the two kinds' bytes must differ."""
    assert_true(
        _golden_hex(String("topic_live")) != _golden_hex(String("index_pinned")),
        "topic_live.hex and index_pinned.hex hold the same bytes",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_broker_build_binding_encodes_to_the_topic_live_golden]()
    suite.test[test_search_scan_binding_encodes_to_the_index_pinned_golden]()
    suite.test[test_the_two_goldens_are_different_bytes]()
    suite^.run()
