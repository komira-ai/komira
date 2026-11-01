# =============================================================================
# split_ids.mojo: the 16-byte split uuid
# =============================================================================
#
# A split's object key embeds its uuid, and the split `put` overwrites without a
# precondition. Two writers must therefore never mint the same uuid, and a
# restarted process (whose sequence starts again at 1) must not mint a key an
# earlier process already used. The uuid is laid out as
#
#   byte 0       the worker discriminant (one per dispatcher of a process)
#   bytes 1..7   the low 56 bits of the install-time epoch, in microseconds,
#                little-endian: the wall clock read once when the dispatcher
#                was built
#   bytes 8..15  the per-dispatcher sequence, little-endian
#
# the same rule `komira_log_index`'s consumer uses for its split keys.
# =============================================================================


def make_split_uuid(
    worker_disc: UInt8, epoch_us: UInt64, seq: Int64
) -> InlineArray[UInt8, 16]:
    """The split uuid of the `seq`-th split of the dispatcher that was built at
    `epoch_us` with discriminant `worker_disc`."""
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    u[0] = worker_disc
    for i in range(7):
        u[1 + i] = UInt8(Int((epoch_us >> UInt64(i * 8)) & UInt64(0xFF)))
    var s = UInt64(seq)
    for i in range(8):
        u[8 + i] = UInt8(Int((s >> UInt64(i * 8)) & UInt64(0xFF)))
    return u^
