# =============================================================================
# komira_telemetry_store.keys: THE OBJECT-KEY LAYOUT, WHICH *IS* THE INDEX.
# =============================================================================
#
# Time-partitioned Parquet is the base at-rest artifact for logs and metrics;
# an optional text-index sidecar may sit beside it.
#
# -- WHY THE DAY IS IN THE KEY ------------------------------------------------
# It is the cheapest possible index: a reader holding `[t0,t1]` COMPUTES the day
# prefixes by arithmetic and never asks the bucket what exists. That is what
# removes listing from the read path, and removing listing is not a nicety here:
# see the next block.
#
# -- THE CONSTRAINT THAT SHAPES EVERY KEY BELOW -------------------------------
# The object-store listing primitive (`ObjectStore.list_with_delimiter`,
# `komira_objectstore/store.mojo`) is SINGLE-LEVEL, and its conformers DISAGREE
# IN BOTH DIRECTIONS:
#
#   * a local-filesystem store returns nested keys AS OBJECTS and never
#     populates `common_prefixes`;
#   * a cloud object store hides nested keys behind a rollup and DOES populate
#     `common_prefixes`.
#
# So a two-level layout looks fine on a local store and returns nothing on the
# cloud one; a `common_prefixes` descent works on the cloud store and returns
# nothing locally. Both directions are SILENT. THE THREE RULES THIS MODULE
# ENFORCES:
#
#   1. Every read-path key is either an EXACT GET of a computed name, or a
#      single-level LIST of a prefix whose remainder contains NO '/'.
#   2. Exactly ONE discovery LIST exists on the read path (writer-shard
#      enumeration), and it goes through the union fold in
#      `komira_objectstore.sublineage_shard_keys`, the spelling that is correct
#      on BOTH conformers.
#   3. KEY DEPTH IS A CONSTANT, NEVER A FREE PARAMETER. Here it is enforced, not
#      documented: every caller-supplied segment is REFUSED if it contains '/',
#      so no caller can deepen the tree and silently change what a LIST returns.
#
# -- THE KEYS -----------------------------------------------------------------
#   <root>/<ds>/<YYYYMMDD>/data/<start_ms:020d>-<uuid32hex>.parquet   BASE
#   <root>/<ds>/<YYYYMMDD>/text/<start_ms:020d>-<uuid32hex>.split     SIDECAR
#   <root>/<ds>/<YYYYMMDD>/_lineage/<writer_id>/manifest/<seq:020d>.chunk
#   <root>/<ds>/<YYYYMMDD>/_lineage/<writer_id>/_HEAD
#
# `<root>` is the caller's prefix (`TELEMETRY_ROOT`, "telemetry", by default).
# `<start_ms:020d>` prefixes the basename so a single-level LIST of `.../data/`
# returns keys in TIME ORDER. That LIST is the RECOVERY path only, never the
# read path, and its remainder is one segment, so BOTH conformers return it as
# objects. Zero-padding mirrors the CAS manifest's 20-digit sequence padding.
#
# NO SERVICE SEGMENT. Service is a COLUMN, not a path segment: a segment would
# add a level of discovery for a dimension that dictionary-encodes to
# near-nothing and would need a LIST to enumerate, the thing rule 1 forbids.
#
# NO POINTER CROSSES A MODULE BOUNDARY: every surface here is String / Int64 /
# List[String] / InlineArray by value.
# =============================================================================


# =============================================================================
# §1 — the constants. Rule 3: DEPTH IS A CONSTANT.
# =============================================================================

comptime TELEMETRY_ROOT: String = "telemetry"
"""The one root segment every telemetry object lives under."""

comptime TELEMETRY_DATASET_LOGS: String = "logs"
comptime TELEMETRY_DATASET_METRICS: String = "metrics"

comptime TELEMETRY_DATA_SEGMENT: String = "data"
comptime TELEMETRY_TEXT_SEGMENT: String = "text"
comptime TELEMETRY_DATA_SUFFIX: String = ".parquet"
comptime TELEMETRY_TEXT_SUFFIX: String = ".split"

comptime TELEMETRY_PARTITION_PREFIX_DEPTH: Int = 3
"""`telemetry/<ds>/<YYYYMMDD>` — three segments, always."""

comptime TELEMETRY_DATA_KEY_DEPTH: Int = 5
"""`telemetry/<ds>/<YYYYMMDD>/data/<basename>` — five segments, always. A key
with any other depth is not one this module produced."""

comptime TELEMETRY_START_MS_WIDTH: Int = 20
"""Zero-pad width of the `<start_ms>` basename prefix — mirrors the CAS manifest padding."""

comptime NS_PER_MS: Int64 = 1_000_000
comptime NS_PER_DAY: Int64 = 86_400_000_000_000

comptime MAX_TELEMETRY_DAYS_PER_QUERY: Int = 400
"""A read whose range covers more day partitions than this is REFUSED rather
than served: `days_covering` is the prefix generator for the whole read path, so
an unbounded range would silently become an unbounded number of exact GETs. 400
is one year of day partitions, well above a typical logs retention window."""


# =============================================================================
# §2 — segment hygiene. Rule 3, ENFORCED.
# =============================================================================


def _check_segment(seg: String, what: String) raises:
    """REFUSE a caller-supplied path segment that would change the key DEPTH.

    An empty segment collapses a level ('a//b' normalises to 'a/b' on some
    backends and not others); a segment containing '/' ADDS one. Either makes
    `TELEMETRY_DATA_KEY_DEPTH` a lie, and a lie about depth is exactly the
    defect this module exists to prevent: a LIST that returns everything on one
    backend and nothing on the other, silently, in both directions."""
    if seg.byte_length() == 0:
        raise Error(
            "telemetry keys: empty " + what + " segment — key DEPTH is a"
            " constant (see keys.mojo rule 3), an empty segment collapses one"
        )
    var b = seg.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(47):  # '/'
            raise Error(
                "telemetry keys: " + what + " segment '" + seg + "' contains"
                " '/' — key DEPTH is a constant (see keys.mojo rule 3); a"
                " nested segment silently changes what a single-level LIST"
                " returns, and the two object-store conformers disagree about"
                " which direction it breaks in"
            )


def _zero_pad(v: Int64, width: Int) raises -> String:
    """Left-zero-pad a NON-NEGATIVE integer to `width` digits."""
    if v < Int64(0):
        raise Error(
            "telemetry keys: cannot zero-pad the negative value "
            + String(v)
            + " — a negative start_ms would sort AFTER every positive one and"
            " break the time-ordered basename"
        )
    var s = String(v)
    var n = s.byte_length()
    if n >= width:
        return s^
    var out = String("")
    var k = width - n
    while k > 0:
        out += "0"
        k -= 1
    out += s
    return out^


comptime _HEX_DIGITS: String = "0123456789abcdef"


def uuid_hex(u: InlineArray[UInt8, 16]) -> String:
    """Lowercase 32-hex-char rendering of a 16-byte segment uuid. Fixed width,
    so the basename `<start_ms:020d>-<uuid>` is fixed width and therefore
    lexicographically time-ordered."""
    var hb = _HEX_DIGITS.as_bytes()
    var out = String("")
    for i in range(16):
        var c = Int(u[i])
        out += chr(Int(hb[(c >> 4) & 0xF]))
        out += chr(Int(hb[c & 0xF]))
    return out^


# =============================================================================
# §3 — the day partition. PURE ARITHMETIC — no I/O, ever.
# =============================================================================


def _floor_div_i64(a: Int64, b: Int64) -> Int64:
    """FLOOR division, written out rather than assumed.

    Mojo's `//` truncation-vs-floor behaviour for negative operands is exactly
    what the `z - 146096` adjustment in `civil_from_day_index` hedges against. A day index computed with the wrong rounding puts a
    pre-epoch timestamp in the day AFTER the one it belongs to — a partition
    whose entries do not satisfy its own [min,max] contract. Written out, it is
    correct under either semantics."""
    var q = a // b
    var r = a - q * b
    if r != Int64(0) and ((r < Int64(0)) != (b < Int64(0))):
        q -= Int64(1)
    return q


def day_index_from_ns(ts_ns: Int64) -> Int64:
    """UTC days since 1970-01-01 for an epoch-nanosecond timestamp."""
    return _floor_div_i64(ts_ns, NS_PER_DAY)


def day_start_ns(day_index: Int64) -> Int64:
    """The first nanosecond of a day partition (its inclusive lower bound)."""
    return day_index * NS_PER_DAY


def day_end_ns(day_index: Int64) -> Int64:
    """The LAST nanosecond of a day partition (its inclusive upper bound)."""
    return day_index * NS_PER_DAY + (NS_PER_DAY - Int64(1))


@fieldwise_init
struct Civil(Copyable, Movable, Deinitable):
    """A civil UTC date — the result of `civil_from_day_index`."""

    var year: Int
    var month: Int
    var day: Int


def civil_from_day_index(z_in: Int64) -> Civil:
    """Days since 1970-01-01 -> (year, month, day). Howard Hinnant's
    `civil_from_days`, proleptic Gregorian.

    Implemented here rather than imported from a calendar package: this
    package's dependency surface stays Arrow, object store and Parquet, and
    pulling a calendar package in for twelve lines of integer arithmetic is not
    worth it. Pinned against the inverse
    (`day_index_from_civil`) and against hand-computed dates by
    `tests/test_telemetry_keys.mojo`."""
    var z = Int(z_in) + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    var year = y + 1 if m <= 2 else y
    return Civil(year, m, d)


def day_index_from_civil(y: Int, m: Int, d: Int) -> Int64:
    """(year, month, day) -> days since 1970-01-01. The inverse of
    `civil_from_day_index` (Hinnant `days_from_civil`)."""
    var yy = y - 1 if m <= 2 else y
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return Int64(era * 146097 + doe - 719468)


def day_string_from_day_index(day_index: Int64) raises -> String:
    """`YYYYMMDD` for a day index. Fixed width, so day prefixes sort in time
    order and a reader can compare them as strings."""
    var c = civil_from_day_index(day_index)
    if c.year < 0 or c.year > 9999:
        raise Error(
            "telemetry keys: year " + String(c.year) + " is outside the"
            " 4-digit YYYYMMDD partition vocabulary — the timestamp is corrupt,"
            " and a wrapped year string would silently merge two partitions"
        )
    return (
        _zero_pad(Int64(c.year), 4)
        + _zero_pad(Int64(c.month), 2)
        + _zero_pad(Int64(c.day), 2)
    )


def day_string_from_ns(ts_ns: Int64) raises -> String:
    """`YYYYMMDD` for an epoch-nanosecond timestamp. THE partition function."""
    return day_string_from_day_index(day_index_from_ns(ts_ns))


def days_covering(t0_ns: Int64, t1_ns: Int64) raises -> List[String]:
    """THE READ-PATH PREFIX GENERATOR: every `YYYYMMDD` partition a closed range
    `[t0_ns, t1_ns]` touches, ascending. PURE ARITHMETIC — ZERO I/O.

    This is the function that makes "discovery by manifest replay, never by
    listing" possible at all: with the day in the key, the set of partitions a
    query must consider is COMPUTED, so the bucket is never asked what exists."""
    if t1_ns < t0_ns:
        raise Error(
            "telemetry keys: days_covering called with t1 < t0 ("
            + String(t1_ns)
            + " < "
            + String(t0_ns)
            + ") — an inverted range would silently return zero partitions,"
            " which is indistinguishable from 'no data'"
        )
    var d0 = day_index_from_ns(t0_ns)
    var d1 = day_index_from_ns(t1_ns)
    var span = Int(d1 - d0) + 1
    if span > MAX_TELEMETRY_DAYS_PER_QUERY:
        raise Error(
            "telemetry keys: range spans "
            + String(span)
            + " day partitions, over the "
            + String(MAX_TELEMETRY_DAYS_PER_QUERY)
            + " ceiling — refused rather than turned into that many exact GETs"
        )
    var out = List[String](capacity=span)
    var d = d0
    while d <= d1:
        out.append(day_string_from_day_index(d))
        d += Int64(1)
    return out^


# =============================================================================
# §4 — the keys themselves.
# =============================================================================


def telemetry_partition_prefix(
    root: String, dataset: String, day: String
) raises -> String:
    """`<root>/<ds>/<YYYYMMDD>` — the partition prefix. Also the
    `index_meta_prefix` the CAS sub-lineage builders hang off, so a partition's
    manifests and its data objects share one computed parent."""
    _check_segment(root, "root")
    _check_segment(dataset, "dataset")
    _check_segment(day, "day")
    return root + "/" + dataset + "/" + day


def telemetry_data_key(
    root: String,
    dataset: String,
    day: String,
    start_ms: Int64,
    segment_uuid: InlineArray[UInt8, 16],
) raises -> String:
    """The BASE artifact's key. `<start_ms:020d>` first so a single-level LIST of
    `…/data/` comes back in time order on both conformers."""
    var basename = (
        _zero_pad(start_ms, TELEMETRY_START_MS_WIDTH)
        + "-"
        + uuid_hex(segment_uuid)
        + TELEMETRY_DATA_SUFFIX
    )
    return (
        telemetry_partition_prefix(root, dataset, day)
        + "/"
        + TELEMETRY_DATA_SEGMENT
        + "/"
        + basename
    )


def telemetry_text_sidecar_key(data_key: String) raises -> String:
    """THE SIDECAR'S KEY IS DERIVED FROM THE BASE'S, NEVER DISCOVERED.

    One sidecar per data object, same basename: no independent lifecycle, no
    separate manifest, no listing to pair them, because the name is derivable.
    This function IS that derivation, and it is the reason the text split can
    be a sidecar without adding a second manifest or a second discovery LIST.

    Fail-loud on a key this module did not produce: a sidecar key computed off a
    foreign key would name an object that does not exist, and a not-found on the
    sidecar path is easy to fold to 'no matches' — a silent wrong answer."""
    var suffix_len = TELEMETRY_DATA_SUFFIX.byte_length()
    var n = data_key.byte_length()
    if n <= suffix_len:
        raise Error(
            "telemetry keys: '" + data_key + "' is not a telemetry data key"
        )
    var kb = data_key.as_bytes()
    var sb = TELEMETRY_DATA_SUFFIX.as_bytes()
    for i in range(suffix_len):
        if kb[n - suffix_len + i] != sb[i]:
            raise Error(
                "telemetry keys: '"
                + data_key
                + "' does not end in "
                + TELEMETRY_DATA_SUFFIX
                + " — refusing to derive a sidecar key from a foreign key"
            )
    # The `/data/` segment, located STRUCTURALLY (the second-to-last segment),
    # never by a substring replace: a `/data/` occurring inside a root or a
    # dataset name would otherwise be rewritten instead of the real one.
    var marker = String("/") + TELEMETRY_DATA_SEGMENT + "/"
    var mlen = marker.byte_length()
    var mb = marker.as_bytes()
    var cut = -1
    var j = n - suffix_len - 1
    while j >= 0:
        if kb[j] == UInt8(47):  # '/' — the basename's own separator
            if j + 1 >= mlen:
                var start = j + 1 - mlen
                var hit = True
                for t in range(mlen):
                    if kb[start + t] != mb[t]:
                        hit = False
                        break
                if hit:
                    cut = start
            break
        j -= 1
    if cut < 0:
        raise Error(
            "telemetry keys: '"
            + data_key
            + "' has no '"
            + marker
            + "' parent segment — refusing to derive a sidecar key from a"
            " foreign key"
        )
    var head = String(StringSlice(unsafe_from_utf8=Span(kb[0:cut])))
    var base = String(
        StringSlice(unsafe_from_utf8=Span(kb[cut + mlen : n - suffix_len]))
    )
    return (
        head
        + "/"
        + TELEMETRY_TEXT_SEGMENT
        + "/"
        + base
        + TELEMETRY_TEXT_SUFFIX
    )


def telemetry_key_depth(key: String) -> Int:
    """Number of '/'-separated segments in `key`. Rule 3's observable: a test
    asserts this equals `TELEMETRY_DATA_KEY_DEPTH` for every produced key, so a
    future segment added to the layout goes RED instead of silently changing
    what a single-level LIST returns."""
    if key.byte_length() == 0:
        return 0
    var b = key.as_bytes()
    var n = 1
    for i in range(len(b)):
        if b[i] == UInt8(47):
            n += 1
    return n
