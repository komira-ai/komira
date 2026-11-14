# What a dataset is: a name, a scale, and the files that make it up, each with
# the size, the sha256 and the row count it is expected to have. Values only:
# nothing here reads a file.
#
# An expectation can be unrecorded: `UNRECORDED_BYTES` and `UNRECORDED_ROWS`
# are -1 and an empty sha256 means no checksum is recorded yet. The verifier
# (verify.mojo) reports what it observed for such a file so the value can be
# recorded after the first verified run. A checksum is filled in here only
# where it is known for certain.

comptime UNRECORDED_BYTES: Int = -1
"""A file whose size is not recorded yet."""

comptime UNRECORDED_ROWS: Int = -1
"""A file whose row count is not recorded yet."""

comptime H2O_DEFAULT_SEED: UInt64 = 0x6B6F6D697261
"""The seed of the standard h2o-style datasets."""

comptime H2O_DEFAULT_ROWS: Int = 10_000_000
"""The row count of the standard h2o-style datasets."""

comptime H2O_DEFAULT_GROUPS: Int = 100
"""The group count `k` of the standard h2o-style group-by dataset."""

comptime H2O_GENERATOR_VERSION: String = "komira-h2o-1"
"""Names the h2o-style generator's output: a change to what it writes for a
seed and a size is a new version."""


def _is_token_byte(c: UInt8) -> Bool:
    return (
        (c >= 0x30 and c <= 0x39)
        or (c >= 0x41 and c <= 0x5A)
        or (c >= 0x61 and c <= 0x7A)
        or c == 0x5F
        or c == 0x2D
        or c == 0x2E
    )


def is_token(text: String) -> Bool:
    """True when `text` is non-empty and holds only ASCII letters, digits,
    '_', '-' and '.'. Dataset names, scales and generator names are tokens, so
    a lock file can hold them as one word."""
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        if not _is_token_byte(bytes[i]):
            return False
    return True


def is_sha256_hex(text: String) -> Bool:
    """True for exactly 64 lowercase hexadecimal characters."""
    var bytes = text.as_bytes()
    if len(bytes) != 64:
        return False
    for i in range(64):
        var c = bytes[i]
        if not ((c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x66)):
            return False
    return True


def validate_relative_path(path: String) raises:
    """Raise unless `path` is a relative path inside a cache directory: not
    empty, no leading '/', no backslash, and every '/'-separated segment a
    non-empty token that is neither "." nor "..".

    Raises:
        Error: naming the path and the rule it breaks.
    """
    if path.byte_length() == 0:
        raise Error("dataset path: empty")
    if path.as_bytes()[0] == 0x2F:
        raise Error("dataset path: absolute path refused: " + path)
    var segments = path.split("/")
    for i in range(len(segments)):
        var seg = String(segments[i])
        if seg.byte_length() == 0:
            raise Error("dataset path: empty segment in " + path)
        if seg == "." or seg == "..":
            raise Error("dataset path: '" + seg + "' segment refused in " + path)
        if not is_token(seg):
            raise Error("dataset path: unsupported character in " + path)


struct DatasetFile(Copyable, Movable):
    """One file of a dataset, by path relative to the cache directory."""

    var path: String
    var expected_bytes: Int
    """The size in bytes, or `UNRECORDED_BYTES`."""
    var expected_sha256: String
    """64 lowercase hex characters, or empty when not recorded."""
    var expected_rows: Int
    """The row count, or `UNRECORDED_ROWS`."""

    def __init__(
        out self,
        var path: String,
        expected_bytes: Int,
        var expected_sha256: String,
        expected_rows: Int,
    ):
        self.path = path^
        self.expected_bytes = expected_bytes
        self.expected_sha256 = expected_sha256^
        self.expected_rows = expected_rows

    @staticmethod
    def unrecorded(var path: String, expected_rows: Int) -> DatasetFile:
        """A file whose size and checksum are recorded on its first verified
        run; its row count may be known."""
        return DatasetFile(path^, UNRECORDED_BYTES, String(), expected_rows)

    def has_bytes(self) -> Bool:
        return self.expected_bytes >= 0

    def has_sha256(self) -> Bool:
        return self.expected_sha256.byte_length() > 0

    def has_rows(self) -> Bool:
        return self.expected_rows >= 0


struct DatasetManifest(Copyable, Movable):
    """A dataset at one scale: its files and what each must be."""

    var name: String
    """A token: tpch, clickbench, h2o_groupby, h2o_join."""
    var scale: String
    """A token: sf10, full, n10000000_k100_seed123."""
    var generator: String
    """The generator's version token, or empty for files the user supplies."""
    var files: List[DatasetFile]

    def __init__(
        out self,
        var name: String,
        var scale: String,
        var generator: String,
        var files: List[DatasetFile],
    ):
        self.name = name^
        self.scale = scale^
        self.generator = generator^
        self.files = files^

    def validate(self) raises:
        """Raise unless the manifest is well formed: name and scale are
        tokens, the generator is empty or a token, there is at least one file,
        every path is a valid relative path and appears once, every recorded
        checksum is 64 lowercase hex characters, and no recorded size or row
        count is below the unrecorded marker.

        Raises:
            Error: naming the first thing wrong.
        """
        if not is_token(self.name):
            raise Error("manifest: name is not a token: '" + self.name + "'")
        if not is_token(self.scale):
            raise Error("manifest: scale is not a token: '" + self.scale + "'")
        if self.generator.byte_length() > 0 and not is_token(self.generator):
            raise Error("manifest: generator is not a token: '" + self.generator + "'")
        if len(self.files) == 0:
            raise Error("manifest " + self.name + " " + self.scale + ": no files")
        for i in range(len(self.files)):
            ref f = self.files[i]
            validate_relative_path(f.path)
            for j in range(i):
                if self.files[j].path == f.path:
                    raise Error("manifest: path listed twice: " + f.path)
            if f.has_sha256() and not is_sha256_hex(f.expected_sha256):
                raise Error("manifest: sha256 is not 64 lowercase hex: " + f.path)
            if f.expected_bytes < UNRECORDED_BYTES:
                raise Error("manifest: size below the unrecorded marker: " + f.path)
            if f.expected_rows < UNRECORDED_ROWS:
                raise Error("manifest: row count below the unrecorded marker: " + f.path)


# --- Recorded checksums ---------------------------------------------------------
# A checksum is recorded here once, by a human, from the lines the stage tool
# prints (stage.mojo, `komira-bench-stage tpch` / `verify`). The tables of
# TPC-H and ClickBench read this list when they are built: a path listed here
# gets its size and sha256 (and its row count, when the line has one), so from
# then on the verifier reports VERIFIED instead of UNRECORDED.


struct RecordedFile(Copyable, Movable):
    """One recorded file: the path, the size and the sha256 a first verified
    run observed, and the row count it observed (`UNRECORDED_ROWS` when the
    run did not count rows)."""

    var path: String
    var bytes: Int
    var sha256: String
    var rows: Int

    def __init__(out self, var path: String, bytes: Int, var sha256: String, rows: Int):
        self.path = path^
        self.bytes = bytes
        self.sha256 = sha256^
        self.rows = rows


def recorded_line(path: String, bytes: Int, sha256: String, rows: Int) -> String:
    """The line `recorded_files` takes for a file, as the stage tool prints it:
    paste it above `return out^`."""
    return (
        String('    out.append(RecordedFile("') + path + String('", ')
        + String(bytes) + String(', "') + sha256 + String('", ') + String(rows) + String("))")
    )


def recorded_files() -> List[RecordedFile]:
    """Every checksum recorded so far. Nothing is recorded yet: no dataset has
    been staged and measured on a benchmark host."""
    var out = List[RecordedFile]()
    return out^


def apply_recorded(mut files: List[DatasetFile], recorded: List[RecordedFile]) raises:
    """Fill the size, sha256 and row count of every file of `files` that has a
    record in `recorded` (a record for another dataset's path is ignored).

    Raises:
        Error: a record that is not a size of at least 0 and a sha256 of 64
            lowercase hex characters, a path recorded twice, or a record that
            contradicts a size or row count the manifest already knows.
    """
    for r in range(len(recorded)):
        ref rec = recorded[r]
        for q in range(r):
            if recorded[q].path == rec.path:
                raise Error("recorded: path recorded twice: " + rec.path)
        if rec.bytes < 0 or not is_sha256_hex(rec.sha256) or rec.rows < UNRECORDED_ROWS:
            raise Error("recorded: malformed record for " + rec.path)
        for i in range(len(files)):
            if files[i].path != rec.path:
                continue
            if files[i].has_bytes() and files[i].expected_bytes != rec.bytes:
                raise Error("recorded: size of " + rec.path + " contradicts the manifest")
            if files[i].has_rows() and rec.rows >= 0 and files[i].expected_rows != rec.rows:
                raise Error("recorded: row count of " + rec.path + " contradicts the manifest")
            files[i].expected_bytes = rec.bytes
            files[i].expected_sha256 = rec.sha256.copy()
            if rec.rows >= 0:
                files[i].expected_rows = rec.rows


# --- TPC-H -------------------------------------------------------------------
# One Parquet file per table at <dir>/tpch/sf<N>/<table>.parquet. The user
# supplies the files. Row counts follow the specification's cardinalities, which
# scale linearly except for region and nation; lineitem's count is not linear
# and is recorded only where it is known (scale factor 1).


def tpch_manifest(scale_factor: Int) raises -> DatasetManifest:
    """The TPC-H manifest at scale factor 1, 10 or 100.

    Raises:
        Error: any other scale factor.
    """
    if scale_factor != 1 and scale_factor != 10 and scale_factor != 100:
        raise Error(
            "tpch_manifest: scale factor " + String(scale_factor) + " is not 1, 10 or 100"
        )
    var scale = String("sf") + String(scale_factor)
    var dir = String("tpch/") + scale + "/"
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(dir + "region.parquet", 5))
    files.append(DatasetFile.unrecorded(dir + "nation.parquet", 25))
    files.append(DatasetFile.unrecorded(dir + "supplier.parquet", 10_000 * scale_factor))
    files.append(DatasetFile.unrecorded(dir + "customer.parquet", 150_000 * scale_factor))
    files.append(DatasetFile.unrecorded(dir + "part.parquet", 200_000 * scale_factor))
    files.append(DatasetFile.unrecorded(dir + "partsupp.parquet", 800_000 * scale_factor))
    files.append(DatasetFile.unrecorded(dir + "orders.parquet", 1_500_000 * scale_factor))
    var lineitem_rows = 6_001_215 if scale_factor == 1 else UNRECORDED_ROWS
    files.append(DatasetFile.unrecorded(dir + "lineitem.parquet", lineitem_rows))
    apply_recorded(files, recorded_files())
    var m = DatasetManifest(String("tpch"), scale^, String(), files^)
    m.validate()
    return m^


# --- ClickBench ----------------------------------------------------------------
# One file the user supplies at <dir>/clickbench/hits.parquet: the single-file
# `hits` table of 99,997,497 rows and 14,779,976,446 bytes. Its checksum is
# recorded on the first verified run.


def clickbench_manifest() raises -> DatasetManifest:
    """The ClickBench `hits` manifest."""
    var files = List[DatasetFile]()
    files.append(
        DatasetFile(
            String("clickbench/hits.parquet"),
            14_779_976_446,
            String(),
            99_997_497,
        )
    )
    apply_recorded(files, recorded_files())
    var m = DatasetManifest(String("clickbench"), String("full"), String(), files^)
    m.validate()
    return m^


# --- h2o-style (generated) ------------------------------------------------------
# The files komira writes itself (h2o_groupby.mojo, h2o_join.mojo). Their row
# counts are exact; size and checksum are recorded on the first verified run,
# because the bytes are tied to the writer and the generator version.


def _require_h2o_size(who: String, rows: Int) raises:
    if rows < 1 or rows > 2_000_000_000:
        raise Error(who + ": rows must be in 1..2000000000, got " + String(rows))


def h2o_groupby_id3_range(rows: Int, groups: Int) -> Int:
    """The number of distinct id3 and id6 values: `rows // groups`, at least 1."""
    var n = rows // groups
    return n if n > 1 else 1


def h2o_groupby_scale(rows: Int, groups: Int, seed: UInt64) -> String:
    return (
        String("n") + String(rows) + "_k" + String(groups) + "_seed" + String(seed)
    )


def h2o_groupby_path(rows: Int, groups: Int, seed: UInt64) -> String:
    return String("h2o/groupby_") + h2o_groupby_scale(rows, groups, seed) + ".parquet"


def h2o_groupby_manifest(rows: Int, groups: Int, seed: UInt64) raises -> DatasetManifest:
    """The manifest of the generated group-by file of `rows` rows and `groups`
    groups for `seed`.

    Raises:
        Error: `rows` outside 1..2000000000 or `groups` outside 1..rows.
    """
    _require_h2o_size("h2o_groupby_manifest", rows)
    if groups < 1 or groups > rows:
        raise Error("h2o_groupby_manifest: groups must be in 1..rows, got " + String(groups))
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(h2o_groupby_path(rows, groups, seed), rows))
    var m = DatasetManifest(
        String("h2o_groupby"),
        h2o_groupby_scale(rows, groups, seed),
        String(H2O_GENERATOR_VERSION),
        files^,
    )
    m.validate()
    return m^


def h2o_join_small_rows(rows: Int) -> Int:
    """Rows of the `small` join table: `rows // 1000000`, at least 1."""
    var n = rows // 1_000_000
    return n if n > 1 else 1


def h2o_join_medium_rows(rows: Int) -> Int:
    """Rows of the `medium` join table: `rows // 1000`, at least 1."""
    var n = rows // 1_000
    return n if n > 1 else 1


def h2o_join_scale(rows: Int, seed: UInt64) -> String:
    return String("n") + String(rows) + "_seed" + String(seed)


def h2o_join_path(rows: Int, seed: UInt64, table: String) -> String:
    return String("h2o/join_") + h2o_join_scale(rows, seed) + "_" + table + ".parquet"


def h2o_join_manifest(rows: Int, seed: UInt64) raises -> DatasetManifest:
    """The manifest of the four generated join files (x, small, medium, big)
    for a `rows`-row x table and `seed`.

    Raises:
        Error: `rows` outside 1..2000000000.
    """
    _require_h2o_size("h2o_join_manifest", rows)
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(h2o_join_path(rows, seed, "x"), rows))
    files.append(
        DatasetFile.unrecorded(h2o_join_path(rows, seed, "small"), h2o_join_small_rows(rows))
    )
    files.append(
        DatasetFile.unrecorded(h2o_join_path(rows, seed, "medium"), h2o_join_medium_rows(rows))
    )
    files.append(DatasetFile.unrecorded(h2o_join_path(rows, seed, "big"), rows))
    var m = DatasetManifest(
        String("h2o_join"), h2o_join_scale(rows, seed), String(H2O_GENERATOR_VERSION), files^
    )
    m.validate()
    return m^


# --- the supported datasets -------------------------------------------------------


def supported_manifests() raises -> List[DatasetManifest]:
    """The manifest of every supported dataset at every supported scale, in a
    fixed order: TPC-H sf1, sf10, sf100, ClickBench, then the h2o-style group-by
    and join files at their standard size."""
    var out = List[DatasetManifest]()
    out.append(tpch_manifest(1))
    out.append(tpch_manifest(10))
    out.append(tpch_manifest(100))
    out.append(clickbench_manifest())
    out.append(h2o_groupby_manifest(H2O_DEFAULT_ROWS, H2O_DEFAULT_GROUPS, H2O_DEFAULT_SEED))
    out.append(h2o_join_manifest(H2O_DEFAULT_ROWS, H2O_DEFAULT_SEED))
    return out^


def find_manifest(name: String, scale: String) raises -> DatasetManifest:
    """The supported manifest with this name and scale.

    Raises:
        Error: listing the supported name and scale pairs.
    """
    var sets = supported_manifests()
    var known = String()
    for i in range(len(sets)):
        if sets[i].name == name and sets[i].scale == scale:
            return sets[i].copy()
        known += String(" ") + sets[i].name + "/" + sets[i].scale
    raise Error("no dataset " + name + "/" + scale + "; supported:" + known)
