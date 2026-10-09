# =============================================================================
# Tests for `scan_identity_audit.mojo`: the identity-coverage audit (rules
# R0, R1, R2, R4, R5) and the reproducibility audit (R9).
#
# Both audits take the rendered plan text as an argument, so these tests
# supply it by hand. That puts every rule's input under the test's control:
# a text that carries an identity, one that omits it, one that carries a
# second entry's identity. Each test drives exactly one rule and asserts the
# message it raises, with the label, kind, count or value that the rule
# must quote. The pass cases are built to reach every "continue" arm, so a
# rule that raised on a legal corpus would fail them.
#
# Values the tests compare against are computed outside the audit: the kind
# id is the FNV-1a 32 test vector for "a", the hashes come from
# `ScanBinding.identity_hash()` (in `scan_binding.mojo`, not under test), and
# every substring precondition a text relies on is asserted before use.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    SCAN_ORIENTATION_ROW,
    ScanBinding,
    scan_kind_id,
)
from komira_scan_source.scan_identity_audit import (
    ScanIdentityCorpus,
    audit_scan_identity_coverage,
    audit_scan_identity_reproducibility,
)
from komira_scan_source.scan_kind_registry import (
    ScanKindDescriptor,
    ScanKindRegistry,
)
from komira_scan_source.scan_params import ScanParams


comptime ALPHA = "k.alpha"
comptime BETA = "k.beta"
comptime GAMMA = "k.gamma"

# Structural ids with digit runs that no 64-bit hash in these tests holds as
# a substring (each use that depends on it is asserted).
comptime SID_A: UInt64 = 7300000000000000011
comptime SID_B: UInt64 = 7300000000000000022
comptime SID_C: UInt64 = 7300000000000000033
comptime SID_D: UInt64 = 7300000000000000044
comptime SID_E: UInt64 = 7300000000000000055


# =============================================================================
# Helpers
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, nullable=False))
    return sb.build()


def _bk(
    kind_id: UInt32,
    kind_name: String,
    name: String,
    fp: UInt64,
    sid: UInt64,
    var params: ScanParams = ScanParams(),
) -> ScanBinding:
    return ScanBinding(
        kind_id=kind_id,
        kind_name=String(kind_name),
        name=String(name),
        params=params^,
        schema=_schema(),
        fingerprint=fp,
        structural_id=sid,
        gate=PushdownGate.reject_all(),
    )


def _b(
    kind: String,
    name: String,
    fp: UInt64,
    sid: UInt64,
    var params: ScanParams = ScanParams(),
) -> ScanBinding:
    return _bk(scan_kind_id(kind), kind, name, fp, sid, params^)


def _desc(kind: String) -> ScanKindDescriptor:
    return ScanKindDescriptor(String(kind), PushdownGate.reject_all())


def _registry(kinds: List[String]) raises -> ScanKindRegistry:
    var reg = ScanKindRegistry()
    for i in range(len(kinds)):
        reg.register(_desc(kinds[i]))
    return reg^


def _text(b: ScanBinding) -> String:
    """A plan text that carries both identities, as `plan_display` does."""
    return (
        String("Scan[bid=")
        + String(b.identity_hash())
        + String(", bsid=")
        + String(b.structural_id)
        + String("]")
    )


def _texts(c: ScanIdentityCorpus) -> List[String]:
    var out = List[String]()
    for i in range(c.num_entries()):
        out.append(_text(c.bindings[i]))
    return out^


def _rendered(corpora: List[ScanIdentityCorpus]) -> List[List[String]]:
    var out = List[List[String]]()
    for i in range(len(corpora)):
        out.append(_texts(corpora[i]))
    return out^


def _one(var c: ScanIdentityCorpus) -> List[ScanIdentityCorpus]:
    var out = List[ScanIdentityCorpus]()
    out.append(c^)
    return out^


def _cov_err(
    registry: ScanKindRegistry,
    corpora: List[ScanIdentityCorpus],
    rendered: List[List[String]],
) -> String:
    try:
        audit_scan_identity_coverage(registry, corpora, rendered)
    except e:
        return String(e)
    return String("no error")


def _rep_err(
    corpora: List[ScanIdentityCorpus], rebuilt: List[ScanIdentityCorpus]
) -> String:
    try:
        audit_scan_identity_reproducibility(corpora, rebuilt)
    except e:
        return String(e)
    return String("no error")


def _alpha_corpus() -> ScanIdentityCorpus:
    """A legal corpus that reaches every skip arm of R1, R2, R4 and R5:

    - base/dupfp share a fingerprint (R1 counts it once; R2's premise fails)
      and a structural id (R5b skips the pair), with different names, so
      their identities and texts differ;
    - base/bytes have the same identity_hash (same name, same params) and the
      same fingerprint, but different structural ids carried only in their
      own texts (R4b's first operand is false; R5b finds no carrier);
    - name differs from base in fingerprint and in identity_hash (R2 skips
      on the second test).
    """
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("base"), _b(ALPHA, String("t0"), 10, SID_A))
    c.add(String("dupfp"), _b(ALPHA, String("t1"), 10, SID_A))
    c.add(String("bytes"), _b(ALPHA, String("t0"), 10, SID_B))
    c.add(String("name"), _b(ALPHA, String("t2"), 11, SID_C))
    return c^


def _beta_corpus() -> ScanIdentityCorpus:
    var c = ScanIdentityCorpus(_desc(BETA))
    c.add(String("base"), _b(BETA, String("u0"), 20, SID_D))
    c.add(String("name"), _b(BETA, String("u1"), 21, SID_E))
    return c^


def _good_pair() -> List[ScanIdentityCorpus]:
    """Beta first, so looking up alpha's corpus passes over a non-match."""
    var out = List[ScanIdentityCorpus]()
    out.append(_beta_corpus())
    out.append(_alpha_corpus())
    return out^


# =============================================================================
# 1. ScanIdentityCorpus
# =============================================================================


def test_corpus_add_and_count() raises:
    var c = ScanIdentityCorpus(_desc(ALPHA))
    assert_equal(c.num_entries(), 0)
    c.add(String("mtime"), _b(ALPHA, String("t"), 1, SID_A))
    c.add(String("codec"), _b(ALPHA, String("t"), 2, SID_B))
    assert_equal(c.num_entries(), 2)
    assert_equal(c.labels[0], "mtime")
    assert_equal(c.labels[1], "codec")
    assert_equal(c.bindings[1].fingerprint, UInt64(2))
    assert_equal(c.descriptor.kind_id, scan_kind_id(ALPHA))


def test_corpus_copy_is_deep() raises:
    """The copy carries every field, and growing it leaves the original."""
    var c = _alpha_corpus()
    var d = c.copy()
    assert_equal(d.descriptor.kind_name, ALPHA)
    assert_equal(d.descriptor.kind_id, c.descriptor.kind_id)
    assert_equal(d.num_entries(), 4)
    for i in range(4):
        assert_equal(d.labels[i], c.labels[i])
        assert_equal(d.bindings[i].fingerprint, c.bindings[i].fingerprint)
        assert_equal(d.bindings[i].structural_id, c.bindings[i].structural_id)
        assert_equal(d.bindings[i].identity_hash(), c.bindings[i].identity_hash())
    d.add(String("extra"), _b(ALPHA, String("t9"), 99, SID_E))
    d.labels[0] = String("renamed")
    assert_equal(c.num_entries(), 4)
    assert_equal(c.labels[0], "base")
    assert_equal(d.num_entries(), 5)


# =============================================================================
# 2. Coverage audit: a legal corpus passes
# =============================================================================


def test_coverage_passes_a_legal_registry_and_corpora() raises:
    var corpora = _good_pair()
    # The preconditions the skip arms rely on, checked rather than assumed.
    ref a = corpora[1]
    assert_equal(a.bindings[0].fingerprint, a.bindings[1].fingerprint)
    assert_not_equal(a.bindings[0].identity_hash(), a.bindings[1].identity_hash())
    assert_equal(a.bindings[0].identity_hash(), a.bindings[2].identity_hash())
    assert_not_equal(a.bindings[0].structural_id, a.bindings[2].structural_id)
    var rendered = _rendered(corpora)
    for ci in range(len(corpora)):
        for i in range(corpora[ci].num_entries()):
            for j in range(corpora[ci].num_entries()):
                var sid_j = String(corpora[ci].bindings[j].structural_id)
                if (
                    corpora[ci].bindings[i].structural_id
                    != corpora[ci].bindings[j].structural_id
                ):
                    assert_false(sid_j in rendered[ci][i])
    var reg = _registry([String(ALPHA), String(BETA)])
    assert_equal(_cov_err(reg, corpora, rendered), "no error")


# =============================================================================
# 3. Coverage audit: R4 shape, R0 completeness, R1 non-vacuity
# =============================================================================


def test_coverage_r4_refuses_fewer_rendered_lists_than_corpora() raises:
    var corpora = _good_pair()
    var rendered = List[List[String]]()
    rendered.append(_texts(corpora[0]))
    var err = _cov_err(_registry([String(ALPHA), String(BETA)]), corpora, rendered)
    assert_true(
        "AUDIT R4 (REACH): the rendered-text list has 1 corpus entr(y/ies) but"
        " 2 corpora were supplied."
        in err,
        err,
    )


def test_coverage_r4_refuses_a_short_rendered_list_for_one_kind() raises:
    """The second corpus is the short one: every corpus is checked."""
    var corpora = _good_pair()
    var rendered = _rendered(corpora)
    _ = rendered[1].pop()
    var err = _cov_err(_registry([String(ALPHA), String(BETA)]), corpora, rendered)
    assert_true(
        "AUDIT R4 (REACH): kind 'k.alpha' has 4 corpus entries but 3 rendered"
        " plan texts."
        in err,
        err,
    )


def test_coverage_r4_refuses_more_rendered_lists_than_corpora() raises:
    """An extra list is refused too: the shape check is `!=`, not `<`."""
    var corpora = _good_pair()
    var rendered = _rendered(corpora)
    rendered.append(_texts(corpora[0]))
    var err = _cov_err(_registry([String(ALPHA), String(BETA)]), corpora, rendered)
    assert_equal(
        err,
        String(
            "ScanIdentity AUDIT R4 (REACH): the rendered-text list has 3"
            " corpus entr(y/ies) but 2 corpora were supplied. Build it with"
            " `render_corpora_plan_text(corpora)` from"
            " `komira_plan_ir.scan_identity_render_audit`, or call"
            " `audit_scan_identity(registry, corpora)` there, which does it"
            " for you."
        ),
    )


def test_coverage_r4_refuses_a_long_rendered_list_for_one_kind() raises:
    """The first corpus has an extra text: `!=`, not `<`, and from index 0."""
    var corpora = _good_pair()
    var rendered = _rendered(corpora)
    var extra = rendered[0][0]
    rendered[0].append(extra^)
    var err = _cov_err(_registry([String(ALPHA), String(BETA)]), corpora, rendered)
    assert_equal(
        err,
        String(
            "ScanIdentity AUDIT R4 (REACH): kind 'k.beta' has 2 corpus"
            " entries but 3 rendered plan texts. Every entry must be rendered"
            " or R4 checks a subset while reporting a whole."
        ),
    )


def test_coverage_r0_refuses_an_empty_registry() raises:
    var corpora = List[ScanIdentityCorpus]()
    var err = _cov_err(ScanKindRegistry(), corpora, List[List[String]]())
    assert_true("AUDIT R0 (COMPLETENESS): the registry is EMPTY" in err, err)
    # The same holds with corpora present: emptiness is checked first.
    var c2 = _good_pair()
    err = _cov_err(ScanKindRegistry(), c2, _rendered(c2))
    assert_true("the registry is EMPTY" in err, err)


def test_coverage_r0_refuses_an_unregistered_corpus_kind() raises:
    var corpora = _good_pair()
    var g = ScanIdentityCorpus(_desc(GAMMA))
    g.add(String("x"), _b(GAMMA, String("g0"), 1, SID_A))
    g.add(String("y"), _b(GAMMA, String("g1"), 2, SID_B))
    corpora.append(g^)
    var err = _cov_err(
        _registry([String(ALPHA), String(BETA)]), corpora, _rendered(corpora)
    )
    assert_true(
        "AUDIT R0 (COMPLETENESS): kind 'k.gamma' supplies an identity corpus"
        " but is NOT REGISTERED."
        in err,
        err,
    )


def test_coverage_r0_refuses_a_registered_kind_without_corpus() raises:
    """Kind "a" is registered last; its id is the FNV-1a 32 test vector."""
    var corpora = _good_pair()
    var err = _cov_err(
        _registry([String(ALPHA), String(BETA), String("a")]),
        corpora,
        _rendered(corpora),
    )
    assert_true(
        "AUDIT R0 (COMPLETENESS): kind 'a' (id 3826002220) is REGISTERED but"
        " supplies NO identity corpus"
        in err,
        err,
    )


def test_coverage_r1_refuses_a_corpus_of_one_entry() raises:
    """Beta (first) is legal; alpha has one entry."""
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(_beta_corpus())
    var a = ScanIdentityCorpus(_desc(ALPHA))
    a.add(String("only"), _b(ALPHA, String("t0"), 1, SID_A))
    corpora.append(a^)
    var err = _cov_err(
        _registry([String(ALPHA), String(BETA)]), corpora, _rendered(corpora)
    )
    assert_true(
        "AUDIT R1 (NON-VACUITY): kind 'k.alpha' supplies a corpus of 1"
        " entr(y/ies)."
        in err,
        err,
    )


def test_coverage_r1_refuses_an_empty_corpus() raises:
    var corpora = _one(ScanIdentityCorpus(_desc(ALPHA)))
    var err = _cov_err(_registry([String(ALPHA)]), corpora, _rendered(corpora))
    assert_true("kind 'k.alpha' supplies a corpus of 0 entr(y/ies)." in err, err)


def test_coverage_r1_refuses_a_single_distinct_fingerprint() raises:
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("a"), _b(ALPHA, String("t0"), 5, SID_A))
    c.add(String("b"), _b(ALPHA, String("t1"), 5, SID_B))
    c.add(String("c"), _b(ALPHA, String("t2"), 5, SID_C))
    var corpora = _one(c^)
    var err = _cov_err(_registry([String(ALPHA)]), corpora, _rendered(corpora))
    assert_true(
        "AUDIT R1 (NON-VACUITY): kind 'k.alpha' supplies 3 entries but only 1"
        " DISTINCT fingerprint(s)"
        in err,
        err,
    )


def test_coverage_r1_counts_two_distinct_among_repeats() raises:
    """Fingerprints 5, 5, 6: two distinct, so R1 passes and nothing raises."""
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("a"), _b(ALPHA, String("t0"), 5, SID_A))
    c.add(String("b"), _b(ALPHA, String("t1"), 5, SID_B))
    c.add(String("c"), _b(ALPHA, String("t2"), 6, SID_C))
    var corpora = _one(c^)
    assert_equal(
        _cov_err(_registry([String(ALPHA)]), corpora, _rendered(corpora)),
        "no error",
    )


def test_coverage_validates_every_entry_against_its_descriptor() raises:
    """Entry 0 carries the required param, entry 1 does not: the registry's
    bind-time check runs on each entry, not only the first."""
    var reg = ScanKindRegistry()
    var req = List[String]()
    req.append(String("path"))
    reg.register(
        ScanKindDescriptor(
            String(ALPHA), PushdownGate.reject_all(), required_params=req^
        )
    )
    var p = ScanParams()
    p.put_str(String("path"), String("/d/a"))
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("with"), _b(ALPHA, String("t0"), 1, SID_A, p^))
    c.add(String("without"), _b(ALPHA, String("t0"), 2, SID_B))
    var corpora = _one(c^)
    var err = _cov_err(reg, corpora, _rendered(corpora))
    assert_equal(
        err,
        "ScanBinding validate: kind 'k.alpha' requires param(s) not present:"
        " path",
    )


def test_coverage_validate_checks_orientation() raises:
    var reg = ScanKindRegistry()
    reg.register(
        ScanKindDescriptor(
            String(ALPHA),
            PushdownGate.reject_all(),
            orientation=SCAN_ORIENTATION_ROW,
        )
    )
    var c = _alpha_corpus()
    var corpora = _one(c^)
    var err = _cov_err(reg, corpora, _rendered(corpora))
    assert_equal(
        err,
        "ScanBinding validate: kind 'k.alpha' declares orientation 1 but the"
        " binding carries 0",
    )


# =============================================================================
# 4. Coverage audit: R4a/R4b reach, R2 coverage
# =============================================================================


def test_coverage_r4a_refuses_a_text_without_the_identity() raises:
    """Entry 1's text drops `bid=`; entry 0's is intact."""
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("base"), _b(ALPHA, String("t0"), 1, SID_A))
    c.add(String("mtime"), _b(ALPHA, String("t1"), 2, SID_B))
    var corpora = _one(c^)
    var rendered = _rendered(corpora)
    rendered[0][1] = String("Scan[bsid=") + String(SID_B) + String("]")
    var id1 = String(corpora[0].bindings[1].identity_hash())
    var err = _cov_err(_registry([String(ALPHA)]), corpora, rendered)
    assert_true(
        String("AUDIT R4a (REACH) FAILED for kind 'k.alpha':\n  entry 'mtime'")
        + String(" has identity_hash ")
        + id1
        + String(", and that value does NOT APPEAR")
        in err,
        err,
    )
    assert_true(String("\n  rendered: Scan[bsid=") + String(SID_B) in err, err)


def test_coverage_r4b_refuses_different_identities_with_one_text() raises:
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("base"), _b(ALPHA, String("t0"), 1, SID_A))
    c.add(String("name"), _b(ALPHA, String("t1"), 2, SID_A))
    var corpora = _one(c^)
    var id0 = corpora[0].bindings[0].identity_hash()
    var id1 = corpora[0].bindings[1].identity_hash()
    assert_not_equal(id0, id1)
    var both = (
        String("Scan[bid=")
        + String(id0)
        + String(" bid=")
        + String(id1)
        + String(" bsid=")
        + String(SID_A)
        + String("]")
    )
    var rendered = List[List[String]]()
    rendered.append([both, both])
    var err = _cov_err(_registry([String(ALPHA)]), corpora, rendered)
    assert_true(
        String("AUDIT R4b (REACH) FAILED for kind 'k.alpha':\n  entries 'base'")
        + String(" and 'name' have DIFFERENT identity_hash (")
        + String(id0)
        + String(" vs ")
        + String(id1)
        + String(") and render IDENTICAL plan text")
        in err,
        err,
    )


def _r2_corpus() -> List[ScanIdentityCorpus]:
    """Two entries the kind's fingerprint separates (1 vs 2) and core's
    identity does not: same name, same params, same schema."""
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("base"), _b(ALPHA, String("t0"), 1, SID_A))
    c.add(String("mtime"), _b(ALPHA, String("t0"), 2, SID_B))
    return _one(c^)


def test_coverage_r2_refuses_a_live_collision() raises:
    """Identical texts: the collision is live, and the message says so."""
    var corpora = _r2_corpus()
    var id0 = corpora[0].bindings[0].identity_hash()
    assert_equal(id0, corpora[0].bindings[1].identity_hash())
    var same = String("Scan[bid=") + String(id0) + String("]")
    var rendered = List[List[String]]()
    rendered.append([same, same])
    var err = _cov_err(_registry([String(ALPHA)]), corpora, rendered)
    assert_true(
        String("AUDIT R2 (COVERAGE) FAILED for kind 'k.alpha':\n  MEASURED:")
        + String(" entries 'base' and 'mtime' have DIFFERENT fingerprints (1 vs")
        + String(" 2) and the SAME derived identity_hash (")
        + String(id0)
        + String(").")
        in err,
        err,
    )
    assert_true("their rendered plan text is IDENTICAL" in err, err)
    assert_false("MASKED" in err, err)
    assert_true(
        String("\n  binding: k.alpha(t0)  |  k.alpha(t0)\n  rendered: ")
        + same
        + String("\n            ")
        + same
        in err,
        err,
    )


def test_coverage_r2_refuses_a_masked_collision() raises:
    """Texts differ only by `bsid=`: still red, with the masked wording."""
    var corpora = _r2_corpus()
    var err = _cov_err(_registry([String(ALPHA)]), corpora, _rendered(corpora))
    assert_true("AUDIT R2 (COVERAGE) FAILED for kind 'k.alpha'" in err, err)
    assert_true("their rendered plan text DIFFERS" in err, err)
    assert_true("MASKED, not absent" in err, err)
    assert_false("is IDENTICAL" in err, err)


# =============================================================================
# 5. Coverage audit: R5 supplied reach and attribution
# =============================================================================


def test_coverage_r5a_refuses_a_text_without_the_structural_id() raises:
    var corpora = _good_pair()
    var rendered = _rendered(corpora)
    var b = corpora[1].bindings[3].copy()
    rendered[1][3] = String("Scan[bid=") + String(b.identity_hash()) + String("]")
    assert_false(String(SID_C) in rendered[1][3])
    var err = _cov_err(_registry([String(ALPHA), String(BETA)]), corpora, rendered)
    assert_true(
        String("AUDIT R5a (SUPPLIED REACH) FAILED for kind 'k.alpha':\n  entry")
        + String(" 'name' has structural_id ")
        + String(SID_C)
        + String(", and that value does NOT APPEAR")
        in err,
        err,
    )


def _r5b_corpus() -> List[ScanIdentityCorpus]:
    var c = ScanIdentityCorpus(_desc(ALPHA))
    c.add(String("base"), _b(ALPHA, String("t0"), 1, SID_A))
    c.add(String("other"), _b(ALPHA, String("t1"), 2, SID_B))
    return _one(c^)


def test_coverage_r5b_names_the_first_entry_carrying_both() raises:
    var corpora = _r5b_corpus()
    var rendered = _rendered(corpora)
    rendered[0][0] += String(" also ") + String(SID_B)
    var err = _cov_err(_registry([String(ALPHA)]), corpora, rendered)
    assert_true(
        String("AUDIT R5b (ATTRIBUTION) FAILED for kind 'k.alpha':\n  entries")
        + String(" 'base' and 'other' have DIFFERENT structural_id (")
        + String(SID_A)
        + String(" vs ")
        + String(SID_B)
        + String("), and the text of entry 'base' carries BOTH")
        in err,
        err,
    )


def test_coverage_r5b_names_the_second_entry_carrying_both() raises:
    var corpora = _r5b_corpus()
    var rendered = _rendered(corpora)
    assert_false(String(SID_B) in rendered[0][0])
    rendered[0][1] += String(" also ") + String(SID_A)
    var err = _cov_err(_registry([String(ALPHA)]), corpora, rendered)
    assert_true("the text of entry 'other' carries BOTH" in err, err)
    assert_true(
        String("\n  rendered: ") + rendered[0][0] + String("\n            ")
        + rendered[0][1]
        in err,
        err,
    )


# =============================================================================
# 6. Reproducibility audit (R9)
# =============================================================================


def test_reproducibility_passes_two_independent_builds() raises:
    assert_equal(_rep_err(_good_pair(), _good_pair()), "no error")


def test_reproducibility_refuses_a_different_corpus_count() raises:
    var rebuilt = List[ScanIdentityCorpus]()
    rebuilt.append(_beta_corpus())
    var err = _rep_err(_good_pair(), rebuilt)
    assert_true(
        "AUDIT R9 (REPRODUCIBILITY): the second build has 1 corpus"
        " entr(y/ies) but the first has 2."
        in err,
        err,
    )


def test_reproducibility_refuses_a_different_kind_at_one_index() raises:
    var rebuilt = List[ScanIdentityCorpus]()
    rebuilt.append(_beta_corpus())
    rebuilt.append(_beta_corpus())
    var err = _rep_err(_good_pair(), rebuilt)
    assert_true(
        "AUDIT R9 (REPRODUCIBILITY): corpus 1 is kind 'k.alpha' in the first"
        " build and 'k.beta' in the second."
        in err,
        err,
    )


def test_reproducibility_refuses_a_different_entry_count() raises:
    var rebuilt = _good_pair()
    rebuilt[1].add(String("extra"), _b(ALPHA, String("t9"), 9, SID_E))
    var err = _rep_err(_good_pair(), rebuilt)
    assert_true(
        "AUDIT R9 (REPRODUCIBILITY): kind 'k.alpha' produced 4 entries in one"
        " build and 5 in the next."
        in err,
        err,
    )


def _rebuilt_with(var b: ScanBinding) -> List[ScanIdentityCorpus]:
    """`_good_pair()` with alpha's entry 1 ('dupfp') replaced by `b`."""
    var out = _good_pair()
    out[1].bindings[1] = b^
    return out^


def test_reproducibility_reports_fingerprint_first() raises:
    """Fingerprint and structural id both differ: fingerprint is named."""
    var err = _rep_err(
        _good_pair(), _rebuilt_with(_b(ALPHA, String("t1"), 77, SID_E))
    )
    assert_true(
        "AUDIT R9 (REPRODUCIBILITY) FAILED for kind 'k.alpha':\n  entry 'dupfp'"
        " has fingerprint = 10 when built once and 77 when built again"
        in err,
        err,
    )


def test_reproducibility_reports_structural_id_before_identity() raises:
    """Structural id and name both differ: structural_id is named."""
    var err = _rep_err(
        _good_pair(), _rebuilt_with(_b(ALPHA, String("t7"), 10, SID_E))
    )
    assert_true(
        String("entry 'dupfp' has structural_id = ")
        + String(SID_A)
        + String(" when built once and ")
        + String(SID_E)
        + String(" when built again")
        in err,
        err,
    )


def test_reproducibility_reports_identity_hash() raises:
    var a = _b(ALPHA, String("t1"), 10, SID_A)
    var b = _b(ALPHA, String("t7"), 10, SID_A)
    assert_not_equal(a.identity_hash(), b.identity_hash())
    var err = _rep_err(_good_pair(), _rebuilt_with(b.copy()))
    assert_true(
        String("entry 'dupfp' has identity_hash() = ")
        + String(a.identity_hash())
        + String(" when built once and ")
        + String(b.identity_hash())
        + String(" when built again")
        in err,
        err,
    )


def test_reproducibility_reports_render_alone() raises:
    """Same kind_id, kind_name/name split differently: FNV over "k.alpha"
    then "x" equals FNV over "k.alph" then "ax", so identity_hash agrees and
    only the render tells the two builds apart."""
    var a = _bk(scan_kind_id(ALPHA), String(ALPHA), String("x"), 10, SID_A)
    var b = _bk(scan_kind_id(ALPHA), String("k.alph"), String("ax"), 10, SID_A)
    assert_equal(a.identity_hash(), b.identity_hash())
    var first = _good_pair()
    first[1].bindings[1] = a^
    var err = _rep_err(first, _rebuilt_with(b^))
    assert_true(
        "entry 'dupfp' has render() = k.alpha(x) when built once and"
        " k.alph(ax) when built again"
        in err,
        err,
    )


def main() raises:
    var suite = TestSuite()
    # ScanIdentityCorpus
    suite.test[test_corpus_add_and_count]()
    suite.test[test_corpus_copy_is_deep]()
    # Coverage audit: pass
    suite.test[test_coverage_passes_a_legal_registry_and_corpora]()
    # R4 shape, R0, R1, validate
    suite.test[test_coverage_r4_refuses_fewer_rendered_lists_than_corpora]()
    suite.test[test_coverage_r4_refuses_a_short_rendered_list_for_one_kind]()
    suite.test[test_coverage_r4_refuses_more_rendered_lists_than_corpora]()
    suite.test[test_coverage_r4_refuses_a_long_rendered_list_for_one_kind]()
    suite.test[test_coverage_r0_refuses_an_empty_registry]()
    suite.test[test_coverage_r0_refuses_an_unregistered_corpus_kind]()
    suite.test[test_coverage_r0_refuses_a_registered_kind_without_corpus]()
    suite.test[test_coverage_r1_refuses_a_corpus_of_one_entry]()
    suite.test[test_coverage_r1_refuses_an_empty_corpus]()
    suite.test[test_coverage_r1_refuses_a_single_distinct_fingerprint]()
    suite.test[test_coverage_r1_counts_two_distinct_among_repeats]()
    suite.test[test_coverage_validates_every_entry_against_its_descriptor]()
    suite.test[test_coverage_validate_checks_orientation]()
    # R4a, R4b, R2
    suite.test[test_coverage_r4a_refuses_a_text_without_the_identity]()
    suite.test[test_coverage_r4b_refuses_different_identities_with_one_text]()
    suite.test[test_coverage_r2_refuses_a_live_collision]()
    suite.test[test_coverage_r2_refuses_a_masked_collision]()
    # R5
    suite.test[test_coverage_r5a_refuses_a_text_without_the_structural_id]()
    suite.test[test_coverage_r5b_names_the_first_entry_carrying_both]()
    suite.test[test_coverage_r5b_names_the_second_entry_carrying_both]()
    # R9
    suite.test[test_reproducibility_passes_two_independent_builds]()
    suite.test[test_reproducibility_refuses_a_different_corpus_count]()
    suite.test[test_reproducibility_refuses_a_different_kind_at_one_index]()
    suite.test[test_reproducibility_refuses_a_different_entry_count]()
    suite.test[test_reproducibility_reports_fingerprint_first]()
    suite.test[test_reproducibility_reports_structural_id_before_identity]()
    suite.test[test_reproducibility_reports_identity_hash]()
    suite.test[test_reproducibility_reports_render_alone]()
    suite^.run()
