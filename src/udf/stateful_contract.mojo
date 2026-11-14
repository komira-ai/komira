# =============================================================================
# stateful_contract.mojo — the parallelism contract a stateful UDF declares
# =============================================================================
#
# UDF-DESIGN Deliverable 3. A
# stateful `MapFn` / `FilterFn` carries a `comptime parallelism: StatefulContract`
# member; the engine reads it at plan-compile to pick the execution skeleton.
# Four contracts:
#   * `stateless`      — read-only `self`, any order, full morsel parallelism
#                        (the default).
#   * `serial_ordered` — pinned to one worker, morsels fed in plan order
#                        (single-threaded for this stage).
#   * `mergeable`      — per-worker partial state + a user `merge` at stage end
#                        (commutative-associative state only).
#   * `partition_local`— hash-partition by `partition_keys`, optionally
#                        sort each partition by `order_keys`, serial-within /
#                        parallel-across (SQL `OVER (PARTITION BY ... ORDER BY)`
#                        semantics). The partition/order
#                        keys are comptime — part of the UDF's identity.
#
# This ships `stateless` only (the run_row/run_scalar path); the other
# three are not served yet — but `StatefulContract` exists because the
# operators read `parallelism.tag` and the IR snapshots it on `UdfData`.
#
# The comptime `KeyList` machinery (for `partition_local`) works — the same `@fieldwise_init`-struct-with-a-`List`-field shape as
# `SchemaDescriptor`; iterate via `comptime for ... comptime x = list[i]`.
# =============================================================================


# --- the contract tags (the runtime `UdfData.parallelism_tag` is a snapshot
#     of `StatefulContract.tag`) ---
comptime CONTRACT_STATELESS: UInt8 = 0
comptime CONTRACT_SERIAL_ORDERED: UInt8 = 1
comptime CONTRACT_MERGEABLE: UInt8 = 2
comptime CONTRACT_PARTITION_LOCAL: UInt8 = 3


@fieldwise_init
struct KeyEntry(Copyable, Movable):
    """One partition / order key: `(column-name, ascending)`. `name` is
    `String`, not `StringLiteral` (parametric in 1.0.0b1). This only honors
    `ascending=True` (descending / NULLS-FIRST is a sequenced-later item)."""

    var name: String
    var ascending: Bool


@fieldwise_init
struct KeyList(Copyable, Movable):
    """A comptime list of `KeyEntry` — used for `partition_local`'s
    `partition_keys` / `order_keys`. Empty `KeyList()` means "no keys"
    (the `stateless`/`serial_ordered`/`mergeable` cases, and the
    "no within-partition order required" case for `partition_local`)."""

    var keys: List[KeyEntry]

    def __init__(out self):
        self.keys = List[KeyEntry]()

    def num_keys(self) -> Int:
        return len(self.keys)

    def names_joined(self) -> String:
        var s = String("")
        for i in range(len(self.keys)):
            if i > 0:
                s += ", "
            s += self.keys[i].name
        return s


@fieldwise_init
struct StatefulContract(ImplicitlyCopyable, Copyable, Movable):
    """The parallelism contract a stateful UDF declares (`comptime parallelism`
    on `MapFn`/`FilterFn`). `tag` is the runtime-snapshotable discriminator
    (-> `UdfData.parallelism_tag`); `partition_keys`/`order_keys` are comptime
    (part of the UDF's identity — they ride only on the comptime view `F`,
    not on the runtime-copy()'d `UdfData`, which gets a runtime-`List[String]`
    snapshot of them instead)."""

    var tag: UInt8
    comptime partition_keys: KeyList = KeyList()   # empty unless tag == CONTRACT_PARTITION_LOCAL
    comptime order_keys: KeyList = KeyList()       # empty = "no within-partition order required"

    # --- the three keyless contracts as comptime constants ---
    comptime stateless = StatefulContract(tag=CONTRACT_STATELESS)
    comptime serial_ordered = StatefulContract(tag=CONTRACT_SERIAL_ORDERED)
    comptime mergeable = StatefulContract(tag=CONTRACT_MERGEABLE)
    # `partition_local` is constructed with its keys, e.g.:
    #   comptime parallelism = StatefulContract(
    #       tag=CONTRACT_PARTITION_LOCAL,
    #       partition_keys=materialize[KeyList([KeyEntry("user_id", True)])](),
    #       order_keys=materialize[KeyList([KeyEntry("ts", True)])](),
    #   )

    def is_stateless(self) -> Bool:
        return self.tag == CONTRACT_STATELESS
