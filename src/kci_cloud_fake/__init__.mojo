"""`kci_cloud_fake`: the fake clouds of kci.

These are FAKES, not mocks: working, lightweight clouds held in memory that
really deploy, keep state and answer reads, so everything above the cloud
module runs against them unchanged.

  * `FakeCloud` ("fake"): complete; the executable specification of a
    cloud and the offline test double.
  * `FakeLimitedCloud` ("fake-limited"): deliberately partial (no `job`,
    no `bucket`, no public ingress); the offline proof that a graph a cloud cannot
    host is refused before anything is created.

`FakeCloud` takes a provider shape (`ProviderShape`: generic by default;
`aws`, `gcp`, `azure` and `onprem` are the shaped fakes), the per-cloud table of roles
and provider kinds each catalog type lowers to. The built-in clouds are a
list of values (`builtin_shapes`); `shape_named` looks a cloud name up in it
and refuses any other name.

Both lower to data (the complete fixed set of roles of each type), realize
one node type (`FakeNode`), deploy into a `FakeStore` (state, labels as
written, a failed flag per node, unmodelled values and a call log), honour
the ownership labels (every object born stamped by the standard label
rule, read back exactly, listed per cell), and pass the `kci_cloud`
conformance kit. The faulty variant is built from constructor arguments:
`fail_at_call = k` (the k-th mutating call is refused once), `read_lag = n`
(reads lag every create and delete by n reads) and `foreign = [names]`
(objects made outside kci before it ran); the kit's race hook makes the next
create meet a second apply's object.
"""

from kci_cloud_fake.fake_store import FakeStore, FakeView
from kci_cloud_fake.nodes import (
    FakeNode,
    fake_bucket_address,
    fake_bucket_name,
    fake_host,
    fake_url,
    static_digest,
)
from kci_cloud_fake.clouds import FakeLimitedCloud, FakeCloud
from kci_cloud_fake.shapes import ProviderShape, ShapeRow, builtin_shapes, shape_named
