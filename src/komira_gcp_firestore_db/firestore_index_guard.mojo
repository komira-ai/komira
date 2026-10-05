# =============================================================================
# komira_gcp_firestore_db/firestore_index_guard.mojo — THE UNDECLARED-COMPOSITE-
#   INDEX GUARD: decide, from the wire shape alone, whether Firestore will serve a
#   structuredQuery off its AUTOMATIC single-field indexes, and if it will not,
#   require that a composite index has been DECLARED for exactly that shape.
# =============================================================================
#
# WHY THIS EXISTS. Two list endpoints of a deployed service were both 500
# FAILED_PRECONDITION on every live database. Same shape both times:
#
#     FROM repo WHERE workspace_id == <wid> ORDER BY name ASC
#
# — one equality plus an ORDER BY on a different field, with no composite index.
# The store tests for BOTH queries existed and were GREEN, because they run
# against SQLite: the one backend in the matrix that never asks for a composite
# index. The suite could not see the defect, so the defect shipped. This file is
# the thing that makes the shape itself checkable, in the driver, on every
# backend-neutral query the Firestore arm builds.
#
# ------------------------------------------------------------------------------
# THE RULE, AS FIRESTORE ACTUALLY IMPLEMENTS IT
# ------------------------------------------------------------------------------
# It was already written down in `firestore_database.mojo` — three times, as PROSE
# COMMENTS ("Firestore auto-indexes every single field, so this needs no declared
# composite index"; "Needs a composite index on (phase_col, created_at) on a live
# database (a provisioning concern)"). A comment cannot fail a build. This is that prose,
# executable:
#
#   * EVERY single field is automatically indexed, ascending and descending. So a
#     one-field equality, a one-field range, and an ORDER BY on that same one
#     field are all free.
#   * MULTIPLE EQUALITIES with NO ordering and no range are ALSO free: Firestore
#     serves them with a zigzag merge join across the single-field indexes.
#   * A composite index becomes REQUIRED the moment the query needs more than one
#     field's index *in a defined order*:
#       - an ORDER BY on a field that is not the sole constrained field,
#       - a range/inequality alongside an equality, or alongside an ORDER BY on
#         another field, or a second inequality field,
#       - an ORDER BY on two or more distinct fields,
#       - an `array-contains` combined with any other filter or ordering.
#
# An equality-filtered field is FREE IN THE ORDERING: the filter pins it to a
# single value, so `WHERE name == 'x' ORDER BY name` needs nothing. That carve-out
# is why the predicate subtracts the equality set from the ordering set before it
# counts.
#
# ------------------------------------------------------------------------------
# WHAT "SERVED BY A DECLARED INDEX" MEANS HERE
# ------------------------------------------------------------------------------
# A Firestore composite index is an ORDERED list of (field, direction). It serves
# a query when
#   1. its LEADING fields are exactly the query's equality fields — as a SET, in
#      any order, because an equality prefix constrains each of those fields to
#      one value and their relative order in the index does not matter; then
#   2. the fields AFTER that prefix begin with the query's inequality field(s)
#      followed by its ORDER BY fields, in the query's order. ⚠ When the query
#      has NO ORDER BY, those inequality fields are ALSO matched as a SET: with
#      nothing ordering the result, their relative order in the index is not the
#      query's to dictate, and Firestore serves the scan off whichever order the
#      index happens to carry (measured against live Firestore — see the
#      carve-out in §3 `_index_serves`). With an ORDER BY present, position and
#      direction are both load-bearing and nothing here is relaxed; and
#   3. an index may be LONGER than the query needs — trailing fields are fine.
#      This is why `ix_review_repo_created_id` (repo_id, created_at DESC, id DESC)
#      serves an ORDER BY created_at DESC that never mentions `id`.
#
# DIRECTIONS. Firestore scans an index in EITHER direction, so one index serves a
# sort order and its FULL reversal — but only the FULL reversal: the flip applies
# to every field of the index, and you cannot flip one term and not another.
#
# ⛔ SO THE REVERSAL IS UNAVAILABLE ONCE THE QUERY HAS AN UNORDERED PREFIX. The
# prefix fields are pinned by the FILTER, so they cannot be flipped to buy the
# ordered suffix its opposite direction: with a prefix, the suffix directions
# must MATCH the declared index, and a mismatched one needs its own index.
#
# THIS PARAGRAPH ONCE ASSERTED THE OPPOSITE — "a single-term ORDER BY is
# therefore always direction-agnostic ... deliberately NOT tightened" — and live
# Firestore falsified it: a minute-cadence job 500d every run on
# FAILED_PRECONDITION demanding (status ASC, updated_at DESC, __name__ DESC) over
# a collection declaring only (status ASC, updated_at ASC). See `_index_serves`
# step 3 for the measurement and the controlled differential that isolates it.
#
# ------------------------------------------------------------------------------
# WHAT THIS DOES **NOT** CLAIM (stated so nobody reads more into a green run)
# ------------------------------------------------------------------------------
#   * DISJUNCTIONS. A `COMBINE_OR` filter is passed through unjudged. The driver's
#     own contract is that the OR-union case is issued by the STORE as two
#     separate `query_rows` calls (see the `_build_structured_query` docstring), so
#     each arm reaches this guard on its own and is judged on its own. A genuine
#     multi-field OR pushed as one group is NOT covered.
#   * DECLARED != DEPLOYED. This proves a shape was declared in the tree. It
#     cannot prove the index was ensured in the target database — that is the
#     deploy path's job, and the list outage above was precisely a shape that
#     WAS declared and never deployed.
#     The two failures are different and both need catching.
#   * `_build_claim_query` renders its own JSON and does not pass through here.
#
# ENCAPSULATION. Value types only — `String` / `Bool` / `List` of flat
# PODs in and out. ZERO UnsafePointer, no wildcard origin, no
# unsafe_from_address, no byte-slab. `def`-based, Mojo 1.0.0b2.
# =============================================================================

from komira_db import (
    Pred,
    Filter,
    Order,
    PRED_EQ,
    PRED_LT,
    PRED_LE,
    PRED_GTE,
    PRED_IS_NULL,
    PRED_IS_NOT_NULL,
    PRED_JSON_KEY_EQ,
    PRED_IN,
    PRED_ARRAY_CONTAINS,
    COMBINE_OR,
)


# =============================================================================
# §1 — the declared-index value model.
# =============================================================================
@fieldwise_init
struct DeclaredIndexField(Copyable, Movable, Deinitable):
    """One field of a declared composite index: the column and its direction.

    `array_contains` selects Firestore's ARRAY-MEMBERSHIP key mode, which is a
    DIFFERENT index from an ordered key on the same column and does not serve an
    ordered query — `desc` is meaningless when it is set."""

    var col: String
    var desc: Bool
    var array_contains: Bool

    def copy(self) -> Self:
        return Self(String(self.col), self.desc, self.array_contains)


@fieldwise_init
struct DeclaredIndex(Copyable, Movable, Deinitable):
    """One declared composite index on one collection. `fields` order is
    LOAD-BEARING — the ordered field list IS the index."""

    var collection: String
    var fields: List[DeclaredIndexField]

    def copy(self) -> Self:
        var fs = List[DeclaredIndexField]()
        for i in range(len(self.fields)):
            fs.append(self.fields[i].copy())
        return Self(String(self.collection), fs^)


struct DeclaredIndexSet(Copyable, Movable, Deinitable):
    """The set of composite indexes a driver has been TOLD exist. A default-
    constructed set is EMPTY, and an empty set is not a disabled guard: it means
    every shape that needs a composite index is refused. That is the intended
    reading — a driver nobody told anything to should not be inventing queries
    the backend will reject."""

    var indexes: List[DeclaredIndex]

    def __init__(out self):
        self.indexes = List[DeclaredIndex]()

    def copy(self) -> Self:
        var out = Self()
        for i in range(len(self.indexes)):
            out.indexes.append(self.indexes[i].copy())
        return out^

    def declare(mut self, var idx: DeclaredIndex):
        self.indexes.append(idx^)

    def declare_asc(mut self, var collection: String, var c0: String, var c1: String):
        """Declare a two-field all-ascending composite index — the dominant
        `(<scope> ASC, <sort> ASC)` list-scan shape."""
        var fs = List[DeclaredIndexField]()
        fs.append(DeclaredIndexField(c0^, False, False))
        fs.append(DeclaredIndexField(c1^, False, False))
        self.indexes.append(DeclaredIndex(collection^, fs^))

    def __len__(self) -> Int:
        return len(self.indexes)

    @staticmethod
    def parse_table_lenient(table: String) -> DeclaredIndexSet:
        """The NON-RAISING parse: `parse_table` below, except that a malformed
        line is SKIPPED instead of raised, for a caller that must not raise (a
        constructor). A skipped line reads exactly like a shape nobody declared,
        so a caller that can raise should use `parse_table`;
        `test_firestore_index_guard` holds the two to the same result on a
        well-formed table."""
        var out = DeclaredIndexSet()
        for line in table.split(String("\n")):
            var row = String(line)
            if row.byte_length() == 0 or row.startswith(String("#")):
                continue
            var parts = row.split(String("|"))
            if len(parts) < 2:
                continue
            var fields = List[DeclaredIndexField]()
            var ok = True
            for i in range(1, len(parts)):
                var tok = String(parts[i])
                var cut = tok.rfind(String(":"))
                if cut < 0:
                    ok = False
                    break
                var col = String(tok[byte=:cut])
                var mode = String(tok[byte=cut + 1 :])
                if mode == String("A"):
                    fields.append(DeclaredIndexField(col^, False, False))
                elif mode == String("D"):
                    fields.append(DeclaredIndexField(col^, True, False))
                elif mode == String("C"):
                    fields.append(DeclaredIndexField(col^, False, True))
                else:
                    ok = False
                    break
            if ok:
                out.indexes.append(DeclaredIndex(String(parts[0]), fields^))
        return out^

    @staticmethod
    def parse_table(table: String) raises -> DeclaredIndexSet:
        """Parse a declaration table: one index per line,
        `collection|col:MODE|col:MODE|...`, MODE in A(sc) / D(esc) / C(ontains);
        an empty line or one starting `#` is skipped. Raises on the first
        malformed field. The flat form is what a caller generates from wherever
        its indexes are declared (a manifest, a deploy bundle)."""
        var out = DeclaredIndexSet()
        for line in table.split(String("\n")):
            var row = String(line)
            if row.byte_length() == 0 or row.startswith(String("#")):
                continue
            var parts = row.split(String("|"))
            if len(parts) < 2:
                continue
            var fields = List[DeclaredIndexField]()
            for i in range(1, len(parts)):
                var tok = String(parts[i])
                var cut = tok.rfind(String(":"))
                if cut < 0:
                    raise Error(
                        String(
                            "firestore declared-index table: malformed field '"
                        )
                        + tok
                        + String("' (want `col:A|D|C`)")
                    )
                var col = String(tok[byte=:cut])
                var mode = String(tok[byte=cut + 1 :])
                if mode == String("A"):
                    fields.append(DeclaredIndexField(col^, False, False))
                elif mode == String("D"):
                    fields.append(DeclaredIndexField(col^, True, False))
                elif mode == String("C"):
                    fields.append(DeclaredIndexField(col^, False, True))
                else:
                    raise Error(
                        String("firestore declared-index table: unknown mode '")
                        + mode
                        + String("' (want A / D / C)")
                    )
            out.indexes.append(DeclaredIndex(String(parts[0]), fields^))
        return out^



# =============================================================================
# §2 — the shape the query needs, derived from the WIRE filter + order.
# =============================================================================
def _is_equality_op(op: UInt8) -> Bool:
    """Ops that pin a field to ONE value. `IS_NULL` counts: Firestore's
    `unaryFilter IS_NULL` is an equality against the null sentinel. `JSON_KEY_EQ`
    counts — it is an equality against a nested field path."""
    return op == PRED_EQ or op == PRED_IS_NULL or op == PRED_JSON_KEY_EQ


def _is_range_op(op: UInt8) -> Bool:
    """Ops that select a RANGE of values. `IS_NOT_NULL` counts: Firestore treats
    `!=` / `not-in` / `IS_NOT_NULL` as inequalities for index-selection purposes."""
    return (
        op == PRED_LT
        or op == PRED_LE
        or op == PRED_GTE
        or op == PRED_IS_NOT_NULL
    )


def _contains(haystack: List[String], needle: String) -> Bool:
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


@fieldwise_init
struct QueryIndexShape(Copyable, Movable, Deinitable):
    """The index-relevant shape of one structuredQuery: which fields are pinned by
    equality, which select a range, which are array-membership tests, and which
    fields the result is ordered by (with directions) AFTER removing the ones an
    equality already pinned."""

    var eq_fields: List[String]
    var range_fields: List[String]
    var array_fields: List[String]
    var order_fields: List[String]
    var order_desc: List[Bool]
    var is_disjunction: Bool

    def copy(self) -> Self:
        return Self(
            self.eq_fields.copy(),
            self.range_fields.copy(),
            self.array_fields.copy(),
            self.order_fields.copy(),
            self.order_desc.copy(),
            self.is_disjunction,
        )

    def describe(self) -> String:
        """A one-line human rendering of the shape, for the refusal message. The
        whole point of failing here rather than in the cloud is that the message
        can name the exact index that is missing."""
        var out = String("")
        for i in range(len(self.eq_fields)):
            if out.byte_length() > 0:
                out += String(" AND ")
            out += self.eq_fields[i] + String(" ==")
        for i in range(len(self.range_fields)):
            if out.byte_length() > 0:
                out += String(" AND ")
            out += self.range_fields[i] + String(" <range>")
        for i in range(len(self.array_fields)):
            if out.byte_length() > 0:
                out += String(" AND ")
            out += self.array_fields[i] + String(" array-contains")
        if out.byte_length() == 0:
            out = String("<no filter>")
        for i in range(len(self.order_fields)):
            out += String(" ORDER BY ") if i == 0 else String(", ")
            out += self.order_fields[i]
            out += String(" DESC") if self.order_desc[i] else String(" ASC")
        return out^

    def unordered_prefix(self) -> List[String]:
        """The index fields BEFORE the ordered suffix, in Firestore's required
        order: every equality field, then every array-contains field, then any
        range field the ORDER BY does not already carry.

        ⚠ THE RANGE/ORDER OVERLAP IS THE SUBTLE ONE, and getting it wrong is how
        this guard first went red on shapes that are genuinely declared. Firestore
        requires a range field to be the FIRST ordered field, so a query like
        `owner_user_id == x AND created_at < t ORDER BY created_at DESC` needs
        `(owner_user_id, created_at)` — ONE `created_at` entry, not two. Emitting
        it in both the prefix and the suffix demanded a three-field index that
        nobody would ever declare and that Firestore does not want."""
        var out = List[String]()
        for i in range(len(self.eq_fields)):
            out.append(String(self.eq_fields[i]))
        for i in range(len(self.array_fields)):
            out.append(String(self.array_fields[i]))
        for i in range(len(self.range_fields)):
            if _contains(self.eq_fields, self.range_fields[i]):
                continue
            if _contains(self.order_fields, self.range_fields[i]):
                continue  # the ordered suffix already carries it
            out.append(String(self.range_fields[i]))
        return out^

    def required_index(self) -> String:
        """The composite index this shape needs, rendered in the same
        `(field ASC, field DESC)` form an index declaration uses — so the
        refusal is also the fix."""
        var prefix = self.unordered_prefix()
        var out = String("(")
        var n = 0
        for i in range(len(prefix)):
            if n > 0:
                out += String(", ")
            out += prefix[i]
            out += (
                String(" CONTAINS")
                if _contains(self.array_fields, prefix[i])
                else String(" ASC")
            )
            n += 1
        for i in range(len(self.order_fields)):
            if n > 0:
                out += String(", ")
            out += self.order_fields[i]
            out += String(" DESC") if self.order_desc[i] else String(" ASC")
            n += 1
        out += String(")")
        return out^


def query_index_shape(filter: Filter, order: List[Order]) -> QueryIndexShape:
    """Derive the index-relevant shape from the PUSHED filter + order.

    ⚠ PRED_IN is deliberately IGNORED. `query_rows` splits IN predicates out and
    evaluates them CLIENT-SIDE in Mojo (the "load candidates, filter in Mojo"
    pattern), so an IN pred never reaches the wire and must not be counted toward
    an index requirement. This function is called with the ALREADY-SPLIT filter;
    the belt-and-braces skip here keeps it correct if it is ever called with a
    raw one."""
    var eq = List[String]()
    var rng = List[String]()
    var arr = List[String]()
    for i in range(len(filter.preds)):
        var op = filter.preds[i].op
        if op == PRED_IN:
            continue
        var col = String(filter.preds[i].col)
        if op == PRED_ARRAY_CONTAINS:
            if not _contains(arr, col):
                arr.append(col^)
        elif _is_equality_op(op):
            if not _contains(eq, col):
                eq.append(col^)
        elif _is_range_op(op):
            if not _contains(rng, col):
                rng.append(col^)

    # An equality pins the field to one value, so ordering by it is free. Drop
    # those terms before counting — this is what makes `WHERE name == 'x' ORDER BY
    # name` correctly need nothing.
    var ocols = List[String]()
    var odesc = List[Bool]()
    for i in range(len(order)):
        var col = String(order[i].col)
        if _contains(eq, col):
            continue
        ocols.append(col^)
        odesc.append(order[i].desc)

    return QueryIndexShape(
        eq^,
        rng^,
        arr^,
        ocols^,
        odesc^,
        filter.combine == COMBINE_OR and len(filter.preds) > 1,
    )


def needs_composite_index(shape: QueryIndexShape) -> Bool:
    """True iff Firestore will NOT serve this shape off its automatic single-field
    indexes. See the module header for the rule; the four clauses below are that
    rule, one clause each."""
    # An array-membership test is served alone by the automatic array index, but
    # combined with ANY other constraint or ordering it needs a composite index.
    if len(shape.array_fields) > 0:
        if (
            len(shape.eq_fields) > 0
            or len(shape.range_fields) > 0
            or len(shape.order_fields) > 0
            or len(shape.array_fields) > 1
        ):
            return True

    # Two or more ordered fields is, by definition, a defined multi-field order.
    if len(shape.order_fields) > 1:
        return True

    # An ordering on a field the filter did not pin, alongside any equality, is
    # the `repo` / `api_key` shape — the one that is 500ing in production.
    if len(shape.order_fields) == 1 and len(shape.eq_fields) > 0:
        return True

    # A range needs its own index scan. Free only when it is the ONLY constrained
    # field and any ordering is on that same field.
    if len(shape.range_fields) > 0:
        if len(shape.range_fields) > 1 or len(shape.eq_fields) > 0:
            return True
        if len(shape.order_fields) > 0 and not _contains(
            shape.range_fields, shape.order_fields[0]
        ):
            return True

    return False


# =============================================================================
# §3 — does a DECLARED index serve the shape?
# =============================================================================
def _same_set(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not _contains(b, a[i]):
            return False
    return True


def _index_serves(idx: DeclaredIndex, shape: QueryIndexShape) -> Bool:
    """See the module header, "WHAT 'SERVED BY A DECLARED INDEX' MEANS HERE"."""
    # 1. the leading fields must be the query's unordered prefix — equalities (as
    #    a SET: an equality pins one value, so their relative order in the index
    #    does not matter), then array-contains, then any range field the ORDER BY
    #    does not already carry (see `unordered_prefix` for why that last clause
    #    is not a de-duplication nicety but the actual Firestore rule).
    var prefix = shape.unordered_prefix()
    var npre = len(prefix)
    if len(idx.fields) < npre:
        return False
    var neq = len(shape.eq_fields)
    var idx_eq = List[String]()
    for i in range(neq):
        if idx.fields[i].array_contains:
            return False  # an array key cannot serve an equality term
        idx_eq.append(String(idx.fields[i].col))
    if not _same_set(idx_eq, shape.eq_fields):
        return False
    # the non-equality part of the prefix is position-sensitive — EXCEPT when the
    # query carries NO `orderBy` at all, where it is matched as a SET.
    #
    # ⭐ WHY THE CARVE-OUT, AND WHY IT IS MEASURED RATHER THAN CAUTIOUS. A query
    # with no `orderBy` imposes NO ordering constraint, so the relative order of
    # the range fields after the equality prefix is not the query's to dictate:
    # Firestore picks an index and the IMPLICIT result ordering follows whatever
    # that index says. Matching them positionally demanded an index in the
    # arbitrary order the caller happened to APPEND its predicates in, which is
    # not a property of the query at all.
    #
    # THE OUTAGE THAT PROVED IT. A job store's stale-job scan appends
    # [phase(eq), updated_at(lt), pod_name(gte), pod_name(lt)], so this loop
    # demanded `(phase, updated_at, pod_name)` and refused the declared
    # (phase, pod_name, updated_at). The scan — the only path that moved a job
    # out of ASSIGNED — was therefore dark continuously, refused HERE,
    # client-side, before Firestore was ever asked.
    #
    # ★ FIRESTORE SETTLED IT, READ-ONLY: that exact shape against the live
    # database answered HTTP 200, ordered by `pod_name` ASC — served by
    # (phase, pod_name, updated_at), the only three-field `jobs` index that
    # database has. The guard was
    # STRICTER THAN FIRESTORE, which is the one direction a guard may not be:
    # it turns a servable query into a permanent outage.
    #
    # ⛔ THIS DOES NOT TOUCH ORDER-BY STRICTNESS. The carve-out is gated on
    # `len(shape.order_fields) == 0`. The moment a query names an ORDER BY, the
    # block below runs and position AND direction stay load-bearing — see the
    # DIRECTIONS note in §3 step 3 and
    # `test_equality_prefix_makes_order_by_direction_load_bearing`, which a live
    # 500 FAILED_PRECONDITION pinned. `array_contains` is likewise
    # excluded: an array key is a different key MODE, not a reorderable range.
    var ranges_are_a_set = (
        len(shape.order_fields) == 0 and len(shape.array_fields) == 0
    )
    if ranges_are_a_set:
        var idx_rng = List[String]()
        var want_rng = List[String]()
        for i in range(neq, npre):
            if idx.fields[i].array_contains:
                return False  # an array key cannot serve a range term
            idx_rng.append(String(idx.fields[i].col))
            want_rng.append(String(prefix[i]))
        if not _same_set(idx_rng, want_rng):
            return False
    else:
        for i in range(neq, npre):
            if idx.fields[i].col != prefix[i]:
                return False
            var want_array = _contains(shape.array_fields, prefix[i])
            if idx.fields[i].array_contains != want_array:
                return False

    # 2. the ordered fields follow, in the query's order, as ordered keys.
    if len(idx.fields) < npre + len(shape.order_fields):
        return False
    for i in range(len(shape.order_fields)):
        if idx.fields[npre + i].array_contains:
            return False
        if idx.fields[npre + i].col != shape.order_fields[i]:
            return False

    # 3. directions: the ordered terms must ALL match the index, or ALL be its
    #    exact reversal.
    #
    # ⛔⛔ THE REVERSAL IS ONLY AVAILABLE WHEN THERE IS NO UNORDERED PREFIX, AND
    # THAT RESTRICTION IS MEASURED, NOT CAUTIOUS. Firestore scans an index
    # backwards as a WHOLE — the flip applies to EVERY field, the prefix
    # included. When the query carries an equality/range prefix, the prefix
    # fields are pinned by the FILTER and cannot be flipped to buy the ordered
    # suffix its opposite direction, so a direction-mismatched suffix needs its
    # OWN index.
    #
    # THIS PARAGRAPH USED TO SAY THE OPPOSITE ("a single-term ORDER BY is
    # therefore always direction-agnostic ... deliberately NOT tightened"), and
    # live Firestore falsified it. Measured every minute on a deployed service,
    # a query answered HTTP 500 with
    #   FAILED_PRECONDITION: The query requires an index.
    #   ... collectionGroups/run/indexes/_
    #       status ASC, updated_at DESC, __name__ DESC
    # over a collection declaring ONLY (status ASC, updated_at ASC).
    #
    # ★ IT IS A CONTROLLED DIFFERENTIAL. The service issued two shapes
    # differing in the ORDER BY DIRECTION AND NOTHING ELSE — same collection,
    # same equality, same inequality column — and the ASC one is served (200)
    # while the DESC one is refused (500). Falsifier:
    # `test_equality_prefix_makes_order_by_direction_load_bearing`.
    #
    # ⚠ A REFUSAL HERE IS NOT A REGRESSION, IT IS THE POINT: it moves a live
    # 500 to a red test on the commit that introduces the shape. The remedy is to DECLARE the index, never to relax this.
    var all_match = True
    var all_reversed = True
    for i in range(len(shape.order_fields)):
        if idx.fields[npre + i].desc != shape.order_desc[i]:
            all_match = False
        else:
            all_reversed = False
    if npre > 0:
        return all_match
    return all_match or all_reversed


def declared_set_serves(
    declared: DeclaredIndexSet, collection: String, shape: QueryIndexShape
) -> Bool:
    for i in range(len(declared.indexes)):
        if declared.indexes[i].collection != collection:
            continue
        if _index_serves(declared.indexes[i], shape):
            return True
    return False


# =============================================================================
# §4 — the guard the driver calls.
# =============================================================================
def require_declared_index(
    declared: DeclaredIndexSet,
    collection: String,
    filter: Filter,
    order: List[Order],
) raises:
    """RAISE if this structuredQuery needs a composite index that `declared` does
    not contain. A no-op for a shape Firestore serves off automatic single-field
    indexes, and a no-op for a shape a declared index covers.

    The message names the collection, the shape, and the exact index that would
    make it work — because the failure this replaces was a bare
    `500 FAILED_PRECONDITION` from which nobody could tell which of ~181 store
    call sites was at fault."""
    var shape = query_index_shape(filter, order)
    if shape.is_disjunction:
        # See "WHAT THIS DOES NOT CLAIM" — a pushed multi-field OR is out of scope
        # rather than silently judged by conjunction rules.
        return
    if not needs_composite_index(shape):
        return
    if declared_set_serves(declared, collection, shape):
        return
    raise Error(
        String("firestore: UNDECLARED COMPOSITE INDEX for collection '")
        + collection
        + String("'. The query `FROM ")
        + collection
        + String(" WHERE ")
        + shape.describe()
        + String(
            "` cannot be served by Firestore's automatic single-field indexes and"
            " no declared composite index covers it — this is a 500"
            " FAILED_PRECONDITION at run time. Declare "
        )
        + collection
        + String(" ")
        + shape.required_index()
        + String(
            " in the DeclaredIndexSet passed to FirestoreDatabase and create the"
            " index in the database, or change the query shape."
        )
    )
