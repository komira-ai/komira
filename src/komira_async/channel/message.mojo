# =============================================================================
# komira_async.channel.message — cross-worker SPSC mesh envelope
# =============================================================================
# Message[T] is the SPSC mesh envelope.
# Internal-facing for the worker_main loop step 4 drain;
# consumer-surface still sees T directly via channel.recv().
#
# Bound: T: Movable & Deinitable.
# =============================================================================


@fieldwise_init
struct Message[T: Movable & Deinitable](Movable, Deinitable):
    """Cross-worker SPSC envelope.

    Carries:
      payload: T            — the value being shipped to the destination worker
      src_worker: UInt16    — origin worker for tracing / token routing
      op_id: Int64          — destination worker's op_id keyspace handle

    declares the canonical 3-field shape
    """

    var payload: Self.T
    var src_worker: UInt16
    var op_id: Int64
