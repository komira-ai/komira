# =============================================================================
# ExecResult — operator-to-scheduler signaling enum
# =============================================================================
#
# Operators must be able to emit MORE than one output per input (e.g.,
# unnest, cross-join, window expansions). The scheduler uses ExecResult to
# decide whether to pull another morsel from the source or re-invoke the
# operator on pending state.
#
# Rationale for a plain enum (not sum-type): Mojo's `Variant` is heavy for a
# hot-path signal that carries no payload. Output morsels are emitted via an
# output buffer/sink; ExecResult only communicates the control-flow intent.
# =============================================================================


comptime NEED_MORE_INPUT: UInt8 = 0
"""Operator consumed the morsel; ready for another. Scheduler pulls next."""

comptime HAVE_MORE_OUTPUT: UInt8 = 1
"""Operator has additional output buffered; call execute again before pulling next input."""

comptime FINISHED: UInt8 = 2
"""Operator will not produce more output even with more input (e.g., LIMIT reached)."""

comptime FILTERED_EMPTY: UInt8 = 3
"""Morsel produced zero output rows (e.g., filter with selectivity 0). Fast path for NEED_MORE_INPUT."""


struct ExecResult(ImplicitlyCopyable, Movable):
    """Thin wrapper around the UInt8 tag so the code reads as `ExecResult(NEED_MORE_INPUT)`."""

    var tag: UInt8

    def __init__(out self, tag: UInt8):
        self.tag = tag

    @always_inline
    def is_need_more_input(self) -> Bool:
        return self.tag == NEED_MORE_INPUT

    @always_inline
    def is_have_more_output(self) -> Bool:
        return self.tag == HAVE_MORE_OUTPUT

    @always_inline
    def is_finished(self) -> Bool:
        return self.tag == FINISHED

    @always_inline
    def is_filtered_empty(self) -> Bool:
        return self.tag == FILTERED_EMPTY
