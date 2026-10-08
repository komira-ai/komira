# =============================================================================
# kci_cloud_fake/nodes.mojo: the engine node the fake clouds realize.
# =============================================================================
#
# One node type, `FakeNode`, realized from a `LoweredNode` (data):
#
#   * kind `run`       `<id>/run`: the running thing of a workload (a
#                      service, a container job's definition, a worker).
#                      Its desired digest renders every modelled field (the
#                      lowered node's `desired` fields, defaults filled in),
#                      then each `Ref` value as it resolved; with a reference
#                      not yet bound it has NO digest (UNBOUND), never a
#                      placeholder. A service's run node exposes URL and HOST.
#   * kind `public`    `<id>/public`: the public ingress of a service, by the
#                      mechanism the cell chose at validate time.
#   * kind `identity`  `<id>/identity`: the private identity of a workload,
#                      or a service account; an account's exposes
#                      NAME (`account`, a desired field, like `serves`).
#   * kind `grant`     `<id>/u-<h>` or `<id>/grant`: one grant edge.
#   * kind `bucket`    `<id>/bucket`: a bucket. It exposes NAME and ADDRESS
#                      (`stores`, a desired field, like `serves`).
#   * kind `table`     `<id>/table`: a table. It exposes NAME (`named`, a
#                      desired field, like `serves`). Its desired `key` is
#                      part of the digest, and `live_key` reads it back from
#                      a stored digest (what `list_owned` reports as the
#                      object's key).
#   * kind `queue`     `<id>/queue`: a queue; kind `topic` `<id>/topic`: a
#                      topic. Each exposes NAME and ADDRESS (`addressed`, a
#                      desired field naming what it is, like `serves`).
#   * kind `subscription` `<id>/sub`: one subscription.
#   * kind `secret`    `<id>/secret`: a secret's container (no value). It
#                      exposes NAME (`secret_named`, a desired field, like
#                      `serves`).
#   * kind `zone`, `record`, `certificate`: a DNS zone, a DNS record set, a
#                      certificate. Each exposes what its `out.<OUTPUT>`
#                      desired fields say, with the value written there
#                      (`out.NAME`, `out.HOST`): how the node behaves, not
#                      state, so never in its digest.
# Those are the generic shape's kinds. On a provider shape (shapes.mojo) the
# kind is the provider kind id (on onprem also a `<id>/vault` beside each
# identity, a service's `<id>/endpoint`, which serves nothing, and a grant's
# helper `<id>/r-<h>`; on gcp a table's `<id>/ix-<h>` and `<id>/ttl`; on aws
# a worker's `<id>/task`, which serves nothing); the
# node behaves the same: `serves`, `stores`, `account` and `named` (desired
# fields), not the kind, decide what it exposes. On aws a queue also has a
# `<id>/policy`; on gcp a queue has its private `<id>/topic`, which
# addresses nothing.
# A role the file turned off is the same node with `wanted` False. A node
# whose object the store marks replace-only (`FakeStore.replace_only`) plans
# a drift as a replace and converges by replacing (which the engine refuses
# in v1), never by an update.
#
# A NAMED PRIMARY OBJECT (`physical_name`, a desired field kci writes on the
# primary node) is part of the digest like any field, and its outputs follow
# the name: a bucket's, a table's, a secret's, a queue's or a topic's NAME is
# the name itself (its ADDRESS built on it), an account's NAME is
# `<name>@identity.fake`, a service's URL and HOST are `fake://<name>` and
# `<name>.fake`. The fake keeps every object at its node id (it does not
# look an object up by name): the object at a named node IS the object of
# that name. The create, or the adoption, records the name with the object
# (`FakeStore.names`), and `list_owned` reports it; an update never renames.
#
# A node keeps the retention kci set on the lowered node. Its object carries
# the retention mark `kci-retention=<retain|delete>` from its create call on,
# and the mark follows the node: retention is part of the node's digest, so a
# changed retention is an update, and the update rewrites the mark in the same
# call.
#
# Every node is born stamped (`create_owned` writes `create_labels`: the
# standard label rule's labels, the `kci-run-id` label when the scope has a
# validation run, the retention mark; and the provenance annotation, in the
# one create call). An adoption writes the identity and retention labels, and
# never a validation run: the run did not create the object; on a node kci
# marked `adopted` (the primary node of a resource that writes `adopt`) it
# also writes the adoption mark `kci_adopted=true`. A node reads its
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
    CONVERGE_REPLACE,
    RES_ABSENT,
    RES_FAILED,
    RETAIN_KEEP,
    VERB_CREATE,
    VERB_NOOP,
    VERB_REPLACE,
    VERB_UPDATE,
    unbound_error,
)
from kci_cloud import (
    LoweredNode,
    adoption_labels,
    create_labels,
    retain_labels,
    standard_identity_of,
    standard_label_rule,
)

from kci_cloud_fake.fake_store import FakeStore, FakeView


def fake_url(resource_id: String) -> String:
    return String("fake://") + resource_id


def fake_host(resource_id: String) -> String:
    return resource_id + String(".fake")


def fake_bucket_name(resource_id: String) -> String:
    return resource_id + String("-bucket")


def fake_bucket_address(resource_id: String) -> String:
    return String("fake-bucket://") + fake_bucket_name(resource_id)


def fake_account_name(resource_id: String) -> String:
    return resource_id + String("@identity.fake")


def fake_table_name(resource_id: String) -> String:
    return resource_id + String("-table")


def fake_secret_name(resource_id: String) -> String:
    return resource_id + String("-secret")


def fake_messaging_name(resource_id: String, what: String) -> String:
    """`<id>-queue` or `<id>-topic`."""
    return resource_id + String("-") + what


def fake_messaging_address(resource_id: String, what: String) -> String:
    return String("fake-") + what + String("://") + fake_messaging_name(resource_id, what)


def live_key(digest: String) -> String:
    """The `key` field of a stored digest (`kind|name=value|...`), or empty
    when it has none."""
    var at = digest.find("|key=")
    if at < 0:
        return String("")
    var start = at + 5
    var rest = String(digest[byte = start : digest.byte_length()])
    var end = rest.find("|")
    if end < 0:
        return rest^
    return String(rest[byte=0:end])


def _plan(id: String, live: ResourceStatus, retention: Int) -> ChangeAction:
    var verb = VERB_UPDATE
    var why = String("drifted -> update")
    if live.phase == RES_ABSENT:
        verb = VERB_CREATE
        why = String("absent -> create")
    elif live.is_matched():
        verb = VERB_NOOP
        why = String("matched")
    return ChangeAction(id, verb, why, retention)


def _unmanaged(v: FakeView) -> String:
    if v.extra.byte_length() == 0:
        return String("")
    return String("label ") + v.extra + String(" (not modelled; left as it is)")


def static_digest(node: LoweredNode) raises -> String:
    """The digest of a lowered node's own desired fields, in order (the
    `serves`, `stores`, `account`, `named`, `addressed`, `secret_named` and
    `out.<OUTPUT>` fields are how the node behaves, not state), and a KEEP
    node's retention (a `kci_retain` digest field, not a label)."""
    var d = ModelledDigest(node.kind)
    for i in range(len(node.desired)):
        ref key = node.desired[i].key
        if key == "serves" or key == "stores" or key == "account" or key == "named" or key == "addressed":
            continue
        if key == "secret_named" or key.startswith("out."):
            continue
        d.field(node.desired[i].key, node.desired[i].value)
    if node.retention == RETAIN_KEEP:
        d.field(String("kci_retain"), String("keep"))
    return d.text()


struct FakeNode(EngineResource, Movable, Deinitable):
    var _store: ArcPointer[FakeStore]
    var _id: String
    var _owner: String
    var _kind: String
    var _static: String
    var _serves: Bool
    var _stores: Bool
    var _account: Bool
    var _named: Bool
    var _secret_named: Bool
    var _addressed: String
    var _outs: List[String]
    """`out.<OUTPUT>` fields in order, two entries each: the OUTPUT name,
    then its value."""
    var _name: String
    """The author's cloud name of this node's object (`physical_name`), or
    empty."""
    var _retention: Int
    var _deps: List[String]
    var _refs: List[InputRef]
    var _bound: List[String]
    var _is_bound: Bool
    var _wanted: Bool
    var _adopted: Bool

    def __init__(out self, store: ArcPointer[FakeStore], node: LoweredNode) raises:
        self._store = store.copy()
        self._id = node.id.copy()
        self._owner = node.owner.copy()
        self._kind = node.kind.copy()
        self._static = static_digest(node)
        self._serves = node.field(String("serves")) == "true"
        self._stores = node.field(String("stores")) == "true"
        self._account = node.field(String("account")) == "true"
        self._named = node.field(String("named")) == "true"
        self._secret_named = node.field(String("secret_named")) == "true"
        self._addressed = node.field(String("addressed"))
        self._outs = List[String]()
        for i in range(len(node.desired)):
            ref k = node.desired[i].key
            if k.startswith("out."):
                self._outs.append(String(k[byte = 4 : k.byte_length()]))
                self._outs.append(node.desired[i].value.copy())
        self._name = node.field(String("physical_name"))
        self._retention = node.retention
        self._deps = node.depends_on.copy()
        self._refs = node.inputs.copy()
        self._bound = List[String]()
        self._is_bound = len(self._refs) == 0
        self._wanted = node.wanted
        self._adopted = node.adopted

    def _desired_digest(self) raises -> String:
        if not self._is_bound:
            raise unbound_error(self._id, self._refs[0])
        var d = self._static.copy()
        for i in range(len(self._refs)):
            d += String("|") + self._refs[i].field + String("=") + self._bound[i]
        return d^

    def _resource(self) -> String:
        """The id of the resource this node was lowered from: its id up to
        the role (`store/app/files` of `store/app/files/bucket`). It is the
        owner for a resource written at the top, and the full path for one
        a composite expanded (whose owner is the top), so two objects under
        one owner never share a default name."""
        var at = self._id.rfind("/")
        if at <= 0:
            return self._owner.copy()
        return String(self._id[byte=0:at])

    def _base(self) -> String:
        """What this node's outputs are built on: its object's name, else
        its resource's id."""
        if self._name.byte_length() > 0:
            return self._name.copy()
        return self._resource()

    def _url(self) -> String:
        if self._serves:
            return fake_url(self._base())
        return String("")

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return self._retention

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        self._store[].read_fault(self._id)
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
                String("fake: the node failed to become ready"),
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
        self._store[].read_fault(self._id)
        var v = self._store[].read(self._id)
        if not v.present:
            return ResourceStatus.absent()
        return ResourceStatus.drifted(
            self._id, String(""), v.url, String(""), standard_identity_of(v.labels)
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        var action = _plan(self._id, live, self._retention)
        if action.verb == VERB_UPDATE and self._store[].replaced_only(self._id):
            action.verb = VERB_REPLACE
            action.reason = String("drifted on a field the cloud cannot change in place -> replace")
        return action^

    def create(mut self, creds: Creds) raises -> String:
        self._store[].create(
            self._id,
            self._kind,
            self._desired_digest(),
            self._url(),
            retain_labels(self._retention),
            String(""),
            self._name,
        )
        return self._id.copy()

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        # The identity, the validation run (when the scope has one) and the
        # retention mark, all in the one create call.
        var labels = create_labels(stamp, self._retention)
        var note = stamp.provenance.run_id + String("@") + stamp.provenance.revision
        self._store[].create(
            self._id, self._kind, self._desired_digest(), self._url(), labels, note, self._name
        )
        return self._id.copy()

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        var note = stamp.provenance.run_id + String("@") + stamp.provenance.revision
        # No validation-run label: this run did not create the object.
        var labels = standard_label_rule(stamp)
        labels.extend(retain_labels(self._retention))
        labels.extend(adoption_labels(self._adopted))
        self._store[].relabel(physical_id, labels, note, self._name)

    def update(mut self, creds: Creds) raises:
        var mark = retain_labels(self._retention)
        self._store[].update(self._id, self._desired_digest(), self._url(), mark[0])

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._store[].remove(physical_id)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        if self._store[].replaced_only(self._id):
            return CONVERGE_REPLACE
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
        if len(self._outs) > 0:
            for i in range(0, len(self._outs), 2):
                o.set(self._outs[i], self._outs[i + 1])
            return o^
        var named = self._name.byte_length() > 0
        if self._stores:
            var n = self._name.copy() if named else fake_bucket_name(self._resource())
            o.set(String("NAME"), n)
            o.set(String("ADDRESS"), String("fake-bucket://") + n)
            return o^
        if self._account:
            o.set(String("NAME"), fake_account_name(self._base()))
            return o^
        if self._named:
            o.set(String("NAME"), self._name.copy() if named else fake_table_name(self._resource()))
            return o^
        if self._secret_named:
            o.set(String("NAME"), self._name.copy() if named else fake_secret_name(self._resource()))
            return o^
        if self._addressed.byte_length() > 0:
            var n = self._name.copy() if named else fake_messaging_name(self._resource(), self._addressed)
            o.set(String("NAME"), n)
            o.set(String("ADDRESS"), String("fake-") + self._addressed + String("://") + n)
            return o^
        if not self._serves:
            return o^
        var v = self._store[].read(self._id)
        if not v.present:
            return o^
        o.set(String("URL"), v.url)
        o.set(String("HOST"), fake_host(self._base()))
        return o^

    def owner(mut self) -> String:
        return self._owner.copy()

    def stamps_ownership(mut self) -> Bool:
        return True

    def wanted(mut self) -> Bool:
        return self._wanted
