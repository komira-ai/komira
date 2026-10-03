# =============================================================================
# UdfDescriptor -- Metadata for scalar UDFs
# =============================================================================
#
# Mojo trait method defaults are limited; rather than forcing every UDF to define 5+
# metadata methods, metadata lives in a separate UdfDescriptor struct alongside
# the prototype in the registry.
# =============================================================================


# =============================================================================
# FunctionStability -- volatility level controlling constant folding
# =============================================================================

struct FunctionStability(ImplicitlyCopyable, Movable, Copyable, Deinitable):
    """Function volatility level, controlling constant folding and caching.

    Three levels:
        IMMUTABLE: Same input -> same output always. Safe to constant-fold.
        STABLE: Same within a single query. Not foldable across queries.
        VOLATILE: May differ per call (e.g., random()). Never foldable.
    """
    var _tag: UInt8

    def __init__(out self, tag: UInt8):
        self._tag = tag

    def __init__(out self, tag: Int):
        self._tag = UInt8(tag)

    comptime IMMUTABLE = FunctionStability(0)
    comptime STABLE = FunctionStability(1)
    comptime VOLATILE = FunctionStability(2)


# =============================================================================
# NullHandling -- null handling strategy for scalar UDFs
# =============================================================================

struct NullHandling(ImplicitlyCopyable, Movable, Copyable, Deinitable):
    """Null handling strategy for scalar UDFs.

    Three modes:
        MANUAL: UDF handles nulls itself. Full control (e.g., COALESCE).
        PROPAGATE: Null-in -> null-out. Engine masks output at null positions.
        SKIP_NULL_FAST_PATH: Call evaluate when no nulls; fall back to
            PROPAGATE when nulls exist.
    """
    var _tag: UInt8

    def __init__(out self, tag: UInt8):
        self._tag = tag

    def __init__(out self, tag: Int):
        self._tag = UInt8(tag)

    comptime MANUAL = NullHandling(0)
    comptime PROPAGATE = NullHandling(1)
    comptime SKIP_NULL_FAST_PATH = NullHandling(2)


# =============================================================================
# UdfDescriptor -- metadata stored alongside the UDF prototype
# =============================================================================

struct UdfDescriptor(Movable, Copyable, Deinitable):
    """Metadata for a scalar UDF, stored alongside the prototype in the registry.

    Fields:
        name: Human-readable name for error messages and EXPLAIN output.
        stability: Volatility level controlling constant folding.
        null_handling: Null handling strategy (MANUAL, PROPAGATE, SKIP_NULL).
        preserves_ordering: Whether the UDF preserves row ordering.
        input_columns: Optional column indices for input projection.
            None means full input schema.
    """
    var name: String
    var stability: FunctionStability
    var null_handling: NullHandling
    var preserves_ordering: Bool
    var input_columns: Optional[List[Int]]

    def __init__(out self, name: String):
        """Minimal descriptor with sensible defaults.

        Defaults: IMMUTABLE stability, MANUAL null handling, no ordering
        preservation, no input column restriction.

        Args:
            name: Human-readable name for this UDF.
        """
        self.name = name
        self.stability = FunctionStability.IMMUTABLE
        self.null_handling = NullHandling.MANUAL
        self.preserves_ordering = False
        self.input_columns = None
