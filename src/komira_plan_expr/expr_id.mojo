# =============================================================================
# ExprId -- typed handle into the plan's expression pool
# =============================================================================
#
# An ExprId is a UInt32 newtype over an index into `Plan[S].expr_pool`. It is
# NOT a struct carrying expression fields -- it is purely a type-safety
# wrapper so that capability setters like `set_pushed_predicate(expr: ExprId)`
# cannot be accidentally called with an unrelated integer.
#
# `ProjectionSpec` is declared here too (alias `List[Int]`) to keep the small
# cluster of plan-handle types colocated. It is deliberately not a struct;
# promote it if projection grows richer (nested path projection).
# =============================================================================


@fieldwise_init
struct ExprId(ImplicitlyCopyable, Movable, Writable):
    """Opaque index into the plan's expression registry.

    Holds a UInt32 index; zero-cost at runtime vs a raw integer but prevents
    accidental mixing with unrelated integer handles (column indices,
    worker IDs, etc.) at compile time.
    """

    var id: UInt32

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("ExprId(", self.id, ")")


# ProjectionSpec: List[Int] (column indices into the source's pre-projection
# schema). Defined here as an alias for documentation; call sites use
# `List[Int]` directly to match the source trait signature exactly.
comptime ProjectionSpec = List[Int]
