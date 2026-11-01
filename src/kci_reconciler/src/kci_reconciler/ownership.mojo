# =============================================================================
# kci_reconciler/ownership.mojo: whose object is this, and where is it recorded.
# =============================================================================
#
# THREE VALUES, AND WHY THEY ARE SEPARATE.
#
#   * `ResourceKey (machine, cell, resource)` is how the STATE STORE keys a
#     node. A logical id alone is not a key: the same graph applied to two
#     cells (or by two release machines into one cell) has the same logical
#     ids, and a store keyed by logical id alone would let one cell adopt the
#     other's intent. `resource` is the node's logical id.
#   * `OwnerStamp` is the IDENTITY a node's cloud object carries (the labels
#     kci stamps): managed-by, machine, cell, resource, role, scheme. It is
#     part of the object from the call that creates it
#     (`Resource.create_owned`), so no object kci makes ever exists without
#     it, not even between a create and a later label patch.
#   * `Provenance (run_id, revision)` is WHO LAST WROTE IT. It rides beside the
#     stamp into the create call, to be written as annotations, and is never
#     part of the identity, never compared and never in a digest: a per-run
#     value in the digest would make every apply a diff (and, on Cloud Run,
#     mint a new revision on every push).
#   * `validation_run_id` is WHICH VALIDATION RUN CREATED IT, or None when the
#     apply is not part of a validation run. It rides in the stamp beside the
#     provenance and, like it, is never part of the identity, never compared
#     and never in a digest. Unlike it, it is written ONCE, by the create call
#     (an update or an adoption never writes it): it says who created the
#     object, so a cleanup can act on what a run can prove it made. The engine
#     carries it opaque; kci_cloud checks it against komira_validation_run's
#     rule before any create and writes it as the `<prefix>-run-id` label.
#
# `CellScope (machine, cell, provenance, adopt, validation_run_id)` is what an
# apply runs IN. An
# OWNED scope (machine and cell both set) turns on the ownership rules in
# engine.mojo; the UNOWNED scope (both empty) is the engine's older single-cell
# form, with no stamp and no foreign check, kept for the conformers that do
# not stamp. kci's own deploy path refuses an unowned scope.
#
# THE OWNERSHIP RULE (the cases the engine can decide alone). For a
# node whose object is PRESENT:
#   * stamped with this node's identity                         -> ours
#   * no stamp, no ledger record, adopted by its resource (`adopt`)   -> ours, after
#                                                                  the stamp
#   * no stamp, no ledger record                                -> FOREIGN
#   * no stamp but a ledger record                              -> CONFLICT
#                                                    (the stamp was stripped)
#   * another identity's stamp                                  -> CONFLICT
#   * our stamp, but the ledger records another physical id     -> CONFLICT
# A FOREIGN or CONFLICT node refuses the whole run BEFORE ANY CHANGE (the
# engine reads every node's presence first), and destroy never deletes one.
# An ABSENT object is never a problem: it is created (a crash before the
# create, or a new node).
#
# Value-typed: String / List / Bool / Int only. No pointer. Mojo 1.0.0b2.
# =============================================================================

comptime KCI_SCHEME: Int = 1
"""The label scheme this engine stamps. Part of the identity: an object stamped
under another scheme is not recognised as ours."""

comptime LABEL_MANAGED_BY = "kci_managed_by"
comptime LABEL_MACHINE = "kci_machine"
comptime LABEL_CELL = "kci_cell"
comptime LABEL_RESOURCE = "kci_resource"
comptime LABEL_ROLE = "kci_role"
comptime LABEL_SCHEME = "kci_scheme"
comptime MANAGED_BY_KCI = "kci"

comptime REFUSED_TOKEN = "kci: REFUSED"
"""The first words of every ownership refusal (a driver maps it to exit 3)."""


@fieldwise_init
struct Label(Copyable, Movable, Deinitable):
    """One key/value label, as kci means it. A cloud's label rule (its adapter)
    encodes these into what the cloud accepts and decodes them back."""

    var key: String
    var value: String


@fieldwise_init
struct ResourceKey(Copyable, Movable, Deinitable):
    """The state store's key: `(machine, cell, resource)`, where `resource` is
    the node's logical id."""

    var machine: String
    var cell: String
    var resource: String

    def same(self, other: ResourceKey) -> Bool:
        return (
            self.machine == other.machine
            and self.cell == other.cell
            and self.resource == other.resource
        )

    def text(self) -> String:
        """`<machine>/<cell>/<resource>`; for the unowned scope, the bare
        resource."""
        if self.machine.byte_length() == 0 and self.cell.byte_length() == 0:
            return self.resource.copy()
        return self.machine + String("/") + self.cell + String("/") + self.resource


@fieldwise_init
struct Provenance(Copyable, Movable, Deinitable):
    """Who last wrote an object: the run and the revision. Annotations only;
    never part of the identity and never in a digest."""

    var run_id: String
    var revision: String

    @staticmethod
    def none() -> Provenance:
        return Provenance(String(""), String(""))


struct OwnerStamp(Copyable, Movable, Deinitable):
    """The identity a node's object carries, plus the provenance and the
    validation run written beside it. `identity()` is what the engine
    compares; `provenance` and `validation_run_id` are not."""

    var machine: String
    var cell: String
    var resource: String
    var role: String
    var scheme: Int
    var provenance: Provenance
    var validation_run_id: Optional[String]

    def __init__(
        out self,
        machine: String,
        cell: String,
        resource: String,
        role: String,
        scheme: Int = KCI_SCHEME,
        provenance: Provenance = Provenance.none(),
        validation_run_id: Optional[String] = None,
    ):
        self.machine = machine
        self.cell = cell
        self.resource = resource
        self.role = role
        self.scheme = scheme
        self.provenance = provenance.copy()
        self.validation_run_id = validation_run_id.copy()

    def __init__(out self, *, copy: Self):
        self.machine = copy.machine.copy()
        self.cell = copy.cell.copy()
        self.resource = copy.resource.copy()
        self.role = copy.role.copy()
        self.scheme = copy.scheme
        self.provenance = copy.provenance.copy()
        self.validation_run_id = copy.validation_run_id.copy()

    def identity(self) -> String:
        """The comparable identity, one line, the same words a cloud object
        that cannot carry labels writes in its description:
        `kci:v<scheme> owner=<machine>/<cell>/<resource>/<role>`."""
        return (
            String("kci:v")
            + String(self.scheme)
            + String(" owner=")
            + self.machine
            + String("/")
            + self.cell
            + String("/")
            + self.resource
            + String("/")
            + self.role
        )

    def labels(self) -> List[Label]:
        """The six identity labels, raw (a cloud's label rule encodes them).
        Provenance and the validation run are not among them."""
        var out = List[Label]()
        out.append(Label(String(LABEL_MANAGED_BY), String(MANAGED_BY_KCI)))
        out.append(Label(String(LABEL_MACHINE), self.machine.copy()))
        out.append(Label(String(LABEL_CELL), self.cell.copy()))
        out.append(Label(String(LABEL_RESOURCE), self.resource.copy()))
        out.append(Label(String(LABEL_ROLE), self.role.copy()))
        out.append(Label(String(LABEL_SCHEME), String(self.scheme)))
        return out^

    @staticmethod
    def identity_of_labels(labels: List[Label]) -> String:
        """The identity the raw `labels` carry, or empty when they do not carry
        a complete kci stamp (any of the six missing, or not managed by kci).
        The provenance is not read."""
        var managed = String("")
        var machine = String("")
        var cell = String("")
        var resource = String("")
        var role = String("")
        var scheme = String("")
        var seen = 0
        for i in range(len(labels)):
            ref l = labels[i]
            if l.key == LABEL_MANAGED_BY:
                managed = l.value.copy()
                seen |= 1
            elif l.key == LABEL_MACHINE:
                machine = l.value.copy()
                seen |= 2
            elif l.key == LABEL_CELL:
                cell = l.value.copy()
                seen |= 4
            elif l.key == LABEL_RESOURCE:
                resource = l.value.copy()
                seen |= 8
            elif l.key == LABEL_ROLE:
                role = l.value.copy()
                seen |= 16
            elif l.key == LABEL_SCHEME:
                scheme = l.value.copy()
                seen |= 32
        if seen != 63 or managed != MANAGED_BY_KCI:
            return String("")
        return (
            String("kci:v")
            + scheme
            + String(" owner=")
            + machine
            + String("/")
            + cell
            + String("/")
            + resource
            + String("/")
            + role
        )


struct CellScope(Copyable, Movable, Deinitable):
    """What an apply runs in: the release machine, the cell, the provenance of
    this run, the logical ids the run was told to ADOPT (each resource whose `adopt` is set, the
    only way an unstamped object of a wanted name is taken over), and the id
    of the validation run this apply is part of (None outside one)."""

    var machine: String
    var cell: String
    var provenance: Provenance
    var adopt: List[String]
    var validation_run_id: Optional[String]

    def __init__(
        out self,
        machine: String,
        cell: String,
        provenance: Provenance = Provenance.none(),
        var adopt: List[String] = List[String](),
        validation_run_id: Optional[String] = None,
    ):
        self.machine = machine
        self.cell = cell
        self.provenance = provenance.copy()
        self.adopt = adopt^
        self.validation_run_id = validation_run_id.copy()

    def __init__(out self, *, copy: Self):
        self.machine = copy.machine.copy()
        self.cell = copy.cell.copy()
        self.provenance = copy.provenance.copy()
        self.adopt = copy.adopt.copy()
        self.validation_run_id = copy.validation_run_id.copy()

    @staticmethod
    def unowned() -> CellScope:
        """The engine's older single-cell form: no stamp, no foreign check, the
        store keyed by `("", "", logical id)`. Not accepted by kci's deploy
        path."""
        return CellScope(String(""), String(""))

    def owned(self) -> Bool:
        return self.machine.byte_length() > 0 and self.cell.byte_length() > 0

    def key(self, logical_id: String) -> ResourceKey:
        return ResourceKey(self.machine.copy(), self.cell.copy(), logical_id)

    def stamp(self, owner: String, logical_id: String) -> OwnerStamp:
        """The stamp of node `logical_id` lowered from authored resource
        `owner`: resource = the owner, role = the rest of the node id (node
        ids are `<resource>/<role>`). A node with no owner is its own resource
        with an empty role. The stamp carries this scope's provenance and
        validation run."""
        var resource = logical_id.copy()
        var role = String("")
        var prefix = owner + String("/")
        if owner.byte_length() > 0 and logical_id.startswith(prefix):
            resource = owner.copy()
            role = String(logical_id[byte = prefix.byte_length() : logical_id.byte_length()])
        return OwnerStamp(
            self.machine.copy(),
            self.cell.copy(),
            resource^,
            role^,
            KCI_SCHEME,
            self.provenance.copy(),
            self.validation_run_id.copy(),
        )

    def adopts(self, logical_id: String) -> Bool:
        for i in range(len(self.adopt)):
            if self.adopt[i] == logical_id:
                return True
        return False


def ownership_problem(
    logical_id: String,
    identity: String,
    present: Bool,
    live_physical_id: String,
    live_stamp: String,
    recorded_physical_id: String,
    adopting: Bool,
) -> String:
    """Why kci must not act on node `logical_id`'s live object, or empty when
    it may. `identity` is the stamp this node's object must carry;
    `recorded_physical_id` is what the store confirmed for the node (empty if
    nothing). The table is the file header's."""
    if not present:
        return String("")
    if live_stamp == identity:
        if (
            recorded_physical_id.byte_length() > 0
            and live_physical_id.byte_length() > 0
            and recorded_physical_id != live_physical_id
        ):
            return (
                String("conflict: the ledger records physical id \"")
                + recorded_physical_id
                + String("\" but the object stamped for this node is \"")
                + live_physical_id
                + String("\"")
            )
        return String("")
    if live_stamp.byte_length() == 0:
        if recorded_physical_id.byte_length() > 0:
            return String(
                "conflict: the ledger records this node, but the live object"
                " carries no kci stamp (stripped, or replaced out of band);"
                " kci does not act on it"
            )
        if adopting:
            return String("")
        return (
            String("foreign: an object named for this node exists and carries no")
            + String(" kci stamp; kci never takes it over unless its resource writes")
            + String(" adopt (which puts ")
            + logical_id
            + String(" in the run's adopt list)")
        )
    return (
        String("conflict: the live object is stamped for another owner (")
        + live_stamp
        + String(")")
    )


def refusal_text(
    scope: CellScope, verb: String, problems: List[String]
) -> String:
    """One refusal naming every problem node. `problems` holds
    `<logical id>: <why>` lines."""
    var s = String(REFUSED_TOKEN) + String(" ") + verb + String(" in cell \"")
    s += scope.cell + String("\" of machine \"") + scope.machine
    s += String("\" before any change: ") + String(len(problems))
    s += String(" node(s) kci may not act on:")
    for i in range(len(problems)):
        s += String("\n  ") + problems[i]
    return s^
