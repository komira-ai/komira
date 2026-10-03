# =============================================================================
# AN OBJECT KEY IS A BYTE STRING — EVERY DECODER IN THIS PACKAGE MUST SAY SO
# =============================================================================
#
# ⛔ THE DEFECT CLASS THIS FILE EXISTS FOR: a per-byte `chr(Int(byte))` decode.
#
# `chr` maps a CODE POINT to its UTF-8 ENCODING. A decoder that rebuilds stored
# bytes with `out += chr(Int(b))` therefore RE-ENCODES every byte >= 0x80 into
# TWO: `é` (C3 A9) -> `Ã©` (C3 83 C2 A9), `ß` (C3 9F) -> `ÃŸ` (C3 83 C2 9F).
# ASCII is the corruption's FIXED POINT, which is exactly why an all-ASCII
# corpus never sees it.
#
# ⚠ THIS PACKAGE DOCUMENTS THE CLASS IN SEVERAL PLACES (`komira_shuffle`'s `codec.mojo`,
# `delimiter_faithful_conditional_store.mojo`, and the whole of
# `tests/test_delimiter_listing_byte_faithful.mojo`), and a comment does not
# stop a copy. ⇒ A COMMENT IS NOT A GUARD. This file is the guard.
#
# THE SIX SITES, each with its own test below:
#
#   1. `objectstore_uri._bytes_to_str`    — the URI PATH is the customer's
#      OBJECT KEY. ⭐ The SDK's cloud read and write paths take
#      `parse(uri).path.raw()` straight to `FileSystem.open(key)`, so a
#      corrupted key 404s on read and a WRITE lands at a key nobody asked
#      for. The name says BYTES: a name that says ASCII invites a `chr` copy.
#   2. `path.Path.filename`               — `Path.parse` in the SAME FILE is
#      byte-exact too; the module must agree with itself.
#   3. `cas_manifest.decode_head`         — `encode_head` writes the etag RAW;
#      an asymmetric codec pair.
#   4. `sublineage_base_fold._decode_base_chunk` — the decoded shard id is fed
#      back into `_block_crc` and compared, so a non-ASCII shard id made a
#      PERFECTLY GOOD block report itself CORRUPT.
#   5. `sublineage_base_fold._first_segment_after` — the shard segment of an
#      object key; it must match its twins in `sublineage_shard_keys` and
#      `sharded_lineage`.
#   6. `local_fs_conditional_store._decode_fname_to_key` (BOTH arms) and
#      `_mkdir_p_root`.
#
# ⭐⭐ SITE 6's `%XX` ARM IS INVISIBLE TO A `chr(Int(` GREP. Spelled
# `out += chr((hi << 4) | lo)` it is the same defect with no matching text.
# ⇒ GREP THE FAMILY (`chr(` fed anything byte-valued), NEVER THE SPELLING.
#
# ⚠ THE ON-DISK FIXTURE AVOIDS DECOMPOSABLE CHARACTERS ON PURPOSE. `ü`
# (U+00FC) HAS a canonical decomposition, so a normalizing filesystem can hand
# back `u`+U+0308 and red a byte assertion with a LENGTH MISMATCH — which is
# the doubling defect's own diagnostic signature. `ß`, `東京` and `𐍈` do not
# decompose, so NFC == NFD and the assertion means what it says. Pure-function
# tests (no filesystem in the loop) deliberately use
# `Zürich`: there is nothing to normalize it, and the two fixture sets
# being DIFFERENT means a fix to one arm cannot pass both.
#
# ⚠ NOTHING HERE ASSERTS THAT TWO CODE PATHS AGREE. Agreement is also
# satisfied by both being wrong alike. Every assertion is against the EXACT
# bytes of the fixture's own source text, or against an observable the defect
# changes (a listing's membership, a CRC verdict, a directory that exists).
# =============================================================================

from komira_runtime_paths import test_tmpdir
from std.ffi import external_call
from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import (
    ManifestHead,
    decode_head,
    encode_head,
)
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
    _decode_fname_to_key,
    _encode_key_to_fname,
    _is_existing_dir,
    _mkdir_p_root,
)
from komira_objectstore.objectstore_uri import parse
from komira_objectstore.path import Path
from komira_objectstore.sublineage_base_fold import (
    _base_chunk_record_count,
    _decode_base_chunk,
    _encode_base_chunk,
    _shard_from_object_key,
)
from komira_objectstore.types import WritePrecondition


# =============================================================================
# THE FIXTURES
# =============================================================================
#
# IN-MEMORY (no filesystem, so decomposition cannot occur):
#   'Zürich'   7 bytes  5A C3 BC 72 69 63 68     2-byte lead (C3)   the decomposable case
#   '東京'      6 bytes  E6 9D B1 E4 BA AC        two 3-byte seqs
#   '𐍈'        4 bytes  F0 90 8D 88              one 4-byte seq
#   'plain'    5 bytes  ASCII — the CONTROL
#
# ON-DISK (normalization-immune only):
#   'straße'   7 bytes  · '東京' · '𐍈' · 'plain'

comptime _EXPECTED_MEM_BYTES: Int = 22  # 7 + 6 + 4 + 5
comptime _EXPECTED_DISK_BYTES: Int = 22  # 7 + 6 + 4 + 5


def _mem_names() raises -> List[String]:
    return [
        String("Zürich"),
        String("東京"),
        String("𐍈"),
        String("plain"),
    ]


def _disk_names() raises -> List[String]:
    return [
        String("straße"),
        String("東京"),
        String("𐍈"),
        String("plain"),
    ]


# =============================================================================
# Byte helpers
# =============================================================================


def _bytes_of(imm s: String) raises -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _hex(imm b: List[UInt8]) raises -> String:
    var digits: List[String] = [
        String("0"), String("1"), String("2"), String("3"),
        String("4"), String("5"), String("6"), String("7"),
        String("8"), String("9"), String("a"), String("b"),
        String("c"), String("d"), String("e"), String("f"),
    ]
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += " "
        var v = Int(b[i])
        out += digits[v >> 4]
        out += digits[v & 15]
    return out^


def _assert_bytes_eq(
    imm got: String, imm want: String, imm what: String
) raises:
    var gb = _bytes_of(got)
    var wb = _bytes_of(want)
    if len(gb) != len(wb):
        raise Error(
            what + ": got " + String(len(gb)) + " bytes [" + _hex(gb)
            + "] for a " + String(len(wb)) + "-byte source [" + _hex(wb)
            + "]. If every byte >= 0x80 doubled, a per-code-point `chr()`"
            " decode is back — see this file's header"
        )
    for i in range(len(gb)):
        if gb[i] != wb[i]:
            raise Error(
                what + ": byte " + String(i) + " differs (got [" + _hex(gb)
                + "] want [" + _hex(wb) + "])"
            )


def _sh(cmd: String) raises:
    var cmd_local = cmd
    var rc = external_call["system", Int32](
        cmd_local.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("shell command failed rc=" + String(Int(rc)) + ": " + cmd)


def _scratch_dir() raises -> String:
    """A per-run scratch root under `$TEST_TMPDIR`, which the test runner makes
    private to each run, so two concurrent runs of the SAME test cannot
    collide."""
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var root = base + String("/osbytes_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


# =============================================================================
# NON-VACUITY — without this, an all-ASCII fixture makes the file a tautology
# =============================================================================


def test_fixtures_are_actually_non_ascii() raises:
    """NON-VACUITY GUARD FOR EVERY OTHER TEST IN THIS FILE.

    ⛔ THE DEFECTIVE DECODE IS THE IDENTITY ON ASCII, so an all-ASCII fixture
    makes every assertion below pass against it. A later "tidy up the weird
    characters" edit would silently convert this file into decoration (an
    ASCII-ified fixture + a neutered guard lets the defective code build fully
    GREEN).

    Five properties, each ruling out a different degenerate fixture:
      1. a name holds a byte >= 0x80;
      2. all three multi-byte lead classes appear (C0-DF, E0-EF, F0-F7) — a
         decode that only handled 2-byte sequences survives a C3-only fixture;
      3. an all-ASCII CONTROL name is present, so a "fix" that damages ASCII is
         caught rather than hidden;
      4. the exact stored byte total of BOTH fixture sets, so a substitution
         preserving the class set still reds;
      5. the two sets are DIFFERENT (in-memory keeps `Zürich`, on-disk uses
         only non-decomposable characters), so a fix to one arm cannot pass
         both.

    Killed by: replacing any non-ASCII name with ASCII; dropping the 3-byte or
    the 4-byte name; dropping the ASCII control; merging the two sets.
    """
    var sets: List[List[String]] = [_mem_names(), _disk_names()]
    var totals: List[Int] = [0, 0]
    for si in range(len(sets)):
        var ks = sets[si].copy()
        var total = 0
        var n_high = 0
        var saw_2b = False
        var saw_3b = False
        var saw_4b = False
        var saw_ascii_control = False
        for i in range(len(ks)):
            var b = _bytes_of(ks[i])
            total += len(b)
            var this_high = 0
            for j in range(len(b)):
                var v = Int(b[j])
                if v >= 0x80:
                    this_high += 1
                    n_high += 1
                if v >= 0xC0 and v <= 0xDF:
                    saw_2b = True
                if v >= 0xE0 and v <= 0xEF:
                    saw_3b = True
                if v >= 0xF0 and v <= 0xF7:
                    saw_4b = True
            if this_high == 0:
                saw_ascii_control = True
        if n_high == 0:
            raise Error(
                "VACUOUS FIXTURE (set " + String(si) + "): no name holds a byte"
                " >= 0x80, so every assertion in this file passes against the"
                " DEFECTIVE per-code-point `chr` decode. See this file's header."
            )
        if not saw_2b:
            raise Error("VACUOUS FIXTURE: no 2-byte (C0-DF) lead byte present")
        if not saw_3b:
            raise Error("VACUOUS FIXTURE: no 3-byte (E0-EF) lead byte present")
        if not saw_4b:
            raise Error("VACUOUS FIXTURE: no 4-byte (F0-F7) lead byte present")
        if not saw_ascii_control:
            raise Error("VACUOUS FIXTURE: no all-ASCII CONTROL name")
        totals[si] = total
    assert_equal(totals[0], _EXPECTED_MEM_BYTES)
    assert_equal(totals[1], _EXPECTED_DISK_BYTES)
    # (5) the two sets must differ — see the header on decomposition.
    var mem = _mem_names()
    var disk = _disk_names()
    var differs = False
    for i in range(len(mem)):
        if mem[i] != disk[i]:
            differs = True
    if not differs:
        raise Error(
            "VACUOUS FIXTURE: the in-memory and on-disk sets are identical, so"
            " the decomposition split this file argues for is not being tested"
        )


# =============================================================================
# FALSIFIER 1 — `objectstore_uri._bytes_to_str` (was `_bytes_to_ascii`)
# =============================================================================


def test_uri_object_key_survives_parse_exactly() raises:
    """SITE: `komira_objectstore/objectstore_uri._bytes_to_str`, PATH arm.

    ⭐ THE CUSTOMER-DATA PATH. `parse(uri).path.raw()` IS the S3 object key
    the SDK's cloud read and write paths hand to `FileSystem.open`. Under the
    defect a key holding any byte >= 0x80 is re-encoded, so a read 404s on an
    object that exists and a write lands somewhere else.

    Killed by: restoring `out += chr(Int(bs[i]))` in `_bytes_to_str`.
    """
    var ks = _mem_names()
    for i in range(len(ks)):
        var key = String("data/") + ks[i] + String("/part-0.parquet")
        var uri = String("s3://bucket/") + key
        var got = parse(uri).path.raw()
        _assert_bytes_eq(got, key, "parse().path.raw() for " + uri)
    # A key that is ONLY the non-ASCII run (no ASCII prefix to hide behind).
    var bare = parse(String("s3://bucket/東京")).path.raw()
    _assert_bytes_eq(bare, String("東京"), "parse() bare non-ASCII key")


def test_uri_authority_survives_parse_exactly() raises:
    """SITE: same function, AUTHORITY arm — a SEPARATE call site (two of them),
    so a fix to the path arm only cannot pass this.

    Killed by: restoring the `chr` loop in `_bytes_to_str`.
    """
    var host = String("bücket.東京.example")
    var with_path = parse(String("s3://") + host + String("/k")).authority
    _assert_bytes_eq(with_path, host, "authority (slash arm)")
    var no_path = parse(String("s3://") + host).authority
    _assert_bytes_eq(no_path, host, "authority (no-slash arm)")


# =============================================================================
# FALSIFIER 2 — `path.Path.filename`
# =============================================================================


def test_path_filename_survives_exactly() raises:
    """SITE: `komira_objectstore/path.Path.filename`.

    ⚠ `Path.parse` IN THE SAME FILE is byte-exact (it builds an `out_bytes`
    list), and the NO-SLASH arm of `filename()` returns `self._raw` directly.
    A defect can sit in one branch only, so both branches are asserted here.

    Killed by: restoring `out += chr(Int(bs[j]))` in `Path.filename`.
    """
    var ks = _mem_names()
    for i in range(len(ks)):
        var name = ks[i] + String(".parquet")
        # (a) the slash branch — the defective one.
        var p = Path.parse(String("a/b/") + name)
        _assert_bytes_eq(p.filename(), name, "filename() slash branch")
        # (b) the no-slash branch — already correct; a "fix" must not break it.
        var q = Path.parse(name)
        _assert_bytes_eq(q.filename(), name, "filename() no-slash branch")


# =============================================================================
# FALSIFIER 3 — `cas_manifest.decode_head`
# =============================================================================


def test_manifest_head_etag_round_trips_exactly() raises:
    """SITE: `komira_objectstore/cas_manifest.decode_head`.

    `encode_head` writes the etag's bytes RAW, so a `chr` decode made this an
    ASYMMETRIC codec pair: the decoded etag would not equal the one written and
    every `If-Match` HEAD advance built on it would 412 forever.

    ⚠ An ETag is an OPAQUE token from whichever store conformer produced it —
    this decoder may not assume a charset for it. Every etag the tree's own
    conformers produce today IS ASCII (quoted FNV hex / an S3 hex hash), so
    this site is the class's SHAPE with reach that is real but unexercised by
    any store in the tree; it is fixed because an asymmetric codec pair is a
    defect regardless of who happens to feed it.

    Killed by: restoring `etag += chr(Int(bytes[24 + i]))` in `decode_head`.
    """
    var ks = _mem_names()
    for i in range(len(ks)):
        var etag = String("\"") + ks[i] + String("\"")
        var h = ManifestHead(Int64(7), Int64(4096), etag)
        var got = decode_head(encode_head(h))
        assert_equal(got.chunk_seq, Int64(7))
        assert_equal(got.next_offset, Int64(4096))
        _assert_bytes_eq(got.etag_of_last_chunk, etag, "decode_head etag")


# =============================================================================
# FALSIFIER 4 — `sublineage_base_fold._decode_base_chunk`
# =============================================================================


def test_base_chunk_shard_id_round_trips_and_crc_holds() raises:
    """SITE: `komira_objectstore/sublineage_base_fold._decode_base_chunk`.

    ⭐ THE OBSERVABLE IS A FALSE CORRUPTION REPORT, NOT A MANGLED STRING. The
    decoded `sid` is fed straight back into `_block_crc(sid, ...)` and compared
    against the CRC computed over the ORIGINAL at encode time. A `chr` decode
    changes the bytes, so the CRCs differ and a PERFECTLY GOOD block raises
    `_base chunk CRC mismatch (corrupt block)`. That is why this test asserts a
    RAISE-FREE decode as well as the bytes — "both wrong alike" cannot satisfy
    a CRC computed over the pre-encode value.

    Killed by: restoring `sid += chr(Int(body[32 + i]))` in `_decode_base_chunk`
    (which reds on the CRC before it reaches the byte assertion).
    """
    var ks = _mem_names()
    var payloads: List[Int64] = [Int64(10), Int64(11), Int64(12)]
    for i in range(len(ks)):
        var sid = String("shard-") + ks[i]
        var body = _encode_base_chunk(sid, Int64(100), payloads)
        var rc = _base_chunk_record_count(body)
        assert_equal(rc, Int64(3))
        var entry = _decode_base_chunk(body, rc, Int64(0))
        _assert_bytes_eq(
            entry.source_shard_id, sid, "_decode_base_chunk source_shard_id"
        )
        assert_equal(entry.source_local_base, Int64(100))
        assert_equal(entry.count, Int64(3))


# =============================================================================
# FALSIFIER 5 — `sublineage_base_fold._first_segment_after`
# =============================================================================


def test_shard_segment_of_an_object_key_survives_exactly() raises:
    """SITE: `komira_objectstore/sublineage_base_fold._first_segment_after`,
    reached through `_shard_from_object_key` (its live caller shape).

    An object key's `<shard>` segment is customer-named. Its three correct
    twins — `sublineage_shard_keys._shard_id_from_key`,
    `_shard_id_from_common_prefix` and `sharded_lineage`'s — were already
    byte-exact; this was the copy left behind, which is what makes a
    per-package sweep insufficient and a falsifier necessary.

    Killed by: restoring `out += chr(Int(c))` in `_first_segment_after`.
    """
    var ks = _mem_names()
    var enum_prefix = String("part-0/_lineage/")
    for i in range(len(ks)):
        var shard = String("s-") + ks[i]
        var key = enum_prefix + shard + String("/manifest/000.chunk")
        _assert_bytes_eq(
            _shard_from_object_key(key, enum_prefix),
            shard,
            "_shard_from_object_key",
        )
    # A shard segment at end-of-key (no trailing '/') exercises the other exit.
    var tail = enum_prefix + String("𐍈")
    _assert_bytes_eq(
        _shard_from_object_key(tail, enum_prefix), String("𐍈"),
        "_shard_from_object_key at end of key",
    )


# =============================================================================
# FALSIFIER 6 — `local_fs_conditional_store._decode_fname_to_key`, `%XX` arm
# =============================================================================


def test_flat_filename_codec_round_trips_exactly() raises:
    """SITE: `local_fs_conditional_store._decode_fname_to_key`, the `%XX` arm.

    ⭐⭐ THE ARM THAT WAS INVISIBLE TO A `chr(Int(` GREP: it was spelled
    `out += chr((hi << 4) | lo)`. `(hi << 4) | lo` is a BYTE, so this is the
    same defect with no matching text, and it survived every earlier pass over
    this class for that reason alone.

    `_encode_key_to_fname` percent-encodes every non-[A-Za-z0-9._-] byte, so a
    non-ASCII key reaches the decoder ENTIRELY through the `%XX` arm — meaning
    the round trip was broken for every such key. The encode side is asserted
    too (it is `# SAFE:`-marked and must STAY the identity on ASCII).

    Killed by: restoring `out += chr((hi << 4) | lo)` in
    `_decode_fname_to_key`.
    """
    var ks = _mem_names()
    for i in range(len(ks)):
        var key = String("kg/") + ks[i] + String("/manifest/_HEAD")
        var fname = _encode_key_to_fname(key)
        # The encoded filename must itself be pure ASCII + `%` escapes.
        var fb = _bytes_of(fname)
        for j in range(len(fb)):
            if Int(fb[j]) >= 0x80:
                raise Error(
                    "_encode_key_to_fname leaked a non-ASCII byte at " + String(j)
                    + " (" + _hex(fb) + ") — the `%XX` decode arm would then"
                    " never be exercised by this test"
                )
        _assert_bytes_eq(
            _decode_fname_to_key(fname), key, "flat fname codec round trip"
        )


def test_decode_fname_passes_a_raw_non_ascii_byte_through() raises:
    """SITE: same function, the LITERAL-BYTE arm — a SEPARATE `chr` call site,
    so a fix to the `%XX` arm only cannot pass this.

    The literal arm sees a filename this store did NOT write (a foreign file
    dropped into the root, which `list_with_delimiter` will happily decode).
    Its documented contract is pass-through, and pass-through must mean the
    BYTES.

    Killed by: restoring `out += chr(Int(bs[i]))` in `_decode_fname_to_key`.
    """
    var ks = _mem_names()
    for i in range(len(ks)):
        var foreign = ks[i] + String(".dat")
        _assert_bytes_eq(
            _decode_fname_to_key(foreign), foreign,
            "_decode_fname_to_key literal arm",
        )
    # A malformed `%` escape must ALSO pass through byte-exactly.
    _assert_bytes_eq(
        _decode_fname_to_key(String("%ZZ東京")), String("%ZZ東京"),
        "_decode_fname_to_key malformed-escape passthrough",
    )


# =============================================================================
# FALSIFIER 7 — `local_fs_conditional_store._mkdir_p_root` (ON DISK)
# =============================================================================


def test_mkdir_p_root_creates_the_directory_it_was_given() raises:
    """SITE: `local_fs_conditional_store._mkdir_p_root`.

    ⭐ THE STRONGEST ASSERTION FOR A PATH DEFECT NEEDS NO EXPECTED BYTES AT
    ALL: the directory the caller NAMED must exist afterwards. Under the defect
    `_mkdir_p_root` created a DIFFERENTLY-NAMED directory while
    `LocalFsConditionalStore.__init__` bound `self._root` to the ORIGINAL, so
    every later open under `_root` hit a path that does not exist — the same
    "a re-encoded path does not exist on disk" failure `local_fs` readdir
    produced, in the WRITE direction. Normalization-immune, so the on-disk
    fixture set is used here.

    ⚠ MULTI-SEGMENT ON PURPOSE: the mkdir walk creates each intermediate level
    from the accumulated prefix, so a single-segment path would exercise only
    the loop's tail.

    Killed by: restoring `acc += chr(c)` in `_mkdir_p_root`.
    """
    var root = _scratch_dir()
    var ks = _disk_names()
    for i in range(len(ks)):
        var target = root + String("/") + ks[i] + String("/inner/leaf")
        _mkdir_p_root(target)
        if not _is_existing_dir(target):
            raise Error(
                "_mkdir_p_root('" + target + "') did not create THAT directory"
                " — a re-encoded path names a directory that does not exist."
                " Expected bytes [" + _hex(_bytes_of(target)) + "]"
            )
        # The intermediate level must exist under its GIVEN name too.
        var mid = root + String("/") + ks[i]
        assert_true(_is_existing_dir(mid), "intermediate level missing: " + mid)
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# FALSIFIER 8 — THE OBSERVABLE, END TO END THROUGH THE STORE
# =============================================================================


def test_store_lists_back_the_key_it_was_given() raises:
    """SITES: `_decode_fname_to_key` + `_mkdir_p_root`, through the PUBLIC
    surface (`conditional_put` -> `list_with_delimiter`).

    ⭐ THE WRONG ANSWER, NOT THE WRONG STRING. `list_with_delimiter` decodes
    each filename back to a key and matches it against the CALLER's prefix,
    which arrives as CORRECT UTF-8. Corrupt on ONE side only ⇒ nothing matches
    ⇒ the object is SILENTLY ABSENT from the listing — byte-for-byte the shape
    that made `WHERE city = 'Zürich'` return an empty result set on the engine
    side. The count assertion is what catches it; the byte assertion is what
    catches "corrupted but consistently so".

    ⚠ The store ROOT is non-ASCII too, so this test also fails if
    `_mkdir_p_root` regresses.

    Killed by: restoring EITHER `chr` arm in `_decode_fname_to_key`, or
    `acc += chr(c)` in `_mkdir_p_root`.
    """
    var scratch = _scratch_dir()
    var ks = _disk_names()
    var root = scratch + String("/store-") + ks[0]
    var store = LocalFsConditionalStore(root)

    var prefix = String("kg/東京/")
    var body: List[UInt8] = [UInt8(1), UInt8(2), UInt8(3)]
    var want = List[String]()
    for i in range(len(ks)):
        var key = prefix + ks[i] + String(".obj")
        want.append(key)
        _ = store.conditional_put(
            Path.parse(key), body, WritePrecondition.if_none_match_star()
        )

    var listed = store.list_with_delimiter(Path.parse(prefix))
    if len(listed.objects) != len(want):
        var names = String("")
        for i in range(len(listed.objects)):
            names += " [" + _hex(_bytes_of(listed.objects[i].location)) + "]"
        raise Error(
            "list_with_delimiter under a non-ASCII prefix returned "
            + String(len(listed.objects)) + " of " + String(len(want))
            + " objects. A one-sided decode makes the key stop matching the"
            " prefix and the object goes SILENTLY MISSING. got:" + names
        )
    for i in range(len(want)):
        var found = False
        for j in range(len(listed.objects)):
            if listed.objects[j].location == want[i]:
                found = True
        if not found:
            raise Error(
                "key not listed back byte-exactly: want ["
                + _hex(_bytes_of(want[i])) + "]"
            )
    _sh(String("rm -rf '") + scratch + String("'"))


def main() raises:
    test_fixtures_are_actually_non_ascii()
    test_uri_object_key_survives_parse_exactly()
    test_uri_authority_survives_parse_exactly()
    test_path_filename_survives_exactly()
    test_manifest_head_etag_round_trips_exactly()
    test_base_chunk_shard_id_round_trips_and_crc_holds()
    test_shard_segment_of_an_object_key_survives_exactly()
    test_flat_filename_codec_round_trips_exactly()
    test_decode_fname_passes_a_raw_non_ascii_byte_through()
    test_mkdir_p_root_creates_the_directory_it_was_given()
    test_store_lists_back_the_key_it_was_given()
    print("test_objectstore_bytes_non_ascii: ALL PASS")
