# =============================================================================
# komira_git/sha1dc.mojo -- SHA-1 with collision detection (sha1dc).
# =============================================================================
#
# A port of sha1collisiondetection (MIT License, notice at the end of this
# header; lib/sha1.c of release stable-v1.0.3), the SHA-1 git hashes
# objects with. It computes SHA-1 and, for every 64-byte block, checks
# whether the block is one half of a near-collision built from one of 32
# known disturbance vectors (sha1dc_ubc.mojo): for each vector whose
# unavoidable bit conditions the block meets, it applies the vector's message
# difference to the expanded block, recompresses backward and forward from
# the stored state at step 58 or 65, and reports a collision when the other
# block leads to the same chaining value (or, with reduced-round detection
# on, starts from the same one). The SHAttered PDFs are such a pair.
#
# On detection the digest is upstream's "safe hash" by default: the block is
# compressed twice more, so a detected collision does not hash to the value
# its twin hashes to. With safe hashing off the digest is plain SHA-1.
# Without a detection the digest is plain SHA-1 either way.
#
# Callers that must refuse a collision use `sha1dc` (one shot) or
# `Sha1dc.digest`, which raise the error OBJECT_ID_COLLISION names; object
# ids (`hash_object`) are computed this way.
#
# Upstream unrolls each step with rotating register names; this port keeps
# one register order (a, b, c, d, e) and unrolls at compile time, so a stored
# state is (a, b, c, d, e) before the step it is named for.
#
# -----------------------------------------------------------------------------
# Upstream attribution (sha1collisiondetection, LICENSE.txt):
#
#   MIT License
#
#   Copyright (c) 2017:
#       Marc Stevens
#       Cryptology Group
#       Centrum Wiskunde & Informatica
#       P.O. Box 94079, 1090 GB Amsterdam, Netherlands
#       marc@marc-stevens.nl
#
#       Dan Shumow
#       Microsoft Research
#       danshu@microsoft.com
#
#   Permission is hereby granted, free of charge, to any person obtaining a
#   copy of this software and associated documentation files (the
#   "Software"), to deal in the Software without restriction, including
#   without limitation the rights to use, copy, modify, merge, publish,
#   distribute, sublicense, and/or sell copies of the Software, and to permit
#   persons to whom the Software is furnished to do so, subject to the
#   following conditions:
#
#   The above copyright notice and this permission notice shall be included
#   in all copies or substantial portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
#   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
#   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
#   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
#   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
#   USE OR OTHER DEALINGS IN THE SOFTWARE.
# =============================================================================

from .sha1dc_ubc import _ALL_DVS, _DV_COUNT, _dv_field, _dv_word, _ubc_check

comptime OBJECT_ID_COLLISION: StaticString = "komira_git: ObjectIdCollision: "
"""The prefix of the error raised when SHA-1 collision detection fires; test
an error's text with `is_object_id_collision`."""

comptime _IV0: UInt32 = 0x67452301
comptime _IV1: UInt32 = 0xEFCDAB89
comptime _IV2: UInt32 = 0x98BADCFE
comptime _IV3: UInt32 = 0x10325476
comptime _IV4: UInt32 = 0xC3D2E1F0

comptime _Words = InlineArray[UInt32, 80]
comptime _State = InlineArray[UInt32, 5]


def is_object_id_collision(message: String) -> Bool:
    """True when `message` (an error's text) is the error raised for a
    detected SHA-1 collision."""
    return message.startswith(OBJECT_ID_COLLISION)


def _collision_error(what: String) -> Error:
    """The error raised for a detected collision in `what`."""
    return Error(
        String(OBJECT_ID_COLLISION) + what
        + " holds a block of a SHA-1 collision attack"
    )


@always_inline
def _rotl[n: Int](x: UInt32) -> UInt32:
    return (x << UInt32(n)) | (x >> UInt32(32 - n))


@always_inline
def _f[t: Int](b: UInt32, c: UInt32, d: UInt32) -> UInt32:
    """The boolean function of step `t`."""
    comptime if t < 20:
        return d ^ (b & (c ^ d))
    elif t < 40:
        return b ^ c ^ d
    elif t < 60:
        return (b & c) + (d & (b ^ c))
    else:
        return b ^ c ^ d


@always_inline
def _k[t: Int]() -> UInt32:
    """The additive constant of step `t`."""
    comptime if t < 20:
        return 0x5A827999
    elif t < 40:
        return 0x6ED9EBA1
    elif t < 60:
        return 0x8F1BBCDC
    else:
        return 0xCA62C1D6


@always_inline
def _expand(mut w: _Words):
    """Fill w[16:80] from w[0:16] (SHA-1 message expansion)."""
    comptime for t in range(16, 80):
        w[t] = _rotl[1](w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16])


@always_inline
def _forward[first: Int, last: Int](mut s: _State, w: _Words):
    """Run steps first..last-1 on the state `s` (the state before step
    `first`), leaving the state before step `last`."""
    var a = s[0]
    var b = s[1]
    var c = s[2]
    var d = s[3]
    var e = s[4]
    comptime for t in range(first, last):
        var x = _rotl[5](a) + _f[t](b, c, d) + e + _k[t]() + w[t]
        e = d
        d = c
        c = _rotl[30](b)
        b = a
        a = x
    s[0] = a
    s[1] = b
    s[2] = c
    s[3] = d
    s[4] = e


@always_inline
def _backward[last: Int](mut s: _State, w: _Words):
    """Undo steps last-1 down to 0 on the state `s` (the state before step
    `last`), leaving the state before step 0."""
    var a = s[0]
    var b = s[1]
    var c = s[2]
    var d = s[3]
    var e = s[4]
    comptime for i in range(last):
        comptime t = last - 1 - i
        var a0 = b
        var b0 = _rotl[2](c)
        var c0 = d
        var d0 = e
        var e0 = a - (_rotl[5](a0) + _f[t](b0, c0, d0) + _k[t]() + w[t])
        a = a0
        b = b0
        c = c0
        d = d0
        e = e0
    s[0] = a
    s[1] = b
    s[2] = c
    s[3] = d
    s[4] = e


@always_inline
def _load_block(data: Span[UInt8, _], pos: Int, mut w: _Words):
    """w[0:16] from the 64 bytes at data[pos], big-endian. The caller has
    checked that pos + 64 <= len(data)."""
    # SAFETY: p points into `data`, which the caller borrows for the whole
    # call, and the caller has checked that data[pos] to data[pos + 63]
    # exist; only those 64 bytes are read, once each.
    var p = data.unsafe_ptr() + pos
    comptime for i in range(16):
        w[i] = (
            (UInt32(p[4 * i]) << 24)
            | (UInt32(p[4 * i + 1]) << 16)
            | (UInt32(p[4 * i + 2]) << 8)
            | UInt32(p[4 * i + 3])
        )


def _compress(mut ihv: _State, w: _Words):
    """One SHA-1 compression of the expanded block `w` into `ihv`."""
    var s = ihv.copy()
    _forward[0, 80](s, w)
    for i in range(5):
        ihv[i] += s[i]


def _compress_states(
    mut ihv: _State, mut w: _Words, mut s58: _State, mut s65: _State
):
    """Expand `w` and compress it into `ihv`, keeping the states before steps
    58 and 65 (the steps the disturbance vectors recompress from)."""
    _expand(w)
    var s = ihv.copy()
    _forward[0, 58](s, w)
    s58 = s.copy()
    _forward[58, 65](s, w)
    s65 = s.copy()
    _forward[65, 80](s, w)
    for i in range(5):
        ihv[i] += s[i]


def _recompress[step: Int](
    me2: _Words, state: _State, mut ihvin: _State, mut ihvout: _State
):
    """From `state`, the state before step `step` of the block being
    checked, compute the chaining values a block with expanded message `me2`
    reaching that state would start from (`ihvin`) and end at (`ihvout`)."""
    var back = state.copy()
    _backward[step](back, me2)
    ihvin = back.copy()
    var fwd = state.copy()
    _forward[step, 80](fwd, me2)
    for i in range(5):
        ihvout[i] = back[i] + fwd[i]


@always_inline
def _same(x: _State, y: _State) -> Bool:
    return (
        (x[0] ^ y[0]) | (x[1] ^ y[1]) | (x[2] ^ y[2]) | (x[3] ^ y[3])
        | (x[4] ^ y[4])
    ) == 0


struct Sha1dc(Copyable, Movable):
    """Streaming SHA-1 with collision detection (sha1collisiondetection).

    Detection, the unavoidable-bit-condition filter and safe hashing are on
    by default and reduced-round detection is off, as upstream sets them;
    the `set_*` switches change them before the first `update`.
    """

    var _ihv: _State
    var _buffer: InlineArray[UInt8, 64]
    var _total: UInt64
    var _found: Bool
    var _safe_hash: Bool
    var _use_ubc: Bool
    var _detect: Bool
    var _reduced_round: Bool
    # The last disturbance vector `_process` recompressed, as upstream's
    # SHA1_CTX keeps it: its expanded message (the block's words xor the
    # DV's difference) and the chaining value the recompression started
    # from. Zero until a DV is recompressed; komira_git_conformance compares
    # them with upstream's ctx->m2 and ctx->ihv2.
    var _m2: _Words
    var _ihv2: _State
    # The disturbance vectors `_process` recompressed for the last block,
    # bit k for DV k: the ubc mask with the filter on, all 32 with it off,
    # fewer when a detection ends the loop early, zero with detection off.
    # komira_git_conformance compares it with upstream's ubc_check mask.
    var _recompressed: UInt32

    def __init__(out self):
        """An empty hash state with upstream's default switches."""
        self._ihv = [_IV0, _IV1, _IV2, _IV3, _IV4]
        self._buffer = InlineArray[UInt8, 64](fill=0)
        self._total = 0
        self._found = False
        self._safe_hash = True
        self._use_ubc = True
        self._detect = True
        self._reduced_round = False
        self._m2 = _Words(fill=0)
        self._ihv2 = _State(fill=0)
        self._recompressed = 0

    def set_safe_hash(mut self, on: Bool):
        """Whether a detected block is compressed twice more (default on), so
        that the digest differs from plain SHA-1's."""
        self._safe_hash = on

    def set_use_ubc(mut self, on: Bool):
        """Whether to check only the disturbance vectors whose unavoidable bit
        conditions a block meets (default on). Off checks all 32 for every
        block: slower, same result."""
        self._use_ubc = on

    def set_detect_collision(mut self, on: Bool):
        """Whether to detect collisions at all (default on). Off is plain
        SHA-1."""
        self._detect = on

    def set_detect_reduced_round_collision(mut self, on: Bool):
        """Whether to also report collisions of reduced-step SHA-1 (default
        off; upstream uses it to test the detector)."""
        self._reduced_round = on

    def collision_found(self) -> Bool:
        """True once a block absorbed so far was detected as part of a
        collision."""
        return self._found

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data`."""
        var n = len(data)
        var pos = 0
        var left = Int(self._total & 63)
        if left > 0:
            var take = min(64 - left, n)
            for i in range(take):
                self._buffer[left + i] = data[i]
            self._total += UInt64(take)
            pos = take
            if left + take < 64:
                return
            self._process_buffer()
        while n - pos >= 64:
            var w = _Words(uninitialized=True)
            _load_block(data, pos, w)
            self._process(w)
            self._total += 64
            pos += 64
        for i in range(n - pos):
            self._buffer[i] = data[pos + i]
        self._total += UInt64(n - pos)

    def finalize_into(self, mut out: InlineArray[UInt8, 20]) -> Bool:
        """Write the digest to `out`; True when a collision was detected (the
        digest is then the safe hash, unless safe hashing is off). The state
        is not changed, so more data may be absorbed afterwards."""
        var h = self.copy()
        var bits = h._total << 3
        h._push_byte(0x80)
        while (h._total & 63) != 56:
            h._push_byte(0)
        for i in range(8):
            h._push_byte(UInt8((bits >> UInt64(56 - 8 * i)) & 0xFF))
        for i in range(5):
            var v = h._ihv[i]
            out[4 * i] = UInt8(v >> 24)
            out[4 * i + 1] = UInt8((v >> 16) & 0xFF)
            out[4 * i + 2] = UInt8((v >> 8) & 0xFF)
            out[4 * i + 3] = UInt8(v & 0xFF)
        return h._found

    def digest(self) raises -> InlineArray[UInt8, 20]:
        """The digest, or the OBJECT_ID_COLLISION error when a collision was
        detected."""
        var out = InlineArray[UInt8, 20](fill=0)
        if self.finalize_into(out):
            raise _collision_error(
                "input of " + String(Int(self._total)) + " bytes"
            )
        return out^

    def _push_byte(mut self, b: UInt8):
        self._buffer[Int(self._total & 63)] = b
        self._total += 1
        if (self._total & 63) == 0:
            self._process_buffer()

    def _process_buffer(mut self):
        var w = _Words(uninitialized=True)
        comptime for i in range(16):
            w[i] = (
                (UInt32(self._buffer[4 * i]) << 24)
                | (UInt32(self._buffer[4 * i + 1]) << 16)
                | (UInt32(self._buffer[4 * i + 2]) << 8)
                | UInt32(self._buffer[4 * i + 3])
            )
        self._process(w)

    def _process(mut self, mut w: _Words):
        """Compress the block whose first 16 words are `w`, then check it
        against the disturbance vectors (upstream's sha1_process)."""
        var ihv1 = self._ihv.copy()
        var s58 = _State(fill=0)
        var s65 = _State(fill=0)
        _compress_states(self._ihv, w, s58, s65)
        self._recompressed = 0
        if not self._detect:
            return
        var mask = _ALL_DVS
        if self._use_ubc:
            mask = _ubc_check(w)
        if mask == 0:
            return
        var ihvtmp = _State(fill=0)
        for dv in range(_DV_COUNT):
            if ((mask >> UInt32(dv)) & 1) == 0:
                continue
            for t in range(16):
                self._m2[t] = w[t] ^ _dv_word(dv, t)
            _expand(self._m2)
            if _dv_field(dv, 3) == 58:
                _recompress[58](self._m2, s58, self._ihv2, ihvtmp)
            else:
                _recompress[65](self._m2, s65, self._ihv2, ihvtmp)
            self._recompressed |= UInt32(1) << UInt32(dv)
            if _same(ihvtmp, self._ihv) or (
                self._reduced_round and _same(ihv1, self._ihv2)
            ):
                self._found = True
                if self._safe_hash:
                    _compress(self._ihv, w)
                    _compress(self._ihv, w)
                return


def sha1dc(data: Span[UInt8, _]) raises -> InlineArray[UInt8, 20]:
    """The SHA-1 digest of `data`, or the OBJECT_ID_COLLISION error when
    `data` holds a block of a detected collision."""
    var h = Sha1dc()
    h.update(data)
    return h.digest()
