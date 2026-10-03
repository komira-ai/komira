# =============================================================================
# kci_cloud_mem/nodes.mojo: the engine node the reference clouds realize.
# =============================================================================
#
# One node type, `MemNode`, realized from a `LoweredNode` (data):
#
#   * kind `run`       `<id>/run`: the running thing of a service or a job.
#                      Its desired digest renders every modelled field (the
#                      lowered node's `desired` fields, defaults filled in),
#                      then each `Ref` value as it resolved; with a reference
#                      not yet bound it has NO digest (UNBOUND), never a
#                      placeholder. A service's run node exposes URL and HOST.
#   * kind `public`    `<id>/public`: the public ingress of a service, by the
#                      mechanism the cell chose at validate time.
#   * kind `schedule`  `<id>/schedule`: the trigger of a scheduled job.
#   * kind `grant`     `<id>/uses/<target>`: one `Uses` line.
# A role the file turned off is the same node with `wanted` False.
#
# Every node is born stamped (`create_owned` writes the standard label rule's
# labels and the provenance annotation in the one create call), reads its
# stamp back from the labels, reports an out-of-band value on an unmodelled
# field as an unmanaged difference, and never puts provenance in its digest.
# =============================================================================

from std.memory import ArcPointer

from kci_reconciler import (
    ChangeAction,
    Creds,
    InputRef,
    Label,
    ModelledDigest,
    OwnerStamp,
    Outputs,
    Resource as EngineResource,
    ResolvedInputs,
    ResourceStatus,
    CONVERGE_IN_PLACE,
    RES_ABSENT,
    RES_FAILED,
    RETAIN_DELETE,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
    unbound_error,
)
from kci_cloud import LoweredNode, standard_identity_of, standard_label_rule

from kci_cloud_mem.mem_store import MemStore, MemView


def mem_url(resource_id: String) -> String:
    return String("mem://") + resource_id


def mem_host(resource_id: String) -> String:
    return resource_id + String(".mem")


def _plan(id: String, live: ResourceStatus) -> ChangeAction:
    var verb = VERB_UPDATE
    var why = String("drifted -> update")
    if live.phase == RES_ABSENT:
        verb = VERB_CREATE
        why = String("absent -> create")
    elif live.is_matched():
        verb = VERB_NOOP
        why = String("matched")
    return ChangeAction(id, verb, why, RETAIN_DELETE)


def _unmanaged(v: MemView) -> String:
    if v.extra.byte_length() == 0:
        return String("")
    return String("label ") + v.extra + String(" (not modelled; left as it is)")


def static_digest(node: LoweredNode) raises -> String:
    """The digest of a lowered node's own desired fields, in order (the
    `serves` field is how the node behaves, not state)."""
    var d = ModelledDigest(node.kind)
    for i in range(len(node.desired)):
        if node.desired[i].key == "serves":
            continue
        d.field(node.desired[i].key, node.desired[i].value)
    return d.text()


struct MemNode(EngineResource, Movable, Deinitable):
    var _store: ArcPointer[MemStore]
    var _id: String
    var _owner: String
    var _kind: String
    var _static: String
    var _serves: Bool
    var _deps: List[String]
    var _refs: List[InputRef]
    var _bound: List[String]
    var _is_bound: Bool
    var _wanted: Bool

    def __init__(out self, store: ArcPointer[MemStore], node: LoweredNode) raises:
        self._store = store.copy()
        self._id = node.id.copy()
        self._owner = node.owner.copy()
        self._kind = node.kind.copy()
        self._static = static_digest(node)
        self._serves = node.field(String("serves")) == "true"
        self._deps = node.depends_on.copy()
        self._refs = node.inputs.copy()
        self._bound = List[String]()
        self._is_bound = len(self._refs) == 0
        self._wanted = node.wanted

    def _desired_digest(self) raises -> String:
        if not self._is_bound:
            raise unbound_error(self._id, self._refs[0])
        var d = self._static.copy()
        for i in range(len(self._refs)):
            d += String("|") + self._refs[i].field + String("=") + self._bound[i]
        return d^

    def _url(self) -> String:
        if self._serves:
            return mem_url(self._owner)
        return String("")

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var v = self._store[].read(self._id)
        if not v.present:
            return ResourceStatus.absent()
        var stamp = standard_identity_of(v.labels)
        var extra = _unmanaged(v)
        if v.failed:
            return ResourceStatus(
                RES_FAILED,
                self._id,
                v.digest,
                String("mem: the node failed to become ready"),
                v.url,
                String(""),
                stamp,
                extra,
            )
        if not self._is_bound:
            # A presence read: with no bound inputs there is no desired digest
            # to compare, so the node is reported present and unmatched.
            return ResourceStatus.drifted(self._id, v.digest, v.url, String(""), stamp, extra)
        var want = self._desired_digest()
        if v.digest == want:
            return ResourceStatus.matched(self._id, want, v.url, String(""), stamp, extra)
        return ResourceStatus.drifted(self._id, v.digest, v.url, String(""), stamp, extra)

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        var v = self._store[].read(self._id)
        if not v.present:
            return ResourceStatus.absent()
        return ResourceStatus.drifted(
            self._id, String(""), v.url, String(""), standard_identity_of(v.labels)
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return _plan(self._id, live)

    def create(mut self, creds: Creds) raises -> String:
        self._store[].create(
            self._id, self._kind, self._desired_digest(), self._url(), List[Label](), String("")
        )
        return self._id.copy()

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        var labels = standard_label_rule(stamp)
        var note = stamp.provenance.run_id + String("@") + stamp.provenance.revision
        self._store[].create(
            self._id, self._kind, self._desired_digest(), self._url(), labels, note
        )
        return self._id.copy()

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        var note = stamp.provenance.run_id + String("@") + stamp.provenance.revision
        self._store[].relabel(physical_id, standard_label_rule(stamp), note)

    def update(mut self, creds: Creds) raises:
        self._store[].update(self._id, self._desired_digest(), self._url())

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._store[].remove(physical_id)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE

    def input_refs(mut self) -> List[InputRef]:
        return self._refs.copy()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        var vals = List[String]()
        for i in range(len(self._refs)):
            vals.append(
                resolved.value_of(self._id, self._refs[i].producer, self._refs[i].output)
            )
        self._bound = vals^
        self._is_bound = True

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        var o = Outputs()
        if not self._serves:
            return o^
        var v = self._store[].read(self._id)
        if not v.present:
            return o^
        o.set(String("URL"), v.url)
        o.set(String("HOST"), mem_host(self._owner))
        return o^

    def owner(mut self) -> String:
        return self._owner.copy()

    def stamps_ownership(mut self) -> Bool:
        return True

    def wanted(mut self) -> Bool:
        return self._wanted
