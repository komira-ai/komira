# =============================================================================
# kci_cloud/metadata.mojo: the rules of the METADATA every resource may carry.
# =============================================================================
#
# Three fields of `Resource`, the same on every type that takes them:
#
#   * `labels` 7: the author's labels. GRAPH findings, true on every cloud
#     (`metadata_findings`), because a file must deploy on any cloud and the
#     rule is the strictest the built-in clouds share:
#       - a key is 1 to 63 bytes of `[a-z0-9_-]`, starting with a letter and
#         ending with a letter or a digit;
#       - a value is empty, or 1 to 63 bytes of `[a-z0-9_-]` starting and
#         ending with a letter or a digit;
#       - a key in kci's own label space (starting `kci_`, where the
#         identity stamp lives, or `kci-`, where the run-id and retention
#         marks live) is refused: an author's label could otherwise forge
#         whose an object is, which validation run made it, or whether it is
#         kept.
#     How many labels an object carries beside kci's own
#     (`KCI_LABELS_MAX`) is a limit of each cloud, refused by its `check`.
#   * `physical_name` 6: the cloud name of the resource's PRIMARY object.
#     GRAPH findings: written only on a type whose catalog row takes a name
#     (`CatalogType.takes_name`: not a grant, not a DNS record); never
#     written empty; of the portable name grammar (`NAME_MAX_BYTES` bytes at
#     most of `[a-z0-9-]`, a letter first, a letter or a digit last, no
#     `--`), narrow on purpose: widening it later is free, narrowing it
#     breaks authors; and one name per object: two resources of one type
#     may not write the same name. A cloud that takes fewer bytes, or more
#     at least, or that has no name of its own for a kind, refuses it as
#     its limit.
#     ONE NAME PER KIND ON A CLOUD (`shared_name_findings`, a LIMIT finding
#     of validate): two types may lower their primary objects to one cloud
#     kind (a service and a worker that are both one kind of container app
#     on a cloud), so two resources of two types writing one name would
#     collide there partway through an apply. Validate lowers each named
#     resource the cloud hosts and passes (data, nothing realized) and
#     refuses the second name of a (kind, name) pair, the kind read from the
#     cloud's own lowering: a value, never a cloud's name.
#   * `adopt` 8: take over the existing object named `physical_name`, so it
#     must be written. kci adds the resource's primary node to the scope's
#     adopt list (`with_adopted`) on plan and apply; the engine then stamps
#     an unstamped object of that node instead of refusing it as foreign
#     (ownership.mojo's table), and absent, creates it. Destroy ignores the
#     adopt list (an adoption is never a reason to delete), so an object a
#     destroy meets unstamped is still refused. The other roles of the
#     resource are created as usual. An adopted object is the resource's
#     from then on, like one kci created: the closed world and the
#     resource's retention apply to it.
#
# LOWERING. These are kci's, not the cloud's (`deploy.lower_data` writes
# them after the adapter lowers): every node of the resource gets one
# desired field `label.<key>` per label, sorted by key (`label_fields`); the
# primary node gets `physical_name` when it is written. They are desired
# state like any other field: a changed label is an update.
#
# A NAME IS FIXED WHEN ITS OBJECT IS CREATED. `list_owned` reports the
# author's name each object was created under (`OwnedRecord.name`, empty for
# a name the adapter chose); a wanted node that asks for another one is
# refused before any change (`name_change_findings`), on plan, apply and
# destroy alike: a new name is a new object, and an update cannot rename it.
# =============================================================================

from kci_resource_proto.resource import Resource

from kci_cloud.adapter import CloudAdapter, FINDING_GRAPH, FINDING_LIMIT, Finding, LoweredNode, OwnedRecord, Setting
from kci_cloud.catalog import Catalog, body_field, primary_node
from kci_cloud.feed import Feed
from kci_cloud.firing import Firing
from kci_cloud.grants import edges_for

comptime LABEL_FIELD_PREFIX = "label."
"""The desired-field prefix of an author's label (`label.<key>`)."""
comptime PHYSICAL_NAME_FIELD = "physical_name"
"""The desired field of the primary node that holds the author's cloud
name."""
comptime LABEL_MAX_BYTES = 63
"""The longest label key or value."""
comptime NAME_MAX_BYTES = 63
"""The longest cloud name of the portable grammar."""
comptime KCI_LABELS_MAX = 8
"""The most labels kci writes on one object itself: the six identity labels
of the stamp, the run-id mark and the retention mark (labels.mojo). A cloud
that carries N labels on an object carries N - KCI_LABELS_MAX of the
author's."""


def _lower(c: Int) -> Bool:
    return c >= ord("a") and c <= ord("z")


def _alnum(c: Int) -> Bool:
    return _lower(c) or (c >= ord("0") and c <= ord("9"))


def label_key_problem(key: String) -> String:
    """Why `key` is not a label key every cloud takes, or empty if it is."""
    var b = key.as_bytes()
    var n = len(b)
    if n == 0:
        return String("a label key is not empty")
    if n > LABEL_MAX_BYTES:
        return String("a label key is at most ") + String(LABEL_MAX_BYTES) + String(" bytes; this one is ") + String(n)
    if key.startswith("kci_") or key.startswith("kci-"):
        return String(
            "a label key starting kci_ or kci- is kci's own (the identity stamp and its"
            " marks); an author's label may not write it"
        )
    if not _lower(Int(b[0])):
        return String("a label key starts with a lowercase letter (a-z)")
    for i in range(n):
        var c = Int(b[i])
        if not _alnum(c) and c != ord("_") and c != ord("-"):
            return String("a label key is lowercase letters, digits, '_' and '-' only")
    if not _alnum(Int(b[n - 1])):
        return String("a label key ends with a letter or a digit")
    return String("")


def label_value_problem(value: String) -> String:
    """Why `value` is not a label value every cloud takes, or empty if it
    is. An empty value is legal."""
    var b = value.as_bytes()
    var n = len(b)
    if n == 0:
        return String("")
    if n > LABEL_MAX_BYTES:
        return String("a label value is at most ") + String(LABEL_MAX_BYTES) + String(" bytes; this one is ") + String(n)
    for i in range(n):
        var c = Int(b[i])
        if not _alnum(c) and c != ord("_") and c != ord("-"):
            return String("a label value is lowercase letters, digits, '_' and '-' only")
    if not _alnum(Int(b[0])) or not _alnum(Int(b[n - 1])):
        return String("a label value starts and ends with a letter or a digit")
    return String("")


def physical_name_problem(name: String) -> String:
    """Why `name` is not a cloud name of the portable grammar, or empty if
    it is."""
    var b = name.as_bytes()
    var n = len(b)
    if n == 0:
        return String("physical_name is written empty; leave it unset to let the cloud name the object")
    if n > NAME_MAX_BYTES:
        return String("a cloud name is at most ") + String(NAME_MAX_BYTES) + String(" bytes; this one is ") + String(n)
    if not _lower(Int(b[0])):
        return String("a cloud name starts with a lowercase letter (a-z)")
    for i in range(n):
        var c = Int(b[i])
        if not _alnum(c) and c != ord("-"):
            return String("a cloud name is lowercase letters, digits and '-' only")
        if c == ord("-") and i > 0 and Int(b[i - 1]) == ord("-"):
            return String("a cloud name may not contain '--'")
    if not _alnum(Int(b[n - 1])):
        return String("a cloud name ends with a letter or a digit")
    return String("")


def sorted_label_keys(r: Resource) -> List[String]:
    """The keys of `r.labels`, sorted (byte order)."""
    var keys = List[String]()
    for entry in r.labels.items():
        keys.append(entry.key.copy())
    for i in range(1, len(keys)):
        var j = i
        while j > 0 and keys[j] < keys[j - 1]:
            var t = keys[j].copy()
            keys[j] = keys[j - 1].copy()
            keys[j - 1] = t^
            j -= 1
    return keys^


def label_fields(r: Resource) raises -> List[Setting]:
    """One desired field `label.<key>` per label of `r`, sorted by key."""
    var out = List[Setting]()
    var keys = sorted_label_keys(r)
    for i in range(len(keys)):
        out.append(Setting(String(LABEL_FIELD_PREFIX) + keys[i], r.labels[keys[i]]))
    return out^


def metadata_findings(catalog: Catalog, resources: List[Resource], r: Resource) -> List[Finding]:
    """Every graph finding of `r`'s metadata (the file header)."""
    var out = List[Finding]()
    var keys = sorted_label_keys(r)
    for i in range(len(keys)):
        var why = label_key_problem(keys[i])
        if why.byte_length() > 0:
            out.append(Finding(FINDING_GRAPH, r.id, String("labels.") + keys[i], why))
        var value = String("")
        try:
            value = r.labels[keys[i]]
        except:
            pass
        var bad = label_value_problem(value)
        if bad.byte_length() > 0:
            out.append(Finding(FINDING_GRAPH, r.id, String("labels.") + keys[i], bad))
    var tname = String("")
    var takes = True
    var field = 0
    try:
        field = body_field(r)
        var t = catalog.index_of(field)
        if t >= 0:
            tname = catalog.types[t].name.copy()
            takes = catalog.types[t].takes_name
    except:
        pass  # no type: a graph finding of its own
    if r.physical_name:
        ref name = r.physical_name.value()
        if not takes:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    r.id,
                    String("physical_name"),
                    String("a ") + tname + String(" has no cloud name of its own to write"),
                )
            )
        else:
            var why = physical_name_problem(name)
            if why.byte_length() > 0:
                out.append(Finding(FINDING_GRAPH, r.id, String("physical_name"), why))
            else:
                for k in range(len(resources)):
                    ref other = resources[k]
                    if other.id == r.id:
                        break
                    if not other.physical_name or other.physical_name.value() != name:
                        continue
                    var same = False
                    try:
                        same = body_field(other) == field
                    except:
                        pass
                    if same:
                        out.append(
                            Finding(
                                FINDING_GRAPH,
                                r.id,
                                String("physical_name"),
                                String("\"") + name + String("\" is also the cloud name of ") + tname
                                + String(" \"") + other.id + String("\"; one name names one object"),
                            )
                        )
                        break
    if r.adopt and not r.physical_name:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("adopt"),
                String("adopt takes over the existing object named physical_name, and none is written"),
            )
        )
    return out^


def name_change_findings(nodes: List[LoweredNode], owned: List[OwnedRecord]) -> List[Finding]:
    """One finding per wanted node whose object (`owned`, as the cloud
    reports it) was created under another author's name than the one the
    node now asks for (empty on either side: the adapter's own name)."""
    var out = List[Finding]()
    for i in range(len(owned)):
        ref rec = owned[i]
        for k in range(len(nodes)):
            ref n = nodes[k]
            if n.id != rec.owner_node or not n.wanted:
                continue
            var want = n.field(String(PHYSICAL_NAME_FIELD))
            if want != rec.name:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        n.owner,
                        String("physical_name"),
                        String("the cloud name of ") + n.id + String(" changed from ") + _shown(rec.name)
                        + String(" to ") + _shown(want)
                        + String(
                            ": a cloud name is fixed when its object is created (a new name is a"
                            " new object). Write the name it has, or give the resource a new id"
                        ),
                    )
                )
            break
    return out^


def _shown(name: String) -> String:
    if name.byte_length() == 0:
        return String("the cloud's own")
    return String("\"") + name + String("\"")


def adopted_nodes(catalog: Catalog, resources: List[Resource]) raises -> List[String]:
    """The primary node of every resource that writes `adopt`. Raises for a
    resource of no catalog type (validate refuses it first)."""
    var out = List[String]()
    for i in range(len(resources)):
        ref r = resources[i]
        if not r.adopt:
            continue
        out.append(primary_node(catalog, resources, r.id))
    return out^


def shared_name_findings[
    S: CloudAdapter
](
    cloud: S,
    catalog: Catalog,
    resources: List[Resource],
    feeds: List[Feed],
    firings: List[Firing],
) -> List[Finding]:
    """One LIMIT finding per resource whose primary object, lowered by
    `cloud`, is of the same kind and writes the same `physical_name` as an
    earlier resource's (the file header). Validate calls this only on a
    graph with no other finding, so every resource is one the cloud hosts
    and takes. A resource whose lowering raises, or that lowers no primary
    node, is skipped: the lowering contract refuses it at plan."""
    var kinds = List[String]()
    var names = List[String]()
    var owners = List[String]()
    var out = List[Finding]()
    for i in range(len(resources)):
        ref r = resources[i]
        if not r.physical_name:
            continue
        var kind = String("")
        try:
            var primary = primary_node(catalog, resources, r.id)
            var nodes = cloud.lower(r, edges_for(resources, r), feeds, firings)
            for n in range(len(nodes)):
                if nodes[n].id == primary:
                    kind = nodes[n].kind.copy()
                    break
        except:
            continue
        if kind.byte_length() == 0:
            continue
        ref name = r.physical_name.value()
        for k in range(len(kinds)):
            if kinds[k] == kind and names[k] == name:
                out.append(
                    Finding(
                        FINDING_LIMIT,
                        r.id,
                        String("physical_name"),
                        String("\"") + name + String("\" is also the cloud name of \"") + owners[k]
                        + String("\": on cloud \"") + cloud.cloud_id().text() + String("\" both are ") + kind
                        + String(", and one name names one object of a kind"),
                    )
                )
                break
        kinds.append(kind^)
        names.append(name.copy())
        owners.append(r.id.copy())
    return out^
