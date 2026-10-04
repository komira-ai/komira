"""`kci_cloud_fake`: the fake clouds of kci.

These are FAKES, not mocks: working, lightweight clouds held in memory that
really deploy, keep state and answer reads, so everything above the cloud
module runs against them unchanged.

  * `FakeCloud` ("fake"): complete; the executable specification of a
    cloud and the offline test double.
  * `FakeLimitedCloud` ("fake-limited"): deliberately partial (no `job`,
    no public ingress); the offline proof that a graph a cloud cannot
    host is refused before anything is created.

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
from kci_cloud_fake.nodes import FakeNode, fake_host, fake_url, static_digest
from kci_cloud_fake.clouds import FakeLimitedCloud, FakeCloud
