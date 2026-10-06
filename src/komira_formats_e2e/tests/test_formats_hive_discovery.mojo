# =============================================================================
# Discovery of a real Hive tree with a non-ASCII partition value.
# =============================================================================
#
# The tree is written by the four real writers (`write_hive_tree`) into this
# run's TEST_TMPDIR, so the files exist on disk and the listing is the real
# `LocalFs.list` (the readdir shim), not an injected path list.
#
# What each test proves, and the defect it catches:
#   * test_eager_directory_lists_exact_set -- `EagerGlobDiscovery` in
#     directory mode returns exactly the eight files, byte for byte, in byte
#     order. A readdir decode that re-encodes each byte as a code point
#     (`chr(byte)`) returns `city=ZÃ¼rich` for the four Zürich files, a path
#     that does not exist; this test reds on it.
#   * test_eager_glob_non_ascii_static_prefix -- a glob whose static prefix
#     holds the non-ASCII directory (`.../city=Zürich/*.{csv,orc}`) matches
#     exactly two files, and `.../*/part-0.jsonl` matches one per partition.
#   * test_hive_partition_values_are_utf8_exact -- `PrunedHiveDiscovery.open`
#     infers one STRING partition column `city` and reports, for each file,
#     the value whose bytes are exactly 5A C3 BC 72 69 63 68 (or `Oslo`).
#   * test_prune_to_zurich_by_fold -- the tree gets two near-miss sibling
#     partitions, `city=Zurich` (ASCII u) and `city=Zürich` spelled NFD
#     (5A 75 CC 88 72 69 63 68: u + U+0308), each with one file. `open_pruned`
#     with `city = 'Zürich'` (precomposed) and the partition schema inferred
#     keeps exactly the four precomposed Zürich files and neither sibling: the
#     predicate is applied to each listed path's decoded value as a byte
#     compare. A compare that folds accents or case, normalizes Unicode, or
#     looks only at a prefix or first byte keeps a sibling and reds (planted:
#     a first-byte compare in the STRING equality gave "fold prune: 6 paths,
#     want 4").
#   * test_escaped_partition_dir_decodes -- a directory spelled the way
#     komira's own encoder writes it, `city=Z%C3%BCrich`, decodes to exactly
#     the 7 raw bytes of `Zürich` (the %-unescape accumulates bytes; a
#     `chr(byte)` decode would yield `ZÃ¼rich`).
#   * test_prune_to_oslo_by_prefix -- with the column declared, the equality
#     is spliced into the list prefix (`<root>/city=Oslo/`); exactly the four
#     Oslo files come back, so the targeted listing is exercised on disk.
#     The same route is not asserted for Zürich: `encode_partition_value`
#     %-escapes every byte >= 0x80, so the derived prefix is
#     `<root>/city=Z%C3%BCrich/`, which does not name the raw-UTF-8 directory
#     this tree (and Spark or Hive) writes, and `open_pruned` raises "matched
#     no files" (komira-ai/komira#448). The fold route above is the one that
#     finds it today; add the Zürich prefix-route leg when that issue is fixed.
#
# Where the expectations come from: the listing is read from disk; the
# expected paths are built by the fixture's `file_path` from `city_zurich()`
# and `city_oslo()`, the same helpers that named the files when they were
# written. What keeps that from being circular for the non-ASCII case is
# test_fixture_is_not_ascii, which pins `city_zurich()` to the literal bytes
# 5A C3 BC 72 69 63 68, and the byte compare of every listed path and
# partition value against those bytes.
# =============================================================================

from std.os import makedirs
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_arrow.arrow_types import ArrowType
from komira_fs.file_discovery import EagerGlobDiscovery, GlobDiscoveryOptions
from komira_fs.local_fs import LocalFs
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    PrunedHiveDiscovery,
)
from komira_runtime_paths import test_tmpdir

from komira_formats_e2e import (
    city_oslo,
    city_zurich,
    file_path,
    write_file_bytes,
    write_hive_tree,
)


comptime _Fs = LocalFs[NoopSink]


def _hex(s: String) -> String:
    var digits = String("0123456789ABCDEF").as_bytes()
    var bs = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bs)):
        if i > 0:
            out.append(UInt8(ord(" ")))
        out.append(digits[Int(bs[i]) >> 4])
        out.append(digits[Int(bs[i]) & 0xF])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _assert_same_bytes(got: String, want: String, label: String) raises:
    if got != want:
        raise Error(
            label + ": got [" + _hex(got) + "] want [" + _hex(want) + "]"
        )


def _root(tag: String) raises -> String:
    var base = test_tmpdir()
    var n = base.byte_length()
    if n > 1 and base.as_bytes()[n - 1] == UInt8(ord("/")):
        var trimmed = String(base[byte = 0 : n - 1])
        return trimmed + "/formats_e2e_" + tag
    return base + "/formats_e2e_" + tag


def _built_tree(tag: String) raises -> String:
    var root = _root(tag)
    write_hive_tree(root)
    return root


def _zurich_files(root: String) -> List[String]:
    var z = city_zurich()
    var out = List[String]()
    out.append(file_path(root, z, "avro"))
    out.append(file_path(root, z, "csv"))
    out.append(file_path(root, z, "jsonl"))
    out.append(file_path(root, z, "orc"))
    return out^


def _oslo_files(root: String) -> List[String]:
    var o = city_oslo()
    var out = List[String]()
    out.append(file_path(root, o, "avro"))
    out.append(file_path(root, o, "csv"))
    out.append(file_path(root, o, "jsonl"))
    out.append(file_path(root, o, "orc"))
    return out^


def _all_files(root: String) -> List[String]:
    """Byte order: `O` (4F) sorts before `Z` (5A)."""
    var out = _oslo_files(root)
    var z = _zurich_files(root)
    for i in range(len(z)):
        out.append(z[i].copy())
    return out^


def _assert_paths(
    got_count: Int, got: List[String], want: List[String], label: String
) raises:
    if got_count != len(want):
        var listing = String("")
        for i in range(len(got)):
            listing += "\n    " + got[i]
        raise Error(
            label + ": " + String(got_count) + " paths, want "
            + String(len(want)) + ":" + listing
        )
    for i in range(len(want)):
        _assert_same_bytes(got[i], want[i], label + " path " + String(i))


def _eager_paths(d: EagerGlobDiscovery) raises -> List[String]:
    var out = List[String]()
    for i in range(d.num_paths()):
        out.append(d.path_at(i))
    return out^


def _hive_paths(d: PrunedHiveDiscovery) raises -> List[String]:
    var out = List[String]()
    for i in range(d.num_paths()):
        out.append(d.path_at(i))
    return out^


def test_fixture_is_not_ascii() raises:
    """Vacuity guard: the partition value under test is the 7-byte
    precomposed spelling, so an ASCII-only fixed point cannot hide a decode
    defect."""
    var z = city_zurich().as_bytes()
    var want = [0x5A, 0xC3, 0xBC, 0x72, 0x69, 0x63, 0x68]
    assert_equal(len(z), len(want), "Zürich is 7 bytes")
    for i in range(len(want)):
        assert_equal(Int(z[i]), want[i], "Zürich byte " + String(i))


def test_eager_directory_lists_exact_set() raises:
    var root = _built_tree("eager_dir")
    var fs = _Fs.new()
    var d = EagerGlobDiscovery.open(fs, root)
    var got = _eager_paths(d)
    _assert_paths(d.num_paths(), got, _all_files(root), "eager dir")
    assert_equal(d.partition_schema().num_columns(), 0, "eager is not hive-aware")


def test_eager_glob_non_ascii_static_prefix() raises:
    var root = _built_tree("eager_glob")
    var fs = _Fs.new()
    var z = city_zurich()

    var d1 = EagerGlobDiscovery.open(fs, _zurich_glob(root, z))
    var want1 = List[String]()
    want1.append(file_path(root, z, "csv"))
    want1.append(file_path(root, z, "orc"))
    _assert_paths(d1.num_paths(), _eager_paths(d1), want1, "glob Zürich/*.{csv,orc}")

    var d2 = EagerGlobDiscovery.open(fs, root + "/*/part-0.jsonl")
    var want2 = List[String]()
    want2.append(file_path(root, city_oslo(), "jsonl"))
    want2.append(file_path(root, z, "jsonl"))
    _assert_paths(d2.num_paths(), _eager_paths(d2), want2, "glob */part-0.jsonl")


def _zurich_glob(root: String, city: String) -> String:
    return root + "/city=" + city + "/*.{csv,orc}"


def test_hive_partition_values_are_utf8_exact() raises:
    var root = _built_tree("hive_values")
    var fs = _Fs.new()
    var d = PrunedHiveDiscovery.open(fs, root)
    var want = _all_files(root)
    _assert_paths(d.num_paths(), _hive_paths(d), want, "hive open")

    assert_equal(d.num_partition_cols(), 1, "one partition column")
    _assert_same_bytes(d.partition_col_name_at(0), String("city"), "column name")
    assert_true(
        d.partition_col_type_at(0) == ArrowType.STRING, "city infers STRING"
    )
    for i in range(d.num_paths()):
        var pv = d.partition_values_at(i)
        assert_equal(pv.num_pairs(), 1, "one pair for path " + String(i))
        _assert_same_bytes(pv.keys[0], String("city"), "key " + String(i))
        # Paths 0-3 are Oslo, 4-7 Zürich (byte order, asserted above).
        var want_city = city_oslo() if i < 4 else city_zurich()
        _assert_same_bytes(pv.values[0], want_city, "city of path " + String(i))


def _eq_city(value: String) -> PartitionPredicate:
    var cs = List[PartitionConstraint]()
    cs.append(PartitionConstraint.eq(String("city"), value, ArrowType.STRING))
    return PartitionPredicate(constraints=cs^)


def _from_bytes(bs: List[Int]) -> String:
    var out = List[UInt8]()
    for i in range(len(bs)):
        out.append(UInt8(bs[i]))
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _zurich_nfd() -> String:
    """`Zürich` decomposed: Z, u, U+0308 (CC 88), rich."""
    return _from_bytes([0x5A, 0x75, 0xCC, 0x88, 0x72, 0x69, 0x63, 0x68])


def _write_sibling(root: String, city: String) raises:
    var pdir = root + "/city=" + city
    makedirs(pdir, exist_ok=True)
    var body = List[UInt8]()
    body.extend("id\n1\n".as_bytes())
    write_file_bytes(pdir + "/part-0.csv", body)


def test_prune_to_zurich_by_fold() raises:
    var root = _built_tree("prune_fold")
    _write_sibling(root, String("Zurich"))
    _write_sibling(root, _zurich_nfd())
    var fs = _Fs.new()

    # Vacuity guard: the near-misses are on disk and discovered unpruned, as
    # values distinct from the precomposed spelling.
    var every = PrunedHiveDiscovery.open(fs, root)
    assert_equal(every.num_paths(), 10, "eight tree files + two near-miss siblings")
    var seen_ascii = False
    var seen_nfd = False
    for i in range(every.num_paths()):
        var v = every.partition_values_at(i).values[0]
        if v == String("Zurich"):
            seen_ascii = True
        if v == _zurich_nfd():
            seen_nfd = True
    assert_true(seen_ascii, "city=Zurich sibling discovered")
    assert_true(seen_nfd, "NFD city=Zürich sibling discovered")
    assert_true(_zurich_nfd() != city_zurich(), "NFD differs from NFC in bytes")

    var d = PrunedHiveDiscovery.open_pruned(
        fs,
        root,
        List[String](),  # infer the partition schema
        List[ArrowType](),
        _eq_city(city_zurich()),
        GlobDiscoveryOptions.default(),
    )
    _assert_paths(d.num_paths(), _hive_paths(d), _zurich_files(root), "fold prune")
    for i in range(d.num_paths()):
        _assert_same_bytes(
            d.partition_values_at(i).values[0], city_zurich(), "pruned city " + String(i)
        )


def test_escaped_partition_dir_decodes() raises:
    var root = _root("escaped")
    _write_sibling(root, String("Z%C3%BCrich"))
    var fs = _Fs.new()
    var d = PrunedHiveDiscovery.open(fs, root)
    assert_equal(d.num_paths(), 1, "one file under the escaped directory")
    _assert_same_bytes(
        d.path_at(0), root + "/city=Z%C3%BCrich/part-0.csv", "escaped path"
    )
    _assert_same_bytes(
        d.partition_values_at(0).values[0], city_zurich(), "decoded city"
    )


def test_prune_to_oslo_by_prefix() raises:
    var root = _built_tree("prune_prefix")
    var fs = _Fs.new()
    var cols = List[String]()
    cols.append(String("city"))
    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    var d = PrunedHiveDiscovery.open_pruned(
        fs, root, cols, types, _eq_city(city_oslo()), GlobDiscoveryOptions.default()
    )
    _assert_paths(d.num_paths(), _hive_paths(d), _oslo_files(root), "prefix prune")


def main() raises:
    test_fixture_is_not_ascii()
    test_eager_directory_lists_exact_set()
    test_eager_glob_non_ascii_static_prefix()
    test_hive_partition_values_are_utf8_exact()
    test_prune_to_zurich_by_fold()
    test_escaped_partition_dir_decodes()
    test_prune_to_oslo_by_prefix()
    print("test_formats_hive_discovery: ALL PASS")
