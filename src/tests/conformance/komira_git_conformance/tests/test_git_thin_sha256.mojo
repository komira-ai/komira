# =============================================================================
# komira_git_conformance/tests/test_git_thin_sha256.mojo -- the thin pack
# and the sha256 pack git wrote (gen_packs.sh).
# =============================================================================
#
# test_thin: `git pack-objects --thin` of main~10..main. `index_pack` must
# refuse it (its REF_DELTAs name objects main~10 has, as git index-pack
# without --fix-thin refuses it); `index_thin_pack`, given every object of
# the repository as `ExternalBases`, must index exactly the objects
# `git rev-list --objects main ^main~10` lists, with at least one delta on an
# object outside the pack (else the pack was not thin and the test proves
# nothing), and read each back with cat-file's kind and payload. Catches a
# REF_DELTA base looked up only in the pack, and a thin pack accepted as
# complete. The depth of a delta on an outside base is checked by
# komira_git's test_pack_reader, not here.
#
# test_sha256: the same history in a sha256 repository: `check_git_pack`
# with 32-byte ids in REF bases, the index and the trailer. Catches an id or
# checksum width fixed at 20 bytes anywhere in the reader or the index.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import (
    ExternalBases,
    ObjectFormat,
    PackLimits,
    index_pack,
    index_thin_pack,
    read_thin_pack_object,
)

from komira_git_conformance import check_git_pack, parse_batch, parse_ids, read_fixture


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_thin() raises:
    var f = ObjectFormat.sha1()
    var objects = parse_batch(f, Span(read_fixture("objects.batch")))
    var pack = read_fixture("thin.pack")
    var limits = PackLimits()
    var refused = String()
    try:
        _ = index_pack(f, Span(pack), limits)
    except e:
        refused = String(e)
    assert_true(refused.startswith("komira_git: pack: "))
    assert_true(refused.endswith(" deltas have no base in the pack"))
    var bases = ExternalBases(f)
    for i in range(objects.count()):
        _ = bases.add(objects.kinds[i], Span(objects.payloads[i]))
    var got = index_thin_pack(f, Span(pack), limits, bases)
    var want = parse_ids(Span(read_fixture("thin.ids")))
    assert_equal(got.index.count(), len(want))
    for i in range(len(want)):
        assert_equal(got.index.id_at(i).to_hex(), want[i])
    var outside = 0
    for i in range(len(got.entries)):
        var e = got.entries[i].copy()
        if e.is_delta() and got.index.find(e.base_id) < 0:
            outside += 1
        var k = objects.find(e.id)
        assert_true(k >= 0)
        var obj = read_thin_pack_object(Span(pack), got.index, e.id, limits, bases)
        assert_true(obj.kind == objects.kinds[k])
        assert_true(_same(obj.payload, objects.payloads[k]))
    assert_true(outside > 0)
    # Every delta whose chain ends outside the pack is one index_pack could
    # not resolve.
    var unresolvable = 0
    for i in range(len(got.entries)):
        var cur = got.entries[i].copy()
        while cur.is_delta():
            var b = got.index.find(cur.base_id)
            if b < 0:
                unresolvable += 1
                break
            var at = got.index.offset_at(b)
            for j in range(len(got.entries)):
                if got.entries[j].offset == at:
                    cur = got.entries[j].copy()
                    break
    assert_equal(refused, "komira_git: pack: " + String(unresolvable) + " deltas have no base in the pack")
    print("komira_git_conformance: thin pack, " + String(len(want)) + " objects, " + String(outside) + " deltas on outside bases")


def test_sha256() raises:
    var f = ObjectFormat.sha256()
    var objects = parse_batch(f, Span(read_fixture("objects256.batch")))
    var stats = check_git_pack(f, "sha256", objects)
    assert_true(stats.ofs_deltas > 0)
    print("komira_git_conformance: sha256 pack matches git (" + String(stats.entries) + " objects)")


def main() raises:
    test_thin()
    test_sha256()
