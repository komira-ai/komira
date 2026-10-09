# =============================================================================
# PLAN_EXCHANGE: the tag id it takes, and the node round-tripping through the
# IR (factory, copy, `_copy_plan`, render, schema re-derivation, integrity).
# =============================================================================
#
# THE TAG PIN. The exchange takes id 18, not 16: ids 16 and 17 are retired
# (their wire numbers 17 and 18 are reserved forever), and a reused id would
# decode old bytes as the wrong node. The pin asserts the id, the count, the
# retired pair, and that no two declared `PLAN_*` constants share an id or a
# name. Mutants: `PLAN_EXCHANGE = 16` (collides with a retired id) and
# `PLAN_EXCHANGE = 15` (collides with PLAN_CAST_TO_VARCHAR) each go red here.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    PLAN_EXCHANGE,
    PLAN_TAG_COUNT,
    plan_tag_name,
    plan_tag_is_retired,
    EXCHANGE_KIND_GATHER,
    EXCHANGE_KIND_BROADCAST,
    EXCHANGE_KIND_HASH,
    EXCHANGE_KIND_RANGE,
    EXCHANGE_KEY_ENCODING_UNSET,
)
from komira_plan_ir.plan_helpers import _copy_plan, validate_plan_integrity
from komira_plan_ir.schema_propagation import infer_schema


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _hash_exchange(partitions: Int, adaptive: Bool) raises -> LogicalPlan:
    var keys: List[String] = ["k"]
    return LogicalPlan.exchange(
        _scan(), EXCHANGE_KIND_HASH, keys^, partitions=partitions,
        adaptive_allowed=adaptive,
    )


def _range_exchange(descending: Bool) raises -> LogicalPlan:
    var ok: List[String] = ["v"]
    var desc: List[Bool] = [descending]
    return LogicalPlan.exchange(
        _scan(), EXCHANGE_KIND_RANGE, order_keys=ok^, descending=desc^
    )


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


def _refusal(var child: LogicalPlan, kind: UInt8, var keys: List[String], var order_keys: List[String], var descending: List[Bool], partitions: Int) -> String:
    try:
        _ = LogicalPlan.exchange(
            child^, kind, keys^, order_keys=order_keys^, descending=descending^,
            partitions=partitions,
        )
    except e:
        return String(e)
    return String("")


# =============================================================================
# The tag space
# =============================================================================


def test_the_exchange_takes_tag_18_and_the_count_is_19() raises:
    """Catches the exchange placed on a retired id, and a count that was not
    moved with it (a histogram sized from the count would index past its
    end on tag 18)."""
    assert_equal(Int(PLAN_EXCHANGE), 18)
    assert_equal(PLAN_TAG_COUNT, 19)
    assert_true(plan_tag_is_retired(UInt8(16)))
    assert_true(plan_tag_is_retired(UInt8(17)))
    assert_false(plan_tag_is_retired(PLAN_EXCHANGE))
    assert_false(plan_tag_is_retired(PLAN_CAST_TO_VARCHAR))
    assert_equal(plan_tag_name(PLAN_EXCHANGE), "Exchange")
    assert_equal(plan_tag_name(UInt8(16)), "tag#16")
    assert_equal(plan_tag_name(UInt8(17)), "tag#17")


def test_no_two_plan_tags_share_an_id_or_a_name() raises:
    """Every declared `PLAN_*` constant, listed by hand: the ids are pairwise
    distinct, none is retired, each is below the count, and each has its own
    name (none falls back to `tag#<n>`). The highest is `PLAN_TAG_COUNT - 1`,
    and every live id below the count is one of them. Catches a collision of
    the new tag with any existing one, a tag with no name arm, and a count
    with a gap at its top."""
    var tags: List[UInt8] = [
        PLAN_SCAN, PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_JOIN,
        PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN, PLAN_PARTITION_BY,
        PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN, PLAN_UNION, PLAN_VIEW_REF,
        PLAN_CSE_REF, PLAN_CAST_TO_VARCHAR, PLAN_EXCHANGE,
    ]
    var top = 0
    for i in range(len(tags)):
        assert_false(plan_tag_is_retired(tags[i]), String(Int(tags[i])))
        assert_true(Int(tags[i]) < PLAN_TAG_COUNT, String(Int(tags[i])))
        if Int(tags[i]) > top:
            top = Int(tags[i])
        assert_false(
            plan_tag_name(tags[i]).startswith("tag#"), plan_tag_name(tags[i])
        )
        for k in range(i + 1, len(tags)):
            assert_true(tags[i] != tags[k], "id " + String(Int(tags[i])))
            assert_true(
                plan_tag_name(tags[i]) != plan_tag_name(tags[k]),
                plan_tag_name(tags[i]),
            )
    assert_equal(top, PLAN_TAG_COUNT - 1)
    var live = 0
    for t in range(PLAN_TAG_COUNT):
        if not plan_tag_is_retired(UInt8(t)):
            live += 1
    assert_equal(live, len(tags))


# =============================================================================
# The node
# =============================================================================


def test_the_factory_stores_every_field_and_keeps_the_child_schema() raises:
    """Catches a field not stored, and a schema that is not the child's."""
    var e = _hash_exchange(0, True)
    assert_true(e.is_exchange())
    assert_equal(Int(e.tag), Int(PLAN_EXCHANGE))
    ref d = e.exchange_data_ref()
    assert_equal(Int(d.kind), Int(EXCHANGE_KIND_HASH))
    assert_equal(len(d.keys), 1)
    assert_equal(d.keys[0], "k")
    assert_equal(Int(d.key_encoding), Int(EXCHANGE_KEY_ENCODING_UNSET))
    assert_equal(d.partitions, 0)
    assert_true(d.adaptive_allowed)
    assert_equal(Int(d.child[].tag), Int(PLAN_SCAN))
    assert_equal(e.output_schema.num_columns(), 2)
    assert_equal(e.output_schema.field_name(0), "k")
    assert_equal(e.output_schema.field_name(1), "v")
    var inferred = infer_schema(e)
    assert_equal(inferred.num_columns(), 2)
    assert_equal(inferred.field_name(1), "v")


def test_a_range_exchange_derives_nulls_first_from_descending() raises:
    var e = _range_exchange(True)
    ref d = e.exchange_data_ref()
    assert_equal(len(d.order_keys), 1)
    assert_equal(len(d.nulls_first), 1)
    assert_true(d.descending[0])


def _assert_same_exchange(q: LogicalPlan, p: LogicalPlan) raises:
    assert_true(q.is_exchange())
    ref a = q.exchange_data_ref()
    ref b = p.exchange_data_ref()
    assert_equal(Int(a.kind), Int(b.kind))
    assert_equal(len(a.keys), len(b.keys))
    for i in range(len(a.keys)):
        assert_equal(a.keys[i], b.keys[i])
    assert_equal(Int(a.key_encoding), Int(b.key_encoding))
    assert_equal(len(a.order_keys), len(b.order_keys))
    for i in range(len(a.order_keys)):
        assert_equal(a.order_keys[i], b.order_keys[i])
        assert_equal(a.descending[i], b.descending[i])
        assert_equal(a.nulls_first[i], b.nulls_first[i])
    assert_equal(len(a.descending), len(b.descending))
    assert_equal(len(a.nulls_first), len(b.nulls_first))
    assert_equal(a.partitions, b.partitions)
    assert_equal(a.adaptive_allowed, b.adaptive_allowed)
    assert_equal(_render(q), _render(p))
    assert_equal(q.structural_hash(), p.structural_hash())


def _assert_both_copies_keep(p: LogicalPlan) raises:
    _assert_same_exchange(p.copy(), p)
    _assert_same_exchange(_copy_plan(p), p)
    assert_true(validate_plan_integrity(p))


def test_every_field_survives_both_copies() raises:
    """`copy()` and `_copy_plan` return an exchange with every field equal,
    the same render and the same hash. Catches `_copy_plan` with no exchange
    arm (it raises) and a `copy()` that drops the payload (a shell node)."""
    _assert_both_copies_keep(_hash_exchange(8, True))
    _assert_both_copies_keep(_range_exchange(False))
    _assert_both_copies_keep(
        LogicalPlan.exchange(_scan(), EXCHANGE_KIND_BROADCAST, partitions=3)
    )


def test_every_field_enters_plan_identity() raises:
    """Exchanges differing in one field each hash apart: kind, keys,
    partitions, adaptive, the ordering's direction. Catches a render that
    omits any of them (two different redistributions would share a compiled
    plan)."""
    var keys_v: List[String] = ["v"]
    var hashes = List[UInt64]()
    hashes.append(_hash_exchange(0, False).structural_hash())
    hashes.append(_hash_exchange(4, False).structural_hash())
    hashes.append(_hash_exchange(0, True).structural_hash())
    hashes.append(
        LogicalPlan.exchange(_scan(), EXCHANGE_KIND_HASH, keys_v^).structural_hash()
    )
    hashes.append(LogicalPlan.exchange(_scan(), EXCHANGE_KIND_GATHER).structural_hash())
    hashes.append(LogicalPlan.exchange(_scan(), EXCHANGE_KIND_BROADCAST).structural_hash())
    hashes.append(_range_exchange(False).structural_hash())
    hashes.append(_range_exchange(True).structural_hash())
    hashes.append(_scan().structural_hash())
    for a in range(len(hashes)):
        for b in range(a + 1, len(hashes)):
            assert_true(hashes[a] != hashes[b], String(a) + " vs " + String(b))
    var text = _render(_hash_exchange(4, True))
    assert_true(
        String(text.split("\n")[0])
        == 'Exchange(kind=HASH, keys=["k"], key_encoding=255, order=[]/[]/[], partitions=4, adaptive)',
        text,
    )


def test_the_factory_refuses_every_malformed_shape() raises:
    """Catches each guard dropped: a kind outside the space, HASH without
    keys, keys on a non-HASH exchange, RANGE without order keys, a key the
    child does not have, a direction list of the wrong length, negative
    partitions."""
    var none = List[String]()
    var k: List[String] = ["k"]
    var bad: List[String] = ["nope"]
    var nd = List[Bool]()
    var one: List[Bool] = [False]
    assert_true("kind 9" in _refusal(_scan(), UInt8(9), none.copy(), none.copy(), nd.copy(), 0))
    assert_true("needs keys" in _refusal(_scan(), EXCHANGE_KIND_HASH, none.copy(), none.copy(), nd.copy(), 0))
    assert_true("only a HASH" in _refusal(_scan(), EXCHANGE_KIND_GATHER, k.copy(), none.copy(), nd.copy(), 0))
    assert_true("needs order keys" in _refusal(_scan(), EXCHANGE_KIND_RANGE, none.copy(), none.copy(), nd.copy(), 0))
    assert_true("'nope' is not a column" in _refusal(_scan(), EXCHANGE_KIND_HASH, bad.copy(), none.copy(), nd.copy(), 0))
    assert_true("'nope' is not a column" in _refusal(_scan(), EXCHANGE_KIND_RANGE, none.copy(), bad.copy(), one.copy(), 0))
    assert_true("descending flags" in _refusal(_scan(), EXCHANGE_KIND_RANGE, none.copy(), k.copy(), nd.copy(), 0))
    assert_true("negative" in _refusal(_scan(), EXCHANGE_KIND_GATHER, none.copy(), none.copy(), nd.copy(), -1))
    # And a well-formed one is not refused.
    assert_equal(_refusal(_scan(), EXCHANGE_KIND_GATHER, none.copy(), none.copy(), nd.copy(), 0), "")


def test_integrity_refuses_an_exchange_with_no_payload() raises:
    """Catches `validate_plan_integrity` with no exchange arm (it would report
    'unknown tag' for a well-formed exchange) or one that skips the payload
    check."""
    assert_true(validate_plan_integrity(_hash_exchange(0, False)))
    var shell = LogicalPlan(PLAN_EXCHANGE, _schema())
    assert_false(validate_plan_integrity(shell))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
