# =============================================================================
# test_pruned_hive_raw_spelling.mojo
# =============================================================================
# A declared-column partition prune must find a Hive tree whatever spelling
# its writer used for the directory value.
#
# THE DEFECT. `PrunedHiveDiscovery.open_pruned` with a DECLARED STRING column
# and `city = 'Zürich'` built ONE list prefix, `<root>/city=Z%C3%BCrich/`,
# because `encode_partition_value` %-escapes every byte >= 0x80. Spark and
# Hive write that directory as raw UTF-8 (`city=Zürich`; Spark's
# `ExternalCatalogUtils.escapePathName` escapes only a fixed ASCII set), so
# the raw tree was never listed and the call raised "matched no files".
#
# THE CONTRACT TESTED HERE. For each pinned value the prune lists the
# komira spelling (`encode_partition_value`, unchanged) AND the Spark
# spelling (`escapePathName`) when the two differ, once each, and unions the
# files without duplicates:
#   * raw tree (the issue's repro)        -> exactly the Zürich file;
#   * escaped tree                        -> exactly the Zürich file;
#   * a tree holding BOTH spellings       -> both files, once each;
#   * ASCII control (`Oslo`)              -> one prefix, one file;
#   * IN with a repeated non-ASCII value  -> each spelling listed once;
#   * the Spark escape set, byte by byte (0x00-0x7F), through the prefix.
#
# The on-disk tests use `Zürich` exactly as the issue does. `ü` is written
# precomposed (U+00FC); ext4 and APFS store and return the bytes as given.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_runtime_paths import test_tmpdir
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_fs.file_discovery import GlobDiscoveryOptions
from komira_fs.partition_codec import (
    encode_partition_value,
    parse_partition_value,
    partition_value_spellings,
)
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    PrunedHiveDiscovery,
    evaluate_partition_prefix,
)


comptime _Fs = LocalFs[NoopSink]


# =============================================================================
# fixtures
# =============================================================================


def _zurich() -> String:
    """`Zürich`: 5A C3 BC 72 69 63 68 (asserted below, so an ASCII edit of
    the fixture cannot turn every test here into a pass on the old code)."""
    return String("Zürich")


def _zurich_escaped() -> String:
    return String("Z%C3%BCrich")


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
    var root = base + String("/rawspell_") + tag + String("_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


def _put(root: String, seg: String, file: String) raises:
    """Create `<root>/city=<seg>/<file>` with one byte of content. `seg` is the
    on-disk directory spelling, verbatim."""
    var d = root + String("/city=") + seg
    _sh(String("mkdir -p '") + d + String("'"))
    _sh(String("printf 'X' > '") + d + String("/") + file + String("'"))


def _city_cols() -> List[String]:
    var c = List[String]()
    c.append(String("city"))
    return c^


def _string_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.STRING)
    return t^


def _city_eq(value: String) -> PartitionPredicate:
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.eq(String("city"), value, ArrowType.STRING))
    return PartitionPredicate(constraints=preds^)


def _city_in(values: List[String]) -> PartitionPredicate:
    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.in_list(String("city"), values, ArrowType.STRING)
    )
    return PartitionPredicate(constraints=preds^)


def _open(root: String, pred: PartitionPredicate) raises -> PrunedHiveDiscovery:
    var fs = _Fs.new()
    return PrunedHiveDiscovery.open_pruned(
        fs,
        root,
        _city_cols(),
        _string_types(),
        pred,
        GlobDiscoveryOptions.default(),
    )


def test_fixture_is_non_ascii() raises:
    """Non-vacuity guard: the fixture holds bytes >= 0x80, so the old
    escape-everything prefix differs from the raw directory name."""
    var b = _zurich().as_bytes()
    assert_equal(len(b), 7)
    assert_equal(Int(b[1]), 0xC3)
    assert_equal(Int(b[2]), 0xBC)
    assert_equal(encode_partition_value(_zurich(), ArrowType.STRING), _zurich_escaped())


# =============================================================================
# on-disk: the issue's repro and its siblings
# =============================================================================


def test_raw_utf8_tree_declared_eq_returns_exactly_zurich() raises:
    """THE ISSUE'S REPRO. `city=Zürich` (raw, as Spark/Hive write it) and
    `city=Oslo`; declared `city = 'Zürich'` returns exactly the Zürich file.
    Red on the old code: it listed only `city=Z%C3%BCrich/` and raised
    "matched no files". Killed by: not listing the raw spelling."""
    var root = _disk_root(String("raw"))
    _put(root, _zurich(), String("part-0.csv"))
    _put(root, String("Oslo"), String("part-0.csv"))
    var disc = _open(root, _city_eq(_zurich()))
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), root + String("/city=Zürich/part-0.csv"))
    var pv = disc.partition_values_at(0)
    assert_equal(pv.values[0], _zurich())
    _sh(String("rm -rf '") + root + String("'"))


def test_escaped_tree_declared_eq_returns_exactly_zurich() raises:
    """A tree written with komira's own escaped spelling still reads (the
    read-side fix must not drop the spelling `encode_partition_value`
    writes). Killed by: listing only the raw spelling."""
    var root = _disk_root(String("esc"))
    _put(root, _zurich_escaped(), String("part-0.csv"))
    _put(root, String("Oslo"), String("part-0.csv"))
    var disc = _open(root, _city_eq(_zurich()))
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), root + String("/city=Z%C3%BCrich/part-0.csv"))
    var pv = disc.partition_values_at(0)
    assert_equal(pv.values[0], _zurich())
    _sh(String("rm -rf '") + root + String("'"))


def test_both_spellings_tree_returns_both_files_once() raises:
    """A tree holding BOTH spellings of the same value (e.g. two writers):
    both files come back, once each, in byte order (`%` 0x25 < 0xC3), and
    both decode to `Zürich`. The Oslo file never does. Also run as
    `city IN ('Zürich', 'Zürich')` so a repeated value cannot duplicate a
    file. Killed by: dropping either spelling; dropping both dedups."""
    var root = _disk_root(String("both"))
    _put(root, _zurich(), String("part-0.csv"))
    _put(root, _zurich_escaped(), String("part-1.csv"))
    _put(root, String("Oslo"), String("part-0.csv"))

    var disc = _open(root, _city_eq(_zurich()))
    assert_equal(disc.num_paths(), 2)
    assert_equal(disc.path_at(0), root + String("/city=Z%C3%BCrich/part-1.csv"))
    assert_equal(disc.path_at(1), root + String("/city=Zürich/part-0.csv"))
    assert_equal(disc.partition_values_at(0).values[0], _zurich())
    assert_equal(disc.partition_values_at(1).values[0], _zurich())

    var twice = List[String]()
    twice.append(_zurich())
    twice.append(_zurich())
    var disc2 = _open(root, _city_in(twice))
    assert_equal(disc2.num_paths(), 2)
    assert_false(disc2.path_at(0) == disc2.path_at(1))
    _sh(String("rm -rf '") + root + String("'"))


def test_ascii_control_oslo() raises:
    """ASCII control: `city = 'Oslo'` returns exactly the Oslo file. Its two
    spellings coincide, so one prefix is derived (asserted in the prefix
    tests below)."""
    var root = _disk_root(String("oslo"))
    _put(root, _zurich(), String("part-0.csv"))
    _put(root, String("Oslo"), String("part-0.csv"))
    var disc = _open(root, _city_eq(String("Oslo")))
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), root + String("/city=Oslo/part-0.csv"))
    _sh(String("rm -rf '") + root + String("'"))


def test_spark_space_tree_declared_eq() raises:
    """An ASCII value the two escape sets disagree on: Spark (non-Windows)
    leaves a space raw (`city=New York`), komira writes `New%20York`. The
    Spark-written tree is found."""
    var root = _disk_root(String("space"))
    _put(root, String("New York"), String("part-0.csv"))
    _put(root, String("Oslo"), String("part-0.csv"))
    var disc = _open(root, _city_eq(String("New York")))
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), root + String("/city=New York/part-0.csv"))
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# prefix derivation: which prefixes, how many, in what order
# =============================================================================


def test_prefix_non_ascii_eq_lists_two_spellings() raises:
    """`city = 'Zürich'` derives exactly two prefixes: komira's spelling
    first, then the raw one. Killed by: not adding the raw spelling."""
    var d = evaluate_partition_prefix(
        String("t/"), _city_cols(), _string_types(), _city_eq(_zurich())
    )
    assert_equal(len(d.prefixes), 2)
    assert_equal(d.prefixes[0], String("t/city=Z%C3%BCrich/"))
    assert_equal(d.prefixes[1], String("t/city=Zürich/"))


def test_prefix_ascii_eq_lists_one_spelling() raises:
    """`city = 'Oslo'`: the spellings coincide, so ONE prefix (no redundant
    list call). Killed by: removing both the equal-spelling check in
    `partition_value_spellings` and the per-column dedup (either alone keeps
    this green; the other tests here kill each one alone)."""
    var d = evaluate_partition_prefix(
        String("t/"), _city_cols(), _string_types(), _city_eq(String("Oslo"))
    )
    assert_equal(len(d.prefixes), 1)
    assert_equal(d.prefixes[0], String("t/city=Oslo/"))


def test_prefix_in_with_repeat_dedups_spellings() raises:
    """`city IN ('Zürich', 'Oslo', 'Zürich')` derives each distinct spelling
    once, in first-seen order: 3 prefixes, not 5. Killed by: removing the
    per-column spelling dedup."""
    var vals = List[String]()
    vals.append(_zurich())
    vals.append(String("Oslo"))
    vals.append(_zurich())
    var d = evaluate_partition_prefix(
        String("t/"), _city_cols(), _string_types(), _city_in(vals)
    )
    assert_equal(len(d.prefixes), 3)
    assert_equal(d.prefixes[0], String("t/city=Z%C3%BCrich/"))
    assert_equal(d.prefixes[1], String("t/city=Zürich/"))
    assert_equal(d.prefixes[2], String("t/city=Oslo/"))


def test_prefix_two_columns_cartesian_bound() raises:
    """Two pinned columns, each with one non-ASCII value: 2 x 2 = 4 prefixes
    (a writer may mix spellings per level). An ASCII second column keeps it
    at 2 x 1 = 2. This is the documented bound: the product over pinned
    columns of their DISTINCT spellings."""
    var cols = List[String]()
    cols.append(String("country"))
    cols.append(String("city"))
    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    types.append(ArrowType.STRING)

    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.eq(String("country"), String("Österreich"), ArrowType.STRING)
    )
    preds.append(PartitionConstraint.eq(String("city"), _zurich(), ArrowType.STRING))
    var d = evaluate_partition_prefix(
        String("t/"), cols, types, PartitionPredicate(constraints=preds^)
    )
    assert_equal(len(d.prefixes), 4)
    assert_equal(d.prefixes[0], String("t/country=%C3%96sterreich/city=Z%C3%BCrich/"))
    assert_equal(d.prefixes[1], String("t/country=%C3%96sterreich/city=Zürich/"))
    assert_equal(d.prefixes[2], String("t/country=Österreich/city=Z%C3%BCrich/"))
    assert_equal(d.prefixes[3], String("t/country=Österreich/city=Zürich/"))

    var preds2 = List[PartitionConstraint]()
    preds2.append(
        PartitionConstraint.eq(String("country"), String("Österreich"), ArrowType.STRING)
    )
    preds2.append(PartitionConstraint.eq(String("city"), String("Wien"), ArrowType.STRING))
    var d2 = evaluate_partition_prefix(
        String("t/"), cols, types, PartitionPredicate(constraints=preds2^)
    )
    assert_equal(len(d2.prefixes), 2)


def test_prefix_null_sentinel_one_spelling() raises:
    """NULL (the empty canonical value) is `__HIVE_DEFAULT_PARTITION__` in
    both spellings (Spark writes the same sentinel): one prefix."""
    var d = evaluate_partition_prefix(
        String("t/"), _city_cols(), _string_types(), _city_eq(String(""))
    )
    assert_equal(len(d.prefixes), 1)
    assert_equal(d.prefixes[0], String("t/city=__HIVE_DEFAULT_PARTITION__/"))


def test_spellings_contract() raises:
    """`partition_value_spellings` directly: komira's spelling first, Spark's
    second only when it differs; both decode back to the value. Killed by:
    removing the equal-spelling check (Oslo / NULL would get two equal
    entries); swapping the order."""
    var z = partition_value_spellings(_zurich(), ArrowType.STRING)
    assert_equal(len(z), 2)
    assert_equal(z[0], _zurich_escaped())
    assert_equal(z[1], _zurich())
    for i in range(len(z)):
        assert_equal(parse_partition_value(z[i], ArrowType.STRING), _zurich())

    var o = partition_value_spellings(String("Oslo"), ArrowType.STRING)
    assert_equal(len(o), 1)
    assert_equal(o[0], String("Oslo"))

    var n = partition_value_spellings(String(""), ArrowType.STRING)
    assert_equal(len(n), 1)
    assert_equal(n[0], String("__HIVE_DEFAULT_PARTITION__"))

    # a timestamp: komira keeps `:` and escapes the space; Spark the reverse;
    # DuckDB/pyarrow (and Windows Spark) escape both.
    var ts = partition_value_spellings(
        String("2026-11-04 03:00:00"), ArrowType.TIMESTAMP
    )
    assert_equal(len(ts), 3)
    assert_equal(ts[0], String("2026-11-04%2003:00:00"))
    assert_equal(ts[1], String("2026-11-04 03%3A00%3A00"))
    assert_equal(ts[2], String("2026-11-04%2003%3A00%3A00"))
    for i in range(len(ts)):
        assert_equal(
            parse_partition_value(ts[i], ArrowType.TIMESTAMP),
            String("2026-11-04 03:00:00"),
        )


# =============================================================================
# the raw spelling's escape set, byte by byte
# =============================================================================
# Spark `ExternalCatalogUtils.escapePathName` (sql/catalyst/.../catalog/
# ExternalCatalogUtils.scala, `charToEscape`) escapes, as `%XX` uppercase:
#   0x01-0x1F, `"` `#` `%` `'` `*` `/` `:` `=` `?` `\` 0x7F `{` `[` `]` `^`
# and nothing else on a non-Windows writer (Windows adds space `<` `>` `|`).
# Every char >= 0x80 is left raw. komira's raw spelling also escapes 0x00 (a
# NUL cannot be in a path name and must not reach a C-string boundary).
# The set is restated here independently of the implementation.


def _spark_escapes(c: Int) -> Bool:
    if c <= 0x1F or c == 0x7F:
        return True
    var punct = String("\"#%'*/:=?\\{[]^")
    var pb = punct.as_bytes()
    for i in range(len(pb)):
        if Int(pb[i]) == c:
            return True
    return False


def _hex2(c: Int) -> String:
    var digits = String("0123456789ABCDEF").as_bytes()
    var out = String("%")
    out += chr(Int(digits[c >> 4]))
    out += chr(Int(digits[c & 15]))
    return out^


def test_raw_spelling_escape_set_is_sparks() raises:
    """For every ASCII byte c, the value `a<c>b` derives the prefixes
    [komira spelling] + [Spark spelling if different], where the Spark
    spelling escapes c iff c is in `charToEscape` above. Killed by: any
    change to the raw spelling's escape set (adding `:`'s exemption, raw
    `/`, escaping space, ...). For a one-byte value the DuckDB/pyarrow and
    Windows-Spark spellings coincide with one of these two, so the list is
    still at most two long; each writer's own set is checked byte by byte in
    `test_pruned_hive_writer_spellings`."""
    for c in range(0, 128):
        var value = String("a") + chr(c) + String("b")
        var komira = encode_partition_value(value, ArrowType.STRING)
        var spark = String("a") + (_hex2(c) if _spark_escapes(c) else chr(c)) + String("b")
        var d = evaluate_partition_prefix(
            String("t/"), _city_cols(), _string_types(), _city_eq(value)
        )
        var want = List[String]()
        want.append(String("t/city=") + komira + String("/"))
        if spark != komira:
            want.append(String("t/city=") + spark + String("/"))
        if len(d.prefixes) != len(want):
            raise Error(
                "byte " + _hex2(c) + ": got " + String(len(d.prefixes))
                + " prefixes, want " + String(len(want))
            )
        for i in range(len(want)):
            if d.prefixes[i] != want[i]:
                raise Error(
                    "byte " + _hex2(c) + ": prefix " + String(i) + " is '"
                    + d.prefixes[i] + "', want '" + want[i] + "'"
                )


def main() raises:
    var suite = TestSuite()
    suite.test[test_fixture_is_non_ascii]()
    suite.test[test_raw_utf8_tree_declared_eq_returns_exactly_zurich]()
    suite.test[test_escaped_tree_declared_eq_returns_exactly_zurich]()
    suite.test[test_both_spellings_tree_returns_both_files_once]()
    suite.test[test_ascii_control_oslo]()
    suite.test[test_spark_space_tree_declared_eq]()
    suite.test[test_prefix_non_ascii_eq_lists_two_spellings]()
    suite.test[test_prefix_ascii_eq_lists_one_spelling]()
    suite.test[test_prefix_in_with_repeat_dedups_spellings]()
    suite.test[test_prefix_two_columns_cartesian_bound]()
    suite.test[test_prefix_null_sentinel_one_spelling]()
    suite.test[test_spellings_contract]()
    suite.test[test_raw_spelling_escape_set_is_sparks]()
    suite^.run()
