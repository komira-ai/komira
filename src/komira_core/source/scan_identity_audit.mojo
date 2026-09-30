# =============================================================================
# THE IDENTITY-COVERAGE AUDIT — one mechanical rule for a defect class.
# =============================================================================
#
# ---------------------------------------------------------------------------
# THE DEFECT CLASS THIS EXISTS TO STOP
# ---------------------------------------------------------------------------
#
# A scan kind's OWN `fingerprint()` folds some input, and that input never
# reaches core's DERIVED `identity_hash()` — so it never reaches the plan TEXT
# that `LogicalPlan.structural_hash()` folds, so two distinct scans share a
# plan-compile cache key (`factory_hash = plan.structural_hash()` in
# `EngineContext`) and one query's compiled plan is returned for another. A
# SILENT WRONG ANSWER — nothing raises, nothing goes red.
#
# Instances of the class look like:
#
#   * binding params that never reach the plan text;
#   * a kind-SUPPLIED `structural_id` that omits an input (e.g. a broker
#     binding folding (topic, partition) but not `start_offset`) — the derived
#     fold must cover what the kind forgot;
#   * an input such as projection ORDER or `_mtime_ns` left out of the binding;
#   * a binding declaring `SNAPSHOT_NONE` while the source's `fingerprint()`
#     folds `_mtime_ns`, so two scans of ONE path at DIFFERENT mtimes share an
#     `identity_hash`.
#
# Found one at a time by hand, the class keeps recurring. THIS FILE IS THE
# GATE.
#
# ---------------------------------------------------------------------------
# THE RULE, STATED ONCE
# ---------------------------------------------------------------------------
#
#     For two bindings of the SAME kind:
#         fingerprint(a) != fingerprint(b)  =>  identity_hash(a) != identity_hash(b)
#
# In words: core's DERIVED identity must be at least as discriminating as the
# kind's OWN. The kind is the authority on what makes two of its scans
# different; core is the thing that has to carry that difference into the cache
# key. When core is coarser than the kind, the gap is exactly the silent
# collision.
#
# ⚠ THE CONVERSE IS DELIBERATELY NOT CHECKED. `identity_hash` being FINER than
# `fingerprint` (e.g. arrow's `estimated_rows` param, which the fingerprint does
# not fold) costs at worst a cache MISS. A miss is loud in a profile and cheap
# in correctness; a collision is silent and wrong. One direction, sharp.
#
# ---------------------------------------------------------------------------
# THE SECOND RULE — R4 (REACH)
# ---------------------------------------------------------------------------
#
# The rule above compares two `identity_hash` values. It never asks whether
# that value gets ANYWHERE — and `identity_hash` matters for exactly one
# reason: `LogicalPlan.structural_hash()` is FNV-1a over the plan TEXT
# (`logical_plan.mojo`) and `EngineContext` uses it as `factory_hash`.
#
# ONE line carries it there:
#
#     writer.write(", bid=", b.identity_hash())      # plan_display.mojo
#
# Deleting that line would leave every value rule GREEN; only FORMAT goldens
# would go red — and a format golden goes red on any innocuous render change,
# so the fix of least resistance is to update its literal, at which point the
# identity is gone from the key with nothing left to notice.
#
# So the second rule is stated once, as a CLASS rule off the same corpora:
#
#     for every entry:  identity_hash(b)  appears in  render(plan over b)
#     for every pair:   identity_hash(a) != identity_hash(b)  =>
#                       plan text (a) != plan text (b)
#
# Containment, not a field name: it pins that identity is IN the text and
# survives renaming `bid=` or reordering fields, so it is a rule rather than a
# third golden. The rendering itself cannot happen in this file (the plan layer
# imports `source_variant`, which imports this module), so it is supplied by
# `komira_core/plan/scan_identity_render_audit.mojo` — which is also the
# entry point production and the gate test should call.
#
# ---------------------------------------------------------------------------
# THE THIRD RULE — R5, THE OTHER TWIN
# ---------------------------------------------------------------------------
#
# `plan_display.mojo` writes TWO identities for a binding-backed scan, and R4
# protects only the second:
#
#     writer.write(", bsid=", b.structural_id)      # the KIND-SUPPLIED one
#     writer.write(", bid=", b.identity_hash())     # the CORE-DERIVED one
#
# R0-R4 never read `structural_id`: R4 asks where `identity_hash` goes and
# nothing else asks where `structural_id` goes. Same class, one field to the
# left.
#
# ⚠ AND `bsid=` IS NOT REDUNDANT WITH `bid=`. The derived fold covers
# kind_id + kind_name + name + params + schema + gate + orientation
# (+ snapshot_token iff PINNED) — every input core can SEE. `structural_id` is
# the kind's statement about what core CANNOT see, and IN_MEMORY is the case
# that needs it: two `from_record_batch` sources with the same synthetic name
# and the same schema differ ONLY in their bytes, and only `InMemorySource` can
# hash those. For that pair `bsid=` is the ONLY field in the entire render that
# can separate two different tables — deleting it merges them in the
# plan-compile cache and in `plan_cse`, which over-produces rows through a
# spurious self-join.
#
#     for every entry:  structural_id(b)  appears in  render(plan over b)
#     for every pair:   structural_id(a) != structural_id(b)  =>
#                       the DIFFERENCE IS ATTRIBUTABLE TO THE structural_id
#
# ⚠ THE SECOND CLAUSE IS NOT "THE TEXTS DIFFER", AND THAT IS THE WHOLE POINT.
# On every file-kind corpus a pair with differing `structural_id` also has
# differing `identity_hash` (R2 requires it whenever the fingerprints differ,
# and for a file source `structural_id == fingerprint`). So `bid=` alone makes
# the texts differ, and an observe-a-difference pair rule is GREEN with `bsid=`
# deleted. R5b therefore demands the difference be located AT the value: entry
# i's text carries `structural_id(i)` and NOT `structural_id(j)`. No other
# field can supply that witness, because the witness is the value's own digits.
#
# ---------------------------------------------------------------------------
# WHY A CORPUS AND NOT A LIST OF PAIRS
# ---------------------------------------------------------------------------
#
# Mojo has no reflection, so the set of inputs a kind's `fingerprint()` folds
# cannot be enumerated by machine — the kind has to say. The question is what
# shape of "saying" is hardest to under-supply.
#
#   * A list of (a, b) PAIRS lets the kind choose which comparisons run. It can
#     ship the pair that passes and omit the one that fails.
#   * A CORPUS does not. The kind supplies bindings; the AUDIT does all pairs.
#     Adding one entry re-checks it against every other entry, so a corpus
#     cannot be curated into a pass.
#
# On top of that, three mechanical defenses make an EMPTY or LAZY corpus fail
# rather than pass — see `audit_scan_identity_coverage` R0/R1. Rule R0 is what
# makes this registry-driven rather than a hand-listed set of kinds: it is not
# "audit the kinds we remembered", it is "audit EVERY REGISTERED KIND, and a
# registered kind with no corpus is RED".
#
# ---------------------------------------------------------------------------
# THE SAME SHAPE IN THE LEGACY UNION ARMS
# ---------------------------------------------------------------------------
#
# The audit covers BINDING-BACKED kinds, because `identity_hash()` is a method
# on `ScanBinding`. The rule itself does not stop there: a file arm still on
# the legacy `SourceVariant` union whose `fingerprint()` folds an input
# (quote style, mtime) that the plan text does not carry has the same gap.
# `ScanData.fingerprint()` is the only consumer of `SourceVariant.fingerprint()`,
# so for a legacy file arm the mtime is folded into a value the plan-compile
# cache does not read, while the value it does read — the plan text, via
# `structural_hash` — cannot see it. That asymmetry is the class.
#
# The fix for each arm is to declare the input as a `param` or as a
# `SNAPSHOT_PINNED` token. What this file guarantees is that an arm cannot
# become binding-backed WITHOUT closing it: the moment an arm becomes
# binding-backed, `core_scan_identity_corpora()` demands its corpus and R2
# demands the coverage.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE CANNOT DO, SAID PLAINLY
# ---------------------------------------------------------------------------
#
# It cannot prove a corpus is COMPLETE — that every input the kind's
# `fingerprint()` folds appears as a varied entry. Without reflection nothing
# can. What it does instead is make incompleteness expensive to reach: the
# corpus lives beside the binding builder (so the two are edited together), the
# registry drives the iteration (so a new kind is covered by existing code), and
# `core_scan_identity_corpora()` in `source_variant.mojo` RAISES on a
# binding-backed legacy tag with no corpus arm (so an arm cannot become
# binding-backed without being audited).
#
# POINTER DISCIPLINE: values only. No pointer of any kind appears here.

from komira_core.source.scan_binding import ScanBinding
from komira_core.source.scan_kind_registry import (
    ScanKindDescriptor,
    ScanKindRegistry,
)


struct ScanIdentityCorpus(Copyable, Movable, Deinitable):
    """A kind's own statement of what makes two of its scans different.

    Built by the package that OWNS the kind, beside the function that builds
    the kind's bindings, so the two are edited in one place. Carries its own
    `ScanKindDescriptor` so a corpus is self-describing and the audit can check
    the descriptor against the bindings it claims to describe.

    EACH ENTRY VARIES ONE THING. The label says which — it is the text a
    failure quotes, so `"mtime"` is a useful label and `"case 3"` is not.
    """

    var descriptor: ScanKindDescriptor
    var labels: List[String]
    var bindings: List[ScanBinding]

    def __init__(out self, var descriptor: ScanKindDescriptor):
        self.descriptor = descriptor^
        self.labels = List[String]()
        self.bindings = List[ScanBinding]()

    def copy(self) -> Self:
        var out = Self(self.descriptor.copy())
        out.labels = self.labels.copy()
        out.bindings = self.bindings.copy()
        return out^

    def add(mut self, var label: String, var binding: ScanBinding):
        """Add one entry. `label` names the input this entry varies."""
        self.labels.append(label^)
        self.bindings.append(binding^)

    def num_entries(self) -> Int:
        return len(self.bindings)


def _distinct_fingerprint_count(corpus: ScanIdentityCorpus) -> Int:
    var seen = List[UInt64]()
    for i in range(len(corpus.bindings)):
        var fp = corpus.bindings[i].fingerprint
        var found = False
        for j in range(len(seen)):
            if seen[j] == fp:
                found = True
                break
        if not found:
            seen.append(fp)
    return len(seen)


def _corpus_index_for(
    corpora: List[ScanIdentityCorpus], kind_id: UInt32
) -> Int:
    for i in range(len(corpora)):
        if corpora[i].descriptor.kind_id == kind_id:
            return i
    return -1


def audit_scan_identity_reproducibility(
    corpora: List[ScanIdentityCorpus],
    rebuilt: List[ScanIdentityCorpus],
) raises:
    """R9 REPRODUCIBILITY — an identity a SECOND BUILD cannot reproduce is not
    an identity.

    ⚠ WHY THIS RULE EXISTS, AND WHY IT IS NOT A RESTATEMENT OF R2. Every rule
    from R0 to R8 reads ONE build of a corpus. Not one of them can see an
    identity that is a function of WHEN it was constructed rather than of WHAT
    it describes — because within a single build such a value looks exactly like
    a well-behaved one: distinct where the kind says distinct, stable under
    `copy()`, folded into `identity_hash()` on demand. It differs from a real
    identity in only one place, and that place is the SECOND build.

    The instance this rule exists for:

        InMemorySource.fingerprint() == _mix64(komira_next_inmem_source_id())

    a SplitMix64 finalization of a process-global monotonic counter
    (`in_memory_source.mojo`). Two sources over BYTE-IDENTICAL content have
    DIFFERENT fingerprints, while their `structural_id()` and the plan text and
    `LogicalPlan.structural_hash()` are all EQUAL. That is deliberate and
    correct: folding the counter into the structural hash would break subquery
    dedup and the plan-compile cache, because a structural hash MUST be equal
    for structurally identical plans.

    THE TRAP THAT FOLLOWS, WHICH THIS RULE TURNS INTO A RED TEST:

      * R1 asks for >= 2 DISTINCT fingerprints. A counter supplies that for
        FREE — so for such a kind R1, whose entire job is "a corpus that
        asserts nothing must FAIL", is satisfied by a corpus of two entries
        that vary NOTHING AT ALL. The one rule guaranteed unfalsifiable is the
        anti-vacuity rule.
      * R2 then reads `fingerprint(a) != fingerprint(b)` and demands core
        separate them. Its FIX line says "carry the differing input in
        `params`" — and carrying THAT input makes `identity_hash()` per-ctor
        unique, therefore the plan text per-ctor unique, therefore
        `structural_hash()` per-ctor unique, therefore `factory_hash` never
        hits and `plan_cse` / `optimizer_scan_dedup` never fold, for EVERY
        in-memory scan. The gate would DEMAND a regression.

    So the premise R2 rests on — "the KIND is the authority on what makes two of
    its scans different" — needs the authority to be a property of the DATA. R9
    is that check, stated positively: build the corpus twice; the two builds
    must agree. A pure function of (path, mtime, codec, content) does. A counter
    does not.

    It is also what `scan_binding.mojo` requires of `kind_id`: a hashed name
    rather than a tag byte, "stable ACROSS PROCESSES, so it survives
    serialization". A value that cannot be reproduced by a second build in the
    SAME process certainly cannot be reproduced by a second PROCESS. R9 is that
    sentence made mechanical, one build earlier.

    ⚠ RESIDUAL, STATED SO A PASS IS NOT OVER-READ. This rule can only see what
    the caller gives it: `rebuilt` must be an INDEPENDENT invocation of the same
    builder, not `corpora.copy()`. A copy trivially agrees. The production gate
    calls `core_scan_identity_corpora()` twice.
    """
    if len(rebuilt) != len(corpora):
        raise Error(
            String("ScanIdentity AUDIT R9 (REPRODUCIBILITY): the second build")
            + String(" has ")
            + String(len(rebuilt))
            + String(" corpus entr(y/ies) but the first has ")
            + String(len(corpora))
            + String(". The two arguments must be two INDEPENDENT invocations")
            + String(" of the same corpus builder; a builder whose SHAPE")
            + String(" changes between calls is already non-reproducible.")
        )
    for ci in range(len(corpora)):
        ref a = corpora[ci]
        ref b = rebuilt[ci]
        var kname = String(a.descriptor.kind_name)
        if a.descriptor.kind_id != b.descriptor.kind_id:
            raise Error(
                String("ScanIdentity AUDIT R9 (REPRODUCIBILITY): corpus ")
                + String(ci)
                + String(" is kind '")
                + kname
                + String("' in the first build and '")
                + b.descriptor.kind_name
                + String("' in the second. The two builds must be parallel;")
                + String(" build both from the same list-producing function.")
            )
        if a.num_entries() != b.num_entries():
            raise Error(
                String("ScanIdentity AUDIT R9 (REPRODUCIBILITY): kind '")
                + kname
                + String("' produced ")
                + String(a.num_entries())
                + String(" entries in one build and ")
                + String(b.num_entries())
                + String(" in the next. A corpus builder must be a FUNCTION of")
                + String(" the kind, not of when it ran.")
            )
        for i in range(a.num_entries()):
            var field = String("")
            var va = String("")
            var vb = String("")
            if a.bindings[i].fingerprint != b.bindings[i].fingerprint:
                field = String("fingerprint")
                va = String(a.bindings[i].fingerprint)
                vb = String(b.bindings[i].fingerprint)
            elif a.bindings[i].structural_id != b.bindings[i].structural_id:
                field = String("structural_id")
                va = String(a.bindings[i].structural_id)
                vb = String(b.bindings[i].structural_id)
            elif a.bindings[i].identity_hash() != b.bindings[i].identity_hash():
                field = String("identity_hash()")
                va = String(a.bindings[i].identity_hash())
                vb = String(b.bindings[i].identity_hash())
            elif a.bindings[i].render() != b.bindings[i].render():
                field = String("render()")
                va = a.bindings[i].render()
                vb = b.bindings[i].render()
            if field.byte_length() == 0:
                continue
            raise Error(
                String("ScanIdentity AUDIT R9 (REPRODUCIBILITY) FAILED for")
                + String(" kind '")
                + kname
                + String("':\n  entry '")
                + a.labels[i]
                + String("' has ")
                + field
                + String(" = ")
                + va
                + String(" when built once and ")
                + vb
                + String(" when built again, from the same inputs, in the same")
                + String(" process.\n  THE VALUE IS THEREFORE A FUNCTION OF")
                + String(" WHEN IT WAS CONSTRUCTED, NOT OF WHAT IT DESCRIBES.")
                + String(" Every rule R0-R8 reads ONE build and cannot see")
                + String(" this: within a single build such a value is")
                + String(" distinct where the kind says distinct and stable")
                + String(" under copy(), so it passes R1 and drives R2.\n  WHY")
                + String(" THAT IS FATAL HERE: `identity_hash()` reaches")
                + String(" `LogicalPlan.structural_hash()` through the plan")
                + String(" TEXT, and `EngineContext` uses that as")
                + String(" `factory_hash`. A key that changes per construction")
                + String(" NEVER HITS — every plan recompiles, `plan_cse` and")
                + String(" `optimizer_scan_dedup` never fold, and nothing goes")
                + String(" red. It also cannot survive serialization, which is")
                + String(" the property `scan_kind_id` is a hashed name")
                + String(" (rather than a tag byte) in order to have.\n  THE")
                + String(" IN-TREE INSTANCE THIS RULE WAS WRITTEN FOR:")
                + String(" `InMemorySource.fingerprint()` is")
                + String(" `_mix64(<process-global monotonic counter>)`. Its")
                + String(" plan-discriminating identity is `structural_id()`")
                + String(" (content-derived) — the counter is the")
                + String(" ALLOCATOR-REUSE identity and its own docstring says")
                + String(" folding it into the structural hash 'broke subquery")
                + String(" dedup + the Layer-1 plan-compile cache'.\n  FIX:")
                + String(" supply the kind's CONTENT-DERIVED identity as the")
                + String(" binding's `fingerprint`, not a per-construction")
                + String(" token. If the kind has no content-derived identity,")
                + String(" it does not yet have an identity a plan cache can")
                + String(" key on, and that is the bug.")
            )


def audit_scan_identity_coverage(
    registry: ScanKindRegistry,
    corpora: List[ScanIdentityCorpus],
    rendered: List[List[String]],
) raises:
    """THE GATE. Raises, naming the kind and the two entries, on any violation.

    ⚠ PREFER `komira_core.plan.scan_identity_render_audit.audit_scan_identity`
    — it produces `rendered` from the production plan path and calls this. The
    third argument is REQUIRED and not defaulted on purpose: a defaulted-empty
    render list would be a render-less mode to fall into by accident, and R4 is
    the rule that catches the identity not reaching the plan at all.

    `rendered[ci][i]` is the plan TEXT of a scan over `corpora[ci].bindings[i]`.

    Six rules. The NUMBERS are identifiers in the order the rules were added,
    not the order they run; the RUN order is the order a failure is most useful
    to read (R4a deliberately runs before R2, because "the identity reaches
    the text at all" is the premise that makes R2's consequence measurable; and
    R5 runs LAST, as a second pass, because a `structural_id` that fails to
    reach the text is only worth reporting once the DERIVED identity — the one
    a kind author cannot forget to populate — has been cleared):

    R0 COMPLETENESS — the registry is the list, not a hand-written one.
        Every REGISTERED kind must have exactly one corpus, and every corpus's
        kind must be registered. So a new kind is covered by the moment it is
        registered; nobody has to remember to add it to an audit list. A
        hand-listed set of kinds would be the same defect one level up.

    R1 NON-VACUITY — an empty or degenerate corpus must FAIL, not pass.
        >= 2 entries and >= 2 DISTINCT fingerprints. Without this, the cheapest
        way to satisfy the gate is a corpus of one, which asserts nothing.

    R2 COVERAGE — the rule this file exists for.
        For every PAIR: a differing `fingerprint` forces a differing
        `identity_hash`. All pairs, so a corpus cannot be curated into a pass.

    R3 DESCRIPTOR AGREEMENT — the binding matches what the kind declared.
        `registry.validate` already checks orientation, snapshot policy and
        required params. Running it here means a kind cannot declare
        `SNAPSHOT_PINNED` on its descriptor while its builder still emits
        `SNAPSHOT_NONE`, caught a second way.

    R4 REACH — the derived identity must actually REACH the plan text.
        R0-R3 are all about VALUES on a `ScanBinding`. None of them looks at
        whether that value gets anywhere, and `identity_hash()` matters for
        exactly one reason: `LogicalPlan.structural_hash()` is FNV-1a over the
        plan TEXT and `EngineContext` uses it as `factory_hash`.

        ⚠ One `writer.write(", bid=", b.identity_hash())` in `plan_display.mojo`
        is the only thing carrying the derived identity into that text.
        Deleting it would leave every rule above GREEN — R2 compares
        `identity_hash` values directly, so it cannot see that the value
        stopped reaching anything — and only FORMAT goldens would go red. A
        format golden goes red on any innocuous render change, so the fix of
        least resistance is to update its literal.

        Two clauses:
          a. REACH   — every entry's plan text CONTAINS its `identity_hash()`.
             Deliberately containment and not a field name: it pins that
             identity is IN the text, and survives renaming `bid=` or
             reordering the fields, so it is a class rule and not a golden.
          b. SEPARATE — for every PAIR, a differing `identity_hash` forces
             differing plan text. (a) implies (b) in practice; (b) is stated
             because it is the property at the CALL SITE, and because it is
             what lets R2 MEASURE its consequence instead of asserting it.

    R5 SUPPLIED REACH — and so must the KIND-SUPPLIED `structural_id`.

        ⚠ R4 COVERS ONLY ONE OF TWO TWINS. The render writes
        `bsid=<structural_id>` beside `bid=<identity_hash()>`, and R0-R4 never
        read `structural_id` at all. `bsid=` is not redundant: the derived fold
        covers only what core can SEE, and `structural_id` is the kind's
        statement about what it cannot (IN_MEMORY content bytes).

        Two clauses:
          a. REACH     — every entry's plan text CONTAINS its `structural_id`.
             Containment of the VALUE, like R4a, so renaming `bsid=` or
             reordering fields stays green and deleting it does not.
          b. ATTRIBUTE — for every PAIR with a differing `structural_id`, the
             difference must be located AT that value: entry i's text carries
             `structural_id(i)` and NOT `structural_id(j)`.

             ⚠ NOT "the texts differ". On a file-kind corpus a pair whose
             `structural_id` differs ALSO has a differing `identity_hash`, so
             `bid=` alone makes the texts differ and an observe-a-difference
             rule is green with `bsid=` deleted. The witness here is the
             value's own digits, which no other field can supply.
    """

    # -- R4 PRECONDITION: the rendered text describes THESE corpora. ----------
    #
    # A shape mismatch is the one way R4 could be silently skipped, so it is a
    # named error rather than a short loop. (An audit that quietly checks fewer
    # things than it claims is the failure this whole file is a response to.)
    if len(rendered) != len(corpora):
        raise Error(
            String("ScanIdentity AUDIT R4 (REACH): the rendered-text list has ")
            + String(len(rendered))
            + String(" corpus entr(y/ies) but ")
            + String(len(corpora))
            + String(" corpora were supplied. Build it with")
            + String(" `render_corpora_plan_text(corpora)` from")
            + String(" `komira_core.plan.scan_identity_render_audit`, or")
            + String(" call `audit_scan_identity(registry, corpora)` there,")
            + String(" which does it for you.")
        )
    for i in range(len(corpora)):
        if len(rendered[i]) != corpora[i].num_entries():
            raise Error(
                String("ScanIdentity AUDIT R4 (REACH): kind '")
                + corpora[i].descriptor.kind_name
                + String("' has ")
                + String(corpora[i].num_entries())
                + String(" corpus entries but ")
                + String(len(rendered[i]))
                + String(" rendered plan texts. Every entry must be rendered")
                + String(" or R4 checks a subset while reporting a whole.")
            )

    # -- R0c: an empty registry asserts nothing. ------------------------------
    #
    # PASS by finding nothing to check. This is the in-process half; a
    # declared kind the gate test never imports is the on-disk half.
    if registry.num_kinds() == 0:
        raise Error(
            String("ScanIdentity AUDIT R0 (COMPLETENESS): the registry is")
            + String(" EMPTY, so R0b iterates nothing and every rule below")
            + String(" would report PASS having checked no kind at all.")
            + String(" Register the descriptors of the kinds under audit.")
        )

    # -- R0a: every corpus's kind is registered. ------------------------------
    for i in range(len(corpora)):
        ref c = corpora[i]
        if not registry.describes(c.descriptor.kind_id):
            raise Error(
                String("ScanIdentity AUDIT R0 (COMPLETENESS): kind '")
                + c.descriptor.kind_name
                + String("' supplies an identity corpus but is NOT REGISTERED.")
                + String(" An unregistered kind is invisible to the optimizer;")
                + String(" register its descriptor where the corpus is built.")
            )

    # -- R0b: every registered kind has a corpus. -----------------------------
    #
    # THIS is the clause that makes the audit registry-driven. Registering a
    # kind and forgetting to audit it is RED, and no edit to this file is
    # needed to cover a kind that did not exist when it was written.
    for i in range(registry.num_kinds()):
        var kid = registry.kind_id_at(i)
        if _corpus_index_for(corpora, kid) < 0:
            raise Error(
                String("ScanIdentity AUDIT R0 (COMPLETENESS): kind '")
                + registry.descriptor(kid).kind_name
                + String("' (id ")
                + String(kid)
                + String(") is REGISTERED but supplies NO identity corpus, so")
                + String(" nothing checks that core's derived identity_hash()")
                + String(" covers what its own fingerprint() folds. Build a")
                + String(" `ScanIdentityCorpus` next to the kind's binding")
                + String(" builder, one entry per input the fingerprint folds.")
            )

    for ci in range(len(corpora)):
        ref c = corpora[ci]
        var kname = String(c.descriptor.kind_name)

        # -- R1: non-vacuity. -------------------------------------------------
        if c.num_entries() < 2:
            raise Error(
                String("ScanIdentity AUDIT R1 (NON-VACUITY): kind '")
                + kname
                + String("' supplies a corpus of ")
                + String(c.num_entries())
                + String(" entr(y/ies). A corpus of fewer than 2 asserts")
                + String(" NOTHING — the audit is all-pairs and there are no")
                + String(" pairs. Vary one identity input per entry.")
            )
        var distinct = _distinct_fingerprint_count(c)
        if distinct < 2:
            raise Error(
                String("ScanIdentity AUDIT R1 (NON-VACUITY): kind '")
                + kname
                + String("' supplies ")
                + String(c.num_entries())
                + String(" entries but only ")
                + String(distinct)
                + String(" DISTINCT fingerprint(s), so the R2 implication is")
                + String(" never exercised — its premise never holds. Add an")
                + String(" entry that the kind's OWN fingerprint() separates.")
            )

        for i in range(c.num_entries()):
            # -- R3: the binding agrees with what the kind declared. ----------
            registry.validate(c.bindings[i])

            # -- R4a: REACH. The derived identity is IN the plan text. --------
            #
            # Runs before R2 on purpose: R2's diagnostic reasons about what the
            # plan text does and does not distinguish, and that reasoning is
            # only meaningful once identity demonstrably reaches the text.
            var id_str = String(c.bindings[i].identity_hash())
            if not (id_str in rendered[ci][i]):
                raise Error(
                    String("ScanIdentity AUDIT R4a (REACH) FAILED for kind '")
                    + kname
                    + String("':\n  entry '")
                    + c.labels[i]
                    + String("' has identity_hash ")
                    + id_str
                    + String(", and that value does NOT APPEAR in the plan")
                    + String(" text the scan renders.\n  The derived identity")
                    + String(" therefore reaches NOTHING: `LogicalPlan")
                    + String(".structural_hash()` is FNV-1a over this text and")
                    + String(" `EngineContext` uses it as `factory_hash`, so a")
                    + String(" difference core computed but did not render")
                    + String(" cannot separate two plans.\n  This is the rule")
                    + String(" that goes red when `plan_display.mojo` stops")
                    + String(" emitting the binding's `identity_hash()` — a")
                    + String(" deletion that leaves R0-R3 GREEN, because they")
                    + String(" compare the VALUE and never ask where it goes.")
                    + String("\n  rendered: ")
                    + rendered[ci][i]
                )

            # -- R2: coverage, all pairs. -------------------------------------
            for j in range(i + 1, c.num_entries()):
                var fp_i = c.bindings[i].fingerprint
                var fp_j = c.bindings[j].fingerprint
                var id_i = c.bindings[i].identity_hash()
                var id_j = c.bindings[j].identity_hash()
                var text_differs = rendered[ci][i] != rendered[ci][j]

                # -- R4b: SEPARATE. Differing identity => differing text. -----
                if id_i != id_j and not text_differs:
                    raise Error(
                        String("ScanIdentity AUDIT R4b (REACH) FAILED for kind")
                        + String(" '")
                        + kname
                        + String("':\n  entries '")
                        + c.labels[i]
                        + String("' and '")
                        + c.labels[j]
                        + String("' have DIFFERENT identity_hash (")
                        + String(id_i)
                        + String(" vs ")
                        + String(id_j)
                        + String(") and render IDENTICAL plan text, so the")
                        + String(" difference core computed cannot reach")
                        + String(" `structural_hash()` and the two scans SHARE")
                        + String(" a plan-compile cache key.\n  rendered: ")
                        + rendered[ci][i]
                    )

                if fp_i == fp_j:
                    continue
                if id_i != id_j:
                    continue

                # R2 proper: the kind separates them, core does not.
                #
                # ⚠ THE MESSAGE BELOW DOES NOT ASSERT A CHAIN THIS RUN CAN
                # DISPROVE. "so the plan TEXT does not, so `structural_hash()`
                # does not, so they SHARE a plan-compile cache key" is FALSE
                # whenever another rendered field happens to separate the pair
                # (`bsid=`, the KIND-SUPPLIED `structural_id`, is the usual
                # one). A diagnostic that overstates its consequence teaches
                # the reader to discount it. So the consequence is MEASURED —
                # R4 above guarantees the text is a meaningful thing to measure
                # — and what remains inferred is labelled as inferred.
                var consequence: String
                if text_differs:
                    consequence = (
                        String("\n  MEASURED: their rendered plan text DIFFERS,")
                        + String(" so they do NOT share a cache key TODAY.")
                        + String(" Something OTHER than the derived identity is")
                        + String(" separating them — `bsid=` (the")
                        + String(" KIND-SUPPLIED `structural_id`) is the usual")
                        + String(" one.\n  INFERRED: that is a value the KIND")
                        + String(" computes and can get wrong, and one in tree")
                        + String(" already is: `broker_scan_binding` folds only")
                        + String(" (topic, partition) and omits `start_offset`.")
                        + String(" The DERIVED fold is the one a kind author")
                        + String(" cannot forget to populate, and it is what")
                        + String(" covers the supplied one — so this is a")
                        + String(" violation whose consequence is MASKED, not")
                        + String(" absent. If the masking field ever stops")
                        + String(" separating the pair, the collision goes live")
                        + String(" with nothing red.")
                    )
                else:
                    consequence = (
                        String("\n  MEASURED: their rendered plan text is")
                        + String(" IDENTICAL, so `LogicalPlan.structural_hash()`")
                        + String(" is equal, so they SHARE a plan-compile cache")
                        + String(" key (`factory_hash`, engine_context.mojo")
                        + String(":4106) and one query's compiled plan is")
                        + String(" returned for the other. A silent wrong")
                        + String(" answer, live.")
                    )
                raise Error(
                    String("ScanIdentity AUDIT R2 (COVERAGE) FAILED for kind '")
                    + kname
                    + String("':\n  MEASURED: entries '")
                    + c.labels[i]
                    + String("' and '")
                    + c.labels[j]
                    + String("' have DIFFERENT fingerprints (")
                    + String(fp_i)
                    + String(" vs ")
                    + String(fp_j)
                    + String(") and the SAME derived identity_hash (")
                    + String(id_i)
                    + String("). The KIND's own fold distinguishes these two")
                    + String(" scans; CORE's does not.")
                    + consequence
                    + String("\n  FIX: carry the differing input in `params`,")
                    + String(" or declare it as the `snapshot_token` under")
                    + String(" SNAPSHOT_PINNED.")
                    + String("\n  binding: ")
                    + c.bindings[i].render()
                    + String("  |  ")
                    + c.bindings[j].render()
                    + String("\n  rendered: ")
                    + rendered[ci][i]
                    + String("\n            ")
                    + rendered[ci][j]
                )

    # -- R5: THE KIND-SUPPLIED IDENTITY MUST REACH THE TEXT TOO. -------------
    #
    # A SECOND PASS, deliberately after every R0-R4/R2 verdict. `bsid=` and
    # `bid=` are twins in the render and this rule is the second half of R4 —
    # but when both are broken at once the DERIVED identity is the more useful
    # failure to read first, because it is the one no kind author can forget to
    # populate. Running R5 last also keeps each earlier rule's falsifier
    # reporting the rule it was written for.
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        var kname = String(c.descriptor.kind_name)

        # -- R5a: REACH. The kind's own content identity is IN the text. ------
        #
        # Every entry first, so R5b may assume it. (Residual, stated: like R4a
        # this is containment of a decimal value, so a short `structural_id`
        # could in principle be satisfied by another field's digits. Real kinds
        # supply a 64-bit hash; a kind whose id is small enough to collide
        # would have a far worse problem than this check.)
        for i in range(c.num_entries()):
            var sid_str = String(c.bindings[i].structural_id)
            if not (sid_str in rendered[ci][i]):
                raise Error(
                    String("ScanIdentity AUDIT R5a (SUPPLIED REACH) FAILED for")
                    + String(" kind '")
                    + kname
                    + String("':\n  entry '")
                    + c.labels[i]
                    + String("' has structural_id ")
                    + sid_str
                    + String(", and that value does NOT APPEAR in the plan")
                    + String(" text the scan renders.\n  `structural_id` is the")
                    + String(" identity the KIND supplies for what CORE CANNOT")
                    + String(" SEE — `identity_hash()` folds kind_id, name,")
                    + String(" params, schema, gate and orientation, and none")
                    + String(" of those can separate two IN_MEMORY batches with")
                    + String(" one name and one schema that differ in their")
                    + String(" BYTES. So it is not redundant with `bid=`, and")
                    + String(" the render is the only place it reaches")
                    + String(" `LogicalPlan.structural_hash()`.\n  This is the")
                    + String(" rule that goes red when `plan_display.mojo`")
                    + String(" stops emitting the binding's `structural_id` — a")
                    + String(" deletion that leaves R0-R4 GREEN, because not")
                    + String(" one of them reads the supplied identity.")
                    + String("\n  rendered: ")
                    + rendered[ci][i]
                )

        # -- R5b: ATTRIBUTE. The difference is located AT the value. ----------
        for i in range(c.num_entries()):
            for j in range(i + 1, c.num_entries()):
                var sid_i = c.bindings[i].structural_id
                var sid_j = c.bindings[j].structural_id
                if sid_i == sid_j:
                    continue
                var carrier: Int = -1
                if String(sid_j) in rendered[ci][i]:
                    carrier = i
                elif String(sid_i) in rendered[ci][j]:
                    carrier = j
                if carrier < 0:
                    continue
                raise Error(
                    String("ScanIdentity AUDIT R5b (ATTRIBUTION) FAILED for")
                    + String(" kind '")
                    + kname
                    + String("':\n  entries '")
                    + c.labels[i]
                    + String("' and '")
                    + c.labels[j]
                    + String("' have DIFFERENT structural_id (")
                    + String(sid_i)
                    + String(" vs ")
                    + String(sid_j)
                    + String("), and the text of entry '")
                    + c.labels[carrier]
                    + String("' carries BOTH — so whatever makes these two")
                    + String(" renders differ, it is NOT the structural_id.")
                    + String("\n  WHY THAT IS A FAILURE AND NOT A CURIOSITY:")
                    + String(" on every corpus in this tree a pair whose")
                    + String(" structural_id differs also has a differing")
                    + String(" identity_hash, so `bid=` alone makes the texts")
                    + String(" differ. A rule that merely OBSERVED a difference")
                    + String(" would be GREEN with the `bsid=` write deleted —")
                    + String(" the same masked consequence R2's diagnostic was")
                    + String(" rewritten for. The supplied identity must be the")
                    + String(" WITNESS, not a passenger.")
                    + String("\n  rendered: ")
                    + rendered[ci][i]
                    + String("\n            ")
                    + rendered[ci][j]
                )
