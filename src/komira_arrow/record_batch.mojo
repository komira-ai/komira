# =============================================================================
# RecordBatch and RecordBatchBuilder -- columnar batch with typed accessors
# =============================================================================
#
# RecordBatchBuilder uses Slab[Column] (dynamic growth, unknown size).
# RecordBatch uses Slab[Column] (fixed size after construction).
# The build() method transfers ownership by stealing the Slab's slab,
# then moving each Column individually via take_pointee() into a new Slab.
# =============================================================================

# =============================================================================
# WILDCARD-ORIGIN SITES: pending migration
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# Do NOT add new wildcard sites to this file.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType, layouts_conflict
from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.offset_overflow import ARROW_INT32_OFFSET_MAX
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.varlen_width_guard import check_offsets_buffer_width
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion


def _zero_length_column(at: ArrowType) raises -> Column[HeapRegion]:
    """One zero-length `Column` of the declared `ArrowType` — the per-field
    building block of `RecordBatch.empty_from_schema`.

    The DECLARED type is preserved exactly (no widening to NULL, no collapse to
    a numeric placeholder): a consumer that reads the schema of an empty result
    and then reads the column types must see the same answer it would for a
    non-empty result of the same query.

    Buffer presence follows the Arrow layout of the type, because a consumer may
    probe `has_offsets_buffer()` before reading. Variable-width layouts carry a
    ZEROED single-entry offsets buffer (Arrow's `offsets[0] == 0` for a length-0
    array); fixed-width layouts carry none. Validity is absent (`null_count ==
    0`) — with zero rows there is no bit to set, and an absent validity buffer is
    the canonical Arrow spelling of "no nulls".
    """
    var offsets: Optional[OwnedAlignedBuffer] = None
    if (
        at == ArrowType.STRING
        or at == ArrowType.BINARY
        or at == ArrowType.LIST
        or at == ArrowType.MAP
        or at == ArrowType.LIST_VIEW
    ):
        # Int32 offsets: one entry, value 0.
        var ob32 = OwnedAlignedBuffer(4)
        ob32.zero()
        offsets = Optional[OwnedAlignedBuffer](ob32^)
    elif (
        at == ArrowType.LARGE_STRING
        or at == ArrowType.LARGE_BINARY
        or at == ArrowType.LARGE_LIST
        or at == ArrowType.LARGE_LIST_VIEW
    ):
        # Int64 offsets: one entry, value 0.
        var ob64 = OwnedAlignedBuffer(8)
        ob64.zero()
        offsets = Optional[OwnedAlignedBuffer](ob64^)
    return Column[HeapRegion](
        arrow_type=at,
        data=OwnedAlignedBuffer(0),
        offsets=offsets^,
        validity=Optional[Bitmap[HeapRegion]](None),
        length=0,
        null_count=0,
        offset=0,
    )


# =============================================================================
# RecordBatchBuilder -- flexible RecordBatch construction for any number of columns
# =============================================================================

struct RecordBatchBuilder(Movable):
    """Incrementally builds a RecordBatch by adding columns one at a time.

    Uses Slab[Column] for dynamic growth. Columns are moved in
    on add_column() and transferred to RecordBatch on build().
    """

    var _columns: Slab[Column[HeapRegion]]

    def __init__(out self):
        """Create an empty RecordBatchBuilder."""
        self._columns = Slab[Column[HeapRegion]]()

    @staticmethod
    def with_capacity(capacity: Int) -> RecordBatchBuilder:
        """Pre-allocate storage for N columns."""
        var builder = RecordBatchBuilder()
        if capacity > 0:
            builder._columns = Slab[Column[HeapRegion]].with_capacity(capacity)
        return builder^

    def add_column(mut self, var col: Column[HeapRegion]):
        """Append a column to the builder. The column is moved (consumed)."""
        self._columns.append(col^)

    def num_columns(self) -> Int:
        """Columns appended so far. The next `add_column` lands at this index."""
        return len(self._columns)

    def share_column(self, index: Int) raises -> Column[HeapRegion]:
        """Arc-SHARE an ALREADY-ADDED column: a new `Column` whose every buffer
        ALIASES slot `index`'s bytes via a refcount bump, with NO byte copy.

        The one supported use is emitting a second output column that is
        provably byte-identical to one this builder already holds — the
        JOIN-KEY CSE (`komira_join_assembly.join_key_cse`), where an INNER
        equi-join projects the key from BOTH sides and the two output columns
        hold the same values by definition of the join condition.

        SOUNDNESS is `Column.share`'s, verbatim: Arrow buffers are immutable on
        every consumer path, so two columns of one batch aliasing one buffer
        cannot expose a write-through hazard. This does NOT read the builder
        destructively and does not renumber anything — the returned column must
        still be `add_column`'d to take a slot of its own.

        Raises:
            Error: If `index` is not an already-added slot. A silently
                out-of-range read would emit a wrong COLUMN, which no row-count
                assertion can see.
        """
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatchBuilder.share_column: index "
                + String(index)
                + " is outside the "
                + String(len(self._columns))
                + " columns added so far"
            )
        return self._columns[index].share()

    def build(mut self, var schema: Schema) raises -> RecordBatch:
        """Consume this builder and schema, returning a RecordBatch."""
        var num_cols = len(self._columns)
        if schema.num_columns() != num_cols:
            raise Error(
                "RecordBatchBuilder.build: schema has "
                + String(schema.num_columns())
                + " fields, but builder has "
                + String(num_cols)
                + " columns"
            )
        if num_cols == 0:
            var batch = RecordBatch()
            batch.schema = schema^
            return batch^

        var num_rows = self._columns[0]._length
        for i in range(1, num_cols):
            if self._columns[i]._length != num_rows:
                raise Error(
                    "RecordBatchBuilder.build: column "
                    + String(i)
                    + " has length "
                    + String(self._columns[i]._length)
                    + ", expected "
                    + String(num_rows)
                )

        # ★ THE TAG IS CHECKED AGAINST THE BUFFER, NOT AGAINST THE OTHER TAG.
        #
        # Every reconciliation in the drain loop below decides what a column IS
        # by comparing two type TAGS — and two tags that agree with each other
        # while BOTH disagree with the buffers satisfy all of them.
        # `check_offsets_buffer_width` is the one check here that consults the
        # offsets buffer's actual SIZE, so a producer that stamps an
        # Int64-offset tag on an Int32-offset buffer is refused rather than
        # having its claim written into the Schema. Skipped for a column with
        # no offsets buffer at all (a legitimate all-empty varlen shape; the
        # promotion guard below handles that case by declining to promote).
        #
        # ⚠ THIS PASS MUST STAY ABOVE THE DRAIN LOOP AND MUST NOT MOVE INTO IT.
        # The drain uses `take_slot_unchecked(i)`, whose contract is that a
        # matching `set_len_unchecked(0)` runs afterwards; raising from inside
        # that loop leaves `self._columns` claiming a length that includes
        # already-moved-from slots, and its destructor then `destroy_pointee`s
        # them — a double free, observed as a bare SIGSEGV with no test output
        # at all. A validation that can raise belongs before the first move.
        for i in range(num_cols):
            ref pre = self._columns[i]
            if pre._offsets:
                check_offsets_buffer_width(
                    "RecordBatchBuilder.build",
                    pre.arrow_type,
                    i,
                    pre._length,
                    Int(pre._offsets.value().len()),
                )

        # Transfer columns individually from Slab to Slab.
        #
        # The Slab is NOT transferred whole (steal_slab() + from_slab()):
        # that relies on bitcast[Column] reinterpreting raw bytes as
        # Column structs and does not preserve Column.arrow_type.
        #
        # This drains `self._columns` in place via
        # `take_slot_unchecked(i)` — a safe Slab primitive that moves
        # each Column out without shifting the tail OR touching `_len_t`.
        # After draining, `set_len_unchecked(0)` marks the slab empty so
        # its destructor does NOT call `destroy_pointee` on the
        # moved-from slots.
        #
        # DICTIONARY preservation: When the Column was decoded as DICTIONARY
        # (int32 indices + dict offsets + dict data) but the Schema says
        # STRING (from Parquet's BYTE_ARRAY physical type), we update the
        # Schema to match the Column's actual data layout. The Column's
        # arrow_type is authoritative; the Schema is the one that needs
        # correction.

        var columns = Slab[Column[HeapRegion]].create(num_cols)

        for i in range(num_cols):
            # SAFETY: take_slot_unchecked moves the Column out of slot i
            # without shifting the tail. Its contract requires a matching
            # `set_len_unchecked(0)` below so the drop does not read the
            # moved-from slots. See Slab.take_slot_unchecked docstring.
            var col = self._columns.take_slot_unchecked(i)

            # Does this column's offsets buffer ACTUALLY hold Int64 entries?
            # This is the promotion's precondition, and it is deliberately
            # not `col.arrow_type == LARGE_STRING`: the whole point of the
            # lockstep is that the COLUMN is authoritative, which is only
            # true if its buffers back its claim.
            var wide_offsets_are_real = False
            if col._offsets:
                wide_offsets_are_real = (
                    Int(col._offsets.value().len()) >= (col._length + 1) * 8
                )

            # Reconcile Schema vs Column type for DICTIONARY columns.
            var schema_type = schema.field_arrow_type(i)
            if col.arrow_type == ArrowType.DICTIONARY and (
                schema_type == ArrowType.STRING
                or schema_type == ArrowType.LARGE_STRING
            ):
                schema._arrow_types[i] = col.arrow_type.type_id
            elif wide_offsets_are_real and (
                (
                    col.arrow_type == ArrowType.LARGE_STRING
                    and schema_type == ArrowType.STRING
                )
                or (
                    col.arrow_type == ArrowType.LARGE_BINARY
                    and schema_type == ArrowType.BINARY
                )
            ):
                # LOCKSTEP OFFSET-WIDTH PROMOTION. Same principle as the
                # DICTIONARY case above and the same direction: the COLUMN is
                # authoritative about its own buffers, so the Schema is what
                # gets corrected.
                #
                # WHY IT MUST HAPPEN HERE. A varlen gather decides its offset
                # width from the DATA (above 2 GiB it emits Int64 offsets and
                # tags the Column `LARGE_*` rather than raising), but the
                # producer appended its Schema field BEFORE gathering — it
                # cannot know the width in advance without a second pass over
                # the whole column. `build` is the one point where both halves
                # are in hand, and it is already the tree's place for exactly
                # this correction.
                #
                # WITHOUT THIS the promotion would be strictly WORSE than the
                # raise it replaces: `_ensure_column_type` would find a
                # LARGE_STRING Column under a STRING field. It no longer
                # "repairs" that — `_reject_layout_conflict` refuses across a
                # physical-layout change, so the failure is loud — but a loud
                # failure at a downstream accessor is still a query that
                # returns nothing. The lockstep is what makes it return data.
                #
                # ⚠ ONE DIRECTION ONLY, AND THE ASYMMETRY IS THE POINT.
                # Widening the Schema to match a wide Column is safe: every
                # value the Column holds is representable, and the tag now
                # describes the buffers. The REVERSE — a STRING Column under a
                # LARGE_STRING field — is NOT reconciled here and must keep
                # raising, because narrowing the declared type of a column
                # whose offsets are int32 would be a claim about the buffers
                # that is simply false. `test_string_under_large_string_schema_is_rejected`
                # pins that, and it must stay red-on-regression.
                #
                # ⚠ AND IT IS GATED ON `wide_offsets_are_real`, NOT ON THE TAG
                # ALONE. A tag-only form would promote the SCHEMA on the
                # strength of a claim nothing had checked: a producer that
                # stamped LARGE_STRING on an Int32-offsets buffer would get the
                # schema widened to agree with it, and from then on every
                # reader would stride that buffer by 8. `_reject_layout_conflict`
                # would not catch it, because that guard is also tag-vs-tag and
                # by then the two tags AGREE. The
                # undersized case now raises above; the offsets-ABSENT case
                # falls through here, leaving the Schema narrow so the
                # layout-conflict refusal at the first accessor still fires.
                schema._arrow_types[i] = col.arrow_type.type_id

            columns.append(col^)

        # All slots have been moved out via take_slot_unchecked. Mark the
        # slab empty so its destructor does not call destroy_pointee on
        # the moved-from slots.
        self._columns.set_len_unchecked(0)

        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^


# =============================================================================
# RecordBatch -- type-erased columnar batch using Column
# =============================================================================

struct RecordBatch(Movable):
    """A batch of columnar data: a Schema plus type-erased Columns.

    Fields:
        schema: The Schema describing column names, types, and nullability.
        _columns: Slab[Column] owning the column data.
        _num_rows: Number of rows in this batch.
        _selection_mask: Optional row-level filter (late materialization).
            When `Some`, the batch carries a filter that downstream
            operators MUST honor — only rows where the bit is set are
            "live"; the rest are logically dropped. The full column
            payload is still present (no gather has been performed).
            This is the high-selectivity short-circuit added by
            `_decode_with_late_mat`: when a filter survives >=95% of
            rows, the per-RG `gather_batch(filter)` + `gather_batch
            (payload)` pair is skipped (saves O(N×ncols×elem_size)
            memcpy) and the mask is plumbed instead.

            Consumers of `RecordBatch` MUST either:
              (a) honor the mask natively in their per-row loop, or
              (b) call `materialize_selection_if_present()` at entry
                  to perform the gather and clear the mask (default
                  defensive behavior; preserves correctness at the
                  cost of moving the gather to the consumer site).

            Default: `None` (no mask, all rows live).
    """

    var schema: Schema
    var _columns: Slab[Column[HeapRegion]]
    var _num_rows: Int
    var _selection_mask: Optional[BooleanArray]

    def __init__(out self):
        """Create an empty RecordBatch."""
        self.schema = Schema()
        self._columns = Slab[Column[HeapRegion]]()
        self._num_rows = 0
        self._selection_mask = Optional[BooleanArray](None)

    # --- Type-erased constructors (Column-based) ---

    @staticmethod
    def from_columns_0(var schema: Schema) raises -> RecordBatch:
        """Construct a RecordBatch from an empty schema (zero columns, zero rows)."""
        if schema.num_columns() != 0:
            raise Error(
                "RecordBatch.from_columns_0: schema has "
                + String(schema.num_columns())
                + " fields, expected 0"
            )
        var batch = RecordBatch()
        batch.schema = schema^
        return batch^

    @staticmethod
    def empty_from_schema(var schema: Schema) raises -> RecordBatch:
        """A ZERO-ROW batch that still carries its FULL schema — the canonical
        "an empty result still has a schema" shape.

        WHY THIS EXISTS. `RecordBatch.num_columns()`
        reads `len(self._columns)` — the PHYSICAL column count — NOT
        `schema.num_columns()`. So the idiom at the empty
        early-returns of a materialize path,

            var empty = RecordBatch()
            empty.schema = authoritative_schema^   # schema FIELD set …
            return empty^                          # … _columns still EMPTY

        produces an INTERNALLY INCONSISTENT batch: an N-field schema over zero
        physical columns. Every consumer that iterates
        `range(rb.num_columns())` — the Arrow egress surfaces, a parquet
        writer, a result printer — therefore saw a 0-COLUMN result for a query
        whose predicate merely happened to match nothing: 0 rows, but 0
        columns where the query has 3.

        That is a product defect. Every Arrow egress
        contract requires the schema BEFORE the rows and requires it STABLE: the
        C Data Interface answers `get_schema` before the first `get_next` and
        specifies "the schema is the same for all data chunks"; IPC streaming
        puts the schema first and holds it; Flight returns `FlightInfo.schema`
        from `GetFlightInfo` (i.e. before `DoGet` runs) and has a dedicated
        `GetSchema` RPC. A 0-column empty batch cannot satisfy a consumer that
        already read an N-column schema.

        This constructor makes "zero rows WITH a schema" REPRESENTABLE: it
        materializes one zero-length `Column` per field, typed by that field's
        `ArrowType`, so `num_columns() == schema.num_columns()` holds and the
        batch is consistent under both accessors.

        A zero-length schema is still legal and yields the plain empty batch
        (the `SELECT COUNT(*)`-shaped zero-column contract that
        `count_only` / `from_columns_0` rely on is untouched).

        KNOWN NARROWING: `Column`'s decimal precision/scale and dictionary
        value-type are private to `column.mojo`, so a zero-length DECIMAL /
        DICTIONARY column carries the type tag but not those parameters. They
        remain available on the returned batch's `schema` `Field`
        (`decimal_precision` / `decimal_scale` / `_dict_index_type`), which is
        what an egress consumer reads.

        ⛔ THE COLUMN-SIDE PARAMETER STILL MATTERS AT ZERO ROWS:
        `Column.as_decimal128` / `as_decimal256` RAISE on a column with no
        precision BEFORE they look at the length, so any reader that asks for
        the typed view of one of these columns refuses on zero rows (e.g. a
        grouped median over an empty DECIMAL file). A reader of a zero-length
        DECIMAL column from here must not ask for the typed view (or must read
        (p, s) off the schema `Field`).
        """
        var n = schema.num_columns()
        if n == 0:
            var bare = RecordBatch()
            bare.schema = schema^
            return bare^
        var columns = Slab[Column[HeapRegion]].create(n)
        for i in range(n):
            columns.append(_zero_length_column(schema.field_arrow_type(i)))
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = 0
        return batch^

    @staticmethod
    def count_only(num_rows: Int) raises -> RecordBatch:
        """Stream AQ: synthetic zero-column batch that carries only a row
        count. Used by the PLAIN filter-count fast path
        (`_decode_with_late_mat` under count-only hook) to skip the
        `filter_to_indices` + `gather_batch` + column-level concat work
        when the downstream sink is an ungrouped `count(*)` that reads
        only `num_rows`. Safe because the ParquetCollectSink concat
        codepath and `_execute_agg_sink_no_keys` count-star fast path
        both handle `num_columns() == 0` explicitly.
        """
        var batch = RecordBatch()
        batch._num_rows = num_rows
        return batch^

    @staticmethod
    def from_typed_columns_1(
        var schema: Schema,
        var col0: Column[HeapRegion],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and 1 type-erased Column."""
        if schema.num_columns() != 1:
            raise Error(
                "RecordBatch.from_typed_columns_1: schema has "
                + String(schema.num_columns())
                + " fields, expected 1"
            )
        var num_rows = col0.length()
        var columns = Slab[Column[HeapRegion]].create(1)
        columns.append(col0^)
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    @staticmethod
    def from_typed_columns_2(
        var schema: Schema,
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and 2 type-erased Columns."""
        if schema.num_columns() != 2:
            raise Error(
                "RecordBatch.from_typed_columns_2: schema has "
                + String(schema.num_columns())
                + " fields, expected 2"
            )
        if col0.length() != col1.length():
            raise Error(
                "RecordBatch.from_typed_columns_2: column lengths differ: "
                + String(col0.length()) + " vs " + String(col1.length())
            )
        var num_rows = col0.length()
        var columns = Slab[Column[HeapRegion]].create(2)
        columns.append(col0^)
        columns.append(col1^)
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    @staticmethod
    def from_typed_columns_3(
        var schema: Schema,
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
        var col2: Column[HeapRegion],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and 3 type-erased Columns."""
        if schema.num_columns() != 3:
            raise Error(
                "RecordBatch.from_typed_columns_3: schema has "
                + String(schema.num_columns())
                + " fields, expected 3"
            )
        var num_rows = col0.length()
        if col1.length() != num_rows or col2.length() != num_rows:
            raise Error("RecordBatch.from_typed_columns_3: column lengths differ")
        var columns = Slab[Column[HeapRegion]].create(3)
        columns.append(col0^)
        columns.append(col1^)
        columns.append(col2^)
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    @staticmethod
    def from_typed_columns_4(
        var schema: Schema,
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
        var col2: Column[HeapRegion],
        var col3: Column[HeapRegion],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and 4 type-erased Columns.

        Mirror of `from_typed_columns_3` extended to 4-column payload arity
        for the variable-N drain path. Lengths must agree (raises on mismatch).
        """
        if schema.num_columns() != 4:
            raise Error(
                "RecordBatch.from_typed_columns_4: schema has "
                + String(schema.num_columns())
                + " fields, expected 4"
            )
        var num_rows = col0.length()
        if (
            col1.length() != num_rows
            or col2.length() != num_rows
            or col3.length() != num_rows
        ):
            raise Error("RecordBatch.from_typed_columns_4: column lengths differ")
        var columns = Slab[Column[HeapRegion]].create(4)
        columns.append(col0^)
        columns.append(col1^)
        columns.append(col2^)
        columns.append(col3^)
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    @staticmethod
    def from_typed_columns_slab(
        var schema: Schema,
        var columns: Slab[Column[HeapRegion]],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and a pre-built Slab[Column[HeapRegion]].

        Generalized form of the per-arity `from_typed_columns_N` ladder
        for sites whose column arity is runtime-N (drain sites in
        the engine runtime for variable-payload joins). Mojo cannot express a variadic of a single non-Copyable type (`Column` is
        Movable-only), so the canonical generalization is `Slab[Column]` (the
        same backing storage `from_typed_columns_3` builds internally).

        Lengths must all agree; raises with a precise mismatch report on
        violation.
        """
        var n = schema.num_columns()
        if columns.len() != n:
            raise Error(
                "RecordBatch.from_typed_columns_slab: column count "
                + String(columns.len())
                + " != schema columns "
                + String(n)
            )
        if n == 0:
            var batch = RecordBatch()
            batch.schema = schema^
            batch._columns = columns^
            batch._num_rows = 0
            return batch^
        var num_rows = columns[0].length()
        for i in range(1, n):
            if columns[i].length() != num_rows:
                raise Error(
                    "RecordBatch.from_typed_columns_slab: column lengths"
                    " differ (col 0 has " + String(num_rows)
                    + " rows, col " + String(i) + " has "
                    + String(columns[i].length()) + ")"
                )
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    # --- Backward-compatible constructors (PrimitiveArray[int64]) ---

    @staticmethod
    def from_columns_1(
        var schema: Schema,
        var col0: PrimitiveArray[DType.int64],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and 1 int64 column (backward compat)."""
        if schema.num_columns() != 1:
            raise Error(
                "RecordBatch.from_columns_1: schema has "
                + String(schema.num_columns())
                + " fields, expected 1"
            )
        var num_rows = col0.length
        var columns = Slab[Column[HeapRegion]].create(1)
        columns.append(Column.from_primitive[DType.int64](col0^))
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    @staticmethod
    def from_columns_2(
        var schema: Schema,
        var col0: PrimitiveArray[DType.int64],
        var col1: PrimitiveArray[DType.int64],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and 2 int64 columns (backward compat)."""
        if schema.num_columns() != 2:
            raise Error(
                "RecordBatch.from_columns_2: schema has "
                + String(schema.num_columns())
                + " fields, expected 2"
            )
        if col0.length != col1.length:
            raise Error(
                "RecordBatch.from_columns_2: column lengths differ: "
                + String(col0.length) + " vs " + String(col1.length)
            )
        var num_rows = col0.length
        var columns = Slab[Column[HeapRegion]].create(2)
        columns.append(Column.from_primitive[DType.int64](col0^))
        columns.append(Column.from_primitive[DType.int64](col1^))
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    @staticmethod
    def from_columns_3(
        var schema: Schema,
        var col0: PrimitiveArray[DType.int64],
        var col1: PrimitiveArray[DType.int64],
        var col2: PrimitiveArray[DType.int64],
    ) raises -> RecordBatch:
        """Construct a RecordBatch from a schema and 3 int64 columns (backward compat)."""
        if schema.num_columns() != 3:
            raise Error(
                "RecordBatch.from_columns_3: schema has "
                + String(schema.num_columns())
                + " fields, expected 3"
            )
        var num_rows = col0.length
        if col1.length != num_rows or col2.length != num_rows:
            raise Error("RecordBatch.from_columns_3: column lengths differ")
        var columns = Slab[Column[HeapRegion]].create(3)
        columns.append(Column.from_primitive[DType.int64](col0^))
        columns.append(Column.from_primitive[DType.int64](col1^))
        columns.append(Column.from_primitive[DType.int64](col2^))
        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = num_rows
        return batch^

    # --- Accessors ---

    @always_inline
    def num_columns(self) -> Int:
        return len(self._columns)

    @always_inline
    def num_rows(self) -> Int:
        return self._num_rows

    def to_record_batch(var self) raises -> RecordBatch:
        """Identity conversion -- returns `self`, MOVED. Zero copy, zero work.

        `Table.to_record_batch()` (`table.mojo`) is the real conversion: it
        CONCATENATES a chunked result into one buffer. This spelling lets a
        call site write `.to_record_batch()` against either a `RecordBatch`
        or a `Table` result with byte-identical obligations.

        ⭐ THE SIGNATURE IS COPIED FROM `Table.to_record_batch`, DELIBERATELY,
        AND MUST STAY COPIED. `var self` + `raises` + `-> RecordBatch` is what
        makes the CALL SITE's obligations identical for both receivers. Drop
        `raises` and a site inside a non-raising `fn` compiles against a
        `RecordBatch` and breaks against a `Table`. Take `self` instead of
        `var self` and it becomes a COPY of the whole result at every site,
        since `RecordBatch` is `Movable` and not `Copyable`; `return self^` is
        a move BY CONSTRUCTION, and a copy would not compile.

        ⚠ Appending `.to_record_batch()` at a site that does NOT need
        contiguity is FREE on a `RecordBatch` and therefore INVISIBLE; on a
        chunked `Table` that same site pays a concat. Call it only where one
        contiguous buffer is genuinely needed.

        Returns:
            `self`, moved. The same buffers, at the same addresses.
        """
        return self^

    @always_inline
    def column_at(self, index: Int) -> ref [self._columns._bytes] Column[HeapRegion]:
        """Return a safe reference to the Column[HeapRegion] at `index`.

        The reference's lifetime is tied to this RecordBatch's column storage.
        Preferred over _column_ref() for all new code.

        Args:
            index: Zero-based column index.

        Returns:
            An immutable reference to the Column.
        """
        return self._columns[index]

    def content_hash(self, seed: UInt64) -> UInt64:
        """Fold this batch's CONTENT into a running FNV-1a hash, returning the
        updated accumulator.

        Content = the schema text (`Schema.write_to` — field names, arrow
        types, nullability), the row count, and every column's
        `Column.content_hash` (the raw buffer bytes + per-column structural
        metadata), folded in column order.

        This is the per-batch half of the **content-derived structural
        identity** that `InMemorySource.structural_id()` folds across batches
        and that `plan_display` emits in place of the per-ctor unique
        `fingerprint()` for an in-memory scan. Two batches built from
        byte-identical schema + data hash equal (so two structurally-identical
        in-mem plans dedup / cache-hit); two batches that differ in any
        field name, type, or value byte hash differently (so CSE never merges
        two genuinely-distinct in-mem tables into a false self-join).

        The selection mask is NOT folded: an in-memory source carries its
        batches mask-free (the mask is a transient decode-time lever), so it
        is not part of the source's structural identity.
        """
        comptime prime = UInt64(0x00000100000001B3)
        var h = seed
        # Schema text — captures field names + types + nullability (the
        # discriminator that distinguishes e.g. `left_val`/`right_val`).
        var schema_text = String("")
        schema_text.write(self.schema)
        var sb = schema_text.as_bytes()
        for i in range(len(sb)):
            h = (h ^ UInt64(sb[i])) * prime
        h = (h ^ UInt64(self._num_rows)) * prime
        for i in range(len(self._columns)):
            h = self._columns[i].content_hash(h)
        return h

    def take_columns(mut self) -> Slab[Column[HeapRegion]]:
        """Move the Column[HeapRegion] slab out of this RecordBatch.

        Hot-path
        helper for `accept_arrow*` write-side callers that have ownership
        of the RecordBatch and want to feed its columns into
        `encode_record_batch_message` without deep-copying them (a
        `col.deep_copy()` loop is roughly a third of the uncompressed write
        wall).

        After this call, `self._columns` is an empty `Slab[Column]` and
        `self.num_columns() == 0`; the caller now owns the moved-out
        slab. `self._num_rows` and `self.schema` are unchanged — only
        the column storage is moved.

        Safety:
            Uses stdlib `swap` to exchange `self._columns` with a fresh
            empty `Slab[Column]`. This is NOT a partial-move-via-
            UnsafePointer (Hard ban #11) — both sides are valid Slabs
            before and after; the swap leaves `self` in a
            destructor-safe state (an empty slab drops cleanly).

        Returns:
            The previously-held `Slab[Column]`. Caller owns it.
        """
        var out = Slab[Column[HeapRegion]]()
        swap(self._columns, out)
        return out^

    def append_column(
        mut self, field: Field, var col: Column[HeapRegion]
    ) raises -> None:
        """Append one column (with its schema `field`) to this batch in place.

        GLOB-G.8: the partition-column materialization appends K
        constant columns to each decoded data batch. The new column's length
        must match the batch's row count (or the batch must be empty, in which
        case the column's length defines the row count). Both the schema and
        the column storage grow by one.
        """
        if self.num_columns() > 0 and col.length() != self._num_rows:
            raise Error(
                String("RecordBatch.append_column: column length ")
                + String(col.length())
                + " != batch row count "
                + String(self._num_rows)
            )
        if self.num_columns() == 0:
            self._num_rows = col.length()
        # Rebuild the schema with the existing fields + the appended field.
        var sb = SchemaBuilder()
        var nc = self.schema.num_columns()
        for i in range(nc):
            sb.add_field(self.schema.field_at(i))
        sb.add_field(field)
        self.schema = sb.build()
        self._columns.append(col^)

    @always_inline
    def _columns_ptr(self) -> UnsafePointer[Column[HeapRegion], MutUntrackedOrigin]:
        """Return a raw pointer to the base of the column array.

        INTERNAL: prefixed with _ to indicate unsafe escape hatch. Prefer
        column_at() for safe access. Only use this for zero-copy view patterns
        (MorselView) that need a non-owning pointer to the column storage
        for the lifetime of parallel processing.

        SAFETY: The returned pointer is valid as long as this RecordBatch
        is alive. Do NOT free or modify the pointer. The RecordBatch owns
        the column storage.

        NOTE: `Slab._unsafe_ptr` is origin-tied (returns a `self`-bound
        pointer, so `rb`'s lifetime is not severed). This accessor keeps an
        untracked return for its existing parallelize-view callers
        (group_ref / row / MorselView) by re-casting to MutExternalOrigin
        here. Those callers already uphold the liveness contract manually
        (the RecordBatch outlives the view). Prefer `_column_ref` (origin-
        tied) for new call sites.
        """
        return self._columns._unsafe_ptr().unsafe_mut_cast[
            True
        ]().unsafe_origin_cast[MutUntrackedOrigin]()

    def _column_ref[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self, index: Int) raises -> UnsafePointer[Column[HeapRegion], o]:
        """Return a pointer to the Column[HeapRegion] at `index` with
        ORIGIN TIED to this RecordBatch.

        A wildcard-origin return (`UnsafePointer[..., MutExternalOrigin]`)
        would sever the lifetime tie to `self`: the compiler could ASAP-drop
        `self` between the call and the pointer's first use, yielding a
        use-after-free (heap-pointer-garbage reads under AOT).

        Origin `o` is inferred from the receiver borrow, binding the
        returned pointer's lifetime to `self` — the compiler now tracks
        deref sites against `self`'s liveness.

        Prefer `column_at()` for safe ref-returning access; this method
        retained for hot-path call sites that need pointer semantics.

        SAFETY: pointer valid for the duration of `self`'s borrow `o`.
        """
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch._column_ref: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        return self._columns._mut_ptr(index).unsafe_mut_cast[
            _mut
        ]().unsafe_origin_cast[o]()

    def column_arrow_type(self, index: Int) raises -> ArrowType:
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_arrow_type: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        var schema_type = self.schema.field_arrow_type(index)
        var column_type = self._columns[index].arrow_type
        if column_type != schema_type:
            # The READ-ONLY twin of `_ensure_column_type`'s rewrite: handing
            # back `schema_type` for a column that is physically something
            # else mis-routes every caller that dispatches on the result.
            # Same predicate, same reason.
            self._reject_layout_conflict(
                index, column_type, schema_type, "column_arrow_type"
            )
            print(
                "WARNING: Column.arrow_type mismatch at index "
                + String(index)
                + ": column has "
                + String(column_type)
                + " but schema says "
                + String(schema_type)
                + ". Using schema type (likely Column[HeapRegion] move corruption)."
            )
        return schema_type

    def column_by_index(self, index: Int) raises -> Int:
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_by_index: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        return self._columns[index]._length

    def column_value(self, col_index: Int, row_index: Int) raises -> Scalar[DType.int64]:
        if col_index < 0 or col_index >= len(self._columns):
            raise Error(
                "RecordBatch.column_value: col_index "
                + String(col_index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(col_index)
        var arr = self._columns[col_index].as_primitive[DType.int64]()
        return arr.get(row_index)

    def _reject_layout_conflict(
        self,
        index: Int,
        column_type: ArrowType,
        schema_type: ArrowType,
        site: String,
    ) raises:
        """RAISE when the Column and the Schema disagree about the BUFFER
        LAYOUT, rather than resolving the disagreement in the Schema's favour.

        ⚠ THIS IS DELIBERATELY NARROWER THAN "the types differ", AND THE
        NARROWNESS IS THE WHOLE DESIGN. `_ensure_column_type` is a heuristic
        recovery — one of three layered workarounds for a `Column` MOVE defect
        whose root cause is not established. Nothing establishes that defect
        as fixed, so the recovery it provides must not be removed. See the STATUS block on
        `_ensure_column_type` below.

        The bug's signature is what makes the split possible: the move defect
        **zeroes** the tag (it "reads as 0 (which maps to `ArrowType.NULL`)").
        It does not rewrite `STRING` into `LARGE_STRING`, and it cannot turn a
        `DICTIONARY` column into a `STRING` one. So:

        * tag is `NULL`, schema is concrete → repair, as before. This is the
          move-bug signature; `test_heuristic_recovery_null_type` and
          `test_heuristic_recovery_string_type` pin it and MUST stay green.
        * both concrete, SAME physical-layout class (`DATE32` vs `INT32`,
          `TIMESTAMP_US` vs `INT64`) → repair, as before. A relabel across
          identical buffers reads the same bytes; the tree does this
          deliberately in `compiler_eval_column.mojo` and
          `parquet/decode_helpers.mojo`.
        * both concrete, DIFFERENT physical-layout class → **RAISE**. The
          move bug cannot produce this, and resolving it silently is a
          reinterpretation of the buffers:
            - `DICTIONARY` under `STRING` reads int32 dictionary CODES as
              per-row string offsets — the B-5 P0 (`tests/test_b5_segfault.mojo`);
            - `LARGE_STRING` under `STRING` reads int64 offsets as int32.

        `layouts_conflict` returns False whenever either side's layout is not
        determined by the tag alone, so a type this file does not model can
        never make this raise.

        Args:
            index: Column index, for the message.
            column_type: The tag the Column actually carries.
            schema_type: The tag the Schema claims.
            site: Accessor name, so the message names the caller.

        Raises:
            Error naming both types and both layout classes, when they
            conflict.
        """
        if not layouts_conflict(column_type, schema_type):
            return
        raise Error(
            "RecordBatch."
            + site
            + ": PHYSICAL LAYOUT CONFLICT at column index "
            + String(index)
            + " (name '"
            + self.schema.field_name(index)
            + "'): the Column carries "
            + String(column_type)
            + " (layout class "
            + String(column_type.physical_layout_class())
            + ") but the Schema says "
            + String(schema_type)
            + " (layout class "
            + String(schema_type.physical_layout_class())
            + "). These describe DIFFERENT buffer layouts, so resolving the"
            + " disagreement in the Schema's favour would reinterpret the"
            + " column's buffers — e.g. int32 dictionary codes read as string"
            + " offsets (the B-5 segfault), or int64 LARGE_STRING offsets read"
            + " as int32. This is NOT the Column-move signature (which zeroes"
            + " the tag to NULL and is still repaired); the producer of this"
            + " batch built a Schema that does not describe its Columns."
        )

    def _ensure_column_type(self, index: Int) raises:
        """Repair a `Column.arrow_type` that disagrees with the Schema.

        ★ STATUS OF THE `Column` MOVE BUG, stated because this method exists
        only as a workaround for it:

        **NOT ESTABLISHED AS FIXED. The workarounds stay.** The other two
        workarounds (`with_capacity` everywhere in the Parquet reader;
        schema-authoritative lookup) are still in place, and a use-after-free
        keepalive fix in the Parquet batch reader is a different defect that
        cannot explain a zeroed type tag on a column that never went through
        the Parquet reader. No test observes the corruption arising on its own; the two `test_heuristic_recovery_*`
        tests INJECT it by writing `arrow_type` directly. So the evidence
        establishes neither "fixed" nor "still live", and the correct posture
        for an unfalsified silent-corruption defence is to keep it.

        What CHANGED here is only the case the move bug cannot produce: a
        mismatch across a physical-layout class. See `_reject_layout_conflict`.
        """
        var schema_type = self.schema.field_arrow_type(index)
        var column_type = self._columns[index].arrow_type
        if column_type != schema_type:
            self._reject_layout_conflict(
                index, column_type, schema_type, "_ensure_column_type"
            )
            print(
                "WARNING: Repairing Column.arrow_type at index "
                + String(index)
                + ": was "
                + String(self._columns[index].arrow_type)
                + ", setting to "
                + String(schema_type)
                + " (from Schema)"
            )
            # SAFETY: interior mutability under immutable-receiver.
            # `_ensure_column_type` takes `self` (immutable) to preserve
            # the read-only API of the surrounding `column_as_*` /
            # `column_value` accessors that call into it — making this
            # method `mut self` would cascade `mut` through those
            # accessors and every downstream caller (cross-module: engine
            # streaming_s3_agg.mojo takes `read batch: RecordBatch`).
            # ⚠ This is NOT "interior mutation that does not observe outside
            # the method call and cannot race":
            #   * The write DOES observe outside the call. It persists on the
            #     batch — that is the whole point, so the next accessor sees
            #     a repaired tag instead of repairing it again. What is true
            #     is the weaker claim that the repair is IDEMPOTENT and
            #     converges to the Schema's value, so a second observer sees
            #     the same result the first one did.
            #   * "cannot race" is not established. Whether a RecordBatch
            #     reaches a worker thread through a `column_as_*` accessor is
            #     an ASSUMPTION about every present and future caller of a
            #     public method, which is not a property this file can hold.
            #     The narrowing above is what makes the residual
            #     exposure small: after it, the only value this can ever
            #     write is one that reads the SAME buffers the same way.
            # Load-bearing wildcard: immutable-self + interior write → keep
            # wildcard, annotate.
            self._columns._mut_ptr(index)[].arrow_type = schema_type

    def column_as_dictionary(self, index: Int) raises -> StringDictionaryArray:
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_as_dictionary: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].as_dictionary()

    def column_as_string(self, index: Int) raises -> StringArray[HeapRegion]:
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_as_string: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        # ⚠ ORDER IS the DICTIONARY branch below
        # runs BEFORE `_ensure_column_type`, not after. With the repair first,
        # a DICTIONARY Column under a Schema that says STRING had its tag
        # stamped to STRING, this branch became unreachable, and the fallthrough
        # `as_string()` read the dictionary's offsets buffer as if it held
        # `_length + 1` per-row offsets — a SEGFAULT, whose fix established that the COLUMN
        # is authoritative over the Schema for exactly this pair. Decoding the
        # dictionary honours that; it is also what makes the layout-conflict
        # guard in `_ensure_column_type` a no-op for the one cross-class
        # mismatch the Parquet reader legitimately produces (BYTE_ARRAY -> the
        # Schema says STRING, `preserve_dict=True` -> the Column is DICTIONARY).
        #
        # DICTIONARY<STRING> decode-to-STRING. A DICTIONARY-encoded
        # column read through the STRING accessor (the typed-join build-payload
        # / probe-passthrough FEED and the byte-keyed AGG feed both reach the
        # source column via `column_as_string`) is transparently decoded to a
        # dense StringArray: resolve each row's dictionary entry via
        # `StringDictionaryArray.get(row)` (rather than raising
        # `Column.as_string: arrow_type is dictionary`). Null rows (indices
        # validity bit clear) emit an empty placeholder + invalid validity so
        # the downstream StringArray carries the null bitmap.
        if self._columns[index].arrow_type == ArrowType.DICTIONARY:
            var dict_arr = self._columns[index].as_dictionary()
            var n = len(dict_arr)
            var vals = List[String](capacity=n)
            var valids = List[Bool](capacity=n)
            var any_null = False
            var has_validity = dict_arr.indices.validity.__bool__()
            for r in range(n):
                var is_valid = (
                    dict_arr.indices.validity.value().test(r)
                    if has_validity else True
                )
                if not is_valid:
                    vals.append(String(""))
                    valids.append(False)
                    any_null = True
                else:
                    vals.append(dict_arr.get(r))
                    valids.append(True)
            if any_null:
                return StringArray.from_strings_with_validity(vals, valids)
            return StringArray.from_strings(vals)
        # ★ LARGE_STRING -> NARROW, WHEN AND ONLY WHEN IT PROVABLY FITS.
        #
        # An output string column is promoted to Int64 offsets when its bytes
        # pass the int32 ceiling; without this arm every call site of THIS
        # accessor would raise `Column.as_string: arrow_type is large_string`.
        # That is a fail-CLOSED refusal, so no wrong answer — but a promoted
        # result would be unreadable by CSV, JSON, Avro, ORC, Parquet,
        # `df.show()` and the eval layer alike. SQL and Python users must get
        # data they can read.
        #
        # Narrowing is LOSSLESS exactly when `data_length <= INT32_MAX`: the
        # value bytes are untouched and each offset is re-expressed at a width
        # that still represents it. Promotion is decided on the WHOLE result's
        # byte total, and a batch/slice/aggregate downstream of it is routinely
        # far smaller, so this arm is the common case, not a corner.
        #
        # ⛔ IT MUST NEVER TRUNCATE. Above the ceiling we RAISE, naming
        # `column_as_large_string` — the accessor whose return type can hold
        # the answer. Silently wrapping the offsets here would put back the
        # exact int32 overflow the promotion abolished, with the guard gone.
        #
        # ⚠ AN ACCESSOR GAINING AN ARM DOES NOT WIDEN THE CALLERS THAT NEVER
        # GO THROUGH THAT ACCESSOR. The Parquet writer's string arm reads the
        # COLUMN-level `as_string()`, which has no narrowing arm and refuses
        # `large_string` at ANY size; it needs (and has) its own int64-offset
        # arm in `_encode_column_to_page`. "N call sites are fixed" is a claim
        # about the sites, and it has to be checked per site.
        if self._columns[index].arrow_type == ArrowType.LARGE_STRING:
            self._ensure_column_type(index)
            var wide = self._columns[index].as_large_string()
            if wide.data_length > ARROW_INT32_OFFSET_MAX:
                raise Error(
                    "RecordBatch.column_as_string: column "
                    + String(index)
                    + " is large_string with "
                    + String(wide.data_length)
                    + " bytes of data, which cannot be represented with int32"
                    " offsets (ceiling "
                    + String(ARROW_INT32_OFFSET_MAX)
                    + "). Use column_as_large_string(index) — narrowing here"
                    " would wrap the offsets and produce wrong values."
                )
            var n = wide.length
            comptime int32_size = size_of[Int32]()
            var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
            for r in range(n + 1):
                offsets_buf.set_typed[Int32](
                    r, Int32(Int(wide.offsets.get_typed[Int64](r)))
                )
            offsets_buf.set_length(Int64((n + 1) * int32_size))

            var data_buf = OwnedAlignedBuffer(max(wide.data_length, 1))
            if wide.data_length > 0:
                data_buf.copy_from_view(
                    wide.data.view_range_ro(0, wide.data_length)
                )
            data_buf.set_length(Int64(wide.data_length))

            var validity = Optional[Bitmap[HeapRegion]](None)
            if wide.validity:
                var bm_len = wide.validity.value().length
                var bm = Bitmap.create(bm_len)
                var bm_bytes = (bm_len + 7) >> 3
                if bm_bytes > 0:
                    bm.buffer.copy_from_view(
                        wide.validity.value().buffer.view_range_ro(0, bm_bytes)
                    )
                    bm.buffer.set_length(bm_bytes)
                validity = bm^

            return StringArray[HeapRegion](
                offsets=offsets_buf^,
                data=data_buf^,
                validity=validity^,
                length=n,
                data_length=wide.data_length,
                null_count=wide.null_count,
            )
        self._ensure_column_type(index)
        return self._columns[index].as_string()

    def column_as_large_string(
        self, index: Int
    ) raises -> LargeStringArray[HeapRegion]:
        """The Int64-offset twin of `column_as_string` — the accessor a
        PROMOTED string column can always be read through, at any size.

        ⚠ THIS IS THE ONE THAT CANNOT REFUSE ON SIZE, AND THAT IS WHY IT
        EXISTS. `column_as_string` narrows a `large_string` column when the
        bytes fit int32 and raises when they do not; a sink that must work on
        the 2 GiB+ column that CAUSED the promotion has to come through here.
        Every bulk text/file sink therefore branches on the column's own tag
        rather than funnelling both widths into the narrow accessor.

        Unlike `column_as_string` there is deliberately NO DICTIONARY decode
        arm: no producer in this tree emits a DICTIONARY column under a
        `large_string` field, so an arm for it would be untested code claiming
        a capability nothing exercises.

        Args:
            index: Zero-based column index.

        Returns:
            A LargeStringArray copy of the column's buffers.

        Raises:
            Error if `index` is out of range or the column is not LARGE_STRING.
        """
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_as_large_string: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].as_large_string()

    def column_as_binary(self, index: Int) raises -> BinaryArray[HeapRegion]:
        # typed BINARY
        # accessor mirroring column_as_string. Delegates to the existing
        # Column.as_binary() (column.mojo) which reconstructs a BinaryArray
        # (offsets + data + validity) — BINARY is STRING without UTF-8
        # validation, so the buffer layout is identical.
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_as_binary: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].as_binary()

    def column_as_primitive[
        dtype: DType
    ](self, index: Int) raises -> PrimitiveArray[dtype]:
        """Copy column `index` out as a `PrimitiveArray[dtype]`, at ANY storage
        DType `Column.as_primitive` accepts.

        ★ THIS IS THE ONE IMPLEMENTATION; the four `column_as_primitive_<t>`
        accessors below are one-line delegations to it. With only per-width
        copies, a fold whose gate ADMITS i8 / i16 / u8 / u16 / u32 / u64 has
        to route every non-INT64 width through the INT32 accessor and RAISES
        `Column.as_primitive: arrow_type mismatch` on
        `SELECT sum(<int16 col>) FROM t`. A parametric accessor cannot
        develop that hole: a caller asks for the width it measured.

        ⚠ IT KEEPS `_ensure_column_type`, AND THAT IS WHY IT IS HERE RATHER
        THAN AT THE CALLER. Reaching the Column directly
        (`batch.column_at(i).as_primitive[dt]()`) reads the UNREPAIRED
        `Column.arrow_type` and so bypasses the Column-move workaround every
        accessor on this struct runs first — see `_ensure_column_type`'s own
        docstring ("NOT ESTABLISHED AS FIXED. The workarounds stay.") and the
        zero-copy block below, which states the same rule for the share twins.

        Parameters:
            dtype: The storage DType to read the column as. `Column.as_primitive`
                admits the storage-compatible temporal aliases too (DATE32 /
                TIME32_* / INTERVAL_YEAR_MONTH as int32; DATE64 / TIMESTAMP* /
                TIME64_* / DURATION_* / INTERVAL_DAY_TIME as int64), which is
                what lets a MIN/MAX fold read a date without a per-logical-type
                reader.

        Args:
            index: The column index.

        Returns:
            A new PrimitiveArray holding a copy of this column's window.

        Raises:
            Error if `index` is out of range, or if the column's storage DType
            is not compatible with `dtype`.
        """
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_as_primitive: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].as_primitive[dtype]()

    def column_as_primitive_int32(self, index: Int) raises -> PrimitiveArray[DType.int32]:
        return self.column_as_primitive[DType.int32](index)

    def column_as_primitive_int64(self, index: Int) raises -> PrimitiveArray[DType.int64]:
        return self.column_as_primitive[DType.int64](index)

    def column_as_primitive_float64(self, index: Int) raises -> PrimitiveArray[DType.float64]:
        return self.column_as_primitive[DType.float64](index)

    # Typed Float32 accessor; mirror of column_as_primitive_float64 above.
    def column_as_primitive_float32(self, index: Int) raises -> PrimitiveArray[DType.float32]:
        return self.column_as_primitive[DType.float32](index)

    # =========================================================================
    # ZERO-COPY twins of the four `column_as_primitive_*` accessors above.
    #
    # ⚠ THEY EXIST FOR ONE REASON: `_ensure_column_type`. A caller that reaches
    # the Column directly — `batch.column_at(i).can_share_as_primitive[dt]()` —
    # reads the UNREPAIRED `Column.arrow_type` and so BYPASSES the Column-move
    # workaround every copy accessor above runs first. That is not a stylistic
    # difference. Under a corrupted tag the bypass changes behaviour TWICE over:
    # `can_share_as_primitive` compares the corrupt tag and declines, and the
    # decline path — `Column.as_primitive` called directly — RAISES on the
    # mismatch where `RecordBatch.column_as_primitive_*` would have repaired the
    # tag from the Schema and proceeded. A working query becomes an error, in
    # BOTH gate arms, which would also destroy the OFF-arm identity any A/B of
    # the sharing gate rests on.
    #
    # `_ensure_column_type`'s own docstring states the move bug is "NOT
    # ESTABLISHED AS FIXED. The workarounds stay." — so the correct posture for
    # a new accessor is to inherit the defence, not to route around it.
    #
    # PARAMETRIC, unlike the four monomorphic copy accessors above: those
    # predate `Column.as_primitive`'s comptime dtype parameter and were never
    # collapsed. There is no reason to add eight more hand-written methods.
    # =========================================================================

    def column_can_share_as_primitive[dtype: DType](self, index: Int) raises -> Bool:
        """True iff `column_share_as_primitive[dtype](index)` may serve column
        `index` — after repairing a Schema-disagreeing `Column.arrow_type`, which
        is the whole reason to ask through the RecordBatch rather than the
        Column. Raises only on an out-of-range index or a layout conflict."""
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_can_share_as_primitive: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].can_share_as_primitive[dtype]()

    def column_share_as_primitive[dtype: DType](self, index: Int) raises -> PrimitiveArray[dtype]:
        """Arc-SHARE column `index`'s value buffer as a `PrimitiveArray[dtype]` —
        the zero-copy twin of `column_as_primitive_*`, for a caller that has
        AUDITED its consumers to be read-only.

        Repairs the column's `arrow_type` from the Schema first (see the block
        above). Raises if the share gate does not hold, so a misuse is LOUD —
        check `column_can_share_as_primitive[dtype](index)` and fall back to
        `column_as_primitive_*` for the copy.

        CALLER'S OBLIGATION is `Column.share_as_primitive`'s, unchanged and not
        weakened by going through the batch: under sharing, a consumer that
        MUTATES the result in place (`set` / `set_valid` / `set_null` /
        `view_mut` / `_unsafe_data_ptr`) writes THROUGH to the source column."""
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_share_as_primitive: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].share_as_primitive[dtype]()

    def column_share_decline_reason[dtype: DType](self, index: Int) raises -> String:
        """WHY column `index` cannot be shared as `dtype` — `""` when it CAN.

        A share that declines is free and silent-safe, which is exactly why a
        decline COUNT alone is an ambiguous diagnostic: `can_share_as_primitive`
        has TWO independent refusal conditions (a validity bitmap; an arrow_type
        not storage-compatible with `dtype`) and they route to different defects.
        A fire set that reads only "k of n shared" has to ATTRIBUTE the shortfall,
        and attribution by assumption is how a diagnosis goes wrong. This
        returns the reason so the run states it instead."""
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_share_decline_reason: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        ref c = self._columns[index]
        if c.can_share_as_primitive[dtype]():
            return String("")
        if c.has_validity_buffer():
            return String("has_validity")
        return String("type:") + String(c.arrow_type)

    # Typed Boolean accessor; delegates to Column.as_boolean().
    def column_as_boolean(self, index: Int) raises -> BooleanArray:
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_as_boolean: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].as_boolean()

    def column_as_decimal128(self, index: Int) raises -> Decimal128Array[HeapRegion]:
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_as_decimal128: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        self._ensure_column_type(index)
        return self._columns[index].as_decimal128()

    def column_by_name(self, name: String) raises -> Int:
        return self.schema.column_index(name)

    def column_length(self, index: Int) raises -> Int:
        if index < 0 or index >= len(self._columns):
            raise Error(
                "RecordBatch.column_length: index "
                + String(index)
                + " out of range [0, "
                + String(len(self._columns))
                + ")"
            )
        return self._columns[index]._length

    # --- selection-mask accessors (late-materialization short-circuit) ---

    @always_inline
    def has_selection_mask(self) -> Bool:
        """Return True if this batch carries a row-level filter mask.

        See `_selection_mask` field doc for the contract: when True,
        consumers MUST honor the mask (either natively in their per-row
        loop, or via `materialize_selection_if_present` at entry).
        """
        return Bool(self._selection_mask)

    def selection_mask_true_count(self) -> Int:
        """Return the number of live rows under the selection mask, or
        `num_rows()` when no mask is set (no rows masked out)."""
        if not self._selection_mask:
            return self._num_rows
        return self._selection_mask.value().true_count()

    def selection_mask_get(self, row: Int) raises -> Bool:
        """VECTOR-NATIVE INC-2: is `row` LIVE under the selection mask? True (row
        survives) when no mask is set (identity). Used by the typed Stage fold's
        survivor pass to honor a reader-deferred selection WITHOUT gathering."""
        if not self._selection_mask:
            return True
        return self._selection_mask.value().get(row)

    def set_selection_mask(mut self, var mask: BooleanArray) raises:
        """Attach a selection mask. The mask's length must equal num_rows."""
        if mask.length != self._num_rows:
            raise Error(
                "RecordBatch.set_selection_mask: mask length "
                + String(mask.length)
                + " does not match num_rows "
                + String(self._num_rows)
            )
        self._selection_mask = mask^

    def take_selection_mask(mut self) -> Optional[BooleanArray]:
        """Move the selection mask out, leaving None behind."""
        var out = self._selection_mask^
        self._selection_mask = Optional[BooleanArray](None)
        return out^

    def clear_selection_mask(mut self):
        """Drop the selection mask without materializing it. Caller is
        asserting that the mask has already been honored."""
        self._selection_mask = Optional[BooleanArray](None)
