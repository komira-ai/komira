# =============================================================================
# komira_async.channel — cross-task communication primitives
# =============================================================================
# (Message[T] cross-worker SPSC
# envelope).
#
# Four shapes — MPSC, SPSC, Oneshot, Broadcast — each with sender/receiver
# split. There are no unifying Sender[T] / Receiver[T] traits — the four shapes' semantics don't fit one trait.
#
# Channel constructors are MODULE-LEVEL FREE FUNCTIONS matching
# tokio idiom (`mpsc::channel(cap)`, `oneshot::channel()`).
#
# Pointer discipline: every sender/receiver carries `_shared: ArcPointer[...]`
# as an internal field — encapsulated, never exposed in any public method
# signature.
# =============================================================================
