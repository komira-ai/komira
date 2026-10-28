# komira_pipeline_exec

The driver that runs the segments of a physical plan. A plan is a list of
`SegmentDescPod` (`komira_physical_plan`): each segment is a source, a chain of
operators and a sink, with dependencies on other segments. `run_plan` runs the
segments in dependency order, and `run_segment` runs one segment on the workers
of a `ParallelDispatch` (`komira_async_api`), over the source, operator and sink
traits of `komira_morsel`.

Import each module by name; the package root exports nothing.

- `run_plan`: `run_plan(descs, builder, dispatch, num_workers, token)` checks
  the plan, then repeats: take the ready set, start its lowest segment id,
  publish its output. It returns the outputs no dependent took, by segment id.
  A segment that raises ends the run and the segments not started do not start.
- `run_segment`: build the members, size the sink for the workers, run one
  `SegmentTask` per worker, then combine once, finalize and take the output. A
  recorded error, or a cancellation by the caller's `CancellationToken`, is
  raised after the workers joined, and the sink is never combined or read.
- `segment_task`: `SegmentRun`, the state the workers share, and `SegmentTask`,
  the worker body. A worker reads the cancel flag and the token at every morsel
  boundary, claims a morsel (`None` at the end of input, never asked again by
  that worker), runs the operator chain and hands the rest to the sink. An
  operator returning HAVE_MORE_OUTPUT is executed again on the same morsel, each
  chunk pushed on before the next is asked for; FILTERED_EMPTY drops the morsel;
  FINISHED lets the rows it held go on and stops the worker's claims. A raise is
  recorded in the pipeline's first-error slot, which keeps the first error, and
  cancels the pipeline so the other workers stop at their next boundary.
- `plan_check`: `check_plan` refuses, by name and before any segment is built,
  a plan the driver cannot run; `ready_set` lists the segments that may start.
- `edge_policy`: what the driver does with each edge tag and order key. E1, E2
  and E3 make a consumer wait for its producer, E5 does not, E4 is refused;
  ORDER_NONE and ORDER_PARTITION_ID are served and ORDER_ROW_RANGE is refused.
- `published_outputs`: `PublishedOutputs`, the batch each finished segment left.
- `segment_builder`: the `SegmentBuilder` trait through which a plan's members
  are constructed from a descriptor.
- `source_variant`, `op_variant`, `pipeline_sink`: the closed variants. Each
  holds one of three member types, fixed where the variant is named, and a tag;
  its trait methods test the tag and call the member. `unused_members` fills
  the slots a list leaves empty with members that refuse to run.
- `fake_support`, `fake_members`, `fake_builder`, `fake_dispatch`: sources,
  an operator, sinks, a builder and dispatchers that record what the driver does
  in shared counters, and run the workers one after another in an order a test
  chooses.

The combine order is a property of the sink: it merges its per-worker slots,
indexed by worker id, in worker id order after every worker has joined. A
memory budget is a property of the sink too: a sink that cannot grow raises, and
the raise fails the query through the first-error slot.

## Example

Two segments over fake members. The first produces twelve rows; the second reads
them back and counts them. The workers run one after another, so the result does
not depend on a schedule.

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    SegmentDescPod,
)
from komira_pipeline_exec.fake_builder import (
    FROM_CURSOR,
    FROM_DEP,
    TO_COUNT,
    FakeBuilder,
    FakeScript,
    fake_desc,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.fake_support import batch_values
from komira_pipeline_exec.run_plan import run_plan

var descs = List[SegmentDescPod]()
descs.append(fake_desc(0))
var deps = List[Int]()
deps.append(0)
var tags = List[UInt8]()
tags.append(EDGE_E3_PUBLISH_WAIT)
descs.append(fake_desc(1, deps^, tags^))

var builder = FakeBuilder()
_ = builder.add(FakeScript(FROM_CURSOR, n_morsels=4, rows=3))
_ = builder.add(FakeScript(FROM_DEP, rows=5, dep=0, to_kind=TO_COUNT))

var dispatch = InlineDispatch()
var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
assert_false(out.has(0))  # the consumer took it
var counted = batch_values(out.take(1))
assert_equal(counted[0], Int64(12))
```
