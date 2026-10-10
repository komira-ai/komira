# komira_physical_plan

The PhysicalPlan IR (segment descriptors: a source, a chain of morsel operators and a sink, as inert data), its IR version door, and the purity gate that refuses a physical plan still holding a LogicalPlan.

- `physical_plan`: the segment descriptor `SegmentDescPod`, its `SourceSpecPod`, the `MorselOp` operator and the sink payloads, the source, operator, sink and edge tags, and `PHYSICAL_PLAN_IR_VERSION` with its door `assert_physical_plan_ir_version_compatible`, which refuses a segment emitted at another IR version.
- `physical_plan_purity_gate`: `assert_physical_plan_carries_no_logical_plan`, which refuses a segment whose expressions still hold a correlated subquery (and so a LogicalPlan), and raises on an expression tag it does not model.

The logical plan, which this package builds on, is in `komira_plan_ir`. `komira_optimizer` emits a LogicalPlan and does not depend on this package, so an import of it from the optimizer does not resolve and fails the optimizer's build. Users import the modules (`from komira_physical_plan.physical_plan import MorselOp`); the package's `__init__.mojo` exports nothing.
