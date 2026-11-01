# =============================================================================
# test_run_context -- the RunContext trait hands a driver its host profile
# =============================================================================
#
# What the test proves, and the defect it catches: a `RunContext` conformer
# hands a driver its host profile and worker count through the trait, and
# lowering under the profile it hands out records the profile's morsel size (a
# trait whose methods a conformer cannot satisfy, or a driver that lowered
# under a profile other than the context's).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_engine_runtime.run_context import RunContext
from komira_host_profile.host_profile import HostProfile, reference_host_profile
from komira_host_profile.morsel_sizing_policy import lower_segment_morsel_rows
from komira_physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    SINK_AGG,
    SINK_ORIENT_COLUMNAR,
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
