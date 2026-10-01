# =============================================================================
# THE IDENTITY-COVERAGE GATE — one mechanical rule for a four-instance class.
# =============================================================================
#
# The scan-identity audit lives in komira_core (`source/scan_identity_audit`);
# this file runs it over every registered scan kind, including the broker
# kind this package contributes.
#
# ---------------------------------------------------------------------------
# WHY A GATE AND NOT A PER-INSTANCE FIX
# ---------------------------------------------------------------------------
#
# One defect class has several instances, each easy to miss by reading a diff:
#
#   1. Out-of-core binding params never reaching the plan TEXT.
#   2. `broker_scan_binding`'s SUPPLIED `structural_id` folding only
#      (topic, partition) and omitting `start_offset`.
#   3. ORC projection ORDER and `_mtime_ns`.
#   4. An arrow binding declaring `SNAPSHOT_NONE` while
#      `ArrowSource.fingerprint()` folds `_mtime_ns`.
#
# So the rule is written down ONCE and checked BY MACHINE, for every kind:
#
#     fingerprint(a) != fingerprint(b)  =>  identity_hash(a) != identity_hash(b)
#
# Instance 4, for example, fails the audit with its own message:
#
#   ScanIdentity AUDIT R2 (COVERAGE) FAILED for kind 'komira.arrow.ipc':
#     entries 'baseline' and 'mtime' have DIFFERENT fingerprints
#     (16677305617667912387 vs 3972932743152711107) but the SAME derived
#     identity_hash (13181734882649314514).
#
# ---------------------------------------------------------------------------
# WHAT ELSE THIS FILE PINS
# ---------------------------------------------------------------------------
#
# The rendered plan text and the derived identity are the most likely way a
# scan-binding change goes wrong quietly. `test_scan_binding_arrow_arm.mojo`
# pins `fingerprint` and `structural_id` — the values a change must keep
# CONSTANT. This file pins the two values a change must keep CORRECT:
#
#   * `identity_hash()` is pinned against an INDEPENDENT reference
#     computation (`param_hash_*` + `schema_identity_hash` +
#     `PushdownGate.hash_into` transcribed from their definitions), not lifted
#     from our own output. The reference reproduces three existing goldens —
#     `scan_kind_id("komira.arrow.ipc") == 2587754919`,
#     `broker_scan_kind_id() == 2705777722`, and both `GOLDEN_FP_MTIME_*`
#     values in `test_scan_binding_arrow_arm.mojo`.
#   * The rendered SCAN LINE is pinned as a whole, ASSEMBLED from those
#     independently-derived literals plus the declared field order — so a
#     changed VALUE and a changed FORMAT are both red, and neither pin is
#     circular.
#
# ---------------------------------------------------------------------------
# REACH: VALUES MUST GET TO THE PLAN TEXT (sections 6 and 7)
# ---------------------------------------------------------------------------
#
# Comparing VALUES is not enough. If the render stopped writing
# `, bid=<identity_hash>`, the value-level gate would stay GREEN: the derived
# identity would stop reaching the plan text, and only the two FORMAT goldens
# of section 3 would notice — goldens that go red on any innocuous render
# change, so the fix of least resistance is to update the literal. Section 6
# is a CLASS rule (audit R4) off the same registry-driven corpora rather than
# a third golden, plus one production-path test whose only possible carrier
# is `bid=`.
#
# The render writes TWO identities, `bsid=` (kind-supplied) and `bid=`
# (core-derived); R4 protects only the second. Section 7 is audit rule R5 for
# the first, and its pair clause is sharper than R4b's: see its section
# header.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_not_equal,
    assert_raises,
)

from komira_core.arrow import (
    ArrowType,
    Field,
    PrimitiveArray,
    RecordBatch,
    Schema,
    SchemaBuilder,
)
from komira_core.source.in_memory_source import InMemorySource
from komira_core.plan.logical_plan import LogicalPlan
from komira_core.source.arrow_source import ArrowSource
from komira_core.source.pushdown_gate import PushdownGate
from komira_core.source.scan_binding import (
    ScanBinding,
    SNAPSHOT_NONE,
    SNAPSHOT_PINNED,
    SCAN_KIND_NAME_ARROW_IPC,
    SCAN_KIND_NAME_AVRO,
    SCAN_KIND_NAME_CSV,
    SCAN_KIND_NAME_IN_MEMORY,
    SCAN_KIND_NAME_ORC,
    SCAN_ORIENTATION_COLUMNAR,
    SCAN_ORIENTATION_ROW,
    scan_kind_id,
)
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr
from komira_core.plan.scan_identity_render_audit import (
    NODE_WITNESS_ALPHA,
    _cheap_witness_binding,
    audit_scan_identity_cheap_key,
    NODE_WITNESS_BETA,
    ScanNodeCorpus,
    audit_scan_identity,
    audit_scan_node_identity,
    build_scan_node_corpus,
    render_corpora_plan_text,
    render_scan_node_plan_text,
    render_scan_plan_text,
)
from komira_core.source.scan_identity_audit import (
    ScanIdentityCorpus,
    audit_scan_identity_coverage,
)
from komira_core.source.scan_kind_registry import (
    ScanKindDescriptor,
    ScanKindRegistry,
)
from komira_core.source.scan_params import ScanParams
from komira_core.source.source_variant import (
    ARROW_CODEC_UNCOMPRESSED,
    ARROW_CODEC_ZSTD,
    SourceVariant,
    arrow_scan_descriptor,
    arrow_scan_identity_corpus,
    avro_scan_descriptor,
    avro_scan_identity_corpus,
    core_scan_identity_corpora,
    csv_scan_descriptor,
    csv_scan_identity_corpus,
    inmem_scan_descriptor,
    inmem_scan_identity_corpus,
    json_scan_descriptor,
    json_scan_identity_corpus,
    orc_scan_descriptor,
    orc_scan_identity_corpus,
)

from komira_broker.broker_scan_binding import (
    broker_scan_binding,
    broker_scan_descriptor,
    broker_scan_identity_corpus,
)


# =============================================================================
# The universe under audit — assembled the way PRODUCTION would assemble it.
# =============================================================================
#
# Core's own kinds come from `core_scan_identity_corpora()`, which is DERIVED
# from `_tag_is_binding_backed` and RAISES on a migrated arm with no corpus.
# Out-of-core kinds are contributed by their own packages — a broker corpus
# reaching core's audit is the same shape as a broker binding reaching core's
# plan.


def _corpora() raises -> List[ScanIdentityCorpus]:
    var out = core_scan_identity_corpora()
    out.append(broker_scan_identity_corpus(Schema()))
    return out^


def _registry() raises -> ScanKindRegistry:
    var reg = ScanKindRegistry()
    reg.register(arrow_scan_descriptor())
    # Registered WITH its binding: an unregistered kind is invisible to R0,
    # so its identity holes would go unchecked.
    reg.register(orc_scan_descriptor())
    # The first descriptor that declares ROW — without it every registered
    # kind would say COLUMNAR, and `ScanKindRegistry.validate`'s orientation
    # comparison would never see two different values.
    reg.register(avro_scan_descriptor())
    # The SECOND descriptor that declares ROW, which keeps `validate`'s
    # orientation comparison multi-valued instead of it reverting to a check
    # that cannot fail the moment one kind changes.
    reg.register(csv_scan_descriptor())
    # The THIRD descriptor that declares ROW, and a kind whose carrier is
    # constructed at both orientations by its callers. Registered WITH its
    # binding, like every other kind.
    reg.register(json_scan_descriptor())
    # IN_MEMORY. Its corpus comes through `core_scan_identity_corpora()` like
    # the others; the difference is that IN_MEMORY is not binding-backed, so
    # that function appends it explicitly rather than reaching it through the
    # tag walk.
    #
    # ⚠ IT IS THE KIND WHOSE `fingerprint` AND `structural_id` ARE DIFFERENT
    # VALUES, so it is the corpus in this gate for which R2 and R5 audit
    # DIFFERENT ENTRIES: R2 covers `schema` (an input core can see), R5 covers
    # `bytes` / `rows` / `nbatches` (inputs only the kind can see).
    # `test_inmem_content_identity.mojo
    # :test_supplying_the_content_hash_as_the_binding_fingerprint_fires_r2`
    # shows why the split is needed.
    reg.register(inmem_scan_descriptor())
    reg.register(broker_scan_descriptor())
    return reg^


# =============================================================================
# 1. THE GATE.
# =============================================================================


def test_every_registered_scan_kind_covers_its_own_fingerprint() raises:
    """The identity-coverage rule, over every registered kind.

    THE RULE: for two bindings of one kind, if the KIND's own `fingerprint()`
    separates them then CORE's derived `identity_hash()` must separate them
    too. When core is coarser than the kind, the gap IS the silent collision:
    the plan text does not distinguish the two scans, `structural_hash()` does
    not, the engine's `factory_hash` does not, and one query's compiled plan
    is handed to another.

    The audit runs all pairs of every corpus of every REGISTERED kind, so this
    single call covers a kind that did not exist when this test was written.
    """
    audit_scan_identity(_registry(), _corpora(), _corpora())


def test_the_audit_is_driven_by_the_registry_not_by_a_list_here() raises:
    """A hand-listed set of kinds is the same defect one level up: it goes
    stale silently, and the kind that was forgotten is the kind that is
    unchecked. So R0 makes a REGISTERED-but-unaudited kind RED.

    Registering a kind nobody supplied a corpus for must FAIL — that is the
    mechanism by which a new kind is automatically covered.
    """
    var reg = _registry()
    reg.register(
        ScanKindDescriptor(
            kind_name=String("example.newcomer.kind"),
            gate=PushdownGate.reject_all(),
        )
    )
    with assert_raises(contains="REGISTERED but supplies NO identity corpus"):
        audit_scan_identity(reg, _corpora(), _corpora())


def test_a_corpus_that_asserts_nothing_is_red_not_green() raises:
    """The cheapest way to satisfy an all-pairs audit is a corpus of one, which
    has no pairs. R1 rejects it, and rejects a corpus whose entries all share a
    fingerprint — where the R2 implication's PREMISE never holds, so the rule
    is never exercised and the kind reports green having proven nothing.

    (A lexical scan whose precondition never held is the same failure mode: it
    reports green while checking nothing.)
    """
    var reg = ScanKindRegistry()
    reg.register(arrow_scan_descriptor())

    # (a) one entry -> no pairs at all.
    var one = ScanIdentityCorpus(arrow_scan_descriptor())
    one.add(String("only"), _arrow_binding_for(String("/t/a.arrow"), UInt64(0)))
    var only = List[ScanIdentityCorpus]()
    only.append(one^)
    with assert_raises(contains="AUDIT R1 (NON-VACUITY)"):
        audit_scan_identity(reg, only.copy(), only.copy())

    # (b) two entries, ONE fingerprint -> the implication is never exercised.
    var dup = ScanIdentityCorpus(arrow_scan_descriptor())
    dup.add(String("a"), _arrow_binding_for(String("/t/a.arrow"), UInt64(0)))
    dup.add(String("a-again"), _arrow_binding_for(String("/t/a.arrow"), UInt64(0)))
    var dups = List[ScanIdentityCorpus]()
    dups.append(dup^)
    with assert_raises(contains="DISTINCT fingerprint"):
        audit_scan_identity(reg, dups.copy(), dups.copy())


def test_the_audit_catches_a_planted_coverage_hole() raises:
    """THE AUDIT'S OWN FALSIFIER. A gate that cannot be made to fail is not a
    gate — every in-tree kind passes, so nothing else in this file would
    notice if the R2 loop stopped checking.

    The planted binding is instance 4 in miniature: a kind whose `fingerprint`
    separates two scans while every core-visible input is identical.
    """
    var reg = ScanKindRegistry()
    reg.register(
        ScanKindDescriptor(
            kind_name=String("example.hole.kind"),
            gate=PushdownGate.reject_all(),
        )
    )
    var c = ScanIdentityCorpus(
        ScanKindDescriptor(
            kind_name=String("example.hole.kind"),
            gate=PushdownGate.reject_all(),
        )
    )
    c.add(String("v1"), _planted(UInt64(0x1111)))
    c.add(String("v2"), _planted(UInt64(0x2222)))
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(c^)
    with assert_raises(contains="AUDIT R2 (COVERAGE) FAILED"):
        audit_scan_identity(reg, corpora.copy(), corpora.copy())


def _planted(fp: UInt64) -> ScanBinding:
    """Two of these differ ONLY in the kind-supplied `fingerprint`; every input
    core can see is identical, so `identity_hash` cannot tell them apart."""
    return ScanBinding(
        kind_id=scan_kind_id(String("example.hole.kind")),
        kind_name=String("example.hole.kind"),
        name=String("t"),
        params=ScanParams(),
        schema=Schema(),
        fingerprint=fp,
        structural_id=fp,
        gate=PushdownGate.reject_all(),
    )


def _schema_abc() -> Schema:
    """A non-empty schema. Used only where the SCHEMA is the varied input —
    `ArrowSource.fingerprint()` does not fold it, which is exactly what makes it
    the witness section 6 needs."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.INT64, nullable=True))
    sb.add_field(Field("c", ArrowType.STRING, nullable=True))
    return sb.build()


def _arrow_binding_for(var path: String, mtime: UInt64) -> ScanBinding:
    """An arrow binding, built through the production path — `SourceVariant`'s
    own constructor — so the corpus cannot drift from what a plan actually
    carries."""
    return SourceVariant.from_arrow_uncompressed(
        ArrowSource(path^, Schema(), mtime_ns=mtime)
    ).binding_ref().copy()


# =============================================================================
# 2. INSTANCE 4, DIRECTLY.
# =============================================================================


def test_two_mtimes_of_one_arrow_file_do_not_share_a_plan_cache_key() raises:
    """The readable form of instance 4.

    `ArrowSource.fingerprint()` folds `_mtime_ns` per its
    stale-cache-invalidation contract: rewriting the file at the same path
    MUST produce a different identity. A binding that declares `SNAPSHOT_NONE`
    and puts the mtime nowhere else leaves core's derived identity blind to
    it — the same file before and after a rewrite would hash identically in
    `identity_hash()`, and a plan compiled against the old bytes could be
    replayed against the new ones.

    THE NUMBERS for that broken shape (independent reference, corpus fixture):
        fingerprint  mtime=0           16677305617667912387
        fingerprint  mtime=1700000000   3972932743152711107   <- kind: DIFFERENT
        identity_hash both             13181734882649314514   <- core:  SAME
    """
    var old = _arrow_binding_for(String("/t/a.arrow"), UInt64(0))
    var new = _arrow_binding_for(String("/t/a.arrow"), UInt64(1700000000))

    # The premise: the KIND's own fold separates them.
    assert_not_equal(old.fingerprint, new.fingerprint)
    # The claim: so does core's.
    assert_not_equal(
        old.identity_hash(),
        new.identity_hash(),
        "two arrow scans of one path at different mtimes share a derived"
        " identity; rendered as: " + old.render(),
    )


def test_arrow_declares_the_mtime_as_a_pinned_snapshot_token() raises:
    """THE FIX, NAMED. The mtime IS the arrow kind's identity, so the policy is
    `SNAPSHOT_PINNED` — "the token IS identity", the same conclusion as ORC.

    The rejected alternative was taking the mtime OUT of
    `ArrowSource.fingerprint()`. That fails twice: it would CHANGE the arrow
    fingerprint VALUE (`test_scan_binding_arrow_arm.mojo` pins both literals,
    and every plan-cache key would move), and it would delete the
    stale-cache-invalidation contract outright — a rewritten file at the same
    path would silently reuse the old plan AND the old cached metadata.
    Pinning is the fix; unpinning is the bug with a different spelling.
    """
    ref b = SourceVariant.from_arrow_zstd(
        ArrowSource(String("/t/a.arrow"), Schema(), mtime_ns=UInt64(1700000000))
    ).binding_ref()
    assert_equal(b.snapshot_policy, SNAPSHOT_PINNED)
    assert_equal(b.snapshot_token, UInt64(1700000000))
    # And the descriptor agrees, so `ScanKindRegistry.validate` accepts it.
    assert_equal(arrow_scan_descriptor().snapshot_policy, SNAPSHOT_PINNED)


def test_the_arrow_fingerprint_value_did_not_move_with_the_fix() raises:
    """The fingerprint stays byte-identical. The fix changes what
    core DERIVES; it must not change what the kind SUPPLIES. If these move,
    every plan-cache key in the tree moves with them and every cached plan
    silently recompiles — the failure mode with nothing red.

    The literals are the ones `test_scan_binding_arrow_arm.mojo` already pins
    against an independent reference; repeated here because THIS file is the
    one that changed the binding.
    """
    assert_equal(
        _arrow_binding_for(String("/tmp/golden_arrow_fp.arrow"), UInt64(0)).fingerprint,
        UInt64(15012656508847213963),
    )
    assert_equal(
        _arrow_binding_for(
            String("/tmp/golden_arrow_fp.arrow"), UInt64(1234567890)
        ).fingerprint,
        UInt64(7086693336528161761),
    )


# =============================================================================
# 3. GOLDENS FOR THE TWO VALUES NOBODY PINNED — `bid=` AND THE PLAN TEXT.
# =============================================================================
#
# These are the most likely values to drift quietly.
# Every existing golden pins `fingerprint` / `structural_id` — the values a
# migration must keep CONSTANT. These pin the values a migration must get
# RIGHT, and they are what makes a future silent drift loud.

comptime GOLDEN_PATH: String = "/tmp/golden_arrow_fp.arrow"

comptime ARROW_BID_ZSTD_MTIME_1234567890: UInt64 = 1811394600828435969
"""`identity_hash()` of the arrow binding for (GOLDEN_PATH, mtime=1234567890,
codec=zstd, estimated_rows=-1, empty schema), from the independent reference.
It includes the snapshot token, which is what makes a rewritten file a
different scan."""

comptime BROKER_BID_ORDERS_P3_OFF1000: UInt64 = 5576424882752574727
"""`identity_hash()` of `broker_scan_binding("orders", 3, 1000, Schema())`.
`SNAPSHOT_LIVE`, so the token is NOT folded — that exclusion is the
identity/freshness split, and this literal is what pins it."""


def _golden_arrow_binding() -> ScanBinding:
    return SourceVariant.from_arrow_zstd(
        ArrowSource(String(GOLDEN_PATH), Schema(), mtime_ns=UInt64(1234567890))
    ).binding_ref().copy()


def test_golden_identity_hash_arrow() raises:
    """A golden on `identity_hash()`. Derived independently, not lifted from
    our own output — see this file's header for how the reference was
    validated against three existing goldens."""
    assert_equal(
        _golden_arrow_binding().identity_hash(), ARROW_BID_ZSTD_MTIME_1234567890
    )


def test_golden_identity_hash_broker() raises:
    assert_equal(
        broker_scan_binding(
            String("orders"), Int64(3), Int64(1000), Schema()
        ).identity_hash(),
        BROKER_BID_ORDERS_P3_OFF1000,
    )


def test_golden_rendered_plan_text_arrow() raises:
    """THE RENDERED PLAN TEXT, pinned whole. `LogicalPlan.structural_hash()` is
    FNV-1a over exactly this string and `EngineContext` uses it as
    `factory_hash` — so this line IS the plan-compile cache key, and an
    unreviewed change to it silently repartitions every cache.

    ASSEMBLED, NOT TRANSCRIBED. The expected string is built here from the
    independently-derived literals plus the field order the plan renderer
    declares, so a changed VALUE and a changed FORMAT are both red and neither
    pin is circular.
    """
    var expected = String('Scan(path="') + String(GOLDEN_PATH) + String('"')
    expected += String(", type=ARROW")
    expected += String(", binding=") + String(SCAN_KIND_NAME_ARROW_IPC)
    expected += String("(") + String(GOLDEN_PATH)
    expected += String(", codec=") + String(ARROW_CODEC_ZSTD)
    expected += String(", estimated_rows=-1")
    expected += String(", path=") + String(GOLDEN_PATH) + String(")")
    # `bsid` is the KIND-supplied identity (== fingerprint for a file source);
    # `bid` is CORE's derived one. Both are emitted because neither subsumes
    # the other — see `plan_display.mojo` "WHY THREE VALUES AND NOT ONE".
    expected += String(", bsid=7086693336528161761")
    expected += String(", bid=") + String(ARROW_BID_ZSTD_MTIME_1234567890)
    expected += String(", source_kind=COLUMNAR)")

    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant.from_arrow_zstd(
                ArrowSource(
                    String(GOLDEN_PATH), Schema(), mtime_ns=UInt64(1234567890)
                )
            ),
            Schema(),
        )
    )
    assert_equal(rendered.strip(), expected)


def test_golden_rendered_plan_text_broker() raises:
    """The same pin for a kind `komira_core` has never heard of. `type=BINDING`
    means "consult `kind_id`"; the reverse-DNS name and the sorted param map are
    what make EXPLAIN readable for it."""
    var expected = String('Scan(path="orders", type=BINDING')
    expected += String(", binding=komira.broker.topic(orders")
    expected += String(", partition=3, start_offset=1000, topic=orders)")
    expected += String(", bsid=17762514713362705584")
    expected += String(", bid=") + String(BROKER_BID_ORDERS_P3_OFF1000)
    expected += String(", source_kind=COLUMNAR)")

    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant.from_binding(
                broker_scan_binding(
                    String("orders"), Int64(3), Int64(1000), Schema()
                )
            ),
            Schema(),
        )
    )
    assert_equal(rendered.strip(), expected)


# =============================================================================
# 4. THE END-TO-END CLAIM — a distinguishable pair must reach the PLAN HASH.
# =============================================================================


def test_every_distinguishable_pair_reaches_the_plan_compile_cache_key() raises:
    """The audit's rule R2 is about the BINDING. This is the claim that matters
    at the call site: if EITHER fold separates two bindings of one kind, the
    plans rooted at them must not share a `structural_hash` — because that hash
    is `factory_hash`, and a shared key means one query gets the other's
    compiled plan.

    It is checked over the SAME corpora the audit uses, so a kind that supplies
    a corpus gets both checks for free, and this is the check that would have
    caught instance 1 (params not rendered) and instance 2 (the supplied
    `structural_id` omitting `start_offset`) — neither of which R2 constrains,
    because in both cases the kind's OWN fold did not separate the pair either.
    """
    var corpora = _corpora()
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        for i in range(c.num_entries()):
            for j in range(i + 1, c.num_entries()):
                var same_fp = c.bindings[i].fingerprint == c.bindings[j].fingerprint
                var same_id = (
                    c.bindings[i].identity_hash() == c.bindings[j].identity_hash()
                )
                if same_fp and same_id:
                    continue
                var pi = LogicalPlan.scan_from_source(
                    SourceVariant.from_binding(c.bindings[i].copy()), Schema()
                )
                var pj = LogicalPlan.scan_from_source(
                    SourceVariant.from_binding(c.bindings[j].copy()), Schema()
                )
                assert_not_equal(
                    pi.structural_hash(),
                    pj.structural_hash(),
                    String("kind '")
                    + c.descriptor.kind_name
                    + String("': entries '")
                    + c.labels[i]
                    + String("' and '")
                    + c.labels[j]
                    + String("' are distinguishable but share a plan-compile")
                    + String(" cache key; rendered as: ")
                    + String(pi),
                )


def test_the_live_snapshot_contract_survives_the_render() raises:
    """The other half of the identity/freshness split, which the fix must not break. A
    `SNAPSHOT_LIVE` token is resolved per execution and written to a
    PER-EXECUTION copy; that copy must render BYTE-IDENTICALLY to the cached
    plan, or the identity/freshness split is defeated at the last step and
    every execution recompiles.

    `SNAPSHOT_PINNED` is the opposite by construction, and this asserts both in
    one place so the arrow fix cannot be read as "fold the token always".
    """
    var live = broker_scan_binding(String("orders"), Int64(3), Int64(1000), Schema())
    var live_resolved = live.with_snapshot_token(UInt64(999999))
    assert_equal(live.identity_hash(), live_resolved.identity_hash())
    assert_equal(live.render(), live_resolved.render())

    var pinned = _arrow_binding_for(String("/t/a.arrow"), UInt64(0))
    assert_not_equal(
        pinned.identity_hash(), pinned.with_snapshot_token(UInt64(7)).identity_hash()
    )


# =============================================================================
# 5. THE RESIDUAL HOLE THIS CLOSES — a migrated arm nobody registered.
# =============================================================================


def test_a_migrated_arm_cannot_be_left_unaudited() raises:
    """The audit is registry-driven, which covers any kind that IS registered.
    The hole is a kind that migrates and is never registered.

    `core_scan_identity_corpora()` closes it by walking the legacy tag space and
    asking `_tag_is_binding_backed` itself: a binding-backed tag with no corpus
    arm RAISES, naming the tag. So an arm that becomes binding-backed cannot
    pass without saying what makes two of its scans different — adding
    `SOURCE_VARIANT_ORC` or `SOURCE_VARIANT_AVRO` to `_tag_is_binding_backed`
    makes this function RAISE until the corpus arm exists. See
    `test_the_migrated_orc_kind_is_present_and_non_vacuous` and
    `test_the_migrated_avro_kind_is_present_and_non_vacuous`.
    """
    var corpora = core_scan_identity_corpora()
    # ⚠ DELIBERATELY NOT A COUNT PIN. The `raise` inside
    # `core_scan_identity_corpora()` is what catches a migrated-but-unaudited
    # arm, and it catches it by NAME. A `len(corpora) == N` here would add no
    # coverage on top of that and would go red on a CORRECT migration — a
    # spurious failure reads as a noisy gate, and a noisy gate gets switched
    # off. Assert what must be TRUE (arrow is present and non-vacuous), not
    # what happens to be the count today.
    var saw_arrow = False
    for i in range(len(corpora)):
        if corpora[i].descriptor.kind_name == String(SCAN_KIND_NAME_ARROW_IPC):
            saw_arrow = True
            assert_true(corpora[i].num_entries() >= 2)
    assert_true(saw_arrow, "the core-owned arrow kind lost its identity corpus")


def test_the_arrow_corpus_varies_every_input_the_fingerprint_folds() raises:
    """`ArrowSource.fingerprint()` folds exactly two things — `path` and
    `_mtime_ns` — so the corpus must vary both, or the audit passes over a
    hole it cannot see. Written as an assertion rather than a comment because
    a corpus entry deleted to make a change pass is precisely how a gate rots.
    """
    var c = arrow_scan_identity_corpus()
    var saw_path = False
    var saw_mtime = False
    for i in range(c.num_entries()):
        if c.labels[i] == String("path"):
            saw_path = True
        if c.labels[i] == String("mtime"):
            saw_mtime = True
    assert_true(saw_path, "the arrow corpus stopped varying `path`")
    assert_true(saw_mtime, "the arrow corpus stopped varying `mtime` — that is"
                " the entry that caught instance 4")


def test_the_orc_corpus_varies_every_input_the_fingerprint_folds() raises:
    """`OrcSource.fingerprint()` folds three things — `path`, `_mtime_ns`, and
    the `projection` vector — and the projection fold is
    ORDER-SENSITIVE, which `read_orc_bytes_projected`'s output-column contract
    makes a real distinction. So the projection needs TWO entries: a different
    LENGTH and a different ORDER. A corpus that varied only the length would
    pass while `[0,2]` and `[2,0]` collided.

    Written as an assertion for the same reason the arrow one is: a corpus entry
    deleted to make a change pass is how a gate rots.
    """
    var c = orc_scan_identity_corpus()
    var saw_path = False
    var saw_mtime = False
    var saw_projection = False
    var saw_projection_order = False
    for i in range(c.num_entries()):
        if c.labels[i] == String("path"):
            saw_path = True
        if c.labels[i] == String("mtime"):
            saw_mtime = True
        if c.labels[i] == String("projection"):
            saw_projection = True
        if c.labels[i] == String("projection_order"):
            saw_projection_order = True
    assert_true(saw_path, "the orc corpus stopped varying `path`")
    assert_true(saw_mtime, "the orc corpus stopped varying `mtime`")
    assert_true(saw_projection, "the orc corpus stopped varying `projection`")
    assert_true(
        saw_projection_order,
        "the orc corpus stopped varying projection ORDER — `[0,2]` vs `[2,0]`"
        " are different scans and only that entry checks it",
    )


def test_the_migrated_orc_kind_is_present_and_non_vacuous() raises:
    """The ORC half of `test_a_migrated_arm_cannot_be_left_unaudited`. The
    `raise` inside `core_scan_identity_corpora()` catches an arm that migrates
    with no corpus; this catches the opposite drift — an arm whose corpus was
    emptied or unhooked while the arm stayed binding-backed."""
    var corpora = core_scan_identity_corpora()
    var saw_orc = False
    for i in range(len(corpora)):
        if corpora[i].descriptor.kind_name == String(SCAN_KIND_NAME_ORC):
            saw_orc = True
            assert_true(corpora[i].num_entries() >= 2)
    assert_true(saw_orc, "the core-owned orc kind lost its identity corpus")


def test_the_avro_corpus_varies_every_input_the_fingerprint_folds() raises:
    """`AvroSource.fingerprint()` folds exactly two things — the `path` (its
    length and its bytes) and `_mtime_ns`. Two entries
    cover it; a third would have to vary something the fingerprint cannot see,
    which would be testing core against itself rather than checking coverage.

    Written as an assertion for the same reason the arrow and orc ones are: a
    corpus entry deleted to make a change pass is how a gate rots.
    """
    var c = avro_scan_identity_corpus()
    var saw_path = False
    var saw_mtime = False
    for i in range(c.num_entries()):
        if c.labels[i] == String("path"):
            saw_path = True
        if c.labels[i] == String("mtime"):
            saw_mtime = True
    assert_true(saw_path, "the avro corpus stopped varying `path`")
    assert_true(saw_mtime, "the avro corpus stopped varying `mtime`")


def test_the_migrated_avro_kind_is_present_and_non_vacuous() raises:
    """The AVRO half of `test_a_migrated_arm_cannot_be_left_unaudited` — the
    drift this catches is an arm whose corpus was emptied or unhooked while the
    arm stayed binding-backed."""
    var corpora = core_scan_identity_corpora()
    var saw_avro = False
    for i in range(len(corpora)):
        if corpora[i].descriptor.kind_name == String(SCAN_KIND_NAME_AVRO):
            saw_avro = True
            assert_true(corpora[i].num_entries() >= 2)
    assert_true(saw_avro, "the core-owned avro kind lost its identity corpus")


def test_the_csv_corpus_varies_every_input_the_fingerprint_folds() raises:
    """`CsvSource.fingerprint()` folds exactly THREE things — the `path` (its
    length and its bytes), `_mtime_ns`, and `quote_style_tag`. Three varied
    entries cover it.

    ⚠ THE `quote_style` ENTRY IS THE IMPORTANT ONE. CSV's `quote_style_tag`
    is the sharpest instance of the identity-coverage class: two scans with
    GENUINELY DIFFERENT DECODERS (RFC 4180 vs POSIX quoting) sharing a
    plan-compile cache key. Deleting that entry deletes the check that closes
    it.
    """
    var c = csv_scan_identity_corpus()
    var saw_path = False
    var saw_mtime = False
    var saw_quote = False
    for i in range(c.num_entries()):
        if c.labels[i] == String("path"):
            saw_path = True
        if c.labels[i] == String("mtime"):
            saw_mtime = True
        if c.labels[i] == String("quote_style"):
            saw_quote = True
    assert_true(saw_path, "the csv corpus stopped varying `path`")
    assert_true(saw_mtime, "the csv corpus stopped varying `mtime`")
    assert_true(saw_quote, "the csv corpus stopped varying `quote_style`")


def test_the_migrated_csv_kind_is_present_and_non_vacuous() raises:
    """The CSV half of `test_a_migrated_arm_cannot_be_left_unaudited` — the
    drift this catches is an arm whose corpus was emptied or unhooked while the
    arm stayed binding-backed."""
    var corpora = core_scan_identity_corpora()
    var saw_csv = False
    for i in range(len(corpora)):
        if corpora[i].descriptor.kind_name == String(SCAN_KIND_NAME_CSV):
            saw_csv = True
            assert_true(corpora[i].num_entries() >= 3)
    assert_true(saw_csv, "the core-owned csv kind lost its identity corpus")


def test_the_inmem_kind_is_present_and_non_vacuous() raises:
    """The IN_MEMORY half of `test_a_migrated_arm_cannot_be_left_unaudited`, and it
    guards a DIFFERENT drift from the other four.

    IN_MEMORY is not binding-backed yet, so it does not reach
    `core_scan_identity_corpora()` through the tag walk — that function appends
    it explicitly, guarded on the tag NOT being binding-backed. The drift this
    catches is that guard being left in place after the flip (which would append
    the corpus twice) or removed before it (which would drop this kind out of
    the audit entirely, silently, with every other rule still green)."""
    var corpora = core_scan_identity_corpora()
    var saw = 0
    for i in range(len(corpora)):
        if corpora[i].descriptor.kind_name == String(
            SCAN_KIND_NAME_IN_MEMORY
        ):
            saw += 1
            assert_true(corpora[i].num_entries() >= 4)
    assert_equal(
        saw,
        1,
        "the in-memory kind must appear in `core_scan_identity_corpora()`"
        " EXACTLY once — 0 means it dropped out of the audit, 2 means the"
        " pre-flip explicit append survived the tag flip",
    )


def test_the_inmem_corpus_states_both_halves_of_its_identity() raises:
    """⚠ THE ONE CORPUS IN THIS GATE WHOSE ENTRIES ARE AUDITED BY DIFFERENT
    RULES, which is what makes this kind worth a test of its own.

    `komira.in_memory` is the first kind whose `fingerprint` (the SCHEMA
    identity — what core can see) and `structural_id` (the CONTENT hash — what
    it cannot) are different values. So:

      * the `schema` entry has a DIFFERENT fingerprint from baseline and is
        audited by R2;
      * the `bytes` entry has the SAME fingerprint and a different
        `structural_id`, so R2's premise never holds for it and R5 is what
        audits it.

    Both directions are asserted, because a corpus in which every entry fell
    on one side would make the other rule vacuous for this kind — and
    vacuity that nobody notices is the failure this gate exists to prevent."""
    var c = inmem_scan_identity_corpus()
    var base = -1
    var schema_at = -1
    var bytes_at = -1
    for i in range(c.num_entries()):
        if c.labels[i] == String("baseline"):
            base = i
        elif c.labels[i] == String("schema"):
            schema_at = i
        elif c.labels[i] == String("bytes"):
            bytes_at = i
    assert_true(base >= 0 and schema_at >= 0 and bytes_at >= 0)
    # R2's premise HOLDS here.
    assert_not_equal(
        c.bindings[base].fingerprint, c.bindings[schema_at].fingerprint
    )
    assert_not_equal(
        c.bindings[base].identity_hash(), c.bindings[schema_at].identity_hash()
    )
    # R2's premise NEVER holds here — R5 is the auditor.
    assert_equal(
        c.bindings[base].fingerprint, c.bindings[bytes_at].fingerprint
    )
    assert_not_equal(
        c.bindings[base].structural_id, c.bindings[bytes_at].structural_id
    )


def test_the_registry_has_at_last_seen_two_different_orientations() raises:
    """⚠ THE AUDIT'S OWN PRECONDITION: THE REGISTRY HOLDS BOTH ORIENTATIONS.

    `identity_hash()` folds `orientation`, and `ScanKindRegistry.validate`
    refuses a binding whose orientation differs from its descriptor's. Both were
    written against a registry in which EVERY kind declared
    `SCAN_ORIENTATION_COLUMNAR` — the field's own default — so neither could
    ever have produced a different answer, and both would have passed as dead
    code.

    This asserts the registry now contains BOTH values. It is the guard that
    keeps the ROW kind from quietly reverting to COLUMNAR and taking these two
    mechanisms back to unexercised without anything else going red.
    """
    var reg = _registry()
    var saw_columnar = False
    var saw_row = False
    for kind_name in [
        String(SCAN_KIND_NAME_ARROW_IPC),
        String(SCAN_KIND_NAME_ORC),
        String(SCAN_KIND_NAME_AVRO),
        String(SCAN_KIND_NAME_CSV),
    ]:
        var d = reg.descriptor(scan_kind_id(kind_name))
        if d.orientation == SCAN_ORIENTATION_COLUMNAR:
            saw_columnar = True
        if d.orientation == SCAN_ORIENTATION_ROW:
            saw_row = True
    assert_true(saw_columnar, "no registered kind declares COLUMNAR")
    assert_true(
        saw_row,
        "no registered kind declares ROW — `orientation` is back to being a"
        " field whose only observed value is its default, which makes both"
        " `ScanData.__init__`'s read and `ScanKindRegistry.validate`'s check"
        " unfalsifiable",
    )


# =============================================================================
# 6. R4 (REACH) — THE GATE HAD THE HOLE IT WAS BUILT TO CLOSE.
# =============================================================================
#
# Everything above compares VALUES on a `ScanBinding`. None of it asks whether
# the value gets anywhere, and `identity_hash()` matters for exactly one
# reason: `LogicalPlan.structural_hash()` is FNV-1a over the plan TEXT and
# `EngineContext` uses it as `factory_hash`.
#
# One line of the plan renderer carries it there —
# `writer.write(", bid=", b.identity_hash())`. Deleting it would leave
# `test_every_registered_scan_kind_covers_its_own_fingerprint` GREEN, and
# only the two FORMAT goldens in section 3 would go red. A format golden goes
# red on any innocuous render change, so the fix of least resistance is to
# update its literal — at which point identity is out of the cache key with
# nothing left to notice. That is the same shape as the four instances this
# file exists for: a value that reaches one fold and not the one everything
# reads.


def test_a_difference_only_the_derived_identity_carries_reaches_the_plan_hash() raises:
    """THE PRODUCTION-PATH FALSIFIER FOR THE `bid=` DELETION. RED if
    the plan renderer stops emitting the binding's `identity_hash()`, with no
    fixture, no planted corpus and no format literal involved.

    Two arrow bindings over ONE path at ONE mtime with DIFFERENT SCHEMAS.
    Everything else the scan node renders is identical BY CONSTRUCTION:

      `path=` / `binding=`  — `ArrowSource`'s params are path, codec and
                              estimated_rows; the schema is not among them, and
                              `ScanBinding.render()` emits only kind_name, name
                              and the param map.
      `bsid=`               — `ArrowSource.fingerprint()` folds path + mtime
                              ONLY, so the kind-supplied id is EQUAL.
      `type=` / `source_kind=` — same kind, same declared orientation.

    So `bid=` is the ONLY field that can carry the difference, and
    `identity_hash()` folds `schema_identity_hash(schema)` precisely so it can.
    This is not hypothetical: two scans of one Arrow file under different
    projected schemas are different queries, and sharing a `factory_hash` hands
    one the other's compiled plan.
    """
    var a = SourceVariant.from_arrow_uncompressed(
        ArrowSource(String("/t/a.arrow"), Schema(), mtime_ns=UInt64(7))
    )
    var b = SourceVariant.from_arrow_uncompressed(
        ArrowSource(String("/t/a.arrow"), _schema_abc(), mtime_ns=UInt64(7))
    )

    # The premise: every OTHER discriminator is equal.
    assert_equal(a.binding_ref().fingerprint, b.binding_ref().fingerprint)
    assert_equal(a.binding_ref().structural_id, b.binding_ref().structural_id)
    assert_equal(a.binding_ref().render(), b.binding_ref().render())
    # The claim: core DERIVED a difference, and it reaches the plan text.
    assert_not_equal(
        a.binding_ref().identity_hash(), b.binding_ref().identity_hash()
    )

    var pa = LogicalPlan.scan_from_source(a^, Schema())
    var pb = LogicalPlan.scan_from_source(b^, Schema())
    assert_not_equal(
        String(pa),
        String(pb),
        "two arrow scans whose ONLY difference is one core DERIVED render"
        " identically — `bid=` is the only field that can carry it, so it is"
        " gone from the render; text was: " + String(pa),
    )
    assert_not_equal(
        pa.structural_hash(),
        pb.structural_hash(),
        "and therefore they share a plan-compile cache key",
    )


def test_every_corpus_entrys_identity_appears_in_its_rendered_plan_text() raises:
    """R4a as a readable assertion, over the SAME registry-driven corpora the
    audit uses — so it covers a kind that does not exist yet.

    Containment rather than a field name on purpose: it pins that the identity
    is IN the text, and survives renaming `bid=` or reordering the fields. A
    rule, not a third golden.
    """
    var corpora = _corpora()
    var rendered = render_corpora_plan_text(corpora)
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        for i in range(c.num_entries()):
            assert_true(
                String(c.bindings[i].identity_hash()) in rendered[ci][i],
                String("kind '")
                + c.descriptor.kind_name
                + String("' entry '")
                + c.labels[i]
                + String("': the derived identity reaches nothing; rendered: ")
                + rendered[ci][i],
            )


def test_the_audit_catches_an_identity_that_never_reaches_the_plan_text() raises:
    """THE R4a FALSIFIER — the `bid=` deletion, simulated exactly, without
    editing production code.

    The audit takes the rendered text as an argument (the plan layer cannot be
    imported from `source/` — see `scan_identity_audit.mojo`'s header), so the
    deletion is reproducible here by stripping `, bid=<n>` from every rendered
    line and asserting the gate goes RED. Without R4, this exact input would
    be GREEN.
    """
    var corpora = _corpora()
    var rendered = render_corpora_plan_text(corpora)
    var stripped = List[List[String]]()
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        var texts = List[String]()
        for i in range(c.num_entries()):
            var bid = String(", bid=") + String(c.bindings[i].identity_hash())
            texts.append(rendered[ci][i].replace(bid, String("")))
        stripped.append(texts^)
    with assert_raises(contains="AUDIT R4a (REACH) FAILED"):
        audit_scan_identity_coverage(_registry(), corpora, stripped)


def test_the_audit_catches_two_distinct_plans_that_render_identically() raises:
    """THE R4b FALSIFIER, and the reason R4b is not redundant with R4a.

    Each text below CONTAINS its own entry's identity — R4a is satisfied — yet
    the two texts are EQUAL, so `structural_hash()` cannot separate the plans.
    R4a alone would pass; the pair rule is what catches it.
    """
    var corpora = _corpora()
    var rendered = render_corpora_plan_text(corpora)
    var merged = List[List[String]]()
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        # One text naming EVERY entry's identity, used for every entry.
        var both = String("Scan(")
        for i in range(c.num_entries()):
            both += String(" id") + String(i) + String("=")
            both += String(c.bindings[i].identity_hash())
        both += String(")")
        var texts = List[String]()
        for _ in range(c.num_entries()):
            texts.append(String(both))
        merged.append(texts^)
    with assert_raises(contains="AUDIT R4b (REACH) FAILED"):
        audit_scan_identity_coverage(_registry(), corpora, merged)


def test_the_coverage_message_measures_the_plan_text_it_used_to_assert() raises:
    """R2's diagnostic must not state a consequence its own run disproves.

    An unconditional "so the plan TEXT does not, so `structural_hash()` does
    not, so they SHARE a plan-compile cache key" would be wrong: the
    planted-hole corpus below is a counterexample to exactly that chain. Those
    two bindings differ in their kind-supplied `structural_id`, which the
    render emits as `bsid=`, so their plan text DOES differ and they do NOT
    share a key. A diagnostic that overstates teaches the reader to discount
    it.

    The message MEASURES the plan-text outcome (R4 is what makes that a
    meaningful measurement) and labels what remains INFERRED. This asserts both
    halves are present, not merely that R2 still fires.
    """
    var reg = ScanKindRegistry()
    reg.register(
        ScanKindDescriptor(
            kind_name=String("example.hole.kind"),
            gate=PushdownGate.reject_all(),
        )
    )
    var c = ScanIdentityCorpus(
        ScanKindDescriptor(
            kind_name=String("example.hole.kind"),
            gate=PushdownGate.reject_all(),
        )
    )
    c.add(String("v1"), _planted(UInt64(0x1111)))
    c.add(String("v2"), _planted(UInt64(0x2222)))
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(c^)

    # The counterexample, measured here first: the two plans do NOT collide.
    assert_not_equal(
        render_scan_plan_text(_planted(UInt64(0x1111))),
        render_scan_plan_text(_planted(UInt64(0x2222))),
    )
    with assert_raises(contains="MEASURED: their rendered plan text DIFFERS"):
        audit_scan_identity(reg, corpora.copy(), corpora.copy())


def test_the_render_list_cannot_silently_describe_other_corpora() raises:
    """R4's precondition. A shape mismatch is the one way R4 could be skipped
    while the audit reported PASS, so it is a named error."""
    var corpora = _corpora()
    var short = List[List[String]]()
    with assert_raises(contains="AUDIT R4 (REACH)"):
        audit_scan_identity_coverage(_registry(), corpora, short)


# =============================================================================
# 7. R5 — THE TWIN R4 DID NOT CLOSE.
# =============================================================================
#
# Section 6 protects `bid=`. The render writes TWO identities:
#
#     writer.write(", bsid=", b.structural_id)      # the KIND-SUPPLIED one
#     writer.write(", bid=", b.identity_hash())     # the CORE-DERIVED one
#
# Deleting the `bsid=` write and running this file without R5 gives:
#
#     PASS test_every_registered_scan_kind_covers_its_own_fingerprint
#     ...
#     FAIL test_golden_rendered_plan_text_arrow      <- FORMAT golden
#     FAIL test_golden_rendered_plan_text_broker     <- FORMAT golden
#     FAIL test_the_coverage_message_measures_the_plan_text_it_used_to_assert
#
# The class gate stays GREEN: R0-R4 never read `structural_id` at all. The
# third failure is not a class rule either — it is the hand-planted
# two-binding witness of sections 4 and 6, which happens to differ ONLY in
# `structural_id`; it names R2's diagnostic in its message, so it points a
# reader away from the defect rather than at it.
#
# ⚠ AND `bsid=` IS NOT REDUNDANT WITH `bid=`. `identity_hash()` folds kind_id,
# kind_name, name, params, schema, gate and orientation — everything core can
# SEE. `structural_id` is the kind's statement about what core CANNOT: two
# `from_record_batch` sources with one synthetic name and one schema differ
# only in their BYTES, and for that pair `bsid=` is the ONLY field in the
# whole render that can separate two different tables.


def test_every_corpus_entrys_supplied_structural_id_appears_in_its_rendered_plan_text() raises:
    """R5a as a readable assertion, over the SAME registry-driven corpora — so
    it covers a kind that does not exist yet, exactly as its R4a twin does.

    RED if the plan renderer stops emitting `b.structural_id`.
    """
    var corpora = _corpora()
    var rendered = render_corpora_plan_text(corpora)
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        for i in range(c.num_entries()):
            assert_true(
                String(c.bindings[i].structural_id) in rendered[ci][i],
                String("kind '")
                + c.descriptor.kind_name
                + String("' entry '")
                + c.labels[i]
                + String("': the KIND-SUPPLIED identity reaches nothing;")
                + String(" rendered: ")
                + rendered[ci][i],
            )


def test_the_audit_catches_a_supplied_identity_that_never_reaches_the_plan_text() raises:
    """THE R5a FALSIFIER — the `bsid=` deletion, simulated exactly, without
    editing production code. Without R5 this exact input would be GREEN: R4
    alone closes only one of the two twins."""
    var corpora = _corpora()
    var rendered = render_corpora_plan_text(corpora)
    var stripped = List[List[String]]()
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        var texts = List[String]()
        for i in range(c.num_entries()):
            var bsid = String(", bsid=") + String(c.bindings[i].structural_id)
            texts.append(rendered[ci][i].replace(bsid, String("")))
        stripped.append(texts^)
    with assert_raises(contains="AUDIT R5a (SUPPLIED REACH) FAILED"):
        audit_scan_identity_coverage(_registry(), corpora, stripped)


def test_a_pair_rule_that_only_observed_a_difference_would_not_have_caught_this() raises:
    """THE R5b FALSIFIER, AND THE REASON R5b IS NOT "the texts differ".

    The simulated regression is a plausible-looking render change: instead of
    this scan's own `bsid=<id>`, emit the SET of every structural_id in the
    corpus. Containment still holds for every entry (R5a green), every text
    still carries its own `bid=` (R4a green) and the texts still DIFFER pairwise
    (R4b green, and an observe-a-difference pair rule would be green too) — but
    no text is attributable to ITS OWN supplied identity any more, so a real
    `bsid=` deletion is indistinguishable from this.

    The test asserts BOTH halves: first that the naive property holds (so the
    weaker rule really would have passed), then that R5b fires anyway.
    """
    var corpora = _corpora()
    var rendered = render_corpora_plan_text(corpora)
    var smeared = List[List[String]]()
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        var all_sids = String("bsids=[")
        for i in range(c.num_entries()):
            if i > 0:
                all_sids += String(" ")
            all_sids += String(c.bindings[i].structural_id)
        all_sids += String("]")
        var texts = List[String]()
        for i in range(c.num_entries()):
            var own = String("bsid=") + String(c.bindings[i].structural_id)
            texts.append(rendered[ci][i].replace(own, all_sids))
        smeared.append(texts^)

    # HALF ONE: the naive pair property — "differing structural_id forces
    # differing text" — must still hold on SOME pair, or half two proves
    # nothing about masking.
    #
    # ⚠ IT DOES NOT HOLD ON EVERY PAIR, BECAUSE OF IN_MEMORY.
    # The masking comes from `bid=`, and `bid=` separates a pair only when
    # core's DERIVED identity does. That is true of every FILE-kind pair
    # because `structural_id == fingerprint` for every file kind and R2 forces
    # the derived fold to separate whatever the fingerprint separates.
    # `komira.in_memory` is the kind for which it is false BY CONSTRUCTION:
    # two batches with one name and one schema differing only in their BYTES
    # have an identical `identity_hash()`, so `bid=` cannot mask anything and
    # the naive rule fails on its own.
    #
    # So the assertion is two-sided: masking must still be DEMONSTRATED
    # somewhere, and the only kind allowed to escape it is one whose supplied
    # identity core provably cannot derive.
    var masked = 0
    var unmasked = 0
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        for i in range(c.num_entries()):
            for j in range(i + 1, c.num_entries()):
                if c.bindings[i].structural_id == c.bindings[j].structural_id:
                    continue
                if smeared[ci][i] != smeared[ci][j]:
                    masked += 1
                    continue
                unmasked += 1
                assert_equal(
                    String(c.descriptor.kind_name),
                    String(SCAN_KIND_NAME_IN_MEMORY),
                    "a pair the naive rule CANNOT see, for a kind whose"
                    " `identity_hash()` was supposed to separate it. Either R2"
                    " stopped holding for this kind, or a second kind now"
                    " supplies an identity core cannot derive — both are"
                    " findings, neither is a reason to relax this test",
                )
                assert_equal(
                    c.bindings[i].identity_hash(),
                    c.bindings[j].identity_hash(),
                    "the pair is unmasked but its derived identities DIFFER, so"
                    " something other than `bid=` stopped separating the texts",
                )
    assert_true(
        masked > 0,
        "the weaker pair rule was supposed to PASS on at least one pair; if it"
        " passes on none, this test is no longer demonstrating the masking",
    )
    assert_true(
        unmasked > 0,
        "no pair in any corpus is separated by `structural_id` ALONE, so R5b is"
        " demonstrated only against pairs `bid=` already separates. That was the"
        " state of the tree before step 6, and it is what"
        " `_cheap_witness_binding` exists to stand in for — if it has returned,"
        " the in-memory corpus lost its bytes-only entries",
    )

    # HALF TWO: R5b fires regardless, because the difference is not AT the
    # structural_id.
    with assert_raises(contains="AUDIT R5b (ATTRIBUTION) FAILED"):
        audit_scan_identity_coverage(_registry(), corpora, smeared)


def test_a_difference_only_the_kind_supplied_identity_carries_reaches_the_plan_hash() raises:
    """THE PRODUCTION-PATH FALSIFIER FOR THE `bsid=` DELETION — the exact
    analogue of `test_a_difference_only_the_derived_identity_carries_reaches_
    the_plan_hash`, on the other twin.

    Two bindings for which EVERY input core can see is identical — same
    kind_id, name, params, schema, gate, orientation, snapshot policy — and
    only the KIND-SUPPLIED `structural_id` differs. So `identity_hash()` is
    equal by construction, `binding=` is equal, `path=` / `type=` /
    `source_kind=` are equal, and `bsid=` is the ONLY field that can separate
    the two plans.

    ⚠ THIS PAIR IS NOT A CURIOSITY. Two `DataFrame.from_record_batch` sources
    with the same synthetic name (`__inmem_<firstcol>_<numrows>`) and the same
    schema differ ONLY in their bytes; `InMemorySource` is the only thing that
    can hash those, and it does so into `structural_id`. Merging them in
    `structural_hash()` would make a self-join over two different in-memory
    tables read one of them twice.
    """
    var a = _planted(UInt64(0x1111))
    var b = _planted(UInt64(0x2222))

    # The premise: every discriminator CORE derives is equal.
    assert_equal(a.identity_hash(), b.identity_hash())
    assert_equal(a.render(), b.render())
    assert_not_equal(a.structural_id, b.structural_id)

    var pa = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(a.copy()), Schema()
    )
    var pb = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(b.copy()), Schema()
    )
    assert_not_equal(
        String(pa),
        String(pb),
        "two scans whose ONLY difference is the identity the KIND supplies"
        " render identically — `bsid=` is the only field that can carry it, so"
        " it is gone from the render; text was: " + String(pa),
    )
    assert_not_equal(
        pa.structural_hash(),
        pb.structural_hash(),
        "and therefore two different tables share a plan-compile cache key",
    )


# =============================================================================
# 8. R6-R8 — THE SECOND CORPUS AXIS: THE SCAN NODE'S OWN FIELDS.
# =============================================================================
#
# Section 6 protects `bid=`; section 7 protects `bsid=`. The same question
# applies to EVERY value `plan_display._write_plan_node` writes for a scan
# node — neutralise one write, run the class gate — and it finds a THIRD
# carrier in a strictly worse state than either twin:
#
#     projection=  ScanData.projection   no class rule, and NO golden
#     filter=      ScanData.filter       no class rule, and NO golden
#
# `bid=` and `bsid=` at least go red in two FORMAT goldens. These would go
# red in NOTHING: no plan-text expectation contains `projection=` or
# `filter=`, and no `assert_not_equal` on `structural_hash()` covers a
# projection-only or filter-only difference. A test with two different filter
# predicates in a `Filter` NODE above the scan does not count — its
# predicates never reach the scan's own `filter=`.
#
# ⚠ WHY R4/R5 CANNOT REACH IT, AND WHY THE FIX IS NOT A THIRD GOLDEN.
# `ScanIdentityCorpus` varies `ScanBinding`s; `projection` and `filter` are
# SCAN-NODE fields no binding corpus can populate, so no amount of corpus
# discipline over bindings touches them. A format golden is precisely what
# would leave them unprotected. So this is a SECOND CORPUS AXIS through the
# same containment rules — `ScanNodeCorpus`, R6 (non-vacuity) / R7 (reach) /
# R8 (separation) — run from the SAME entry point over EVERY registered kind.


def _witness(var a: String) -> List[String]:
    var out = List[String]()
    out.append(a^)
    return out^


def _cols2(var a: String, var b: String) -> List[String]:
    var out = List[String]()
    out.append(a^)
    out.append(b^)
    return out^


def _node_plan(
    var projection: Optional[List[String]], var filter: Optional[Expr]
) raises -> LogicalPlan:
    """A scan over ONE fixed arrow binding, varying only the node fields.

    The binding is a constant of this helper on purpose: every binding-derived
    field of the render is then identical between two calls, so a difference in
    the output can only have come from `projection` or `filter`. Attribution by
    construction, which is what the `bsid=` twin had to buy with a lexical
    witness (R5b)."""
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(
            _arrow_binding_for(String("/t/node.arrow"), UInt64(11))
        ),
        Schema(),
        projection^,
        filter^,
    )


def test_a_projection_only_difference_reaches_the_plan_compile_cache_key() raises:
    """THE PRODUCTION-PATH FALSIFIER FOR THE `projection=` DELETION.

    Two scans of ONE path under ONE binding, differing ONLY in the scan-level
    projection. Every other field the node renders is identical by construction
    (one binding), so `projection=` is the only thing that can separate them.
    Two scans reading different column sets are different queries; sharing a
    `factory_hash` hands one the other's compiled plan.

    RED if the renderer's `projection=` write is neutralised — and so is the
    whole class gate."""
    var alpha = String(NODE_WITNESS_ALPHA)
    var beta = String(NODE_WITNESS_BETA)
    var pa = _node_plan(Optional(_witness(String(alpha))), None)
    var pb = _node_plan(Optional(_witness(String(beta))), None)
    assert_not_equal(
        String(pa),
        String(pb),
        "two scans of one binding differing ONLY in their scan-level projection"
        " render identically — `projection=` is the only field that can carry"
        " it, so it is gone from the render; text was: " + String(pa),
    )
    assert_not_equal(
        pa.structural_hash(),
        pb.structural_hash(),
        "and therefore two different column sets share a plan-compile cache key",
    )


def test_a_projection_order_only_difference_reaches_the_plan_compile_cache_key() raises:
    """AND ORDER IS PART OF IT. Identity-coverage instance 3 was ORC's
    projection ORDER reaching the kind's fingerprint and not core's derived
    identity, so the same input is checked here on the node axis: the same two
    columns in the opposite order must not collide.

    This pair is invisible to a containment rule — both texts carry both column
    names — so R8 is the only rule that can see it, and a render that sorted the
    projection would be caught by nothing else in the tree."""
    var alpha = String(NODE_WITNESS_ALPHA)
    var beta = String(NODE_WITNESS_BETA)
    var pa = _node_plan(
        Optional(_cols2(String(alpha), String(beta))), None
    )
    var pb = _node_plan(
        Optional(_cols2(String(beta), String(alpha))), None
    )
    assert_not_equal(
        String(pa),
        String(pb),
        "two scans whose projections differ only in ORDER render identically;"
        " text was: " + String(pa),
    )
    assert_not_equal(pa.structural_hash(), pb.structural_hash())


def test_a_filter_only_difference_reaches_the_plan_compile_cache_key() raises:
    """THE PRODUCTION-PATH FALSIFIER FOR THE `filter=` DELETION — the other
    half of the third carrier.

    ⚠ A FILTER NODE ABOVE THE SCAN DOES NOT COVER THIS: such predicates reach
    the plan text through `Filter(predicate=...)` and never through the scan's
    own `filter=`. The predicates here are PUSHED DOWN — a `ScanData.filter`,
    which is what `optimizer_filter.push_predicates_down` produces and what the
    scan's render is the only carrier for."""
    var alpha = String(NODE_WITNESS_ALPHA)
    var fa = col(String(alpha)) > 0
    var fb = col(String(alpha)) > 1
    var pa = _node_plan(None, Optional(fa^))
    var pb = _node_plan(None, Optional(fb^))
    assert_not_equal(
        String(pa),
        String(pb),
        "two scans of one binding differing ONLY in their PUSHED-DOWN filter"
        " render identically — `filter=` is the only field that can carry it,"
        " so it is gone from the render; text was: " + String(pa),
    )
    assert_not_equal(
        pa.structural_hash(),
        pb.structural_hash(),
        "and therefore two different predicates share a plan-compile cache key",
    )


def test_every_registered_kinds_scan_node_fields_reach_its_plan_text() raises:
    """R6-R8 as a readable assertion, over the SAME registry-driven corpora the
    binding axis uses — so the node axis covers a kind that does not exist yet,
    exactly as R0 makes the binding axis do.

    Core states the node corpus ONCE (`build_scan_node_corpus`) because
    `projection` and `filter` are `ScanData` fields written by one branch every
    kind shares. A per-kind node corpus would be seven copies of one statement
    and a kind could ship a curated one."""
    var corpora = _corpora()
    assert_true(len(corpora) >= 2, "the node axis is being run over nothing")
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        audit_scan_node_identity(
            build_scan_node_corpus(
                String(c.descriptor.kind_name), c.bindings[0]
            )
        )


def _node_corpus_for_falsifiers() raises -> ScanNodeCorpus:
    """Four entries: two that differ ONLY in projection, two ONLY in filter.
    The minimum that satisfies R6, so each falsifier below fails for the rule it
    names rather than for vacuity."""
    var b = _arrow_binding_for(String("/t/node.arrow"), UInt64(11))
    var alpha = String(NODE_WITNESS_ALPHA)
    var beta = String(NODE_WITNESS_BETA)
    var c = ScanNodeCorpus(String("komira.arrow.ipc"), b)
    c.add(
        String("p-alpha"),
        _witness(String(alpha)),
        Optional(_witness(String(alpha))),
        None,
    )
    c.add(
        String("p-beta"),
        _witness(String(beta)),
        Optional(_witness(String(beta))),
        None,
    )
    var f0 = col(String(alpha)) > 0
    var w0 = String(f0)
    c.add(String("f-gt-0"), _witness(w0^), None, Optional(f0^))
    var f1 = col(String(alpha)) > 1
    var w1 = String(f1)
    c.add(String("f-gt-1"), _witness(w1^), None, Optional(f1^))
    return c^


def test_the_node_audit_catches_a_projection_that_never_reaches_the_plan_text() raises:
    """THE R7a FALSIFIER FOR `projection=`, simulated exactly and without
    editing production code.

    "The write was deleted" is not approximated by string surgery here — it is
    RE-RENDERED through the production path with the projection ABSENT, which is
    byte-for-byte what `_write_plan_node` would emit if the write did not exist.
    Without this axis, this exact input would be GREEN in every other rule."""
    var c = _node_corpus_for_falsifiers()
    var b = _arrow_binding_for(String("/t/node.arrow"), UInt64(11))
    # Entries 0 and 1 carry a projection and no filter.
    c.rendered[0] = render_scan_node_plan_text(b, None, None)
    c.rendered[1] = render_scan_node_plan_text(b, None, None)
    with assert_raises(contains="AUDIT R7a (NODE REACH) FAILED"):
        audit_scan_node_identity(c)


def test_the_node_audit_catches_a_filter_that_never_reaches_the_plan_text() raises:
    """THE R7a FALSIFIER FOR `filter=` — the same simulation on the other half
    of the third carrier, because closing one of a pair and calling it done is
    exactly the hole R4 alone leaves for `bsid=`."""
    var c = _node_corpus_for_falsifiers()
    var b = _arrow_binding_for(String("/t/node.arrow"), UInt64(11))
    # Entries 2 and 3 carry a filter and no projection.
    c.rendered[2] = render_scan_node_plan_text(b, None, None)
    c.rendered[3] = render_scan_node_plan_text(b, None, None)
    with assert_raises(contains="AUDIT R7a (NODE REACH) FAILED"):
        audit_scan_node_identity(c)


def test_the_node_audit_catches_two_distinct_scan_nodes_that_render_identically() raises:
    """THE R8 FALSIFIER, and the reason R8 is not implied by R7a.

    Every text below CONTAINS every witness, so R7a and R7c are satisfied — yet
    all four are EQUAL, so `structural_hash()` cannot separate them. This is the
    shape a render that emitted the WHOLE corpus's fields into every node would
    have, and the pair rule is the only thing that sees it."""
    var c = _node_corpus_for_falsifiers()
    var everything = String(c.control)
    for i in range(c.num_entries()):
        ref ws = c.witnesses[i]
        for w in range(len(ws)):
            everything += String(" ") + ws[w]
    for i in range(c.num_entries()):
        c.rendered[i] = String(everything)
    with assert_raises(contains="AUDIT R8 (NODE SEPARATION) FAILED"):
        audit_scan_node_identity(c)


def test_a_node_corpus_that_exercises_only_one_axis_is_red_not_green() raises:
    """R6, and it is NOT the same rule as R1 one level over — it is sharper.

    R1 asks for two distinct fingerprints. R6 asks for two distinct values on
    EACH AXIS IN ISOLATION, because a corpus whose entries always vary BOTH
    fields is separated by whichever one still renders: delete `projection=` and
    every pair is still separated by its filter, so R8 reports green having
    proven nothing about projection. The isolation clause is the whole rule."""
    var b = _arrow_binding_for(String("/t/node.arrow"), UInt64(11))
    var alpha = String(NODE_WITNESS_ALPHA)
    var beta = String(NODE_WITNESS_BETA)

    # (a) filter axis never varied on its own.
    var only_proj = ScanNodeCorpus(String("example.oneaxis.kind"), b)
    only_proj.add(
        String("p-alpha"),
        _witness(String(alpha)),
        Optional(_witness(String(alpha))),
        None,
    )
    only_proj.add(
        String("p-beta"),
        _witness(String(beta)),
        Optional(_witness(String(beta))),
        None,
    )
    with assert_raises(contains="NO pair that differs ONLY in `filter`"):
        audit_scan_node_identity(only_proj)

    # (b) projection axis never varied on its own.
    var only_filter = ScanNodeCorpus(String("example.oneaxis.kind"), b)
    var f0 = col(String(alpha)) > 0
    var w0 = String(f0)
    only_filter.add(String("f-gt-0"), _witness(w0^), None, Optional(f0^))
    var f1 = col(String(alpha)) > 1
    var w1 = String(f1)
    only_filter.add(String("f-gt-1"), _witness(w1^), None, Optional(f1^))
    with assert_raises(contains="NO pair that differs ONLY in `projection`"):
        audit_scan_node_identity(only_filter)


def test_a_witness_the_binding_already_supplies_is_red_not_green() raises:
    """R7b, the clause that measures away R7a's residual instead of accepting
    it.

    R4a and R5a accept a stated residual: containment of a 64-bit decimal could
    in principle be satisfied by another field's digits. For a COLUMN NAME that
    residual is not small — a projection named `a` is a substring of almost any
    path. So the node axis does not accept it: a witness that already appears in
    the CONTROL render (the same binding with neither field set) is RED, because
    R7a would then hold for that entry with the field's write DELETED.

    Here the binding's own path is poisoned with the witness, which is exactly
    what a badly-chosen witness looks like."""
    var poisoned = _arrow_binding_for(
        String("/t/") + String(NODE_WITNESS_ALPHA) + String(".arrow"),
        UInt64(11),
    )
    var alpha = String(NODE_WITNESS_ALPHA)
    var beta = String(NODE_WITNESS_BETA)
    var c = ScanNodeCorpus(String("example.poisoned.kind"), poisoned)
    c.add(
        String("p-alpha"),
        _witness(String(alpha)),
        Optional(_witness(String(alpha))),
        None,
    )
    c.add(
        String("p-beta"),
        _witness(String(beta)),
        Optional(_witness(String(beta))),
        None,
    )
    var f0 = col(String(beta)) > 0
    var w0 = String(f0)
    c.add(String("f-gt-0"), _witness(w0^), None, Optional(f0^))
    var f1 = col(String(beta)) > 1
    var w1 = String(f1)
    c.add(String("f-gt-1"), _witness(w1^), None, Optional(f1^))
    with assert_raises(contains="AUDIT R7b (NODE REACH / CAUSED) FAILED"):
        audit_scan_node_identity(c)


def test_the_node_axis_runs_from_the_same_entry_point_as_the_binding_axis() raises:
    """A SECOND AXIS NOBODY CALLS IS A SECOND AXIS THAT DOES NOT EXIST.

    `audit_scan_identity` is THE gate. This asserts the node axis runs from
    inside it, for every corpus it is handed, by feeding it a corpus that passes
    every binding-axis rule (two arrow bindings at two mtimes — distinct
    fingerprints, distinct derived identities, agreeing descriptor) and whose
    only fault is on the node axis: the binding's PATH contains the node
    witness, so R7b fires.

    Without the wiring this input is GREEN — which is precisely how a rule set
    that is never called reports success."""
    var reg = ScanKindRegistry()
    reg.register(arrow_scan_descriptor())
    var poisoned_path = String("/t/") + String(NODE_WITNESS_ALPHA) + String(
        ".arrow"
    )
    var c = ScanIdentityCorpus(arrow_scan_descriptor())
    c.add(String("mtime-0"), _arrow_binding_for(String(poisoned_path), UInt64(0)))
    c.add(String("mtime-1"), _arrow_binding_for(String(poisoned_path), UInt64(1)))
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(c^)
    with assert_raises(contains="AUDIT R7b (NODE REACH / CAUSED) FAILED"):
        audit_scan_identity(reg, corpora.copy(), corpora.copy())


def test_an_empty_registry_is_red_not_a_vacuous_pass() raises:
    """R0c. R0b iterates the registry; over an empty one it iterates nothing and
    every rule below reports PASS having checked no kind. Same principle as R1
    one level up: a scan whose precondition never holds reports green while
    checking nothing."""
    var empty = ScanKindRegistry()
    with assert_raises(contains="the registry is"):
        audit_scan_identity(
            empty, List[ScanIdentityCorpus](), List[ScanIdentityCorpus]()
        )


# =============================================================================
# 8. R9 REPRODUCIBILITY — every rule R0-R8 is BLIND to a per-construction
#    identity.
# =============================================================================
#
# `InMemorySource.from_record_batch` on two byte-identical 8-row INT64
# batches gives:
#
#   IDENTICAL CONTENT
#     a.fingerprint()   = 10451216379200822465     <- DIFFER
#     b.fingerprint()   = 10905525725756348110
#     a.structural_id() = 5502437198329981542      <- EQUAL
#     b.structural_id() = 5502437198329981542
#     a plan text       = Scan(path="__in_memory__", type=IN_MEMORY,
#                              inmem_id=5502437198329981542,
#                              source_kind=COLUMNAR)
#     b plan text       = (byte-identical)
#     a/b structural_hash() = 442106568064097468   <- EQUAL
#
#   DIFFERENT CONTENT
#     a.structural_id() = 5502437198329981542
#     b.structural_id() = 12044196832890295638
#     a/b structural_hash() = 442106568064097468 / 14687349485171436105
#
# So for IN_MEMORY the KIND's `fingerprint()` is NOT its plan-discriminating
# identity — `structural_id()` is, and `fingerprint()`'s own docstring says
# why (folding it into the structural hash would break subquery dedup and the
# plan-compile cache). The audit's R1 and R2 both read `binding.fingerprint`,
# so an IN_MEMORY corpus that supplies the counter — which is what
# `ScanBinding.fingerprint`'s docstring instructs every binding-backed arm to
# supply — walks into both of the traps the tests below pin.


def _inmem_1col_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, nullable=False))
    return sb.build()


def _inmem_batch(num_rows: Int, seed: Int) raises -> RecordBatch:
    var vals = List[Int64]()
    for i in range(num_rows):
        vals.append(Int64(seed + i))
    return RecordBatch.from_columns_1(
        _inmem_1col_schema(), PrimitiveArray[DType.int64].from_list(vals)
    )


def _counter_backed_binding(num_rows: Int, seed: Int) raises -> ScanBinding:
    """An IN_MEMORY binding built THE WAY `ScanBinding.fingerprint`'s
    docstring instructs — "A migrated arm MUST pass the value its concrete
    source's `fingerprint()` returned". For every file kind that is right.
    For IN_MEMORY it supplies a process-global counter."""
    var ims = InMemorySource.from_record_batch(_inmem_batch(num_rows, seed))
    var params = ScanParams()
    return ScanBinding(
        kind_id=scan_kind_id(String("example.inmem.probe")),
        kind_name=String("example.inmem.probe"),
        name=String("__in_memory__"),
        params=params^,
        schema=Schema(),
        fingerprint=ims.fingerprint(),
        structural_id=ims.structural_id(),
        gate=PushdownGate.accept_all(),
    )


def _counter_backed_corpora() raises -> List[ScanIdentityCorpus]:
    """The corpus builder under test. Called TWICE by R9, exactly as the
    production gate calls `core_scan_identity_corpora()` twice."""
    var d = ScanKindDescriptor(
        kind_name=String("example.inmem.probe"),
        gate=PushdownGate.accept_all(),
    )
    var c = ScanIdentityCorpus(d^)
    c.add(String("content-a"), _counter_backed_binding(8, 0))
    c.add(String("content-b"), _counter_backed_binding(8, 999))
    var out = List[ScanIdentityCorpus]()
    out.append(c^)
    return out^


def _counter_backed_registry() raises -> ScanKindRegistry:
    var reg = ScanKindRegistry()
    reg.register(
        ScanKindDescriptor(
            kind_name=String("example.inmem.probe"),
            gate=PushdownGate.accept_all(),
        )
    )
    return reg^


def test_a_per_construction_identity_is_red_not_green() raises:
    """R9's falsifier, and it is a REAL kind rather than a planted constant:
    the binding is built through `InMemorySource`'s own production factory and
    supplies exactly what `ScanBinding.fingerprint`'s contract asks for.

    Both builds describe the SAME two batches. Only the counter moved."""
    with assert_raises(contains="AUDIT R9 (REPRODUCIBILITY) FAILED"):
        audit_scan_identity(
            _counter_backed_registry(),
            _counter_backed_corpora(),
            _counter_backed_corpora(),
        )


def test_r1_cannot_see_a_corpus_that_varies_nothing_when_identity_is_a_counter() raises:
    """WHY R9 IS NOT REDUNDANT WITH R1.

    R1's whole job is "a corpus that asserts nothing must FAIL": it demands >= 2
    DISTINCT fingerprints so the R2 implication's premise can hold. A
    per-construction counter supplies that for free, so R1 is GREEN on a corpus
    whose two entries are over BYTE-IDENTICAL content — i.e. on a corpus that
    varies nothing at all. The one rule guaranteed unfalsifiable for such a kind
    is the anti-vacuity rule.

    R2 then FIRES on that same corpus, demanding core separate two scans it must
    NOT separate — and R2's FIX line says to carry the differing input in
    `params`, which would make every in-memory plan's cache key per-construction
    unique. That is the trap, asserted here end to end."""
    var a = _counter_backed_binding(8, 0)
    var b = _counter_backed_binding(8, 0)
    assert_not_equal(
        a.fingerprint,
        b.fingerprint,
        "premise: the counter separates two sources over identical content",
    )
    assert_equal(
        a.structural_id,
        b.structural_id,
        "and the CONTENT identity does not — which is the whole point",
    )
    assert_equal(
        a.identity_hash(),
        b.identity_hash(),
        "core's derived identity cannot separate them either, and MUST NOT:"
        " two structurally identical plans must hash equal",
    )

    var d = ScanKindDescriptor(
        kind_name=String("example.inmem.probe"),
        gate=PushdownGate.accept_all(),
    )
    var c = ScanIdentityCorpus(d^)
    c.add(String("same-content"), a^)
    c.add(String("same-content-again"), b^)
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(c^)

    with assert_raises(contains="AUDIT R2 (COVERAGE) FAILED"):
        audit_scan_identity_coverage(
            _counter_backed_registry(),
            corpora.copy(),
            render_corpora_plan_text(corpora),
        )


def test_the_in_memory_plan_hash_is_content_derived_not_per_construction() raises:
    """THE CONTRACT IN_MEMORY MUST KEEP, pinned at the CORE layer.

    Two plans over byte-identical in-memory content MUST share a
    `structural_hash`, and two over different content MUST NOT. Both directions,
    because only the pair makes it a discrimination rather than a constant."""
    var same_a = LogicalPlan.scan_from_source(
        SourceVariant(InMemorySource.from_record_batch(_inmem_batch(8, 0))),
        _inmem_1col_schema(),
    )
    var same_b = LogicalPlan.scan_from_source(
        SourceVariant(InMemorySource.from_record_batch(_inmem_batch(8, 0))),
        _inmem_1col_schema(),
    )
    var other = LogicalPlan.scan_from_source(
        SourceVariant(InMemorySource.from_record_batch(_inmem_batch(8, 999))),
        _inmem_1col_schema(),
    )
    assert_equal(
        same_a.structural_hash(),
        same_b.structural_hash(),
        "two separately-constructed in-memory sources over IDENTICAL content"
        " must share a plan-compile cache key — the subquery-dedup / plan-cache"
        " contract. A per-construction identity in the render breaks it"
        " silently: every plan recompiles and no fold ever fires.",
    )
    assert_not_equal(
        same_a.structural_hash(),
        other.structural_hash(),
        "and two over DIFFERENT content must not — otherwise CSE merges two"
        " distinct tables into a self-join (CSE over-production)",
    )


# =============================================================================
# 9. R10, THE AGG-CSE CHEAP KEY.
# =============================================================================
#
# `placeholder_inmem_id` makes the agg-CSE CHEAP KEY blind to a kind's own
# content identity. It must cover `bsid=` as well as `inmem_id=`: IN_MEMORY
# carries its content hash in `bsid=`, so without the placeholder there the
# content hash re-enters the key and kills the lever — fail-SAFE for
# correctness, silently fatal to the pass.
#
# Placeholdering `bsid=` for the FILE kinds too costs agg-CSE no GROUPING
# PRECISION. Over the registry-driven corpora, all pairs:
#
#     pairs whose `structural_id` differs, that `identity_hash()` does NOT
#     also separate  ............................................  0
#
# Not by luck: audit R2 already demands that core's DERIVED `identity_hash()`
# separate every pair whose `fingerprint()` differs, and
# `structural_id == fingerprint` for every file kind. R10a re-measures that on
# every run instead of leaving it in a comment.
#
# ⚠ AND R10a ALONE IS SATISFIED BY PLACEHOLDERING NOTHING. That is what R10b is
# for: without it, "the placeholder was never applied to `bsid=` and nobody
# noticed" is the state R10a reports as healthy.


def test_the_cheap_key_still_separates_every_pair_core_can_tell_apart() raises:
    """R10a over the REGISTERED corpora — the 0-merge measurement, as a rule.

    ⚠ THE ASSERTION IS ON THE CHEAP KEY, NOT THE EXACT ONE. The exact key
    separates these pairs trivially (nothing is placeholdered in it), so the
    same test written with `structural_hash()` would stay green with the
    placeholder applied to every field in the render."""
    var corpora = core_scan_identity_corpora()
    var checked = 0
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        for i in range(c.num_entries()):
            for j in range(i + 1, c.num_entries()):
                if (
                    c.bindings[i].identity_hash()
                    == c.bindings[j].identity_hash()
                ):
                    continue
                checked += 1
                var pa = LogicalPlan.scan_from_source(
                    SourceVariant.from_binding(c.bindings[i].copy()), Schema()
                )
                var pb = LogicalPlan.scan_from_source(
                    SourceVariant.from_binding(c.bindings[j].copy()), Schema()
                )
                assert_not_equal(
                    pa.structural_hash_modulo_inmem_id(),
                    pb.structural_hash_modulo_inmem_id(),
                    String(
                        "R10a: placeholdering `bsid=` MERGED a pair core's"
                        " derived `identity_hash()` can tell apart — "
                    )
                    + String(c.descriptor.kind_name)
                    + String(" '")
                    + c.labels[i]
                    + String("' vs '")
                    + c.labels[j]
                    + String("'"),
                )
    assert_true(
        checked >= 32,
        String(
            "R10a fixture premise: the registered corpora hold 32 such pairs"
            " across 5 kinds. Fewer means a corpus shrank, and a rule over a"
            " shrunken corpus reports a smaller fact than the one R10 rests"
            " on. Got "
        )
        + String(checked),
    )


def test_the_cheap_key_is_blind_to_a_kind_supplied_content_identity() raises:
    """R10b — the placeholder actually took.

    Two bindings differing ONLY in `structural_id`: the EXACT key must separate
    them (R5's property, restated here as this test's own premise) and the CHEAP
    key must NOT. This is the lever, and the ONLY clause that fails if `bsid=`
    loses its placeholder branch."""
    var wa = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_cheap_witness_binding(UInt64(0x1111))),
        Schema(),
    )
    var wb = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_cheap_witness_binding(UInt64(0x2222))),
        Schema(),
    )
    assert_not_equal(
        wa.structural_hash(),
        wb.structural_hash(),
        "premise: `bsid=` must reach the EXACT key, or R10b below is vacuous",
    )
    assert_equal(
        wa.structural_hash_modulo_inmem_id(),
        wb.structural_hash_modulo_inmem_id(),
        "R10b: the CHEAP key must be blind to the KIND-SUPPLIED content"
        " identity. A mismatch means `_write_plan_node` did not placeholder"
        " `bsid=` — BLOCKER 2's silent death of the agg-CSE pre-grouping, the"
        " moment IN_MEMORY migrates.",
    )


def test_the_cheap_key_rules_run_from_the_same_entry_point() raises:
    """R10 must be reachable from `audit_scan_identity`, not only from the two
    tests above. Same lesson as the node axis: a rule with its own private
    caller is a rule a new kind is not covered by."""
    var reg = _registry()
    audit_scan_identity(reg, _corpora(), _corpora())
    # And directly, so a future edit that drops the call from the entry point
    # is not masked by this test never having exercised the rule itself.
    audit_scan_identity_cheap_key(_corpora())


def test_r10b_could_tell_a_lost_placeholder_from_a_working_one() raises:
    """THE ANTI-VACUITY CLAUSE FOR R10b. Its assertion is an EQUALITY, and an
    equality is satisfied for free by a render that emits neither value. Pin
    both halves of what makes it a measurement: the witness pair is separable
    WITHOUT the placeholder, and the two renders of ONE binding actually
    differ."""
    var wa = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_cheap_witness_binding(UInt64(0x1111))),
        Schema(),
    )
    var wb = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_cheap_witness_binding(UInt64(0x2222))),
        Schema(),
    )
    assert_not_equal(
        wa.structural_hash(),
        wb.structural_hash(),
        "the witness pair must be separable WITHOUT the placeholder, or R10b"
        " cannot tell a lost placeholder from a working one",
    )
    assert_not_equal(
        wa.structural_hash(),
        wa.structural_hash_modulo_inmem_id(),
        "and the two renders of ONE binding must DIFFER — if they agreed,"
        " `bsid=` is absent from the render entirely and R5, not R10, is the"
        " rule that should be red",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_registered_scan_kind_covers_its_own_fingerprint]()
    suite.test[test_the_audit_is_driven_by_the_registry_not_by_a_list_here]()
    suite.test[test_a_corpus_that_asserts_nothing_is_red_not_green]()
    suite.test[test_the_audit_catches_a_planted_coverage_hole]()
    suite.test[test_two_mtimes_of_one_arrow_file_do_not_share_a_plan_cache_key]()
    suite.test[test_arrow_declares_the_mtime_as_a_pinned_snapshot_token]()
    suite.test[test_the_arrow_fingerprint_value_did_not_move_with_the_fix]()
    suite.test[test_golden_identity_hash_arrow]()
    suite.test[test_golden_identity_hash_broker]()
    suite.test[test_golden_rendered_plan_text_arrow]()
    suite.test[test_golden_rendered_plan_text_broker]()
    suite.test[test_every_distinguishable_pair_reaches_the_plan_compile_cache_key]()
    suite.test[test_the_live_snapshot_contract_survives_the_render]()
    suite.test[test_a_migrated_arm_cannot_be_left_unaudited]()
    suite.test[test_the_arrow_corpus_varies_every_input_the_fingerprint_folds]()
    suite.test[test_the_orc_corpus_varies_every_input_the_fingerprint_folds]()
    suite.test[test_the_migrated_orc_kind_is_present_and_non_vacuous]()
    suite.test[test_the_avro_corpus_varies_every_input_the_fingerprint_folds]()
    suite.test[test_the_migrated_avro_kind_is_present_and_non_vacuous]()
    suite.test[test_the_csv_corpus_varies_every_input_the_fingerprint_folds]()
    suite.test[test_the_migrated_csv_kind_is_present_and_non_vacuous]()
    suite.test[test_the_inmem_kind_is_present_and_non_vacuous]()
    suite.test[test_the_inmem_corpus_states_both_halves_of_its_identity]()
    suite.test[test_the_registry_has_at_last_seen_two_different_orientations]()
    suite.test[test_a_difference_only_the_derived_identity_carries_reaches_the_plan_hash]()
    suite.test[test_every_corpus_entrys_identity_appears_in_its_rendered_plan_text]()
    suite.test[test_the_audit_catches_an_identity_that_never_reaches_the_plan_text]()
    suite.test[test_the_audit_catches_two_distinct_plans_that_render_identically]()
    suite.test[test_the_coverage_message_measures_the_plan_text_it_used_to_assert]()
    suite.test[test_the_render_list_cannot_silently_describe_other_corpora]()
    suite.test[test_every_corpus_entrys_supplied_structural_id_appears_in_its_rendered_plan_text]()
    suite.test[test_the_audit_catches_a_supplied_identity_that_never_reaches_the_plan_text]()
    suite.test[test_a_pair_rule_that_only_observed_a_difference_would_not_have_caught_this]()
    suite.test[test_a_difference_only_the_kind_supplied_identity_carries_reaches_the_plan_hash]()
    suite.test[test_an_empty_registry_is_red_not_a_vacuous_pass]()
    suite.test[test_a_per_construction_identity_is_red_not_green]()
    suite.test[
        test_r1_cannot_see_a_corpus_that_varies_nothing_when_identity_is_a_counter
    ]()
    suite.test[
        test_the_in_memory_plan_hash_is_content_derived_not_per_construction
    ]()
    suite.test[test_a_projection_only_difference_reaches_the_plan_compile_cache_key]()
    suite.test[test_a_projection_order_only_difference_reaches_the_plan_compile_cache_key]()
    suite.test[test_a_filter_only_difference_reaches_the_plan_compile_cache_key]()
    suite.test[test_every_registered_kinds_scan_node_fields_reach_its_plan_text]()
    suite.test[test_the_node_audit_catches_a_projection_that_never_reaches_the_plan_text]()
    suite.test[test_the_node_audit_catches_a_filter_that_never_reaches_the_plan_text]()
    suite.test[test_the_node_audit_catches_two_distinct_scan_nodes_that_render_identically]()
    suite.test[test_a_node_corpus_that_exercises_only_one_axis_is_red_not_green]()
    suite.test[test_a_witness_the_binding_already_supplies_is_red_not_green]()
    suite.test[test_the_node_axis_runs_from_the_same_entry_point_as_the_binding_axis]()
    suite.test[test_the_cheap_key_still_separates_every_pair_core_can_tell_apart]()
    suite.test[
        test_the_cheap_key_is_blind_to_a_kind_supplied_content_identity
    ]()
    suite.test[test_the_cheap_key_rules_run_from_the_same_entry_point]()
    suite.test[test_r10b_could_tell_a_lost_placeholder_from_a_working_one]()
    suite^.run()

