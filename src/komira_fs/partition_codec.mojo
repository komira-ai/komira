# =============================================================================
# komira_fs.partition_codec — Hive partition value encode/parse
# round-trip helper + key=value path parse + type-probe.
# =============================================================================
#
# THE CRITICAL MODULE. The `encode` that splices
# a constant into a list prefix and the `parse` that
# reads a `key=value` path segment back into a partition value
# MUST be a single shared helper pair that ROUND-TRIPS exactly. A one-byte
# disagreement (URL-escape rule, date/timestamp format, the null sentinel)
# builds a prefix that matches NOTHING on disk -> the query SILENTLY returns
# zero rows, with no error and no diagnostic. This is the nastiest failure
# mode in the whole feature; the round-trip unit test across the full type
# matrix is the safety net.
#
# What this module owns (the inverse pair + the parse primitives):
#   * `encode_partition_value(value, arrow_type) -> String`
#       path-segment form: URL-escape the unsafe bytes, canonical date/ts/int
#       formatting, the `__HIVE_DEFAULT_PARTITION__` NULL sentinel.
#   * `parse_partition_value(segment, arrow_type) -> String`
#       the EXACT inverse: URL-unescape, the null sentinel back to "" (the
#       NULL marker), pass-through of canonical numeric/date text.
#   * `partition_value_spellings(value, arrow_type) -> List[String]`
#       read side only: the distinct directory spellings to list for a value
#       (komira, Spark, DuckDB/pyarrow, Windows Spark), and
#       `partition_value_spelling_for(value, arrow_type, writer)` for one.
#   * `parse_key_value_segments(path) -> (keys, values)`
#       split a discovered path's directory components into the ordered
#       `(partition_col_name, value_string)` pairs, disqualifying
#       non-conforming segments (no `=`, double-`=`, `?` / newline).
#   * type-probe + schema inference: DATE32 -> TIMESTAMP -> INT64 ->
#       VARCHAR per DuckDB's candidate order; conflict falls to VARCHAR.
#
# Pointer discipline:
#   * NO UnsafePointer anywhere — pure String/byte/List logic.
#   * safe across destroy-recreate by construction: every function is pure (no struct fields,
#     no byte-slab storage, no wildcard origins).
#
# NULL-SENTINEL NOTE: a Hive NULL partition value is encoded on-disk as the
# literal directory `key=__HIVE_DEFAULT_PARTITION__` (DuckDB compatibility).
# In our string-typed value model the canonical NULL is the EMPTY string `""`
# (a real empty partition value is indistinguishable on disk and is also NULL
# under Hive semantics). So:  encode("")  -> "__HIVE_DEFAULT_PARTITION__"  and
# parse("__HIVE_DEFAULT_PARTITION__") -> "".  The round-trip holds both ways.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field


# =============================================================================
# constants.
# =============================================================================

comptime HIVE_DEFAULT_PARTITION: String = "__HIVE_DEFAULT_PARTITION__"


# =============================================================================
# URL-escape / unescape (the path-segment-safe byte transform).
# =============================================================================
# A Hive partition value lands in a single `/`-delimited path segment, so any
# byte that would break path-segment parsing — `/`, `=`, `%`, control chars,
# and the bytes DuckDB/Hive percent-escape — must be `%XX`-escaped. We use the
# RFC-3986 "unreserved" set as the SAFE set (ALPHA / DIGIT / `-` `_` `.` `~`)
# PLUS the partition-friendly `:` and ` ` -> we escape SPACE too for safety,
# but KEEP `-` and `.` and `:` unescaped so the common Date and
# Timestamp shapes stay human-readable and match the
# on-disk DuckDB/Spark layout (which does NOT escape `-`/`:`/space-as-`%20`...
# actually Spark escapes space; we escape space as %20 to be safe and match
# the inverse). The inverse `_url_unescape` reverses ANY `%XX`.
# =============================================================================


@always_inline
def _is_unreserved(b: UInt8) -> Bool:
    """RFC-3986 unreserved byte set, EXTENDED with the partition-canonical
    punctuation we deliberately keep human-readable on disk (`-` `_` `.` `~`
    `:`). Everything else (`/`, `=`, `%`, space, control, high bytes) is
    `%XX`-escaped by `_url_escape`."""
    # ALPHA
    if (b >= UInt8(ord("A")) and b <= UInt8(ord("Z"))) or (b >= UInt8(ord("a")) and b <= UInt8(ord("z"))):
        return True
    # DIGIT
    if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
        return True
    # unreserved punctuation + the date/timestamp-canonical `:`.
    if (
        b == UInt8(ord("-"))
        or b == UInt8(ord("_"))
        or b == UInt8(ord("."))
        or b == UInt8(ord("~"))
        or b == UInt8(ord(":"))
    ):
        return True
    return False


@always_inline
def _hex_digit(nibble: Int) -> String:
    """A single UPPERCASE hex digit for a 0..15 nibble (RFC-3986 uses upper)."""
    if nibble < 10:
        return chr(ord("0") + nibble)
    return chr(ord("A") + (nibble - 10))


def _url_escape(value: String) -> String:
    """`%XX`-escape every byte not in the unreserved set. The exact
    inverse of `_url_unescape`."""
    var bs = value.as_bytes()
    var out = String("")
    for i in range(len(bs)):
        var b = bs[i]
        if _is_unreserved(b):
            # SAFE: `_is_unreserved` is True only for ASCII alnum + `-_.~:`,
            # so `b < 0x80` here and `chr(Int(b))` is the IDENTITY. This is a
            # genuine code-point conversion, NOT the byte-decode defect fixed
            # at the other four sites in this file on do not
            # "fix" it, and do not COPY it to a site whose byte is unbounded.
            out += chr(Int(b))
        else:
            out += "%"
            out += _hex_digit(Int(b) >> 4)
            out += _hex_digit(Int(b) & 0xF)
    return out^


@always_inline
def _hex_value(b: UInt8) -> Int:
    """The 0..15 value of an ASCII hex digit, or -1 if `b` is not hex."""
    if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
        return Int(b) - ord("0")
    if b >= UInt8(ord("A")) and b <= UInt8(ord("F")):
        return Int(b) - ord("A") + 10
    if b >= UInt8(ord("a")) and b <= UInt8(ord("f")):
        return Int(b) - ord("a") + 10
    return -1


def _url_unescape(segment: String) raises -> String:
    """Reverse `_url_escape`: every `%XX` -> the byte `0xXX`; everything else
    passes through. A malformed `%` (not followed by two hex digits) RAISES
    (Fail Fast & Loud — a corrupt path segment is a real error, not a value)."""
    var bs = segment.as_bytes()
    # ⛔ ACCUMULATE BYTES, NOT `chr(...)`. Until 2026-09-07 this built a String
    # with `out += chr((hi << 4) | lo)` and `out += chr(Int(b))`, and `chr`
    # maps a CODE POINT to its UTF-8 ENCODING — so every unescaped byte >= 0x80
    # was RE-ENCODED into two. `encode_partition_value("Zürich")` produces
    # `Z%C3%BCrich`; this function turned it back into `ZÃ¼rich`, i.e. the
    # MANDATED INVERSE PAIR (the HARD-FAIL GATE this module's
    # header describes) did NOT round-trip for any non-ASCII value. The header
    # states the consequence exactly: a one-byte disagreement builds a prefix
    # that matches NOTHING on disk and the query SILENTLY returns zero rows.
    # ASCII is the corruption's fixed point, so the all-ASCII round-trip
    # matrix passed over it.
    var out = List[UInt8]()
    var i = 0
    var n = len(bs)
    while i < n:
        var b = bs[i]
        if b == UInt8(ord("%")):
            if i + 2 >= n:
                raise Error(
                    String(
                        "partition_codec: truncated %-escape in path segment '"
                    )
                    + segment
                    + "'"
                )
            var hi = _hex_value(bs[i + 1])
            var lo = _hex_value(bs[i + 2])
            if hi < 0 or lo < 0:
                raise Error(
                    String(
                        "partition_codec: malformed %-escape in path segment '"
                    )
                    + segment
                    + "'"
                )
            out.append(UInt8((hi << 4) | lo))
            i += 3
        else:
            out.append(b)
            i += 1
    # LENGTH-EXPLICIT byte-exact materialization — the in-tree spelling
    # (`komira_arrow/string_column_view.mojo:145`); NOT
    # `String(unsafe_from_utf8_ptr=)`, which stops at the first NUL.
    return String(StringSlice(unsafe_from_utf8=Span(out)))


# =============================================================================
# encode_partition_value / parse_partition_value (the MANDATED inverse
#       pair —).
# =============================================================================


def encode_partition_value(value: String, arrow_type: ArrowType) -> String:
    """Encode a partition `value` (as the engine's canonical string form) into
    its on-disk path-SEGMENT form, ready to splice into a `key=...` list
    prefix. The EXACT inverse of `parse_partition_value`.

    Contract:
      * The canonical NULL value (the empty string) -> the literal
        `__HIVE_DEFAULT_PARTITION__` sentinel (DuckDB compatibility).
      * Any other value -> `_url_escape`d (path-segment-safe).

    The `arrow_type` is carried for API symmetry with `parse` and for the
    type matrix the round-trip test exercises; numeric / date / timestamp
    values are already in their canonical text form (e.g. `2026-11-04`,
    `1793750400`, `2026-11-04 03:00:00`) by the time they reach here, so the
    encoding is the same `_url_escape` for all types — the type only governs
    what the CANONICAL text IS, which the caller produced. (A `Date` is
    `YYYY-MM-DD`; a `Timestamp` is `YYYY-MM-DD HH:MM:SS`; an `Int` is its
    decimal digits.) Keeping one escape rule for all types is exactly what
    makes the inverse total and round-trip-clean.
    """
    if value.byte_length() == 0:
        return HIVE_DEFAULT_PARTITION
    return _url_escape(value)


def parse_partition_value(segment: String, arrow_type: ArrowType) raises -> String:
    """Parse a partition path SEGMENT-value back into the engine's canonical
    string form. The EXACT inverse of `encode_partition_value`.

    Contract:
      * The literal `__HIVE_DEFAULT_PARTITION__` sentinel -> the canonical NULL
        value (the empty string).
      * Any other segment -> `_url_unescape`d.

    Raises on a malformed `%`-escape.
    """
    if segment == HIVE_DEFAULT_PARTITION:
        return String("")
    return _url_unescape(segment)


# =============================================================================
# The directory spellings other writers use (read side only).
# =============================================================================
# `encode_partition_value` is komira's WRITE spelling and stays as it is. Other
# writers spell a partition VALUE differently in the `key=value` directory.
# Each rule below is from the writer's source; each escapes a byte as `%XX`
# with UPPERCASE hex and copies every other byte verbatim:
#
#   KOMIRA (`encode_partition_value`): escapes everything except ASCII
#     letters, digits and `- _ . ~ :`.
#
#   SPARK (POSIX). `ExternalCatalogUtils.escapePathName`
#     (sql/catalyst/src/main/scala/org/apache/spark/sql/catalyst/catalog/
#     ExternalCatalogUtils.scala, `charToEscape`, itself taken from Hive's
#     `FileUtils.escapePathName`) escapes ONLY
#         0x01-0x1F   "  #  %  '  *  /  :  =  ?  \  0x7F  {  [  ]  ^
#     and writes every other char raw, including every char >= 0x80. Applied
#     to the key too (`getPartitionPathString`). `Zürich` -> `Zürich`.
#
#   SPARK (Windows). The same `charToEscape` adds space `<` `>` `|` when
#     `Shell.WINDOWS`. `Zürich Nord` -> `Zürich%20Nord`.
#
#   URI: DuckDB and pyarrow, which share one rule.
#     * DuckDB: `HivePartitioning::EscapeValue` (src/common/
#       hive_partitioning.cpp) -> `StringUtil::URLEncode` (src/common/
#       string_util.cpp, `URLEncodeInternal`, `encode_slash` defaults true)
#       keeps ASCII letters, digits and `_ - ~ .`, escapes everything else.
#       The key is escaped the same way (`HivePartitioning::Escape`, in
#       physical_copy_to_file.cpp).
#     * pyarrow / Arrow C++: `HivePartitioning::FormatValues`
#       (cpp/src/arrow/dataset/partition.cc) -> `arrow::util::UriEscape`
#       (cpp/src/arrow/util/uri.cc) -> uriparser `uriEscapeExA` with
#       spaceToPlus and normalizeBreaks false (src/UriEscape.c): keeps the
#       RFC 3986 unreserved set (ASCII letters, digits, `- . _ ~`), escapes
#       everything else. The key is NOT escaped.
#     This differs from KOMIRA only on `:`: `03:00` -> `03%3A00`.
#
# The rules are ASCII-only, so escaping per BYTE is identical to the
# writers' per-char rules: every UTF-8 byte of a non-ASCII char is >= 0x80.
#
# Edge cases deliberately NOT reproduced (documented, not listed):
#   * 0x00 is escaped in every spelling here. Spark writes it raw and
#     uriparser stops at it, but a NUL cannot occur in a path name and a raw
#     NUL handed to a C-string FS boundary would truncate the prefix.
#   * DuckDB writes a non-NULL value equal (case-insensitively) to
#     `__HIVE_DEFAULT_PARTITION__` with its first byte escaped (`%5F_HIVE...`).
#     komira cannot express that value as distinct from NULL today.
#   * Keys are used as given; a key that one of the writers escapes (any
#     byte outside its keep-set) is not expanded.
#
# The reader lists every distinct spelling (`partition_value_spellings`);
# `parse_partition_value` decodes each one to the same canonical value.
# =============================================================================

# The writers, in the order `partition_value_spellings` lists them.
# komira's own spelling: `encode_partition_value`.
comptime HIVE_WRITER_KOMIRA: Int = 0
# Spark / Hive `escapePathName` on a POSIX host.
comptime HIVE_WRITER_SPARK: Int = 1
# DuckDB `URLEncode` and pyarrow `UriEscape` (RFC 3986 unreserved kept).
comptime HIVE_WRITER_URI: Int = 2
# Spark / Hive `escapePathName` on Windows (adds space `<` `>` `|`).
comptime HIVE_WRITER_SPARK_WINDOWS: Int = 3
comptime HIVE_WRITER_COUNT: Int = 4


@always_inline
def _spark_escapes_byte(b: UInt8) -> Bool:
    """True iff Spark's POSIX `escapePathName` %-escapes byte `b` (plus 0x00,
    see the section header)."""
    if b <= 0x1F or b == 0x7F:
        return True
    return (
        b == UInt8(ord('"'))
        or b == UInt8(ord("#"))
        or b == UInt8(ord("%"))
        or b == UInt8(ord("'"))
        or b == UInt8(ord("*"))
        or b == UInt8(ord("/"))
        or b == UInt8(ord(":"))
        or b == UInt8(ord("="))
        or b == UInt8(ord("?"))
        or b == UInt8(ord("\\"))
        or b == UInt8(ord("{"))
        or b == UInt8(ord("["))
        or b == UInt8(ord("]"))
        or b == UInt8(ord("^"))
    )


@always_inline
def _spark_windows_escapes_byte(b: UInt8) -> Bool:
    """Spark's set plus the `Shell.WINDOWS` additions: space `<` `>` `|`."""
    return (
        _spark_escapes_byte(b)
        or b == UInt8(ord(" "))
        or b == UInt8(ord("<"))
        or b == UInt8(ord(">"))
        or b == UInt8(ord("|"))
    )


@always_inline
def _uri_escapes_byte(b: UInt8) -> Bool:
    """True iff DuckDB `URLEncode` / uriparser `uriEscapeExA` escape `b`:
    everything outside ASCII letters, digits and `- _ . ~`."""
    if (b >= UInt8(ord("A")) and b <= UInt8(ord("Z"))) or (
        b >= UInt8(ord("a")) and b <= UInt8(ord("z"))
    ):
        return False
    if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
        return False
    return not (
        b == UInt8(ord("-"))
        or b == UInt8(ord("_"))
        or b == UInt8(ord("."))
        or b == UInt8(ord("~"))
    )


@always_inline
def _writer_escapes_byte(writer: Int, b: UInt8) -> Bool:
    if writer == HIVE_WRITER_SPARK:
        return _spark_escapes_byte(b)
    if writer == HIVE_WRITER_SPARK_WINDOWS:
        return _spark_windows_escapes_byte(b)
    if writer == HIVE_WRITER_URI:
        return _uri_escapes_byte(b)
    return not _is_unreserved(b)  # HIVE_WRITER_KOMIRA


@always_inline
def _hex_digit_byte(nibble: Int) -> UInt8:
    """The UPPERCASE ASCII hex digit byte for a 0..15 nibble."""
    if nibble < 10:
        return UInt8(ord("0") + nibble)
    return UInt8(ord("A") + (nibble - 10))


def _escape_for_writer(value: String, writer: Int) -> String:
    """`value` with the bytes `writer` escapes as `%XX` (uppercase hex) and
    every other byte copied verbatim. Accumulates BYTES (a `chr()` per byte
    would re-encode each byte >= 0x80 into two; see `_url_unescape`)."""
    var bs = value.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bs)):
        var b = bs[i]
        if _writer_escapes_byte(writer, b):
            out.append(UInt8(ord("%")))
            out.append(_hex_digit_byte(Int(b) >> 4))
            out.append(_hex_digit_byte(Int(b) & 0xF))
        else:
            out.append(b)
    # Byte-exact, length-explicit materialization (as in `_url_unescape`).
    # The input was a valid String and only ASCII bytes were replaced by
    # ASCII, so the output is valid UTF-8.
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def partition_value_spelling_for(
    value: String, arrow_type: ArrowType, writer: Int
) -> String:
    """The directory spelling `writer` (a `HIVE_WRITER_*` constant) gives
    `value`. The NULL value (the empty string) is `__HIVE_DEFAULT_PARTITION__`
    for every writer. `HIVE_WRITER_KOMIRA` is `encode_partition_value`."""
    if writer == HIVE_WRITER_KOMIRA or value.byte_length() == 0:
        return encode_partition_value(value, arrow_type)
    return _escape_for_writer(value, writer)


def partition_value_spellings(value: String, arrow_type: ArrowType) -> List[String]:
    """The on-disk directory spellings a READER must try for `value`: one per
    writer in `HIVE_WRITER_*` order (komira, Spark, DuckDB/pyarrow, Windows
    Spark), each kept only if no earlier writer produced the same bytes. So
    1 to 4 elements, komira's spelling always first; values made of ASCII
    letters, digits and `- _ . ~`, and NULL, have exactly one.

    Writers keep using `encode_partition_value`; this function is for
    building list prefixes.
    """
    var out = List[String]()
    for w in range(HIVE_WRITER_COUNT):
        var s = partition_value_spelling_for(value, arrow_type, w)
        var seen = False
        for i in range(len(out)):
            if out[i] == s:
                seen = True
                break
        if not seen:
            out.append(s^)
    return out^


# =============================================================================
# key=value path parse, built on parse_partition_value.
# =============================================================================
# Split a discovered path into its ordered `(partition_col_name, value)`
# pairs. DISQUALIFY a non-conforming directory component (no `=`, double-`=`,
# `?` / newline / control). The final `/`-component (the file name itself) is
# NEVER a partition directory.
# =============================================================================


@always_inline
def _segment_has_disqualifying_byte(comp: String) -> Bool:
    """True if `comp` contains a byte that disqualifies it from being a Hive
    `key=value` partition directory: `?` (glob residual that escaped), a
    newline / carriage-return, or any other ASCII control byte. (`=` count is
    checked separately by the caller — exactly one `=` is required.)"""
    var bs = comp.as_bytes()
    for i in range(len(bs)):
        var b = bs[i]
        if b == UInt8(ord("?")):
            return True
        if b < 0x20:  # ASCII control (incl. \n=0x0A, \r=0x0D, \t=0x09)
            return True
    return False


def _kv_split(comp: String, mut out_key: String, mut out_value: String) -> Bool:
    """If `comp` is exactly `<key>=<value>` with EXACTLY one `=`, a non-empty
    key, and no disqualifying byte, write key/value and return True. Else
    return False (a plain directory component, not a partition component).

    The `<value>` is left in its raw on-disk SEGMENT form here (still
    `%`-escaped); the caller runs `parse_partition_value` to decode it once
    the column type is known. (Splitting and decoding are separated because
    type inference — — must see the RAW segment text to type-probe before
    the canonical decode.)"""
    if _segment_has_disqualifying_byte(comp):
        return False
    var bs = comp.as_bytes()
    var eq_pos = -1
    var eq_count = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("=")):
            eq_count += 1
            if eq_pos < 0:
                eq_pos = i
    if eq_count != 1:
        return False  # no `=`, or double-`=` (disqualified)
    if eq_pos == 0:
        return False  # empty key
    # BYTE-EXACT split. ⛔ NOT `key += chr(Int(bs[i]))` — that was this body
    # until 2026-09-07 and it RE-ENCODED every byte >= 0x80 into two, so a raw
    # (unescaped) non-ASCII partition directory — which Spark/Hive write and
    # `_segment_has_disqualifying_byte` deliberately does NOT reject, since it
    # only screens `?` and bytes < 0x20 — was mojibaked before
    # `parse_partition_value` ever saw it. This is the LAZY (pruned-hive) arm's
    # counterpart to `hive_partition_parser._parse_kv_component`, whose
    # identical defect was fixed the same day.
    out_key = String(StringSlice(unsafe_from_utf8=bs[0:eq_pos]))
    out_value = String(StringSlice(unsafe_from_utf8=bs[eq_pos + 1 : len(bs)]))
    return True


def parse_key_value_segments(
    path: String, mut out_keys: List[String], mut out_values: List[String]
):
    """Parse `path`'s directory components into ordered `(key, value)`
    partition pairs. Values are the RAW on-disk segment text (still
    `%`-escaped) — the caller decodes via `parse_partition_value` once the
    column type is known.

    The LAST `/`-component (the file name) is never a partition directory.
    Leading-`/` empty components are skipped. Non-conforming components
    (no `=`, double-`=`, `?`/control byte) are silently skipped (they are
    plain directories, not partitions — DuckDB does the same).

    Clears `out_keys` / `out_values` before populating.
    """
    out_keys.clear()
    out_values.clear()
    var comps = List[String]()
    for s in path.split("/"):
        comps.append(String(s))
    var n = len(comps)
    if n <= 1:
        return
    for i in range(n - 1):  # strictly before the final (file name) component
        ref comp = comps[i]
        if comp.byte_length() == 0:
            continue
        var k = String("")
        var v = String("")
        if _kv_split(comp, k, v):
            out_keys.append(k^)
            out_values.append(v^)


# =============================================================================
# type-probe + schema inference.
# =============================================================================
# Probe a partition column's values DATE32 -> TIMESTAMP -> INT64 -> VARCHAR
# (DuckDB candidate order, extended with TIMESTAMP). The probe runs on the
# DECODED canonical value text (post-`parse_partition_value`), since the
# `__HIVE_DEFAULT_PARTITION__` NULL sentinel decodes to "" and an all-"" /
# mixed column should not type-probe as an int/date.
# =============================================================================


def _value_parses_as_int(v: String) -> Bool:
    """True iff `v` is a non-empty optionally-signed run of ASCII digits that
    conservatively fits Int64 (<= 18 digits). Empty -> not an int (it is the
    NULL marker / a string)."""
    var bs = v.as_bytes()
    if len(bs) == 0:
        return False
    var start = 0
    if bs[0] == UInt8(ord("-")) or bs[0] == UInt8(ord("+")):
        if len(bs) == 1:
            return False
        start = 1
    for i in range(start, len(bs)):
        if bs[i] < UInt8(ord("0")) or bs[i] > UInt8(ord("9")):
            return False
    if len(bs) - start > 18:
        return False
    return True


def _days_in_month(yyyy: Int, mm: Int) -> Int:
    """The number of days of month `mm` (1..12) of year `yyyy` in the
    proleptic Gregorian calendar: February has 29 days in a year divisible
    by 4 and not by 100, or divisible by 400."""
    if mm == 2:
        var leap = (yyyy % 4 == 0 and yyyy % 100 != 0) or yyyy % 400 == 0
        return 29 if leap else 28
    if mm == 4 or mm == 6 or mm == 9 or mm == 11:
        return 30
    return 31


def _date_digits_are_calendar_date(v: String) -> Bool:
    """True iff the digit bytes at `YYYY-MM-DD` positions 0..9 of `v` (shape
    already checked by the caller) name a real calendar date: month 1..12 and
    day 1 up to that month's last day."""
    var bs = v.as_bytes()
    var yyyy = 0
    for i in range(4):
        yyyy = yyyy * 10 + (Int(bs[i]) - ord("0"))
    var mm = (Int(bs[5]) - ord("0")) * 10 + (Int(bs[6]) - ord("0"))
    var dd = (Int(bs[8]) - ord("0")) * 10 + (Int(bs[9]) - ord("0"))
    if mm < 1 or mm > 12:
        return False
    return dd >= 1 and dd <= _days_in_month(yyyy, mm)


def _value_parses_as_date32(v: String) -> Bool:
    """True iff `v` matches strict `YYYY-MM-DD` and names a real calendar
    date (a day past its month's last day, such as 2027-02-29, is not)."""
    var bs = v.as_bytes()
    if len(bs) != 10:
        return False
    for i in range(10):
        if i == 4 or i == 7:
            if bs[i] != UInt8(ord("-")):
                return False
        else:
            if bs[i] < UInt8(ord("0")) or bs[i] > UInt8(ord("9")):
                return False
    return _date_digits_are_calendar_date(v)


def _value_parses_as_timestamp(v: String) -> Bool:
    """True iff `v` matches `YYYY-MM-DD HH:MM:SS` (the canonical second-
    precision timestamp partition form). Date portion validated as in
    `_value_parses_as_date32`; time portion HH(00-23):MM(00-59):SS(00-59).
    (A `T` separator variant is intentionally NOT accepted in v1 — the
    canonical encode form uses a space; keeping the probe strict to the
    encode form keeps the round-trip total.)"""
    var bs = v.as_bytes()
    if len(bs) != 19:
        return False
    # date: positions 0..9 are YYYY-MM-DD
    for i in range(10):
        if i == 4 or i == 7:
            if bs[i] != UInt8(ord("-")):
                return False
        else:
            if bs[i] < UInt8(ord("0")) or bs[i] > UInt8(ord("9")):
                return False
    # separator: position 10 is a single space
    if bs[10] != UInt8(ord(" ")):
        return False
    # time: positions 11..18 are HH:MM:SS
    for i in range(11, 19):
        if i == 13 or i == 16:
            if bs[i] != UInt8(ord(":")):
                return False
        else:
            if bs[i] < UInt8(ord("0")) or bs[i] > UInt8(ord("9")):
                return False
    var hh = (Int(bs[11]) - ord("0")) * 10 + (Int(bs[12]) - ord("0"))
    var mi = (Int(bs[14]) - ord("0")) * 10 + (Int(bs[15]) - ord("0"))
    var ss = (Int(bs[17]) - ord("0")) * 10 + (Int(bs[18]) - ord("0"))
    if not _date_digits_are_calendar_date(v):
        return False
    if hh > 23 or mi > 59 or ss > 59:
        return False
    return True


def probe_partition_type(values: List[String]) -> ArrowType:
    """Infer the ArrowType of a partition column from its DECODED canonical
    value set, candidate order DATE32 -> TIMESTAMP -> INT64 -> VARCHAR.
    An empty value set, or any conflict, falls to STRING
    (VARCHAR). NULL markers (the empty string) DISQUALIFY the int/date/ts
    probes (an all-NULL / null-bearing column is a string)."""
    if len(values) == 0:
        return ArrowType.STRING
    var all_int = True
    var all_date = True
    var all_ts = True
    for i in range(len(values)):
        ref v = values[i]
        if not _value_parses_as_int(v):
            all_int = False
        if not _value_parses_as_date32(v):
            all_date = False
        if not _value_parses_as_timestamp(v):
            all_ts = False
        if not all_int and not all_date and not all_ts:
            break
    # Candidate order: DATE32 first (most specific 10-char shape), then
    # TIMESTAMP (19-char), then INT64 (digits), else STRING. A value cannot
    # be both a 10-char date AND a digit-run, so these are mutually exclusive
    # in practice; the order is the tie-break contract.
    if all_date:
        return ArrowType.DATE32
    if all_ts:
        return ArrowType.TIMESTAMP
    if all_int:
        return ArrowType.INT64
    return ArrowType.STRING
