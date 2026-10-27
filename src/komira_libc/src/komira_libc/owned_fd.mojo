# =============================================================================
# OwnedFd -- RAII wrapper for a POSIX file descriptor
# =============================================================================
#
# Wraps a raw Int32 file descriptor in a Movable struct that automatically
# closes the fd on destruction.  Auto-synth __moveinit__ via OwnedPointer[Int32].
#
# Why OwnedPointer: a bare `Int32` field is trivially copyable; Mojo would
# auto-synth a Copyable struct, which means both the original and the copy
# would try to close the same fd.  OwnedPointer[Int32] is Movable-only
# (not Copyable), so OwnedFd inherits Movable-only semantics from its single
# field -- exactly one owner, exactly one close.
# =============================================================================

from std.memory import OwnedPointer
from std.ffi import external_call


struct OwnedFd(Movable):
    """RAII wrapper for a POSIX file descriptor.

    Auto-synth __moveinit__ via OwnedPointer[Int32].  The fd is closed in
    __deinit__ if it is >= 0 (the validity sentinel).

    Fields:
        _fd: Heap-allocated Int32 holding the raw fd value.
             OwnedPointer ensures single-owner / single-close semantics.
    """

    var _fd: OwnedPointer[Int32]

    # =========================================================================
    # Construction
    # =========================================================================

    def __init__(out self, fd: Int32):
        """Wrap a raw POSIX fd.  Caller transfers ownership.

        Args:
            fd: A raw file descriptor.  May be negative (sentinel for
                "not yet opened").  The OwnedFd takes ownership and will
                close it on destruction if fd >= 0.
        """
        self._fd = OwnedPointer[Int32](fd)

    @staticmethod
    def from_raw(fd: Int32) -> OwnedFd:
        """Wrap a raw POSIX fd.  Caller transfers ownership.

        Convenience factory that delegates to `__init__`.

        Args:
            fd: A raw file descriptor.  May be negative (sentinel for
                "not yet opened").  The OwnedFd takes ownership and will
                close it on destruction if fd >= 0.

        Returns:
            An OwnedFd that owns the descriptor.
        """
        return OwnedFd(fd)

    # NOTE: No __moveinit__.  Auto-synthesized via OwnedPointer[Int32]'s
    # own moveinit.  This is the design point of OwnedFd.

    # =========================================================================
    # Accessors
    # =========================================================================

    @always_inline
    def raw(self) -> Int32:
        """Return the raw fd value (does NOT transfer ownership).

        Returns:
            The underlying Int32 file descriptor.
        """
        return self._fd[]

    @always_inline
    def is_valid(self) -> Bool:
        """Return True if the fd is non-negative (i.e. a real descriptor).

        Returns:
            True if `raw() >= 0`, False otherwise.
        """
        return self._fd[] >= Int32(0)

    # =========================================================================
    # Destruction
    # =========================================================================

    def __deinit__(deinit self):
        """Close the fd if it is valid (>= 0).

        SAFETY: OwnedPointer guarantees exactly one owner, so this runs
        exactly once.  The close(2) syscall is idempotent on a valid fd.
        """
        if self._fd[] >= Int32(0):
            _ = external_call["close", Int32](self._fd[])
