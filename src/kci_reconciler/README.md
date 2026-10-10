# kci_reconciler

The provider-neutral deploy engine core of kci. A deploy is a `ResourceGraph`
of nodes, each a conformer of the `Resource` trait type-erased into an
`ErasedResource`. The engine orders the graph by each node's `depends_on`
(and its `input_refs`) and drives the verbs over it:

- `plan_graph` reads every node's live state and returns one `ChangeAction`
  per node (create, update, no-op, ...) without changing anything;
- `apply_graph` (and `apply_graph_tracked`) creates, updates or adopts each
  node in dependency order, recording a write-ahead intent in a `StateStore`
  before each create and confirming it after;
- `rollback_create` unwinds what an apply created, in reverse;
- `destroy_graph` deletes in reverse order, skips nodes kept by policy
  (`RETAIN_KEEP`, unless `force_delete_data`) and nodes that cannot be
  deleted (`RETAIN_UNDELETABLE`, returned to the caller), and retires an
  intent only after a re-read shows the resource gone;
- the `*_owned` forms do the same inside a cell scope, where every object
  carries an `OwnerStamp` and a foreign or conflicting object is refused
  before any change.

It also holds the fault vocabulary a conformer raises with: whose fault a
failure is (`fault_error`, `fault_domain_of_error`; an untagged fault reads
as ours) and the permanent and in-flight marks that drive retries.

The package names no provider and does no I/O. Every live read and mutation
is the conformer's; `InMemoryStateStore` is the in-memory `StateStore`.

## Examples

A conformer implements the verbs over its own notion of live state. This one
keeps its "live" state in the node itself, so the whole cycle runs in memory:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_reconciler import ChangeAction, Creds, ErasedResource, InMemoryStateStore, Resource, ResourceGraph
from kci_reconciler import ResourceStatus, CONVERGE_IN_PLACE, RES_ABSENT, RETAIN_DELETE, VERB_CREATE
from kci_reconciler import VERB_NOOP, apply_graph, destroy_graph, plan_graph

struct MemoryNode(Resource, Movable, Deinitable):
    var id: String
    var deps: List[String]
    var live: Bool

    def __init__(out self, id: String, deps: List[String]):
        self.id = id.copy()
        self.deps = deps.copy()
        self.live = False

    def logical_id(mut self) -> String:
        return self.id.copy()

    def depends_on(mut self) -> List[String]:
        return self.deps.copy()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        if not self.live:
            return ResourceStatus.absent()
        return ResourceStatus.matched("mem-" + self.id, "v1")

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var verb = VERB_CREATE if live.phase == RES_ABSENT else VERB_NOOP
        return ChangeAction(self.id, verb, "", RETAIN_DELETE)

    def create(mut self, creds: Creds) raises -> String:
        self.live = True
        return "mem-" + self.id

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self.live = False

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE

var graph = ResourceGraph()
graph.add(ErasedResource.erase(MemoryNode("app", ["bucket"])))  # added first, applied second
graph.add(ErasedResource.erase(MemoryNode("bucket", List[String]())))

var first = plan_graph(graph, Creds.none())
assert_equal(len(first), 2)
assert_equal(first[0].logical_id, "bucket")  # dependency order
assert_equal(first[0].verb_name(), "create")

var store = InMemoryStateStore()
var applied = apply_graph(graph, Creds.none(), store)
assert_equal(applied[0].logical_id, "bucket")
assert_equal(applied[1].physical_id, "mem-app")
assert_equal(store.count_confirmed("app"), 1)

var again = plan_graph(graph, Creds.none())
assert_true(again[0].is_noop() and again[1].is_noop())

var survivors = destroy_graph(graph, Creds.none(), store)
assert_equal(len(survivors), 0)
assert_equal(store.count_reaped("bucket"), 1)
assert_equal(store.count_reaped("app"), 1)
```

A raise site states whose fault a failure is, and marks a fault it has
proven permanent; only a permanent fault stops the retries, and a message
that merely quotes one inherits nothing:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_reconciler import FAULT_OURS, FAULT_UNSET, FAULT_USER, deploy_fault_message, fault_domain_of_error
from kci_reconciler import fault_error, fault_is_retryable, is_our_responsibility, mark_permanent_fault

var err = String(fault_error(FAULT_USER, mark_permanent_fault("CreateService: HTTP 400 INVALID_ARGUMENT")))
assert_equal(fault_domain_of_error(err), FAULT_USER)
assert_false(fault_is_retryable(err))
assert_equal(deploy_fault_message(err), "CreateService: HTTP 400 INVALID_ARGUMENT")

var quoted = "apply node 'app' failed: " + err
assert_true(fault_is_retryable(quoted))
assert_equal(fault_domain_of_error(quoted), FAULT_UNSET)
assert_true(is_our_responsibility(FAULT_UNSET))  # an unclassified fault is ours
assert_true(is_our_responsibility(FAULT_OURS))
assert_false(is_our_responsibility(FAULT_USER))
```
