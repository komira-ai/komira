# =============================================================================
# komira_git_conformance/tests/test_git_packs.mojo -- the sha1 packs git
# wrote (gen_packs.sh), each read by komira_git and checked against git.
# =============================================================================
#
# For every pack, `check_git_pack` (check.mojo) requires:
#   * the index komira_git writes byte-equal to `git index-pack`'s: every
#     id, offset, CRC-32, the fan-out table, the pack checksum and the index
#     checksum. Catches an entry boundary off by a byte (wrong offsets and
#     CRCs), a wrong id (an object resolved from the wrong base or with the
#     wrong kind), a fan-out or order mistake;
#   * git's index, parsed, equal to the index komira_git built;
#   * per entry, verify-pack's offset, size in the pack, kind, delta depth
#     and base id. Catches an OFS_DELTA distance decoded without the "+1 per
#     continuation" of gitformat-pack (a wrong base, or none), a size varint
#     read with the wrong continuation or shift, a depth counted from the
#     wrong end;
#   * every object of the repository in the pack, read back by id with
#     cat-file's kind and payload. Catches a delta instruction applied wrong.
#
# Then, so the checks above ran on what they claim to: `ofs` has OFS_DELTAs
# and no REF_DELTA; `ref` has REF_DELTAs and no OFS_DELTA; `nodelta` none;
# `narrow` (window 2, depth 3) chains no deeper than 3; `deep` (depth 4095)
# chains deeper than `ofs` (depth 50) does; `stored` has deltas. And
# `ofs_large.idx`, git's index with every offset over 0x40 in the eight-byte
# table, is byte-equal to `serialize(0x40)`.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import ObjectFormat, PackLimits, index_pack, parse_pack_index

from komira_git_conformance import (
    check_git_pack,
    parse_batch,
    read_fixture,
    require_same_bytes,
    require_same_index,
)


def main() raises:
    var f = ObjectFormat.sha1()
    var objects = parse_batch(f, Span(read_fixture("objects.batch")))
    assert_true(objects.count() > 100)

    var ofs = check_git_pack(f, "ofs", objects)
    assert_true(ofs.ofs_deltas > 0)
    assert_equal(ofs.ref_deltas, 0)
    assert_true(ofs.max_depth >= 2)

    var refs = check_git_pack(f, "ref", objects)
    assert_true(refs.ref_deltas > 0)
    assert_equal(refs.ofs_deltas, 0)

    var nodelta = check_git_pack(f, "nodelta", objects)
    assert_equal(nodelta.ofs_deltas + nodelta.ref_deltas, 0)

    var narrow = check_git_pack(f, "narrow", objects)
    assert_true(narrow.ofs_deltas > 0)
    assert_true(narrow.max_depth <= 3)

    var deep = check_git_pack(f, "deep", objects)
    assert_true(deep.max_depth > ofs.max_depth)

    var stored = check_git_pack(f, "stored", objects)
    assert_true(stored.ofs_deltas > 0)

    var pack = read_fixture("ofs.pack")
    var got = index_pack(f, Span(pack), PackLimits())
    var large = read_fixture("ofs_large.idx")
    require_same_bytes("ofs_large.idx", got.index.serialize(0x40), large)
    require_same_index("ofs_large.idx parsed", got.index, parse_pack_index(f, Span(large)))
    print(
        "komira_git_conformance: sha1 packs match git (" + String(objects.count())
        + " objects; ofs depth " + String(ofs.max_depth) + ", deep depth "
        + String(deep.max_depth) + ")"
    )
