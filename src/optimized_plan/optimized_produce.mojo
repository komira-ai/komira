# =============================================================================
# optimized_produce.mojo: the producer's half (docs/design/optimized_plan.md
# §4.1, §7.1).
# =============================================================================
#
# `produce_optimized_plan` serializes a plan the caller has already optimized.
# It does not call the optimizer (the package's `closure_excludes` keeps the
# optimizer out of its closure) and decides nothing about the plan: it writes
# what the plan records.
#
#   body      `OptimizedPlanBody{plan}` in canonical form, with `plan` from
#             `optimized_plan_to_wire` (plan_wire's OPTIMIZED encoder, which
#             decodes its own output before returning).
#   needs     `DeclaredNeeds` with `unbounded` as `OPTIMIZED_BODY_UNBOUNDED_V1`
#             and no udfs, runtimes or data scopes.
#   versions  `format_version` is `OPTIMIZED_PLAN_FORMAT_VERSION_1` and the
#             stamp's `optimizer_contract_version` is
#             `OPTIMIZED_PLAN_CONTRACT_VERSION_1`, both from the header
#             library. The caller's stamp supplies the build, config digest and
#             kind; its contract version is overwritten with the one this
#             build writes.
#   result    `OptimizedPlan` in canonical form, so equal inputs give equal
#             bytes.
#
# The plan carries no scan statistic: `ScanData.row_count` and `table_stats`
# are refused by plan_wire (OPTIMIZED_FIELD_UNSUPPORTED), and so is a join with
# no recorded build side (OPTIMIZED_JOIN_BUILD_SIDE_MISSING). plan_ir has no
# operation that rewrites the scans of a whole tree, so the producer does not
# strip statistics for the caller; the plan comes in without them.
# =============================================================================

from optimized_plan_header import (
    OPTIMIZED_PLAN_CONTRACT_VERSION_1,
    OPTIMIZED_PLAN_FORMAT_VERSION_1,
)
from plan_ir.logical_plan import LogicalPlan
from plan_ir.udf_ref import UdfRef
from plan_proto.optimized_plan import (
    DeclaredNeeds,
    OptimizedPlan,
    OptimizedPlanBody,
    ProducerStamp,
)
from plan_proto.plan import WireWriteTarget
from plan_wire import optimized_plan_to_wire

from .canonical_encoder import encode_canonical
from .optimized_body import OPTIMIZED_BODY_UNBOUNDED_V1
from .optimized_digest import optimized_plan_digest


def produce_optimized_plan(
    plan: LogicalPlan,
    var stamp: ProducerStamp,
    write_target: Optional[WireWriteTarget] = None,
) raises -> List[UInt8]:
    """The canonical `OptimizedPlan` bytes of an optimized `plan`, stamped by
    `stamp` (module header). the producer sets
    `stamp.optimizer_contract_version` to the version this build writes; a
    write target is bound into the digest."""
    stamp.optimizer_contract_version = OPTIMIZED_PLAN_CONTRACT_VERSION_1
    var body = encode_canonical(
        OptimizedPlanBody(
            Optional(optimized_plan_to_wire(plan, List[UdfRef]())),
            [],
            [],
            [],
        )
    )
    var header = OptimizedPlan(
        OPTIMIZED_PLAN_FORMAT_VERSION_1,
        Optional(stamp^),
        List[UInt8](),
        List[UInt8](),
        Optional(DeclaredNeeds([], [], OPTIMIZED_BODY_UNBOUNDED_V1, [])),
        write_target.copy(),
        None,
        List[UInt8](),
    )
    header.plan_digest = optimized_plan_digest(body, header)
    header.body = body^
    return encode_canonical(header)
