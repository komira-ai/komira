# =============================================================================
# plan_check -- the checks a plan passes before any segment runs, and the ready set
# =============================================================================
#
# `check_plan` refuses, by name and before the first segment is built, a plan
# the driver cannot run: an IR version other than the one this build reads, a
# segment whose id is not its position, a dependency outside the plan or on the
# segment itself, edge tags that do not match the dependencies one to one, an
# edge tag or an order key without a policy, and a dependency cycle through the
# edges a consumer waits for.
#
# `ready_set` is the scheduler's view of a plan: the segments that have not
# finished and whose waited-for dependencies have, in segment id order.

from komira_physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    SegmentDescPod,
)

from .edge_policy import (
    POLICY_WAIT,
    check_order_key,
    edge_policy,
    edge_tag_name,
)


def ready_set(
    ref descs: List[SegmentDescPod], ref finished: List[Bool]
) raises -> List[Int]:
    """The ids of the segments that may start: not finished, and every
    dependency whose edge policy is `POLICY_WAIT` finished. Ascending."""
    var out = List[Int]()
    for i in range(len(descs)):
        if finished[i]:
            continue
        var ok = True
        for d in range(len(descs[i].deps)):
            if edge_policy(descs[i].edge_tags[d]) == POLICY_WAIT:
                if not finished[descs[i].deps[d]]:
                    ok = False
                    break
        if ok:
            out.append(i)
    return out^


def check_plan(ref descs: List[SegmentDescPod]) raises:
    """Raise unless the driver can run `descs`. See the module header."""
    var n = len(descs)
    for i in range(n):
        ref desc = descs[i]
        var where = String("segment ") + String(i)
        if desc.ir_version != PHYSICAL_PLAN_IR_VERSION:
            raise Error(
                "komira_pipeline_exec: "
                + where
                + " is IR version "
                + String(desc.ir_version)
                + ", this build reads version "
                + String(PHYSICAL_PLAN_IR_VERSION)
            )
        if desc.seg_id != i:
            raise Error(
                "komira_pipeline_exec: "
                + where
                + " has seg_id "
                + String(desc.seg_id)
                + "; a segment's id is its position"
            )
        if len(desc.edge_tags) != len(desc.deps):
            raise Error(
                "komira_pipeline_exec: "
                + where
                + " has "
                + String(len(desc.deps))
                + " dependencies and "
                + String(len(desc.edge_tags))
                + " edge tags"
            )
        for d in range(len(desc.deps)):
            var dep = desc.deps[d]
            if dep < 0 or dep >= n:
                raise Error(
                    "komira_pipeline_exec: "
                    + where
                    + " depends on segment "
                    + String(dep)
                    + ", which is not in the plan"
                )
            if dep == i:
                raise Error(
                    "komira_pipeline_exec: " + where + " depends on itself"
                )
            try:
                _ = edge_policy(desc.edge_tags[d])
            except e:
                raise Error(
                    String(e)
                    + " ("
                    + where
                    + ", edge to segment "
                    + String(dep)
                    + ", "
                    + edge_tag_name(desc.edge_tags[d])
                    + ")"
                )
        try:
            check_order_key(desc.order_key_kind)
        except e:
            raise Error(String(e) + " (" + where + ")")

    # A cycle through waited-for edges leaves the ready set empty before every
    # segment has finished.
    var finished = List[Bool](length=n, fill=False)
    var remaining = n
    while remaining > 0:
        var ready = ready_set(descs, finished)
        if len(ready) == 0:
            raise Error(
                "komira_pipeline_exec: the plan has a dependency cycle; "
                + String(remaining)
                + " segments can never start"
            )
        for r in range(len(ready)):
            finished[ready[r]] = True
            remaining -= 1
