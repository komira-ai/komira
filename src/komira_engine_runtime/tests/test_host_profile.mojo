# =============================================================================
# test_host_profile -- the host profile and the morsel size lowering records
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * the constructor refuses a thread count or budget below 1 and unknown
#     spill bits (a profile that would size work for zero workers);
#   * a breaker's spill tiers are the intersection of what it declared and
#     what the host offers (a breaker spilling to a tier the host lacks);
#   * the reference profile is made of constants (a lowered-plan comparison
#     that differs by machine);
#   * detection honours the thread and memory flags and derives them when 0;
#   * the tier rule maps each segment shape to its tier, first match wins
#     (a probe segment sized as an aggregate);
#   * a `RunContext` conformer hands a driver its host profile and worker
#     count through the trait (the trait compiles with a conformer);
#   * `record_segment_morsel_rows` writes the policy's value into the segment,
#     and lowering twice under one profile records the same value.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_engine_runtime.hardware import HardwareProfile
from komira_engine_runtime.host_profile import (
    HostProfile,
    SPILL_TIER_ALL,
    SPILL_TIER_LOCAL_DISK,
    SPILL_TIER_NONE,
    SPILL_TIER_OBJECT_STORE,
    detect_host_profile,
    reference_host_profile,
)
from komira_engine_runtime.run_context import RunContext
from komira_engine_runtime.morsel_sizing_policy import (
    MORSEL_TIER_AGG,
    MORSEL_TIER_BULK_SCAN,
    MORSEL_TIER_DEFAULT,
    MORSEL_TIER_JOIN_PROBE,
    MorselSizingPolicy,
    lower_segment_morsel_rows,
    record_segment_morsel_rows,
    segment_morsel_tier,
)
from komira_physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    OP_FILTER,
    OP_JOIN_PROBE,
    OP_LIMIT,
    SINK_AGG,
    SINK_COLLECT,
    SINK_JOIN_PROBE,
    SINK_ORIENT_COLUMNAR,
    SINK_SORT,
    SOURCE_BATCH,
    SOURCE_PARQUET,
    SegmentDescPod,
    SourceSpecPod,
)


def _i64_schema(cols: Int) -> Schema:
    var sb = SchemaBuilder()
    for i in range(cols):
        sb.add_field(Field("c" + String(i), ArrowType.INT64, False))
    return sb.build()


def _seg(source_kind: UInt8, var op_tags: List[UInt8], sink_kind: UInt8) -> SegmentDescPod:
    var ops = Slab[MorselOp]()
    for i in range(len(op_tags)):
        ops.append(MorselOp(tag=op_tags[i]))
    return SegmentDescPod(
        seg_id=0,
        source_kind=source_kind,
        source_spec=SourceSpecPod.batch(-1),
        ops=ops^,
        sink_kind=sink_kind,
        sink_key_dtype=KEY_DTYPE_NONE,
        sink_orientation=SINK_ORIENT_COLUMNAR,
        sink_param_id=0,
        sink_state_id=0,
        deps=List[Int](),
        edge_tags=List[UInt8](),
    )


def _raises_invalid(threads: Int, budget: Int, tiers: UInt8) -> Bool:
    try:
        _ = HostProfile(
            "b", HardwareProfile.defaults(), threads, budget, tiers
        )
    except e:
        return String("HOST_PROFILE_INVALID") in String(e)
    return False


def test_constructor_refuses_invalid_values() raises:
    assert_true(_raises_invalid(0, 1024, SPILL_TIER_NONE))
    assert_true(_raises_invalid(4, 0, SPILL_TIER_NONE))
    assert_true(_raises_invalid(4, 1024, UInt8(4)))
    assert_false(_raises_invalid(1, 1, SPILL_TIER_ALL))


def test_spill_tiers_are_the_intersection() raises:
    var host = HostProfile(
        "b", HardwareProfile.defaults(), 4, 1 << 20, SPILL_TIER_LOCAL_DISK
    )
    assert_equal(host.spill_tiers_for(SPILL_TIER_ALL), SPILL_TIER_LOCAL_DISK)
    assert_equal(host.spill_tiers_for(SPILL_TIER_OBJECT_STORE), SPILL_TIER_NONE)
    assert_true(host.may_spill(SPILL_TIER_ALL))
    assert_false(host.may_spill(SPILL_TIER_OBJECT_STORE))
    assert_false(host.may_spill(SPILL_TIER_NONE))


def test_reference_profile_is_constant() raises:
    var a = reference_host_profile("build-1")
    var b = reference_host_profile("build-1")
    assert_equal(String(a), String(b))
    assert_equal(a.engine_build, "build-1")
    assert_equal(a.thread_count, 8)
    assert_equal(a.hardware.effective_e_core_l2_per_worker(), 1024 * 1024)
    assert_equal(a.spill_tiers, SPILL_TIER_LOCAL_DISK)
    assert_equal(a.memory_budget_bytes, a.hardware.default_memory_budget())


def test_detect_honours_flags_and_derives_zero() raises:
    var fixed = detect_host_profile("b", 3, 12345, SPILL_TIER_ALL)
    assert_equal(fixed.thread_count, 3)
    assert_equal(fixed.memory_budget_bytes, 12345)
    assert_equal(fixed.spill_tiers, SPILL_TIER_ALL)
    var derived = detect_host_profile("b")
    assert_equal(derived.thread_count, derived.hardware.compute_threads())
    assert_true(derived.thread_count >= 1)
    assert_true(derived.memory_budget_bytes >= 1)


def test_segment_tier_rule() raises:
    # 1. a join probe operator, or a join probe sink -> JOIN_PROBE, even into AGG
    assert_equal(
        segment_morsel_tier(_seg(SOURCE_BATCH, [OP_JOIN_PROBE], SINK_AGG)),
        MORSEL_TIER_JOIN_PROBE,
    )
    assert_equal(
        segment_morsel_tier(_seg(SOURCE_PARQUET, List[UInt8](), SINK_JOIN_PROBE)),
        MORSEL_TIER_JOIN_PROBE,
    )
    # 2. an aggregate sink -> AGG
    assert_equal(
        segment_morsel_tier(_seg(SOURCE_PARQUET, [OP_FILTER], SINK_AGG)),
        MORSEL_TIER_AGG,
    )
    # 3. a Parquet scan that only collects -> BULK_SCAN (a limit does not filter)
    assert_equal(
        segment_morsel_tier(_seg(SOURCE_PARQUET, [OP_LIMIT], SINK_COLLECT)),
        MORSEL_TIER_BULK_SCAN,
    )
    # 4. a filter, a non-Parquet source, or another sink -> DEFAULT
    assert_equal(
        segment_morsel_tier(_seg(SOURCE_PARQUET, [OP_FILTER], SINK_COLLECT)),
        MORSEL_TIER_DEFAULT,
    )
    assert_equal(
        segment_morsel_tier(_seg(SOURCE_BATCH, List[UInt8](), SINK_COLLECT)),
        MORSEL_TIER_DEFAULT,
    )
    assert_equal(
        segment_morsel_tier(_seg(SOURCE_PARQUET, List[UInt8](), SINK_SORT)),
        MORSEL_TIER_DEFAULT,
    )


def test_record_writes_the_policy_value() raises:
    var host = reference_host_profile("b")
    var schema = _i64_schema(8)  # 64 B/row
    var seg = _seg(SOURCE_PARQUET, List[UInt8](), SINK_COLLECT)
    assert_equal(seg.morsel_rows, 0)  # not lowered yet
    record_segment_morsel_rows(host, seg, schema)
    # Reference L2 share 1 MiB, half for state -> 512 KiB / 64 B = 8192 rows,
    # x8 for BULK_SCAN = 65536.
    assert_equal(seg.morsel_rows, 65536)
    var policy = MorselSizingPolicy.for_host(host)
    assert_equal(
        seg.morsel_rows, policy.morsel_rows(schema, MORSEL_TIER_BULK_SCAN)
    )
    var agg = _seg(SOURCE_PARQUET, List[UInt8](), SINK_AGG)
    record_segment_morsel_rows(host, agg, schema)
    assert_equal(agg.morsel_rows, 8192)


def test_lowering_is_deterministic_under_one_profile() raises:
    var schema = _i64_schema(3)
    var seg = _seg(SOURCE_BATCH, [OP_FILTER], SINK_COLLECT)
    var a = lower_segment_morsel_rows(reference_host_profile("b"), seg, schema)
    var b = lower_segment_morsel_rows(reference_host_profile("b"), seg, schema)
    assert_equal(a, b)
    assert_true(a > 0)


struct _FixedRun(RunContext):
    var host: HostProfile

    def __init__(out self, var host: HostProfile):
        self.host = host^

    def host_profile(self) -> HostProfile:
        return self.host.copy()

    def num_workers(self) -> Int:
        return self.host.thread_count


def _lowered_rows[C: RunContext](ctx: C, segment: SegmentDescPod, schema: Schema) -> Int:
    return lower_segment_morsel_rows(ctx.host_profile(), segment, schema)


def test_run_context_hands_out_its_host_profile() raises:
    var ctx = _FixedRun(reference_host_profile("b"))
    assert_equal(ctx.num_workers(), 8)
    var schema = _i64_schema(8)
    var seg = _seg(SOURCE_PARQUET, List[UInt8](), SINK_AGG)
    assert_equal(_lowered_rows(ctx, seg, schema), 8192)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
