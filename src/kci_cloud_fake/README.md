# kci_cloud_fake

The fake clouds of kci: working, lightweight clouds held in memory that
really deploy, keep state and answer reads, so everything above the cloud
layer (`kci_cloud`'s validate, plan, apply and destroy, and the
`kci_reconciler` engine) runs against them unchanged and offline. They are
fakes, not mocks: they implement `kci_cloud`'s `CloudAdapter` and pass its
conformance kit.

- `FakeCloud` (`"fake"`) is complete: the executable specification of a
  cloud and the offline test double. It takes a `ProviderShape` (generic by
  default; `builtin_shapes()` holds the `aws`, `gcp`, `azure` and `onprem`
  shapes, and `shape_named` looks one up), the table of roles and provider
  kinds each catalog type lowers to.
- `FakeLimitedCloud` (`"fake-limited"`) is deliberately partial (no `container_job`,
  `table`, `bucket`, messaging, secret or public ingress): the offline proof
  that a graph a cloud cannot host is refused before anything is created.

Both deploy into a `FakeStore` that keeps every object's state, labels as
written and a call log. Every object is stamped by the standard label rule
and carries the `kci-retention` mark. Constructor arguments give a faulty
variant: the k-th mutating call refused once, reads that lag, objects made
outside kci before it ran. Nothing here talks to a real cloud.

## Examples

Plan and apply a graph of a public service allowed to start a container job,
and a schedule that starts the job, on `"fake"`. A plan makes no mutating
call; an apply creates every node the graph lowers to (each resource's
identity and run, the schedule, the service's public ingress, the grants
between them and each resource's implicit grant to write the cell's logs),
and every node it applied is live:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_cloud import CellContext, Catalog, Clouds, apply_resources, describe, plan_resources
from kci_cloud_fake import FakeCloud, FakeLimitedCloud
from kci_reconciler import CellScope, Creds, InMemoryStateStore, Provenance
from kci_resource_proto.resource import ResourceList
from komira_proto_codec import decode_json

def shop_graph() raises -> ResourceList:
    return decode_json[ResourceList](
        '{"resource":['
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":8080,"public":{}},'
        '"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]},'
        '{"id":"nightly","containerJob":{"image":{"digest":"sha256:b2"}}},'
        '{"id":"tick","schedule":{"cron":"0 3 * * *","timezone":"UTC","target":{"resource":"nightly"}}}'
        ']}'
    )

def builtin_clouds() raises -> Clouds:
    var clouds = Clouds(Catalog.v1())
    clouds.add(describe(FakeCloud()))
    clouds.add(describe(FakeLimitedCloud()))
    return clouds^

def cell() -> CellContext:
    return CellContext(CellScope("shop", "blue", Provenance("run-1", "rev-1")))

var clouds = builtin_clouds()
var fake = FakeCloud()
var state = InMemoryStateStore()
var graph = shop_graph()

var actions = plan_resources(clouds, fake, cell(), graph.resource, Creds.none(), state)
assert_true(len(actions) > 0)
assert_equal(fake.mutations(), 0)  # a plan changes nothing
assert_equal(fake.live_count(), 0)

var outcome = apply_resources(clouds, fake, cell(), graph.resource, Creds.none(), state)
assert_true(outcome.ok())
assert_true(len(outcome.applied) > 0)
assert_equal(fake.live_count(), len(outcome.applied))
```

The same graph on `"fake-limited"` is refused by validate, with every reason
at once (the service's public ingress, and the job it has no runner for), and
the cloud serves no call:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_cloud import apply_resources
from kci_cloud_fake import FakeLimitedCloud
from kci_reconciler import Creds, InMemoryStateStore

var limited = FakeLimitedCloud()
var state = InMemoryStateStore()
var refused = String()
try:
    _ = apply_resources(builtin_clouds(), limited, cell(), shop_graph().resource, Creds.none(), state)
except e:
    refused = String(e)
assert_true(refused.startswith('kci: cannot apply this graph to cloud "fake-limited". Nothing was created.'), refused)
assert_true(refused.find('resource "api" field service.public') >= 0, refused)
assert_true(refused.find('resource "nightly"') >= 0, refused)
assert_equal(limited.mutations(), 0)
assert_equal(limited.live_count(), 0)
```
