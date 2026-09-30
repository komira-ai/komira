# =============================================================================
# process_result.mojo — ProcessResult enum-via-tag for FusedMorselOp
# =============================================================================
#
# Trait set: `(Movable, Deinitable)`. `RecordBatch` is Movable-only, so
# `Optional[RecordBatch]` cannot synthesize a copy constructor either; every
# `process_batch` body moves the return value, so Movable suffices.
# Factories take their payload by `var` (ownership transfer) for the same
# reason.
#
# Codegen: the (tag, payload, has_value) triple is returned in registers
# (w0/x1/w2 on arm64) with branchless producer code — measurably faster than
# a `Tuple[UInt8, Optional[T]]` return, whose per-variant return blocks are
# branchy and mispredict on alternating variants.
#
# Why a struct with explicit tag (not an enum tagged-union or
# Tuple[UInt8, Optional[T]]):
#   1. Mojo has no tagged-sum-with-data primitive — but this shape does not
#      need one. A @fieldwise_init struct with a `tag: UInt8` discriminant is
#      the canonical and codegen-optimal sum-type-by-tag idiom.
#   2. Calling-convention win — the ABI returns the (tag, payload, has_value)
#      triple in registers (w0/x1/w2 on arm64), producing branchless straight-
#      line code from the producer side.
#   3. The Tuple alternative pays a branch-mispredict tax on per-variant
#      return blocks.
#   4. @staticmethod constructor factories compile to the same branchless code
#      as positional construction — codegen-equivalent.
#
# Variant contract:
#   - need_input(Optional(rb)): stage fully consumed input batch and emitted
#     ONE output batch. Driver pushes rb to sink, advances source.
#   - need_input(None):         stage fully consumed input batch and emitted
#     NO output (breaker accumulation, JoinBuild). Driver advances source
#     without push.
#   - have_output(rb):          stage emitted partial output without consuming
#     the full input batch (high-fanout JoinProbe / TableFn). Driver pushes
#     rb to sink, RE-invokes process_batch on same input (retry-loop).
#   - done():                   end-of-input signaled by stage. Rare;
#     typically source signals end via None-returning next_morsel.
#
# No current conformer emits have_output: every
# Filter/Project/HashAgg/Sort/TopN/Window/JoinProbe consumes its input fully
# in one process_batch call. The driver's retry loop exists for table
# functions and other expanding stages.
#
# Driver loop dispatch idiom (canonical):
#   var result = stage.process_batch[__origin_of(bv)](bv)
#   if Int(result.tag) == ProcessResult.TAG_NEED_INPUT:
#       if result.batch:
#           sink.consume(result.batch.take())
#       current_input = None  # advance source
#   elif Int(result.tag) == ProcessResult.TAG_HAVE_OUTPUT:
#       if result.batch:
#           sink.consume(result.batch.take())
#       # current_input UNCHANGED — retry-loop
#   else:  # TAG_DONE
#       break
#
# Encapsulation invariants:
#   - ZERO UnsafePointer in trait surface or public API.
#   - ZERO wildcard origins (struct holds Optional[RecordBatch] — no origin
#     parameter).
#   - ZERO unsafe_from_address.
#   - The .batch.take() extraction in the driver loop uses Optional.take,
#     never a partial move via take_pointee.
#
# Placement rationale (komira_core, not the engine operators package):
#   - ProcessResult is the trait-method return type on FusedMorselOp. Its
#     domain is cross-package — both the engine operators (every conformer's
#     process_batch) and the engine dispatch driver loop consume it. Placing
#     it in the lowest shared dependency avoids a circular dependency.
# =============================================================================

from komira_core.arrow.schema import RecordBatch


# =============================================================================
# ProcessResult enum-via-tag
# =============================================================================


@fieldwise_init
struct ProcessResult(Movable, Deinitable):
    """One process_batch outcome, encoded as a 3-variant sum-type-by-tag.

    See module docstring for the variant contract, the codegen rationale, and
    the driver loop dispatch idiom.

    Fields:
        tag: One of TAG_NEED_INPUT (0), TAG_HAVE_OUTPUT (1), TAG_DONE (2).
        batch: Optional[RecordBatch] payload. Some(rb) when the stage emitted
            output this call; None for breaker accumulators (need_input(None))
            or the done variant.
    """

    comptime TAG_NEED_INPUT: UInt8 = 0
    comptime TAG_HAVE_OUTPUT: UInt8 = 1
    comptime TAG_DONE: UInt8 = 2

    var tag: UInt8
    var batch: Optional[RecordBatch]

    # =========================================================================
    # Constructor factories
    # =========================================================================
    #
    # @staticmethod factories compile to the same branchless code as positional
    # construction. Callers use the factories for readability;
    # @fieldwise_init's positional ctor is preserved for the rare cases (e.g.,
    # generic forwarding) that need it.

    @staticmethod
    @always_inline
    def need_input(var opt: Optional[RecordBatch]) -> Self:
        """Stage consumed input fully; advance source.

        Use need_input(Optional(rb)) when the stage emitted one output batch.
        Use need_input(None) when the stage is a breaker accumulator (HashAgg
        update, JoinBuild) — no per-batch emit.

        Takes the Optional by value (ownership transfer) because RecordBatch
        is Movable-only — implicit copy is not available, so the caller
        transfers ownership explicitly.
        """
        return Self(tag=Self.TAG_NEED_INPUT, batch=opt^)

    @staticmethod
    @always_inline
    def have_output(var rb: RecordBatch) -> Self:
        """Stage emitted partial output; driver retries on same input.

        Used by high-fanout JoinProbe streaming and table-expanding stages
        when one input row expands to >1 output batch worth of rows. The
        driver pushes the emitted batch to sink, then re-invokes
        process_batch on the SAME input morsel (no source advance).
        """
        return Self(
            tag=Self.TAG_HAVE_OUTPUT, batch=Optional[RecordBatch](rb^)
        )

    @staticmethod
    @always_inline
    def done() -> Self:
        """End-of-input signaled by stage. Driver breaks the loop.

        Rare path; typically the source signals end via None-returning
        next_morsel. Reserved for stages that intrinsically know when to
        stop (e.g., a future LIMIT-pushed-into-stage variant).
        """
        return Self(tag=Self.TAG_DONE, batch=Optional[RecordBatch](None))
