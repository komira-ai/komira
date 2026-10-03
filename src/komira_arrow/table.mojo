# =============================================================================
# Table -- ONE result object that is CHUNKED INSIDE
# =============================================================================
#
# WHY THIS TYPE EXISTS
# --------------------
# A fused parquet join that stitches thousands of per-morsel batches into ONE
# contiguous `RecordBatch` spends a large fraction of its wall in that stitch,
# and the cost is SYNCHRONISATION, not traffic: deleting it saves wall with
# bytes flat. To bank that, the engine must be able to hand back the segments.
#
# ⛔ BUT A LIST IS THE WRONG USER-FACING SHAPE. A user should get one
# collection, not a collection of collections. Both reference implementations
# agree, and NEITHER returns a list:
#
#   DuckDB   `MaterializedQueryResult` owns ONE `unique_ptr<ColumnDataCollection>`;
#            the collection is chunked INTERNALLY -- `ChunkCount()`,
#            `Chunks()`, `segments` (`column_data_collection.hpp`).
#   pyarrow  ONE `Table`, whose columns are `ChunkedArray`s. `num_rows`,
#            `table['col']` and `to_pandas()` all work on the single object.
#
# So the user gets ONE object that HAPPENS to be chunked inside, and iterates
# chunks only if it wants zero-copy. That is what this type is. It is also what
# makes an Arrow C Data Interface export natural rather than bolted on: the C
# stream (`ArrowArrayStream`) is a SEQUENCE of batches, so a chunked Table
# exports without a stitch, where a contiguous `RecordBatch` had to build one
# first.
#
# ⚠ WHAT THIS TYPE DELIBERATELY DOES **NOT** DO
# ---------------------------------------------
# There is NO per-column access (`column_at`, `column_as_primitive_int64`, ...).
# A chunked table's column is a `ChunkedArray`, and there is no such type
# (`Column` is a FLAT single-buffer array). Offering `column_at`
# here would have to either silently concatenate (re-introducing the exact cost
# this type exists to remove) or serve chunk 0 and quietly return a PREFIX of
# the answer. Both are worse than not offering it, so the surface stops at the
# table level and `chunk(i)` is how you reach columns. This boundary is
# stated, not accidental.
#
# ⭐ TWO DOORS TO ONE CONTIGUOUS BATCH, AND THEY ARE NOT INTERCHANGEABLE
# ---------------------------------------------------------------------
#   `into_single_batch()`  ASSERTS  -- raises on >1 chunk. For a caller that
#                                      drove the producer at a budget that
#                                      cannot segment, so >1 chunk is a
#                                      ROUTING BUG. Product call sites
#                                      depend on that raise.
#   `to_record_batch()`    CONCATENATES -- for a caller that asked for one
#                                      buffer on purpose and will pay for it.
#                                      Read ITS docstring before using
#                                      it on a DICTIONARY result: the
#                                      divergent-dict concat arm is O(N^2).
# ⛔ Do NOT collapse these into one. A silent concat behind the assert gives
# back exactly the stitch this type exists to remove, and nothing goes red.
#
# INVARIANT: EVERY CHUNK SHARES ONE SCHEMA
# ----------------------------------------
# Enforced at construction, fail-loud -- COUNT and physical LAYOUT, both. It is
# what makes `num_rows()` a plain sum and what lets a consumer read the schema
# ONCE.
#
# ⚠ THE LAYOUT HALF MATTERS. Comparing `num_columns()` and nothing else lets a
# chunk that lockstep-promoted to `large_string` sit under a table schema
# still saying `string`; a consumer reading the schema once then strides an
# int64 offsets buffer by 4. Note what does NOT catch it:
# `RecordBatch._ensure_column_type` (`record_batch.mojo`) compares a Column
# against ITS OWN batch schema, and `RecordBatchBuilder.build` has by then
# widened that batch's schema in lockstep -- so the two AGREE and the accessor
# guard sees nothing. Only the TABLE-vs-CHUNK relationship diverges, and this
# is the only seam holding both sides of it.
#
# ⚠⚠ AND THE LAYOUT HALF HAS ITS OWN HOLE TO CLOSE. The chunk-vs-schema
# comparison is `layouts_conflict`, which is False against an UNKNOWN class on
# EITHER side. That carve-out is right for a NULL CHUNK column (the `Column`
# MOVE defect must stay repairable) but it makes the check VACUOUS when the
# unknown side is the TABLE SCHEMA: a `string` chunk and a `large_string` chunk
# both pass, while conflicting with each other. So `from_chunks` also compares
# the chunks TO EACH OTHER -- but only for the columns whose table type is
# unknown, which is the only place the schema-side check cannot already decide
# it. This matters more the more the engine is chunked by default: a
# NULL-typed output column stops being a rare repair case and starts being a
# shape any result can carry.
# =============================================================================

from std.collections import List

from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ARROW_LAYOUT_UNKNOWN, ArrowType, layouts_conflict
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch, Schema
from komira_arrow.string_array import StringArray


struct Table(Movable):
    """A query result: ONE object, chunked internally.

    Presents the whole result -- `num_rows()`, `num_columns()`, `schema()` --
    while owning N `RecordBatch` segments that are never stitched unless a
    caller asks for one contiguous batch.

    Fields:
        _schema: The one schema every chunk carries.
        _chunks: The segments, in OUTPUT-ROW ORDER. May be empty.
        _num_rows: Cached sum of the chunks' row counts.
    """

    var _schema: Schema
    # ⭐ `Slab`, NOT `List`, AND THE REASON IS ORIGIN SPELLABILITY -- NOT perf.
    # `Slab.__getitem__` returns `ref [self._bytes] T`, so composed through
    # this field a per-element accessor's origin is `origin_of(self._chunks
    # ._bytes)` -- A REAL FIELD PATH, which is a thing you can type. `List`
    # yields `origin_of(self._chunks["element"])`, a synthetic origin with NO
    # SYNTAX, which is why `ref [self._chunks]` and `ref [self]` BOTH fail on
    # a List field with "cannot return reference with incompatible origin".
    # That is the whole reason `chunk(i)` can exist below.
    #
    # ⛔ THE SPELLABILITY IS EXACTLY ONE LEVEL DEEP. A 2-deep accessor
    # (`Table.column_at(i, c) -> ref Column`) derives
    # `origin_of(self._chunks._bytes._columns._bytes)`, which the compiler
    # PRINTS in its own error but which is not syntax -- `self._chunks._bytes`
    # is a `List[UInt8]` and has no `._columns`. An explicit origin parameter
    # does not rescue it. ⇒ callers chain `t.chunk(i).column_at(c)`, each
    # hop 1-deep at its own site. Do not re-attempt the 2-deep form.
    var _chunks: Slab[RecordBatch]
    var _num_rows: Int
    # ⭐ THE PREFIX SUM, AND ITS INVARIANT IS "NON-EMPTY IFF `num_chunks() > 1`".
    # `_chunk_starts[i]` is the number of rows BEFORE chunk `i`, so
    # `_chunk_starts[0] == 0` and `len(_chunk_starts) == len(_chunks)`.
    #
    # ⛔ IT IS DELIBERATELY NOT BUILT AT n <= 1, AND THAT IS A HARD CONSTRAINT
    # RATHER THAN A TUNING CHOICE. `from_batch` is the documented ZERO-COST
    # WRAP -- "no copy, no concat, the batch is moved in" -- and it is what
    # `materialize_plan` calls on the common one-chunk result. A one-element
    # `List[Int]` is a heap allocation, so building one there would put a fresh
    # malloc on the path of every query to serve a search that the n == 1 arm
    # never performs. An empty `List[Int]()` allocates nothing, so the wrap
    # stays allocation-free. `_locate` checks `len(self._chunks) == 1` FIRST and returns
    # `(0, row)` without ever reading this list.
    var _chunk_starts: List[Int]

    def __init__(out self):
        """An empty table: no schema, no chunks, zero rows."""
        self._schema = Schema()
        self._chunks = Slab[RecordBatch]()
        self._num_rows = 0
        self._chunk_starts = List[Int]()

    @staticmethod
    def from_batch(var batch: RecordBatch) -> Table:
        """The ONE-CHUNK table -- the shape every unchunked driver returns.

        This is the zero-cost wrap: no copy, no concat, the batch is moved in.
        It is what keeps `chunk_budget_bytes <= 0` byte-identical to handing
        back the single batch.
        """
        var t = Table()
        t._schema = batch.schema.copy()
        t._num_rows = batch.num_rows()
        t._chunks.append(batch^)
        return t^

    @staticmethod
    def from_chunks(
        var chunks: List[RecordBatch], var schema: Schema
    ) raises -> Table:
        """`from_chunks` for a caller holding a `List` -- moves into a `Slab`
        and delegates to the overload below, which is the real body.

        ⭐ THIS OVERLOAD EXISTS FOR CALLERS THAT BUILD A `List`. A constructor
        is the one place where paying an O(n) re-container is honest: the
        caller already built the `List`, and the moves are `RecordBatch`
        handles, not buffers.

        ⚠ REVERSE-THEN-POP, not `pop(0)`: `List.pop()` off the END is O(1) where
        `pop(0)` memmoves the whole tail on every call. Reversing first makes
        the back-to-front drain produce FORWARD order, which is the order the
        whole type is defined by.
        """
        var n = len(chunks)
        var slab = Slab[RecordBatch].create(n)
        chunks.reverse()
        for _i in range(n):
            slab.append(chunks.pop())
        _ = chunks^
        return Table.from_chunks(slab^, schema^)

    @staticmethod
    def from_chunks(
        var chunks: Slab[RecordBatch], var schema: Schema
    ) raises -> Table:
        """Build a table from SEGMENTS, in output-row order.

        `schema` is AUTHORITATIVE -- it is the driver's own output schema, not
        an inference from chunk 0, because a 0-row chunk sequence has no chunk
        to infer from and "an empty result still has a schema".

        Raises when a chunk's column COUNT disagrees with the schema, when a
        chunk's column TYPE describes a DIFFERENT BUFFER LAYOUT than the one
        the table schema declares, and -- where the schema's own layout class
        is UNKNOWN and therefore cannot adjudicate -- when two CHUNKS describe
        different buffer layouts from each other. See the module header for why
        this is checked rather than tolerated. A 0-COLUMN chunk is admitted
        ONLY when the schema is also 0-column, so the `count_only` carrier
        shape cannot enter a table that claims columns.

        ⭐ THE THIRD CHECK EXISTS BECAUSE THE SECOND ONE IS NOT TRANSITIVE
        THROUGH AN UNKNOWN. Every comparison here is `layouts_conflict`, which
        is False whenever either side's class is unknown -- deliberately, so a
        zeroed `NULL` tag stays repairable. When the TABLE schema is the
        unknown side, that makes the chunk-vs-schema check vacuous for that
        column: a `string` chunk and a `large_string` chunk both pass it while
        contradicting each other. The cross-chunk arm is armed only for those
        columns, uses the same predicate, and keeps the same carve-outs (a
        relabel is admitted, a NULL chunk column is neither a witness nor
        judged).

        ⭐ THE TYPE CHECK IS `layouts_conflict`, NOT `!=`, AND THAT IS THE
        WHOLE DESIGN. It refuses only a pair whose layout classes are BOTH
        KNOWN and DIFFER -- `large_string` (int64 offsets) under `string`
        (int32), `dictionary` (int32 codes) under `string`. It deliberately
        ADMITS a relabel across identical buffers (`DATE32` vs `INT32`,
        `TIMESTAMP_US` vs `INT64`), which this tree does on purpose, and it
        admits anything involving `NULL` -- a zeroed tag is the `Column` MOVE
        defect's signature, and `RecordBatch._ensure_column_type`'s heuristic
        recovery from it must keep working. Same predicate, same rationale and
        same carve-outs as `RecordBatch._reject_layout_conflict`, one frame up.

        ⚠ WHY THIS SEAM AND NOT AN ACCESSOR. Every chunk a promoting producer
        builds is INTERNALLY CONSISTENT: `RecordBatchBuilder.build` widens that
        BATCH's own schema in lockstep with its promoted column, so a Column
        and its own batch schema AGREE and no intra-batch guard can see
        anything wrong. The divergence exists only BETWEEN the table schema and
        a chunk, and `from_chunks` is the one place holding both.
        """
        var t = Table()
        var want = schema.num_columns()
        var total = 0
        # ---------------------------------------------------------------------
        # ⭐ THE CROSS-CHUNK WITNESS -- ARMED ONLY WHERE THE TABLE SCHEMA CANNOT
        # ADJUDICATE.
        #
        # The per-chunk check below compares chunk c against the TABLE SCHEMA
        # and nothing else. That is sufficient whenever the schema's own layout
        # class is KNOWN: every chunk that agrees with a known class agrees
        # with every other chunk that agrees with it, by transitivity. It is
        # NOT sufficient when the schema's class is UNKNOWN -- `NULL`, the
        # `Column` MOVE defect's signature -- because `layouts_conflict` is
        # False against an unknown side BY CONSTRUCTION, so a `string` chunk
        # and a `large_string` chunk BOTH pass while conflicting with each
        # OTHER. A consumer that reads the schema once and walks the chunks
        # then strides one of them by the wrong offset width: the exact wrong
        # answer the schema-side check exists to refuse, reached by the one
        # route it cannot see.
        #
        # ⛔ THE NARROWNESS IS STRUCTURAL, NOT INCIDENTAL. The witness is
        # allocated ONLY for the column indices whose TABLE type is UNKNOWN, so
        # on every result whose schema is fully typed -- which is all of them
        # unless a Column arrived zeroed -- this costs one `num_columns()` walk
        # and refuses nothing new. It cannot over-fire on the relabel carve-out
        # either: the comparison is the SAME `layouts_conflict`, so `DATE32`
        # beside `INT32` is admitted between chunks exactly as it is admitted
        # against the schema.
        #
        # ⚠ A `NULL` CHUNK COLUMN STILL CONFLICTS WITH NOTHING. It contributes
        # no witness and is compared against none, so `_ensure_column_type`'s
        # heuristic recovery from a zeroed tag keeps working -- refusing here
        # would turn a REPAIRABLE corruption into a hard failure at assembly.
        # ---------------------------------------------------------------------
        var track_witness = False
        for c in range(want):
            if (
                schema.field_arrow_type(c).physical_layout_class()
                == ARROW_LAYOUT_UNKNOWN
            ):
                track_witness = True
                break
        var witness = List[ArrowType]()
        var witness_chunk = List[Int]()
        if track_witness:
            for _c in range(want):
                witness.append(ArrowType.NULL)
                witness_chunk.append(-1)
        for i in range(len(chunks)):
            var got = chunks[i].num_columns()
            if got != want:
                raise Error(
                    "Table.from_chunks: chunk "
                    + String(i)
                    + " has "
                    + String(got)
                    + " columns but the table schema declares "
                    + String(want)
                    + "; every chunk must carry the same schema."
                )
            # TYPE, not just count. `field_arrow_type` does NOT bounds-check,
            # so the walk is bounded by the CHUNK's own schema as well as the
            # table's: `num_columns()` above is the PHYSICAL column count, and
            # nothing here may index a short schema off its end.
            var chunk_fields = chunks[i].schema.num_columns()
            var n_cmp = want if want < chunk_fields else chunk_fields
            for c in range(n_cmp):
                var chunk_type = chunks[i].schema.field_arrow_type(c)
                var table_type = schema.field_arrow_type(c)
                if layouts_conflict(chunk_type, table_type):
                    raise Error(
                        "Table.from_chunks: PHYSICAL LAYOUT CONFLICT at chunk "
                        + String(i)
                        + ", column index "
                        + String(c)
                        + " (name '"
                        + schema.field_name(c)
                        + "'): the chunk carries "
                        + String(chunk_type)
                        + " (layout class "
                        + String(chunk_type.physical_layout_class())
                        + ") but the table schema declares "
                        + String(table_type)
                        + " (layout class "
                        + String(table_type.physical_layout_class())
                        + "). These describe DIFFERENT buffer layouts, so a"
                        + " consumer that reads the table schema ONCE and then"
                        + " walks the chunks would reinterpret this chunk's"
                        + " buffers -- e.g. an int64 large_string offsets"
                        + " buffer strided by 4. The producer widened one"
                        + " chunk's schema (lockstep offset promotion) without"
                        + " widening the table schema it declared up front."
                    )
                if not track_witness:
                    continue
                # The schema could not adjudicate this column; make the CHUNKS
                # adjudicate it against each other. `layouts_conflict` is the
                # same predicate with the same carve-outs -- an UNKNOWN on
                # either side is admitted, so a NULL chunk column neither sets
                # a witness nor is judged against one.
                if chunk_type.physical_layout_class() == ARROW_LAYOUT_UNKNOWN:
                    continue
                if witness_chunk[c] < 0:
                    witness[c] = chunk_type
                    witness_chunk[c] = i
                    continue
                if layouts_conflict(chunk_type, witness[c]):
                    raise Error(
                        "Table.from_chunks: PHYSICAL LAYOUT CONFLICT BETWEEN"
                        " CHUNKS at column index "
                        + String(c)
                        + " (name '"
                        + schema.field_name(c)
                        + "'): chunk "
                        + String(witness_chunk[c])
                        + " carries "
                        + String(witness[c])
                        + " (layout class "
                        + String(witness[c].physical_layout_class())
                        + ") but chunk "
                        + String(i)
                        + " carries "
                        + String(chunk_type)
                        + " (layout class "
                        + String(chunk_type.physical_layout_class())
                        + "). The TABLE schema declares "
                        + String(table_type)
                        + ", whose layout class is UNKNOWN, so it cannot"
                        + " adjudicate between them -- which is why this is"
                        + " checked chunk-against-chunk. A consumer that reads"
                        + " the table schema ONCE and then walks the chunks"
                        + " would reinterpret one of these two segments'"
                        + " buffers, e.g. an int64 large_string offsets buffer"
                        + " strided by 4."
                    )
            total += chunks[i].num_rows()
        t._schema = schema^
        # ⭐ THE PREFIX SUM IS COMPUTED ONCE, HERE, FROM THE ROW COUNTS THE
        # VALIDATION WALK ABOVE ALREADY READ -- it is a second pass over
        # `num_rows()` only, not a second pass over the data.
        #
        # ⛔ SKIPPED ENTIRELY AT n <= 1. See the field's own comment: at n == 1
        # `_locate` is a direct hit that never consults this list, so building
        # it would be a heap allocation bought for nothing -- and `from_batch`,
        # the wrap every query takes today, must stay allocation-free. The
        # invariant the accessors rely on is therefore "non-empty IFF
        # num_chunks() > 1", which is stated on the field and asserted by
        # `test_arrow_table_accessors.mojo`.
        if len(chunks) > 1:
            var starts = List[Int](capacity=len(chunks))
            var running = 0
            for i in range(len(chunks)):
                starts.append(running)
                running += chunks[i].num_rows()
            t._chunk_starts = starts^
        t._chunks = chunks^
        t._num_rows = total
        return t^

    def num_rows(self) -> Int:
        """Total rows across every chunk -- the whole result's row count."""
        return self._num_rows

    def num_columns(self) -> Int:
        """Columns in the result. Read off the SCHEMA, so it is answerable on a
        table with zero chunks (an empty result still has a schema)."""
        return self._schema.num_columns()

    def schema(self) -> ref [self._schema] Schema:
        """The one schema every chunk carries."""
        return self._schema

    def num_chunks(self) -> Int:
        """How many segments this table is made of.

        ⚠ THIS IS A PHYSICAL DETAIL, NOT PART OF THE ANSWER. Two runs that
        differ only in chunking are the SAME result; a value oracle must fold
        across chunks rather than compare this number.
        """
        return len(self._chunks)

    def chunks(self) -> ref [self._chunks] Slab[RecordBatch]:
        """Borrow the segments, in output-row order.

        The read-only counterpart of `take_chunks()`: DuckDB spells this
        `ColumnDataCollection::Chunks()` and pyarrow spells it
        `Table.to_batches()`. `table.chunks()[i]` reaches one segment
        (`Slab` has `__getitem__`, `__len__` and `len()`).

        ⭐ PREFER `chunk(i)` for a single segment. This method hands back the
        whole container, so a caller that wanted one chunk borrows all of them.
        """
        return self._chunks

    def chunk(self, i: Int) raises -> ref [self._chunks._bytes] RecordBatch:
        """ONE segment, by index, borrowed -- no copy and no container.

        ⭐ THE ORIGIN IS `self._chunks._bytes`, WHICH IS THE WHOLE REASON THIS
        METHOD CAN EXIST. `Slab.__getitem__` returns `ref [self._bytes] T`;
        composed through this field that is `origin_of(self._chunks._bytes)`,
        a path expression that can be both DERIVED by the compiler from the
        return value and TYPED by a human in the signature. Over a `List`
        field the derived origin would be `origin_of(self._chunks["element"])`
        -- synthetic, with no syntax -- so no declared origin would match and
        the method would be inexpressible. Refs survive an allocating
        statement and a re-read, and chain one hop.

        ⛔ ONE HOP ONLY. `t.chunk(i).column_at(c)` is the spelling for a
        column; a `Table.column_at(i, c)` returning `ref Column` is NOT
        expressible (it derives a 2-deep `._bytes … ._bytes` origin the
        compiler prints but cannot parse) and an explicit origin parameter
        does not rescue it. Do not re-attempt it -- see the field comment.

        ⛔⛔ IT BOUNDS-CHECKS UNCONDITIONALLY AND RAISES, AND THE CHECK BELOW
        IS THE ONLY BOUND THIS METHOD HAS. The only other bound is the
        `debug_assert` inside `Slab.__getitem__`
        (`komira_collections/slab.mojo`), and a `debug_assert` is
        compiled out unless assertions are enabled -- including in an
        ordinary unoptimised build. Without the check, on a ONE-chunk table
        `chunk(1)` returns, and `.num_rows()` reads a `RecordBatch` off the
        end of the slab's byte allocation and answers: A WRONG ANSWER, NOT A
        CRASH.
        ⚠ WHICH IS WHY `Slab.__getitem__`'s OWN DOCSTRING IS A TRAP HERE. It
        says "PANICS if idx >= _len_t or idx < 0"; with assertions compiled
        out it does not. Do not read that sentence as the contract.

        A `raises` callee needs a `raises` CALLER, not a `try` at the call
        site, and a `raises` function CAN return a `ref`: the identical return
        type exists on `InMemoryRegistry.lookup`
        (`komira_scan_source/compiler_registry.mojo`),
        `raises -> ref [self._batches._bytes] RecordBatch` over a
        `Slab[RecordBatch]` field. What a caller can do with the returned
        borrow is a field read (`num_rows()`) or a `column_as_*`, which
        reconstructs an array by buffer memcpy; two compares and a
        well-predicted branch are not measurable against either. If a future
        caller measures this check as a real cost, the answer is an
        explicitly-named unchecked sibling with its own `# SAFETY:` contract
        -- NOT quietly removing the bound from the door everyone else uses.

        ⚠ RAISE, NOT `abort()`: report by NAME at the right altitude instead
        of killing the process.

        Raises:
            Error if `i` is outside `[0, num_chunks())`. A ZERO-CHUNK table
            therefore refuses every index, which is correct: it has no
            segments to borrow.
        """
        if i < 0 or i >= len(self._chunks):
            raise Error(
                "Table.chunk: index "
                + String(i)
                + " out of range [0, "
                + String(len(self._chunks))
                + ")"
            )
        return self._chunks[i]

    def take_chunks(mut self) -> Slab[RecordBatch]:
        """Move the segments out, leaving an empty table.

        The zero-copy egress: an Arrow C Data Interface stream consumes exactly
        this sequence.

        ⚠ RETURNS A `Slab`, NOT A `List` -- the field's type. For a caller:
          * `len()`, `[i]` and `append()` work as on a `List`.
          * `reverse()` and `for b in chunks:` DO NOT EXIST on `Slab`, and
            `pop()` returns `Optional[T]`. Drain forward with
            `take_slot_unchecked(i)` + `set_len(0)`, which `Slab` documents
            as its canonical drain-in-place: O(N) in one pass, no reversal.
        ⛔⛔ ONLY WHEN THE LOOP BODY CANNOT RAISE. That drain moves each slot
        out WITHOUT adjusting the length -- the fix is a SEPARATE statement
        after the loop -- so an error escaping the loop unwinds with the slab
        still claiming every slot live and its destructor double-frees the
        drained ones (a SIGSEGV). For a FALLIBLE body the forward, O(N),
        unwind-safe spelling is `chunks.replace(i, RecordBatch())`, which
        leaves every slot initialised at every point and needs no trailing
        length fix. Full argument: `Slab.take_slot_unchecked`'s docstring.
        ⛔ `take_at(0)` IN A LOOP IS NOT THAT DRAIN. It shifts the tail left on
        every call, so it reproduces the O(N^2) `List.pop(0)` cost the reversal
        existed to avoid. It is the right verb for ONE element (n == 1), where
        the tail is empty.
        """
        # RE-INITIALISE the field rather than leaving it moved-from: this is a
        # `mut self` method, so the table stays alive and observable after the
        # call and Mojo will not let a field be left uninitialized at return.
        var out = self._chunks^
        self._chunks = Slab[RecordBatch]()
        # ⚠ THE PREFIX SUM GOES WITH THE CHUNKS. Leaving it populated beside a
        # zero-chunk `_chunks` breaks the "non-empty IFF num_chunks() > 1"
        # invariant `_locate` reads, and the table stays observable after this
        # call -- that is the whole reason the fields are re-initialised rather
        # than left moved-from.
        self._chunk_starts = List[Int]()
        self._num_rows = 0
        return out^

    # =========================================================================
    # ⭐ THE ACCESSOR SURFACE -- DuckDB's `GetValue(column, index)`, AT THE
    # TABLE LEVEL.
    # =========================================================================
    #
    # WHY THIS BLOCK EXISTS. The type this one is modelled on --
    # `MaterializedQueryResult` (cited in this file's own header) -- answers
    # THREE questions over its chunked `ColumnDataCollection`: `RowCount()`,
    # `Collection()`, and `GetValue(column, index)`. Without the third, a
    # caller that wants ONE CELL has no door out but `.to_record_batch()`,
    # and every consumer grows its own private `_find_col` (a walk over
    # `num_columns()` comparing schema field names -- both of which `Table`
    # already answers) and `_get_*` per-cell readers.
    #
    # ⛔ WHAT IS NOT HERE, AND WHY THE OMISSIONS ARE DELIBERATE
    # --------------------------------------------------------
    # ⛔ NO `column_as_dictionary`. A DICTIONARY column's CODES are meaningless
    # without the dictionary they index, and every chunk of a streaming parquet
    # result "keeps its OWN RG dict so its codes resolve correctly"
    # (`scan_chunk_sink.mojo`). A table-level flat read of that column would
    # therefore hand back codes drawn from DIFFERENT DOMAINS in one sequence --
    # an answer that is WRONG and that nothing goes red about, because every
    # code is individually in range for its own chunk. The only sound
    # table-level spellings are a decoded STRING read (`value_str`, below,
    # which resolves each code against ITS OWN chunk's dictionary) or a
    # genuinely MERGED dictionary (`dictionary_merge.merge_dict_columns`, not
    # wired here -- see `to_record_batch`'s docstring). ⛔ DO NOT ADD IT LATER
    # WITHOUT ONE OF THOSE TWO.
    # ⛔ NO `column_at` / `column_as_primitive_*` returning a whole column. A
    # chunked table's column is a `ChunkedArray` and there is no such
    # type; offering one here would have to concat or serve a PREFIX. That
    # boundary is the module header's, restated, and it is why this block is
    # per-CELL and per-SCHEMA and nothing in between.
    #
    # ⚠ COST: THESE ARE POINT READS, NOT A SCAN PRIMITIVE.
    # ---------------------------------------------------
    # Every `value_*` below routes through the corresponding `RecordBatch`
    # accessor, and those RECONSTRUCT an array from the column's buffers per
    # call (`Column.as_primitive`: "The data is COPIED into a new
    # PrimitiveArray", modulo its non-nullable zero-copy branch). That is the
    # cost `RecordBatch.column_value` has always had, and routing through it is
    # deliberate: reaching the `Column` directly would bypass
    # `_ensure_column_type`, the Column-move workaround whose own docstring
    # says "NOT ESTABLISHED AS FIXED. The workarounds stay."
    # ⇒ Use these for a CELL (an assertion, a scalar result, a header probe).
    # For a SCAN, take the segment once -- `for b in table.chunks(): var arr =
    # b.column_as_primitive_int64(c)` -- and read `arr` in the inner loop.
    #
    # RAISES-NESS MIRRORS `RecordBatch` EXACTLY, including where a body cannot
    # fail (`column_index` delegates to `Schema.column_index`, which raises on
    # an unknown name; `column_arrow_type` raises on a bad index). A signature
    # that differs from the type it is replacing is a trait-conformance trap
    # and a migration paper-cut for no benefit.

    # --- TIER 0: chunk-invariant, read off the SCHEMA --------------------
    #
    # These are free at any chunk count and correct at n == 0, because the
    # table schema is AUTHORITATIVE (see `from_chunks`) and `from_chunks`
    # enforces that every chunk agrees with it on column COUNT and on physical
    # buffer LAYOUT. There is nothing to resolve and no chunk to consult.

    def column_index(self, name: String) raises -> Int:
        """The index of the column named `name`. CHUNK-INVARIANT.

        Reads the TABLE schema, which `from_chunks` documents as
        AUTHORITATIVE -- it is the driver's own output schema, not an
        inference from chunk 0, so this is answerable on a table with ZERO
        chunks exactly as `num_columns()` is ("an empty result still has a
        schema").

        ⭐ THIS IS THE ONE THAT PAYS FOR ITSELF ON ARRIVAL. 93 files carry a
        private `_find_col(rb, name)` whose ENTIRE body is a walk over
        `num_columns()` comparing schema field names. They are private because
        the result type had no name->index door and the only thing that did was
        a `RecordBatch` obtained by converting.

        Raises:
            Error if no field carries that name (`Schema.column_index`).
        """
        return self._schema.column_index(name)

    def column_by_name(self, name: String) raises -> Int:
        """The index of the column named `name` -- `RecordBatch`'s SPELLING.

        Identical to `column_index`, and that is the point: `RecordBatch`
        spells this `column_by_name` and returns the INDEX (not a column), so
        a call site migrating off `.to_record_batch()` keeps its call text.
        `column_index` is the name `Schema` uses one frame down; both are here
        so neither migration direction needs a rename.

        Raises:
            Error if no field carries that name.
        """
        return self._schema.column_index(name)

    def column_arrow_type(self, index: Int) raises -> ArrowType:
        """The Arrow logical type of column `index`. CHUNK-INVARIANT.

        ⚠ THE BOUNDS CHECK IS LOAD-BEARING: `Schema.field_arrow_type` does NOT
        bounds-check (it indexes a parallel `List` directly), a property
        `from_chunks` already has to work around in its own walk.

        ⚠ THIS IS *NOT* `RecordBatch.column_arrow_type`, AND THE DIFFERENCE IS
        THAT THERE IS NOTHING HERE TO DISAGREE. That one compares a physical
        `Column.arrow_type` against its batch schema and repairs a zeroed tag.
        A `Table` owns no columns; the chunk-vs-schema relationship is checked
        ONCE at construction (`from_chunks`, both the schema-side and the
        cross-chunk arms) and refused there, which is strictly earlier and
        strictly louder than a per-read warning.

        Raises:
            Error if `index` is out of range.
        """
        if index < 0 or index >= self._schema.num_columns():
            raise Error(
                "Table.column_arrow_type: index "
                + String(index)
                + " out of range [0, "
                + String(self._schema.num_columns())
                + ")"
            )
        return self._schema.field_arrow_type(index)

    # --- TIER S: per-cell -- LOCATE, then READ ---------------------------

    def _locate(self, row: Int) raises -> Tuple[Int, Int]:
        """Resolve a GLOBAL row index to `(chunk_index, row_within_chunk)`.

        ⭐ n == 1 IS A DIRECT HIT WITH NO SEARCH AND NO LIST READ. That is the
        arm every result in the repo takes today (`materialize_plan` is
        wrap-only), so it is the one that has to be free: one comparison, then
        `(0, row)`. It does not consult `_chunk_starts`, which is why that list
        is never built at n <= 1 and why `from_batch` stays allocation-free.

        ⛔ IT NEVER CONCATENATES AND NEVER SCANS THE CHUNKS. At n > 1 it is a
        binary search over the prefix sum `from_chunks` computed once, so the
        cost is O(log n) in the CHUNK COUNT and independent of the row count.
        A segmented result can hold hundreds of chunks, so a linear walk here
        would be ~300 compares a cell where this is 10.

        ⚠ THE SEARCH IS "LARGEST i WITH `_chunk_starts[i] <= row`", NOT "first
        i with row < start[i+1]", AND THAT CHOICE IS WHAT MAKES EMPTY CHUNKS
        CORRECT. A 0-row chunk at `i` satisfies `start[i] == start[i+1]`, so
        the LARGEST-index rule steps past it onto the chunk that actually holds
        the row; a first-match rule would land ON it and then read row 0 of an
        empty chunk. Interior, leading and trailing empties are all covered,
        and the bound check above is what guarantees the landing chunk is
        non-empty (a row past every non-empty chunk is not a row).

        Raises:
            Error if `row` is outside `[0, num_rows())`. A ZERO-CHUNK table has
            `_num_rows == 0`, so every row fails here and the search below is
            unreachable at n == 0 -- which is what lets it assume
            `_chunk_starts` is non-empty.
        """
        if row < 0 or row >= self._num_rows:
            raise Error(
                "Table: row "
                + String(row)
                + " out of range [0, "
                + String(self._num_rows)
                + ")"
            )
        if len(self._chunks) == 1:
            return (0, row)
        var lo = 0
        var hi = len(self._chunk_starts) - 1
        while lo < hi:
            # ⛔⛔ `(lo + hi + 1) // 2`, NOT `(lo + hi) // 2`, AND THE WRONG ONE
            # DOES NOT FAIL -- IT HANGS. With the conventional midpoint,
            # `lo == hi - 1` gives `mid == lo`, and the `lo = mid` branch then
            # assigns `lo` to itself forever: a test does not go red, it stops
            # responding.
            # A "simplification" to the familiar spelling is therefore not a
            # slow correct answer or a loud wrong one; it is a wedge. The
            # upper-midpoint is what makes the `lo = mid` branch progress.
            var mid = (lo + hi + 1) // 2
            if self._chunk_starts[mid] <= row:
                lo = mid
            else:
                hi = mid - 1
        return (lo, row - self._chunk_starts[lo])

    def column_value(
        self, col_index: Int, row_index: Int
    ) raises -> Scalar[DType.int64]:
        """DuckDB's `GetValue(column, index)` -- the int64 read.

        ⭐ SIGNATURE-IDENTICAL TO `RecordBatch.column_value`, deliberately: a
        call site that today reads `plan.to_record_batch().column_value(c, r)`
        becomes `plan.column_value(c, r)` with no other edit and no conversion.

        `row_index` is GLOBAL across the whole result; the chunk it lands in is
        resolved by `_locate` and the read then delegates to that chunk, so the
        answer does not depend on how the result was segmented.

        Raises:
            Error if `row_index` is out of range for the table, or if
            `col_index` is out of range / the column is not int64-readable
            (both from `RecordBatch.column_value`).
        """
        var loc = self._locate(row_index)
        return self._chunks[loc[0]].column_value(col_index, loc[1])

    def value_primitive[
        dtype: DType
    ](self, col_index: Int, row_index: Int) raises -> Scalar[dtype]:
        """One cell of a PRIMITIVE column, at ANY storage DType
        `Column.as_primitive` accepts.

        ★ THIS IS THE ONLY PARAMETRIC METHOD ON `Table`, AND THAT IS A BUDGET,
        NOT AN ACCIDENT. `table.mojo` lives in `komira_core`, which is reached
        by nearly every target, so every extra instantiation here is paid for
        in compile time across the whole build. So the dtypes
        this repo actually reads get HAND-WRITTEN monomorphic siblings below
        rather than three more instantiations, mirroring what `RecordBatch`
        does with `column_as_primitive` + `column_as_primitive_<t>`.

        ⚠ AND THE SIBLINGS DELEGATE TO `RecordBatch`'s ALREADY-MONOMORPHIC
        ACCESSORS, NOT TO THIS METHOD. `column_as_primitive_int64` and friends
        are instantiated inside `komira_core` already, so routing through them
        adds ZERO new instantiations to the library; routing through this
        parametric would add one thin wrapper per dtype for no behavioural
        difference. This method exists for the widths the repo does NOT
        currently read (i8/i16/u*/f32, and the temporal aliases
        `Column.as_primitive` admits) and is instantiated only by a caller that
        asks for one -- in that caller's TU, not in `komira_core`'s.

        Parameters:
            dtype: The storage DType to read the column as.

        Args:
            col_index: Column index.
            row_index: GLOBAL row index across the whole result.

        Raises:
            Error if `row_index` is out of range for the table, if `col_index`
            is out of range, or if the column's storage DType is incompatible.
        """
        var loc = self._locate(row_index)
        return (
            self._chunks[loc[0]]
            .column_as_primitive[dtype](col_index)
            .get(loc[1])
        )

    def value_i64(
        self, col_index: Int, row_index: Int
    ) raises -> Scalar[DType.int64]:
        """One int64 cell. `row_index` is GLOBAL across the whole result."""
        var loc = self._locate(row_index)
        return self._chunks[loc[0]].column_as_primitive_int64(col_index).get(
            loc[1]
        )

    def value_f64(
        self, col_index: Int, row_index: Int
    ) raises -> Scalar[DType.float64]:
        """One float64 cell. `row_index` is GLOBAL across the whole result."""
        var loc = self._locate(row_index)
        return self._chunks[loc[0]].column_as_primitive_float64(
            col_index
        ).get(loc[1])

    def value_i32(
        self, col_index: Int, row_index: Int
    ) raises -> Scalar[DType.int32]:
        """One int32 cell. `row_index` is GLOBAL across the whole result."""
        var loc = self._locate(row_index)
        return self._chunks[loc[0]].column_as_primitive_int32(col_index).get(
            loc[1]
        )

    def value_bool(self, col_index: Int, row_index: Int) raises -> Bool:
        """One boolean cell. `row_index` is GLOBAL across the whole result.

        BOOL is bit-packed, so it is not a `Scalar[dtype]` read and cannot ride
        `value_primitive` -- same reason `RecordBatch` spells it
        `column_as_boolean` rather than `column_as_primitive[DType.bool]`.
        """
        var loc = self._locate(row_index)
        return self._chunks[loc[0]].column_as_boolean(col_index).get(loc[1])

    def value_str(self, col_index: Int, row_index: Int) raises -> String:
        """One string cell. `row_index` is GLOBAL across the whole result.

        ⭐ THIS IS THE SOUND TABLE-LEVEL READ OF A DICTIONARY COLUMN, and the
        reason no `column_as_dictionary` is offered (see the block comment
        above). `RecordBatch.column_as_string` decodes through the chunk's OWN
        dictionary, so a per-cell string read is correct across chunks whose
        dictionaries diverge -- which is the normal shape of a streaming
        parquet result -- where a flat CODE read would silently mix domains.
        """
        var loc = self._locate(row_index)
        return self._chunks[loc[0]].column_as_string(col_index).get(loc[1])

    # =========================================================================
    # ⭐ TIER A -- THE CONTIGUOUS TYPED ARRAY.
    # =========================================================================
    #
    # WHAT THESE ARE FOR. Tier S above reads ONE CELL and folds across chunks,
    # which is the right shape for a probe. A kernel that wants to SWEEP a
    # column wants the column, once, as a typed array -- and without this
    # block the only door to one is `.to_record_batch()`, which
    # CONCATENATES. A caller that only ever reads a one-chunk result should
    # not be routed through a method whose n > 1 arm is a real concat.
    #
    # ⛔⛔ THE CONTRACT, AND THE REFUSAL IS THE FEATURE:
    #   n == 0  a 0-row typed array, off a schema-carrying empty batch. An
    #           empty result still has a schema, so "the whole
    #           column" is answerable and is empty.
    #   n == 1  SHARE. Straight through to the chunk's own `column_as_*`. No
    #           concat, no copy beyond what that accessor already does.
    #   n >  1  RAISE, naming the count and both alternatives.
    # ⛔ IT NEVER CONCATENATES. That is the rule: *never concatenate to
    # satisfy a TYPE SIGNATURE*. A caller reaching for a contiguous array over a
    # segmented result has stated an assumption that is now false, and a silent
    # concat converts that into a slow correct answer nobody investigates --
    # exactly the failure `into_single_batch` exists to refuse one level up.
    # The caller that genuinely wants contiguity says so with
    # `.to_record_batch()`; the caller that wants to stay chunked loops
    # `chunk(i).column_as_*(c)`.
    #
    # ⛔⛔ EVERY ONE OF THESE ROUTES THROUGH `RecordBatch.column_as_*`, NEVER
    # THROUGH `chunk(i).column_at(c).as_primitive[dt]()`. THIS IS NOT A STYLE
    # CHOICE. Reaching the `Column` directly reads an UNREPAIRED
    # `Column.arrow_type` and so bypasses `RecordBatch._ensure_column_type`,
    # the Column-move-bug workaround every accessor on that struct runs first
    # -- and whose own docstring still reads "NOT ESTABLISHED AS FIXED. The
    # workarounds stay." `RecordBatch.column_as_primitive` states the same rule
    # about itself. A `Table`-level accessor that skipped it would reintroduce
    # the silent-corruption surface at a NEW altitude, where it is harder to
    # see, so the delegation target is load-bearing.
    #
    # ⛔ TIER Z STAYS REFUSED -- no `column_share_as_primitive` /
    # `column_can_share_as_primitive` twins here. `RecordBatch` has them and
    # they have ZERO call sites repo-wide; more to the point "share" is
    # MEANINGLESS across N buffers -- there is no one buffer to share. At
    # n <= 1 it would be an alias for the method above it, and at n > 1 it
    # would have to answer False forever. A method whose only honest answer is
    # "no" is not an accessor.

    def _refuse_if_segmented(self, method: StaticString) raises:
        """RAISE when the table is segmented. The shared refusal for Tier A.

        Factored out so all seven accessors refuse with the SAME message and
        the same threshold -- a per-accessor copy is how one of them ends up
        silently concatenating instead.

        ⚠ `StaticString`, NOT `String`, AND THE FAST PATH IS WHY. Every Tier-A
        accessor calls this FIRST, including on the n <= 1 SHARE path that is
        supposed to cost nothing beyond the delegate. A `String` parameter
        would heap-allocate the accessor's own name on every call, including
        the overwhelming majority that never raise -- paying for the error
        message on the success path. A `StaticString` is a compile-time
        literal, so the allocation happens only inside the `raise` below.
        """
        var n = len(self._chunks)
        if n > 1:
            raise Error(
                String("Table.")
                + String(method)
                + ": table has "
                + String(n)
                + " chunks and this accessor NEVER concatenates. Either call"
                " .to_record_batch() to ask for one contiguous batch on"
                " purpose (it concatenates, and on DICTIONARY/BOOL columns"
                " that arm is quadratic in the chunk count), or stay chunked"
                " and loop chunk(i).column_as_*(col) over num_chunks()."
            )

    def _empty_batch(self) raises -> RecordBatch:
        """A 0-row batch carrying the FULL schema -- the n == 0 subject.

        NOT a bare `RecordBatch()`: `num_columns()` reads the PHYSICAL column
        count, so a schema-less empty batch makes column lookups fail with
        `no field named '<k>'`. Same construction, and the
        same reason, as `into_single_batch`'s and `to_record_batch`'s n == 0
        arms.

        ⛔⛔ EVERY CALLER READS A COLUMN OFF THE TEMPORARY THIS RETURNS, AND
        THAT IS ONLY SOUND BECAUSE THE `column_as_*` ACCESSORS COPY. Per
        `Column`: `as_primitive` -> *"A new PrimitiveArray
        holding a copy of this Column's data"*, `as_string` and `as_boolean`
        say the same about theirs, and all three are buffer memcpys. So the
        array outlives the batch it was read from. ⚠ IF ANY OF THOSE EVER
        BECOMES A SHARING VIEW, EVERY n == 0 ARM IN TIER A TURNS INTO A
        USE-AFTER-FREE ON A DEAD TEMPORARY -- over 0-row buffers, so it would
        very likely not crash where it was introduced. Bind the batch to a
        field or return it alongside the array instead of "fixing" it locally.
        """
        return RecordBatch.empty_from_schema(self._schema.copy())

    def column_as_primitive[
        dtype: DType
    ](self, col_index: Int) raises -> PrimitiveArray[dtype]:
        """The whole column as a `PrimitiveArray[dtype]`. SHARES at n <= 1,
        RAISES at n > 1, NEVER concatenates.

        ★ THIS IS THE ONE IMPLEMENTATION of Tier A's primitive arm; the four
        `column_as_primitive_<t>` methods below are one-line delegations, which
        is the same shape `RecordBatch` uses and for the reason recorded there:
        four hand-written copies and no fifth is what made
        `agg_scalar_fold._fold_int_family` route i8/i16/u8/u16/u32/u64 through
        the INT32 accessor and raise on `SELECT sum(<int16 col>)`. A parametric
        accessor cannot develop that hole.

        Parameters:
            dtype: The storage DType to read the column as. Whatever
                `Column.as_primitive` admits, including the temporal aliases
                (DATE32/TIME32_* as int32; DATE64/TIMESTAMP*/DURATION_* as
                int64).

        Args:
            col_index: The column index.

        Returns:
            A `PrimitiveArray[dtype]` over the whole column. 0-row at n == 0.

        Raises:
            Error naming the chunk count when `num_chunks() > 1`; whatever
            `RecordBatch.column_as_primitive` raises otherwise (index out of
            range, storage DType incompatible with `dtype`).
        """
        self._refuse_if_segmented("column_as_primitive")
        if len(self._chunks) == 0:
            return self._empty_batch().column_as_primitive[dtype](col_index)
        return self._chunks[0].column_as_primitive[dtype](col_index)

    def column_as_primitive_int32(
        self, col_index: Int
    ) raises -> PrimitiveArray[DType.int32]:
        """int32 twin of `column_as_primitive`. Same contract."""
        return self.column_as_primitive[DType.int32](col_index)

    def column_as_primitive_int64(
        self, col_index: Int
    ) raises -> PrimitiveArray[DType.int64]:
        """int64 twin of `column_as_primitive`. Same contract."""
        return self.column_as_primitive[DType.int64](col_index)

    def column_as_primitive_float32(
        self, col_index: Int
    ) raises -> PrimitiveArray[DType.float32]:
        """float32 twin of `column_as_primitive`. Same contract."""
        return self.column_as_primitive[DType.float32](col_index)

    def column_as_primitive_float64(
        self, col_index: Int
    ) raises -> PrimitiveArray[DType.float64]:
        """float64 twin of `column_as_primitive`. Same contract."""
        return self.column_as_primitive[DType.float64](col_index)

    def column_as_string(
        self, col_index: Int
    ) raises -> StringArray[HeapRegion]:
        """The whole column as a `StringArray`. SHARES at n <= 1, RAISES at
        n > 1, NEVER concatenates.

        ⭐ THE n > 1 REFUSAL IS STRONGEST HERE, AND IT IS ABOUT DICTIONARIES
        RATHER THAN ABOUT STRINGS. `RecordBatch.column_as_string` DECODES a
        DICTIONARY column through THAT CHUNK'S OWN dictionary. Every chunk of
        a streaming parquet result "keeps its OWN RG dict so its codes resolve
        correctly" (`scan_chunk_sink.mojo`), so the chunks' dictionaries
        legitimately diverge -- and a table-level accessor that stitched them
        would have to pick one domain for codes minted against several. There
        is no correct stitch to write, which is why this refuses rather than
        concatenating. The per-CELL door (`value_str`) is sound across chunks
        precisely because it decodes inside the chunk it located.
        """
        self._refuse_if_segmented("column_as_string")
        if len(self._chunks) == 0:
            return self._empty_batch().column_as_string(col_index)
        return self._chunks[0].column_as_string(col_index)

    def column_as_boolean(self, col_index: Int) raises -> BooleanArray:
        """The whole column as a `BooleanArray`. SHARES at n <= 1, RAISES at
        n > 1, NEVER concatenates.

        ⚠ THE REFUSAL SAVES MORE HERE THAN THE TYPE SUGGESTS. BOOL is one of
        the types `concat.mojo::_concat_one_column_nway` sends to the PAIR-WISE
        fold rather than an N-way kernel, so `.to_record_batch()` over a
        segmented BOOL column is QUADRATIC in the chunk count and silent about
        it (see `to_record_batch`'s own block below: tens of ms for ONE
        6M-row BOOL column at ~590 chunks). A caller that lands here on a
        segmented table is told, rather than charged.
        """
        self._refuse_if_segmented("column_as_boolean")
        if len(self._chunks) == 0:
            return self._empty_batch().column_as_boolean(col_index)
        return self._chunks[0].column_as_boolean(col_index)

    def into_single_batch(var self) raises -> RecordBatch:
        """The ONE contiguous batch -- for a caller that asked for one.

        ⛔ THIS DOES NOT CONCATENATE, IT ASSERTS. A caller reaches this only
        after driving the producer at a budget that cannot segment (the
        `chunk_budget_bytes <= 0` default), so >1 chunk here means the budget
        and the return shape disagree -- a routing bug, and one that a silent
        concat would convert into a slow correct answer nobody investigates.
        Mirrors `join_node_exec._unwrap_single_chunk`, which already states this
        discipline one frame up.

        A ZERO-chunk table returns a 0-row batch carrying the full schema, not
        a bare `RecordBatch()`: `num_columns()` reads the PHYSICAL column count,
        so a schema-less empty batch makes a downstream Project raise
        `Schema.column_index: no field named '<k>'`.
        """
        var n = len(self._chunks)
        if n == 1:
            # `take_at(0)`, not `pop()`: `Slab.pop()` returns `Optional[T]`
            # and there is nothing to unwrap here -- n == 1 is checked. At
            # n == 1 the tail `take_at` shifts is EMPTY, so this is the O(1)
            # move it looks like. (In a LOOP it would not be -- see
            # `take_chunks`.)
            return self._chunks.take_at(0)
        if n == 0:
            return RecordBatch.empty_from_schema(self._schema.copy())
        raise Error(
            "Table.into_single_batch: table has "
            + String(n)
            + " chunks; a single-batch caller must drive the producer at a"
            " non-positive chunk budget. Use take_chunks() to consume the"
            " segments."
        )

    def to_record_batch(var self) raises -> RecordBatch:
        """The ONE contiguous batch -- CONCATENATING the segments when there
        are several. The method a caller reaches for when it genuinely needs
        one buffer.

        ⭐ THIS IS THE SIBLING OF `into_single_batch()`, NOT ITS REPLACEMENT,
        AND THE DIFFERENCE IS THE WHOLE POINT. `into_single_batch()` ASSERTS:
        it raises on >1 chunk because its callers drove the producer at a
        budget that cannot segment, so >1 chunk there is a ROUTING BUG that a
        silent concat would turn into a slow correct answer nobody
        investigates. This method is for the other caller -- the one that
        asked for contiguity on purpose and is willing to pay for it.
        ⛔ do NOT "simplify" by making `into_single_batch` call this one.

        THE RULE THIS OBEYS: *never concatenate to satisfy a TYPE SIGNATURE*. A concat is legitimate when a computation needs one
        buffer. Reaching this method IS the caller stating that it does.

        Cost, by chunk count:
          * `n == 0` -- a 0-row batch carrying the full schema, allocation-free
            beyond the schema copy. NOT a bare `RecordBatch()`: `num_columns()`
            reads the PHYSICAL column count, so a schema-less empty batch makes
            a downstream Project raise `Schema.column_index: no field named
            '<k>'`. Same reasoning as `into_single_batch`.
          * `n == 1` -- the chunk is MOVED out. No copy, no concat, no
            allocation: the returned batch holds the same buffers the chunk
            held. This is the shape every unchunked driver produces, so
            the common path is byte-identical AND allocation-identical to
            handing back the single batch.
          * `n > 1` -- `concat_record_batches_nway`, one 2-pass walk per
            column. Total memcpy traffic O(total_bytes) for the fixed-width and
            var-len arms.

        ⛔⛔ EXCEPT FOR DICTIONARY COLUMNS, WHERE `n > 1` IS QUADRATIC AND THIS
        METHOD DOES NOT FIX THAT.
        `concat.mojo::_concat_one_column_nway` dispatches DICTIONARY two ways.
        When every chunk's dictionary is byte-identical it is an index memcpy
        (`_concat_columns_nway_dict_identical`) -- O(total_bytes), fine. When
        the dictionaries DIVERGE -- which is the normal case for a streaming
        parquet result, where each chunk "keeps its OWN RG dict so its codes
        resolve correctly" (`scan_chunk_sink.mojo`) -- it falls to a PAIR-WISE
        fold through `_concat_columns`, and every step of that fold reseeds a
        `DictInterner` and rebuilds the merged offsets+data buffers from
        scratch. That is **O(N^2) traffic in the chunk count**, not
        O(total_bytes).

        ⇒ **A many-chunk DICTIONARY result is measurably WORSE through this
        method than through a single-batch terminal.**

        ⚠⚠ AND DICTIONARY IS NOT THE ONLY QUADRATIC TYPE -- THE HEADING
        ABOVE IS NARROWER THAN THE CODE. The cost does not come from anything
        dictionary-specific; it comes from WHICH DISPATCH ARM a type lands on.
        `_concat_one_column_nway` sends **BOOL and the nested types (LIST /
        STRUCT / MAP / UNION)** to the SAME pair-wise
        `acc = _concat_columns(acc, nxt)` fold as a divergent-dict DICTIONARY
        (in `concat.mojo`), and that fold deep-copies its accumulator on
        every step. So:
          * **DICTIONARY** (divergent dicts) -- quadratic, SILENT.
          * **BOOL** -- quadratic, SILENT. `_concat_columns` has a real BOOL
            arm, so this one genuinely concatenates; it is simply O(N^2).
          * **nested LIST / STRUCT / MAP / UNION** -- these RAISE rather than
            fold (the pair-wise fixed-width arm refuses them), so at `n > 1`
            they are a LOUD failure, not a slow one.
        ⭐ The types that are FINE are the ones people assume are the problem:
        **STRING / BINARY** take `_concat_columns_nway_var_len` and
        **LARGE_STRING / LARGE_BINARY** take `_concat_columns_nway_var_len_wide`
        -- both N-way, both O(total_bytes). ⛔ Do NOT size this hazard by
        looking for string columns; a plain STRING result is linear here.

        ⚠ SIZING THE RISK SET FROM CALL SITES DOES NOT WORK. Most call sites
        never read a typed column off the result at all (they assert row
        counts, or discard it). The arm a site will take is a property of the
        PLAN'S SOURCE SCHEMA, not of what the caller subsequently reads, so no
        amount of call-site reading determines it. Size it from the source
        side -- which plans scan parquet whose columns arrive
        dictionary-encoded (`scan_chunk_sink.mojo::_resolve_string_dict_chunk`
        is the ONLY constructor of those columns in the streaming path).

        ⚠ THE COST IS LATENT IN THE CHUNK COUNT, NOT IN THE CODE. While a
        result is one chunk every caller takes the `n == 1` MOVE arm above;
        the moment a result segments, every caller becomes a real concat, the
        dictionary ones on the QUADRATIC arm. Priced at ~590 chunks on ONE
        6M-row column: BOOL in the tens of ms, DICTIONARY (divergent dicts)
        over a second, STRING in the tens of ms. For fixed-width columns it
        is a BYTE cost, not a chunk-count cost, so "emit fewer chunks" is not
        the fix: halving N at identical total bytes barely moves it.

        The arm is deliberately NOT fixed here: rewiring it changes the output
        of an existing kernel for every caller. The N-way kernel it wants
        already exists -- `dictionary_merge.merge_dict_columns`, *"unions
        their dictionaries, remaps indices, returns a single DICTIONARY
        Column"*, O(sum(len_i) + sum(dict_size_i)). Wiring it into
        `_concat_one_column_nway`'s divergent-dict arm needs its own
        byte-identity proof against the pair-wise fold (merged-dictionary
        ORDER, validity, `_dict_size`, the 0/1-column fast paths) and its own
        value verdict.

        ⚠ NO PARALLEL OVERLOAD HERE, AND IT IS STRUCTURAL RATHER THAN A
        PREFERENCE. The column-parallel concat
        (`komira_engine_runtime`'s `concat_record_batches_column_parallel`)
        needs a `Pointer[LocalDispatcher[NoopSink]]` + a `CancellationToken`,
        both from `komira_engine_runtime` -- a package DOWNSTREAM of
        `komira_core`. A method here taking them would put engine-runtime in
        `komira_core`'s `deps`, which must stay empty: core is reached by
        nearly every target. A caller that wants the parallel form drives it
        from the engine layer over `take_chunks()`, where the dispatcher
        already is. The column-parallel fan admits BOOL and DICTIONARY (they
        decline only the row-range TILED route); its one structural decline is
        `< 2 columns`. On a wide fixed-width concat it runs several times
        faster than this serial method.

        Returns:
            One `RecordBatch` carrying every row of this table, in chunk order.

        Raises:
            Whatever `concat_record_batches_nway` raises. In particular
            `ArrowConcatLayoutDisagreement` when two chunks describe DIFFERENT
            buffer layouts. ⭐ That check is NOT redundant with
            `from_chunks`: `from_chunks` compares each chunk against the TABLE
            SCHEMA, so a table schema whose layout class is UNKNOWN (`NULL` --
            admitted on purpose, it is the `Column` MOVE defect's signature)
            admits a `string` chunk and a `large_string` chunk side by side.
            The concat kernel is the seam that compares them to EACH OTHER.
        """
        var n = len(self._chunks)
        if n == 1:
            # See `into_single_batch`: `take_at(0)` at n == 1 shifts an empty
            # tail, so it is the O(1) move `Slab.pop()` cannot be (it returns
            # `Optional[T]`).
            return self._chunks.take_at(0)
        if n == 0:
            return RecordBatch.empty_from_schema(self._schema.copy())

        # ⭐ NO STAGING LOOP. `concat_record_batches_nway` takes a
        # `Slab[RecordBatch]`, and the field IS one, so the segments are
        # handed over by MOVING THE FIELD -- no reverse-then-pop transfer, no
        # allocation.
        #
        # ⚠ THE FIELD IS RE-INITIALISED rather than left moved-from. This is
        # `var self`, so the table is consumed -- but a field cannot be left
        # uninitialized at a return, the same constraint `take_chunks`
        # documents one method up.
        var staged = self._chunks^
        self._chunks = Slab[RecordBatch]()
        return concat_record_batches_nway(staged^)
