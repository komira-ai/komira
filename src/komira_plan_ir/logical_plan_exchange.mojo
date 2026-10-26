# =============================================================================
# logical_plan_exchange — the payload of a `PLAN_EXCHANGE` node
# =============================================================================
#
# An exchange is where rows move between partitions: the producer places one
# for the maximum host count it declares, with `partitions = 0`, and the
# coordinator fills `partitions` in when it cuts the plan into segments
# (docs/design/optimized_plan.md §5.2, §8). Nothing in this tree produces or
# lowers one yet; the node exists so that a plan can state where its
# exchanges are.
#
# Kept out of `logical_plan_variants.mojo` only for size. Like the variants,
# this module and `logical_plan.mojo` import each other; the recursive edge
# goes through `OwnedPointer[LogicalPlan]`.
# =============================================================================

from std.memory import OwnedPointer

from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_ir.plan_decisions import EXCHANGE_KEY_ENCODING_UNSET


struct ExchangeData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_EXCHANGE`.

    The node's output schema is its child's: an exchange moves rows, it does
    not change them.

    Fields:
        child: the input whose rows are redistributed.
        kind: one of `EXCHANGE_KIND_*` (GATHER, BROADCAST, HASH, RANGE).
        keys: the partitioning columns of a HASH exchange, by name in the
            child's schema. Empty for every other kind.
        key_encoding: how the key values are encoded for partitioning, so
            that two exchanges feeding one join agree. The design names no
            values yet; `EXCHANGE_KEY_ENCODING_UNSET` is the only one.
        order_keys, descending, nulls_first: the ordering the exchange
            preserves or partitions by (RANGE), as parallel lists in the shape
            of `SortData`. Empty when the exchange keeps no order.
        partitions: the fan-out. 0 means "filled in at the cut".
        adaptive_allowed: the host may coalesce reducers and split skewed
            partitions at a sealed stage boundary.
        key_groups: the number of buckets the keys hash into when the
            exchange feeds keyed state (docs/design/optimized_plan.md §8.4):
            fixed for the plan's life, so state can be moved group by group.
            Greater than 0 only on a HASH exchange; 0 everywhere else.
    """

    var child: OwnedPointer[LogicalPlan]
    var kind: UInt8
    var keys: List[String]
    var key_encoding: UInt8
    var order_keys: List[String]
    var descending: List[Bool]
    var nulls_first: List[Bool]
    var partitions: Int
    var adaptive_allowed: Bool
    var key_groups: Int

    def __init__(
        out self,
        var child: LogicalPlan,
        kind: UInt8,
        var keys: List[String],
        key_encoding: UInt8 = EXCHANGE_KEY_ENCODING_UNSET,
        var order_keys: List[String] = List[String](),
        var descending: List[Bool] = List[Bool](),
        var nulls_first: List[Bool] = List[Bool](),
        partitions: Int = 0,
        adaptive_allowed: Bool = False,
        key_groups: Int = 0,
    ):
        self.child = OwnedPointer(child^)
        self.kind = kind
        self.keys = keys^
        self.key_encoding = key_encoding
        self.order_keys = order_keys^
        self.descending = descending^
        self.nulls_first = nulls_first^
        self.partitions = partitions
        self.adaptive_allowed = adaptive_allowed
        self.key_groups = key_groups

    def copy(self) -> Self:
        """Deep-clone the ExchangeData (recurses into the child plan)."""
        return Self(
            self.child[].copy(),
            self.kind,
            self.keys.copy(),
            self.key_encoding,
            self.order_keys.copy(),
            self.descending.copy(),
            self.nulls_first.copy(),
            self.partitions,
            self.adaptive_allowed,
            self.key_groups,
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass
