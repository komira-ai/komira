# =============================================================================
# kci_cloud/adapter.mojo: what a cloud adapter built into kci provides.
# =============================================================================
#
# A CLOUD ADAPTER is everything kci knows about one cloud: which catalog
# types it hosts, why it does not host the others, what values it refuses,
# and how it turns one authored resource into engine nodes. Every adapter is
# built into kci; `main` is the one place that lists them. This trait is an
# INTERNAL module boundary that keeps kci testable against the in-memory
# clouds. It is not a plugin interface and not frozen: it changes in an
# ordinary pull request, together with every adapter.
#
# WHY ONE TRAIT PER CLOUD AND NOT AN ERASED LIST OF PER-TYPE ADAPTERS. The
# questions asked across clouds (which built-in cloud hosts a type, is a
# declaration legal) need only DATA, so `Clouds` holds a plain description
# of each adapter (`clouds.describe`). The one call that needs an adapter's
# code, lowering, is made on the adapter of the stage's cell, through a
# generic function. So no function-pointer table is needed here; the
# engine's `ErasedResource` remains the only erasure, one level down.
#
# THE CONTRACT, each held by a test in this package or by the conformance kit:
#   * `implemented` and `absences` together name every catalog type exactly
#     once (`clouds.artifact_problems`): a new type forces a decision on
#     every cloud.
#   * ABSENT_BY_DESIGN is legal only for a CLOUD_BOUND type, NOT_YET only
#     for a PORTABLE one, and an adapter that calls itself complete has no
#     NOT_YET.
#   * `check` is pure and returns EVERY finding for one resource; it is only
#     asked about types the adapter implements.
#   * `lower` is pure (no network, no clock) and returns DATA
#     (`LoweredNode`: id, owner, kind, dependencies, input references, the
#     desired state as ordered fields, wanted or turned off), never engine
#     code, so a lowering is golden-testable (`deploy.lowering_json`). Node
#     ids are `<resource id>/<role>` and every node's owner is the resource
#     id. Each type lowers to its COMPLETE fixed set of roles; a role the
#     file turned off is a node with `wanted` False (the closed world). A
#     dependency or input on ANOTHER resource is written as that resource's
#     id alone; kci resolves it to the resource's primary node
#     (catalog.mojo). `retention` is set by kci from the resource, never by
#     the adapter. Grants are decided by kci too (grants.mojo): `lower` is
#     handed the resource's edges, each with its role and its target's type,
#     and lowers each one by the cloud's own grant kinds. So are the FEEDS
#     (feed.mojo, the list's subscriptions as (subscription, topic, queue)):
#     `check` and `lower` are handed them with every resource, so a cloud
#     whose queue IS its subscription to a topic lowers the queue from its
#     feed, and refuses as a limit what it cannot host. A workload (a
#     service, a container job, a worker) and a service account lower the
#     role `<id>/identity` (turned off for a workload with `run_as`): a
#     grant's principal is that node. `realize` turns one lowered node into
#     the engine node,
#     and must keep its id, owner, wanted and retention.
#   * Every object carries the non-identity retention mark
#     `kci-retention=<retain|delete>` (komira_validation_run's, written by
#     `labels.retain_labels`), and `list_owned` reports a `retain` object as
#     `retained`: kci never deletes it through `list_owned`.
#   * An adapter's node builds a create's labels with `labels.create_labels`
#     (`label_rule` is the identity only). So an object created in a scope
#     with a validation run id carries it as the label `kci-run-id=<id>` from
#     its create call on, and `list_owned` reports it
#     (`OwnedRecord.validation_run_id`). An object created outside a
#     validation run, or adopted, carries no such label. The conformance kit
#     runs a pass under a validation run id of its own and a pass without
#     one, so an adapter whose create path skips the label fails the kit. An
#     id outside komira_validation_run's rule refuses a plan or an apply
#     before any create (`deploy.refuse_unless_valid`). No kci verb sets the
#     scope's validation run id yet.
#   * A table's KEY IS IMMUTABLE. Its `<id>/table` node has the desired field
#     `key` (`data.table_key_text`), and `list_owned` reports each table
#     object's key AS THE CLOUD STORES IT (`OwnedRecord.key`, same rendering;
#     empty for every other kind). kci refuses a plan or an apply whose key
#     differs from the stored one, before any change
#     (`data.key_change_findings`): a new key is a new table, never an
#     update.
#   * THE METADATA IS KCI'S (metadata.mojo). After `lower`, kci writes the
#     author's labels on every node of the resource as desired fields
#     `label.<key>` (sorted by key), and the written cloud name on its
#     primary node as the desired field `physical_name`; an adapter writes
#     neither field itself (`deploy.lower_data` raises if it does). An
#     adapter creates the primary object under `Resource.physical_name` when
#     it is written (it reads it from the resource, as its outputs follow
#     it) and writes the label fields where its object carries labels.
#     `list_owned` reports the author's cloud name each object was created
#     under (`OwnedRecord.name`; empty when the adapter chose the name), and
#     kci refuses a plan, an apply or a destroy whose primary node asks for
#     another one, before any change (`metadata.name_change_findings`): a
#     new name is a new object. `Resource.adopt` adds the primary node to
#     the scope's adopt list on plan and apply (the engine's `--adopt`), so
#     an unstamped object of that name is stamped instead of refused.
#
# ⛔ PRECONDITION FOR THE FIRST REAL ADAPTER: NO `--` STAMPS MAY BE LEFT.
# The standard label rule once wrote the `/` of a role as `--` (`uses--jobs`);
# it now writes `_` (labels.mojo), and the two are NOT decode-compatible:
# `identity_of` reads a `--` stamp as a role nobody lowers. On a cloud that
# holds objects stamped the old way, `list_owned` would report each one as a
# role the file turned off, and the closed world would DELETE it. Only the
# offline fakes implement this trait today, so no such object exists. A real
# adapter must not ship until either (a) the cloud is shown to hold no object
# with a `--` stamp, or (b) a relabel step rewrites every `--` stamp of the
# cell to `_` before the first deploy that reads `list_owned`. Neither exists
# yet; the adapter's pull request carries one of them.
#
# THE REST OF THE INTERFACE (internal, not frozen; every built-in cloud
# provides all of it):
#   * `configure(CellContext)` validates the cell's settings by the
#     adapter's own schema (a typo fails at lint, as findings) and keeps them
#     for `check`, `public_mechanism` and `lower`.
#   * `public_mechanism` is the mechanism that makes a service public in this
#     cell, chosen from the settings at validate time; empty means none, and
#     validate refuses a `public {}` service then. Nothing falls back at
#     apply time.
#   * `bootstrap_resources(machine, cell)` lists what bootstrap must create
#     in a cell of this cloud before any deploy (the state store first).
#   * `label_rule(stamp)` and `identity_of(labels)` encode and decode the
#     ownership stamp (labels.mojo is the standard rule).
#   * `list_owned(creds, scope)` lists every object of this machine and cell
#     the cloud says is kci's, as `OwnedRecord`s; deploy reads it to remove
#     roles a resource still in the file turned off, and to report leftover
#     resources the file no longer names.
#   * `required_artifact(resource)` is the artifact type and platform (OS +
#     CPU) a resource needs here; validate checks the referenced image
#     against it.
#   * `whoami(creds)` answers who the credentials are, before any change.
#   * `trust_render(scope)` and `trust_check(creds, scope)` are the cloud side
#     of trust: what the cell's deploy identity must look like, and whether
#     the live one does.
# =============================================================================

from kci_reconciler import (
    CellScope,
    Creds,
    ErasedResource,
    InputRef,
    Label,
    OwnerStamp,
    RETAIN_DELETE,
    RETAIN_KEEP,
)
from kci_resource_proto.resource import Resource

from kci_cloud.cloud_id import CloudId
from kci_cloud.feed import Feed
from kci_cloud.firing import Firing
from kci_cloud.grants import GrantEdge


comptime ABSENT_BY_DESIGN: Int = 1
"""This cloud will not host the type; legal only for CLOUD_BOUND."""
comptime NOT_YET: Int = 2
"""This cloud does not host the type yet; legal only for PORTABLE."""


def absence_word(kind: Int) -> String:
    if kind == ABSENT_BY_DESIGN:
        return String("ABSENT_BY_DESIGN")
    if kind == NOT_YET:
        return String("NOT_YET")
    return String("ABSENCE_UNSET")


struct Absence(Copyable, Movable, Deinitable):
    """A catalog type a cloud does not host, and why."""

    var field: Int
    var kind: Int
    var reason: String

    def __init__(out self, field: Int, kind: Int, reason: String):
        self.field = field
        self.kind = kind
        self.reason = reason

    def __init__(out self, *, copy: Self):
        self.field = copy.field
        self.kind = copy.kind
        self.reason = copy.reason.copy()


comptime FINDING_GRAPH: Int = 1
"""Wrong whatever the cloud: an id, a reference, an access verb."""
comptime FINDING_COVERAGE: Int = 2
"""The chosen cloud has no adapter for the resource's type."""
comptime FINDING_LIMIT: Int = 3
"""The cloud hosts the type but refuses one of its values or shapes."""
comptime FINDING_CELL: Int = 4
"""The cell is wrong for this cloud: a setting, or the deploy identity."""


struct Finding(Copyable, Movable, Deinitable):
    """One reason a graph cannot be applied. `field_path` is where in the
    author's file (`service.request_timeout`); `citation` is where the limit
    is documented, and `unverified` says the citation was not checked
    against the cloud."""

    var kind: Int
    var resource_id: String
    var field_path: String
    var reason: String
    var citation: String
    var unverified: Bool

    def __init__(
        out self,
        kind: Int,
        resource_id: String,
        field_path: String,
        reason: String,
        citation: String = String(""),
        unverified: Bool = False,
    ):
        self.kind = kind
        self.resource_id = resource_id
        self.field_path = field_path
        self.reason = reason
        self.citation = citation
        self.unverified = unverified

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.resource_id = copy.resource_id.copy()
        self.field_path = copy.field_path.copy()
        self.reason = copy.reason.copy()
        self.citation = copy.citation.copy()
        self.unverified = copy.unverified


@fieldwise_init
struct Setting(Copyable, Movable, Deinitable):
    """One key/value: a cell setting, or one field of a lowered node's
    desired state."""

    var key: String
    var value: String


@fieldwise_init
struct ResolvedArtifact(Copyable, Movable, Deinitable):
    """One entry of a cell's resolved artifact map: the artifact `name` of
    `platform` (OS + CPU) at `revision`, and the content digest it resolved
    to."""

    var name: String
    var platform: String
    var revision: String
    var digest: String


struct CellContext(Copyable, Movable, Deinitable):
    """What a cloud adapter is configured with for one cell: the engine scope
    (machine, cell, provenance, adopt), the cell's settings (validated by
    the adapter in `configure`), the resolved artifact map, and the
    bootstrap capability level the cell was bootstrapped at."""

    var scope: CellScope
    var settings: List[Setting]
    var artifacts: List[ResolvedArtifact]
    var bootstrap_level: Int

    def __init__(
        out self,
        var scope: CellScope,
        var settings: List[Setting] = List[Setting](),
        var artifacts: List[ResolvedArtifact] = List[ResolvedArtifact](),
        bootstrap_level: Int = 1,
    ):
        self.scope = scope^
        self.settings = settings^
        self.artifacts = artifacts^
        self.bootstrap_level = bootstrap_level

    def __init__(out self, *, copy: Self):
        self.scope = copy.scope.copy()
        self.settings = copy.settings.copy()
        self.artifacts = copy.artifacts.copy()
        self.bootstrap_level = copy.bootstrap_level

    def setting(self, key: String) -> Optional[String]:
        for i in range(len(self.settings)):
            if self.settings[i].key == key:
                return self.settings[i].value.copy()
        return None


@fieldwise_init
struct ArtifactNeed(Copyable, Movable, Deinitable):
    """The artifact a resource needs on a cloud: its type (`oci-image`) and
    platform (OS + CPU, `linux/amd64`)."""

    var kind: String
    var platform: String


@fieldwise_init
struct BootstrapItem(Copyable, Movable, Deinitable):
    """One thing bootstrap creates in a cell of a cloud, and why."""

    var kind: String
    var name: String
    var why: String


comptime RUN_UNKNOWN = "unknown"
"""`OwnedRecord.run_id` when the object does not say which run made it."""


struct OwnedRecord(Copyable, Movable, Deinitable):
    """One object of this machine and cell the cloud says is kci's (by its
    stamp): its kind, physical id, location, what it bills, when it was
    created, the run that last wrote it (its provenance, or `RUN_UNKNOWN`),
    whether kci may delete it, the engine node that owns it
    (`<resource>/<role>`), whether it is RETAINED (it carries
    `kci-retention=retain`: kci reports it and never deletes it through this
    list), its immutable KEY as the cloud stores it (a table's, rendered as
    `data.table_key_text`; empty for every other kind), and the VALIDATION
    RUN that created it: the `kci-run-id` label's value as the cloud stores
    it (`labels.validation_run_of`), or None when the object carries none;
    and the author's cloud NAME it was created under
    (`Resource.physical_name`, as the cloud stores it; empty when the
    adapter chose the name)."""

    var kind: String
    var id: String
    var location: String
    var billing: String
    var created_at: String
    var run_id: String
    var deletable_by_kci: Bool
    var owner_node: String
    var retained: Bool
    var key: String
    var validation_run_id: Optional[String]
    var name: String

    def __init__(
        out self,
        kind: String,
        id: String,
        location: String,
        billing: String,
        created_at: String,
        run_id: String,
        deletable_by_kci: Bool,
        owner_node: String,
        retained: Bool,
        key: String,
        validation_run_id: Optional[String],
        name: String = String(""),
    ):
        self.kind = kind
        self.id = id
        self.location = location
        self.billing = billing
        self.created_at = created_at
        self.run_id = run_id
        self.deletable_by_kci = deletable_by_kci
        self.owner_node = owner_node
        self.retained = retained
        self.key = key
        self.validation_run_id = validation_run_id.copy()
        self.name = name

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind.copy()
        self.id = copy.id.copy()
        self.location = copy.location.copy()
        self.billing = copy.billing.copy()
        self.created_at = copy.created_at.copy()
        self.run_id = copy.run_id.copy()
        self.deletable_by_kci = copy.deletable_by_kci
        self.owner_node = copy.owner_node.copy()
        self.retained = copy.retained
        self.key = copy.key.copy()
        self.validation_run_id = copy.validation_run_id.copy()
        self.name = copy.name.copy()


@fieldwise_init
struct Principal(Copyable, Movable, Deinitable):
    """Who a set of credentials is: the principal, and the account or project
    it acts in."""

    var principal: String
    var account: String


def _json_str(s: String) -> String:
    var out = String("\"")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c == ord("\""):
            out += String("\\\"")
        elif c == ord("\\"):
            out += String("\\\\")
        elif c == 10:
            out += String("\\n")
        elif c < 32:
            out += String("?")
        else:
            out += String(s[byte = i : i + 1])
    out += String("\"")
    return out^


def retention_name(retention: Int) -> String:
    """An engine RETAIN_* code as it reads in a lowering: `delete`, `keep`,
    or the bare number for any other code."""
    if retention == RETAIN_DELETE:
        return String("delete")
    if retention == RETAIN_KEEP:
        return String("keep")
    return String(retention)


struct LoweredNode(Copyable, Movable, Deinitable):
    """One engine node as DATA: what `lower` returns. `desired` is the node's
    desired state as ordered fields (rendered, never a code object);
    `inputs` are the values it reads from other nodes at apply time;
    `wanted` is False for a role the file turned off; `retention` is the
    engine's RETAIN_* code, set by kci from the resource (`deploy.lower_data`)
    and carried to the engine node by `realize`."""

    var id: String
    var owner: String
    var kind: String
    var depends_on: List[String]
    var inputs: List[InputRef]
    var desired: List[Setting]
    var wanted: Bool
    var retention: Int

    def __init__(
        out self,
        id: String,
        owner: String,
        kind: String,
        var depends_on: List[String] = List[String](),
        var inputs: List[InputRef] = List[InputRef](),
        var desired: List[Setting] = List[Setting](),
        wanted: Bool = True,
        retention: Int = RETAIN_DELETE,
    ):
        self.id = id
        self.owner = owner
        self.kind = kind
        self.depends_on = depends_on^
        self.inputs = inputs^
        self.desired = desired^
        self.wanted = wanted
        self.retention = retention

    def __init__(out self, *, copy: Self):
        self.id = copy.id.copy()
        self.owner = copy.owner.copy()
        self.kind = copy.kind.copy()
        self.depends_on = copy.depends_on.copy()
        self.inputs = copy.inputs.copy()
        self.desired = copy.desired.copy()
        self.wanted = copy.wanted
        self.retention = copy.retention

    def field(self, key: String) -> String:
        """The desired field `key`, or empty."""
        for i in range(len(self.desired)):
            if self.desired[i].key == key:
                return self.desired[i].value.copy()
        return String("")

    def to_json(self) -> String:
        """One deterministic JSON object (fields in declaration order)."""
        var s = String("{\"id\":") + _json_str(self.id)
        s += String(",\"owner\":") + _json_str(self.owner)
        s += String(",\"kind\":") + _json_str(self.kind)
        s += String(",\"wanted\":") + (String("true") if self.wanted else String("false"))
        s += String(",\"retention\":") + _json_str(retention_name(self.retention))
        s += String(",\"depends_on\":[")
        for i in range(len(self.depends_on)):
            if i > 0:
                s += String(",")
            s += _json_str(self.depends_on[i])
        s += String("],\"inputs\":[")
        for i in range(len(self.inputs)):
            if i > 0:
                s += String(",")
            s += String("{\"producer\":") + _json_str(self.inputs[i].producer)
            s += String(",\"output\":") + _json_str(self.inputs[i].output)
            s += String(",\"field\":") + _json_str(self.inputs[i].field) + String("}")
        s += String("],\"desired\":{")
        for i in range(len(self.desired)):
            if i > 0:
                s += String(",")
            s += _json_str(self.desired[i].key) + String(":") + _json_str(self.desired[i].value)
        s += String("}}")
        return s^


trait CloudAdapter(Movable):
    """Everything kci knows about one cloud. See the file header."""

    def cloud_id(self) -> CloudId:
        """The opaque id of this cloud (a cell's `cloud`, `--cloud=<id>`)."""
        ...

    def complete(self) -> Bool:
        """True iff the adapter claims to host every PORTABLE type."""
        ...

    def implemented(self) -> List[Int]:
        """The `Resource.body` field numbers this adapter lowers."""
        ...

    def absences(self) -> List[Absence]:
        """Every catalog type this adapter does not lower, each with a reason."""
        ...

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        """Take the cell's settings; return every setting this cloud refuses
        (FINDING_CELL), validated by the adapter's own schema."""
        ...

    def public_mechanism(self) -> String:
        """The mechanism that makes a service public in the configured cell,
        or empty when the cell chooses none (validate then refuses a public
        service)."""
        ...

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
        """Every value or shape of `r` this cloud refuses, given the list's
        `feeds` (kci's, from `feed.feeds_of`) and `firings` (kci's, from
        `triggers.firings_of`). Pure."""
        ...

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        """The artifact type and platform `r` needs on this cloud."""
        ...

    def lower(
        self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]
    ) raises -> List[LoweredNode]:
        """`r`'s engine nodes, as data, including one grant per edge of
        `edges` (kci's, from `grants.edges_for`), given the list's `feeds`
        (kci's, from `feed.feeds_of`) and `firings` (kci's, from
        `triggers.firings_of`). Pure: no network, no clock."""
        ...

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        """The engine node for one lowered node (same id, owner, wanted)."""
        ...

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        """What bootstrap creates in a cell of this cloud."""
        ...

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        """The identity labels an object is created with for `stamp` (the
        validation run and retention labels ride beside them:
        `labels.create_labels`)."""
        ...

    def identity_of(self, labels: List[Label]) -> String:
        """The ownership identity `labels` carry, or empty."""
        ...

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        """Every object of `scope`'s machine and cell this cloud says is
        kci's."""
        ...

    def whoami(mut self, creds: Creds) raises -> Principal:
        """Who `creds` are."""
        ...

    def trust_render(self, scope: CellScope) -> String:
        """What the cell's deploy identity must look like on this cloud."""
        ...

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        """Whether the live deploy identity is what `trust_render` says
        (FINDING_CELL findings; empty when it is)."""
        ...
