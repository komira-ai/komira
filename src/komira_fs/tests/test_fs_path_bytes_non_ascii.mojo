# =============================================================================
# A FILESYSTEM PATH IS A BYTE STRING AND MUST SURVIVE LISTING/PARSING EXACTLY
# =============================================================================
#
# ⛔ THE DEFECT THIS FILE EXISTS FOR (found + fixed the
# `komira_fs` half of the repo-wide `chr(Int(byte))` class; the engine
# half is covered by `komira_engine_dispatch`'s hive-partition tests).
#
# Six functions in `komira_fs` decoded a STORED BYTE with `chr`:
#
#     var out = String("")
#     for i in range(start, end):
#         out += chr(Int(bs[i]))
#
# `chr` maps a CODE POINT to its UTF-8 ENCODING, so a byte >= 0x80 is not
# reproduced but RE-ENCODED into two: `ü` (C3 BC) came back as `Ã¼`
# (C3 83 C2 BC). ASCII is the corruption's FIXED POINT, so counts, sets and
# every count-based assertion in the suite survived it — and an all-ASCII test corpus
# cannot see it at all.
#
# ⚠ WHY THIS PACKAGE IS THE WORST PLACE FOR IT: THESE STRINGS ARE PATHS.
# A mojibaked path DOES NOT EXIST ON DISK. The failure is therefore not a
# mangled output column but a listing that matches nothing:
#
#   `local_fs._local_fs_list_recursive`  — the READDIR decode behind
#       `LocalFs.list`. Every discovered path (eager glob discovery AND the
#       pruned/lazy arm's targeted listing) came out of here. The corrupted
#       path was then handed to `hive_partition_parser`, so the partition
#       VALUE was corrupt too, so `partition_prune_scans._value_satisfies`
#       byte-compared it against the user's CORRECT predicate literal, found
#       nothing, rewrote the Filter to literal FALSE and returned an EMPTY
#       RESULT SET for `WHERE city = 'Zürich'` over a tree that plainly has
#       it. The engine-side fix landed first; this one is what makes it work
#       end to end, because readdir is UPSTREAM of the parser.
#   `local_fs._local_fs_list_dir_shallow` — the partition-schema
#       probe, reached in production from
#       the engine's scan setup.
#   `glob._slice_str` — used by `split_static_prefix`, whose output is fed
#       STRAIGHT to `fs.list`. Its docstring CLAIMED "UTF-8-byte-safe" while
#       the body was the opposite.
#   `shallow_dir_entry._shallow_basename` — the S3 / GCS / Azure
#       `list_dir_shallow` basename, i.e. the same defect on the cloud arm.
#   `partition_codec._url_unescape` — BOTH of its decodes (`chr((hi<<4)|lo)`
#       for the `%XX` byte and `chr(Int(b))` for the pass-through byte). This
#       is the LAZY arm's `parse_partition_value`, and it is one half of the
#       MANDATED INVERSE PAIR that module's own header calls a HARD-FAIL GATE:
#       `encode_partition_value("Zürich")` = `Z%C3%BCrich`, and the parse
#       turned that back into `ZÃ¼rich`. The header states the consequence
#       exactly — "builds a prefix that matches NOTHING on disk -> the query
#       SILENTLY returns zero rows".
#       ⚠ `_url_ESCAPE`'s `chr(Int(b))` is NOT this defect and is deliberately
#       left alone: it is guarded by `_is_unreserved`, so `b < 0x80` and the
#       call is the identity. A "fix" there would be a false positive.
#   `partition_codec._kv_split` — the lazy arm's `key=value` splitter, the
#       exact counterpart of the engine-side `_parse_kv_component`.
#       `_segment_has_disqualifying_byte` screens only `?` and bytes < 0x20,
#       so a RAW (unescaped) non-ASCII directory — which Spark and Hive both
#       write — reached it and was mojibaked before any decode ran.
#
# ⚠ WHAT THIS FILE DELIBERATELY DOES NOT ASSERT. It never asserts that two
# code paths AGREE — agreement is satisfied by both arms being wrong alike,
# which was demonstrated on a sibling defect the same day. Every assertion is
# against the EXACT bytes of the fixture's own source text.
#
# ⚠ AND THE ON-DISK FIXTURE AVOIDS DECOMPOSABLE CHARACTERS ON PURPOSE. `ü`
# (U+00FC) has a canonical decomposition, so a normalizing filesystem could
# hand back `u`+U+0308 and red the byte assertion for a reason that is not
# this defect. The three ON-DISK names use `ß` (U+00DF), `東京` and `𐍈`, none
# of which decompose, so NFC == NFD and the byte assertion is exact on both
# APFS and ext4. The PURE-FUNCTION tests, which never touch a filesystem, use
# `Zürich`, a realistic partition value.
#
# ⚠ THIS IS NOT A UTF-8 VALIDATOR. The contract is BYTE reproduction,
# including bytes that are not valid UTF-8 at all; that is why the fix spelling
# is `String(StringSlice(unsafe_from_utf8=<span>))` and why byte identity is
# the whole claim. That spelling is also LENGTH-EXPLICIT, unlike
# `String(unsafe_from_utf8_ptr=)`, which stops at the first NUL.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs, ShallowDirEntry
from komira_fs.shallow_dir_entry import _shallow_basename
from komira_fs.glob import brace_expand, split_static_prefix
from komira_fs.partition_codec import (
    encode_partition_value,
    parse_partition_value,
    parse_key_value_segments,
)
from komira_async.ops.waker_sink import NoopSink


comptime _Fs = LocalFs[NoopSink]


# =============================================================================
# THE FIXTURE
# =============================================================================
#
# ON-DISK names — all three multi-byte UTF-8 lead classes, none decomposable:
#   'straße'  7 bytes  73 74 72 61 C3 9F 65      2-byte lead (C3 9F)
#   '東京'    6 bytes  E6 9D B1 E4 BA AC         two 3-byte sequences
#   '𐍈'      4 bytes  F0 90 8D 88               one 4-byte sequence
#   'praha'   5 bytes  ASCII — the CONTROL: the corruption's fixed point,
#                      it must come back unchanged, so a "fix" that mangles
#                      ASCII is caught too.

comptime _N_DISK_VALUES: Int = 4

comptime _EXPECTED_DISK_VALUE_BYTES: Int = 22  # 7 + 6 + 4 + 5


def _disk_values() raises -> List[String]:
    return [
        String("straße"),
        String("東京"),
        String("𐍈"),
        String("praha"),
    ]


# The PURE-FUNCTION fixture uses a realistic non-ASCII partition value.
def _zurich() raises -> String:
    return String("Zürich")


# =============================================================================
# Byte helpers — every assertion in this file is about BYTES
# =============================================================================


def _bytes_of(imm s: String) raises -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _hex(imm b: List[UInt8]) raises -> String:
    """Byte-wise hex, for diagnostics. ⚠ Mojo `String` has no positional
    `s[i]` — a byte, a code point and a grapheme are three different things at
    one index, which is a smaller relative of the very defect this file pins —
    so the digit table is a `List[String]`, not a string indexed."""
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
            what
            + ": got "
            + String(len(gb))
            + " bytes ["
            + _hex(gb)
            + "] for a "
            + String(len(wb))
            + "-byte source ["
            + _hex(wb)
            + "]. If every byte >= 0x80 doubled, the per-code-point `chr()`"
            " decode is back — see this file's header"
        )
    for i in range(len(gb)):
        if gb[i] != wb[i]:
            var one_g = List[UInt8]()
            one_g.append(gb[i])
            var one_w = List[UInt8]()
            one_w.append(wb[i])
            raise Error(
                what
                + ": byte "
                + String(i)
                + " is 0x"
                + _hex(one_g)
                + ", source has 0x"
                + _hex(one_w)
                + " (got ["
                + _hex(gb)
                + "] want ["
                + _hex(wb)
                + "])"
            )


# =============================================================================
# NON-VACUITY — without this, an all-ASCII fixture makes the file a tautology
# =============================================================================


def test_fixture_is_actually_non_ascii() raises:
    """NON-VACUITY GUARD FOR EVERY OTHER TEST IN THIS FILE.

    ⛔ THE OLD DECODE IS THE IDENTITY ON ASCII. `chr(Int(b))` for b < 0x80
    emits exactly the byte b, so an all-ASCII fixture makes every byte-identity
    assertion below PASS AGAINST THE DEFECTIVE CODE. A fixture edit swapping
    `straße` for `strasse` would fail nothing — it would silently convert this
    whole file into decoration. That failure shape is common enough
    that it is ASSERTED, not commented.

    Five properties, each ruling out a different degenerate fixture:
      1. the on-disk fixture holds a byte >= 0x80;
      2. all three multi-byte lead classes appear among the on-disk names
         (C0-DF, E0-EF, F0-F7) — a decode that only handled 2-byte sequences
         would survive a C3-only fixture;
      3. the exact stored byte total, so a substitution preserving the class
         set still reds;
      4. an ASCII CONTROL value is present — the corruption's fixed point, so
         a "fix" that damages ASCII is caught rather than hidden;
      5. the pure-function fixture (`Zürich`) is itself non-ASCII, since the
         on-disk and pure-function fixtures are different strings and a fix to
         one arm only must not pass.

    Killed by: replacing any non-ASCII value with ASCII; dropping the 3-byte
    or the 4-byte value; dropping the ASCII control.
    """
    var vals = _disk_values()
    if len(vals) != _N_DISK_VALUES:
        raise Error("fixture size changed; expected " + String(_N_DISK_VALUES))

    var total = 0
    var n_high = 0
    var saw_2b = False
    var saw_3b = False
    var saw_4b = False
    var saw_pure_ascii_value = False
    for i in range(len(vals)):
        var b = _bytes_of(vals[i])
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
            saw_pure_ascii_value = True

    if n_high == 0:
        raise Error(
            "VACUOUS FIXTURE: no on-disk value holds a byte >= 0x80, so every"
            " byte-identity assertion in this file passes against the DEFECTIVE"
            " `chr(Int(byte))` decode. See this file's header."
        )
    if not saw_2b:
        raise Error("VACUOUS FIXTURE: no 2-byte (C0-DF) lead byte present")
    if not saw_3b:
        raise Error("VACUOUS FIXTURE: no 3-byte (E0-EF) lead byte present")
    if not saw_4b:
        raise Error("VACUOUS FIXTURE: no 4-byte (F0-F7) lead byte present")
    if not saw_pure_ascii_value:
        raise Error(
            "VACUOUS FIXTURE: no all-ASCII CONTROL value; a decode that"
            " damages ASCII would go unnoticed"
        )
    assert_equal(total, _EXPECTED_DISK_VALUE_BYTES)

    # (5) the pure-function fixture is a DIFFERENT string and must also be
    # non-ASCII on its own.
    var zb = _bytes_of(_zurich())
    assert_equal(len(zb), 7)  # 5A C3 BC 72 69 63 68
    var z_high = 0
    for i in range(len(zb)):
        if Int(zb[i]) >= 0x80:
            z_high += 1
    if z_high == 0:
        raise Error("VACUOUS FIXTURE: the pure-function fixture is all-ASCII")


# =============================================================================
# On-disk fixture construction
# =============================================================================


def _sh(cmd: String) raises:
    var cmd_local = cmd
    var rc = external_call["system", Int32](
        cmd_local.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("shell command failed rc=" + String(Int(rc)) + ": " + cmd)


def _disk_root(tag: String) raises -> String:
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var root = base + String("/fsbytes_") + tag + String("_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


def _build_non_ascii_hive_tree(root: String) raises:
    """`<root>/dir/city=<v>/part-<i>.parquet` for each fixture value."""
    var vals = _disk_values()
    var d = root + String("/dir")
    for i in range(len(vals)):
        var part = d + String("/city=") + vals[i]
        _sh(String("mkdir -p '") + part + String("'"))
        _sh(
            String("printf 'X' > '")
            + part
            + String("/part-")
            + String(i)
            + String(".parquet'")
        )


def _index_of(imm xs: List[String], imm want: String) raises -> Int:
    var wb = _bytes_of(want)
    for i in range(len(xs)):
        var gb = _bytes_of(xs[i])
        if len(gb) != len(wb):
            continue
        var same = True
        for j in range(len(gb)):
            if gb[j] != wb[j]:
                same = False
                break
        if same:
            return i
    return -1


# =============================================================================
# FALSIFIER 1 — `local_fs._local_fs_list_recursive` (the READDIR decode)
# =============================================================================


def test_readdir_recursive_reproduces_path_bytes_exactly() raises:
    """SITE: `komira_fs/local_fs._local_fs_list_recursive`, behind
    `LocalFs.list` — the primary readdir decode, upstream of ALL Hive
    partition parsing.

    Asserts the EXACT expected absolute path for each fixture value, built
    from the SAME source text the directory was created from — not that two
    listings agree.

    Killed by: restoring `s += chr(Int(out_buf[j]))` in
    `_local_fs_list_recursive`. Under the old decode `city=straße` listed as
    `city=straÃŸe` (one byte longer per non-ASCII byte), so the exact-path
    lookup returns -1.
    """
    var root = _disk_root(String("list"))
    _build_non_ascii_hive_tree(root)
    var fs = _Fs.new()
    var listed = fs.list(root + String("/dir"))

    var vals = _disk_values()
    assert_equal(len(listed), len(vals))
    for i in range(len(vals)):
        var want = (
            root
            + String("/dir/city=")
            + vals[i]
            + String("/part-")
            + String(i)
            + String(".parquet")
        )
        var at = _index_of(listed, want)
        if at < 0:
            raise Error(
                "LocalFs.list did not reproduce the on-disk path for value '"
                + vals[i]
                + "'. Wanted ["
                + _hex(_bytes_of(want))
                + "]. Got "
                + String(len(listed))
                + " paths, first ["
                + _hex(_bytes_of(listed[0]))
                + "]. If every byte >= 0x80 doubled, the `chr(Int(byte))`"
                " readdir decode is back."
            )
        _assert_bytes_eq(listed[at], want, "LocalFs.list path")
    _sh(String("rm -rf '") + root + String("'"))


def test_a_listed_path_can_actually_be_opened() raises:
    """SITE: same. THE LIVE FAILURE MODE, stated as its own property.

    A re-encoded path DOES NOT EXIST ON DISK. This is the assertion that does
    not depend on knowing the expected bytes at all: whatever `list` returns
    must name something the filesystem can still find. Under the old decode
    every non-ASCII directory failed this.

    Killed by: the same revert.
    """
    var root = _disk_root(String("open"))
    _build_non_ascii_hive_tree(root)
    var fs = _Fs.new()
    var listed = fs.list(root + String("/dir"))
    assert_equal(len(listed), _N_DISK_VALUES)
    for i in range(len(listed)):
        # `is_dir` RAISES on file-not-found, so a mojibaked path raises here.
        assert_false(fs.is_dir(listed[i]))
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# FALSIFIER 2 — `local_fs._local_fs_list_dir_shallow` (the probe)
# =============================================================================


def test_readdir_shallow_reproduces_entry_name_bytes_exactly() raises:
    """SITE: `komira_fs/local_fs._local_fs_list_dir_shallow`, behind
    `LocalFs.list_dir_shallow` — a SEPARATE decode loop from
    `_local_fs_list_recursive`, so reverting either one alone reds only its
    own falsifier.

    Reached in production from the engine's scan setup
    (the `[FS]`-generic Hive shallow partition-schema probe).

    Killed by: restoring `s += chr(Int(out_buf[j]))` in
    `_local_fs_list_dir_shallow`.
    """
    var root = _disk_root(String("shallow"))
    _build_non_ascii_hive_tree(root)
    var fs = _Fs.new()
    var entries = fs.list_dir_shallow(root + String("/dir"))

    var vals = _disk_values()
    assert_equal(len(entries), len(vals))
    var names = List[String]()
    for i in range(len(entries)):
        assert_true(entries[i].is_dir)
        names.append(entries[i].name)
    for i in range(len(vals)):
        var want = String("city=") + vals[i]
        var at = _index_of(names, want)
        if at < 0:
            raise Error(
                "list_dir_shallow did not reproduce the on-disk entry name for"
                " '"
                + vals[i]
                + "'. Wanted ["
                + _hex(_bytes_of(want))
                + "]."
            )
        _assert_bytes_eq(names[at], want, "ShallowDirEntry.name")
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# FALSIFIER 3 — `glob._slice_str` via `split_static_prefix`
# =============================================================================


def test_split_static_prefix_reproduces_pattern_bytes_exactly() raises:
    """SITE: `komira_fs/glob._slice_str`.

    `split_static_prefix`'s output is handed STRAIGHT to `fs.list`, so a
    mojibaked static prefix lists a directory that does not exist and the glob
    matches nothing. Note the old docstring on `_slice_str` claimed
    "UTF-8-byte-safe" — the assertion, not the comment, is the guard.

    Killed by: restoring `out += chr(Int(bs[i]))` in `glob._slice_str`.
    """
    var pattern = (
        String("/data/city=") + _zurich() + String("/*.parquet")
    )
    var split = split_static_prefix(pattern)
    _assert_bytes_eq(
        split[0],
        String("/data/city=") + _zurich() + String("/"),
        "split_static_prefix static prefix",
    )
    _assert_bytes_eq(split[1], String("*.parquet"),
                     "split_static_prefix residual")


def test_brace_expand_reproduces_alternative_bytes_exactly() raises:
    """SITE: `glob._slice_str`, reached through a DIFFERENT caller
    (`brace_expand` -> `_find_first_brace_group` / `_split_top_level_commas`)
    than the test above, so the site is covered on both of its production
    entry points.

    Killed by: the same revert.
    """
    var pattern = (
        String("/data/city={") + _zurich() + String(",東京}/p.parquet")
    )
    var out = brace_expand(pattern)
    assert_equal(len(out), 2)
    _assert_bytes_eq(
        out[0],
        String("/data/city=") + _zurich() + String("/p.parquet"),
        "brace_expand alt 0",
    )
    _assert_bytes_eq(
        out[1],
        String("/data/city=東京/p.parquet"),
        "brace_expand alt 1",
    )


# =============================================================================
# FALSIFIER 4 — `shallow_dir_entry._shallow_basename` (the CLOUD arm)
# =============================================================================


def test_shallow_basename_reproduces_key_bytes_exactly() raises:
    """SITE: `komira_fs/shallow_dir_entry._shallow_basename` — the
    basename helper S3Fs / GcsFs / AzureFs each use to turn a list key or a
    `CommonPrefixes` fold into a `ShallowDirEntry.name`. Same defect, cloud
    side; a mojibaked basename is a prefix that does not exist in the bucket.

    Killed by: restoring `out += chr(Int(bs[i]))` in `_shallow_basename`.
    """
    # A CommonPrefixes fold (trailing `/`) and a Contents key (no trailing `/`),
    # spanning the 2-, 3- and 4-byte lead classes.
    _assert_bytes_eq(
        _shallow_basename(String("events/city=") + _zurich() + String("/")),
        String("city=") + _zurich(),
        "_shallow_basename CommonPrefixes fold",
    )
    _assert_bytes_eq(
        _shallow_basename(String("events/city=東京/part-0.parquet")),
        String("part-0.parquet"),
        "_shallow_basename Contents key (ASCII basename under non-ASCII dir)",
    )
    _assert_bytes_eq(
        _shallow_basename(String("events/𐍈/straße.parquet")),
        String("straße.parquet"),
        "_shallow_basename 4-byte-lead dir, 2-byte-lead basename",
    )


# =============================================================================
# FALSIFIER 5 — `partition_codec._url_unescape` (BOTH of its decodes)
# =============================================================================


def test_parse_partition_value_decodes_escapes_to_exact_bytes() raises:
    """SITE: `komira_fs/partition_codec._url_unescape`, behind
    `parse_partition_value` — the LAZY (pruned-hive) arm's value decode, and
    one half of the MANDATED INVERSE PAIR this module's header
    calls a HARD-FAIL GATE.

    Two independent decodes live in that function and BOTH were defective:
      * the `%XX` byte, `chr((hi << 4) | lo)` — exercised by the escaped
        fixture. ⚠ NOTE this one is NOT matched by a `chr(Int(` grep, which
        is how it survived the earlier passes over this class.
      * the pass-through byte, `chr(Int(b))` — exercised by the RAW fixture,
        because Spark/Hive write unescaped UTF-8 directory names and nothing
        in the parse path rejects them.

    Killed by: restoring either decode in `_url_unescape`.
    """
    # (a) the ESCAPED form — what `encode_partition_value` produces.
    _assert_bytes_eq(
        parse_partition_value(String("Z%C3%BCrich"), ArrowType.STRING),
        _zurich(),
        "parse_partition_value(%XX escaped)",
    )
    # 3-byte and 4-byte lead classes through the same `%XX` decode.
    _assert_bytes_eq(
        parse_partition_value(String("%E6%9D%B1%E4%BA%AC"), ArrowType.STRING),
        String("東京"),
        "parse_partition_value(%XX escaped, 3-byte)",
    )
    _assert_bytes_eq(
        parse_partition_value(String("%F0%90%8D%88"), ArrowType.STRING),
        String("𐍈"),
        "parse_partition_value(%XX escaped, 4-byte)",
    )
    # (b) the RAW pass-through form — an unescaped on-disk directory.
    _assert_bytes_eq(
        parse_partition_value(_zurich(), ArrowType.STRING),
        _zurich(),
        "parse_partition_value(raw pass-through)",
    )
    _assert_bytes_eq(
        parse_partition_value(String("東京"), ArrowType.STRING),
        String("東京"),
        "parse_partition_value(raw pass-through, 3-byte)",
    )
    _assert_bytes_eq(
        parse_partition_value(String("𐍈"), ArrowType.STRING),
        String("𐍈"),
        "parse_partition_value(raw pass-through, 4-byte)",
    )


def test_encode_parse_round_trip_holds_for_non_ascii() raises:
    """SITE: same. THE MODULE'S OWN HARD-FAIL GATE, restated over non-ASCII.

    The header of `partition_codec.mojo` says the encode/parse pair MUST
    round-trip exactly, because a one-byte disagreement builds a list prefix
    that matches nothing on disk and the query silently returns zero rows.
    The existing round-trip matrix is entirely ASCII, which is the corruption's
    fixed point — so the gate was green over a broken pair.

    ⚠ This asserts round-trip identity AND the exact intermediate encoding, so
    it cannot be satisfied by both halves being wrong in a cancelling way.

    Killed by: restoring either decode in `_url_unescape`.
    """
    var vals = _disk_values()
    for i in range(len(vals)):
        var enc = encode_partition_value(vals[i], ArrowType.STRING)
        var back = parse_partition_value(enc, ArrowType.STRING)
        _assert_bytes_eq(back, vals[i], "encode->parse round trip")
    # Pin the intermediate too, so a change that breaks BOTH halves alike
    # cannot pass on round-trip identity alone.
    _assert_bytes_eq(
        encode_partition_value(_zurich(), ArrowType.STRING),
        String("Z%C3%BCrich"),
        "encode_partition_value intermediate",
    )


# =============================================================================
# FALSIFIER 6 — `partition_codec._kv_split`
# =============================================================================


def test_parse_key_value_segments_reproduces_key_and_value_bytes() raises:
    """SITE: `komira_fs/partition_codec._kv_split`, behind
    `parse_key_value_segments` — the LAZY arm's `key=value` splitter and the
    counterpart of the engine-side `hive_partition_parser._parse_kv_component`
    fixed the same day.

    The KEY and the VALUE were two SEPARATE defective loops on opposite sides
    of the `=`, so the fixture puts a non-ASCII key AND a non-ASCII value in
    the same path: a fix to one arm only cannot pass.

    ⚠ It also pins that a RAW non-ASCII segment is not silently DROPPED:
    `_segment_has_disqualifying_byte` screens `?` and bytes < 0x20 only, so
    these segments are partition components and must be reported as such.

    Killed by: restoring either `key += chr(Int(bs[i]))` or
    `val += chr(Int(bs[i]))` in `_kv_split`.
    """
    var path = (
        String("/w/région=ouest/city=")
        + _zurich()
        + String("/東京=𐍈/part-0.parquet")
    )
    var keys = List[String]()
    var vals = List[String]()
    parse_key_value_segments(path, keys, vals)
    assert_equal(len(keys), 3)
    assert_equal(len(vals), 3)
    _assert_bytes_eq(keys[0], String("région"), "kv key 0 (non-ASCII key)")
    _assert_bytes_eq(vals[0], String("ouest"), "kv value 0 (ASCII control)")
    _assert_bytes_eq(keys[1], String("city"), "kv key 1 (ASCII control)")
    _assert_bytes_eq(vals[1], _zurich(), "kv value 1 (non-ASCII value)")
    _assert_bytes_eq(keys[2], String("東京"), "kv key 2 (3-byte lead)")
    _assert_bytes_eq(vals[2], String("𐍈"), "kv value 2 (4-byte lead)")


# =============================================================================
# THE JOIN — readdir straight through the lazy arm's parse, on REAL bytes
# =============================================================================


def test_listed_non_ascii_path_parses_back_to_its_own_directory_name() raises:
    """The two halves composed: a REAL non-ASCII directory is listed by
    `LocalFs.list` (the readdir decode) and then split by
    `parse_key_value_segments` (the `_kv_split` decode), and the recovered
    value must equal the byte string the directory was CREATED from.

    ⚠ This is the composition, NOT an agreement check: the expected value is
    the fixture's own source text, so both halves being wrong alike still
    reds.

    Killed by: reverting EITHER `_local_fs_list_recursive` or `_kv_split`.
    """
    var root = _disk_root(String("join"))
    _build_non_ascii_hive_tree(root)
    var fs = _Fs.new()
    var listed = fs.list(root + String("/dir"))
    assert_equal(len(listed), _N_DISK_VALUES)

    var vals = _disk_values()
    var seen = 0
    for i in range(len(listed)):
        var keys = List[String]()
        var pvals = List[String]()
        parse_key_value_segments(listed[i], keys, pvals)
        assert_equal(len(keys), 1)
        _assert_bytes_eq(keys[0], String("city"), "joined key")
        var at = _index_of(vals, pvals[0])
        if at < 0:
            raise Error(
                "the value parsed out of a listed path is not one of the"
                " directory names the fixture created: ["
                + _hex(_bytes_of(pvals[0]))
                + "]"
            )
        _assert_bytes_eq(pvals[0], vals[at], "joined value")
        seen += 1
    assert_equal(seen, _N_DISK_VALUES)
    _sh(String("rm -rf '") + root + String("'"))


def main() raises:
    test_fixture_is_actually_non_ascii()
    test_readdir_recursive_reproduces_path_bytes_exactly()
    test_a_listed_path_can_actually_be_opened()
    test_readdir_shallow_reproduces_entry_name_bytes_exactly()
    test_split_static_prefix_reproduces_pattern_bytes_exactly()
    test_brace_expand_reproduces_alternative_bytes_exactly()
    test_shallow_basename_reproduces_key_bytes_exactly()
    test_parse_partition_value_decodes_escapes_to_exact_bytes()
    test_encode_parse_round_trip_holds_for_non_ascii()
    test_parse_key_value_segments_reproduces_key_and_value_bytes()
    test_listed_non_ascii_path_parses_back_to_its_own_directory_name()
    print("test_fs_path_bytes_non_ascii: ALL PASS")
