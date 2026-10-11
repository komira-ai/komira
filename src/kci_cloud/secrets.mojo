# =============================================================================
# kci_cloud/secrets.mojo: the rules of the SECRET primitive, and of the
# `secret_env` references a workload makes to a secret.
# =============================================================================
#
# A `secret` resource is the CONTAINER of a secret value: kci creates it with
# no value, and never reads, writes or stores one. GRAPH findings, true on
# every cloud, that validate collects:
#
#   * on a `secret` (`secret_findings`): it runs as no identity, so it has no
#     `uses` lines (write the line on the workload that reads it, or on the
#     identity that writes it);
#   * on each `secret_env` entry of a workload (a service, a container job
#     or a worker; `secret_env_findings`), at `<arm>.secret_env.<KEY>`
#     (`service.secret_env.TOKEN`):
#       - the variable is not also set by `env` (the container would get one
#         of two values, and which one is the cloud's choice, not the
#         author's);
#       - the reference names EXACTLY ONE of a `name` (a secret that already
#         exists in the cell's store) and a `secret` (a `secret` resource of
#         the list): neither names nothing, and both name two secrets;
#       - a `secret` names a `secret` resource of the list, the resource
#         itself (never one of its outputs), and has no `store` beside it
#         (the resource is in the store its cloud puts it in);
#       - the identity the workload runs as (its own, or its `run_as`
#         account) holds READ or READ_WRITE on that secret, through a `uses`
#         line or a `grant`. THE REFERENCE IS NOT A GRANT: an edge that lets
#         an identity read a secret is printed in the plan like every other
#         edge, so the author writes it, and a reference without it is
#         refused rather than granted silently.
#
# A reference by `secret` is a value the run reads at apply time: the
# secret's NAME (an adapter writes it as an input on the secret's id, which
# kci resolves to `<id>/secret`), so the run is created after the secret.
# =============================================================================

from kci_resource_proto.refs import SecretRef
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import (
    ACCESS_READ,
    ACCESS_READ_WRITE,
    FIELD_SECRET,
)
from kci_cloud.grants import GrantEdge, edges_of, identity_owner
from kci_cloud.messaging import check_typed_ref
from kci_cloud.workload import workload_of


def secret_of(s: SecretRef) -> String:
    """The `secret` resource id a reference names, or empty for one by
    name."""
    if s.secret:
        return s.secret.value().resource.copy()
    return String("")


def secret_findings(field: Int, r: Resource) -> List[Finding]:
    """Every graph finding of the secret resource `r` (by its body `field`);
    empty for any other type."""
    var out = List[Finding]()
    if field != FIELD_SECRET:
        return out^
    if len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("uses"),
                String(
                    "a secret runs as no identity, so it cannot use another resource;"
                    " write the uses line on the workload that reads it, or on the"
                    " identity that writes it"
                ),
            )
        )
    return out^


def _reads(edges: List[GrantEdge], principal: String, secret: String) -> Bool:
    for i in range(len(edges)):
        ref e = edges[i]
        if e.principal != principal or e.target != secret or e.on_cell():
            continue
        if e.access == ACCESS_READ or e.access == ACCESS_READ_WRITE:
            return True
    return False


def _all_edges(resources: List[Resource]) -> List[GrantEdge]:
    """Every edge of the list; a resource whose edges are malformed (a graph
    finding of its own) contributes none."""
    var out = List[GrantEdge]()
    for i in range(len(resources)):
        try:
            out.extend(edges_of(resources[i]))
        except:
            pass
    return out^


def _has_id(resources: List[Resource], id: String) -> Bool:
    for i in range(len(resources)):
        if resources[i].id == id:
            return True
    return False


def _entry_findings(
    resources: List[Resource],
    edges: List[GrantEdge],
    r: Resource,
    path: String,
    also_in_env: Bool,
    s: SecretRef,
    mut out: List[Finding],
):
    var id = r.id.copy()
    if also_in_env:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                path,
                String("the variable is set by env and by secret_env; set it in one"),
            )
        )
    var named = s.name.byte_length() > 0
    if not named and not s.secret:
        out.append(Finding(FINDING_GRAPH, id, path, String("a secret reference with no name and no secret")))
        return
    if named and s.secret:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                path,
                String("a secret reference with both a name and a secret names two secrets; write one"),
            )
        )
        return
    if not s.secret:
        return
    if s.store:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                path + String(".store"),
                String(
                    "a secret resource is in the store its cloud puts it in; store is"
                    " only for a secret referenced by name"
                ),
            )
        )
    var before = len(out)
    check_typed_ref(resources, id, path + String(".secret"), s.secret.value(), FIELD_SECRET, String("secret"), out)
    if len(out) != before:
        return
    var owner = identity_owner(r)
    if owner.byte_length() == 0 or not _has_id(resources, owner):
        return  # a `run_as` that names nothing is a finding of its own
    var target = secret_of(s)
    if _reads(edges, owner, target):
        return
    out.append(
        Finding(
            FINDING_GRAPH,
            id,
            path + String(".secret"),
            String("identity \"")
            + owner
            + String("\" may not READ secret \"")
            + target
            + String("\": the reference is not a grant; write a uses line (or a grant)")
            + String(" giving it READ on \"")
            + target
            + String("\""),
        )
    )


def _sorted_keys(d: Dict[String, SecretRef]) -> List[String]:
    var keys = List[String]()
    for entry in d.items():
        keys.append(entry.key.copy())
    for i in range(1, len(keys)):
        var k = i
        while k > 0 and keys[k] < keys[k - 1]:
            var t = keys[k].copy()
            keys[k] = keys[k - 1].copy()
            keys[k - 1] = t^
            k -= 1
    return keys^


def secret_env_findings(resources: List[Resource], r: Resource) -> List[Finding]:
    """Every graph finding of the `secret_env` entries of the workload `r`,
    in key order; empty for any other type."""
    var out = List[Finding]()
    var w = workload_of(r)
    if not w:
        return out^
    var edges = _all_edges(resources)
    var kind = w.value().kind.copy()
    var secrets = w.value().secret_env.copy()
    var env = w.value().env.copy()
    var keys = _sorted_keys(secrets)
    for i in range(len(keys)):
        try:
            _entry_findings(
                resources,
                edges,
                r,
                kind + String(".secret_env.") + keys[i],
                keys[i] in env,
                secrets[keys[i]],
                out,
            )
        except:
            pass  # a key just read from the map is in it
    return out^
