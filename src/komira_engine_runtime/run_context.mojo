# =============================================================================
# run_context.mojo -- what a run of a physical plan reads from its host
# =============================================================================
#
# A host runs physical plans it lowered itself (`lower(segment, host_profile,
# resolved_inputs)`); it does not optimize. So a run context carries no
# optimizer and no planner: it exposes the host profile the plan was lowered
# under and the worker count the drivers dispatch across. One run context
# serves both drivers: a plan with an unbounded scan runs the same physical
# plan under the streaming driver, in epochs, and nothing here branches on
# whether the input is bounded.
#
# `RunContext` declares only value-returning methods: a Mojo trait method
# cannot return a reference bound to `self`, so the per-run state a driver
# borrows (dispatcher, caches, slot pools) stays on the concrete context.
# =============================================================================

from komira_host_profile.host_profile import HostProfile


trait RunContext:
    """The per-run view of the executor host that a driver reads."""

    def host_profile(self) -> HostProfile:
        """The host profile the run's plan was lowered under."""
        ...

    def num_workers(self) -> Int:
        """The compute workers the run dispatches across (at least 1)."""
        ...
