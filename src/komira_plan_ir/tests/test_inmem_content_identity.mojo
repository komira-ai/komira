# =============================================================================
# THE IN-MEMORY CONTENT-DERIVED IDENTITY
# =============================================================================
#
# THE FACT THIS FILE EXISTS FOR, stated once:
#
#     `InMemorySource._identity` is `_mix64(komira_next_inmem_source_id())` —
#     a process-global monotonic counter implemented C-side in `_posix_shim.c`.
#     Write a plan carrying it to bytes, read it back in a SECOND PROCESS, and
#     the id either collides with an unrelated table or fails to match the same
#     one. It cannot serialize, so it must not be the scan IR's identity.
#
# `scan_binding.mojo:scan_kind_id` states the requirement — `kind_id` is a
# hashed name rather than a tag byte because it must be "stable ACROSS
# PROCESSES, so it survives serialization". Audit rule R9
# (`scan_identity_audit.mojo`) is that sentence made mechanical for a corpus.
# This file is it made mechanical for the KIND.
#
# ---------------------------------------------------------------------------
# THE TWO HALVES, AND WHY NEITHER ALONE IS A TEST
# ---------------------------------------------------------------------------
#
#   STABLE       two separately constructed sources over IDENTICAL content get
#                the SAME identity.  RED against the counter.
#   DISCRIMINATE two sources over DIFFERENT content get DIFFERENT identities.
#                RED against a constant — `return 0` satisfies STABLE.
#
# Each half is satisfiable for free without the other, which is why both are
# here and why the mutants that kill them are named in the docstrings rather
# than described in the abstract.
#
# MUTATION CHECK — one line of `inmem_scan_binding` changed each time:
#
#   MUTANT 1  `structural_id=ims.fingerprint()` (the per-construction counter).
#               FAIL test_two_sources_over_identical_content_share_one_identity
#               PASS test_two_sources_over_different_content_get_different_identities
#
#   MUTANT 2  `structural_id=UInt64(0)`.
#               PASS test_two_sources_over_identical_content_share_one_identity
#               FAIL test_two_sources_over_different_content_get_different_identities
#
# The two halves fail on OPPOSITE mutants and neither mutant is caught by both.
# The pair is the specification; either one alone is a gate with a hole the
# other covers.
#
# The class-level scan-identity audit catches MUTANT 1 too: under it, R9
# (REPRODUCIBILITY) fails for kind 'komira.in_memory'.
#
# ---------------------------------------------------------------------------
# THE COLLISION QUESTION, WITH A NUMBER
# ---------------------------------------------------------------------------
#
# The identity is 64-bit FNV-1a over the schema text and every backing buffer's
# bytes (`InMemorySource._structural_id_compute` -> `RecordBatch.content_hash`
# -> `Column.content_hash`). A collision means two DIFFERENT in-memory tables
# render one `bsid=`, therefore one plan text, therefore one
# `LogicalPlan.structural_hash()`, therefore one `factory_hash` — and one
# query's compiled plan is handed to the other. That is a SILENT WRONG ANSWER
# (the same class as two distinct tables CSE'd into a self-join). Said plainly
# rather than hedged.
#
# WHAT MAKES IT ACCEPTABLE: `plan_display` renders the SAME 64-bit value, from
# the SAME fold, for a legacy in-memory scan (`inmem_id=`); a binding-backed
# scan carries it as `bsid=` instead. Per-pair probability 2^-64 ~ 5.4e-20;
# the birthday bound puts a 50% chance of ANY collision at ~2^32 (4.3 billion)
# distinct in-memory tables sharing one plan cache in one process. The
# alternative — the counter — is collision-free WITHIN a process and
# meaningless ACROSS one.
#
# ⚠ THE ONE THING THAT WOULD CHANGE THE EXPOSURE, so it is written down rather
# than left for a future reader to discover: FOLDING FEWER BYTES. The fold
# covers the schema text, the batch count, each batch's row count and every
# buffer of every column. A future "optimisation" that sampled buffers instead
# of folding them whole would move the collision probability from 2^-64 to
# whatever the sampling misses, silently. `test_the_content_identity_separates_
# a_single_byte` is the tripwire.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_not_equal,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_IN_MEMORY
from komira_plan_ir.scan_identity_render_audit import (
    render_corpora_plan_text,
)
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_KIND_NAME_IN_MEMORY,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_NONE,
    scan_kind_id,
)
from komira_scan_source.scan_identity_audit import (
    ScanIdentityCorpus,
    audit_scan_identity_coverage,
)
from komira_scan_source.scan_kind_registry import (
    ScanKindDescriptor,
    ScanKindRegistry,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import (
    LEGACY_SOURCE_TYPE_IN_MEMORY,
    SourceVariant,
    inmem_scan_binding,
    inmem_scan_descriptor,
    inmem_scan_identity_corpus,
)


# =============================================================================
# GOLDEN LITERALS — derived by an independent reference transcription.
# =============================================================================
#
# ⚠ THE `bid` LITERALS ARE INDEPENDENT; THE `bsid` ONE IS NOT, AND THE
# DIFFERENCE IS DELIBERATE. `identity_hash()` is pinned against literals
# derived INDEPENDENTLY (a Python transcription of `param_hash_*` +
# `schema_identity_hash` + `PushdownGate.hash_into`, about 60 lines of
# arithmetic); the transcription reproduces the already-pinned empty-schema
# literal as its own self-check before producing them. The CONTENT hash is not transcribed: it is a fold over `Schema.write_to`
# text plus every Arrow buffer's bytes and per-column metadata, and a Python
# re-implementation of the Arrow buffer layout is likelier to be wrong than the
# thing it checks. It is pinned MEASURED, and it is guarded by PROPERTY
# (stability, discrimination, reproducibility, cross-process equality) — which
# is a stronger statement about a content hash than a single literal is.
comptime INMEM_KIND_ID: UInt32 = 1495458021
comptime INMEM_SCHEMA_ID_C0: UInt64 = 7709494147569500513
comptime INMEM_SCHEMA_ID_C1: UInt64 = 4014725071283761826
comptime INMEM_BID_ANON_C0: UInt64 = 9011618659995074341
comptime INMEM_BID_ANON_C1: UInt64 = 15669056245047185644
comptime INMEM_BID_NAMED_T_C0: UInt64 = 11852130693867722586

comptime INMEM_SID_C0_8ROWS_SEED0: UInt64 = 5502437198329981542
"""MEASURED, not derived — see the block above. It is ALSO the cross-process
check: a literal in a source file is read by a compiler in one process and
compared in another, on another machine, on every run. A content hash that
folded an address or a counter could not survive that, and nothing else in
this file could tell.

`scan_identity_audit.mojo`'s R9 docstring quotes the same value for two
`InMemorySource.from_record_batch` calls over byte-identical 8-row INT64
batches. The fixture here is an 8-row INT64 batch and it reproduces the value
exactly. A counter cannot do that; a heap address cannot do that; a fold over
the bytes does it without being asked."""


# =============================================================================
# FIXTURES.
# =============================================================================


def _batch(var field_name: String, num_rows: Int, seed: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(field_name^, ArrowType.INT64, nullable=False))
    var vals = List[Int64]()
    for i in range(num_rows):
        vals.append(Int64(seed + i))
    return RecordBatch.from_columns_1(
        sb.build(), PrimitiveArray[DType.int64].from_list(vals)
    )


def _source(
    var field_name: String, num_rows: Int, seed: Int
) raises -> InMemorySource:
    return InMemorySource.from_record_batch(_batch(field_name^, num_rows, seed))


def _identity(
    var field_name: String, num_rows: Int, seed: Int
) raises -> UInt64:
    """THE VALUE UNDER TEST — the identity a binding-backed scan node carries,
    read off the production binding builder rather than off `InMemorySource`.
    Going through `inmem_scan_binding` is the point: an identity that is right
    on the source and never reaches the binding is a recurring failure shape."""
    return inmem_scan_binding(_source(field_name^, num_rows, seed)).structural_id


# =============================================================================
# 1. THE TWO HALVES.
# =============================================================================


def test_two_sources_over_identical_content_share_one_identity() raises:
    """RED AGAINST THE COUNTER — mutant 1 in this file's header (supplying
    the source's per-construction `fingerprint()` as `structural_id`).

    Two SEPARATE `from_record_batch` calls, byte-identical content, no shared
    Arc and no `.copy()` anywhere — so nothing but the fold can make these
    equal. This is the half that makes a plan cache HIT: `plan_cse`, subquery
    dedup and the Layer-1 factory cache all key on the plan text, and
    `in_memory_source.mojo` records what happened when a per-ctor id reached it
    ("broke subquery dedup + the Layer-1 plan-compile cache")."""
    assert_equal(_identity(String("c0"), 8, 0), _identity(String("c0"), 8, 0))


def test_two_sources_over_different_content_get_different_identities() raises:
    """RED AGAINST A CONSTANT — mutant 2. Without this half, `return 0`
    satisfies the test above and the gate is a gate over nothing.

    Four axes, because the fold has four inputs and a discriminator that misses
    one is a silent merge in the plan-compile cache:
      values / row count / schema field name / batch count."""
    var base = _identity(String("c0"), 8, 0)
    assert_not_equal(base, _identity(String("c0"), 8, 999))  # VALUES
    assert_not_equal(base, _identity(String("c0"), 9, 0))  # ROW COUNT
    assert_not_equal(base, _identity(String("c1"), 8, 0))  # SCHEMA
    var sl = Slab[RecordBatch].create(2)
    sl.append(_batch(String("c0"), 8, 0))
    sl.append(_batch(String("c0"), 8, 0))
    assert_not_equal(
        base,
        inmem_scan_binding(
            InMemorySource.from_record_batches(sl^)
        ).structural_id,
    )  # BATCH COUNT


def test_the_content_identity_separates_a_single_byte() raises:
    """The sharpest form of the discriminating half, and the tripwire named in
    this file's collision section: ONE differing value in one row of one column,
    everything else identical. A fold that sampled buffers rather than reading
    them whole would pass every other test here and fail this one."""
    var a = _identity(String("c0"), 64, 0)
    # `seed + i` over 64 rows vs `seed + i` shifted by one at the LAST row only.
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c0"), ArrowType.INT64, nullable=False))
    var vals = List[Int64]()
    for i in range(64):
        vals.append(Int64(i))
    vals[63] = Int64(1_000_000)
    var b = inmem_scan_binding(
        InMemorySource.from_record_batch(
            RecordBatch.from_columns_1(
                sb.build(), PrimitiveArray[DType.int64].from_list(vals)
            )
        )
    ).structural_id
    assert_not_equal(a, b)


def test_the_identity_is_stable_across_copy_and_move() raises:
    """A plan is cloned by every optimizer pass. An identity that moved under
    `.copy()` would make the key change mid-optimization — the same failure as a
    per-construction counter, one level up."""
    var src = _source(String("c0"), 8, 0)
    var before = inmem_scan_binding(src).structural_id
    var cloned = src.copy()
    assert_equal(inmem_scan_binding(cloned).structural_id, before)
    var moved = src^
    assert_equal(inmem_scan_binding(moved).structural_id, before)


def test_the_identity_is_reproducible_across_two_independent_builds() raises:
    """R9 in miniature, at the KIND rather than at the corpus. The corpus
    builder is invoked TWICE — not copied — and every entry must agree on
    `fingerprint`, `structural_id` and `identity_hash()`.

    A `.copy()` here would agree trivially, which is the residual
    `audit_scan_identity_reproducibility`'s own docstring names."""
    var a = inmem_scan_identity_corpus()
    var b = inmem_scan_identity_corpus()
    assert_equal(a.num_entries(), b.num_entries())
    assert_true(a.num_entries() >= 2)
    for i in range(a.num_entries()):
        assert_equal(a.bindings[i].structural_id, b.bindings[i].structural_id)
        assert_equal(a.bindings[i].fingerprint, b.bindings[i].fingerprint)
        assert_equal(
            a.bindings[i].identity_hash(), b.bindings[i].identity_hash()
        )


def test_the_content_identity_is_the_same_value_a_previous_process_measured() raises:
    """THE CROSS-PROCESS CLAIM, made checkable. `INMEM_SID_C0_8ROWS_SEED0` was
    measured in one process and is compared here in another — a different
    binary, on a different machine, on every run. A counter, a heap
    address, or anything else that varies per process cannot pass this, and no
    other test in this file could tell the difference."""
    assert_equal(_identity(String("c0"), 8, 0), INMEM_SID_C0_8ROWS_SEED0)


# =============================================================================
# 2. WHAT THE KIND SUPPLIES, AND WHAT IT DELIBERATELY DOES NOT.
# =============================================================================


def test_the_binding_identity_is_not_the_process_counter() raises:
    """The direction of the fix, asserted rather than assumed. If these ever
    become equal, the counter is back in the IR and every claim in this file's
    header is void."""
    var src = _source(String("c0"), 8, 0)
    assert_not_equal(inmem_scan_binding(src).structural_id, src.fingerprint())
    assert_not_equal(inmem_scan_binding(src).fingerprint, src.fingerprint())


def test_in_memory_source_fingerprint_is_left_alone() raises:
    """⚠ THE TRAP. The obvious "fix" is to make
    `InMemorySource.fingerprint()` content-derived. It would turn THREE
    tests red — `test_in_memory_source_fingerprint_distinct_same_payload`
    / `..._allocator_reuse_distinct` / `..._distinct_bulk_10k` — because a
    content hash makes two sources over identical bytes fingerprint EQUAL, and
    those guard the allocator-reuse hazard.

    The counter is not wrong; it was being asked to be something it is not. It
    stays the ALLOCATOR-REUSE identity — which its own docstring already says is
    NOT what enters the plan structural hash — and the CONTENT identity is
    supplied beside it."""
    var a = _source(String("c0"), 8, 0)
    var b = _source(String("c0"), 8, 0)
    assert_not_equal(a.fingerprint(), b.fingerprint())
    assert_equal(
        inmem_scan_binding(a).structural_id, inmem_scan_binding(b).structural_id
    )


def test_the_declared_inmem_legacy_type_equals_the_plan_layer_constant() raises:
    """`LEGACY_SOURCE_TYPE_IN_MEMORY` is `plan/logical_plan.mojo`'s
    `SOURCE_IN_MEMORY` spelled as a number, because `logical_plan.mojo` imports
    `source_variant.mojo` and importing it back would be a cycle. A test can
    import both, which is the same arrangement ORC / AVRO / CSV already have."""
    assert_equal(LEGACY_SOURCE_TYPE_IN_MEMORY, SOURCE_IN_MEMORY)
    assert_equal(
        inmem_scan_binding(_source(String("c0"), 8, 0)).legacy_source_type,
        SOURCE_IN_MEMORY,
    )


def test_the_kind_declares_what_the_descriptor_declares() raises:
    """R3 in miniature. `ScanKindRegistry.validate` RAISES when a builder and a
    descriptor disagree, which is how instance 4 (arrow's `SNAPSHOT_NONE` beside
    a mtime-folding fingerprint) is caught a second way."""
    var reg = ScanKindRegistry()
    reg.register(inmem_scan_descriptor())
    reg.validate(inmem_scan_binding(_source(String("c0"), 8, 0)))
    assert_equal(
        scan_kind_id(String(SCAN_KIND_NAME_IN_MEMORY)), INMEM_KIND_ID
    )


# =============================================================================
# 3. THE MEASUREMENT THAT DECIDED `fingerprint` != `structural_id`.
# =============================================================================


def _content_fp_binding(num_rows: Int, seed: Int) raises -> ScanBinding:
    """A binding with the CONTENT HASH supplied as
    BOTH `fingerprint` and `structural_id`. Everything else is exactly what
    `inmem_scan_binding` produces."""
    var ims = _source(String("c0"), num_rows, seed)
    var sid = ims.structural_id()
    var params = ScanParams()
    return ScanBinding(
        kind_id=scan_kind_id(String(SCAN_KIND_NAME_IN_MEMORY)),
        kind_name=String(SCAN_KIND_NAME_IN_MEMORY),
        name=String("__in_memory__"),
        params=params^,
        schema=ims.schema(),
        fingerprint=sid,
        structural_id=sid,
        gate=PushdownGate.accept_all(),
        snapshot_policy=SNAPSHOT_NONE,
        orientation=SCAN_ORIENTATION_COLUMNAR,
        legacy_source_type=LEGACY_SOURCE_TYPE_IN_MEMORY,
    )


def test_supplying_the_content_hash_as_the_binding_fingerprint_fires_r2() raises:
    """★ THE MEASUREMENT, RUN AS A TEST RATHER THAN WRITTEN AS PROSE.

    `fingerprint = structural_id = InMemorySource.structural_id()` looks
    natural. It cannot be, and this is why, measured instead of argued:

      R2 demands `fingerprint(a) != fingerprint(b) => identity_hash(a) !=
      identity_hash(b)`. `identity_hash()` folds kind_id, kind_name, name,
      params, schema, gate, orientation (+ the token iff PINNED). NOT ONE of
      those can see a byte. So two 8-row batches with one name and one schema
      and DIFFERENT VALUES have different fingerprints and an IDENTICAL derived
      identity, and R2 fires.

    AND R2's OWN FIX LINE IS THE ONE THAT MUST NOT BE TAKEN HERE. It says
    "carry the differing input in `params`, or declare it as the
    `snapshot_token` under SNAPSHOT_PINNED" — both make `identity_hash()`
    content-sensitive. `identity_hash()` reaches `bid=`, and `plan_display`
    deliberately does NOT placeholder `bid=`, so the agg-CSE CHEAP key would
    stop being content-blind (the planner's cheap-key content-invariance test
    goes red across every walked node kind).

    So the content identity travels as `structural_id` -> `bsid=`, which IS
    placeholdered out of the cheap key and IS in the exact key, and which audit
    rule R5 (SUPPLIED REACH + ATTRIBUTION) was written for — its header names
    IN_MEMORY as the case it exists to cover.

    This test pins the raise so the reasoning above cannot rot into a comment
    that no longer matches the rules."""
    var reg = ScanKindRegistry()
    reg.register(inmem_scan_descriptor())
    var c = ScanIdentityCorpus(inmem_scan_descriptor())
    c.add(String("baseline"), _content_fp_binding(8, 0))
    c.add(String("bytes"), _content_fp_binding(8, 999))
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(c^)
    with assert_raises(contains="AUDIT R2 (COVERAGE) FAILED"):
        audit_scan_identity_coverage(
            reg, corpora.copy(), render_corpora_plan_text(corpora.copy())
        )


def test_the_shipped_kind_passes_the_same_corpus_shape() raises:
    """The control for the test above. Without it, "R2 fires" is equally
    explained by the corpus being malformed, the kind being unregistered, or the
    render being broken — the SAME two entries, built by the SHIPPED builder,
    must pass."""
    var reg = ScanKindRegistry()
    reg.register(inmem_scan_descriptor())
    var c = ScanIdentityCorpus(inmem_scan_descriptor())
    c.add(
        String("baseline"), inmem_scan_binding(_source(String("c0"), 8, 0))
    )
    c.add(String("bytes"), inmem_scan_binding(_source(String("c0"), 8, 999)))
    c.add(String("schema"), inmem_scan_binding(_source(String("c1"), 8, 0)))
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(c^)
    audit_scan_identity_coverage(
        reg, corpora.copy(), render_corpora_plan_text(corpora.copy())
    )


def test_a_bytes_only_pair_is_audited_by_r5_since_r2_cannot_see_it() raises:
    """The other half of the same finding, asserted positively: the entries R2
    skips are NOT unaudited. For a bytes-only pair `fingerprint` is EQUAL (both
    are the schema identity) so R2's premise never holds — and R5b demands the
    difference be located AT the `structural_id`, which is the only field that
    can carry it.

    Pinned here so a future reader does not "fix" the equal fingerprints."""
    var a = inmem_scan_binding(_source(String("c0"), 8, 0))
    var b = inmem_scan_binding(_source(String("c0"), 8, 999))
    assert_equal(a.fingerprint, b.fingerprint)
    assert_equal(a.identity_hash(), b.identity_hash())
    assert_not_equal(a.structural_id, b.structural_id)
    # And R5's premise: the value reaches the text, and it is the witness.
    var corpora = List[ScanIdentityCorpus]()
    var c = ScanIdentityCorpus(inmem_scan_descriptor())
    c.add(String("baseline"), a.copy())
    c.add(String("bytes"), b.copy())
    corpora.append(c^)
    var texts = render_corpora_plan_text(corpora.copy())
    assert_true(String(a.structural_id) in texts[0][0])
    assert_true(String(b.structural_id) in texts[0][1])
    assert_true(not (String(b.structural_id) in texts[0][0]))


# =============================================================================
# 4. THE RENDER — one carrier, not two.
# =============================================================================


def test_a_binding_backed_inmem_scan_emits_its_content_identity_once() raises:
    """⚠ AN INVARIANT THAT MUST BE ENFORCED, NOT ASSUMED.
    `INMEM_ID_PLACEHOLDER`'s docstring says the two carriers "are never emitted
    for the same scan (the `inmem_id=` branch is guarded on `source_type ==
    SOURCE_IN_MEMORY`, the `bsid=` branch on `is_binding_backed()`)".

    Without a guard, that holds only while no binding declares
    `legacy_source_type = SOURCE_IN_MEMORY` (arrow/orc/avro/csv/json declare
    7/5/6/1/4): a property of the kinds, not of the guards. A binding-backed
    in-memory arm MUST declare 3 (its `source_type` readers depend on it), and
    unguarded it renders the same number twice.

    `plan_display` guards the legacy branch with `and not
    is_binding_backed()`. Reverting that clause turns this test red."""
    var b = inmem_scan_binding(_source(String("c0"), 8, 0))
    var sid = b.structural_id
    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant.from_binding(b^), Schema()
        )
    )
    assert_true(String(", bsid=") + String(sid) in rendered)
    assert_true(
        not (String("inmem_id=") in rendered),
        "a binding-backed in-memory scan emitted the LEGACY `inmem_id=` carrier"
        " as well as `bsid=` — the same content identity twice: " + rendered,
    )


def test_golden_identity_hash_inmem() raises:
    """THREE literals, not one: the derived identity must move when
    the SCHEMA moves and when the NAME moves, and a single golden cannot tell a
    correct value from a value that stopped depending on its inputs.

    All three come from the independent reference transcription, which
    self-validates against the already-pinned empty-schema literal before
    producing them — never lifted from this program's output."""
    var anon_c0 = inmem_scan_binding(_source(String("c0"), 8, 0))
    assert_equal(anon_c0.identity_hash(), INMEM_BID_ANON_C0)
    assert_equal(anon_c0.fingerprint, INMEM_SCHEMA_ID_C0)

    var anon_c1 = inmem_scan_binding(_source(String("c1"), 8, 0))
    assert_equal(anon_c1.identity_hash(), INMEM_BID_ANON_C1)
    assert_equal(anon_c1.fingerprint, INMEM_SCHEMA_ID_C1)

    var named = inmem_scan_binding(
        InMemorySource.from_record_batch(
            _batch(String("c0"), 8, 0), Optional(String("t"))
        )
    )
    assert_equal(named.identity_hash(), INMEM_BID_NAMED_T_C0)

    assert_not_equal(INMEM_BID_ANON_C0, INMEM_BID_ANON_C1)
    assert_not_equal(INMEM_BID_ANON_C0, INMEM_BID_NAMED_T_C0)


def test_golden_rendered_plan_text_inmem() raises:
    """THE PLAN TEXT, pinned whole — `LogicalPlan.structural_hash()`
    is FNV-1a over exactly this string and `EngineContext` uses it as
    `factory_hash`, so this line IS the plan-compile cache key.

    ASSEMBLED from the independently-derived `bid` literal, the measured `bsid`
    literal and `plan_display.mojo`'s declared field order — so a changed VALUE
    and a changed FORMAT are separately red. `path=__in_memory__` and
    `type=IN_MEMORY` are the values the legacy in-memory arm renders
    (`ScanData.__init__`'s in-memory branch), so both arms agree on them."""
    var expected = String('Scan(path="__in_memory__", type=IN_MEMORY')
    expected += String(", binding=") + String(SCAN_KIND_NAME_IN_MEMORY)
    expected += String("(__in_memory__)")
    expected += String(", bsid=") + String(INMEM_SID_C0_8ROWS_SEED0)
    expected += String(", bid=") + String(INMEM_BID_ANON_C0)
    expected += String(", source_kind=COLUMNAR)")

    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant.from_binding(
                inmem_scan_binding(_source(String("c0"), 8, 0))
            ),
            Schema(),
        )
    )
    assert_equal(rendered.strip(), expected)


# =============================================================================
# 5. THE CORPUS ITSELF.
# =============================================================================


def test_the_inmem_corpus_varies_every_input_the_content_fold_folds() raises:
    """`InMemorySource._structural_id_compute` folds FOUR inputs — batch count,
    schema text, row count and column bytes — and the binding adds `name`. The
    corpus must vary every one, or the audit passes over a hole it cannot see.

    Written as an assertion, not a comment: a corpus entry deleted to make a
    change pass is how a gate rots, and this file's own R2 measurement is the
    kind of pressure that produces exactly that deletion."""
    var c = inmem_scan_identity_corpus()
    var want: List[String] = [
        String("baseline"),
        String("schema"),
        String("name"),
        String("bytes"),
        String("rows"),
        String("nbatches"),
    ]
    for w in range(len(want)):
        var saw = False
        for i in range(c.num_entries()):
            if c.labels[i] == want[w]:
                saw = True
        assert_true(
            saw, "the in-memory corpus stopped varying `" + want[w] + "`"
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_two_sources_over_identical_content_share_one_identity]()
    suite.test[test_two_sources_over_different_content_get_different_identities]()
    suite.test[test_the_content_identity_separates_a_single_byte]()
    suite.test[test_the_identity_is_stable_across_copy_and_move]()
    suite.test[test_the_identity_is_reproducible_across_two_independent_builds]()
    suite.test[
        test_the_content_identity_is_the_same_value_a_previous_process_measured
    ]()
    suite.test[test_the_binding_identity_is_not_the_process_counter]()
    suite.test[test_in_memory_source_fingerprint_is_left_alone]()
    suite.test[test_the_declared_inmem_legacy_type_equals_the_plan_layer_constant]()
    suite.test[test_the_kind_declares_what_the_descriptor_declares]()
    suite.test[test_supplying_the_content_hash_as_the_binding_fingerprint_fires_r2]()
    suite.test[test_the_shipped_kind_passes_the_same_corpus_shape]()
    suite.test[test_a_bytes_only_pair_is_audited_by_r5_since_r2_cannot_see_it]()
    suite.test[test_a_binding_backed_inmem_scan_emits_its_content_identity_once]()
    suite.test[test_golden_identity_hash_inmem]()
    suite.test[test_golden_rendered_plan_text_inmem]()
    suite.test[test_the_inmem_corpus_varies_every_input_the_content_fold_folds]()
    suite^.run()
