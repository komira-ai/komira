# =============================================================================
# kci_cloud/validate.mojo: the validate phase.
# =============================================================================
#
# Runs before anything is lowered, planned or created, and needs no
# credentials. It collects EVERY finding in one pass, so an author sees all of
# their problems at once:
#
#   0. EXPANSION first (compose.mojo): every composite instance of the list
#      becomes its primitives, each with its path id `top/c1/.../ck`, and
#      every reference names a full path. A finding of the expansion (a
#      definition, a containment cycle, an instance, a path, the size guard)
#      is returned alone: the graph below a refused instance is not known,
#      so nothing after it is judged. Every check below runs on the expanded
#      list, so it holds at every depth. A produced path id is not held to
#      the resource id grammar (its segments were checked as component ids);
#      every authored id is.
#   1. GRAPH findings, true on every cloud: ids (unique, and of the id
#      grammar `[a-z][a-z0-9-]{0,23}` with no trailing or doubled `-`, so
#      never the node-id separator `/`), a type set, every `Ref` naming a
#      resource of the list, an output the producer's type exposes, an access
#      verb the target's type accepts. And the workload rules (compute.mojo,
#      for a service, a container job and a worker): an image that is a
#      content digest by now (a build output must have been substituted by
#      the deploy facade before a cloud ever sees the resource), its
#      platform written as `<os>/<cpu>` (empty means `linux/amd64`); `run_as`
#      a service account; `env` values resolved; a written `command` whose
#      first entry is not empty; a worker's `replicas` never an explicit 0.
#      And the secret rules (secrets.mojo): no `uses` on a secret; each
#      `secret_env` entry of a workload set by it and not also by `env`,
#      naming one of a `name` and a `secret`, its `secret` a secret resource
#      read by the identity that receives it. And the data rules:
#      `retention` only on a type that takes one (a workload is deleted with
#      its resource) and only DELETE or KEEP; and the rules of
#      the data types (data.mojo): no `uses` on a table or a bucket (it runs
#      as no identity, so it can be granted to, never grant); a bucket's
#      `object_expiry_days` never an explicit 0; a table's key, access paths
#      and fields complete and typed, its index names unique. And the
#      messaging rules (messaging.mojo): no `uses` on a queue, a topic or a
#      subscription; a queue's ack deadline and max deliveries in range, its
#      dead-letter queue a queue, never in a cycle; a subscription's topic
#      and queue of their types, each pair once. And the name rules
#      (dns.mojo): no `uses` on a DNS zone, a DNS record or a certificate;
#      DNS names of the name grammar, each in its zone; one zone per domain
#      and one record set per name and type; a record's values of its type;
#      a certificate's domains from 1 to 10, none twice. And the trigger
#      rules (triggers.mojo): no `uses` on a schedule or an event trigger; a
#      cron of the portable form, a time zone of an IANA name's shape, a
#      schedule's target a container job or a service; an event trigger's
#      source a bucket, its event known, its target a service, each
#      (source, event, target) once. And the network rules (network.mojo): no
#      `uses` on a network, a subnet or an IP address; IPv4 ranges of the
#      form, a network's private, a subnet's inside its network's and
#      overlapping no other; a subnet's zone from 1 to 3; a service's
#      `network` a subnet. And the registry rules (registry.mojo): no `uses`
#      on a registry; its format written, and one this kci knows. And the
#      metadata rules of every type (metadata.mojo): labels, cloud names, adopt.
#      And the identity rules (grants.mojo): no `uses` on a grant; a `uses`
#      line or a grant names exactly one of a target and a cell resource,
#      with a verb that target accepts; a grant's principal is an identity
#      (a service account, or a workload with no `run_as`); ONE edge per
#      (principal, target) pair in the whole list, counting `uses` lines,
#      grants and the implicit `cell LOGS WRITE` alike; and no two edges of
#      one resource whose `u-<h>` roles collide. And no REFERENCE CYCLE
#      between resources (cycles.mojo): two services each reading the
#      other's URL can be created in no order, so the cycle is refused here,
#      before anything is read, not by the engine's sort after the reads.
#   2. COVERAGE findings: the chosen cloud has no adapter for a type. The
#      text carries the cloud's typed absence and the built-in clouds
#      that do host the type.
#   3. LIMIT findings: the cloud hosts the type but refuses a value or a
#      shape (`CloudAdapter.check`), for example a public URL on a cloud
#      with no public ingress; the image's platform is not the one the cloud
#      needs for the type (`CloudAdapter.required_artifact`); or a `public {}`
#      service in a cell whose settings choose no public mechanism
#      (`CloudAdapter.public_mechanism`). The mechanism is chosen HERE, from
#      the cell's settings, and never fallen back on at apply time. Last, on
#      a graph with no other finding, one cloud name per (kind, name) of the
#      cloud's lowered primary objects (`metadata.shared_name_findings`).
#
#   4. The ROLE LABEL BUDGET (`lowered_budget_findings`), the check that
#      needs the whole lowering: every lowered node's role (the node id
#      after its owner) must fit the 63-byte label value once encoded. It is
#      a GRAPH finding naming the node, the byte count and every segment's
#      length. Like the names of 3, it runs on a graph with no other
#      finding: validate lowers every resource on the cloud (data, nothing
#      realized; a resource whose lowering raises is skipped, and the
#      lowering contract refuses it at plan). So `validate` reports it, and
#      plan, apply and destroy, which validate first, refuse it before
#      anything is listed, realized or created. Nesting is unbounded in the
#      schema; this is its practical bound.
#
# ⛔ A FINDING IS A REFUSAL OF THE WHOLE GRAPH. There is no "skip what the
# cloud cannot do": that turns "cannot do it yet" into a silently thinner
# deploy.
# =============================================================================

from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.refs import Ref
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import (
    CloudAdapter,
    ArtifactNeed,
    Finding,
    LoweredNode,
    FINDING_GRAPH,
    FINDING_COVERAGE,
    FINDING_LIMIT,
    absence_word,
)
from kci_cloud.catalog import (
    Catalog,
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
    FIELD_SERVICE,
    FIELD_SERVICE_ACCOUNT,
    FIELD_SUBNET,
    FIELD_SUBSCRIPTION,
    FIELD_TABLE,
    FIELD_TOPIC,
    RETENTION_DELETE,
    RETENTION_KEEP,
    RETENTION_NONE,
    body_field,
    portability_word,
)
from kci_cloud.cloud_id import CloudId
from kci_cloud.clouds import Clouds
from kci_cloud.compute import V1_IMAGE_PLATFORM, image_platform, workload_findings
from kci_cloud.data import data_findings
from kci_cloud.feed import Feed, feeds_of
from kci_cloud.messaging import messaging_findings
from kci_cloud.secrets import secret_env_findings, secret_findings
from kci_cloud.dns import dns_findings
from kci_cloud.firing import Firing, firings_of
from kci_cloud.triggers import trigger_findings
from kci_cloud.network import network_findings, service_network_findings
from kci_cloud.registry import registry_findings
from kci_cloud.metadata import metadata_findings, shared_name_findings
from kci_cloud.workload import is_workload, workload_of
from kci_cloud.grants import (
    GrantEdge,
    cell_accepted,
    cell_accepts,
    cell_name,
    edges_for,
    edges_of,
    run_as_of,
)
from kci_cloud.labels import LABEL_VALUE_MAX, encoded_label_bytes
from kci_cloud.compose import expand
from kci_cloud.compose_refs import id_problem, no_ref, owner_of_node
from kci_cloud.cycles import reference_cycle_findings


def _index_of_id(resources: List[Resource], id: String) -> Int:
    for i in range(len(resources)):
        if resources[i].id == id:
            return i
    return -1


def _type_of(catalog: Catalog, r: Resource) -> String:
    try:
        return catalog.name_of(body_field(r))
    except:
        return String("resource with no type")


def _check_principal(
    catalog: Catalog,
    resources: List[Resource],
    owner: String,
    r: Ref,
    mut out: List[Finding],
):
    """A grant's principal is an identity: a service account, or a workload
    with no `run_as` (its private identity)."""
    var path = String("grant.principal")
    var p = _index_of_id(resources, r.resource)
    if p < 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("ref to missing resource \"") + r.resource + String("\""),
            )
        )
        return
    if r._oneof0_case != 0:
        out.append(
            Finding(FINDING_GRAPH, owner, path, String("a principal is an identity, not one of its outputs"))
        )
        return
    ref pr = resources[p]
    var field: Int
    try:
        field = body_field(pr)
    except:
        return
    if field == FIELD_SERVICE_ACCOUNT:
        return
    if is_workload(field):
        var acct = run_as_of(pr)
        if acct.byte_length() > 0:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    owner,
                    path,
                    String("\"")
                    + r.resource
                    + String("\" runs as \"")
                    + acct
                    + String("\" and has no identity of its own; name \"")
                    + acct
                    + String("\" as the principal"),
                )
            )
        return
    out.append(
        Finding(
            FINDING_GRAPH,
            owner,
            path,
            String("the principal must be a service_account, or a workload (a service, a")
            + String(" container_job or a worker) with no run_as; \"")
            + r.resource
            + String("\" is a ")
            + catalog.name_of(field),
        )
    )


def _check_edge_target(
    catalog: Catalog,
    resources: List[Resource],
    owner: String,
    path: String,
    has_target: Bool,
    target: Ref,
    cell: Int,
    access: String,
    mut out: List[Finding],
):
    """A `uses` line's or a grant's target: exactly one of a resource of the
    list and a cell resource, and a verb that target accepts."""
    if has_target and cell != 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("names a target and a cell resource; an edge has exactly one"),
            )
        )
        return
    if not has_target and cell == 0:
        out.append(Finding(FINDING_GRAPH, owner, path, String("no target")))
        return
    if not has_target:
        var name = cell_name(cell)
        if name.byte_length() == 0:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    owner,
                    path,
                    String("cell resource ")
                    + String(cell)
                    + String(" is not one this kci knows (LOGS, METRICS, ARTIFACTS)"),
                )
            )
        elif not cell_accepts(cell, access):
            out.append(
                Finding(
                    FINDING_GRAPH,
                    owner,
                    path,
                    String("the cell's ")
                    + name
                    + String(" does not accept access ")
                    + access
                    + String(" (it accepts ")
                    + cell_accepted(cell)
                    + String(")"),
                )
            )
        return
    if target.resource == owner:
        out.append(Finding(FINDING_GRAPH, owner, path, String("uses itself")))
        return
    var p = _index_of_id(resources, target.resource)
    if p < 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("ref to missing resource \"") + target.resource + String("\""),
            )
        )
        return
    if target._oneof0_case != 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("access is granted to a resource, not to one of its outputs"),
            )
        )
    var pfield: Int
    try:
        pfield = body_field(resources[p])
    except:
        return
    var pt = catalog.index_of(pfield)
    if pt >= 0 and not catalog.types[pt].accepts_access(access):
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                catalog.types[pt].name
                + String(" \"")
                + target.resource
                + String("\" does not accept access ")
                + access,
            )
        )


def _edge_where(e: GrantEdge, owner: String, index: Int) -> String:
    """Where an edge came from, for a refusal text."""
    if e.implicit and e.on_cell():
        return String("the implicit cell LOGS WRITE edge of \"") + owner + String("\"")
    if e.implicit:
        return String("the implicit CALL edge of trigger \"") + owner + String("\"")
    if e.role == "grant":
        return String("grant \"") + owner + String("\"")
    return String("uses[") + String(index) + String("] of \"") + owner + String("\"")


def _edge_path(e: GrantEdge, index: Int) -> String:
    if e.role == "grant":
        return String("grant")
    if e.implicit:
        return String("uses")
    return String("uses[") + String(index) + String("]")


def edge_findings(resources: List[Resource]) -> List[Finding]:
    """ONE edge per (principal, target) pair in the whole list, and no two
    edges of one resource whose roles collide. The implicit edges are
    counted first, so a written edge that repeats one is the one refused."""
    var out = List[Finding]()
    var keys = List[String]()
    var wheres = List[String]()
    for pass_ in range(2):
        for i in range(len(resources)):
            ref r = resources[i]
            if _index_of_id(resources, r.id) != i:
                continue  # a duplicate id is a finding of its own
            var edges: List[GrantEdge]
            try:
                edges = edges_of(r)
            except:
                continue  # its shape is a finding of its own
            for k in range(len(edges)):
                ref e = edges[k]
                if e.implicit != (pass_ == 0):
                    continue
                var key = e.key()
                var dup = -1
                for q in range(len(keys)):
                    if keys[q] == key:
                        dup = q
                        break
                if dup >= 0:
                    out.append(
                        Finding(
                            FINDING_GRAPH,
                            r.id,
                            _edge_path(e, k),
                            String("a second edge from the identity of \"")
                            + e.principal
                            + String("\" to ")
                            + e.target_path()
                            + String("; the first is ")
                            + wheres[dup]
                            + String(" (one edge per principal and target)"),
                        )
                    )
                else:
                    keys.append(key^)
                    wheres.append(_edge_where(e, r.id, k))
    for i in range(len(resources)):
        ref r = resources[i]
        var edges: List[GrantEdge]
        try:
            edges = edges_of(r)
        except:
            continue
        for k in range(len(edges)):
            for q in range(k):
                if edges[q].role == edges[k].role and edges[q].key() != edges[k].key():
                    out.append(
                        Finding(
                            FINDING_GRAPH,
                            r.id,
                            _edge_path(edges[k], k),
                            _edge_where(edges[k], r.id, k)
                            + String(" and ")
                            + _edge_where(edges[q], r.id, q)
                            + String(" lower to one role, ")
                            + edges[k].role
                            + String("; write one of them as a grant resource"),
                        )
                    )
    return out^


def _produced(produced: List[String], id: String) -> Bool:
    for i in range(len(produced)):
        if produced[i] == id:
            return True
    return False


def graph_findings(
    catalog: Catalog, resources: List[Resource], produced: List[String] = List[String]()
) -> List[Finding]:
    """Every cloud-independent finding of `resources`. An id in `produced`
    is a path an expansion made (compose.mojo), whose segments it already
    checked; every other id is held to the resource id grammar."""
    var out = List[Finding]()
    for i in range(len(resources)):
        ref r = resources[i]
        var id = r.id.copy()
        var bad_id = String("") if _produced(produced, id) else id_problem(id)
        if id.byte_length() == 0:
            out.append(
                Finding(FINDING_GRAPH, String("#") + String(i), String("id"), bad_id)
            )
        elif bad_id.byte_length() > 0:
            out.append(Finding(FINDING_GRAPH, id, String("id"), bad_id))
        for k in range(i):
            if resources[k].id == id and id.byte_length() > 0:
                out.append(
                    Finding(FINDING_GRAPH, id, String("id"), String("duplicate id"))
                )
                break
        var field: Int
        try:
            field = body_field(r)
        except e:
            out.append(Finding(FINDING_GRAPH, id, String("body"), String(e)))
            continue
        var t = catalog.index_of(field)
        if t < 0:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    String("body"),
                    String("type field ") + String(field) + String(" is not in the catalog"),
                )
            )
            continue
        var tname = catalog.types[t].name.copy()
        var retention = r.retention.value
        if retention != RETENTION_NONE:
            if not catalog.types[t].takes_retention():
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        String("retention"),
                        String("a ")
                        + tname
                        + String(
                            " takes no retention: it is deleted with its resource;"
                            " retention is for data types"
                        ),
                    )
                )
            elif retention != RETENTION_DELETE and retention != RETENTION_KEEP:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        String("retention"),
                        String("retention value ")
                        + String(retention)
                        + String(" is not DELETE or KEEP"),
                    )
                )
        out.extend(metadata_findings(catalog, resources, r))
        if field == FIELD_BUCKET or field == FIELD_TABLE:
            out.extend(data_findings(field, r))
            continue
        if field == FIELD_QUEUE or field == FIELD_TOPIC or field == FIELD_SUBSCRIPTION:
            out.extend(messaging_findings(resources, field, r))
            continue
        if field == FIELD_SECRET:
            out.extend(secret_findings(field, r))
            continue
        if field == FIELD_DNS_ZONE or field == FIELD_DNS_RECORD or field == FIELD_CERTIFICATE:
            out.extend(dns_findings(catalog, resources, field, r))
            continue
        if field == FIELD_SCHEDULE or field == FIELD_EVENT_TRIGGER:
            out.extend(trigger_findings(resources, field, r))
            continue
        if field == FIELD_NETWORK or field == FIELD_SUBNET or field == FIELD_IP_ADDRESS:
            out.extend(network_findings(resources, field, r))
            continue
        if field == FIELD_REGISTRY:
            out.extend(registry_findings(field, r))
            continue
        if field == FIELD_GRANT:
            ref g = r.grant.value()
            if len(r.uses) > 0:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        String("uses"),
                        String(
                            "a grant is one edge and runs as no identity, so it cannot"
                            " use another resource; write another grant"
                        ),
                    )
                )
            if not g.principal:
                out.append(Finding(FINDING_GRAPH, id, String("grant.principal"), String("no principal")))
            else:
                _check_principal(catalog, resources, id, g.principal.value(), out)
            var has = Bool(g.target)
            _check_edge_target(
                catalog,
                resources,
                id,
                String("grant"),
                has,
                g.target.value().copy() if has else no_ref(),
                g.cell.value,
                g.access.json_name(),
                out,
            )
            continue
        out.extend(workload_findings(catalog, resources, r))
        out.extend(secret_env_findings(resources, r))
        out.extend(service_network_findings(resources, r))
        for u in range(len(r.uses)):
            ref use = r.uses[u]
            var has = Bool(use.target)
            _check_edge_target(
                catalog,
                resources,
                id,
                String("uses[") + String(u) + String("]"),
                has,
                use.target.value().copy() if has else no_ref(),
                use.cell.value,
                use.access.json_name(),
                out,
            )
    var edges = edge_findings(resources)
    for i in range(len(edges)):
        out.append(edges[i].copy())
    out.extend(reference_cycle_findings(resources))
    return out^


def _check_platform[
    S: CloudAdapter
](cloud: S, r: Resource, mut out: List[Finding]):
    """The image's platform against the one the cloud needs for `r`."""
    var have = image_platform(r)
    if have.byte_length() == 0:
        return
    var need = cloud.required_artifact(r)
    if need.platform != have:
        var kind = workload_of(r).value().kind.copy()
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                kind + String(".image.platform"),
                String("platform \"")
                + have
                + String("\" is not deployable on cloud \"")
                + cloud.cloud_id().text()
                + String("\": it runs ")
                + need.kind
                + String(" for ")
                + need.platform
                + String(" (an empty platform means ")
                + String(V1_IMAGE_PLATFORM)
                + String(")"),
            )
        )


def validate_for[
    S: CloudAdapter
](
    clouds: Clouds,
    cloud: S,
    resources: List[Resource],
    definitions: List[CompositeDefinition] = List[CompositeDefinition](),
) raises -> List[Finding]:
    """Every finding of `resources` on `cloud`: the expansion's (with the
    composite `definitions` it was given) alone if it has any, else, on
    the expanded list, graph, coverage, limits, and, on a graph with none
    of those, the cloud names and the role label budget of `cloud`'s
    lowering. Raises only if `cloud` is not one of `clouds` (`main` built
    an adapter it did not list: a wiring defect, not a property of the
    graph; the message is `Clouds.resolve`'s), or on a defect of the
    expansion itself (`expand`)."""
    if clouds.find(cloud.cloud_id()) < 0:
        _ = clouds.resolve(cloud.cloud_id().text())  # raises, naming the built-in clouds
    var x = expand(clouds.catalog, definitions, resources)
    if len(x.findings) > 0:
        return x.findings.copy()
    return validate_expanded(clouds, cloud, x.resources, x.produced)


def validate_expanded[
    S: CloudAdapter
](clouds: Clouds, cloud: S, resources: List[Resource], produced: List[String]) raises -> List[Finding]:
    """`validate_for` of a list that is already expanded: `produced` names
    the ids the expansion made (`Expansion.produced`)."""
    var pid = cloud.cloud_id()
    var e = clouds.find(pid)
    if e < 0:
        _ = clouds.resolve(pid.text())  # raises, naming the built-in clouds
        raise Error(String("unreachable: ") + pid.text())
    ref entry = clouds.entries[e]
    var out = graph_findings(clouds.catalog, resources, produced)
    var feeds = feeds_of(resources)
    var firings = firings_of(resources)
    for i in range(len(resources)):
        ref r = resources[i]
        var field: Int
        try:
            field = body_field(r)
        except:
            continue  # already a graph finding
        var t = clouds.catalog.index_of(field)
        if t < 0:
            continue
        if entry.implements(field):
            var limits = cloud.check(r, feeds, firings)
            var public_refused = False
            for k in range(len(limits)):
                if limits[k].field_path == "service.public":
                    public_refused = True
                out.append(limits[k].copy())
            _check_platform(cloud, r, out)
            if (
                not public_refused
                and field == FIELD_SERVICE
                and r.service.value()._oneof0_case == 1
                and cloud.public_mechanism().byte_length() == 0
            ):
                out.append(
                    Finding(
                        FINDING_LIMIT,
                        r.id,
                        String("service.public"),
                        String("this cell's settings choose no public mechanism")
                        + String(" on cloud \"")
                        + pid.text()
                        + String("\"; kci never picks one at apply time"),
                    )
                )
            continue
        ref ct = clouds.catalog.types[t]
        var why = String("no adapter")
        var a = entry.absence_of(field)
        if a:
            why = absence_word(a.value().kind) + String(": ") + a.value().reason
        var hosts = clouds.implementers(field)
        var listed = String("none")
        if len(hosts) > 0:
            listed = hosts[0].copy()
            for h in range(1, len(hosts)):
                listed += String(", ") + hosts[h]
        out.append(
            Finding(
                FINDING_COVERAGE,
                r.id,
                String(""),
                ct.name
                + String(" (")
                + portability_word(ct.portability)
                + String("): no adapter in cloud \"")
                + pid.text()
                + String("\" (")
                + why
                + String(")\n      clouds built into this kci that implement it: ")
                + listed,
            )
        )
    if len(out) == 0:  # lower only a graph with no other finding
        out.extend(shared_name_findings(cloud, clouds.catalog, resources, feeds, firings))
        out.extend(lowered_budget_findings(cloud, resources, feeds, firings))
    return out^


def refusal_text(cloud: CloudId, findings: List[Finding]) -> String:
    """The one rendering of a refused graph."""
    var s = (
        String("kci: cannot apply this graph to cloud \"")
        + cloud.text()
        + String("\". Nothing was created.")
    )
    for i in range(len(findings)):
        ref f = findings[i]
        s += String("\n  resource \"") + f.resource_id + String("\"")
        if f.field_path.byte_length() > 0:
            s += String(" field ") + f.field_path
        s += String(": ") + f.reason
        if f.citation.byte_length() > 0:
            s += String(" (citation: ") + f.citation + String(")")
        if f.unverified:
            s += String(" [unverified]")
    return s^


def node_role(node: LoweredNode) -> String:
    """The role a node is stamped with: its id after `<owner>/`. A node whose
    id does not start with its owner (the lowering contract refuses it) is
    measured whole."""
    var prefix = node.owner + String("/")
    if node.owner.byte_length() > 0 and node.id.startswith(prefix):
        return String(node.id[byte = prefix.byte_length() : node.id.byte_length()])
    return node.id.copy()


def lowered_budget_findings[
    S: CloudAdapter
](cloud: S, resources: List[Resource], feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
    """`role_budget_findings` of every node `cloud` lowers `resources` to
    (data, nothing realized), each owned by the first segment of its
    resource's id as `deploy.lower_data` stamps it, so the role measured is
    the whole path below the top (`a/b/c/run` of `top/a/b/c`). A resource
    whose lowering raises is skipped: the lowering contract refuses it at
    plan."""
    var nodes = List[LoweredNode]()
    for i in range(len(resources)):
        ref r = resources[i]
        var low: List[LoweredNode]
        try:
            low = cloud.lower(r, edges_for(resources, r), feeds, firings)
        except:
            continue
        for k in range(len(low)):
            var n = low[k].copy()
            n.owner = owner_of_node(r.id)
            nodes.append(n^)
    return role_budget_findings(nodes)


def role_budget_findings(nodes: List[LoweredNode]) -> List[Finding]:
    """A GRAPH finding for every node whose role, encoded as a label value,
    is over `LABEL_VALUE_MAX` bytes: the node, the byte count and the length
    of each `/`-separated segment. Pure; empty when every role fits."""
    var out = List[Finding]()
    for i in range(len(nodes)):
        ref n = nodes[i]
        var role = node_role(n)
        var size = encoded_label_bytes(role)
        if size <= LABEL_VALUE_MAX:
            continue
        var segs = role.split("/")
        var lens = String("")
        for k in range(len(segs)):
            if k > 0:
                lens += String(", ")
            lens += String(segs[k].byte_length())
        out.append(
            Finding(
                FINDING_GRAPH,
                n.owner,
                String(""),
                String("node \"")
                + n.id
                + String("\": its role label is ")
                + String(size)
                + String(" bytes encoded; at most ")
                + String(LABEL_VALUE_MAX)
                + String(" (segment lengths ")
                + lens
                + String("; shorter ids or less nesting fit)"),
            )
        )
    return out^
