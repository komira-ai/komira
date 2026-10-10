# =============================================================================
# kci_cloud/adoption.mojo: safe adoption. What kci checks before it takes over
#   an object it did not create, and what it does with one when the file
#   lets go of it.
# =============================================================================
#
# `Resource.adopt` (metadata.mojo) puts the primary node of its resource in
# the scope's adopt list, so the engine stamps an unstamped object there
# instead of refusing it as foreign. This file makes that safe. Every rule
# below is a value test on what the cloud reports; no cloud is named.
#
# 1. VERIFY BEFORE PLANNING (`adoption_check`, plan and apply). For each
#    wanted node kci marked `adopted` (deploy.lower_data: the primary node of
#    a resource that writes `adopt`), kci asks the cloud what stands there
#    (`CloudAdapter.read_existing`):
#      - nothing: refused. `adopt` takes over an object that exists; a file
#        that wants kci to create it does not write `adopt`.
#      - an object carrying a kci stamp (any identity): not judged here. One
#        stamped for this node was adopted (or created) by an earlier run,
#        and from then on the file may change it like any of kci's objects;
#        one stamped for another owner is the engine's conflict refusal.
#      - an unstamped object: it must be what the node declares, or the
#        plan is refused with both sides named (`existing_mismatches`): the
#        same kind (`LoweredNode.kind`, the cloud's own vocabulary), the same
#        cloud name (`physical_name`), and, for every field of its shape the
#        adapter can read that the node also declares, the same value. The
#        author's labels (`label.*`) are not compared: an adoption writes
#        them. An adoption therefore never changes what it takes over: a
#        change is the next apply's, once the object is kci's.
#    The nodes that pass with an unstamped object are the ones this run
#    TAKES OVER (`AdoptionCheck.taking`).
# 2. THE ADOPTION MARK. kci did not create an adopted object, so it is never
#    its to destroy unless the resource says so. An adapter's `adopt_owned`
#    writes `kci_adopted=true` on a node marked `adopted` (labels.mojo), and
#    `list_owned` reports it (`OwnedRecord.adopted`). The ADOPTED nodes of a
#    run (`adopted_nodes_of`) are the nodes it takes over and every node
#    whose object carries the mark.
# 3. REFUSE DESTRUCTIVE CHANGES. kci refuses, before any change:
#      - a DELETE of an object carrying the mark (`delete_findings`), unless
#        its resource writes `adopt` ADOPT_DELETABLE (`Adoption` 2): on plan
#        and apply, a node the file turned off or a role its resource no
#        longer lowers (the resource is still in the list: its type
#        changed); on destroy, every node of the file. A node whose
#        retention in this run is not delete (the file's, which is what the
#        engine deletes by) is never deleted, so it is not refused.
#      - a REPLACE of an adopted node (`replace_findings`), at either value
#        of `adopt`: the engine plans it when the cloud cannot make a change
#        in place, and its apply cannot replace anything (it stops at such a
#        node), so ADOPT_DELETABLE allows a delete and never a replace. Apply
#        plans first when the run has adopted nodes, so it refuses before
#        any change too.
#        A node the plan reports as known after apply (a producer of it
#        changes in this run) is not read by the plan, so a replace of it is
#        not known before the apply and is not refused here. The engine's
#        apply never replaces an object: a drift it cannot converge in place
#        stops the apply at that node, after the nodes before it landed, and
#        the adopted object stands.
#    The resource whose `adopt` counts for a delete is the one the node
#    belongs to (`resource_of_node`: the longest resource id that prefixes
#    it).
# 3b. A MARKED OBJECT IS NEVER TAKEN FOR KCI'S OWN (`unadopted_findings`,
#    plan and apply): an object carrying the stamp and the mark whose wanted
#    node belongs to a resource that does not write `adopt` (a release
#    whose cloud call failed leaves the object so, its record retired) is
#    refused before any change, as a clean release would have left it
#    foreign. With `adopt` written again, kci keeps managing it as adopted.
# 4. RELEASE, NEVER DELETE, WHEN THE RESOURCE LEAVES THE LIST (deploy.mojo's
#    `removals`). An object carrying the mark whose resource is no longer in
#    the (expanded) list is RELEASED: the apply retires its state record,
#    then asks the cloud to drop every kci label of it
#    (`CloudAdapter.release`). A failure at either step leaves the object
#    stamped and marked, so the next apply releases it again.
#    No delete call reaches the adapter, the object stands as kci last left
#    it (with the fields and the author's labels kci wrote; only kci's own
#    labels are dropped), and a later file that names it again meets an
#    unstamped object. A plan
#    reports each release; a destroy, which acts only on the file's nodes,
#    leaves it to the apply.
# 5. THE PLAN SAYS SO (`PlanReport`, deploy.render_plan): each adopted node
#    is marked `(adopted)` beside its verb, and each release is a line of
#    its own.
#
# NOT DONE HERE. A capability that no flag lifts ("kci can never delete
# this", whatever the file says) is a different thing: ADOPT_DELETABLE is
# the author's choice per resource. An adoption made through the engine's
# own adopt list alone (the conformance kit) writes no mark and is not
# verified; no kci verb sets that list but `with_adopted`.
# =============================================================================

from kci_reconciler import ChangeAction, Creds, RETAIN_DELETE, VERB_REPLACE
from kci_resource_proto.resource import Adoption, Resource

from kci_cloud.adapter import (
    CloudAdapter,
    ExistingObject,
    FINDING_ADOPTION,
    Finding,
    LoweredNode,
    OwnedRecord,
)
from kci_cloud.compose_refs import owner_of_node
from kci_cloud.metadata import LABEL_FIELD_PREFIX, PHYSICAL_NAME_FIELD, adopts


def resource_of_node(resources: List[Resource], node_id: String) -> Int:
    """The index of the resource node `node_id` belongs to: the longest
    resource id `r` with `node_id` starting `r/`; -1 when no resource of
    `resources` lowers it (its resource left the list)."""
    var best = -1
    var best_len = -1
    for i in range(len(resources)):
        var prefix = resources[i].id + String("/")
        if node_id.startswith(prefix) and prefix.byte_length() > best_len:
            best = i
            best_len = prefix.byte_length()
    return best


def deletable(resources: List[Resource], node_id: String) -> Bool:
    """True iff the resource node `node_id` belongs to writes `adopt`
    ADOPT_DELETABLE."""
    var i = resource_of_node(resources, node_id)
    return i >= 0 and resources[i].adopt.value == Adoption.ADOPT_DELETABLE


def _shown(v: String) -> String:
    if v.byte_length() == 0:
        return String("none")
    return String("\"") + v + String("\"")


def existing_mismatches(node: LoweredNode, seen: ExistingObject) -> List[String]:
    """Every way the unstamped object `seen` differs from what `node`
    declares, each naming both sides: its kind, its cloud name, and each
    field `seen` reports that `node` also declares (not the author's
    labels)."""
    var out = List[String]()
    if seen.kind != node.kind:
        out.append(
            String("kind: the resource declares ") + _shown(node.kind) + String(", the cloud holds ")
            + _shown(seen.kind)
        )
    var want = node.field(String(PHYSICAL_NAME_FIELD))
    if seen.name != want:
        out.append(
            String("cloud name: the resource declares ") + _shown(want) + String(", the cloud holds ")
            + _shown(seen.name)
        )
    for i in range(len(seen.fields)):
        ref key = seen.fields[i].key
        if key == PHYSICAL_NAME_FIELD or key.startswith(LABEL_FIELD_PREFIX):
            continue
        for k in range(len(node.desired)):
            if node.desired[k].key != key:
                continue
            if node.desired[k].value != seen.fields[i].value:
                out.append(
                    key + String(": the resource declares ") + _shown(node.desired[k].value)
                    + String(", the cloud holds ") + _shown(seen.fields[i].value)
                )
            break
    return out^


struct AdoptionCheck(Movable):
    """What `adoption_check` found: the refusals, and the nodes this run takes
    over (an unstamped object that is what the node declares)."""

    var findings: List[Finding]
    var taking: List[String]

    def __init__(out self):
        self.findings = List[Finding]()
        self.taking = List[String]()


def adoption_check[
    S: CloudAdapter
](mut cloud: S, creds: Creds, nodes: List[LoweredNode]) raises -> AdoptionCheck:
    """Rule 1 of the file header, over every wanted node marked `adopted`."""
    var out = AdoptionCheck()
    for i in range(len(nodes)):
        ref node = nodes[i]
        if not node.adopted or not node.wanted:
            continue
        var seen = cloud.read_existing(creds, node)
        var name = node.field(String(PHYSICAL_NAME_FIELD))
        if not seen.present:
            out.findings.append(
                Finding(
                    FINDING_ADOPTION,
                    node.owner,
                    String("adopt"),
                    node.id + String(": the resource adopts ") + node.kind + String(" ") + _shown(name)
                    + String(", and cloud \"") + cloud.cloud_id().text()
                    + String("\" holds no such object. adopt takes over an object that exists; to have kci")
                    + String(" create it, do not write adopt"),
                )
            )
            continue
        if seen.stamped:
            continue
        var diff = existing_mismatches(node, seen)
        if len(diff) == 0:
            out.taking.append(node.id.copy())
            continue
        var why = node.id + String(": the object cloud \"") + cloud.cloud_id().text() + String(
            "\" holds is not the one the resource adopts ("
        )
        for k in range(len(diff)):
            if k > 0:
                why += String("; ")
            why += diff[k]
        why += String("). kci takes over only the object the file declares; write what stands there")
        out.findings.append(Finding(FINDING_ADOPTION, node.owner, String("adopt"), why))
    return out^


def adopted_nodes_of(owned: List[OwnedRecord], taking: List[String]) -> List[String]:
    """Rule 2: the nodes this run takes over, then every node whose object
    carries the adoption mark, each once."""
    var out = taking.copy()
    for i in range(len(owned)):
        if not owned[i].adopted:
            continue
        var seen = False
        for k in range(len(out)):
            if out[k] == owned[i].owner_node:
                seen = True
                break
        if not seen:
            out.append(owned[i].owner_node.copy())
    return out^


comptime _RELEASE_HINT = (
    "remove the resource from the list to release the object (kci drops its stamp and record and leaves it standing)"
)


def _refusal(node_id: String, what: String) -> String:
    return (
        node_id + String(": kci adopted this object (it did not create it), and ") + what
        + String(". Write adopt ADOPT_DELETABLE on the resource to let kci do that, or ")
        + String(_RELEASE_HINT)
    )


def delete_findings(
    nodes: List[LoweredNode], owned: List[OwnedRecord], resources: List[Resource], destroy: Bool
) -> List[Finding]:
    """Rule 3, DELETE: one finding per object carrying the adoption mark that
    this run would delete (`nodes` holds the lowering and the roles to
    remove; on `destroy` every node of it is deleted, else only a node not
    wanted), unless the node's retention in this run is not RETAIN_DELETE
    (the engine deletes by it, not by the object's label) or its resource
    writes `adopt` ADOPT_DELETABLE."""
    var out = List[Finding]()
    for i in range(len(owned)):
        ref rec = owned[i]
        if not rec.adopted:
            continue
        for k in range(len(nodes)):
            ref n = nodes[k]
            if n.id != rec.owner_node:
                continue
            # The engine deletes by the node's retention in this run (the
            # file's), not by the label the object carries, so a node it
            # would keep or cannot delete is the one skipped here.
            if n.retention != RETAIN_DELETE:
                break
            if (destroy or not n.wanted) and not deletable(resources, n.id):
                var what = String("this destroy would delete it") if destroy else String(
                    "this change would delete it (the resource no longer lowers it)"
                )
                out.append(
                    Finding(FINDING_ADOPTION, owner_of_node(n.id), String("adopt"), _refusal(n.id, what))
                )
            break
    return out^


def unadopted_findings(
    nodes: List[LoweredNode], owned: List[OwnedRecord], resources: List[Resource]
) -> List[Finding]:
    """Rule 3b: one finding per object carrying the adoption mark whose
    wanted node belongs to a resource that does not write `adopt`."""
    var out = List[Finding]()
    for i in range(len(owned)):
        ref rec = owned[i]
        if not rec.adopted:
            continue
        for k in range(len(nodes)):
            ref n = nodes[k]
            if n.id != rec.owner_node:
                continue
            var r = resource_of_node(resources, n.id)
            if n.wanted and r >= 0 and not adopts(resources[r]):
                out.append(
                    Finding(
                        FINDING_ADOPTION,
                        owner_of_node(n.id),
                        String("adopt"),
                        n.id
                        + String(": the object carries kci's adoption mark (kci adopted it and did not create it),")
                        + String(" and the resource does not write adopt. kci does not take an adopted object for its")
                        + String(" own: write adopt ADOPT on the resource to keep it adopted, or ")
                        + String(_RELEASE_HINT),
                    )
                )
            break
    return out^


def replace_findings(actions: List[ChangeAction], adopted: List[String]) -> List[Finding]:
    """Rule 3, REPLACE: one finding per planned replace of an adopted node,
    whatever its resource's `adopt` says."""
    var out = List[Finding]()
    for i in range(len(actions)):
        ref a = actions[i]
        if a.verb != VERB_REPLACE:
            continue
        for k in range(len(adopted)):
            if adopted[k] != a.logical_id:
                continue
            out.append(
                Finding(
                    FINDING_ADOPTION,
                    owner_of_node(a.logical_id),
                    String("adopt"),
                    a.logical_id
                    + String(": kci adopted this object (it did not create it), and this change would replace it")
                    + String(" (the cloud cannot make it in place: ") + a.reason
                    + String("). kci never replaces an adopted object, whatever adopt says: write the field as")
                    + String(" the object has it, or ") + String(_RELEASE_HINT),
                )
            )
            break
    return out^


struct PlanReport(Movable):
    """A plan, with what safe adoption adds to it: the engine's `actions`,
    the `adopted` nodes among them (rule 2), and the nodes the apply will
    `released` (rule 4)."""

    var actions: List[ChangeAction]
    var adopted: List[String]
    var released: List[String]

    def __init__(
        out self,
        var actions: List[ChangeAction],
        var adopted: List[String] = List[String](),
        var released: List[String] = List[String](),
    ):
        self.actions = actions^
        self.adopted = adopted^
        self.released = released^
