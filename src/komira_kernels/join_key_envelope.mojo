# =============================================================================
# join_key_envelope.mojo — THE COMPOSITE JOIN-KEY ENVELOPE. ONE TABLE.
# =============================================================================
#
# WHICH column types may be a composite hash-join key, and WHICH pairs of them
# may be joined to each other. Both answers come from ONE function,
# `join_key_family`, and every gate in the tree reads it.
#
# ── WHY ONE TABLE, AND WHY THIS IS NOT A STYLE PREFERENCE ──────────────────
#
# The admitted set used to be stated INDEPENDENTLY by four gates, which can
# DIVERGE:
#
#   1  join_node_exec._batch_keys_all_composite_supported
#   2  join_node_exec._schema_keys_all_composite_supported
#   3  join_key_extract.extract_join_key_columns_typed
#   4  optimizer_filter._column_is_supported_key
#
# plus a statement of the PAIRING rule (`_composite_key_family`) and the
# kernel's own raise text. All of them now read this table.
#
# ⛔ THE COST OF #4 MISSING A TYPE IS NOT A REFUSAL, IT IS A BLOW-UP. #4 gates the
# optimizer's CROSS -> INNER equi-key FOLD. A key it declines is not folded,
# so the equi-conjunct stays `Filter(equi, CROSS)` and the walker materialises
# the full N*M Cartesian product first — a single mis-sized allocation that
# returns null. So a
# divergence converts a clean refusal into a Cartesian materialisation. That
# asymmetry is also why the PAIRING rule is enforced at the EXECUTOR and NOT
# here at the optimizer: at the executor a decline is a loud raise, at the
# optimizer a decline is a Cartesian product. Refusing to FOLD a mismatched
# pair would be strictly worse than folding it and failing loud.
#
# ── ADMISSION AND PAIRING ARE THE SAME FACT, READ TWICE ────────────────────
#
# A key type is ADMITTED iff it has a canonicalisation FAMILY. Two keys may be
# PAIRED iff they have the SAME family AND the same type PARAMETERS. So one
# table of `tag -> family` yields both answers and they cannot drift apart:
# `join_key_admitted(k)` is defined AS `join_key_family(k) >= 0`.
#
# ⚠ THE FAMILY ID IS NOT A WIDTH — it is a CANONICALISATION-COMPATIBILITY
# class. Two keys share a family iff the kernel's per-side canonicalisation
# produces comparable bit patterns AND this repo intends the pair to be
# served. The second half is why INT64 and INT32 are DISTINCT families: the
# kernel sign-extends i32 into the SAME Int64 slot INT64 occupies, so folding
# them WOULD WORK — and it is a standing decision that a MISMATCHED-DType
# equi-join FAILS LOUD rather than being served (a deliberate divergence from
# DuckDB, which implicitly casts and answers). Asserted by
# `komira_engine_dispatch.tests.test_join_key_envelope_one_table:
# test_i64_join_i32_is_refused_by_the_pairing_gate`.
#
# ── THE DESCRIPTOR IS NOT AN `ArrowType`, AND THAT IS THE POINT ────────────
#
# A family keyed on an `ArrowType` alone STRUCTURALLY cannot express the rule
# for these types:
#   * `timestamp[us]` and `timestamp[us, tz=UTC]` are BOTH
#     `ArrowType.TIMESTAMP_US`; the timezone lives in `Field._tz`.
#   * every DECIMAL128 shares one tag whatever its `(precision, scale)`.
# A family row keyed on the bare tag would admit a pair this repo must refuse
# and then match it on the raw physical slot — a tz-naive ⋈ UTC join on the
# bare i64, or `decimal(12,2)` ⋈ `decimal(12,4)` comparing unscaled integers,
# where equal VALUES compare unequal and unequal ones compare equal. It is the
# same defect class as a three-slot `Field(name, type, nullable)` rebuild that
# drops `(p, s)` (every value 100x wrong) and, by the identical mechanism,
# drops `_tz`.
#
# ⭐ SO `join_key_pair_compatible` COMPARES THE WHOLE DESCRIPTOR,
# UNCONDITIONALLY, AND THE POLARITY IS THE WHOLE POINT. It is not "compare the
# parameters when the type is a timestamp" — it is "compare the parameters,
# always". A type admitted to the table TOMORROW is parameter-matched BY
# CONSTRUCTION, with no second edit and no second review. As a per-type
# opt-in, a newly admitted parameterised type would default to
# match-on-the-tag — the fail-OPEN direction. Same argument, same shape, as
# `Field.list_item_type_is_lossless`'s allow-list.
#
# ⚠ THE COMPARISON WAS INERT WHEN IT LANDED AND IS NOT ANY MORE. When
# `join_key_pair_compatible` was written
# none of the five admitted tags carried a timezone or a `(p, s)`, so
# `join_key_params_equal` was true for every pair `of_schema_column` could
# build — which is what made that commit a refactor. TIMESTAMP_US arrived the
# same day (tz-naive vs tz-aware share the tag) and DECIMAL128 one commit
# later, so BOTH parameters are now load-bearing. ⛔ Read that ordering the
# right way round: the signature was widened BEFORE the type set on purpose.
# Types-first-signature-later builds the silent-wrong answer in and then has
# to find it.
#
# ⚠ WHAT THE DESCRIPTOR DELIBERATELY DOES **NOT** CARRY, TODAY.
# `Field._dict_index_type`. Two DICTIONARY keys whose CODES have different
# widths currently reach the same-dict fast path on the strength of a
# dictionary-DATA fingerprint alone; whether that is a live defect is
# UNMEASURED, and including the slot here would change today's behaviour for
# a STRING ⋈ DICTIONARY pair (the default is INT32 on both sides, but a dict
# with int8 codes would newly refuse). Out of scope; carded, not fixed.
# `Field._union_type_ids` / `_flags` / kv-metadata cannot reach a join key at
# all — no union or metadata-discriminated type has a family.
#
# ── WHY EACH ROW IS IN THE TABLE (history, carried from the ladders it
#    replaced — do not re-derive these) ───────────────────────────────────
#
# ★ INT32. It was NOT admitted, and because the single-key
# non-INT64 redirect in `join_node_exec._try_run_join` is DType-AGNOSTIC, the
# route gate was the ONLY thing standing between an int32-keyed join and an
# answer: redirect -> gate says no -> decline -> and post the NOE-T16
# spine-delete a decline on the walker path is a RAISE, not a fallback. So
# `join(l, r, ["k"], ["k"])` over an int32 `k` — an ordinary SQL join — could
# not execute at all. The kernel sign-extends INT32 into the Int64 slot
# (injective over the whole Int32 domain, hence exact), and the gates were
# widened with it in the same commit, because a gate that admits a DType the
# kernel raises on is worse than one that refuses.
#
# ★ FLOAT64 / STRING / DICTIONARY — the q2 REGRESSION FIX (EngineContext
# delete). q2's final join folds the `ps_supplycost == min_cost` equality into
# the composite join keys, so one key column is FLOAT64. The composite leaf
# ALREADY canonicalises FLOAT64 (NaN / -0.0 normalised -> Int64 bit pattern),
# STRING (hash + side-channel exact re-check) and DICTIONARY keys, so gating
# to the kernel's full envelope rather than INT64-only is the byte-correct
# serve.
#
# ★ TIER 1 — BOOL / INT8 / INT16 / UINT8 / UINT64 / DATE32 / TIMESTAMP_MS /
# TIMESTAMP_US (+ TIMESTAMP_US with a timezone). The key types are tiered by
# WHAT THE KERNEL HAS TO LEARN; these are the ones it already knows.
# DATE32 is physically `PrimitiveArray[int32]` and every TIMESTAMP_* is
# physically `PrimitiveArray[int64]`, so for those the widening is a TAG
# ADMISSION with no value code at all. INT8 / INT16 / UINT8 widen into the
# Int64 slot exactly, by the same injectivity argument INT32 makes.
#
# ⛔ TWO OF THE EIGHT ARE NOT TAG ADMISSIONS, AND BOTH ARE SILENT-WRONG-ANSWER
# SHAPED:
#   * UINT64 reinterprets into the Int64 slot rather than converting. ⚠ AND
#     THE PREMISE THAT MADE THIS URGENT IS FALSE ON THIS TOOLCHAIN, MEASURED:
#     `Int(UInt64)` on Mojo 1.0.0 wraps BIT-PRESERVINGLY, so the generic
#     `Int64(Int(x))` already answers correctly above 2^63 and the explicit
#     reinterpret changes NO answer. It stays because bit-preservation of
#     a narrowing unsigned->signed conversion is not a contract Mojo states,
#     and depending on it is the fail-open direction. Full measurement, and the
#     mutation that proves the arm is live rather than dead code, in
#     `_numeric_key_slots`' `uint64` branch.
#   * BOOL is a BIT-PACKED `BooleanArray`, not a `PrimitiveArray` slot, so
#     `_numeric_key_slots` cannot see it at all. It has its own render.
#
# ⛔ WHAT WAS DELIBERATELY HELD BACK, AND WHY — so the asymmetry is not read as
# an oversight and re-derived:
#   * ⭐ FLOAT32, BINARY, DECIMAL128 — TIERS 2-4. Each needs a new value
#     transform; each has one, and the per-row argument is on the table rows themselves.
#     ⚠ FLOAT32 is its OWN family, not FLOAT64's. f32 -> f64 is exact, so
#     folding them would WORK — and that is the same argument INT32 makes
#     against being folded into INT64, answered the same way: a
#     mismatched-DType equi-join FAILS LOUD here.
#     ⚠ BINARY is its own family, not STRINGLIKE's, for the same reason,
#     even though both arrive at `_string_bytes_equal`. STRING and
#     DICTIONARY share a family because this repo intends `varchar ⋈ dict`
#     to be SERVED; it does not intend `varchar ⋈ blob` to be.
#   * TIMESTAMP_S / TIMESTAMP_NS / the legacy TIMESTAMP tag / DATE64 /
#     UINT16 / UINT32. These are PHYSICALLY identical to rows already here and
#     would cost nothing to admit — which is exactly why they are not here.
#     No executing test grades their NULL-key and pairing behaviour, so an
#     admission would ship a served type nobody observes. Admit them together
#     with tests that grade them.
#
# ── ADDING A TYPE TO THE ENVELOPE ──────────────────────────────────────────
#
# Add ONE row to `join_key_family`, and add the matching arm to
# `extract_join_key_columns_typed`. The four gates widen with it, in one
# commit, by construction. `test_join_key_envelope_one_table.mojo` fails if
# the two halves disagree — an admitted tag with no kernel arm raises an
# INTERNAL error naming the gap, rather than the ordinary out-of-envelope one.
#
# ⛔ AND BECAUSE THAT IS CHEAP, READ THIS BEFORE YOU DO IT. It is one row, so
# the review has to be deliberate:
#
#  1. NULL KEYS ARE A PER-DTYPE RENDER, AND EASY TO GET WRONG. An arm that
#     lets an Arrow NULL through as whatever value sits under its cleared
#     validity bit makes the composite kernels insert it and MATCH IT AS A
#     REAL KEY. SQL says a
#     NULL key matches nothing; the encoding that enforces it
#     (`_NAN_SENTINEL_BITS`) is written per arm. A new row needs its own
#     null-key coverage.
#     ⚠ Value-level fixtures that carry no NULL keys for the new type will
#     not catch it; test the NULL-key render directly.
#  2. THE PAIRING RULE IS NOT GRADED BY SELF-JOINS. A self-join (one fixture
#     scanned twice) always carries identical `_tz` and identical `(p, s)` on
#     both sides. The direct falsifier is
#     `komira_engine_dispatch.tests.test_join_key_envelope_one_table`;
#     extend it with the pair you are admitting.
#  3. AN INJECTIVE RENDER IS THE WHOLE ARGUMENT. INT32 is exact because
#     sign-extension is injective over the Int32 domain. UINT64 is NOT: a u64
#     above 2^63 has no Int64 value, so it must BITCAST rather than `Int()`.
#     BOOL is bit-packed (`BooleanArray`, not `PrimitiveArray`) and needs its
#     own 1-bit render. DECIMAL128 does not fit the Int64 slot at all.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema


# The canonicalisation families. `-1` is "not a join key at all"; every other
# value is a class within which the kernel's per-side canonicalisation
# produces comparable bit patterns.
comptime JOIN_KEY_FAMILY_NONE = -1
comptime JOIN_KEY_FAMILY_INT64 = 0
comptime JOIN_KEY_FAMILY_FLOAT64 = 1
comptime JOIN_KEY_FAMILY_STRINGLIKE = 2
comptime JOIN_KEY_FAMILY_INT32 = 3
# ── TIER 1 ────────────────────────────────────────────────────
# ⚠ ONE FAMILY PER TAG, and that is not an oversight about "families should
# group things". A family is a set the kernel may join ACROSS, and the repo's
# standing decision is that a MISMATCHED-DType equi-join FAILS LOUD (see the
# INT32 note in the header). Two tags belong in ONE family only where this
# repo intends the CROSS pair to be served — which, of everything in this
# table, is true of exactly STRING ⋈ DICTIONARY.
comptime JOIN_KEY_FAMILY_BOOL = 4
comptime JOIN_KEY_FAMILY_INT8 = 5
comptime JOIN_KEY_FAMILY_INT16 = 6
comptime JOIN_KEY_FAMILY_UINT8 = 7
comptime JOIN_KEY_FAMILY_UINT64 = 8
comptime JOIN_KEY_FAMILY_DATE32 = 9
comptime JOIN_KEY_FAMILY_TIMESTAMP_MS = 10
# ⭐ TIMESTAMP_US AND TIMESTAMP_US_UTC SHARE THIS ROW AND ARE SEPARATED BY
# `join_key_params_equal`, NOT BY A SECOND FAMILY. They are the SAME
# `ArrowType.TIMESTAMP_US`; the timezone lives in `Field._tz`, which is why
# the descriptor carries it. This is the FIRST parameterised row in the
# table, i.e. the first input on which `join_key_pair_compatible`'s
# unconditional parameter comparison is load-bearing rather than inert.
comptime JOIN_KEY_FAMILY_TIMESTAMP_US = 11
# ── TIERS 2-4 ─────────────────────────────────────────────────
# The three rows tier 1 deliberately held back, each because it needed a NEW
# VALUE TRANSFORM rather than a tag admission. Each now has one; see the
# per-row notes in the header.
comptime JOIN_KEY_FAMILY_FLOAT32 = 12
comptime JOIN_KEY_FAMILY_BINARY = 13
# ⭐ THE SECOND PARAMETERISED ROW, AND THE ONE THE DESCRIPTOR WAS WIDENED FOR.
# Every DECIMAL128 shares this tag whatever its `(precision, scale)`, and two
# decimals of DIFFERENT scale whose VALUES are equal have DIFFERENT unscaled
# integers — so a pair matched on the raw 16 bytes would answer wrong in BOTH
# directions (equal values comparing unequal, unequal values comparing equal).
# `join_key_params_equal` is what refuses the pair; it is not optional here.
comptime JOIN_KEY_FAMILY_DECIMAL128 = 14

# The whole ArrowType space. `ArrowType.LARGE_LIST_VIEW` is 49 and is the
# largest tag declared in `arrow_types.mojo`. Used only to DERIVE the envelope's
# human-readable description from the table, so no second list of admitted
# tags is ever written down.
comptime JOIN_KEY_MAX_ARROW_TYPE_ID = 49


@fieldwise_init
struct JoinKeyType(Copyable, Movable):
    """One join key's COMPLETE type identity: the Arrow tag PLUS the type
    parameters that live off the tag (`Field._tz` for TIMESTAMP*,
    `Field.decimal_precision` / `_scale` for DECIMAL*).

    ⚠ CONSTRUCT IT THROUGH `of_schema_column*` / `bare`, not fieldwise, unless
    you are a test pinning the pairing rule. Those constructors NORMALISE: a
    parameter is carried only for a tag that Arrow says is parameterised by
    it, so a stray `decimal_precision` sitting on an INT64 field cannot make
    two ordinary int64 keys refuse each other."""

    var arrow_type: ArrowType
    var tz: String
    var precision: Int
    var scale: Int

    @staticmethod
    def bare(t: ArrowType) -> JoinKeyType:
        """The descriptor for a tag with no parameters attached. Correct for
        every currently-admitted tag; for a parameterised one it describes the
        UNPARAMETERISED member of that family, which is why callers that have
        a Schema must use `of_schema_column` instead."""
        return JoinKeyType(t, String(""), 0, 0)

    @staticmethod
    def absent() -> JoinKeyType:
        """The descriptor for a key column that is NOT PRESENT. `ArrowType.NULL`
        has no family, so an absent key declines — the structural guard that a
        dropped key column never silently joins on fewer keys."""
        return JoinKeyType.bare(ArrowType.NULL)

    @staticmethod
    def of_schema_column(schema: Schema, index: Int) -> JoinKeyType:
        """Read column `index`'s complete key identity off `schema`.

        ⚠ READS THE PARALLEL ACCESSORS, NOT `field_at_unchecked(index)`. That
        method rebuilds a whole `Field` — cloning its metadata keys, metadata
        values and three child lists — which is several allocations to answer
        a question about four scalars."""
        var t = schema.field_arrow_type(index)
        return JoinKeyType(
            t,
            schema.field_tz(index) if arrow_type_carries_timezone(t)
                else String(""),
            schema.field_decimal_precision(index)
                if arrow_type_carries_decimal_params(t) else 0,
            schema.field_decimal_scale(index)
                if arrow_type_carries_decimal_params(t) else 0,
        )

    @staticmethod
    def of_schema_column_named(schema: Schema, name: String) -> JoinKeyType:
        """`of_schema_column` by NAME. A missing column returns `absent()`,
        which has no family and therefore declines."""
        for i in range(schema.num_columns()):
            if schema.field_name(i) == name:
                return JoinKeyType.of_schema_column(schema, i)
        return JoinKeyType.absent()

    @staticmethod
    def of_field(f: Field) -> JoinKeyType:
        """`of_schema_column` for a caller that already holds the `Field`."""
        return JoinKeyType(
            f.arrow_type,
            f._tz.copy() if arrow_type_carries_timezone(f.arrow_type)
                else String(""),
            f.decimal_precision
                if arrow_type_carries_decimal_params(f.arrow_type) else 0,
            f.decimal_scale
                if arrow_type_carries_decimal_params(f.arrow_type) else 0,
        )


def arrow_type_carries_timezone(t: ArrowType) -> Bool:
    """True iff Arrow says a TIMEZONE is part of this type's identity. This is
    an ARROW fact, not a join-envelope policy — it is what makes the
    normalisation in `of_schema_column` safe."""
    return t.is_timestamp()


def arrow_type_carries_decimal_params(t: ArrowType) -> Bool:
    """True iff Arrow says `(precision, scale)` is part of this type's
    identity. An ARROW fact, like `arrow_type_carries_timezone`."""
    return t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256


def join_key_family(kt: JoinKeyType) -> Int:
    """⭐ THE TABLE. The composite-key canonicalisation FAMILY of a key type,
    or `JOIN_KEY_FAMILY_NONE` for a type that may not be a join key at all.

    This is the ONE statement of the join-key envelope. `join_key_admitted`,
    `join_key_pair_compatible`, `join_key_envelope_description`, the two
    executor route gates, the optimizer fold gate and the kernel's own
    defensive raise are all derived from it.

    ⚠ STRING and DICTIONARY share family 2 ON PURPOSE: both hash through the
    same string side-channel and re-check byte-exactly, so the pair is served.

    ⚠ INT32 is family 3 and NOT family 0 ON PURPOSE — see the header. Folding
    it into 0 would SERVE an i64 ⋈ i32 equi-join; this repo fails it loud."""
    if kt.arrow_type == ArrowType.INT64:
        return JOIN_KEY_FAMILY_INT64
    if kt.arrow_type == ArrowType.FLOAT64:
        return JOIN_KEY_FAMILY_FLOAT64
    if (
        kt.arrow_type == ArrowType.STRING
        or kt.arrow_type == ArrowType.DICTIONARY
    ):
        return JOIN_KEY_FAMILY_STRINGLIKE
    if kt.arrow_type == ArrowType.INT32:
        return JOIN_KEY_FAMILY_INT32
    # ── TIER 1. Each of these has an arm in
    # `extract_join_key_columns_typed`, and its own NULL-key leg in
    # `komira_engine_operators.tests.test_join_multi_key_null_key`. ⛔ Do
    # not add a row here without both: a table that admits a tag the kernel
    # has no arm for raises the INTERNAL error rather than the ordinary
    # refusal, and a row graded only on a NULL-free fixture can match a NULL
    # key as a real key (the per-arm `_NAN_SENTINEL_BITS` encoding).
    if kt.arrow_type == ArrowType.BOOL:
        return JOIN_KEY_FAMILY_BOOL
    if kt.arrow_type == ArrowType.INT8:
        return JOIN_KEY_FAMILY_INT8
    if kt.arrow_type == ArrowType.INT16:
        return JOIN_KEY_FAMILY_INT16
    if kt.arrow_type == ArrowType.UINT8:
        return JOIN_KEY_FAMILY_UINT8
    if kt.arrow_type == ArrowType.UINT64:
        return JOIN_KEY_FAMILY_UINT64
    if kt.arrow_type == ArrowType.DATE32:
        return JOIN_KEY_FAMILY_DATE32
    if kt.arrow_type == ArrowType.TIMESTAMP_MS:
        return JOIN_KEY_FAMILY_TIMESTAMP_MS
    if kt.arrow_type == ArrowType.TIMESTAMP_US:
        return JOIN_KEY_FAMILY_TIMESTAMP_US
    # ── TIERS 2-4. Each of these three needs a NEW VALUE TRANSFORM, which is
    # why each has its own arm in `extract_join_key_columns_typed`:
    #   * FLOAT32 — widened to Float64 (EXACT, every f32 is an f64) and then
    #     put through the SAME `_canonicalize_float64_for_hash` FLOAT64 uses.
    #     ⛔ NOT a tag admission: the generic `Int64(Int(x))` fall-through
    #     TRUNCATES, so `0.25` and `0.5` would both land in slot 0 and
    #     CROSS-MATCH. `_numeric_key_slots` takes the float branch on
    #     `dt.is_floating_point()` for exactly that reason.
    #   * BINARY — rides the STRING side channel. Its equality kernel
    #     `_string_bytes_equal` is a BYTE-AT-A-TIME compare with no UTF-8
    #     semantics anywhere in it, so raw bytes are the shape it already
    #     serves (`StringArray.from_byte_lists` is the pre-existing sanction
    #     for a byte-faithful StringArray).
    #   * DECIMAL128 — also rides the STRING side channel, over the value's
    #     16 raw little-endian two's-complement bytes. It does NOT fit the
    #     Int64 slot, and an i128 hashed INTO one would be a hash-only
    #     equality, i.e. a silent cross-match. Two's complement is a UNIQUE
    #     representation of an integer, so at EQUAL SCALE byte equality is
    #     exactly value equality — and the equal-scale premise is enforced by
    #     `join_key_params_equal`, not assumed.
    if kt.arrow_type == ArrowType.FLOAT32:
        return JOIN_KEY_FAMILY_FLOAT32
    if kt.arrow_type == ArrowType.BINARY:
        return JOIN_KEY_FAMILY_BINARY
    if kt.arrow_type == ArrowType.DECIMAL128:
        return JOIN_KEY_FAMILY_DECIMAL128
    return JOIN_KEY_FAMILY_NONE


def join_key_admitted(kt: JoinKeyType) -> Bool:
    """True iff `kt` may be a composite join key. DEFINED as "has a family" —
    admission and pairing cannot drift apart because they are one table."""
    return join_key_family(kt) >= 0


def join_key_params_equal(a: JoinKeyType, b: JoinKeyType) -> Bool:
    """True iff `a` and `b` agree on every type parameter that lives OFF the
    Arrow tag. Compared UNCONDITIONALLY, so a parameterised type admitted to
    the table tomorrow is parameter-matched with no second edit."""
    return a.tz == b.tz and a.precision == b.precision and a.scale == b.scale


def join_key_pair_compatible(a: JoinKeyType, b: JoinKeyType) -> Bool:
    """True iff a key of type `a` may be equi-joined to a key of type `b`.

    Both must be admitted, they must share a canonicalisation family, and they
    must agree on every off-tag type parameter. The kernel canonicalises each
    side INDEPENDENTLY by its own type, so a pair that fails this would hash
    to different bit patterns and SILENTLY never match — or, worse for the
    parameterised types, match the WRONG rows on the raw physical slot."""
    var fa = join_key_family(a)
    if fa < 0:
        return False
    if fa != join_key_family(b):
        return False
    return join_key_params_equal(a, b)


def join_key_envelope_description() -> String:
    """The admitted tags, rendered for a diagnostic — DERIVED from the table by
    enumerating the ArrowType space, never hand-listed. A raise text that
    names the envelope is the place a stale restatement is least likely to be
    noticed and most likely to be believed: the kernel's own message claimed
    "INT64 + FLOAT64 + STRING + DICTIONARY" for the 26 days after INT32 was
    admitted."""
    var out = String("")
    for tid in range(0, JOIN_KEY_MAX_ARROW_TYPE_ID + 1):
        var t = ArrowType(UInt8(tid))
        if join_key_admitted(JoinKeyType.bare(t)):
            if out.byte_length() > 0:
                out += String(", ")
            out += String(t)
    return out^
