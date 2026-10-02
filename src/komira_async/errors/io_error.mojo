# =============================================================================
# komira_async.errors.io_error — IO-substrate errors
# =============================================================================
# Mirrors IoError.UnsupportedBackendOnThisOs
#
#
# All error structs are @value-shaped: Movable + Copyable; no heap fields apart
# from String message bodies (which are themselves Movable + Copyable in 0.26.3).
#
# Declaration-only stubs; each error site wires its own.
# =============================================================================


@fieldwise_init
struct AsyncError(Movable, Copyable, Deinitable):
    """generic async-substrate error. Most call sites raise
    this with a concrete `msg` describing the failure (drain on a draining
    Spawner, double-join on a JoinHandle, etc.)."""

    var msg: String


@fieldwise_init
struct IoError(Movable, Copyable, Deinitable):
    """IO-substrate error. Carries `fd` + `errno` + `msg` so
    operators have the kernel-level context for triage.

    UnsupportedBackendOnThisOs is constructed via the
    `unsupported_backend()` factory for the comptime-platform-guard
    raise path; the `errno` field is 0 for that variant.
    """

    var fd: Int32
    var errno: Int32
    var msg: String

    @staticmethod
    def unsupported_backend(name: String) raises -> IoError:
        """runtime construction with an
        OS-incompatible BackendKind raises this from the dispatch site."""
        raise Error("not implemented")


@fieldwise_init
struct TimeoutError(Movable, Copyable, Deinitable):
    """with_timeout deadline expiry. Carries the offending
    op_id and the duration that elapsed."""

    var op_id: Int64
    var dur_ns: Int64


@fieldwise_init
struct CancelledError(Movable, Copyable, Deinitable):
    """: raised by IoOp.wait / Spawner.spawn /
    Dispatcher.run_with_state / JoinHandle.join / Sender.send / Receiver.recv /
    AsyncMutex.lock / Semaphore.acquire / Notify.notified / Stream.next when
    the cancellation token has been signalled. NOT distinct per cancellation
    reason at v0.1 — the token's `.reason()` accessor surfaces the reason if
    the consumer needs it."""

    var op_id: Int64
    var reason: String


@fieldwise_init
struct ChannelClosed(Movable, Copyable, Deinitable):
    """Raised when send() is called on a channel whose
    receiver has been dropped (or vice versa). Recoverable — the consumer
    handles it (e.g., shut down a producer when its consumer goes away)."""

    var msg: String


@fieldwise_init
struct BroadcastSendError(Movable, Deinitable):
    """Error returned by BroadcastSender.send
    when no subscribers exist. The `kind` discriminates `AllReceiversDropped`
    (today the only variant); the recovered value is preserved generically by
    the channel's internal slot rather than embedded in the error itself.
    """

    var kind: UInt8


# Try-variants — NOT counted in the closed-surface 6 errors note.
@fieldwise_init
struct TrySendError(Movable, Copyable, Deinitable):
    """try_send returns this. Variants: 0 = Full, 1 = Closed."""

    var kind: UInt8
    var msg: String


@fieldwise_init
struct TryRecvError(Movable, Copyable, Deinitable):
    """try_recv returns this. Variants: 0 = Empty, 1 = Closed."""

    var kind: UInt8
    var msg: String
