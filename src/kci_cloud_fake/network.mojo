# =============================================================================
# kci_cloud_fake/network.mojo: how the fake clouds lower the NETWORK types
# (network, subnet, IP address) and a service's `network`, and the limits a
# shape puts on them.
# =============================================================================
#
# A network type runs as no identity: it holds no `identity` role and no
# grant (validate refuses `uses` on it), and it accepts no verb. The roles
# per shape are in shapes.mojo. Every node below exposes its output through
# an `out.<OUTPUT>` desired field (how the node behaves, not state: never in
# a digest; nodes.mojo).
#
#   * network    -> `<id>/network`: the field `ipv4_cidr` (the range) where
#                   the shape's network object holds it, else `subnets`
#                   (`custom`: the network makes no subnet of its own, and
#                   the range is kci's to hold its subnets to); `out.NAME` =
#                   `<id>-network`.
#   * subnet     -> `<id>/subnet`: an INPUT on its network's NAME
#                   (`network`; kci resolves the network's id to
#                   `<network>/network`, so the subnet is created after its
#                   network), the field `ipv4_cidr`, the field `zone` where
#                   the shape's subnets are each in one zone, and `out.NAME`
#                   = `<id>-subnet`.
#   * IP address -> `<id>/address`: the field `version` (`IPV4`), and
#                   `out.ADDRESS` = `<id>.ip.fake`.
#   A network or a subnet with the author's cloud name (`physical_name`)
#   exposes that name as its NAME, and an IP address's ADDRESS is built on
#   it (`<name>.ip.fake`).
#   * a service's `network` -> an INPUT of the service's run node on the
#                   subnet's NAME (`network`), so the run is created after
#                   the subnet and follows it (`network_input`).
#
# LIMITS (`network_limits`, the shapes' own; they cite this package):
#   * on a shape whose subnets are each in one zone (`subnet_zone_limit`),
#     a subnet with no zone;
#   * on a shape that cannot place one service in a subnet
#     (`service_network_limit`), a service with a `network`.
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud import (
    FIELD_IP_ADDRESS,
    FIELD_NETWORK,
    FIELD_SUBNET,
    FINDING_LIMIT,
    Finding,
    LoweredNode,
    Setting,
    service_subnet,
)
from kci_resource_proto.resource import Resource

from kci_cloud_fake.limits import FAKE_CITATION
from kci_cloud_fake.metadata import fake_physical_name
from kci_cloud_fake.shapes import ProviderShape, ROLE_ADDRESS, ROLE_NETWORK, ROLE_SUBNET


def fake_network_name(resource_id: String) -> String:
    return resource_id + String("-network")


def fake_subnet_name(resource_id: String) -> String:
    return resource_id + String("-subnet")


def fake_ip_address(resource_id: String) -> String:
    return resource_id + String(".ip.fake")


def _no_uses(r: Resource, what: String) raises:
    if len(r.uses) > 0:
        raise Error(String("fake: ") + what + String(" \"") + r.id + String("\" has uses lines; validate refuses them"))


def _one(r: Resource, role: String, kind: String, var refs: List[InputRef], var fields: List[Setting]) -> List[LoweredNode]:
    var out = List[LoweredNode]()
    out.append(LoweredNode(r.id + String("/") + role, r.id, kind, List[String](), refs^, fields^))
    return out^


def lower_network(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A network's one role (see the file header)."""
    _no_uses(r, String("network"))
    var fields = List[Setting]()
    if shape.network_ranged:
        fields.append(Setting(String("ipv4_cidr"), r.network.value().ipv4_cidr.copy()))
    else:
        fields.append(Setting(String("subnets"), String("custom")))
    var named = fake_physical_name(r)
    fields.append(Setting(String("out.NAME"), named if named.byte_length() > 0 else fake_network_name(r.id)))
    return _one(r, String(ROLE_NETWORK), shape.kind_of(FIELD_NETWORK, String(ROLE_NETWORK)), List[InputRef](), fields^)


def lower_subnet(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A subnet's one role, after its network (see the file header)."""
    _no_uses(r, String("subnet"))
    ref s = r.subnet.value()
    var refs = List[InputRef]()
    # The network by its resource id: kci resolves its primary node.
    refs.append(InputRef(s.network.value().resource.copy(), String("NAME"), String("network")))
    var fields = List[Setting]()
    fields.append(Setting(String("ipv4_cidr"), s.ipv4_cidr.copy()))
    if shape.subnet_zone_limit.byte_length() > 0 and Bool(s.zone):
        fields.append(Setting(String("zone"), String(Int(s.zone.value()))))
    var named = fake_physical_name(r)
    fields.append(Setting(String("out.NAME"), named if named.byte_length() > 0 else fake_subnet_name(r.id)))
    return _one(r, String(ROLE_SUBNET), shape.kind_of(FIELD_SUBNET, String(ROLE_SUBNET)), refs^, fields^)


def lower_address(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """An IP address's one role: the reserved address."""
    _no_uses(r, String("ip_address"))
    var fields = List[Setting]()
    fields.append(Setting(String("version"), String("IPV4")))
    var base = fake_physical_name(r)
    fields.append(Setting(String("out.ADDRESS"), fake_ip_address(base if base.byte_length() > 0 else r.id)))
    return _one(r, String(ROLE_ADDRESS), shape.kind_of(FIELD_IP_ADDRESS, String(ROLE_ADDRESS)), List[InputRef](), fields^)


def network_input(r: Resource, mut refs: List[InputRef]):
    """A service's `network`, as an input of its run node on the subnet's
    NAME; nothing for a service without one."""
    var subnet = service_subnet(r)
    if subnet.byte_length() > 0:
        # The subnet by its resource id: kci resolves its primary node.
        refs.append(InputRef(subnet^, String("NAME"), String("network")))


def network_limits(r: Resource, shape: ProviderShape, cloud: String, mut out: List[Finding]):
    """The shape's network limits (file header) on `r`; nothing for a type
    they do not concern."""
    if Bool(r.subnet) and shape.subnet_zone_limit.byte_length() > 0 and not Bool(r.subnet.value().zone):
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("subnet.zone"),
                String("on cloud \"") + cloud + String("\" a subnet is in one zone: ") + shape.subnet_zone_limit
                + String("; write its zone (1 to 3)"),
                String(FAKE_CITATION),
            )
        )
    if service_subnet(r).byte_length() > 0 and shape.service_network_limit.byte_length() > 0:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("service.network"),
                String("on cloud \"") + cloud + String("\" a service cannot be placed in a subnet: ")
                + shape.service_network_limit,
                String(FAKE_CITATION),
            )
        )
