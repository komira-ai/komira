# =============================================================================
# komira_git_conformance/oracle.mojo -- sha1collisiondetection, the C library,
# as the oracle of komira_git's sha1dc.
# =============================================================================
#
# FFI-BOUNDARY: //third_party/sha1collisiondetection:sha1dc, upstream's
# lib/sha1.c and lib/ubc_check.c of stable-v1.0.3 plus its read accessors
# (komira_sha1dc_oracle.c), statically linked into this package's tests.
#   * `CSha1dc` owns the SHA1_CTX: a `List[UInt64]` of at least
#     `komira_sha1dc_ctx_size()` bytes, allocated in `__init__` and freed
#     with the struct. C reads and writes it only during each call and keeps
#     no pointer to it; the context holds no pointer itself (no callback is
#     set).
#   * Every other pointer passed (input bytes, the 20-byte digest, the
#     80-word block and the 1-word mask of `ubc_check`, the 5- and 80-word
#     outputs of `last_recompression`) is borrowed from the
#     caller for the one synchronous call; C keeps none of them.
#   * Nothing C returns is a pointer.
# =============================================================================

from std.ffi import external_call


struct CSha1dc(Movable):
    """upstream's SHA1_CTX, driven through its C API (sha1.h)."""

    var _ctx: List[UInt64]

    def __init__(out self):
        """SHA1DCInit: upstream's default switches."""
        var size = Int(external_call["komira_sha1dc_ctx_size", UInt]())
        self._ctx = List[UInt64](length=(size + 7) // 8, fill=UInt64(0))
        # SAFETY: _ctx is at least sizeof(SHA1_CTX) bytes, 8-byte aligned,
        # and owned by self; SHA1DCInit writes it and keeps no pointer.
        external_call["SHA1DCInit", NoneType](self._ctx.unsafe_ptr())

    def set_safe_hash(mut self, on: Bool):
        # SAFETY: as in __init__; the call writes one field of the context.
        external_call["SHA1DCSetSafeHash", NoneType](
            self._ctx.unsafe_ptr(), Int32(1 if on else 0)
        )

    def set_use_ubc(mut self, on: Bool):
        # SAFETY: as in __init__; the call writes one field of the context.
        external_call["SHA1DCSetUseUBC", NoneType](
            self._ctx.unsafe_ptr(), Int32(1 if on else 0)
        )

    def set_detect_collision(mut self, on: Bool):
        # SAFETY: as in __init__; the call writes one field of the context.
        external_call["SHA1DCSetUseDetectColl", NoneType](
            self._ctx.unsafe_ptr(), Int32(1 if on else 0)
        )

    def set_detect_reduced_round_collision(mut self, on: Bool):
        # SAFETY: as in __init__; the call writes one field of the context.
        external_call["SHA1DCSetDetectReducedRoundCollision", NoneType](
            self._ctx.unsafe_ptr(), Int32(1 if on else 0)
        )

    def update(mut self, data: Span[UInt8, _]):
        """SHA1DCUpdate over `data`."""
        if len(data) == 0:
            return
        # SAFETY: data is borrowed for the call and C reads exactly
        # len(data) bytes of it; the context is as in __init__.
        external_call["SHA1DCUpdate", NoneType](
            self._ctx.unsafe_ptr(), data.unsafe_ptr(), UInt(len(data))
        )

    def finalize_into(mut self, mut out: InlineArray[UInt8, 20]) -> Bool:
        """SHA1DCFinal: the digest into `out`; True when upstream reports a
        collision."""
        # SAFETY: out is 20 bytes, borrowed for the call, and C writes
        # exactly 20; the context is as in __init__.
        var rc = external_call["SHA1DCFinal", Int32](
            out.unsafe_ptr(), self._ctx.unsafe_ptr()
        )
        return rc != 0

    def last_recompression(
        mut self,
        mut ihv2: InlineArray[UInt32, 5],
        mut m2: InlineArray[UInt32, 80],
    ):
        """The last disturbance vector upstream's block check recompressed:
        ctx->ihv2 (the chaining value it started from) and ctx->m2 (its
        expanded message)."""
        # SAFETY: ihv2 is 5 words and m2 80, both borrowed for the call, and
        # C writes exactly that many; it reads two fields of the context,
        # which is as in __init__.
        external_call["komira_sha1dc_last_recompression", NoneType](
            self._ctx.unsafe_ptr(), ihv2.unsafe_ptr(), m2.unsafe_ptr()
        )


def c_ubc_check(w: InlineArray[UInt32, 80]) -> UInt32:
    """upstream's ubc_check over the 80 words `w`."""
    var mask = InlineArray[UInt32, 1](fill=0)
    # SAFETY: w is 80 words and mask 1, both borrowed for the call; C reads
    # w and writes mask[0] only.
    external_call["ubc_check", NoneType](w.unsafe_ptr(), mask.unsafe_ptr())
    return mask[0]


def c_dv_count() -> Int:
    """The number of entries of upstream's sha1_dvs."""
    return Int(external_call["komira_sha1dc_dv_count", Int32]())


def c_dv_field(dv: Int, field: Int) -> Int:
    """Field `field` of sha1_dvs[dv]: 0 dvType, 1 dvK, 2 dvB, 3 testt,
    4 maski, 5 maskb."""
    return Int(
        external_call["komira_sha1dc_dv_field", Int32](Int32(dv), Int32(field))
    )


def c_dv_word(dv: Int, t: Int) -> UInt32:
    """Word `t` (0 <= t < 80) of sha1_dvs[dv].dm."""
    return external_call["komira_sha1dc_dv_word", UInt32](Int32(dv), Int32(t))
