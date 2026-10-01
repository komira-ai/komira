# =============================================================================
# THE SEAM DEMONSTRATION — a plan scans a source defined OUTSIDE komira_core.
# =============================================================================
#
# A plan source defined outside komira_core must be a first-class plan source.
#
# ---------------------------------------------------------------------------
# WHAT IS BEING SHOWN, AND WHY THIS PARTICULAR SOURCE
# ---------------------------------------------------------------------------
#
# The source under test is `komira_broker.broker_scan_binding` — chosen
# because a broker source is the hard case:
#
#   * adding a broker arm to the closed `SourceVariant` union in komira_core
#     would force `komira_core -> komira_broker -> ...`, INVERTING THE BUILD
#     DAG;
#   * `ConsumeCore` is Movable-only, so the plan needs a Copyable backend
#     HANDLE (a cheap identity token the plan builder copies, the heavy
#     network substrate constructed at execute time) — see consumer_source.
#
# `komira_broker` depends on `komira_core`. `komira_core` does not depend on
# `komira_broker`. The behavioural form of that claim is
# `test_core_ships_knowing_nothing_about_this_kind` below.
#
# ---------------------------------------------------------------------------
# THE BOUNDARY, STATED SO THIS IS NOT OVERREAD
# ---------------------------------------------------------------------------
#
# SHOWN HERE: a plan rooted at an out-of-core source can be built, typed,
# schema-checked, pushdown-queried, EXPLAIN-rendered, cloned, cache-keyed, and
# resolved against a registry owned by the source's own package.
#
# NOT SHOWN HERE: pulling morsels. That needs a morsel resolver for the kind
# in `komira_morsel`.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
    assert_raises,
)

from komira_core.arrow import ArrowType, Field, Schema, SchemaBuilder
from komira_core.plan.expr import Expr, ScalarValue, BIN_EQ, BIN_GE, BIN_AND, BIN_OR
from komira_core.plan.logical_plan import (
    LogicalPlan,
    SOURCE_BINDING,
    SOURCE_PARQUET,
)
from komira_core.plan.logical_plan_variants import SOURCE_KIND_COLUMNAR
from komira_core.source.scan_binding import (
    ScanBinding,
    SNAPSHOT_LIVE,
    SCAN_HANDLE_UNBOUND,
)
from komira_core.source.scan_kind_registry import ScanKindRegistry
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import check_binding, resolve_for_execution
from komira_core.source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_BINDING,
)

# ⚠ THE IMPORT THAT IS THE WHOLE POINT: a test that reaches a plan reaches
# ACROSS a package boundary for its source. Nothing under `komira_core/`
# names `komira_broker`.
from komira_broker.broker_scan_binding import (
    BrokerScanResolver,
    BROKER_SCAN_KIND_NAME,
    broker_scan_binding,
    broker_scan_descriptor,
    broker_scan_kind_id,
)


def _events_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("offset", ArrowType.INT64, nullable=False))
    sb.add_field(Field("payload", ArrowType.STRING, nullable=True))
    return sb.build()


def _binding() -> ScanBinding:
    return broker_scan_binding(
        String("orders"), Int64(3), Int64(1000), _events_schema()
    )


def _plan() raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_binding()), _events_schema()
    )


# =============================================================================
# 1. Core ships knowing nothing about this kind.
# =============================================================================


def test_core_ships_knowing_nothing_about_this_kind() raises:
    """The behavioural form of "no komira_core edit was needed".

    A freshly constructed core registry does not describe the broker kind. It
    learns of it ONLY when the broker's own package hands over a descriptor —
    at which point it can plan the scan without ever naming a broker type.
    """
    var reg = ScanKindRegistry()
    assert_false(reg.describes(broker_scan_kind_id()))
    assert_equal(reg.num_kinds(), 0)

    reg.register(broker_scan_descriptor())
    assert_true(reg.describes(broker_scan_kind_id()))
    assert_equal(reg.descriptor(broker_scan_kind_id()).kind_name, BROKER_SCAN_KIND_NAME)


def test_kind_id_needs_no_central_allocation_table() raises:
    """`kind_id` is the FNV-1a/32 hash of a reverse-DNS name. There is no table
    in core to add a row to — which is exactly why claiming a kind costs no
    core edit. Cross-checked against an independent Python reference."""
    assert_equal(broker_scan_kind_id(), UInt32(2705777722))


def test_registry_validates_the_broker_binding() raises:
    var reg = ScanKindRegistry()
    reg.register(broker_scan_descriptor())
    # Declared orientation, snapshot policy and required params all agree.
    reg.validate(_binding())


def test_missing_required_param_fails_at_plan_build_naming_the_key() raises:
    """The stated mitigation for stringly-typed param keys. The broker declares
    `topic` and `partition` required; a binding without one fails HERE, naming
    it, rather than producing a wrong answer at execute time."""
    var reg = ScanKindRegistry()
    reg.register(broker_scan_descriptor())
    var stripped = broker_scan_binding(
        String("orders"), Int64(3), Int64(1000), _events_schema()
    )
    # Rebuild without `partition` by constructing the binding's params afresh
    # through the public surface: drop the map entirely.
    var bare = ScanBinding(
        kind_id=stripped.kind_id,
        kind_name=String(stripped.kind_name),
        name=String(stripped.name),
        params=ScanParams(),
        schema=stripped.schema.copy(),
        fingerprint=stripped.fingerprint,
        structural_id=stripped.structural_id,
        gate=stripped.pushdown_gate.copy(),
        snapshot_policy=stripped.snapshot_policy,
        orientation=stripped.orientation,
    )
    with assert_raises(contains="partition"):
        reg.validate(bare)


# =============================================================================
# 2. A plan can scan it.
# =============================================================================


def test_a_plan_can_be_rooted_at_the_out_of_core_source() raises:
    """THE ACCEPTANCE CRITERION. A broker arm in `SourceVariant` would invert the build DAG; this shape
    would invert the build DAG. It does not: the plan carries DATA, and the
    concrete broker types stay in `komira_broker`."""
    var plan = _plan()
    assert_true(Bool(plan._scan))
    ref sd = plan._scan.value()[]

    assert_equal(sd.source.tag, SOURCE_VARIANT_BINDING)
    # `SOURCE_BINDING` is the honest answer: "not one of the legacy enum's
    # kinds — consult binding_ref().kind_id". Critically it is NOT
    # SOURCE_PARQUET, which is what six optimizer sites key on.
    assert_equal(sd.source_type, SOURCE_BINDING)
    assert_not_equal(sd.source_type, SOURCE_PARQUET)
    assert_equal(sd.source_path, String("orders"))
    assert_equal(sd.source_kind, SOURCE_KIND_COLUMNAR)
    assert_equal(sd.source.binding_ref().kind_id, broker_scan_kind_id())

    # The plan's output schema came from the out-of-core source's schema.
    assert_equal(plan.output_schema.num_columns(), 2)
    assert_equal(plan.output_schema.field_name(0), String("offset"))


def test_plan_reads_the_sources_schema_and_params() raises:
    var plan = _plan()
    ref b = plan._scan.value()[].source.binding_ref()
    assert_equal(b.source_schema().num_columns(), 2)
    assert_equal(b.params.get_str(String("topic")), String("orders"))
    assert_equal(b.params.get_i64(String("partition")), Int64(3))
    assert_equal(b.params.get_i64(String("start_offset")), Int64(1000))


def test_explain_names_a_kind_core_never_registered() raises:
    """EXPLAIN must render a kind core has never heard of. This is the concrete
    reason a readable param map beat an opaque byte blob."""
    var sv = SourceVariant.from_binding(_binding())
    assert_equal(sv.kind_name(), BROKER_SCAN_KIND_NAME)
    assert_equal(
        _binding().render(),
        String(
            "komira.broker.topic(orders, partition=3, start_offset=1000,"
            " topic=orders)"
        ),
    )


def test_pushdown_is_answered_from_bits_with_no_broker_type_reachable() raises:
    """The optimizer asks the plan node whether a predicate is pushable and
    gets an answer, with no concrete source anywhere in the call. The broker
    declared the conjunctive-comparison family with the stat-friendly
    requirement RELAXED — it prunes by offset range but carries no column
    statistics."""
    var sv = SourceVariant.from_binding(_binding())

    assert_true(
        sv.supports_filter_pushdown(
            Expr.binary(
                BIN_GE,
                Expr.col_ref("offset"),
                Expr.literal(ScalarValue.from_int(1000)),
            )
        )
    )
    assert_true(
        sv.supports_filter_pushdown(
            Expr.binary(
                BIN_AND,
                Expr.binary(
                    BIN_GE,
                    Expr.col_ref("offset"),
                    Expr.literal(ScalarValue.from_int(1000)),
                ),
                Expr.binary(
                    BIN_EQ,
                    Expr.col_ref("offset"),
                    Expr.literal(ScalarValue.from_int(7)),
                ),
            )
        )
    )
    # STRING has statistics, and the requirement is relaxed anyway.
    assert_true(
        sv.supports_filter_pushdown(
            Expr.binary(
                BIN_EQ,
                Expr.col_ref("payload"),
                Expr.literal(ScalarValue.from_string("x")),
            )
        )
    )
    # OR is not pushable in any in-tree source, and an off-schema column is not
    # pushable at all — the grammar is enforced by core, not by the broker.
    assert_false(
        sv.supports_filter_pushdown(
            Expr.binary(
                BIN_OR,
                Expr.binary(
                    BIN_EQ,
                    Expr.col_ref("offset"),
                    Expr.literal(ScalarValue.from_int(1)),
                ),
                Expr.binary(
                    BIN_EQ,
                    Expr.col_ref("offset"),
                    Expr.literal(ScalarValue.from_int(2)),
                ),
            )
        )
    )
    assert_false(
        sv.supports_filter_pushdown(
            Expr.binary(
                BIN_EQ, Expr.col_ref("nope"), Expr.literal(ScalarValue.from_int(1))
            )
        )
    )


def test_plan_clone_and_structural_hash_survive() raises:
    """A plan clone is the operation the plan cache depends on, and the
    structural hash is what the plan cache keys on. Both must work for a kind
    core has never heard of."""
    var plan = _plan()
    var c = plan.copy()
    assert_equal(c._scan.value()[].source_type, SOURCE_BINDING)
    assert_equal(c._scan.value()[].source_path, String("orders"))
    assert_equal(
        c._scan.value()[].source.fingerprint(),
        plan._scan.value()[].source.fingerprint(),
    )
    assert_equal(c.structural_hash(), plan.structural_hash())


def test_distinct_topics_and_partitions_do_not_collide() raises:
    """The plan-cache discrimination contract, for an out-of-core kind."""
    var a = broker_scan_binding(String("orders"), Int64(3), Int64(0), _events_schema())
    var b = broker_scan_binding(String("orders"), Int64(4), Int64(0), _events_schema())
    var c = broker_scan_binding(
        String("payments"), Int64(3), Int64(0), _events_schema()
    )
    assert_not_equal(a.fingerprint, b.fingerprint)
    assert_not_equal(a.fingerprint, c.fingerprint)
    assert_not_equal(a.identity_hash(), b.identity_hash())


# =============================================================================
# 3. The plan is DATA — no live substrate rode along.
# =============================================================================


def test_no_live_substrate_is_reachable_from_the_plan() raises:
    """consumer_source calls this "THE COPYABLE WALL": `ConsumeCore`
    is Movable-only because it owns a network-backed store, so a `SourceLike`
    conformance would have forced a `copy()` that duplicates a live network
    handle on every plan-cache copy.

    The binding carries no store, no core, no handle at all — `handle` is
    `SCAN_HANDLE_UNBOUND` until a registry binds it, and the heavy substrate is
    constructed at execute time. That is precisely the resolution
    consumer_source asks for.
    """
    var b = _binding()
    assert_equal(b.handle, SCAN_HANDLE_UNBOUND)
    assert_false(b.is_bound())
    # And the plan clones without touching anything live.
    var c = b.copy()
    assert_equal(c.fingerprint, b.fingerprint)
    assert_equal(c.params.get_str(String("topic")), String("orders"))


# =============================================================================
# 4. Execution-time resolution, by a resolver the BROKER owns.
# =============================================================================


def test_live_offset_is_refreshed_per_execution_without_moving_the_cache_key() raises:
    """The identity/freshness split, on the source that motivates it.

    A broker offset moves. Folding it into identity (what search does with
    `generation` today) is safe and thrashy — every produce changes every
    query's cache key. Baking the value while dropping it from identity is
    cheap and UNSAFE — a replayed cached plan reads an offset retention already
    reclaimed. `SNAPSHOT_LIVE` is neither.
    """
    var cached = _binding()
    assert_equal(cached.snapshot_policy, SNAPSHOT_LIVE)
    assert_equal(cached.snapshot_token, UInt64(0))

    var r1 = BrokerScanResolver(_epoch=UInt64(1), _high_watermark=UInt64(5000))
    var e1 = resolve_for_execution(r1, cached)
    assert_equal(e1.snapshot_token, UInt64(5000))

    # A later execution, after more produces.
    var r2 = BrokerScanResolver(_epoch=UInt64(1), _high_watermark=UInt64(9999))
    var e2 = resolve_for_execution(r2, cached)
    assert_equal(e2.snapshot_token, UInt64(9999))

    # THE CACHED PLAN NEVER MOVED, and neither did the cache key.
    assert_equal(cached.snapshot_token, UInt64(0))
    assert_equal(e1.identity_hash(), cached.identity_hash())
    assert_equal(e2.identity_hash(), cached.identity_hash())


def test_resolver_refuses_a_foreign_kind() raises:
    """A resolver owns exactly the kinds its package registered. Dispatching a
    binding to the wrong one is a named error, not a silent mis-decode."""
    var r = BrokerScanResolver(_epoch=UInt64(1), _high_watermark=UInt64(5000))
    var foreign = _binding().copy()
    foreign.kind_id = UInt32(12345)
    foreign.kind_name = String("someone.elses.kind")
    with assert_raises(contains="refusing to resolve foreign kind"):
        _ = r.resolve_snapshot(foreign)


def test_a_handle_from_a_dead_registry_raises_rather_than_dangling() raises:
    """THE OWNERSHIP RULE, on an out-of-core source. This is the
    honest price of a Copyable binding: `ArcPointer` in the IR was a compile-time
    keep-alive and `handle: Int` is not. The epoch check turns what would be a
    use-after-free into a named assertion."""
    var live = BrokerScanResolver(_epoch=UInt64(2), _high_watermark=UInt64(5000))
    var stale = _binding().with_handle(0, UInt64(1))
    with assert_raises(contains="registry that minted it is gone"):
        check_binding(live, stale)

    var current = _binding().with_handle(0, UInt64(2))
    check_binding(live, current)
    assert_equal(resolve_for_execution(live, current).snapshot_token, UInt64(5000))


# =============================================================================
# 5. THE PLAN-CACHE KEY. `structural_hash` must see the binding, not just its
#    NAME.
# =============================================================================
#
# THE BUG THESE FALSIFY.
#
# `LogicalPlan.structural_hash()` is FNV-1a over the plan's TEXT RENDER. For a
# scan that emits only `path` (= `binding.name`), `type`, `source_kind`,
# projection and filter, the params, the kind_id, the schema, the gate and the
# binding's own `structural_id` all stop at the plan node.
#
# So two DISTINCT out-of-core scans that share a NAME would render the same
# text, hash the same, and collide in `EngineContext`'s factory cache
# (`factory_hash = plan.structural_hash()` -> `PlanCompileCache` keyed on
# `hash_combine(factory_hash, stats_hash)`). Query A's compiled plan would be
# returned for query B. That is a silent wrong answer, not a perf cliff.
#
# ⚠ `SourceVariant.structural_id()` ALONE DOES NOT CLOSE IT: the render must
# actually write the binding's identity for a binding arm, whose
# `source_type` is `SOURCE_BINDING` (not `SOURCE_IN_MEMORY`).


def _binding_with(
    topic: String, partition: Int64, start_offset: Int64
) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(
            broker_scan_binding(
                String(topic), partition, start_offset, _events_schema()
            )
        ),
        _events_schema(),
    )


def _plan_over(var params: ScanParams) raises -> LogicalPlan:
    """A broker binding over CALLER-SUPPLIED params, with every other field
    pinned to what `broker_scan_binding("orders", 3, 1000, ...)` produces."""
    var canonical = broker_scan_binding(
        String("orders"), Int64(3), Int64(1000), _events_schema()
    )
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(
            ScanBinding(
                kind_id=broker_scan_kind_id(),
                kind_name=String(BROKER_SCAN_KIND_NAME),
                name=String("orders"),
                params=params^,
                schema=_events_schema(),
                fingerprint=canonical.fingerprint,
                structural_id=canonical.structural_id,
                gate=canonical.pushdown_gate.copy(),
                snapshot_policy=canonical.snapshot_policy,
                orientation=canonical.orientation,
            )
        ),
        _events_schema(),
    )


def test_same_name_different_params_do_not_share_a_plan_cache_key() raises:
    """THE BLOCKER, minimal. Two broker scans of topic "orders", partitions 3
    and 4. Same `binding.name` => same `ScanData.source_path` => the same
    rendered text under a name-only render => the same `structural_hash`.

    A name-only render makes both plans:
        Scan(path="orders", type=UNKNOWN, source_kind=COLUMNAR)
    """
    var p3 = _binding_with(String("orders"), Int64(3), Int64(0))
    var p4 = _binding_with(String("orders"), Int64(4), Int64(0))

    # The precondition that makes this a COLLISION and not two different plans:
    # the only thing the old render could see is identical.
    assert_equal(
        p3._scan.value()[].source_path, p4._scan.value()[].source_path
    )
    assert_not_equal(
        p3._scan.value()[].source.binding_ref().params.get_i64(String("partition")),
        p4._scan.value()[].source.binding_ref().params.get_i64(String("partition")),
    )

    assert_not_equal(
        p3.structural_hash(),
        p4.structural_hash(),
        "two binding scans differing in params share a plan-compile cache key;"
        " rendered as: " + String(p3),
    )


def test_a_param_the_kind_left_out_of_its_own_fingerprint_still_reaches_the_key() raises:
    """WHY EMITTING `structural_id` ALONE WOULD NOT HAVE BEEN A FIX.

    `fingerprint` and `structural_id` are FIELDS the migrating arm SUPPLIES.
    The broker's supplied value folds (topic, partition) and deliberately not
    `start_offset` (broker_scan_binding.mojo). So two scans differing ONLY in
    `start_offset` carry the SAME `structural_id` — asserted here so the claim
    is checked, not assumed — and a render that emitted `structural_id` would
    still have collided them.

    They must not collide: the compiled plan carries the binding, so returning
    the offset-1000 plan for an offset-9000 query reads the wrong rows.

    This is why the render folds the binding's DERIVED identity
    (`identity_hash()`, which core computes over kind + name + params + schema
    + gate + orientation) ALONGSIDE the supplied `structural_id` — neither
    subsumes the other, and only the derived one is impossible for a kind
    author to forget.
    """
    var lo = _binding_with(String("orders"), Int64(3), Int64(1000))
    var hi = _binding_with(String("orders"), Int64(3), Int64(9000))

    # The kind's own supplied identity does NOT discriminate these.
    assert_equal(
        lo._scan.value()[].source.structural_id(),
        hi._scan.value()[].source.structural_id(),
    )
    assert_equal(
        lo._scan.value()[].source.fingerprint(),
        hi._scan.value()[].source.fingerprint(),
    )
    # Core's derived fold does.
    assert_not_equal(
        lo._scan.value()[].source.binding_ref().identity_hash(),
        hi._scan.value()[].source.binding_ref().identity_hash(),
    )
    assert_not_equal(
        lo.structural_hash(),
        hi.structural_hash(),
        "start_offset never reached the plan-compile cache key",
    )


def test_the_same_logical_binding_hashes_identically_across_two_constructions() raises:
    """CANONICALISATION, the other half. A collision fix that traded a wrong
    answer for a nondeterministic key would be a cache-miss storm.

    Two INDEPENDENT constructions of the same logical binding — params inserted
    in OPPOSITE orders, separate Schema objects, separate Strings — must render
    byte-identically and hash equal. `ScanParams` keeps `_keys` sorted on `put`
    and `render`/`hash_into` walk that sorted order, so insertion order cannot
    reach the key.
    """
    var fwd = ScanParams()
    fwd.put_i64(String("partition"), Int64(3))
    fwd.put_i64(String("start_offset"), Int64(1000))
    fwd.put_str(String("topic"), String("orders"))

    var rev = ScanParams()
    rev.put_str(String("topic"), String("orders"))
    rev.put_i64(String("start_offset"), Int64(1000))
    rev.put_i64(String("partition"), Int64(3))

    var a = _plan_over(fwd^)
    var b = _plan_over(rev^)
    assert_equal(String(a), String(b))
    assert_equal(a.structural_hash(), b.structural_hash())

    # And a LIVE snapshot token, resolved per execution, still may not move the
    # key — the identity/freshness split has to survive reaching the render.
    var cached = _binding()
    var r = BrokerScanResolver(_epoch=UInt64(1), _high_watermark=UInt64(5000))
    var refreshed = resolve_for_execution(r, cached)
    assert_equal(refreshed.snapshot_token, UInt64(5000))
    var cached_plan = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(cached.copy()), _events_schema()
    )
    var refreshed_plan = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(refreshed^), _events_schema()
    )
    assert_equal(cached_plan.structural_hash(), refreshed_plan.structural_hash())


def test_explain_labels_the_binding_scan_and_shows_its_params() raises:
    """EXPLAIN must label the scan and show the binding it is over.

    Without an arm for `SOURCE_BINDING` (8) and `SOURCE_ARROW` (7), both
    would fall to `else` and EXPLAIN would print `type=UNKNOWN` for every
    arrow and every binding scan:

        Scan(path="orders", type=UNKNOWN, source_kind=COLUMNAR)
    """
    var rendered = String(_plan())
    assert_true(
        "type=BINDING" in rendered,
        "EXPLAIN mislabels a binding scan; got: " + rendered,
    )
    assert_false("type=UNKNOWN" in rendered, "got: " + rendered)
    # The params are IN the render — which is what makes the hash see them, and
    # incidentally makes EXPLAIN able to describe a kind this build never
    # registered.
    assert_true(
        "komira.broker.topic(orders, partition=3, start_offset=1000,"
        " topic=orders)" in rendered,
        "binding params missing from EXPLAIN; got: " + rendered,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_core_ships_knowing_nothing_about_this_kind]()
    suite.test[test_kind_id_needs_no_central_allocation_table]()
    suite.test[test_registry_validates_the_broker_binding]()
    suite.test[test_missing_required_param_fails_at_plan_build_naming_the_key]()
    suite.test[test_a_plan_can_be_rooted_at_the_out_of_core_source]()
    suite.test[test_plan_reads_the_sources_schema_and_params]()
    suite.test[test_explain_names_a_kind_core_never_registered]()
    suite.test[test_pushdown_is_answered_from_bits_with_no_broker_type_reachable]()
    suite.test[test_plan_clone_and_structural_hash_survive]()
    suite.test[test_distinct_topics_and_partitions_do_not_collide]()
    suite.test[test_no_live_substrate_is_reachable_from_the_plan]()
    suite.test[test_live_offset_is_refreshed_per_execution_without_moving_the_cache_key]()
    suite.test[test_resolver_refuses_a_foreign_kind]()
    suite.test[test_a_handle_from_a_dead_registry_raises_rather_than_dangling]()
    suite.test[test_same_name_different_params_do_not_share_a_plan_cache_key]()
    suite.test[
        test_a_param_the_kind_left_out_of_its_own_fingerprint_still_reaches_the_key
    ]()
    suite.test[
        test_the_same_logical_binding_hashes_identically_across_two_constructions
    ]()
    suite.test[test_explain_labels_the_binding_scan_and_shows_its_params]()
    suite^.run()
