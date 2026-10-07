# =============================================================================
# CsvReadOptions — read-side options for the komira_csv chassis.
# =============================================================================
#
# Read-side options live in this struct. `CsvOptions` in
# `komira_arrow.serde_format_options` is the WRITE-side options surface
# (delimiter / quote / header — three byte-typed POD fields).
#
# `CsvReadOptions` adds the reader-specific knobs the toy reader lacked:
#   - null_strings:    multi-string null-detection (pandas-parity default
#                      `["", "NULL", "NA", "NaN", "null"]`).
#   - true_strings:    Bool-cell true-set (default
#                      `["true", "TRUE", "T", "1", "yes", "Y"]`).
#   - false_strings:   Bool-cell false-set (default
#                      `["false", "FALSE", "F", "0", "no", "N"]`).
#   - infer_rows:      whole-file scan when -1; otherwise N-row prefix
#                      sample for per-column type inference (default 100).
#   - decimal_separator: byte for fraction separator (b'.' default; b','
#                      for European locales).
#   - max_row_bytes:   safety cap on row buffer for unterminated quoted
#                      regions (default 1 MiB).
#
# Pointer-free shape: no `List[String]`
# fields — each string-list field is `InlineArray[String, MAX_NULL_STRINGS=8]`
# + a paired `_n_*: Int` counter. The InlineArray cap is comfortably above
# pandas's 5-default + room for one site-specific token.
# =============================================================================


# 8 entries is the cap — pandas's 5-default + 3 slots of headroom for
# site-specific tokens. Caller passing >8 strings raises typed
# `CsvReadOptionsTooManyNullStrings` at construction.
comptime MAX_NULL_STRINGS: Int = 8
from komira_arrow.arrow_types import ArrowType

comptime MAX_TRUE_FALSE_STRINGS: Int = 8

# Per-column date_format InlineArray cap.
# Per-column date format
# override for heterogeneous-date files (col_birth='MM/DD/YYYY' while
# col_event='YYYY-MM-DD'). Bounded heap-owning, pointer-free shape.
comptime MAX_DATE_FORMATS: Int = 8

# 1 MiB row-buffer safety cap. Unterminated quoted regions are bounded.
comptime DEFAULT_MAX_ROW_BYTES: Int = 1 * 1024 * 1024


# =============================================================================
# QuoteStyle runtime tag —
# =============================================================================
#
# The reader entry `read_csv_bytes_to_batch[Q: QuoteStyle]` takes Q as a
# COMPTIME parameter; the engine source-compile path is RUNTIME (the
# `_compile_csv_scan` arm reads a CsvSource value at plan-compile time).
# Bridge: carry a small runtime integer tag on CsvReadOptions + CsvSource;
# the plan-compiler does a 3-way cascade `if tag == 0: scan[Rfc4180]
# elif tag == 1: scan[Excel] elif tag == 2: scan[Posix]`. The cascade is
# fan-out-comptime (3 monomorphized scanner instantiations baked in), 1
# branch at runtime.
#
# Tag IDs are explicitly chosen to match the conformer order in
# `komira_arrow.quote_styles` (Rfc4180 / Excel / Posix).
# Future conformers extend at the next free tag.
# =============================================================================

comptime QUOTE_STYLE_TAG_RFC4180: Int = 0
comptime QUOTE_STYLE_TAG_EXCEL: Int = 1
comptime QUOTE_STYLE_TAG_POSIX: Int = 2


struct CsvReadOptions(Copyable, Movable, Deinitable):
    """Read-side options for the komira_csv chassis.

    (pointer-free InlineArray[String, 8] cap on string-list
    fields).

    Defaults mirror pandas:
      - delimiter = b','
      - has_header = True
      - quote = b'"'
      - null_strings = ["", "NULL", "NA", "NaN", "null"]
      - true_strings = ["true", "TRUE", "T", "1", "yes", "Y"]
      - false_strings = ["false", "FALSE", "F", "0", "no", "N"]
      - infer_rows = 100
      - decimal_separator = b'.'
      - max_row_bytes = 1 MiB
    """

    # POD bytes (carry-clean across Movable-struct moves)
    var delimiter: UInt8
    var quote: UInt8
    var has_header: Bool
    var decimal_separator: UInt8

    # Bounded heap-owning fields (pointer-free via InlineArray cap)
    var null_strings: Array[String, MAX_NULL_STRINGS]
    var _n_null_strings: Int

    var true_strings: Array[String, MAX_TRUE_FALSE_STRINGS]
    var _n_true_strings: Int

    var false_strings: Array[String, MAX_TRUE_FALSE_STRINGS]
    var _n_false_strings: Int

    # Per-column date_format.
    # date_format: global default format string (empty -> ISO-8601 YYYY-MM-DD).
    # per_column_date_formats / per_column_date_format_columns: parallel
    # arrays (column_name[i] -> format_string[i]). _n_* is the count.
    var date_format: String
    var per_column_date_formats: Array[String, MAX_DATE_FORMATS]
    var per_column_date_format_columns: Array[String, MAX_DATE_FORMATS]
    var _n_per_column_date_formats: Int

    # UTF-8 BOM handling.
    # When True (default), the reader detects and strips a UTF-8 BOM
    # (0xEF 0xBB 0xBF) at file start before scan. False = strict mode:
    # treat BOM bytes as part of the first column's first cell.
    var strip_utf8_bom: Bool

    # Projection fast-skip
    # When non-empty, the reader pre-resolves which columns to materialize
    # at scan time + skips parsing for non-projected columns (the scanner
    # still walks bytes to find row boundaries, but cell-bytes for skipped
    # columns are not converted to typed builders). Bounded heap-owning
    # InlineArray per pointer-free shape.
    var projection_columns: Array[String, MAX_DATE_FORMATS]
    var _n_projection_columns: Int

    # Scalar fields
    var infer_rows: Int
    var max_row_bytes: Int

    # Runtime tag selecting the comptime QuoteStyle instantiation for the
    # scanner. 0 = Rfc4180 (default), 1 = Excel, 2 = Posix. The plan-
    # compiler's _compile_csv_scan arm reads this tag + cascades to the
    # right comptime-monomorphized `read_csv_bytes_to_batch[Q]` arm.
    var quote_style_tag: Int

    # Opt-in toggle: when True, the reader uses `infer_column_types_wide`
    # (17-flag temporal-aware lattice — Date64 / Timestamp_*/ Time_* /
    # Duration_* in addition to the default 5-type lattice). When False
    # (default), uses the original 5-type `infer_column_types` for
    # backward compat. The matching typed-builder cascade in `reader.mojo`
    # materializes Int8/16/32, UInt8/16/32/64, Float32, Date64, all
    # Timestamp/Time/Duration variants, and Decimal128 (Int64 mantissa).
    var infer_temporal_types: Bool

    # Decimal128 precision/scale used when a column is forced or inferred
    # as DECIMAL128. Today the wide lattice does NOT auto-infer
    # DECIMAL128 (the per-cell precision/scale would need to be derived
    # from sample width), but explicit precision/scale here lets a caller
    # who knows their CSV's decimal column shape pre-declare it. The
    # decimal cell parser ships `_try_parse_decimal128_to_int64` which
    # takes (precision, scale) and emits an Int64 mantissa; precision
    # must be <= 18. Defaults: precision=18, scale=2 — matches a generic
    # "money up to $9.2e16" column.
    var decimal_precision: Int
    var decimal_scale: Int

    # =========================================================================
    # DECLARED-SCHEMA DECODE
    # =========================================================================
    var declared_column_types: List[ArrowType]
    """The dtypes the CALLER has already bound this file at — one per column,
    in HEADER ORDER. EMPTY (the default) means "infer", which is every
    historical caller's behaviour and is unchanged.

    ★ THIS IS THE FIELD `row_column_reroute` AND `engine_context` BOTH SAID DID
    NOT EXIST, AND ITS ABSENCE WAS A SILENT WRONG ANSWER. `CsvReadOptions`
    carried no declared-schema input at all, so the columnar CSV reader ALWAYS
    re-inferred. A plan bound `all_varchar=true` (every column VARCHAR) that
    the row tower DECLINES — `... GROUP BY n` — demotes to
    `EngineContext._demote_row_scan_leaf_to_column`, which decoded through this
    reader and ADOPTED the inferred schema. The query BOUND `n = STRING` and
    EXECUTED `n = INT64`, returned six plausible rows and raised NOTHING.

    ⚠ A CAST AFTER THE FACT CANNOT SUBSTITUTE FOR THIS, which is why the input
    is at the DECODE and not at the demote: `all_varchar` over a cell holding
    `0001`, re-inferred INT64, parses to `1` and renders back as `"1"`. The
    right TYPE and the wrong VALUE — strictly worse than the bug it replaces,
    because the type assertion that catches today's version would pass. The
    bytes have to survive, so the PARSE has to happen at the declared dtype.

    THE CONTRACT: empty, or EXACTLY one entry per column of the file. A length
    that disagrees with the header RAISES (`check_declared_column_types`) — the
    caller bound a different file shape than the one on disk, and guessing
    which columns line up is how the silent version of this bug got here."""

    def __init__(out self):
        """Default ctor — pandas-parity defaults."""
        self.delimiter = UInt8(ord(","))
        self.quote = UInt8(ord('"'))
        self.has_header = True
        self.decimal_separator = UInt8(ord("."))

        # Initialize InlineArrays (Mojo 1.0.0b1 requires explicit fill_value
        # for non-trivially-default-constructible inner types; String is
        # default-constructible to "" so we can use a sentinel-fill pattern).
        self.null_strings = Array[String, MAX_NULL_STRINGS](fill=String(""))
        self.true_strings = Array[String, MAX_TRUE_FALSE_STRINGS](fill=String(""))
        self.false_strings = Array[String, MAX_TRUE_FALSE_STRINGS](fill=String(""))

        # Populate defaults
        self.null_strings[0] = String("")
        self.null_strings[1] = String("NULL")
        self.null_strings[2] = String("NA")
        self.null_strings[3] = String("NaN")
        self.null_strings[4] = String("null")
        self._n_null_strings = 5

        self.true_strings[0] = String("true")
        self.true_strings[1] = String("TRUE")
        self.true_strings[2] = String("T")
        self.true_strings[3] = String("1")
        self.true_strings[4] = String("yes")
        self.true_strings[5] = String("Y")
        self._n_true_strings = 6

        self.false_strings[0] = String("false")
        self.false_strings[1] = String("FALSE")
        self.false_strings[2] = String("F")
        self.false_strings[3] = String("0")
        self.false_strings[4] = String("no")
        self.false_strings[5] = String("N")
        self._n_false_strings = 6

        self.infer_rows = 100
        self.max_row_bytes = DEFAULT_MAX_ROW_BYTES

        # Per-column date_format + BOM + projection
        self.date_format = String("")
        self.per_column_date_formats = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        self.per_column_date_format_columns = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        self._n_per_column_date_formats = 0
        self.strip_utf8_bom = True
        self.projection_columns = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        self._n_projection_columns = 0
        # Default Rfc4180.
        self.quote_style_tag = QUOTE_STYLE_TAG_RFC4180
        # Default OFF
        # for backward compat (existing callers see the 5-type lattice).
        self.infer_temporal_types = False
        self.decimal_precision = 18
        self.decimal_scale = 2
        # DECLARED-SCHEMA DECODE: empty == infer, the historical behaviour.
        self.declared_column_types = List[ArrowType]()

    def copy(self) -> Self:
        """Deep clone — the InlineArray[String, N] inner Strings are
        individually heap-owning, so each gets its own copy."""
        var out = Self.__new_uninitialized__()
        out.delimiter = self.delimiter
        out.quote = self.quote
        out.has_header = self.has_header
        out.decimal_separator = self.decimal_separator
        out.null_strings = Array[String, MAX_NULL_STRINGS](fill=String(""))
        out.true_strings = Array[String, MAX_TRUE_FALSE_STRINGS](fill=String(""))
        out.false_strings = Array[String, MAX_TRUE_FALSE_STRINGS](fill=String(""))
        var i = 0
        while i < self._n_null_strings:
            out.null_strings[i] = String(self.null_strings[i])
            i = i + 1
        out._n_null_strings = self._n_null_strings
        i = 0
        while i < self._n_true_strings:
            out.true_strings[i] = String(self.true_strings[i])
            i = i + 1
        out._n_true_strings = self._n_true_strings
        i = 0
        while i < self._n_false_strings:
            out.false_strings[i] = String(self.false_strings[i])
            i = i + 1
        out._n_false_strings = self._n_false_strings
        out.infer_rows = self.infer_rows
        out.max_row_bytes = self.max_row_bytes
        # Fields
        out.date_format = String(self.date_format)
        out.per_column_date_formats = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        out.per_column_date_format_columns = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        var k = 0
        while k < self._n_per_column_date_formats:
            out.per_column_date_formats[k] = String(
                self.per_column_date_formats[k]
            )
            out.per_column_date_format_columns[k] = String(
                self.per_column_date_format_columns[k]
            )
            k = k + 1
        out._n_per_column_date_formats = self._n_per_column_date_formats
        out.strip_utf8_bom = self.strip_utf8_bom
        out.projection_columns = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        k = 0
        while k < self._n_projection_columns:
            out.projection_columns[k] = String(self.projection_columns[k])
            k = k + 1
        out._n_projection_columns = self._n_projection_columns
        # Copy the tag.
        out.quote_style_tag = self.quote_style_tag
        # Copy the opt-in temporal-inference flag + decimal precision/scale.
        out.infer_temporal_types = self.infer_temporal_types
        out.decimal_precision = self.decimal_precision
        out.decimal_scale = self.decimal_scale
        # DECLARED-SCHEMA DECODE: ArrowType is a POD tag, so an element-wise
        # copy is a full deep copy.
        out.declared_column_types = List[ArrowType]()
        for t in self.declared_column_types:
            out.declared_column_types.append(t)
        return out^

    @staticmethod
    def __new_uninitialized__() -> Self:
        """Internal helper for `copy()`. Constructs a Self with placeholder
        InlineArrays; the caller MUST overwrite every used slot before reading.
        """
        var s = Self.__placeholder__()
        return s^

    @staticmethod
    def __placeholder__() -> Self:
        """Construct a Self with all fields set to default sentinels.

        This bypasses the per-field-fill heap allocations the normal `__init__`
        runs, but the result is logically equivalent to a fresh `CsvReadOptions()`
        with zeroed counters — caller must repopulate the InlineArray contents
        before reading any of the bounded fields.
        """
        var s = Self(
            delimiter=UInt8(ord(",")),
            quote=UInt8(ord('"')),
            has_header=True,
            decimal_separator=UInt8(ord(".")),
            null_strings=Array[String, MAX_NULL_STRINGS](fill=String("")),
            _n_null_strings=0,
            true_strings=Array[String, MAX_TRUE_FALSE_STRINGS](fill=String("")),
            _n_true_strings=0,
            false_strings=Array[String, MAX_TRUE_FALSE_STRINGS](fill=String("")),
            _n_false_strings=0,
            infer_rows=100,
            max_row_bytes=DEFAULT_MAX_ROW_BYTES,
        )
        # quote_style_tag is set by Self.__init__ above to RFC4180 default;
        # caller may overwrite via with_quote_style or direct assignment.
        return s^

    def __init__(
        out self,
        delimiter: UInt8,
        quote: UInt8,
        has_header: Bool,
        decimal_separator: UInt8,
        var null_strings: Array[String, MAX_NULL_STRINGS],
        _n_null_strings: Int,
        var true_strings: Array[String, MAX_TRUE_FALSE_STRINGS],
        _n_true_strings: Int,
        var false_strings: Array[String, MAX_TRUE_FALSE_STRINGS],
        _n_false_strings: Int,
        infer_rows: Int,
        max_row_bytes: Int,
    ):
        """Field-wise ctor — used by the placeholder + copy paths.

        new fields (date_format / per_column_* / strip_utf8_bom /
        projection_columns) are initialized to defaults here; callers using
        this ctor must overwrite these AFTER construction if needed.
        """
        self.delimiter = delimiter
        self.quote = quote
        self.has_header = has_header
        self.decimal_separator = decimal_separator
        self.null_strings = null_strings^
        self._n_null_strings = _n_null_strings
        self.true_strings = true_strings^
        self._n_true_strings = _n_true_strings
        self.false_strings = false_strings^
        self._n_false_strings = _n_false_strings
        self.infer_rows = infer_rows
        self.max_row_bytes = max_row_bytes
        # Defaults
        self.date_format = String("")
        self.per_column_date_formats = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        self.per_column_date_format_columns = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        self._n_per_column_date_formats = 0
        self.strip_utf8_bom = True
        self.projection_columns = Array[
            String, MAX_DATE_FORMATS
        ](fill=String(""))
        self._n_projection_columns = 0
        # Default Rfc4180.
        self.quote_style_tag = QUOTE_STYLE_TAG_RFC4180
        # Defaults
        self.infer_temporal_types = False
        self.decimal_precision = 18
        self.decimal_scale = 2
        # DECLARED-SCHEMA DECODE: empty == infer, the historical behaviour.
        self.declared_column_types = List[ArrowType]()

    def with_quote_style(mut self, tag: Int) raises:
        """Set the runtime QuoteStyle tag. Accepts QUOTE_STYLE_TAG_{RFC4180, EXCEL, POSIX}. The
        scanner cascade in `_compile_csv_scan` reads this and routes to
        the matching comptime-monomorphized `read_csv_bytes_to_batch[Q]`.

        Raises if `tag` is not one of the 3 known values.
        """
        if (
            tag != QUOTE_STYLE_TAG_RFC4180
            and tag != QUOTE_STYLE_TAG_EXCEL
            and tag != QUOTE_STYLE_TAG_POSIX
        ):
            raise Error(
                "CsvReadOptions.with_quote_style: unknown tag "
                + String(tag)
                + " — expected 0 (Rfc4180), 1 (Excel), or 2 (Posix)."
            )
        self.quote_style_tag = tag

    def with_per_column_date_format(
        mut self, var column: String, var format: String
    ) raises:
        """Add a per-column date format override

        Args:
            column: Column name to apply this format to.
            format: Format string (e.g. "MM/DD/YYYY", "DD-MM-YYYY"). Empty
                = use global `date_format`.

        Raises:
            Error if the per-column array is full
            (MAX_DATE_FORMATS=8 exceeded).
        """
        if self._n_per_column_date_formats >= MAX_DATE_FORMATS:
            raise Error(
                "CsvReadOptions.with_per_column_date_format: cap "
                + String(MAX_DATE_FORMATS)
                + " exceeded. Reduce per-column override count or extend "
                + "MAX_DATE_FORMATS."
            )
        # InlineArray[String, N] __setitem__ takes by Copyable assignment;
        # String is Copyable so the bare `=` works without `^`.
        self.per_column_date_format_columns[
            self._n_per_column_date_formats
        ] = column
        self.per_column_date_formats[
            self._n_per_column_date_formats
        ] = format
        self._n_per_column_date_formats += 1

    def get_per_column_date_format(self, column_name: String) -> String:
        """Look up the per-column date format for `column_name`. Returns
        the global `date_format` if no override is registered.

        Linear scan over the (typically tiny — at most 8) per-column
        arrays. O(N_OVERRIDES); not on the hot row-loop path (called once
        per column at scan setup).
        """
        var i = 0
        while i < self._n_per_column_date_formats:
            if self.per_column_date_format_columns[i] == column_name:
                return String(self.per_column_date_formats[i])
            i = i + 1
        return String(self.date_format)

    def with_projection(mut self, var column: String) raises:
        """Add a column name to the projection list (fast-skip).

        Empty projection list = read all columns (default). Non-empty
        list = scan emits rows but only converts cells for these columns
        into typed builders (fast-skip non-projected).

        Raises:
            Error if the projection cap is exceeded (MAX_DATE_FORMATS=8
            reused as bound — typical projection-pushdown surface is 1-3
            columns).
        """
        if self._n_projection_columns >= MAX_DATE_FORMATS:
            raise Error(
                "CsvReadOptions.with_projection: cap "
                + String(MAX_DATE_FORMATS)
                + " exceeded. Reduce projection size."
            )
        self.projection_columns[self._n_projection_columns] = column
        self._n_projection_columns += 1

    def with_temporal_inference(mut self, on: Bool):
        """Opt into the wider temporal-aware type-inference lattice.

        Default is False (5-type lattice — Int64/Float64/Date32/Bool/String).
        Pass True to enable Date64/Timestamp_*/Time_*/Duration_* inference
        + the matching typed builders.

        See `komira_csv.type_inference.infer_column_types_wide` for the
        full priority order (most-specific-first).
        """
        self.infer_temporal_types = on

    def with_decimal_precision_scale(
        mut self, precision: Int, scale: Int
    ) raises:
        """Set the (precision, scale) used when a column is declared as
        DECIMAL128.

        Constraints (matching `_try_parse_decimal128_to_int64`):
          - precision in [1, 18]
          - scale in [0, precision]
        Wider precision (19-38) is not supported.
        """
        if precision < 1 or precision > 18:
            raise Error(
                "CsvReadOptions.with_decimal_precision_scale: precision "
                + String(precision)
                + " out of [1, 18] (wider precision is not supported)."
            )
        if scale < 0 or scale > precision:
            raise Error(
                "CsvReadOptions.with_decimal_precision_scale: scale "
                + String(scale)
                + " out of [0, "
                + String(precision)
                + "]."
            )
        self.decimal_precision = precision
        self.decimal_scale = scale

    def is_projected(self, column_name: String) -> Bool:
        """Returns True iff `column_name` is in the projection list, OR
        the projection list is empty (== read-all default)."""
        if self._n_projection_columns == 0:
            return True
        var i = 0
        while i < self._n_projection_columns:
            if self.projection_columns[i] == column_name:
                return True
            i = i + 1
        return False


# =============================================================================
# check_declared_column_types — the DECLARED-SCHEMA decode's one precondition
# =============================================================================


def check_declared_column_types(
    imm declared: List[ArrowType], num_cols: Int, imm where: String,
) raises:
    """Refuse a declared-type list that does not describe the file in hand.

    An empty list means "infer" and is always fine. A NON-empty list must have
    exactly one entry per column the scanner found, because the mapping is
    POSITIONAL — column `i` of the file is parsed at `declared[i]`.

    ⚠ RAISING IS THE POINT. The caller has bound a plan against a schema of a
    different width than the file on disk now has, and every way of continuing
    is a silent wrong answer: truncating drops columns, padding with STRING
    invents them, and falling back to inference re-opens the
    bind-vs-execute type split this input exists to
    close. The message names the widths so the caller can see which side moved.
    """
    if len(declared) == 0:
        return
    if len(declared) != num_cols:
        raise Error(
            String(where)
            + ": the plan declares "
            + String(len(declared))
            + " column(s) but the CSV header has "
            + String(num_cols)
            + ". A declared-schema decode is POSITIONAL, so a width"
            + " disagreement cannot be resolved here — re-bind the scan"
            + " against the file as it is now."
        )
