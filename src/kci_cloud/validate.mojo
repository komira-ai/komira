# =============================================================================
# kci_cloud/validate.mojo: the validate phase.
# =============================================================================
#
# Runs before anything is lowered, planned or created, and needs no
# credentials. It collects EVERY finding in one pass, so an author sees all of
# their problems at once:
#
#   1. GRAPH findings, true on every cloud: ids (unique, and of the id
#      grammar `[a-z][a-z0-9-]{0,23}` with no trailing or doubled `-`, so
#      never the node-id separator `/`), a type set, every `Ref` naming a
#      resource of the list, an output the producer's type exposes, an access
#      verb the target's type accepts, values that are resolved (a build
#      output or a release parameter must have been substituted by the deploy
#      facade before a cloud ever sees the resource) in `env` of a service
#      AND of a job, a variable set by `env` or by `secret_env` but not both,
#      a secret reference with a name, and an image platform written as
#      `<os>/<cpu>` (empty means `linux/amd64`).
#   2. COVERAGE findings: the chosen cloud has no adapter for a type. The
#      text carries the cloud's typed absence and the built-in clouds
#      that do host the type.
#   3. LIMIT findings: the cloud hosts the type but refuses a value or a
#      shape (`CloudAdapter.check`), for example a public URL on a cloud
#      with no public ingress; the image's platform is not the one the cloud
#      needs for the type (`CloudAdapter.required_artifact`); or a `public {}`
#      service in a cell whose settings choose no public mechanism
#      (`CloudAdapter.public_mechanism`). The mechanism is chosen HERE, from
#      the cell's settings, and never fallen back on at apply time.
#
#   4. The ROLE LABEL BUDGET (`role_budget_findings`), the one check that
#      needs the lowering: every lowered node's role (the node id after its
#      owner) must fit the 63-byte label value once encoded. It is a GRAPH
#      finding naming the node, the byte count and every segment's length,
#      and it runs after lowering (data, nothing realized) and before
#      anything is created. Nesting is unbounded in the schema; this is its
#      practical bound.
#
# ⛔ A FINDING IS A REFUSAL OF THE WHOLE GRAPH. There is no "skip what the
# cloud cannot do": that turns "cannot do it yet" into a silently thinner
# deploy.
# =============================================================================

from kci_resource_proto.resource import Resource, Ref, Value

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
from kci_cloud.catalog import Catalog, body_field, portability_word
from kci_cloud.cloud_id import CloudId
from kci_cloud.clouds import Clouds
from kci_cloud.labels import LABEL_VALUE_MAX, encoded_label_bytes


def _index_of_id(resources: List[Resource], id: String) -> Int:
    for i in range(len(resources)):
        if resources[i].id == id:
            return i
    return -1


def _check_value_ref(
    catalog: Catalog,
    resources: List[Resource],
    owner: String,
    path: String,
    r: Ref,
    mut out: List[Finding],
):
    """A `Ref` used as a VALUE: it must name another resource of the list and
    one of the outputs that resource's type exposes."""
    if r.resource == owner:
        out.append(
            Finding(FINDING_GRAPH, owner, path, String("refers to its own resource"))
        )
        return
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
    if r._oneof0_case == 2:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String(
                    "a named output is only for the escape hatch, which this kci"
                    " does not have"
                ),
            )
        )
        return
    if r._oneof0_case != 1:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("a value ref must name an output of \"")
                + r.resource
                + String("\""),
            )
        )
        return
    var output = r.standard.value().json_name()
    var field: Int
    try:
        field = body_field(resources[p])
    except:
        return  # the producer's own missing type is reported on the producer
    var t = catalog.index_of(field)
    if t < 0 or not catalog.types[t].exposes_output(output):
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("\"")
                + r.resource
                + String("\" (")
                + catalog.name_of(field)
                + String(") does not expose ")
                + output,
            )
        )


def _check_value(
    catalog: Catalog,
    resources: List[Resource],
    owner: String,
    path: String,
    v: Value,
    mut out: List[Finding],
):
    var arm = v._oneof0_case
    if arm == 1:
        return
    if arm == 3:
        _check_value_ref(catalog, resources, owner, path, v.ref_.value(), out)
        return
    if arm == 2:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("release parameter \"")
                + v.param.value()
                + String(
                    "\" is unresolved; parameters are substituted before a cloud"
                    " sees the graph"
                ),
            )
        )
        return
    out.append(Finding(FINDING_GRAPH, owner, path, String("has no value")))


comptime ID_MAX_BYTES = 24
"""The longest resource id. Narrowing later breaks authors; widening is free."""

comptime V1_IMAGE_PLATFORM = "linux/amd64"
"""What an empty `Image.platform` means (OS + CPU)."""


def id_problem(id: String) -> String:
    """Why `id` is not a legal resource id, or empty if it is. The grammar is
    `[a-z][a-z0-9-]{0,23}`, with no trailing `-` and no `--`: a lowercase
    letter first, then lowercase letters, digits and single dashes. It keeps
    every id usable in a cloud name or label after a prefix, and it never
    contains `/`, the engine's node-id separator."""
    var b = id.as_bytes()
    var n = len(b)
    if n == 0:
        return String("empty id")
    if n > ID_MAX_BYTES:
        return (
            String("id is ")
            + String(n)
            + String(" bytes; at most ")
            + String(ID_MAX_BYTES)
        )
    if Int(b[0]) < ord("a") or Int(b[0]) > ord("z"):
        return String("an id starts with a lowercase letter (a-z)")
    for i in range(n):
        var c = Int(b[i])
        var lower = c >= ord("a") and c <= ord("z")
        var digit = c >= ord("0") and c <= ord("9")
        if not lower and not digit and c != ord("-"):
            return String("an id is lowercase letters, digits and '-' only")
        if c == ord("-") and i > 0 and Int(b[i - 1]) == ord("-"):
            return String("an id may not contain '--'")
    if Int(b[n - 1]) == ord("-"):
        return String("an id may not end with '-'")
    return String("")


def image_platform(r: Resource) -> String:
    """The image platform of a service or a job, with the empty default
    filled in; empty when the resource has no image."""
    var p = String("")
    var has = False
    if r._oneof0_case == 1 and Bool(r.service.value().image):
        has = True
        p = r.service.value().image.value().platform.copy()
    elif r._oneof0_case == 2 and Bool(r.job.value().image):
        has = True
        p = r.job.value().image.value().platform.copy()
    if not has:
        return String("")
    if p.byte_length() == 0:
        return String(V1_IMAGE_PLATFORM)
    return p^


def _check_image(owner: String, path: String, r: Resource, mut out: List[Finding]):
    """Shared by the two v1 types: an image must be a content digest by now,
    and its platform written `<os>/<cpu>`. Whether a cloud runs that
    platform is the cloud's question (`required_artifact`, in
    `validate_for`)."""
    var has = False
    var arm = 0
    var platform = String("")
    if r._oneof0_case == 1 and Bool(r.service.value().image):
        has = True
        arm = r.service.value().image.value()._oneof0_case
        platform = r.service.value().image.value().platform.copy()
    elif r._oneof0_case == 2 and Bool(r.job.value().image):
        has = True
        arm = r.job.value().image.value()._oneof0_case
        platform = r.job.value().image.value().platform.copy()
    if has and platform.byte_length() > 0:
        var parts = platform.split("/")
        if (
            len(parts) != 2
            or parts[0].byte_length() == 0
            or parts[1].byte_length() == 0
        ):
            out.append(
                Finding(
                    FINDING_GRAPH,
                    owner,
                    path + String(".platform"),
                    String("platform \"")
                    + platform
                    + String("\" is not <os>/<cpu> (for example ")
                    + String(V1_IMAGE_PLATFORM)
                    + String(")"),
                )
            )
    if not has or arm == 0:
        out.append(Finding(FINDING_GRAPH, owner, path, String("no image")))
    elif arm == 1:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String(
                    "the image is a build output that was not resolved to a digest"
                    " before deploy"
                ),
            )
        )


def _check_secret(
    owner: String,
    path: String,
    also_in_env: Bool,
    name: String,
    mut out: List[Finding],
):
    """One `secret_env` entry: a reference with a name, to a variable that
    `env` does not also set (the container would get one of two values, and
    which one is the cloud's choice, not the author's)."""
    if also_in_env:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String(
                    "the variable is set by env and by secret_env; set it in one"
                ),
            )
        )
    if name.byte_length() == 0:
        out.append(Finding(FINDING_GRAPH, owner, path, String("a secret reference with no name")))


def graph_findings(catalog: Catalog, resources: List[Resource]) -> List[Finding]:
    """Every cloud-independent finding of `resources`."""
    var out = List[Finding]()
    for i in range(len(resources)):
        ref r = resources[i]
        var id = r.id.copy()
        var bad_id = id_problem(id)
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
        _check_image(id, tname + String(".image"), r, out)
        if field == 10:
            ref svc = r.service.value()
            for entry in svc.env.items():
                _check_value(
                    catalog,
                    resources,
                    id,
                    String("service.env.") + entry.key,
                    entry.value,
                    out,
                )
            for entry in svc.secret_env.items():
                _check_secret(
                    id,
                    String("service.secret_env.") + entry.key,
                    entry.key in svc.env,
                    entry.value.name,
                    out,
                )
        if field == 11:
            ref job = r.job.value()
            for entry in job.env.items():
                _check_value(
                    catalog,
                    resources,
                    id,
                    String("job.env.") + entry.key,
                    entry.value,
                    out,
                )
            for entry in job.secret_env.items():
                _check_secret(
                    id,
                    String("job.secret_env.") + entry.key,
                    entry.key in job.env,
                    entry.value.name,
                    out,
                )
        for u in range(len(r.uses)):
            var path = String("uses[") + String(u) + String("]")
            ref use = r.uses[u]
            if not use.target:
                out.append(Finding(FINDING_GRAPH, id, path, String("no target")))
                continue
            ref tgt = use.target.value()
            if tgt.resource == id:
                out.append(Finding(FINDING_GRAPH, id, path, String("uses itself")))
                continue
            var p = _index_of_id(resources, tgt.resource)
            if p < 0:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        path,
                        String("ref to missing resource \"") + tgt.resource + String("\""),
                    )
                )
                continue
            if tgt._oneof0_case != 0:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        path,
                        String("access is granted to a resource, not to one of its outputs"),
                    )
                )
            var access = use.access.json_name()
            var pfield: Int
            try:
                pfield = body_field(resources[p])
            except:
                continue
            var pt = catalog.index_of(pfield)
            if pt >= 0 and not catalog.types[pt].accepts_access(access):
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        path,
                        catalog.types[pt].name
                        + String(" \"")
                        + tgt.resource
                        + String("\" does not accept access ")
                        + access,
                    )
                )
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
        var kind = String("service") if r._oneof0_case == 1 else String("job")
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
](clouds: Clouds, cloud: S, resources: List[Resource]) raises -> List[Finding]:
    """Every finding of `resources` on `cloud`: graph, coverage, limits.
    Raises only if `cloud` is not one of `clouds` (`main` built an adapter
    it did not list: a wiring defect, not a property of the graph); the
    message is `Clouds.resolve`'s."""
    var pid = cloud.cloud_id()
    var e = clouds.find(pid)
    if e < 0:
        _ = clouds.resolve(pid.text())  # raises, naming the built-in clouds
        raise Error(String("unreachable: ") + pid.text())
    ref entry = clouds.entries[e]
    var out = graph_findings(clouds.catalog, resources)
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
            var limits = cloud.check(r)
            var public_refused = False
            for k in range(len(limits)):
                if limits[k].field_path == "service.public":
                    public_refused = True
                out.append(limits[k].copy())
            _check_platform(cloud, r, out)
            if (
                not public_refused
                and r._oneof0_case == 1
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
