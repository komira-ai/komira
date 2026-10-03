# =============================================================================
# kci_cloud_mem/nodes.mojo: the engine nodes the reference clouds lower to.
# =============================================================================
#
#   * `MemRunNode`   `<id>/run`: the running thing of a service or a job. Its
#                    desired digest is a canonical rendering of everything the
#                    author set, with each `Ref` value replaced by the value it
#                    resolved to; with a reference not yet bound it has NO
#                    digest (UNBOUND), never a placeholder. A service exposes
#                    URL and HOST once it exists.
#   * `MemGrantNode` `<id>/uses/<target>`: one `Uses` line, ordered after both
#                    ends.
#
# Every node's `owner()` is the authored resource id, as kci_cloud's
# lowering contract requires.
# =============================================================================

from std.memory import ArcPointer

from kci_reconciler import (
    ChangeAction,
    Creds,
    InputRef,
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

from kci_cloud_mem.mem_store import MemStore


def mem_url(resource_id: String) -> String:
    return String("mem://") + resource_id


def mem_host(resource_id: String) -> String:
    return resource_id + String(".mem")


def _failed(id: String, digest: String, url: String) -> ResourceStatus:
    """A present node in the failed state: it exists and does not run what
    the file asks. The engine updates it (a fixed spec is the way out)."""
    return ResourceStatus(
        RES_FAILED, id, digest, String("mem: the node failed to become ready"), url
    )


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


struct MemRunNode(EngineResource, Movable, Deinitable):
    var _store: ArcPointer[MemStore]
    var _resource: String
    var _static: String
    var _serves: Bool
    var _refs: List[InputRef]
    var _bound: List[String]
    var _is_bound: Bool

    def __init__(
        out self,
        store: ArcPointer[MemStore],
        resource: String,
        static: String,
        serves: Bool,
        var refs: List[InputRef],
    ):
        self._store = store.copy()
        self._resource = resource
        self._static = static
        self._serves = serves
        self._refs = refs^
        self._bound = List[String]()
        self._is_bound = len(self._refs) == 0

    def _id(self) -> String:
        return self._resource + String("/run")

    def _desired_digest(self) raises -> String:
        if not self._is_bound:
            raise unbound_error(self._id(), self._refs[0])
        var d = self._static.copy()
        for i in range(len(self._refs)):
            d += String("|") + self._refs[i].field + String("=") + self._bound[i]
        return d^

    def logical_id(mut self) -> String:
        return self._id()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var id = self._id()
        var i = self._store[].find(id)
        if i < 0:
            return ResourceStatus.absent()
        if self._store[].is_failed(i):
            return _failed(id, self._store[].digests[i], self._store[].urls[i])
        if not self._is_bound:
            # A PRESENCE read: `destroy_graph` reads every node without
            # binding its inputs, and only asks whether it exists. With no
            # bound inputs there is no desired digest to compare, so the node
            # is reported present and unmatched, never as matching.
            return ResourceStatus.drifted(id, self._store[].digests[i], self._store[].urls[i])
        var want = self._desired_digest()
        if self._store[].digests[i] == want:
            return ResourceStatus.matched(id, want, self._store[].urls[i])
        return ResourceStatus.drifted(id, self._store[].digests[i], self._store[].urls[i])

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return _plan(self._id(), live)

    def _url(self) -> String:
        if self._serves:
            return mem_url(self._resource)
        return String("")

    def create(mut self, creds: Creds) raises -> String:
        var id = self._id()
        self._store[].put(String("create"), id, self._desired_digest(), self._url())
        return id^

    def update(mut self, creds: Creds) raises:
        self._store[].put(String("update"), self._id(), self._desired_digest(), self._url())

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
                resolved.value_of(self._id(), self._refs[i].producer, self._refs[i].output)
            )
        self._bound = vals^
        self._is_bound = True

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        var o = Outputs()
        if not self._serves:
            return o^
        var i = self._store[].find(self._id())
        if i < 0:
            return o^
        o.set(String("URL"), self._store[].urls[i])
        o.set(String("HOST"), mem_host(self._resource))
        return o^

    def owner(mut self) -> String:
        return self._resource.copy()


struct MemGrantNode(EngineResource, Movable, Deinitable):
    var _store: ArcPointer[MemStore]
    var _resource: String
    var _target: String
    var _access: String

    def __init__(
        out self,
        store: ArcPointer[MemStore],
        resource: String,
        target: String,
        access: String,
    ):
        self._store = store.copy()
        self._resource = resource
        self._target = target
        self._access = access

    def _id(self) -> String:
        return self._resource + String("/uses/") + self._target

    def logical_id(mut self) -> String:
        return self._id()

    def depends_on(mut self) -> List[String]:
        var d = List[String]()
        d.append(self._resource + String("/run"))
        d.append(self._target + String("/run"))
        return d^

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var id = self._id()
        var i = self._store[].find(id)
        if i < 0:
            return ResourceStatus.absent()
        if self._store[].is_failed(i):
            return _failed(id, self._store[].digests[i], String(""))
        if self._store[].digests[i] == self._access:
            return ResourceStatus.matched(id, self._access)
        return ResourceStatus.drifted(id, self._store[].digests[i])

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return _plan(self._id(), live)

    def create(mut self, creds: Creds) raises -> String:
        var id = self._id()
        self._store[].put(String("create"), id, self._access, String(""))
        return id^

    def update(mut self, creds: Creds) raises:
        self._store[].put(String("update"), self._id(), self._access, String(""))

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._store[].remove(physical_id)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE

    def owner(mut self) -> String:
        return self._resource.copy()
