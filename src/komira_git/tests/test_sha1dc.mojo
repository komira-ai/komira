# =============================================================================
# komira_git/tests/test_sha1dc.mojo -- SHA-1 with collision detection.
# =============================================================================
#
# WHERE THE VECTORS COME FROM:
#   * FIPS 180-2 appendix A: SHA-1 of "abc", of the 56-byte two-block
#     message and of one million "a" bytes; the empty message's digest.
#   * sha1collisiondetection stable-v1.0.3 (//third_party/sha1collisiondetection
#     :testdata, staged at sha1dc/test/): the two SHAttered PDFs, whose plain
#     SHA-1 is 38762cf7... for both, and a 128-byte collision of
#     reduced-step SHA-1. The digests expected with detection on are the
#     ones upstream's own `make test` asserts (its Makefile): 16e96b70... and
#     e1761773... for the PDFs (the safe hash), a56374e1... for the reduced
#     file by default, dd39885a... with reduced-round detection.
#   * the git blob ids of the two SHAttered PDFs, ba9aaa14... and
#     b621eecc...: the ids of test/shattered-1.pdf and test/shattered-2.pdf
#     in the tree of upstream's own repository at stable-v1.0.3.
#   * a generated corpus (a fixed linear congruential generator), hashed by
#     komira_crypto's `Sha1` (AWS-LC) as the reference for plain SHA-1.
#
# WHAT EACH TEST CATCHES:
#   * test_fips_vectors: a wrong step function, constant, rotation, byte
#     order or padding.
#   * test_plain_sha1_corpus: any digest that differs from plain SHA-1 on
#     ordinary input (lengths 0 to 300 cover every padding position, plus
#     multi-block lengths), with any of the switches, and with the input fed
#     in pieces split at every offset of a 150-byte message. A false
#     detection would change the digest (the safe hash) and is caught here.
#   * test_shattered_detected: detection that misses the SHAttered pair
#     (plain SHA-1 lets both through with the same digest), a safe hash that
#     is not upstream's, and the error `sha1dc` and `Sha1dc.digest` raise.
#   * test_shattered_switches: safe hashing off gives the plain digest and
#     still reports; detection off reports nothing; the unavoidable bit
#     condition filter off finds the same collision.
#   * test_reduced_round: reduced-round detection reports only when on.
#   * test_recompress_inverts: a backward step that does not undo its forward
#     step, or a state stored at the wrong step (58, 65).
#   * test_shattered_blob_has_id: hash_object refusing a blob whose
#     content is a SHAttered PDF (detection run over the bare content
#     instead of the header-prefixed stream git hashes).
#   * test_object_collision_error: the check hash_object runs on the SHA-1
#     stream of an object not raising on a detected collision, or an error
#     that does not name the object's kind and payload size (fed the
#     SHAttered PDF: no git object stream is a public collision).
#   * test_is_object_id_collision: the error test matches only that error.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import Sha1
from komira_git import (
    OBJECT_ID_COLLISION,
    ObjectFormat,
    ObjectKind,
    Sha1dc,
    hash_object,
    is_object_id_collision,
    object_header,
    sha1dc,
)
from komira_git.object_id import _sha1_object_digest
from komira_git.sha1dc import _compress_states, _expand, _recompress

comptime _SHATTERED_PLAIN = "38762cf7f55934b34d179ae6a4c80cadccbb7f0a"
comptime _SHATTERED_1_SAFE = "16e96b70000dd1e7c85b8368ee197754400e58ec"
comptime _SHATTERED_2_SAFE = "e1761773e6a35916d99f891b77663e6405313587"
comptime _REDUCED_PLAIN = "a56374e1cf4c3746499bc7c0acb39498ad2ee185"
comptime _REDUCED_SAFE = "dd39885a2a5d8f59030b451e00cb45da9f9d3828"
comptime _SHATTERED_1_BLOB = "ba9aaa145ccd24ef760cf31c74d8f7ca1a2e47b0"
comptime _SHATTERED_2_BLOB = "b621eeccd5c7edac9b7dcba35a8d5afd075e24f2"


def _nibble(v: Int) -> String:
    return chr(v + 48) if v < 10 else chr(v + 87)


def _hex(d: InlineArray[UInt8, 20]) -> String:
    var s = String()
    for i in range(20):
        var v = Int(d[i])
        s += _nibble(v >> 4)
        s += _nibble(v & 15)
    return s^


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _read(name: String) raises -> List[UInt8]:
    return Path(String("sha1dc/test/") + name).read_bytes()


def _corpus(n: Int, seed: UInt64) -> List[UInt8]:
    """`n` bytes from a fixed linear congruential generator."""
    var out = List[UInt8](capacity=n)
    var x = seed
    for _ in range(n):
        x = x * 6364136223846793005 + 1442695040888963407
        out.append(UInt8((x >> 33) & 0xFF))
    return out^


def _plain(data: Span[UInt8, _]) -> String:
    var h = Sha1()
    h.update(data)
    var d = InlineArray[UInt8, 20](fill=0)
    h.finalize_into(d)
    return _hex(d)


def _dc(
    data: Span[UInt8, _],
    safe: Bool = True,
    ubc: Bool = True,
    detect: Bool = True,
    reduced: Bool = False,
) -> Tuple[String, Bool]:
    var h = Sha1dc()
    h.set_safe_hash(safe)
    h.set_use_ubc(ubc)
    h.set_detect_collision(detect)
    h.set_detect_reduced_round_collision(reduced)
    h.update(data)
    var d = InlineArray[UInt8, 20](fill=0)
    var found = h.finalize_into(d)
    return (_hex(d), found)


def test_fips_vectors() raises:
    var empty = List[UInt8]()
    assert_equal(_hex(sha1dc(Span(empty))), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    var abc = _bytes("abc")
    assert_equal(_hex(sha1dc(Span(abc))), "a9993e364706816aba3e25717850c26c9cd0d89d")
    var two = _bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    assert_equal(_hex(sha1dc(Span(two))), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    var million = List[UInt8](length=1000000, fill=UInt8(97))
    assert_equal(_hex(sha1dc(Span(million))), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")


def test_plain_sha1_corpus() raises:
    var lengths = List[Int]()
    for n in range(301):
        lengths.append(n)
    lengths.append(1000)
    lengths.append(4096 + 7)
    lengths.append(65536 + 13)
    for i in range(len(lengths)):
        var n = lengths[i]
        var data = _corpus(n, UInt64(n) + 1)
        var want = _plain(Span(data))
        var got = _dc(Span(data))
        assert_equal(got[0], want, "length " + String(n))
        assert_false(got[1], "false detection at length " + String(n))
        assert_equal(_dc(Span(data), safe=False)[0], want)
        assert_equal(_dc(Span(data), ubc=False)[0], want)
        assert_equal(_dc(Span(data), detect=False)[0], want)
        assert_equal(_dc(Span(data), reduced=True)[0], want)
    # Fed in two pieces split at every offset, and one byte at a time.
    var msg = _corpus(150, 7)
    var want = _plain(Span(msg))
    for cut in range(151):
        var h = Sha1dc()
        h.update(Span(msg)[0:cut])
        h.update(Span(msg)[cut:150])
        var d = InlineArray[UInt8, 20](fill=0)
        _ = h.finalize_into(d)
        assert_equal(_hex(d), want, "split at " + String(cut))
    var h = Sha1dc()
    for i in range(150):
        h.update(Span(msg)[i : i + 1])
    var d = InlineArray[UInt8, 20](fill=0)
    _ = h.finalize_into(d)
    assert_equal(_hex(d), want)
    # finalize_into leaves the state as it was.
    _ = h.finalize_into(d)
    assert_equal(_hex(d), want)


def test_shattered_detected() raises:
    var one = _read("shattered-1.pdf")
    var two = _read("shattered-2.pdf")
    assert_equal(len(one), 422435)
    assert_equal(len(two), 422435)
    # The pair is a collision of plain SHA-1.
    assert_equal(_plain(Span(one)), _SHATTERED_PLAIN)
    assert_equal(_plain(Span(two)), _SHATTERED_PLAIN)
    var r1 = _dc(Span(one))
    var r2 = _dc(Span(two))
    assert_true(r1[1])
    assert_true(r2[1])
    assert_equal(r1[0], _SHATTERED_1_SAFE)
    assert_equal(r2[0], _SHATTERED_2_SAFE)
    var raised = String()
    try:
        _ = sha1dc(Span(one))
    except e:
        raised = String(e)
    assert_equal(
        raised,
        "komira_git: ObjectIdCollision: input of 422435 bytes holds a block"
        " of a SHA-1 collision attack",
    )
    var h = Sha1dc()
    h.update(Span(two)[0:1000])
    assert_true(h.collision_found())
    raised = String()
    try:
        _ = h.digest()
    except e:
        raised = String(e)
    assert_equal(
        raised,
        "komira_git: ObjectIdCollision: input of 1000 bytes holds a block"
        " of a SHA-1 collision attack",
    )


def test_shattered_switches() raises:
    var one = _read("shattered-1.pdf")
    var two = _read("shattered-2.pdf")
    var unsafe = _dc(Span(one), safe=False)
    assert_equal(unsafe[0], _SHATTERED_PLAIN)
    assert_true(unsafe[1])
    var off = _dc(Span(two), detect=False)
    assert_equal(off[0], _SHATTERED_PLAIN)
    assert_false(off[1])
    var all_dvs = _dc(Span(one), ubc=False)
    assert_equal(all_dvs[0], _SHATTERED_1_SAFE)
    assert_true(all_dvs[1])
    var all_dvs2 = _dc(Span(two), ubc=False)
    assert_equal(all_dvs2[0], _SHATTERED_2_SAFE)
    assert_true(all_dvs2[1])


def test_reduced_round() raises:
    var data = _read("sha1_reducedsha_coll.bin")
    assert_equal(len(data), 128)
    var dflt = _dc(Span(data))
    assert_equal(dflt[0], _REDUCED_PLAIN)
    assert_false(dflt[1])
    var red = _dc(Span(data), reduced=True)
    assert_equal(red[0], _REDUCED_SAFE)
    assert_true(red[1])


def test_recompress_inverts() raises:
    # With no message difference, recompressing from the state stored at step
    # 58 or 65 must give back the block's own input and output chaining
    # values: the backward steps invert the forward ones.
    var x: UInt64 = 2024
    for trial in range(256):
        var ihv = InlineArray[UInt32, 5](fill=0)
        for i in range(5):
            x = x * 6364136223846793005 + 1442695040888963407
            ihv[i] = UInt32(x >> 32)
        var w = InlineArray[UInt32, 80](fill=0)
        for t in range(16):
            x = x * 6364136223846793005 + 1442695040888963407
            w[t] = UInt32(x >> 32)
        var before = ihv.copy()
        var s58 = InlineArray[UInt32, 5](fill=0)
        var s65 = InlineArray[UInt32, 5](fill=0)
        _compress_states(ihv, w, s58, s65)
        var me2 = w.copy()
        _expand(me2)
        var ihvin = InlineArray[UInt32, 5](fill=0)
        var ihvout = InlineArray[UInt32, 5](fill=0)
        _recompress[58](me2, s58, ihvin, ihvout)
        for i in range(5):
            assert_equal(ihvin[i], before[i], "step 58 in, trial " + String(trial))
            assert_equal(ihvout[i], ihv[i], "step 58 out, trial " + String(trial))
        _recompress[65](me2, s65, ihvin, ihvout)
        for i in range(5):
            assert_equal(ihvin[i], before[i], "step 65 in, trial " + String(trial))
            assert_equal(ihvout[i], ihv[i], "step 65 out, trial " + String(trial))


def test_shattered_blob_has_id() raises:
    # git hashes a blob as "blob 422435\0" then the PDF, so the collision
    # blocks are not at the chaining value they were built for and nothing
    # is detected: each blob has the id git gives it.
    var one = _read("shattered-1.pdf")
    var two = _read("shattered-2.pdf")
    var s1 = ObjectFormat.sha1()
    assert_equal(
        hash_object(s1, ObjectKind.blob(), Span(one)).to_hex(), _SHATTERED_1_BLOB
    )
    assert_equal(
        hash_object(s1, ObjectKind.blob(), Span(two)).to_hex(), _SHATTERED_2_BLOB
    )


def test_object_collision_error() raises:
    var one = _read("shattered-1.pdf")
    var h = Sha1dc()
    h.update(Span(one))
    var raised = String()
    try:
        _ = _sha1_object_digest(h, ObjectKind.tree(), 7)
    except e:
        raised = String(e)
    assert_equal(
        raised,
        "komira_git: ObjectIdCollision: the tree of 7 bytes holds a block"
        " of a SHA-1 collision attack",
    )
    # No collision: the digest of the stream (`git hash-object` of "abc").
    var header = object_header(ObjectKind.blob(), 3)
    var plain = Sha1dc()
    plain.update(Span(header))
    plain.update(Span(_bytes("abc")))
    var d = _sha1_object_digest(plain, ObjectKind.blob(), 3)
    assert_equal(_hex(d), "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f")


def test_is_object_id_collision() raises:
    var one = _read("shattered-1.pdf")
    var msg = String()
    try:
        _ = sha1dc(Span(one))
    except e:
        msg = String(e)
    assert_true(is_object_id_collision(msg))
    assert_true(msg.startswith(OBJECT_ID_COLLISION))
    assert_false(is_object_id_collision("komira_git: loose object: empty file"))
    assert_false(is_object_id_collision(""))


def main() raises:
    test_fips_vectors()
    test_plain_sha1_corpus()
    test_shattered_detected()
    test_shattered_switches()
    test_reduced_round()
    test_recompress_inverts()
    test_shattered_blob_has_id()
    test_object_collision_error()
    test_is_object_id_collision()
    print("komira_git sha1dc tests passed")
