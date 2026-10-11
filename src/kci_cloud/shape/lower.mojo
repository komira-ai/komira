# =============================================================================
# kci_cloud/shape/lower.mojo: THE shared shape lowering, and the shape's checks.
# =============================================================================
#
# `lower_shape` turns one resource into the complete fixed set of roles of its
# type on a `ProviderShape`, as data (`LoweredNode`). It is THE lowering of
# every cloud built into kci that lowers by a shape: the fake clouds
# (kci_cloud_fake) and the adapter of each built-in cloud call it, so a cloud
# lowers as its fake does, byte for byte. There is no second lowering written
# by hand; a change to how a cloud lowers is a change to its shape (data) or
# to this package, and the fakes' goldens see it.
#
# On every shape:
#   service -> `<id>/identity` (wanted iff no `run_as`), `<id>/run`, and the
#              shape's other roles (workloads.mojo), and one grant per edge
#   container job, worker -> `<id>/identity`, `<id>/run`, and the same grants
#   service account -> `<id>/identity` (it exposes NAME), and its grants
#   grant   -> its one edge
#   schedule, event trigger -> `<id>/identity`, `<id>/schedule` or
#              `<id>/trigger`, and the one edge, CALL on the target
#              (triggers.mojo; turned off where the shape folds the schedule
#              into the job it starts)
#   every other type -> its own file's lowering (data, messaging, secrets,
#              dns, network, registry).
# An edge lowers to `<id>/<role>` (`u-<h>` or `grant`), depends on its
# principal's identity node and on its target, and has the desired fields
# principal, target (or cell) and access; where the shape's row names a
# helper, a second node `r-<h>` (or `rules`) that the binding depends on. A
# target type with no row FOLDS into the identity it is for (`cell.<NAME>`).
#
# `shape_limits` is every limit the shape refuses of one resource (the
# reference limits, limits.mojo and each type's file), and, on a shape whose
# grants are DERIVED (shapes.mojo), the two refusals of the derived stamp
# (`derived_grant_limits`): a `grant` resource, and a `uses` line on a
# workload that has `run_as`. On such a shape a binding's node id is computed
# from the cloud's objects (kci_cloud/derived.mojo), which is pure only when
# the owner of an edge is its principal; both of those break it. The fix is
# named in the finding: write the `uses` line on the principal itself.
# =============================================================================

from kci_reconciler import InputRef
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_LIMIT, Finding, LoweredNode, Setting
from kci_cloud.catalog import (
    FIELD_BUCKET,
    FIELD_CERTIFICATE,
    FIELD_DNS_RECORD,
    FIELD_DNS_ZONE,
    FIELD_EVENT_TRIGGER,
    FIELD_GRANT,
    FIELD_IP_ADDRESS,
    FIELD_NETWORK,
    FIELD_QUEUE,
    FIELD_REGISTRY,
    FIELD_SCHEDULE,
    FIELD_SECRET,
    FIELD_SERVICE_ACCOUNT,
    FIELD_SUBNET,
    FIELD_SUBSCRIPTION,
    FIELD_TABLE,
    FIELD_TOPIC,
    body_field,
    body_is,
)
from kci_cloud.feed import Feed
from kci_cloud.firing import Firing
from kci_cloud.grants import GrantEdge, holds_own_identity, run_as_of

from kci_cloud.shape.data import lower_bucket, lower_table
from kci_cloud.shape.dns import dns_limits, lower_certificate, lower_record, lower_zone
from kci_cloud.shape.limits import common_limits, fold_limits, index_limits
from kci_cloud.shape.messaging import lower_queue, lower_subscription, lower_topic, messaging_limits
from kci_cloud.shape.metadata import metadata_limits
from kci_cloud.shape.network import lower_address, lower_network, lower_subnet, network_limits
from kci_cloud.shape.registry import lower_registry
from kci_cloud.shape.secrets import lower_secret
from kci_cloud.shape.shapes import ProviderShape, ROLE_IDENTITY, ROLE_VAULT, helper_role
from kci_cloud.shape.triggers import folds, lower_trigger, trigger_limits
from kci_cloud.shape.workloads import lower_run, workload_limits


comptime DERIVED_CITATION = "kci_cloud: the derived grant stamp (docs/design/deploy_step.md, question Q13)"
"""Where the two refusals of a DERIVED shape are explained."""


def _identity(r: Resource, field: Int, shape: ProviderShape, own: Bool) raises -> List[LoweredNode]:
    """`<id>/identity` (wanted iff the resource holds its own identity) and,
    where the shape has one, its `<id>/vault` helper. A service account's
    identity exposes NAME (`account`, how the node behaves, not state)."""
    var out = List[LoweredNode]()
    var ident = r.id + String("/") + String(ROLE_IDENTITY)
    var fields = List[Setting]()
    if field == FIELD_SERVICE_ACCOUNT:
        fields.append(Setting(String("account"), String("true")))
    out.append(
        LoweredNode(
            ident.copy(),
            r.id,
            shape.kind_of(field, String(ROLE_IDENTITY)),
            List[String](),
            List[InputRef](),
            fields^,
            own,
        )
    )
    if shape.has(field, String(ROLE_VAULT)):
        var deps = List[String]()
        deps.append(ident^)
        out.append(
            LoweredNode(
                r.id + String("/") + String(ROLE_VAULT),
                r.id,
                shape.kind_of(field, String(ROLE_VAULT)),
                deps^,
                List[InputRef](),
                List[Setting](),
                own,
            )
        )
    return out^


def _edge_fields(e: GrantEdge, with_principal: Bool) -> List[Setting]:
    var g = List[Setting]()
    if with_principal:
        g.append(Setting(String("principal"), e.principal.copy()))
    if e.on_cell():
        g.append(Setting(String("cell"), e.cell.copy()))
    else:
        g.append(Setting(String("target"), e.target.copy()))
    g.append(Setting(String("access"), e.access.copy()))
    return g^


def _lower_edges(
    r: Resource, edges: List[GrantEdge], shape: ProviderShape, mut out: List[LoweredNode], wanted: Bool = True
) raises:
    """One grant per edge, by the shape's row for the target's type: the
    binding (and its helper, where the row names one), or FOLDED into the
    identity it is for when the shape has no row. `wanted` False lowers
    every edge turned off (a schedule folded into its job)."""
    for i in range(len(edges)):
        ref e = edges[i]
        var row = shape.grant_row(e.target_field)
        if not row:
            var ident = r.id + String("/") + String(ROLE_IDENTITY)
            var at = -1
            for k in range(len(out)):
                if out[k].id == ident:
                    at = k
            if not e.on_cell() or e.principal != r.id or at < 0:
                raise Error(
                    String("fake: shape \"")
                    + shape.name
                    + String("\" folds this edge of \"")
                    + r.id
                    + String("\" into an identity it does not hold; validate refuses it")
                )
            out[at].desired.append(Setting(String("cell.") + e.cell, e.access.copy()))
            continue
        var deps = List[String]()
        deps.append(e.principal_node())
        if not e.on_cell():
            # The target by its resource id: kci resolves its primary node.
            deps.append(e.target.copy())
        if row.value().helper.byte_length() > 0:
            var hid = r.id + String("/") + helper_role(e.role)
            var hdeps = List[String]()
            if not e.on_cell():
                hdeps.append(e.target.copy())
            out.append(
                LoweredNode(
                    hid.copy(), r.id, row.value().helper.copy(), hdeps^, List[InputRef](), _edge_fields(e, False), wanted
                )
            )
            deps.append(hid^)
        out.append(
            LoweredNode(
                r.id + String("/") + e.role,
                r.id,
                row.value().kind.copy(),
                deps^,
                List[InputRef](),
                _edge_fields(e, True),
                wanted,
            )
        )


def lower_shape(
    r: Resource,
    edges: List[GrantEdge],
    feeds: List[Feed],
    firings: List[Firing],
    mechanism: String,
    shape: ProviderShape,
) raises -> List[LoweredNode]:
    """The complete fixed set of roles of `r` on `shape`, as data (the file
    header). `mechanism` is the cell's public mechanism (empty for none)."""
    var field = body_field(r)
    if field == FIELD_BUCKET:
        return lower_bucket(r, shape)
    if field == FIELD_TABLE:
        return lower_table(r, shape)
    if field == FIELD_QUEUE:
        return lower_queue(r, feeds, shape)
    if field == FIELD_TOPIC:
        return lower_topic(r, shape)
    if field == FIELD_SUBSCRIPTION:
        return lower_subscription(r, shape)
    if field == FIELD_SECRET:
        return lower_secret(r, shape)
    if field == FIELD_DNS_ZONE:
        return lower_zone(r, shape)
    if field == FIELD_DNS_RECORD:
        return lower_record(r, shape)
    if field == FIELD_CERTIFICATE:
        return lower_certificate(r, shape)
    if field == FIELD_NETWORK:
        return lower_network(r, shape)
    if field == FIELD_SUBNET:
        return lower_subnet(r, shape)
    if field == FIELD_IP_ADDRESS:
        return lower_address(r, shape)
    if field == FIELD_REGISTRY:
        return lower_registry(r, shape)
    var out = List[LoweredNode]()
    if field == FIELD_GRANT:
        _lower_edges(r, edges, shape, out)
        return out^
    if field == FIELD_SCHEDULE or field == FIELD_EVENT_TRIGGER:
        var on = not folds(r, edges, shape)
        out.extend(_identity(r, field, shape, on))
        out.extend(lower_trigger(r, edges, shape, on))
        _lower_edges(r, edges, shape, out, on)
        return out^
    var own = holds_own_identity(r)
    out.extend(_identity(r, field, shape, own))
    if field == FIELD_SERVICE_ACCOUNT:
        _lower_edges(r, edges, shape, out)
        return out^
    out.extend(lower_run(r, own, mechanism, shape, firings))
    _lower_edges(r, edges, shape, out)
    return out^


def derived_grant_limits(r: Resource, shape: ProviderShape, cloud: String, mut out: List[Finding]):
    """On a shape whose grants are DERIVED, a `grant` resource and a `uses`
    line on a workload with `run_as` (the file header). Nothing elsewhere."""
    if not shape.grants_derived():
        return
    if body_is(r, FIELD_GRANT):
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("grant"),
                String("cloud \"") + cloud
                + String("\" derives a binding's stamp from its principal, so a binding cannot be owned by a grant"
                + " resource: write a uses line on the principal instead (same target, same access)"),
                String(DERIVED_CITATION),
            )
        )
    var account = run_as_of(r)
    if account.byte_length() > 0 and len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("uses"),
                String("cloud \"") + cloud
                + String("\" derives a binding's stamp from its principal, so a uses line on a workload that runs as \"")
                + account
                + String("\" cannot be owned by the workload: write the uses line on \"")
                + account
                + String("\" itself"),
                String(DERIVED_CITATION),
            )
        )


def shape_limits(
    r: Resource, feeds: List[Feed], firings: List[Firing], shape: ProviderShape, cloud: String, mut out: List[Finding]
):
    """Every limit `shape` refuses of `r` (the file header), cited as the
    cloud called `cloud`."""
    common_limits(r, out)
    fold_limits(r, shape, cloud, out)
    index_limits(r, shape, cloud, out)
    messaging_limits(r, feeds, shape, cloud, out)
    dns_limits(r, shape, cloud, out)
    workload_limits(r, shape, cloud, out)
    trigger_limits(r, firings, shape, cloud, out)
    network_limits(r, shape, cloud, out)
    metadata_limits(r, firings, shape.metadata, shape.schedule_folds, cloud, out)
    derived_grant_limits(r, shape, cloud, out)
