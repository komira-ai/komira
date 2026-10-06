# =============================================================================
# test_pruned_hive_writer_spellings.mojo
# =============================================================================
# The declared-column prune finds a Hive tree in the directory spelling of
# every writer komira models, not only komira's and POSIX Spark's.
#
# THE GAP. After the raw-spelling fix the prune listed two spellings per
# value: komira's (`encode_partition_value`) and POSIX Spark's
# (`escapePathName`). Two more writers spell values differently, verified
# from their sources (see `partition_codec.mojo`, "directory spellings"):
#   * DuckDB (`HivePartitioning::EscapeValue` -> `StringUtil::URLEncode`) and
#     pyarrow / Arrow C++ (`HivePartitioning::FormatValues` ->
#     `arrow::util::UriEscape` -> uriparser `uriEscapeExA`) both escape
#     everything outside ASCII alnum and `- _ . ~`, as uppercase `%XX`. That
#     differs from komira's spelling only on `:`, which komira keeps raw: a
#     DuckDB timestamp directory is `ts=2026-11-04%2003%3A00%3A00`.
#   * Spark on Windows adds space `<` `>` `|` to Spark's set: `Zürich Nord`
#     is `Zürich%20Nord`, unlike both POSIX Spark (`Zürich Nord`) and komira
#     (`Z%C3%BCrich%20Nord`).
#
# Each on-disk test below holds a tree in ONE of those spellings and was red
# before the third and fourth spellings were listed. The prefix tests pin the
# count and order, including values whose spellings coincide. The byte-by-
# byte escape set of each writer is checked through
# `partition_value_spelling_for`.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_runtime_paths import test_tmpdir
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_fs.file_discovery import GlobDiscoveryOptions
from komira_fs.partition_codec import (
    HIVE_WRITER_KOMIRA,
    HIVE_WRITER_SPARK,
    HIVE_WRITER_URI,
    HIVE_WRITER_SPARK_WINDOWS,
    parse_partition_value,
    partition_value_spelling_for,
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
    var root = base + String("/wspell_") + tag + String("_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


def _put(root: String, key: String, seg: String, file: String) raises:
    """Create `<root>/<key>=<seg>/<file>`; `seg` is the on-disk directory
    spelling, verbatim (no `'` in any fixture, so single quotes are safe)."""
    var d = root + String("/") + key + String("=") + seg
    _sh(String("mkdir -p '") + d + String("' && printf 'X' > '") + d + String("/") + file + String("'"))


def _one(s: String) -> List[String]:
    var c = List[String]()
    c.append(s)
    return c^


def _one_type(t: ArrowType) -> List[ArrowType]:
    var c = List[ArrowType]()
    c.append(t)
    return c^


def _eq(col: String, value: String, t: ArrowType) -> PartitionPredicate:
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.eq(col, value, t))
    return PartitionPredicate(constraints=preds^)


def _open(
    root: String, col: String, t: ArrowType, value: String
) raises -> PrunedHiveDiscovery:
    var fs = _Fs.new()
    return PrunedHiveDiscovery.open_pruned(
        fs,
        root,
        _one(col),
        _one_type(t),
        _eq(col, value, t),
        GlobDiscoveryOptions.default(),
    )


def _prefixes(col: String, t: ArrowType, value: String) -> List[String]:
    var d = evaluate_partition_prefix(String("t/"), _one(col), _one_type(t), _eq(col, value, t))
    return d.prefixes.copy()


# The four spellings of `Zürich 10:30` (a value every writer spells
# differently), in the order the prune lists them.
def _mixed() -> String:
    return String("Zürich 10:30")


def _mixed_komira() -> String:
    return String("Z%C3%BCrich%2010:30")


def _mixed_spark() -> String:
    return String("Zürich 10%3A30")


def _mixed_uri() -> String:
    return String("Z%C3%BCrich%2010%3A30")


def _mixed_spark_windows() -> String:
    return String("Zürich%2010%3A30")


# =============================================================================
# on-disk: a tree in each writer's spelling
# =============================================================================


def test_duckdb_pyarrow_timestamp_tree_is_found() raises:
    """A DuckDB / pyarrow tree of a TIMESTAMP partition: `:` is `%3A`, the
    space `%20`. komira's spelling keeps `:` raw and Spark's keeps the space
    raw, so neither matched. Exactly the 03:00 file comes back. Killed by:
    not listing the DuckDB/pyarrow spelling."""
    var root = _disk_root(String("uri"))
    _put(root, String("ts"), String("2026-11-04%2003%3A00%3A00"), String("part-0.csv"))
    _put(root, String("ts"), String("2026-11-04%2004%3A00%3A00"), String("part-0.csv"))
    var disc = _open(root, String("ts"), ArrowType.TIMESTAMP, String("2026-11-04 03:00:00"))
    assert_equal(disc.num_paths(), 1)
    assert_equal(
        disc.path_at(0), root + String("/ts=2026-11-04%2003%3A00%3A00/part-0.csv")
    )
    assert_equal(disc.partition_values_at(0).values[0], String("2026-11-04 03:00:00"))
    _sh(String("rm -rf '") + root + String("'"))


def test_spark_windows_tree_is_found() raises:
    """A Windows-Spark tree: non-ASCII raw, the space `%20`. Exactly the
    `Zürich Nord` file comes back. Killed by: not listing the Windows-Spark
    spelling."""
    var root = _disk_root(String("win"))
    _put(root, String("city"), String("Zürich%20Nord"), String("part-0.csv"))
    _put(root, String("city"), String("Oslo"), String("part-0.csv"))
    var disc = _open(root, String("city"), ArrowType.STRING, String("Zürich Nord"))
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), root + String("/city=Zürich%20Nord/part-0.csv"))
    assert_equal(disc.partition_values_at(0).values[0], String("Zürich Nord"))
    _sh(String("rm -rf '") + root + String("'"))


def test_tree_with_all_four_spellings_returns_each_once() raises:
    """One value, four directories (one per writer): four files, once each,
    in byte order, all decoding to the same value. Killed by: dropping any
    spelling."""
    var root = _disk_root(String("all4"))
    _put(root, String("city"), _mixed_komira(), String("part-k.csv"))
    _put(root, String("city"), _mixed_spark(), String("part-s.csv"))
    _put(root, String("city"), _mixed_uri(), String("part-u.csv"))
    _put(root, String("city"), _mixed_spark_windows(), String("part-w.csv"))
    _put(root, String("city"), String("Oslo"), String("part-0.csv"))
    var disc = _open(root, String("city"), ArrowType.STRING, _mixed())
    assert_equal(disc.num_paths(), 4)
    # byte order: `%3A` < `:` (0x25 < 0x3A); `Z%` < `Zü`; ` ` < `%`.
    assert_equal(disc.path_at(0), root + String("/city=") + _mixed_uri() + String("/part-u.csv"))
    assert_equal(disc.path_at(1), root + String("/city=") + _mixed_komira() + String("/part-k.csv"))
    assert_equal(disc.path_at(2), root + String("/city=") + _mixed_spark() + String("/part-s.csv"))
    assert_equal(
        disc.path_at(3), root + String("/city=") + _mixed_spark_windows() + String("/part-w.csv")
    )
    for i in range(4):
        assert_equal(disc.partition_values_at(i).values[0], _mixed())
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# prefix derivation: count and order, coinciding spellings listed once
# =============================================================================


def test_prefix_value_with_four_distinct_spellings() raises:
    """`Zürich 10:30`: four prefixes, order komira, Spark, DuckDB/pyarrow,
    Windows Spark."""
    var p = _prefixes(String("city"), ArrowType.STRING, _mixed())
    assert_equal(len(p), 4)
    assert_equal(p[0], String("t/city=") + _mixed_komira() + String("/"))
    assert_equal(p[1], String("t/city=") + _mixed_spark() + String("/"))
    assert_equal(p[2], String("t/city=") + _mixed_uri() + String("/"))
    assert_equal(p[3], String("t/city=") + _mixed_spark_windows() + String("/"))


def test_prefix_timestamp_three_spellings() raises:
    """A timestamp: Windows Spark coincides with DuckDB/pyarrow (both escape
    the space and `:`), so three prefixes."""
    var p = _prefixes(String("ts"), ArrowType.TIMESTAMP, String("2026-11-04 03:00:00"))
    assert_equal(len(p), 3)
    assert_equal(p[0], String("t/ts=2026-11-04%2003:00:00/"))
    assert_equal(p[1], String("t/ts=2026-11-04 03%3A00%3A00/"))
    assert_equal(p[2], String("t/ts=2026-11-04%2003%3A00%3A00/"))


def test_prefix_coinciding_spellings_listed_once() raises:
    """Values whose spellings coincide list each distinct one once:
      * `Oslo`: all four agree -> 1;
      * `10:30`: Spark = DuckDB/pyarrow = Windows Spark (`10%3A30`) -> 2;
      * `Zürich`: DuckDB/pyarrow = komira, Windows Spark = Spark -> 2;
      * `New York`: komira = DuckDB/pyarrow = Windows Spark -> 2.
    Killed by: removing the per-value or per-column dedup."""
    var oslo = _prefixes(String("city"), ArrowType.STRING, String("Oslo"))
    assert_equal(len(oslo), 1)
    assert_equal(oslo[0], String("t/city=Oslo/"))

    var hm = _prefixes(String("city"), ArrowType.STRING, String("10:30"))
    assert_equal(len(hm), 2)
    assert_equal(hm[0], String("t/city=10:30/"))
    assert_equal(hm[1], String("t/city=10%3A30/"))

    var z = _prefixes(String("city"), ArrowType.STRING, String("Zürich"))
    assert_equal(len(z), 2)
    assert_equal(z[0], String("t/city=Z%C3%BCrich/"))
    assert_equal(z[1], String("t/city=Zürich/"))

    var ny = _prefixes(String("city"), ArrowType.STRING, String("New York"))
    assert_equal(len(ny), 2)
    assert_equal(ny[0], String("t/city=New%20York/"))
    assert_equal(ny[1], String("t/city=New York/"))


def test_prefix_two_columns_bound() raises:
    """Two pinned columns, each holding a four-spelling value: 4 x 4 = 16
    prefixes, all distinct. The documented bound (4^k for k such columns)."""
    var cols = List[String]()
    cols.append(String("a"))
    cols.append(String("b"))
    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    types.append(ArrowType.STRING)
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.eq(String("a"), _mixed(), ArrowType.STRING))
    preds.append(PartitionConstraint.eq(String("b"), _mixed(), ArrowType.STRING))
    var d = evaluate_partition_prefix(
        String("t/"), cols, types, PartitionPredicate(constraints=preds^)
    )
    assert_equal(len(d.prefixes), 16)
    for i in range(len(d.prefixes)):
        for j in range(i + 1, len(d.prefixes)):
            assert_false(d.prefixes[i] == d.prefixes[j])


# =============================================================================
# each writer's escape set, byte by byte
# =============================================================================
# The sets are restated here from the writers' sources, independently of the
# implementation (citations in `partition_codec.mojo`). Every writer escapes
# as `%XX` with UPPERCASE hex. 0x00 is escaped by every spelling komira lists
# (a documented deviation for Spark, which writes it raw, and pyarrow, whose
# uriparser stops at it).


def _in(c: Int, chars: String) -> Bool:
    var b = chars.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) == c:
            return True
    return False


def _alnum(c: Int) -> Bool:
    return (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)


def _escapes(writer: Int, c: Int) -> Bool:
    if writer == HIVE_WRITER_KOMIRA:
        # partition_codec `_is_unreserved`: alnum and `- _ . ~ :` kept.
        return not (_alnum(c) or _in(c, String("-_.~:")))
    if writer == HIVE_WRITER_URI:
        # DuckDB URLEncodeInternal / uriparser URI_SET_UNRESERVED.
        return not (_alnum(c) or _in(c, String("-_.~")))
    # Spark charToEscape (+ 0x00), Windows adding space < > |.
    var spark = c <= 0x1F or c == 0x7F or _in(c, String("\"#%'*/:=?\\{[]^"))
    if writer == HIVE_WRITER_SPARK_WINDOWS:
        return spark or _in(c, String(" <>|"))
    return spark


def _hex(c: Int) -> String:
    var d = String("0123456789ABCDEF").as_bytes()
    var out = String("%")
    out += chr(Int(d[c >> 4]))
    out += chr(Int(d[c & 15]))
    return out^


def _check_writer_byte_by_byte(writer: Int, name: String) raises:
    for c in range(0, 128):
        var value = String("a") + chr(c) + String("b")
        var want = String("a") + (_hex(c) if _escapes(writer, c) else chr(c)) + String("b")
        var got = partition_value_spelling_for(value, ArrowType.STRING, writer)
        if got != want:
            raise Error(
                name + " byte " + _hex(c) + ": got '" + got + "', want '" + want + "'"
            )
        # and every spelling decodes back to the value
        assert_equal(parse_partition_value(got, ArrowType.STRING), value)
    # bytes >= 0x80: only komira and DuckDB/pyarrow escape them
    var z = partition_value_spelling_for(String("Zürich"), ArrowType.STRING, writer)
    if writer == HIVE_WRITER_KOMIRA or writer == HIVE_WRITER_URI:
        assert_equal(z, String("Z%C3%BCrich"))
    else:
        assert_equal(z, String("Zürich"))


def test_escape_set_komira() raises:
    """komira's spelling is `encode_partition_value`, unchanged."""
    _check_writer_byte_by_byte(HIVE_WRITER_KOMIRA, String("komira"))


def test_escape_set_spark() raises:
    """Killed by: any change to Spark's POSIX set."""
    _check_writer_byte_by_byte(HIVE_WRITER_SPARK, String("spark"))


def test_escape_set_duckdb_pyarrow() raises:
    """Killed by: keeping `:` (or any other byte outside alnum `-_.~`) raw."""
    _check_writer_byte_by_byte(HIVE_WRITER_URI, String("duckdb/pyarrow"))


def test_escape_set_spark_windows() raises:
    """Killed by: dropping any of space `<` `>` `|` from the Windows set. On a
    one-byte value these coincide with komira's spelling in the prefix list,
    so only this direct check can see them."""
    _check_writer_byte_by_byte(HIVE_WRITER_SPARK_WINDOWS, String("spark-windows"))


def test_null_is_the_sentinel_for_every_writer() raises:
    for w in range(4):
        assert_equal(
            partition_value_spelling_for(String(""), ArrowType.STRING, w),
            String("__HIVE_DEFAULT_PARTITION__"),
        )
    assert_equal(len(partition_value_spellings(String(""), ArrowType.STRING)), 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_duckdb_pyarrow_timestamp_tree_is_found]()
    suite.test[test_spark_windows_tree_is_found]()
    suite.test[test_tree_with_all_four_spellings_returns_each_once]()
    suite.test[test_prefix_value_with_four_distinct_spellings]()
    suite.test[test_prefix_timestamp_three_spellings]()
    suite.test[test_prefix_coinciding_spellings_listed_once]()
    suite.test[test_prefix_two_columns_bound]()
    suite.test[test_escape_set_komira]()
    suite.test[test_escape_set_spark]()
    suite.test[test_escape_set_duckdb_pyarrow]()
    suite.test[test_escape_set_spark_windows]()
    suite.test[test_null_is_the_sentinel_for_every_writer]()
    suite^.run()
