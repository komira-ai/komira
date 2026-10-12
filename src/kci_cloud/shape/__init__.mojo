"""`kci_cloud.shape`: the shared shape lowering of the built-in clouds.

A `ProviderShape` is, as data, the fixed set of roles and provider kinds each
catalog type lowers to on one cloud, its grant rows, its absences, its limits
and where its grants carry their stamp (`grant_carrier`: labels, or DERIVED
for a member binding). `lower_shape` is THE lowering over a shape, and
`shape_limits` every limit it refuses: the fake clouds (`kci_cloud_fake`) and
the adapter of each built-in cloud call the same two functions, so a cloud
lowers as its fake does, byte for byte.

  * shapes.mojo    — `ProviderShape` and its rows; the built-in clouds as data
                     (`builtin_shapes`, `shape_named`); the grant carrier.
  * lower.mojo     — `lower_shape` (identity, workloads, edges and every other
                     type by its file), `shape_limits`, and the two refusals of
                     a DERIVED shape (`derived_grant_limits`).
  * workloads.mojo, data.mojo, messaging.mojo, secrets.mojo, dns.mojo,
    network.mojo, registry.mojo, triggers.mojo — each type's lowering and
                     limits; metadata.mojo the per-shape metadata limits;
                     limits.mojo the limits every shape shares.
"""

from kci_cloud.shape.shapes import (
    GPU_REASON_AWS,
    GPU_REASON_UNDECIDED,
    GRANTS_DERIVED,
    GRANTS_LABELLED,
    GrantRow,
    ONPREM_CERTIFICATE_REASON,
    ONPREM_DNS_REASON,
    ONPREM_EVENT_TRIGGER_REASON,
    ONPREM_MESSAGING_REASON,
    ONPREM_NETWORK_REASON,
    ONPREM_REGISTRY_REASON,
    ONPREM_SCALE_TO_ZERO_REASON,
    ONPREM_SCHEDULE_CALL_REASON,
    ONPREM_TABLE_REASON,
    ProviderShape,
    SCHEDULE_DAY_REASON_AWS,
    SCHEDULE_UTC_REASON_AZURE,
    SERVICE_NETWORK_REASON_AZURE,
    SUBNET_ZONE_REASON_AWS,
    ShapeRow,
    TARGET_ANY,
    builtin_shapes,
    helper_role,
    shape_named,
)
from kci_cloud.shape.lower import DERIVED_CITATION, derived_grant_limits, lower_shape, shape_limits
from kci_cloud.shape.messaging import pull_shape
from kci_cloud.shape.workloads import lower_run, workload_limits
from kci_cloud.shape.triggers import folded_fields, folds, lower_trigger, trigger_limits
from kci_cloud.shape.secrets import SECRET_NAMED, lower_secret, secret_env_fields
from kci_cloud.shape.network import (
    fake_ip_address,
    fake_network_name,
    fake_subnet_name,
    lower_address,
    lower_network,
    lower_subnet,
    network_input,
    network_limits,
)
from kci_cloud.shape.registry import fake_registry_address, lower_registry
from kci_cloud.shape.metadata import MetadataLimits, NameRule, fake_physical_name, metadata_limits
from kci_cloud.shape.dns import (
    dns_limits,
    fake_certificate_name,
    fake_zone_name,
    lower_certificate,
    lower_record,
    lower_zone,
    record_kind,
)
