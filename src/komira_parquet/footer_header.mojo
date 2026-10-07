# =============================================================================
# Light footer parses: num_rows and the schema, or num_rows alone
# =============================================================================
#
# `parse_full_metadata` (metadata_parser) builds every RowGroup, ColumnChunk
# and Statistics of a footer. The parses here stop early, for callers that
# need only the top of the footer: `parse_metadata_header_and_schema` returns
# `num_rows`, the flat schema and the `ARROW:schema` value;
# `parse_metadata_num_rows_only` returns `num_rows` alone. Both report how
# many footer bytes they examined.
# =============================================================================

from komira_parquet_api.metadata import SchemaElement
from .thrift_compact import ThriftCompactReader
from .metadata_parser import _parse_schema_element
from komira_buffer.byte_view import ByteView


# =============================================================================
# Light header+schema parser
# =============================================================================
#
# A caller that builds a table's schema and row count (a query planner
# binding a Parquet file) needs only two things from the footer: the total
# `num_rows` and the flat `SchemaElement` list (to build the Arrow
# `Schema`). It does NOT need any `RowGroup` / `ColumnChunk` /
# `ColumnMetaData` / `Statistics`. This light parser does not BUILD any of
# them, and skips the page index / column index / offset index.
#
# Skipping `row_groups` is NOT cheap: Thrift Compact Protocol has no length
# prefix for a struct or a list-of-structs, so `_skip_field(wire_type=9)`
# (`thrift_compact.mojo`) can find the end of `row_groups` only by
# re-reading EVERY nested field header of every RowGroup, ColumnChunk,
# ColumnMetaData and Statistics inside it. It decodes no VALUES, but it is
# O(entire blob) in field headers, never O(1). In a typical footer
# `row_groups` is nearly all of the bytes, and `schema` and `num_rows` come
# before it.
#
# So the loop below BREAKS once both `schema` and `num_rows` are in hand.
# Safe by construction — Thrift field ids are unique, so no later field can
# change either value — and it degrades to the full walk (no regression,
# just no win) if a writer emits `row_groups` BEFORE them. The `early_exit`
# argument (default on) turns the break off, for comparing the two walks.
# Cost: O(bytes up to and including the LAST of {schema, num_rows}).


struct ParquetHeaderAndSchema(Movable):
    """Minimal `(num_rows, schema_elements)` bundle from a light footer
    parse — the FileMetaData header (`num_rows`) plus the flat
    `SchemaElement` list, stopping before `row_groups`. See module
    comment above.
    """

    var num_rows: Int
    var schema_elements: List[SchemaElement]
    var arrow_schema_value: String
    """The raw `ARROW:schema` footer value, or `""` when the file has none.

    This is Thrift field **5**, and the walk above stops at field 3. It is
    not reached by the loop; it is found by `find_arrow_schema_value`, a
    targeted backward byte search that never decodes a `row_groups` field
    header (reaching it with the Thrift walk would mean `_skip_field`-ing
    field 4, the walk the early break exists to avoid).

    Empty is the common and correct answer: most Parquet files are not
    written by pyarrow, and a file without the key must read back exactly
    as before. A caller that decodes the value takes `""`, and anything it
    cannot parse, as no hint."""
    var bytes_examined: Int
    """TOTAL footer byte-probes this parse paid — ACROSS EVERY READER IT
    BUILDS, not one reader's cursor. A byte visited twice counts twice.

    `bytes_consumed` is one reader's cursor and cannot see the
    `ARROW:schema` search, which builds its own reader over the same view.
    So every reader this function constructs adds its footprint to this
    number; a new pass that did not would be invisible to a byte budget."""
    var bytes_consumed: Int
    """Footer bytes the THRIFT WALK actually walked.

    This is one reader's cursor and NOT the parse's cost; read
    `bytes_examined` for that. It is the witness for the early `break`:
    walking the whole footer and walking its first few hundred bytes return
    identical `num_rows` and `schema_elements`, so how far the reader got is
    the only observable difference."""

    def __init__(
        out self,
        num_rows: Int,
        var schema_elements: List[SchemaElement],
        bytes_consumed: Int = -1,
        var arrow_schema_value: String = String(""),
        bytes_examined: Int = -1,
    ):
        self.num_rows = num_rows
        self.schema_elements = schema_elements^
        self.arrow_schema_value = arrow_schema_value^
        self.bytes_consumed = bytes_consumed
        self.bytes_examined = bytes_examined


# =============================================================================
# `ARROW:schema` WITHOUT WALKING `row_groups` — the field-5 problem
# =============================================================================
#
# In `FileMetaData` the key order is `2: schema`, `3: num_rows`,
# `4: row_groups`, `5: key_value_metadata` — so the ONE field that carries
# pyarrow's `ARROW:schema` sits AFTER the one field this parser exists to
# avoid. Thrift Compact has no length prefix for a struct or a
# list-of-structs, so a reader cannot jump over field 4.
#
# The route taken instead: the key is a LITERAL ASCII STRING in the footer
# bytes, and the footer bytes are already in memory. So find it by BYTE
# SEARCH and then hand only the bytes that follow to the real Thrift reader.
# No `row_groups` field header is ever decoded.
#
# The search runs BACKWARD: field 5 follows field 4, so the key lives in the
# footer's TAIL — after it come only `created_by` (field 6) and
# `column_orders` (field 7). A backward scan therefore stops after roughly
# `len(the base64 value) + 100` bytes WHEN THE KEY IS PRESENT. When it is
# ABSENT the scan is O(footer), which is why a caller that already holds a
# full parse reads `FileMetaData.key_value_metadata` instead.
#
# Why a byte search is safe here. A byte search for a 12-byte literal can in
# principle hit inside some other field's data. Three things make a false
# positive both unlikely and HARMLESS:
#   1. the byte BEFORE the key must be `0x0C` — Thrift Compact's varint
#      length for a 12-byte string, i.e. the key's own length prefix;
#   2. what FOLLOWS must parse as `KeyValue` field 2, wire type 8 (binary),
#      with a length the remaining footer can contain — checked by the real
#      `ThriftCompactReader`, not by hand;
#   3. a hit that survives both and is still not the key yields a STRING
#      that is not a base64 Arrow schema, which a decoder takes as no hint. The
#      failure mode of this whole path is "no hint", never a wrong type.
# The value itself is base64 (alphabet `[A-Za-z0-9+/=]`), so the literal
# cannot occur inside another `ARROW:schema` value.


comptime _ARROW_SCAN_SIMD_W = 32
"""Lanes in the `ARROW:schema` scan's needle-first pre-filter.

On the ABSENT arm the cost is about `1/W + P(window contains 'A')` probes
per byte, so the width trades loop overhead against how often a window
holds an 'A' and falls back to the scalar check. 32 lanes (two 128-bit NEON
ops on arm64, one AVX2 op on x86-64) measured faster than 16 on dense and
sparse footers alike.

'A' and not `0x0C` is the needle: the pattern requires `0x0C` at `p-1`
too, but that byte is a Thrift Compact varint length and so is common in a
footer, while 'A' is rare."""

comptime _ARROW_SCHEMA_KEY_LEN = 12
"""`len("ARROW:schema")`. Stated as a constant because it is BOTH the needle
length AND the byte the search demands one position earlier (Thrift Compact
encodes a 12-byte string's length as the single varint byte `0x0C`)."""


@always_inline
def _arrow_schema_key_byte(i: Int) -> UInt8:
    """Byte `i` of the literal `ARROW:schema`.

    Spelled as ordinals on purpose: comparing against a `String` would
    either allocate on every probe of the scan or reach for the string's
    raw pointer.
    """
    if i == 0:
        return UInt8(65)  # 'A'
    if i == 1:
        return UInt8(82)  # 'R'
    if i == 2:
        return UInt8(82)  # 'R'
    if i == 3:
        return UInt8(79)  # 'O'
    if i == 4:
        return UInt8(87)  # 'W'
    if i == 5:
        return UInt8(58)  # ':'
    if i == 6:
        return UInt8(115)  # 's'
    if i == 7:
        return UInt8(99)  # 'c'
    if i == 8:
        return UInt8(104)  # 'h'
    if i == 9:
        return UInt8(101)  # 'e'
    if i == 10:
        return UInt8(109)  # 'm'
    return UInt8(97)  # 'a'


def _arrow_schema_value_at[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin], key_end: Int) -> String:
    """Read the `KeyValue.value` that follows a key ending at `key_end`.

    Returns `""` — never raises — when the bytes there are not a Thrift
    Compact binary field 2, or when its length does not fit the footer. A
    malformed vendor extension is treated as an ABSENT one; it is not a
    corrupt file.
    """
    try:
        reader.pos = key_end
        # `KeyValue.key` is field 1, so the delta-encoded header that follows
        # it resolves against a previous field id of 1.
        reader.prev_field_id = 1
        var field = reader._read_field_header()
        if field[0] != 2 or field[1] != 8:
            return String("")
        var str_len = reader._read_varint()
        if str_len <= 0 or str_len > reader.data_len - reader.pos:
            return String("")
        # Same safe scalar byte-append idiom as `_parse_key_value` — no
        # wildcard-origin cast, no memcpy pointer laundering.
        var bytes = List[UInt8](capacity=str_len + 1)
        for i in range(str_len):
            bytes.append(reader.byte_at(reader.pos + i))
        bytes.append(0)
        return String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())
    except:
        return String("")


struct ArrowSchemaScan(Movable):
    """The `ARROW:schema` search's ANSWER together with WHAT IT COST.

    The cost is returned, not inferred: the search builds its own
    `ThriftCompactReader`, so nothing a CALLER can observe about its own
    reader moves when this search's cost moves. A caller folds this field
    into its own total (`ParquetHeaderAndSchema.bytes_examined`).
    """

    var value: String
    """The raw (still base64) `ARROW:schema` value, or `""` when absent."""
    var bytes_examined: Int
    """Footer byte-probes this search paid: `len(view) - stop_position`.

    Key PRESENT at `p` -> `len(view) - p`, i.e. the TAIL DISTANCE, a few
    hundred bytes on a pyarrow footer regardless of footer size. Key ABSENT
    -> `len(view)`, the whole footer.

    Computed in O(1) from the stop position, not by a per-byte counter: a
    counter in the scan's inner loop would add cost to the hot path, and one
    subtraction at the end is exact for a monotone backward walk. It is
    also invariant under vectorization — the 32-wide pre-filter probes the
    same byte RANGE."""

    def __init__(out self, var value: String, bytes_examined: Int):
        self.value = value^
        self.bytes_examined = bytes_examined

    def copied_value(self) -> String:
        """The value, copied out.

        A copy and not a move, because Mojo 1.0.0 rejects both `scan.value^`
        and a `var self` field move here ("field destroyed out of the middle
        of a value"). On the common arm the value is `""`, so this is a
        no-allocation copy of an empty string; on the key-PRESENT arm it is
        one memcpy of a few-KB base64 blob, smaller than the decode that
        follows it. Read `bytes_examined` from the struct directly; it is an
        `Int`."""
        return self.value.copy()


def find_arrow_schema_value_counted[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin]) -> ArrowSchemaScan:
    """The footer's `ARROW:schema` value AND the byte cost of finding it.

    This is the real entry point; `find_arrow_schema_value` is a wrapper
    that throws the cost away. Prefer this one from anything that reports a
    byte budget, and fold `bytes_examined` into that budget.

    See the module block above for why this is a byte search rather than one
    more arm of the Thrift loop, why it runs backward, and why a false
    positive cannot produce a wrong type.

    Parameters:
        mut: Whether the source view's origin permits mutation (inferred).
        origin: Origin the view is tied to.

    Args:
        view: Origin-tied view over the Thrift-encoded footer bytes.

    Returns:
        An `ArrowSchemaScan`. Never raises: a vendor extension this reader
        cannot read is ABSENT, not an error.
    """
    # `n` and `p` are declared outside the `try` so the `except` arm can
    # still report what was spent; returning 0 bytes from the error path
    # would under-report the cost. Everything that could raise stays inside,
    # so the "never raises" contract in the docstring holds literally.
    var n = 0
    var p = -1
    var value = String("")
    try:
        n = view.len()
        # The needle needs one byte of room BEFORE it (the `0x0C` length
        # prefix) and at least a STOP byte after it, so the scan starts at
        # the last position where a whole key could sit.
        p = n - _ARROW_SCHEMA_KEY_LEN - 1
        var reader = ThriftCompactReader[origin](view)
        var needle = SIMD[DType.uint8, _ARROW_SCAN_SIMD_W](
            _arrow_schema_key_byte(0)
        )
        while p >= 1:
            # NEEDLE-FIRST VECTOR PRE-FILTER. The key cannot START anywhere
            # in `[base, p]` unless some byte there is the needle's byte 0.
            # A window with no `'A'` is skipped whole; a window with one falls
            # through to EXACTLY the scalar verification below, which is why
            # the ANSWER is bit-identical to the pure scalar loop by
            # construction rather than by testing. XOR-then-`reduce_min` is
            # the spelling because `SIMD.__eq__` returns a scalar `Bool` in
            # Mojo 1.0.0 — `(chunk == needle).reduce_or()` does not compile.
            #
            # It does not change `bytes_examined`: the same byte RANGE is
            # probed, 32 lanes at a time.
            var base = p - _ARROW_SCAN_SIMD_W + 1
            if base >= 1:
                var chunk = view.load_simd[
                    DType.uint8, _ARROW_SCAN_SIMD_W
                ](base)
                if (chunk ^ needle).reduce_min() != UInt8(0):
                    p = base - 1
                    continue
            if (
                reader.byte_at(p) == _arrow_schema_key_byte(0)
                and reader.byte_at(p - 1) == UInt8(_ARROW_SCHEMA_KEY_LEN)
            ):
                var matched = True
                for i in range(1, _ARROW_SCHEMA_KEY_LEN):
                    if reader.byte_at(p + i) != _arrow_schema_key_byte(i):
                        matched = False
                        break
                if matched:
                    var v = _arrow_schema_value_at(
                        reader, p + _ARROW_SCHEMA_KEY_LEN
                    )
                    if v.byte_length() > 0:
                        value = v^
                        break
            p -= 1
    except:
        # cov: unreachable: every read above is inside the view (p is in
        # [1, n - 13]) and `_arrow_schema_value_at` catches its own errors.
        pass
    # A stop below 0 (a view shorter than the needle, where the loop never
    # ran) reports the whole view rather than a negative — over-reporting a
    # handful of bytes on a degenerate input, never under-reporting.
    var stop = p if p > 0 else 0
    return ArrowSchemaScan(value^, n - stop)


def find_arrow_schema_value[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin]) -> String:
    """The footer's `ARROW:schema` value, or `""`, WITHOUT walking `row_groups`.

    Thin wrapper over `find_arrow_schema_value_counted` that DISCARDS the
    byte cost. A caller that reports a byte budget must not use this one.

    Parameters:
        mut: Whether the source view's origin permits mutation (inferred).
        origin: Origin the view is tied to.

    Args:
        view: Origin-tied view over the Thrift-encoded footer bytes.

    Returns:
        The raw (still base64) value, or `""` when the key is absent or the
        bytes around it do not parse. Never raises.
    """
    var scan = find_arrow_schema_value_counted(view)
    return scan.copied_value()


def parse_metadata_header_and_schema[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin], early_exit: Bool = True) raises -> ParquetHeaderAndSchema:
    """Parse just `num_rows` + the flat `schema` list from the Thrift
    Compact Protocol FileMetaData footer, STOPPING before `row_groups`
    and the column/offset indexes.

    Cost: O(footer bytes up to and including the LAST of {`schema`,
    `num_rows`}), reported exactly in the returned `bytes_consumed`.

    The stop is an early `break`, not a cheap `_skip_field`: Thrift Compact
    has no length prefix for a struct, so `_skip_field(9)` recursively
    re-reads every nested field header. See module comment above.

    Parameters:
        mut: Whether the source view's origin permits mutation (inferred).
        origin: Origin the view is tied to.

    Args:
        view: Origin-tied view over the Thrift-encoded metadata bytes.
        early_exit: Stop the walk once both fields are read (the default).
            False walks the whole footer, with the same result; it exists to
            compare the two walks.

    Returns:
        A `ParquetHeaderAndSchema` with `num_rows` (Int), the flat
        `schema_elements: List[SchemaElement]`, and `bytes_consumed` —
        the reader position at exit, which is how far into the footer the
        walk got.

    Raises:
        Error if the metadata is malformed.
    """
    var reader = ThriftCompactReader[origin](view)

    var num_rows = 0
    var schema = List[SchemaElement]()

    # Stop the walk once BOTH wanted fields are in hand. See the module
    # comment above for why continuing is not free.
    #
    # Separate booleans, not `num_rows != 0`: an empty Parquet file has a
    # perfectly valid `num_rows = 0`, which is indistinguishable from "not
    # yet seen" in the value itself, and would make a 0-row file walk the
    # whole footer — so the presence flag is explicit.
    var have_num_rows = False
    var have_schema = False

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var field_id = field[0]
        var wire_type = field[1]

        if wire_type == 0:
            break  # STOP

        if field_id == 2 and wire_type == 9:
            # schema: list<SchemaElement>
            var list_header = reader._read_byte()
            var list_size = (list_header >> 4) & 0x0F
            if list_size == 15:
                list_size = reader._read_varint()
            # Reject an element count the remaining bytes cannot contain,
            # before the append loop below turns it into unbounded heap growth.
            list_size = reader._checked_list_size(list_size)

            for _ in range(list_size):
                var elem = _parse_schema_element(reader)
                schema.append(elem^)
            have_schema = True

        elif field_id == 3 and wire_type == 6:
            # num_rows: i64 (zigzag)
            num_rows = reader._read_zigzag()
            have_num_rows = True

        else:
            # Everything else — including field 4 (row_groups), field 1
            # (version), field 6 (created_by), field 7 (column_orders),
            # the page-index/offset-index fields — is skipped WITHOUT
            # DECODING ANY VALUES. That is not the same as cheap: on wire
            # type 9 (list) `_skip_field` must re-read every nested field
            # header to find the list's end, because Thrift Compact has no
            # length prefix for a struct. No ColumnChunk / Statistics is
            # ever CONSTRUCTED.
            reader._skip_field(wire_type)

        # EARLY EXIT. Both fields are read, so every remaining byte of the
        # footer would be walked only to be discarded.
        #
        # Placed AFTER the dispatch (not as a loop condition) so that the
        # iteration which completes the pair still finishes its own read.
        # `row_groups` emitted BEFORE both wanted fields simply never
        # reaches this break early -> old behaviour, no regression.
        if early_exit and have_schema and have_num_rows:
            break

    # The counted form, and the `+` is the point: `reader.pos` alone is what
    # `bytes_consumed` reports; the search below is a SECOND reader over the
    # SAME view, so its footprint has to be ADDED or the total is a fiction.
    # See `ParquetHeaderAndSchema.bytes_examined`.
    var scan = find_arrow_schema_value_counted(view)
    var examined = reader.pos + scan.bytes_examined
    return ParquetHeaderAndSchema(
        num_rows, schema^, reader.pos, scan.copied_value(), examined
    )


# =============================================================================
# The `num_rows`-only entry point — a second name, not a flag
# =============================================================================
#
# Why a second function and not a defaulted `bool` on the one above. A
# defaulted parameter fails quietly in BOTH polarities:
#   * default the hint ON  -> a caller that only wants `num_rows` silently
#     pays an O(footer) byte search for `ARROW:schema`;
#   * default the hint OFF -> a caller that builds a `Schema` from
#     `schema_elements` silently gets a HINT-BLIND one, reading a
#     `large_string` column back as `string`.
# A silent correctness failure is worse than a silent cost, so
# `parse_metadata_header_and_schema` KEEPS the hint, and the cheap route is a
# DIFFERENT NAME returning a DIFFERENT TYPE.
#
# The type is what makes it safe: this returns `num_rows` and a byte count,
# and NO `schema_elements`. A caller cannot build a hint-blind schema from
# it, because there is nothing here to build one from.


struct ParquetFooterNumRows(Movable):
    """`num_rows` from a footer, plus what reading it cost in bytes."""

    var num_rows: Int
    """`FileMetaData.num_rows`, Thrift field 3."""
    var bytes_examined: Int
    """Footer byte-probes paid. Same metric as
    `ParquetHeaderAndSchema.bytes_examined` so the two are comparable."""

    def __init__(out self, num_rows: Int, bytes_examined: Int):
        self.num_rows = num_rows
        self.bytes_examined = bytes_examined


def parse_metadata_num_rows_only[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin]) raises -> ParquetFooterNumRows:
    """`num_rows` alone, WITHOUT the `ARROW:schema` search and WITHOUT
    building the `SchemaElement` list.

    For callers that want a row count and nothing else — the canonical one is
    `ParquetNumRowsCache`, which discarded both the schema list and the hint.

    Cost: O(bytes up to and including Thrift field 3), a few hundred bytes
    on a typical footer against the whole footer for
    `parse_metadata_header_and_schema` when the file has no `ARROW:schema`.

    Degrades, never regresses, on an unusual field order. `_skip_field` on
    a wire-type-9 list is a full recursive walk (see the module comment), so
    a writer that emitted `row_groups` BEFORE `num_rows` would pay that walk
    here; the floor is "no win", not "slower".

    Parameters:
        mut: Whether the source view's origin permits mutation (inferred).
        origin: Origin the view is tied to.

    Args:
        view: Origin-tied view over the Thrift-encoded metadata bytes.

    Returns:
        A `ParquetFooterNumRows`.

    Raises:
        Error if the metadata is malformed.
    """
    var reader = ThriftCompactReader[origin](view)
    var num_rows = 0
    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var field_id = field[0]
        var wire_type = field[1]
        if wire_type == 0:
            break  # STOP
        if field_id == 3 and wire_type == 6:
            num_rows = reader._read_zigzag()
            # Break on having read the field, not on its value: a 0-row
            # file has a valid `num_rows = 0`, and a sentinel-on-the-value
            # test would send it on to walk the whole footer.
            break
        reader._skip_field(wire_type)
    return ParquetFooterNumRows(num_rows, reader.pos)
