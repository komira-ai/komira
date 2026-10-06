# =============================================================================
# komira_fs.pruned_hive_discovery — PrunedHiveDiscovery[FS]: the
# Hive-partition prune-at-list-prefix discovery impl.
# =============================================================================
# THE prune-at-prefix discovery core: it prunes at the list PREFIX, where
# DuckDB prunes only AFTER a full listing.
#
# `PrunedHiveDiscovery` is the SECOND concrete `FileDiscovery` impl (alongside
# `EagerGlobDiscovery`). It adds, on top of eager listing:
#   1. `evaluate_partition_prefix`: given a partition predicate, walk
#      the partition cols in PATH ORDER, consume the longest leading run of
#      EQUALITY constraints into the static list prefix; STOP at the first
#      unpinned col. `IN (v1..vN)` -> N targeted prefixes (one list per value).
#      A value the modelled writers (komira, Spark, DuckDB/pyarrow, Windows
#      Spark) spell differently on disk (non-ASCII, space, `:`, ...) gets a
#      prefix per distinct spelling, so any of those writers' trees is found.
#   2. the post-listing `filter_partitions` fold: for non-enumerable
#      residual predicates (ranges / OR / function-wrapped), parse each
#      survivor path's partition values and drop non-matching files BEFORE any
#      footer is opened.
#   3. partition-schema inference + type-probe from the surviving paths.
#   4. per-file PartitionValues exposed via the `FileDiscovery` hooks, stored
#      as ARENA-INDEX HANDLES into backing `Slab[String]` arenas (the destroy-recreate
#      mandate — NOT `List`-inside-byte-slab).
#
# SCOPE: the discovery impl + prune logic + round-trip codec. The
# OPTIMIZER predicate-split (extract the partition pred from the query) is
# separate: this impl TAKES the partition predicate as a constructor input (`open_pruned`)
# and is unit-tested at the DISCOVERY SEAM. The partition-COLUMN
# materialization belongs to the source operator.
#
# Pointer discipline:
#   * NO UnsafePointer in any signature — `Bool`/`Int`/`String`/`ArrowType`
#     and the POD value types only.
#   * safe across destroy-recreate: the per-file PartitionValues are NOT stored as a
#     `Slab[PartitionValues]` (which would put `List[String]` inside a slab
#     element — the destroy-recreate shape). Instead two backing `Slab[String]` arenas
#     (keys + values) hold the flattened pairs, and a `Slab[Int]` index holds
#     per-file `(start, count)` handles. `partition_values_at(idx)`
#     reconstructs a by-value `PartitionValues` from the arena run. This keeps
#     every slab element a POD (String / Int), never a heap-owning `List`.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Field
from komira_core.collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_fs.file_discovery import (
    FileDiscovery,
    PartitionValues,
    PartitionSchema,
    GlobDiscoveryOptions,
)
from komira_fs.partition_codec import (
    parse_partition_value,
    partition_value_spellings,
    parse_key_value_segments,
    probe_partition_type,
)


# =============================================================================
# the structured partition predicate (the input shape).
# =============================================================================
# The OPTIMIZER splits the query filter into the partition-col
# part and the data-col part and hands the partition part to discovery.
# does NOT do that split — it accepts an already-structured partition
# predicate and tests the derivation directly. So this module defines a small
# self-contained predicate POD (NOT coupled to the optimizer's Expr tree).
#
# A `PartitionPredicate` is a CONJUNCTION (AND) of per-column `PartitionConstraint`s.
# Each constraint is one of:
#   * EQ  (col = const)           — prefix-pinnable to ONE targeted prefix.
#   * IN  (col IN (v1..vN))       — prefix-pinnable to N targeted prefixes.
#   * RANGE / OTHER (col >/<.., function-wrapped, ...) — NON-enumerable; it is
#     a "fold" constraint evaluated client-side against each survivor's
# path-derived partition values. models the common comparison
#     ops (LT/LE/GT/GE/NE) for the fold; an OR-across-cols or function-wrapped
#     predicate is represented as a generic OTHER constraint that the fold
# treats conservatively (keeps the file — correctness over pruning;
#     supplies the real residual evaluator when it lands).
# =============================================================================

comptime _OP_EQ: Int = 0
comptime _OP_IN: Int = 1
comptime _OP_LT: Int = 2
comptime _OP_LE: Int = 3
comptime _OP_GT: Int = 4
comptime _OP_GE: Int = 5
comptime _OP_NE: Int = 6
# OTHER: an opaque non-enumerable, non-comparison predicate (OR-across-cols,
# function-wrapped). The fold keeps the file (cannot evaluate it here).
comptime _OP_OTHER: Int = 7


@fieldwise_init
struct PartitionConstraint(Copyable, Movable, Deinitable):
    """One per-column partition constraint. `op` is one of the `_OP_*`
    constants. `values` holds the CANONICAL-string constant(s):
      * EQ / LT / LE / GT / GE / NE -> exactly one value.
      * IN -> N values (N >= 1).
      * OTHER -> zero values (opaque).
    `arrow_type` is the column's declared/inferred type (governs the encode
    form for the prefix and the comparison semantics for the fold).
    """

    var col: String
    var op: Int
    var values: List[String]
    var arrow_type: ArrowType

    @staticmethod
    def eq(col: String, value: String, arrow_type: ArrowType) -> PartitionConstraint:
        var vs = List[String]()
        vs.append(value)
        return PartitionConstraint(col=col, op=_OP_EQ, values=vs^, arrow_type=arrow_type)

    @staticmethod
    def in_list(
        col: String, values: List[String], arrow_type: ArrowType
    ) -> PartitionConstraint:
        return PartitionConstraint(
            col=col, op=_OP_IN, values=values.copy(), arrow_type=arrow_type
        )

    @staticmethod
    def compare(
        col: String, op: Int, value: String, arrow_type: ArrowType
    ) -> PartitionConstraint:
        """A range/inequality constraint (`op` in LT/LE/GT/GE/NE)."""
        var vs = List[String]()
        vs.append(value)
        return PartitionConstraint(col=col, op=op, values=vs^, arrow_type=arrow_type)

    @staticmethod
    def other(col: String) -> PartitionConstraint:
        """An opaque non-enumerable constraint (OR / function-wrapped). The
        fold cannot evaluate it in and conservatively keeps the file."""
        return PartitionConstraint(
            col=col, op=_OP_OTHER, values=List[String](), arrow_type=ArrowType.STRING
        )

    @always_inline
    def is_equality(self) -> Bool:
        return self.op == _OP_EQ

    @always_inline
    def is_enumerable(self) -> Bool:
        """EQ or IN — pinnable to discrete targeted prefix(es)."""
        return self.op == _OP_EQ or self.op == _OP_IN


@fieldwise_init
struct PartitionPredicate(Copyable, Movable, Deinitable):
    """A conjunction (AND) of per-column `PartitionConstraint`s. The
    caller builds this from the query at scan-construction. An EMPTY
    predicate prunes nothing (lists the base prefix, keeps every file)."""

    var constraints: List[PartitionConstraint]

    @staticmethod
    def empty() -> PartitionPredicate:
        return PartitionPredicate(constraints=List[PartitionConstraint]())

    @always_inline
    def num_constraints(self) -> Int:
        return len(self.constraints)

    def constraint_index_for(self, col: String) -> Int:
        """The index of the first constraint on `col`, or -1 if none (this
        assumes one constraint per col in the conjunction for the prefix walk;
        multiple constraints on one col degrade to the fold). Returns an index
        (not an Optional[PartitionConstraint]) so the caller reads the
        constraint by `ref` — `PartitionConstraint` is `Copyable` but NOT
        `ImplicitlyCopyable` (it owns a `List[String]`), so returning it by
        value would force an implicit copy the type does not allow."""
        for i in range(len(self.constraints)):
            if self.constraints[i].col == col:
                return i
        return -1


# =============================================================================
# evaluate_partition_prefix: predicate -> tightest static prefix(es)
#
# =============================================================================
# Walk the partition columns IN PATH ORDER. Consume the longest leading run of
# ENUMERABLE (EQ / IN) constraints, splicing `col=encode(const)/` per value.
# STOP at the first column that is unpinned (no constraint, or a non-enumerable
# constraint). An EQ contributes ONE value to the cartesian; an IN contributes
# N -> the result is the cartesian product of the leading-run enumerations,
# i.e. N targeted prefixes. The residual constraints (the
# tail past the stop point, plus any non-enumerable constraint that caused the
# stop) flow to fold.
# =============================================================================


@fieldwise_init
struct PrefixDerivation(Copyable, Movable, Deinitable):
    """The result of `evaluate_partition_prefix`:
      * `prefixes`: the targeted static list prefixes to issue (one for the
        all-equality case; N for an IN fan-out; the cartesian for mixed
        EQ/IN; times the extra spellings of each value the modelled writers
        spell differently). Each is `base_prefix + "col=<spelling>/..."` ending in
        `/`.
      * `residual_cols`: the partition columns NOT pinned into the prefix
        (the stop column + everything after it) — the fold evaluates the
        predicate's constraints on these against each survivor.
    """

    var prefixes: List[String]
    var residual_cols: List[String]


def _ensure_trailing_slash(p: String) -> String:
    if p.byte_length() == 0:
        return String("/")
    if p.as_bytes()[p.byte_length() - 1] == UInt8(ord("/")):
        return p
    return p + "/"


def evaluate_partition_prefix(
    base_prefix: String,
    partition_cols: List[String],
    partition_types: List[ArrowType],
    predicate: PartitionPredicate,
) -> PrefixDerivation:
    """Derive the tightest static list prefix(es) from `predicate` over the
    ordered `partition_cols` (with matching `partition_types`), rooted at
    `base_prefix`.

    Walks cols in path order, consuming the longest leading run of EQUALITY /
    `IN` constraints. Each pinned col contributes its DISTINCT directory
    spellings `col=<s>/`, where each value's spellings are
    `partition_value_spellings(value)`: komira's `encode_partition_value`
    form, then each of Spark's, DuckDB/pyarrow's and Windows Spark's that
    differs from those before it (raw UTF-8, raw space, `%3A` for `:`). The
    running prefix set fans out by that count (the cartesian). STOPS at the
    first col with no constraint or a non-enumerable constraint; that col and
    all after it become `residual_cols` for the fold. With no enumerable
    leading run the single prefix is `base_prefix` itself (list everything,
    fold filters).

    BOUND. With S_i the distinct spellings of pinned col i (N_i <= S_i <=
    4 * N_i for N_i values: N_i when every value is spelled alike by all four
    writers), the prefix count is the product of S_i. Versus the single-
    spelling product of N_i, the factor is at most 4^k, k = the number of
    pinned cols holding a value the writers spell differently (3^k when no
    value mixes non-ASCII, a space and `:`; 2^k for non-ASCII alone). Every one of
    those prefixes can hold files (a tree may mix spellings per level), so
    none is redundant. A value made only of ASCII letters, digits and
    `- _ . ~` has one spelling, so such predicates derive the prefixes they
    did before (minus any repeat of a value inside an IN-list).

    NO listing happens here — this is pure derivation. The caller issues
    `fs.list` per prefix (concurrently sequentially as the
    correctness fallback).
    """
    var base = _ensure_trailing_slash(base_prefix)
    var running = List[String]()
    running.append(base)  # one running prefix to start (the base)

    var residual = List[String]()
    var stopped = False

    for ci in range(len(partition_cols)):
        ref col = partition_cols[ci]
        var col_type = partition_types[ci] if ci < len(partition_types) else ArrowType.STRING
        if stopped:
            residual.append(String(col))
            continue
        var cidx = predicate.constraint_index_for(col)
        if cidx < 0:
            # no constraint on this col -> cannot pin; stop, residual from here
            stopped = True
            residual.append(String(col))
            continue
        ref c = predicate.constraints[cidx]
        if not c.is_enumerable():
            # non-enumerable (range / OTHER) -> stop; this col goes to the fold
            stopped = True
            residual.append(String(col))
            continue
        # Enumerable: EQ (1 value) or IN (N values) -> fan the running set out
        # over the column's DISTINCT directory spellings. Each value has one
        # to four (komira, Spark, DuckDB/pyarrow, Windows Spark differ on
        # bytes >= 0x80, a space, `:`, ...); see `partition_value_spellings`.
        # All are listed so a tree written by any of those writers is found. Spellings are deduped
        # per column in first-seen order, so a repeated value or two values
        # sharing a spelling never yield the same prefix twice.
        var segs = List[String]()
        for vi in range(len(c.values)):
            var spellings = partition_value_spellings(c.values[vi], col_type)
            for si in range(len(spellings)):
                var seg = String(col) + "=" + spellings[si] + "/"
                if not _contains(segs, seg):
                    segs.append(seg^)
        var next_running = List[String]()
        for ri in range(len(running)):
            ref base_run = running[ri]
            for si in range(len(segs)):
                next_running.append(base_run + segs[si])
        running = next_running^

    return PrefixDerivation(prefixes=running^, residual_cols=residual^)


# =============================================================================
# the post-listing fold: filter_partitions.
# =============================================================================
# Parse each survivor path's partition values, evaluate the predicate's
# constraints against them, drop non-matching files BEFORE any footer opens.
# Only the RESIDUAL constraints need re-checking (the prefix already pinned
# the leading equality run), but evaluating the FULL predicate is harmless and
# robust, so the fold evaluates every constraint that names a partition col.
# =============================================================================


def _compare_values(have: String, op: Int, want: String, arrow_type: ArrowType) -> Bool:
    """Evaluate `have <op> want` for one partition value. Numeric types
    (INT64) compare numerically; DATE32 / TIMESTAMP / STRING compare
    lexicographically (the canonical text forms `YYYY-MM-DD` /
    `YYYY-MM-DD HH:MM:SS` sort correctly lexically, so lexical == temporal for
    these fixed-width forms). EQ/NE work for all types."""
    # INT64 columns compare NUMERICALLY for every op — the on-disk partition
    # value may be zero-padded (`01`) while the predicate constant is `1`, so a
    # string compare would spuriously mis-match. (DATE32 / TIMESTAMP / STRING
    # are canonical fixed-width text and compare exactly / lexically.)
    if arrow_type == ArrowType.INT64:
        var hv = _parse_int_or_zero(have)
        var wv = _parse_int_or_zero(want)
        if op == _OP_EQ:
            return hv == wv
        if op == _OP_NE:
            return hv != wv
        if op == _OP_LT:
            return hv < wv
        if op == _OP_LE:
            return hv <= wv
        if op == _OP_GT:
            return hv > wv
        if op == _OP_GE:
            return hv >= wv
        return False
    # exact / lexical compare for DATE32 / TIMESTAMP / STRING
    if op == _OP_EQ:
        return have == want
    if op == _OP_NE:
        return have != want
    if op == _OP_LT:
        return have < want
    if op == _OP_LE:
        return have <= want
    if op == _OP_GT:
        return have > want
    if op == _OP_GE:
        return have >= want
    return False


def _parse_int_or_zero(v: String) -> Int:
    """Parse a signed decimal string to Int; 0 on empty/garbage (the type
    probe already guaranteed INT64-typed cols hold digit-runs, so this is the
    happy path; the guard keeps it total)."""
    var bs = v.as_bytes()
    if len(bs) == 0:
        return 0
    var neg = False
    var start = 0
    if bs[0] == UInt8(ord("-")):
        neg = True
        start = 1
    elif bs[0] == UInt8(ord("+")):
        start = 1
    var acc = 0
    for i in range(start, len(bs)):
        var b = bs[i]
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return 0
        acc = acc * 10 + (Int(b) - ord("0"))
    return -acc if neg else acc


def _file_matches_predicate(
    keys: List[String], decoded_values: List[String], predicate: PartitionPredicate
) -> Bool:
    """Evaluate `predicate` (a conjunction) against one file's decoded
    partition `(keys, decoded_values)`. Returns True iff EVERY constraint
    holds. An OTHER (opaque) constraint conservatively HOLDS (keeps the file —
     cannot evaluate OR / function-wrapped predicates without the
    optimizer's residual evaluator; correctness over pruning)."""
    for ci in range(predicate.num_constraints()):
        ref c = predicate.constraints[ci]
        if c.op == _OP_OTHER:
            continue  # cannot evaluate; keep the file
        # find the file's value for this constraint's column
        var found_idx = -1
        for k in range(len(keys)):
            if keys[k] == c.col:
                found_idx = k
                break
        if found_idx < 0:
            # the predicate names a partition col the path lacks — under a
            # consistent layout this shouldn't happen; treat as non-matching.
            return False
        ref have = decoded_values[found_idx]
        if c.op == _OP_IN:
            var any = False
            for vi in range(len(c.values)):
                # numeric equality for INT64 (so `01` matches `1`); else exact
                # string equality (DATE32 / TIMESTAMP / STRING are canonical
                # fixed-width text and compare exactly).
                if c.arrow_type == ArrowType.INT64:
                    if _parse_int_or_zero(have) == _parse_int_or_zero(c.values[vi]):
                        any = True
                        break
                elif have == c.values[vi]:
                    any = True
                    break
            if not any:
                return False
        else:
            if not _compare_values(have, c.op, c.values[0], c.arrow_type):
                return False
    return True


# =============================================================================
# PrunedHiveDiscovery[FS].
# =============================================================================


@fieldwise_init
struct PrunedHiveDiscovery(FileDiscovery, Movable, Deinitable):
    """The Hive-partition prune-at-list-prefix `FileDiscovery` impl.

    Field set:
      var _paths: Slab[String]
        The surviving file paths (post prefix-prune + post fold), lexically
        sorted.
      var _pv_keys: Slab[String]
        Flattened partition-key arena. File `i`'s keys are the run
        `[_pv_index[2*i], _pv_index[2*i] + _pv_index[2*i+1])`.
      var _pv_values: Slab[String]
        Flattened DECODED partition-value arena, parallel to `_pv_keys`.
      var _pv_index: Slab[Int]
        Per-file `(start, count)` handle pairs into the key/value arenas.
        Length == 2 * num_paths. NO `List`-inside-slab — pure Int handles.
      var _part_col_names: List[String]
      var _part_col_types: List[ArrowType]
        The inferred partition schema.

    `is_lazy()` is False (eager). `partition_values_at(i)` reconstructs a
    by-value `PartitionValues` from the arena run; `partition_schema()`
    returns the inferred names.
    """

    var _paths: Slab[String]
    var _pv_keys: Slab[String]
    var _pv_values: Slab[String]
    var _pv_index: Slab[Int]
    var _part_col_names: List[String]
    var _part_col_types: List[ArrowType]

    # -------------------------------------------------------------------------
    # Construction — the prune pipeline (prefix + fold +
    # inference). `open_pruned` is the impl-specific factory (NOT on the
    # trait — it takes the partition predicate).
    # -------------------------------------------------------------------------

    @staticmethod
    def open[
        FS: FileSystem
    ](mut fs: FS, path_spec: String) raises -> PrunedHiveDiscovery:
        """The uniform `FileDiscovery.open` factory (predicate-FREE): discover
        the Hive layout under `path_spec` with NO partition pruning — list the
        base recursively, infer the partition schema, keep every file.

        This is the form the `ColumnarMultiConsumerSource` ctor dispatches when
        `DISC` is bound to `PrunedHiveDiscovery` without an optimizer-derived
        predicate (the predicate-driven prune is `open_pruned`, the
        impl-specific factory calls). With an EMPTY predicate the prefix
        derivation is just the base, so this lists the whole tree, infers the
        partition columns from the surviving paths, and exposes the per-file
        partition values for constant-column materialization.
        """
        return PrunedHiveDiscovery.open_pruned(
            fs,
            path_spec,
            List[String](),  # infer cols
            List[ArrowType](),  # infer types
            PartitionPredicate.empty(),  # no pruning
            GlobDiscoveryOptions.default(),
        )

    @staticmethod
    def open_pruned[
        FS: FileSystem
    ](
        mut fs: FS,
        base_prefix: String,
        partition_cols: List[String],
        partition_types: List[ArrowType],
        predicate: PartitionPredicate,
        options: GlobDiscoveryOptions,
    ) raises -> PrunedHiveDiscovery:
        """Build a `PrunedHiveDiscovery` by:
          1. `evaluate_partition_prefix` -> the targeted static prefix(es)
             (`evaluate_partition_prefix`).
          2. `fs.list` per prefix (SEQUENTIAL — a K-in-flight
             concurrent fan-out over the listing transport is
             a perf lever for later; correctness
             first). Union + dedupe + lexically sort the survivors.
          3. fold: parse each survivor's partition values, evaluate
             the predicate, drop non-matching files.
          4. schema inference over the surviving paths (when
             `partition_cols`/`partition_types` are EMPTY, infer them; when
             supplied, honor them as the declared override).
          5. build the arena-handle partition-value storage.

        Pruned partitions are NEVER listed (the headline win) for the
        enumerable case — only the targeted prefix(es) hit `fs.list`.
        """
        var derivation = evaluate_partition_prefix(
            base_prefix, partition_cols, partition_types, predicate
        )

        # ---- Step 2: list the targeted prefix(es), union + dedupe ----
        var listed = List[String]()
        for pi in range(len(derivation.prefixes)):
            var prefix = derivation.prefixes[pi].copy()
            var page = fs.list(prefix)
            for ci in range(len(page)):
                _append_deduped(listed, page[ci].copy())
        sort(listed)

        # Empty-match policy: a pruned-to-nothing list RAISES
        # unless allow_empty_glob (a typo'd partition value silently returning
        # zero rows is the exact foot-gun warns about).
        if len(listed) == 0 and not options.allow_empty_glob:
            raise Error(
                String(
                    "PrunedHiveDiscovery: partition pruning under base '"
                )
                + base_prefix
                + "' matched no files (check the partition predicate /"
                " encode round-trip; set allow_empty_glob=True to permit)"
            )

        # Steps 3-5 are shared with the test seam (`from_listing`): given the
        # listed survivors, run the fold + schema inference + arena build.
        return PrunedHiveDiscovery.from_listing(
            base_prefix,
            listed^,
            partition_cols,
            partition_types,
            predicate,
            options,
        )

    @staticmethod
    def from_listing(
        base_prefix: String,
        var listed: List[String],
        partition_cols: List[String],
        partition_types: List[ArrowType],
        predicate: PartitionPredicate,
        options: GlobDiscoveryOptions,
    ) raises -> PrunedHiveDiscovery:
        """The post-listing pipeline (fold + schema inference + arena build),
        taking an ALREADY-LISTED candidate set instead of dispatching
        `fs.list`. `open_pruned` calls this after listing the targeted
        prefix(es); the discovery-seam UNIT TESTS call it directly with an
        injected listing (the "injected path lists" seam — exercises the
        fold + inference + partition-value storage without FS wiring, the same
        way `filter_paths` tests the glob filter without `fs.list`).

        `listed` is sorted lexically here (callers may pass an unsorted set).
        Steps mirror `open_pruned`
        """
        sort(listed)

        # ---- Step 4 (first half): determine the partition schema ----
        # If the caller declared cols/types, honor them; else infer from the
        # listed paths.
        var col_names = List[String]()
        var col_types = List[ArrowType]()
        if len(partition_cols) > 0:
            for i in range(len(partition_cols)):
                col_names.append(String(partition_cols[i]))
                var t = partition_types[i] if i < len(partition_types) else ArrowType.STRING
                col_types.append(t)
        else:
            _infer_schema_from_paths(listed, col_names, col_types)

        # ---- Step 3: the fold (drop non-matching survivors) ----
        # Parse each survivor's partition values (decoded), evaluate the
        # predicate, keep matches. Done BEFORE any footer opens.
        var surviving_paths = List[String]()
        var surviving_keys = List[List[String]]()
        var surviving_vals = List[List[String]]()
        for pi in range(len(listed)):
            var path = listed[pi].copy()
            var raw_keys = List[String]()
            var raw_vals = List[String]()
            parse_key_value_segments(path, raw_keys, raw_vals)
            # decode each raw value to canonical form using its col type
            var dec_vals = List[String]()
            for k in range(len(raw_keys)):
                var ktype = _type_for_col(col_names, col_types, raw_keys[k])
                dec_vals.append(parse_partition_value(raw_vals[k], ktype))
            if _file_matches_predicate(raw_keys, dec_vals, predicate):
                surviving_paths.append(path^)
                surviving_keys.append(raw_keys^)
                surviving_vals.append(dec_vals^)

        if len(surviving_paths) == 0 and not options.allow_empty_glob:
            raise Error(
                String("PrunedHiveDiscovery: the partition fold under base '")
                + base_prefix
                + "' dropped every file (the residual predicate matched"
                " nothing; set allow_empty_glob=True to permit)"
            )

        # ---- Step 5: build the arena-handle storage ----
        var paths_slab = Slab[String].create(max(len(surviving_paths), 1))
        for i in range(len(surviving_paths)):
            paths_slab.append(surviving_paths[i].copy())

        # flatten keys/values into the two arenas; index holds (start, count).
        var total_pairs = 0
        for i in range(len(surviving_keys)):
            total_pairs += len(surviving_keys[i])
        var keys_arena = Slab[String].create(max(total_pairs, 1))
        var vals_arena = Slab[String].create(max(total_pairs, 1))
        var index = Slab[Int].create(max(2 * len(surviving_paths), 1))
        var cursor = 0
        for i in range(len(surviving_keys)):
            var count = len(surviving_keys[i])
            index.append(cursor)  # start
            index.append(count)  # count
            for k in range(count):
                keys_arena.append(surviving_keys[i][k].copy())
                vals_arena.append(surviving_vals[i][k].copy())
            cursor += count

        return PrunedHiveDiscovery(
            _paths=paths_slab^,
            _pv_keys=keys_arena^,
            _pv_values=vals_arena^,
            _pv_index=index^,
            _part_col_names=col_names^,
            _part_col_types=col_types^,
        )

    # -------------------------------------------------------------------------
    # FileDiscovery trait surface.
    # -------------------------------------------------------------------------

    @staticmethod
    def is_lazy() -> Bool:
        """Eager: all paths are materialized + pruned at `open_pruned` time."""
        return False

    @always_inline
    def num_paths(self) -> Int:
        return self._paths.len()

    @always_inline
    def path_at(self, idx: Int) raises -> String:
        return self._paths[idx].copy()

    def partition_values_at(self, idx: Int) raises -> PartitionValues:
        """Reconstruct file `idx`'s partition `(key, value)` pairs from the
        arena run. Decoded values."""
        var start = self._pv_index[2 * idx]
        var count = self._pv_index[2 * idx + 1]
        var keys = List[String]()
        var vals = List[String]()
        for k in range(count):
            keys.append(self._pv_keys[start + k].copy())
            vals.append(self._pv_values[start + k].copy())
        return PartitionValues(keys=keys^, values=vals^)

    def partition_schema(self) -> PartitionSchema:
        """The inferred partition-column schema (names). The type matrix is
        carried separately in `_part_col_types` and exposed via
        `partition_col_type_at` for typed materialization."""
        var names = List[String]()
        for i in range(len(self._part_col_names)):
            names.append(String(self._part_col_names[i]))
        return PartitionSchema(names=names^)

    @always_inline
    def num_partition_cols(self) -> Int:
        return len(self._part_col_names)

    def partition_col_type_at(self, idx: Int) -> ArrowType:
        """The inferred ArrowType of partition column `idx`. uses
        this to cast the constant partition column to its declared type."""
        return self._part_col_types[idx]

    def partition_col_name_at(self, idx: Int) -> String:
        """The name of partition column `idx` (the `FileDiscovery` hook).
        The source appends the constant column under this name."""
        return String(self._part_col_names[idx])

    def partition_fields(self) -> List[Field]:
        """The partition schema as Arrow `Field`s (name + type, nullable=False)
        — the shape appends to the output schema."""
        var fields = List[Field]()
        for i in range(len(self._part_col_names)):
            fields.append(
                Field(
                    String(self._part_col_names[i]),
                    self._part_col_types[i],
                    False,
                )
            )
        return fields^


# =============================================================================
# module-private helpers.
# =============================================================================


def _contains(xs: List[String], x: String) -> Bool:
    """True iff `x` is an element of `xs`."""
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _append_deduped(mut out: List[String], var candidate: String):
    """Append `candidate` to `out` iff not already present (the N targeted
    prefix-lists can overlap; the union must dedupe —)."""
    for i in range(len(out)):
        if out[i] == candidate:
            return
    out.append(candidate^)


def _type_for_col(
    col_names: List[String], col_types: List[ArrowType], key: String
) -> ArrowType:
    """The inferred/declared ArrowType for partition column `key`, or STRING
    if `key` is not a recognized partition column."""
    for i in range(len(col_names)):
        if col_names[i] == key:
            return col_types[i]
    return ArrowType.STRING


def _infer_schema_from_paths(
    paths: List[String], mut out_names: List[String], mut out_types: List[ArrowType]
):
    """Infer the partition-column schema from the discovered paths:
    derive the ordered col names from the FIRST path's `key=value` segments,
    then type-probe each col over its DECODED value set across all paths
    (DATE32 -> TIMESTAMP -> INT64 -> VARCHAR). Paths whose layout diverges
    from the first are tolerated here (the fold/by-name remap handles
    heterogeneity downstream); only cols present in the first path are
    inferred. Clears the outs first.
    """
    out_names.clear()
    out_types.clear()
    if len(paths) == 0:
        return
    # ordered col names from the first path
    var first_keys = List[String]()
    var first_vals = List[String]()
    parse_key_value_segments(paths[0], first_keys, first_vals)
    if len(first_keys) == 0:
        return
    for i in range(len(first_keys)):
        out_names.append(String(first_keys[i]))
    # per-col decoded value sets across all paths, for the type probe
    var per_col_vals = List[List[String]]()
    for _ in range(len(first_keys)):
        per_col_vals.append(List[String]())
    for pi in range(len(paths)):
        var keys = List[String]()
        var vals = List[String]()
        parse_key_value_segments(paths[pi], keys, vals)
        for ci in range(len(out_names)):
            # find this col in the path's keys
            for k in range(len(keys)):
                if keys[k] == out_names[ci]:
                    # decode with a STRING type for the probe (the probe reads
                    # decoded canonical text; the NULL sentinel decodes to "")
                    try:
                        per_col_vals[ci].append(
                            parse_partition_value(vals[k], ArrowType.STRING)
                        )
                    except:
                        per_col_vals[ci].append(String(vals[k]))
                    break
    for ci in range(len(out_names)):
        out_types.append(probe_partition_type(per_col_vals[ci]))
