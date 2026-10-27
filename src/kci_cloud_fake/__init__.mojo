"""`kci_cloud_fake`: the fake clouds of kci.

These are FAKES, not mocks: working, lightweight clouds held in memory that
really deploy, keep state and answer reads, so everything above the cloud
module runs against them unchanged.

  * `FakeCloud` ("fake"): complete; the executable specification of a
    cloud and the offline test double.
  * `FakeLimitedCloud` ("fake-limited"): deliberately partial (no
    `container_job`, no `worker`, no `table`, no `bucket`, no messaging, no secret, no DNS, no
    certificate, no schedule, no event trigger, no network type, no registry, no public ingress); the offline proof that a graph a cloud cannot
    host is refused before anything is created.

The shapes and their lowering are kci_cloud's (`kci_cloud.shape`, shared with
every built-in adapter); this package re-exports them, realizes the lowered
nodes and keeps the memory they deploy into.

`FakeCloud` takes a provider shape (`ProviderShape`: generic by default;
`aws`, `gcp`, `azure` and `onprem` are the shaped fakes), the per-cloud table of roles
and provider kinds each catalog type lowers to. The built-in clouds are a
list of values (`builtin_shapes`); `shape_named` looks a cloud name up in it
and refuses any other name.

Both lower to data (the complete fixed set of roles of each type), realize
one node type (`FakeNode`), deploy into a `FakeStore` (state, labels as
written, a failed flag per node, unmodelled values and a call log), honour
the ownership labels (every object born stamped by the standard label
rule, read back exactly, listed per cell; every object carries the
`kci-retention` mark, and an object created in a scope with a validation run
id also carries `kci-run-id=<id>`, an adopted one never; one adopted for a
resource that writes `adopt` carries `kci_adopted=true`), answer an
adoption's read (`read_existing`: the object at a node, its kind, name and
the fields of its stored state) and release an object (its kci labels
dropped, nothing else), and pass the
`kci_cloud` conformance kit. Each shape carries its metadata limits as a value
(`MetadataLimits`: how many labels an object carries, how each type's
primary object may be named), and a named primary object's outputs follow
its name. The faulty variant is built from constructor arguments:
`fail_at_call = k` (the k-th mutating call is refused once), `read_lag = n`
(reads lag every create and delete by n reads) and `foreign = [names]`
(objects made outside kci before it ran); the kit's race hook makes the next
create meet a second apply's object.
"""

from kci_cloud_fake.fake_store import (
    CELL_SCOPE,
    FakeStore,
    FakeView,
    OUTSIDE_PREFIX,
    UNMAPPED_ROLE,
)
from kci_cloud_fake.roles import FAKE_ROLE_PREFIX, fake_role, fake_role_table
from kci_cloud_fake.nodes import (
    FakeNode,
    fake_account_name,
    fake_bucket_address,
    fake_bucket_name,
    fake_host,
    fake_messaging_address,
    fake_messaging_name,
    fake_secret_name,
    fake_table_name,
    fake_url,
    live_key,
    static_digest,
)
from kci_cloud_fake.clouds import FakeLimitedCloud, FakeCloud
from kci_cloud_fake.existing import digest_fields, planted_like, read_existing, release
from kci_cloud.shape import (
    GRANTS_DERIVED,
    GRANTS_LABELLED,
    lower_shape,
    shape_limits,
    GPU_REASON_AWS,
    GPU_REASON_UNDECIDED,
    GrantRow,
    ONPREM_SCALE_TO_ZERO_REASON,
    ONPREM_CERTIFICATE_REASON,
    ONPREM_DNS_REASON,
    ONPREM_MESSAGING_REASON,
    ONPREM_TABLE_REASON,
    ONPREM_EVENT_TRIGGER_REASON,
    ONPREM_NETWORK_REASON,
    ONPREM_REGISTRY_REASON,
    ONPREM_SCHEDULE_CALL_REASON,
    SCHEDULE_DAY_REASON_AWS,
    SCHEDULE_UTC_REASON_AZURE,
    SERVICE_NETWORK_REASON_AZURE,
    SUBNET_ZONE_REASON_AWS,
    ProviderShape,
    ShapeRow,
    TARGET_ANY,
    builtin_shapes,
    helper_role,
    shape_named,
)
from kci_cloud.shape import pull_shape
from kci_cloud.shape import lower_run, workload_limits
from kci_cloud.shape import folded_fields, folds, lower_trigger, trigger_limits
from kci_cloud.shape import SECRET_NAMED, lower_secret, secret_env_fields
from kci_cloud.shape import (
    fake_ip_address,
    fake_network_name,
    fake_subnet_name,
    lower_address,
    lower_network,
    lower_subnet,
    network_input,
    network_limits,
)
from kci_cloud.shape import fake_registry_address, lower_registry
from kci_cloud.shape import MetadataLimits, NameRule, fake_physical_name, metadata_limits
from kci_cloud.shape import (
    dns_limits,
    fake_certificate_name,
    fake_zone_name,
    lower_certificate,
    lower_record,
    lower_zone,
    record_kind,
)
