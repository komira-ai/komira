# =============================================================================
# THE RENDER HALF OF THE IDENTITY AUDIT — identity must REACH the plan text.
# =============================================================================
#
# Rule set: `komira_scan_source/scan_identity_audit.mojo`.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS AND WHY IT IS NOT IN `source/`
# ---------------------------------------------------------------------------
#
# `scan_identity_audit.mojo` states the rules and lives in `source/`, beside
# `ScanBinding`. It therefore CANNOT SEE A PLAN — `logical_plan.mojo` imports
# `source_variant.mojo`, which imports the audit, so the audit importing the
# plan layer back is a cycle. That limitation is not incidental: **the defect
# class the audit exists for is precisely a value that reaches one fold and not
# the plan TEXT**, and a rule set that cannot render a plan cannot check the
# half of the claim that matters at the call site.
#
# So the rules live in one file and the RENDERING lives here, one layer up,
# where `LogicalPlan` is spellable. `audit_scan_identity` below is THE entry
# point: it renders every corpus entry through the production path and hands
# the strings to the rule set, which runs R0-R4 over both.
#
# ---------------------------------------------------------------------------
# THE HOLE THIS CLOSES, MEASURED
# ---------------------------------------------------------------------------
#
# `plan_display.mojo` emits `bid=<identity_hash()>` for a binding-backed scan.
# That single `write` call is the ONLY thing carrying core's
# derived identity into the plan text — and therefore into
# `LogicalPlan.structural_hash()`, which `EngineContext` uses as `factory_hash`.
#
# WITHOUT R4, DELETING IT LEAVES THE CLASS-LEVEL GATE GREEN. R2 compares
# `identity_hash` values directly, so it never notices the value has stopped
# reaching anything; only FORMAT goldens go red, and a format golden goes red on
# any innocuous render change, so the fix-of-least-resistance is to update the
# literal. Identity would reach the hash only because one un-asserted line
# happened to exist.
#
# That is what R4 (REACH) is for, and it is a CLASS rule off the same
# registry-driven corpora — not a third golden. Falsified by deleting the
# `bid=` write: every registered kind goes red, naming the kind and the entry.
#
# ---------------------------------------------------------------------------
# AND THE TWIN R4 DOES NOT CLOSE
# ---------------------------------------------------------------------------
#
# The render writes TWO identities. R4 protects the second only:
#
#     writer.write(", bsid=", b.structural_id)      # KIND-SUPPLIED
#     writer.write(", bid=", b.identity_hash())     # CORE-DERIVED
#
# Deleting the `bsid=` write leaves R4 GREEN — only the FORMAT goldens and a
# hand-planted witness fail. R5 (SUPPLIED REACH + ATTRIBUTION) is the second half,
# and it needed one thing R4 did not: its pair clause cannot merely observe
# that two texts differ, because `bid=` makes them differ on every corpus in
# tree. See `scan_identity_audit.mojo`'s R5 for the attribution form.
#
# ---------------------------------------------------------------------------
# AND THE THIRD CARRIER — THE ENUMERATION
# ---------------------------------------------------------------------------
#
# The general question is asked of EVERY value `plan_display._write_plan_node`
# writes for a scan node — neutralise one write at a time, run the class gate —
# and two of them are worse off than the twins:
#
#     projection=   GREEN without the node axis — and NO format golden either
#     filter=       GREEN without the node axis — and NO format golden either
#
# `bid=` and `bsid=` at least have format goldens. These have none. A test
# whose predicates sit in a `Filter` NODE above the scan never exercises the
# scan's own `filter=`.
#
# So two scans of one path differing ONLY in their scan-level projection or
# pushed-down filter would render identically => equal `structural_hash()` =>
# equal `factory_hash` (`EngineContext`'s `var factory_hash =
# plan.structural_hash()`) and equal `plan_cse` / `optimizer_scan_dedup` key.
# The same silent-wrong-answer class, a different carrier.
#
# ⚠ WHY R4/R5 CANNOT REACH IT, AND THIS IS THE DESIGN POINT. `ScanIdentity
# Corpus` varies `ScanBinding`s. `projection` and `filter` are LogicalPlan
# SCAN-NODE fields that no corpus populates, so no amount of corpus discipline
# over bindings touches them. The fix is therefore A SECOND CORPUS AXIS through
# the SAME containment rules — `ScanNodeCorpus` below — and NOT a format
# golden, because a format golden is precisely what leaves `bid=` and `bsid=`
# unprotected.
#
# THE ONE THING THIS AXIS GETS THAT R5b COULD NOT. R5b had to locate a pair's
# difference AT the `structural_id` with a lexical witness, because the pair
# also differed in `bid=` and "the texts differ" was satisfiable by the wrong
# field. Here attribution is STRUCTURAL: `ScanNodeCorpus` is typed with ONE
# binding and the render takes only `(binding, projection, filter)`, so every
# binding-derived field is byte-identical across the corpus by construction and
# nothing BUT the node fields can be the cause of a difference. A type is a
# stronger witness than a substring.
#
# POINTER DISCIPLINE: values only. No pointer of any kind appears here.
# =============================================================================

from komira_arrow.schema import Schema
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SNAPSHOT_NONE,
    SCAN_ORIENTATION_COLUMNAR,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_identity_audit import (
    ScanIdentityCorpus,
    audit_scan_identity_coverage,
    audit_scan_identity_reproducibility,
)
from komira_scan_source.scan_kind_registry import ScanKindRegistry
from komira_scan_source.source_variant import SourceVariant

from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan


def render_scan_plan_text(binding: ScanBinding) raises -> String:
    """The plan TEXT a scan over `binding` produces, through the PRODUCTION
    path.

    ⚠ THIS MUST NOT BE A HAND-ASSEMBLED APPROXIMATION OF THE RENDER. The whole
    claim being checked is "the identity reaches the text `structural_hash()`
    folds", and that is a fact about `_write_plan_node`, not about a string this
    file can build. So it goes through `LogicalPlan.scan_from_source` (the
    caller-facing factory, and the one a real caller of a binding-backed source
    uses) and `String(plan)` — the same two calls a real EXPLAIN makes.

    The plan's own schema is empty: the audit varies BINDINGS, and a schema
    passed here would appear in no rendered field anyway.
    """
    var plan = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(binding.copy()), Schema()
    )
    return String(String(plan).strip())


def render_corpora_plan_text(
    corpora: List[ScanIdentityCorpus],
) raises -> List[List[String]]:
    """Render every corpus entry, in corpus order, parallel to `corpora`.

    Built here rather than by the caller so the strings the rule set reasons
    over cannot be supplied by hand. (`audit_scan_identity_coverage` also
    rejects a shape that does not match its corpora, so a mismatched list is a
    named error rather than a silently-skipped rule.)
    """
    var out = List[List[String]]()
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        var texts = List[String]()
        for i in range(c.num_entries()):
            texts.append(render_scan_plan_text(c.bindings[i]))
        out.append(texts^)
    return out^


def audit_scan_identity(
    registry: ScanKindRegistry,
    corpora: List[ScanIdentityCorpus],
    rebuilt: List[ScanIdentityCorpus],
) raises:
    """THE GATE. Call THIS, not `audit_scan_identity_coverage` directly.

    Renders every corpus entry through the production plan path and runs ALL
    THREE axes:

      BINDING axis  — R0 completeness, R1 non-vacuity, R2 coverage, R3
                      descriptor agreement, R4 REACH of the DERIVED identity,
                      R5 REACH + ATTRIBUTION of the KIND-SUPPLIED one.
      SCAN-NODE axis — R6 non-vacuity, R7 REACH, R8 SEPARATION, over the
                      `projection` and `filter` fields that live on the plan
                      node and that no binding corpus can populate.
      SECOND-BUILD axis — R9 REPRODUCIBILITY, over `rebuilt`.

    Calling the binding rule set directly is still possible and still correct —
    it demands the rendered text as an argument, so there is no render-less mode
    to fall into by accident.

    ⚠ `rebuilt` IS A REQUIRED ARGUMENT AND IS NOT DEFAULTED, for the same reason
    `rendered` is required one level down: a defaulted-empty second build would
    be a reproducibility-less mode to fall into by accident, and R9 is the rule
    that catches an identity which is a function of WHEN it was built rather
    than of WHAT it describes. It must be an INDEPENDENT invocation of the same
    corpus builder — `core_scan_identity_corpora()` twice, not `.copy()`. See
    `audit_scan_identity_reproducibility` for the measurement that motivated it
    and for the residual a copy would leave.

    ⚠ R9 RUNS FIRST. Every other rule reasons about VALUES on a binding, and
    that reasoning is only meaningful once those values are known to be
    properties of the data — the same ordering argument that puts R4a before
    R2. A non-reproducible corpus makes R2's "MEASURED" numbers a report about
    one particular run.

    ⚠ THE NODE AXIS RUNS LAST, AND OVER EVERY REGISTERED KIND'S FIRST BINDING.
    Last because a planted binding-axis corpus must still report the rule it was
    planted for — R6-R8 firing first would point a reader at the wrong rule, the
    same reason R5 is a second pass. Over every kind's binding because that is
    what makes the second axis registry-driven at zero cost to a kind author:
    core states the node corpus once and a new kind is covered the moment R0
    demands its binding corpus.
    """
    audit_scan_identity_reproducibility(corpora, rebuilt)
    audit_scan_identity_coverage(
        registry, corpora, render_corpora_plan_text(corpora)
    )
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        audit_scan_node_identity(
            build_scan_node_corpus(
                String(c.descriptor.kind_name), c.bindings[0]
            )
        )
    audit_scan_identity_cheap_key(corpora)


# =============================================================================
# R10 — THE CHEAP KEY.
# =============================================================================


def _cheap_witness_binding(structural_id: UInt64) -> ScanBinding:
    """A synthetic binding that differs from its twin ONLY in `structural_id`.

    ⚠ IT IS SYNTHETIC BECAUSE NO REGISTERED KIND CAN SUPPLY THE SHAPE, AND THAT
    IS THE FINDING R10b EXISTS FOR. Over the FILE kinds, ZERO pairs are
    separated by `structural_id` alone — every one is also separated by
    `identity_hash()`, because R2 demands exactly that and
    `structural_id == fingerprint` for every file kind. So R10b over the file
    corpora alone would be VACUOUS.

    IN_MEMORY is the kind that CAN supply it — two batches with one name and
    one schema differing only in their BYTES — which is precisely when the
    placeholder becomes load-bearing. `inmem_scan_identity_corpus()` supplies
    three such pairs (`bytes`, `rows`, `nbatches` against `baseline`).

    ⚠ THIS WITNESS STAYS ANYWAY. The synthetic witness is the only one that is
    INDEPENDENT of a kind: R10b's job is to catch the placeholder being
    dropped, and a rule whose only witnesses come from one kind's corpus dies
    the day that corpus is edited. `test_scan_identity_coverage
    :test_a_pair_rule_that_only_observed_a_difference_would_not_have_caught_this`
    asserts BOTH that real unmasked pairs exist and that IN_MEMORY is the
    only kind allowed to produce them.
    """
    var p = ScanParams()
    p.put_str(String("path"), String("r10.witness"))
    return ScanBinding(
        kind_id=scan_kind_id(String("komira.audit.r10")),
        kind_name=String("komira.audit.r10"),
        name=String("r10.witness"),
        params=p^,
        schema=Schema(),
        fingerprint=UInt64(0x5115),
        structural_id=structural_id,
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_NONE,
        snapshot_token=UInt64(0),
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )


def audit_scan_identity_cheap_key(corpora: List[ScanIdentityCorpus]) raises:
    """R10 — the agg-CSE CHEAP KEY, whose one carrier is
    `LogicalPlan.structural_hash_modulo_inmem_id()`.

    The cheap key is the EXACT key with every KIND-SUPPLIED content identity
    replaced by a fixed token (`inmem_id=` on the legacy in-memory arm, `bsid=`
    on a binding-backed one — `plan_display._write_plan_node`). It exists so
    `optimizer_agg_cse` can pre-group candidates without folding resident bytes.
    Substituting a constant for a variable can only MERGE equivalence classes,
    so SOUNDNESS (`exact equal ==> cheap equal`) holds by construction and is
    not what this rule checks. What is NOT free is PRECISION, and that is what
    this rule measures.

    R10a — THE COARSENING IS FREE WHERE CORE'S DERIVED IDENTITY COVERS IT.
        For every pair whose `identity_hash()` differs, the CHEAP keys must
        differ too. `bid=<identity_hash()>` is never placeholdered, so this
        holds for every kind with `structural_id == fingerprint` — i.e. every
        file kind, by R2 — and it FAILS the moment `bid=` is placeholdered or
        stops reaching the text. It is the rule that says placeholdering
        `bsid=` cost the registered kinds nothing, re-measured on every run
        rather than asserted once in a comment.

        ⚠ THE PREMISE IS `identity_hash()`, NOT `structural_id`. Keying it on
        `structural_id` would make it un-satisfiable for IN_MEMORY, whose whole
        point is a supplied identity core cannot derive — and a rule a correct
        future kind must violate is a rule that gets deleted.

    R10b — AND THE PLACEHOLDER ACTUALLY TOOK.
        A pair differing ONLY in the supplied `structural_id` must land on the
        SAME cheap key. Without this, R10a is satisfied by a render that
        placeholders NOTHING — the exact key trivially separates everything —
        and the lever would be silently dead. Driven by a synthetic witness; see
        `_cheap_witness_binding` for why no registered kind can supply one.
    """
    if len(corpora) == 0:
        raise Error(
            String("AUDIT R10 (CHEAP KEY): no corpora. R0 owns emptiness, but")
            + String(" reaching R10 with none means this rule asserted")
            + String(" NOTHING about the agg-CSE pre-grouping.")
        )

    # -- R10a: a pair core's DERIVED identity separates stays separated. ------
    var checked_pairs = 0
    for ci in range(len(corpora)):
        ref c = corpora[ci]
        var n = c.num_entries()
        for i in range(n):
            for j in range(i + 1, n):
                if (
                    c.bindings[i].identity_hash()
                    == c.bindings[j].identity_hash()
                ):
                    continue
                checked_pairs += 1
                var pa = LogicalPlan.scan_from_source(
                    SourceVariant.from_binding(c.bindings[i].copy()), Schema()
                )
                var pb = LogicalPlan.scan_from_source(
                    SourceVariant.from_binding(c.bindings[j].copy()), Schema()
                )
                if (
                    pa.structural_hash_modulo_inmem_id()
                    == pb.structural_hash_modulo_inmem_id()
                ):
                    raise Error(
                        String("AUDIT R10a (CHEAP KEY) FAILED for kind '")
                        + String(c.descriptor.kind_name)
                        + String("':\n  entries '")
                        + c.labels[i]
                        + String("' and '")
                        + c.labels[j]
                        + String("' have DIFFERENT `identity_hash()` and the")
                        + String(" SAME agg-CSE cheap key, so the placeholdered")
                        + String(" render MERGED a pair core can tell apart.\n")
                        + String("  Expected: 0 such pairs — the")
                        + String(" coarsening was free BECAUSE `bid=")
                        + String("<identity_hash()>` is not placeholdered.\n")
                        + String("  So something now placeholders `bid=`, or")
                        + String(" `bid=` stopped reaching the plan text (see")
                        + String(" R4). This is a PRECISION loss, not a")
                        + String(" correctness one: agg-CSE still folds on the")
                        + String(" EXACT hash, but it now pays that O(resident")
                        + String(" bytes) hash for candidates it used to skip.")
                    )
    if checked_pairs == 0:
        raise Error(
            String("AUDIT R10a (CHEAP KEY): NOT ONE pair across all corpora has")
            + String(" a differing `identity_hash()`, so R10a compared nothing.")
            + String(" R2 should have failed first; if it did not, the corpora")
            + String(" are degenerate.")
        )

    # -- R10b: the placeholder took. -----------------------------------------
    var wa = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_cheap_witness_binding(UInt64(0x1111))),
        Schema(),
    )
    var wb = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_cheap_witness_binding(UInt64(0x2222))),
        Schema(),
    )
    if wa.structural_hash() == wb.structural_hash():
        raise Error(
            String("AUDIT R10b (CHEAP KEY) premise FAILED: the two witness")
            + String(" bindings differ in `structural_id` and their EXACT")
            + String(" hashes are EQUAL, so `bsid=` has stopped reaching the")
            + String(" plan text. That is an R5 failure and R5 should have")
            + String(" reported it; R10b's own assertion below would be")
            + String(" vacuously satisfiable by a render that emits neither.")
        )
    if (
        wa.structural_hash_modulo_inmem_id()
        != wb.structural_hash_modulo_inmem_id()
    ):
        raise Error(
            String("AUDIT R10b (CHEAP KEY) FAILED: two bindings differing ONLY")
            + String(" in the KIND-SUPPLIED `structural_id` got DIFFERENT")
            + String(" agg-CSE cheap keys, so `_write_plan_node` did NOT")
            + String(" placeholder `bsid=`.\n  The cheap key is therefore no")
            + String(" longer blind to a kind's own content identity. For a")
            + String(" FILE kind that costs only precision, because every")
            + String(" file kind sets `structural_id == fingerprint`. For")
            + String(" IN_MEMORY it is the lever itself: its `structural_id` IS the")
            + String(" content hash, so `")
            + String("test_planner_data_scaling_passes.mojo")
            + String(":_assert_cheap_key_invariant` goes red across node")
            + String(" kinds and the O(resident bytes) fold the pre-grouping")
            + String(" exists to avoid comes back.")
        )


# =============================================================================
# THE SECOND CORPUS AXIS — the SCAN NODE's own identity fields.
# =============================================================================
#
# `ScanIdentityCorpus` varies BINDINGS. This one varies the two fields that
# live on the plan's SCAN NODE and not on any binding — `projection` and
# `filter` — over ONE fixed binding.


comptime NODE_WITNESS_ALPHA: StaticString = "px_alpha"
"""A projected column name chosen to be ABSENT from every binding's render.

⚠ LOAD-BEARING, AND RULE R7b IS WHAT KEEPS IT HONEST. R7a is containment of a
short string, so a name that a kind's path, `kind_name` or param map happens to
contain would satisfy it for the wrong reason — the residual R4a/R5a accept for
a 64-bit decimal is much larger for a column name. R7b measures that residual
away by demanding the witness be ABSENT from the CONTROL render (the same
binding with neither field set), so a badly-chosen witness is RED rather than a
silent free pass.
"""

comptime NODE_WITNESS_BETA: StaticString = "px_beta"
"""The second witness. Two are needed: one distinguishes projections by their
CONTENT, and the pair distinguishes them by their ORDER."""


struct ScanNodeCorpus(Movable, Deinitable):
    """One kind's binding, rendered under every scan-node variation.

    ⚠ ONE BINDING PER CORPUS, AND THAT IS THE ATTRIBUTION MECHANISM. R5b needed
    a lexical witness to locate a pair's difference AT the `structural_id`,
    because the pair also differed in `bid=` and "the texts differ" was
    satisfiable by the wrong field. Here the binding is a FIELD of the corpus
    and `render_scan_node_plan_text` takes only `(binding, projection, filter)`,
    so every binding-derived field of the render is byte-identical across the
    whole corpus BY CONSTRUCTION. Nothing but the node fields can cause a
    difference, so R8 needs no witness — the type is the witness.

    ⚠ THE `Expr` IS NOT STORED. `Expr` is `Movable` but not `Copyable`, so a
    corpus that held filters could not be copied or re-rendered. It holds the
    RESULT (the rendered text) plus the two things the rules need to reason
    about the inputs: a canonical KEY per axis (do two entries differ?) and the
    WITNESS tokens (what must appear). Both are computed from the corpus's own
    inputs at build time, never read back out of the plan text — which is what
    makes R7 a check on the render rather than a tautology.
    """

    var kind_name: String
    var binding: ScanBinding
    """THE one binding every entry renders over. A FIELD, not a per-entry
    column — the type is what makes R8's attribution structural."""
    var binding_identity: String
    """`String(binding.identity_hash())` — R7c re-checks R4a under a node
    field."""
    var binding_structural_id: String
    """`String(binding.structural_id)` — R7c re-checks R5a the same way."""
    var labels: List[String]
    var witnesses: List[List[String]]
    """Per entry: the tokens the entry's own inputs say must reach the text."""
    var proj_keys: List[String]
    """Per entry: a canonical identity for the projection. `""` == unset. The
    separator is US (0x1f), which cannot occur in a column name, so
    `["a\\x1fb"]` and `["a", "b"]` cannot alias."""
    var filter_keys: List[String]
    """Per entry: a canonical identity for the filter. `""` == unset."""
    var rendered: List[String]
    """Per entry: the plan TEXT, through the production path."""
    var control: String
    """The same binding with NEITHER field set. R7b's reference point."""

    def __init__(
        out self, var kind_name: String, binding: ScanBinding
    ) raises:
        """⚠ THE CONTROL IS RENDERED HERE, not by the corpus author. R7b is
        only as good as its reference point, and a `control` a caller had to
        remember to set is one a caller can forget to set — at which point it
        is the empty string, every `token in ""` is False, and R7b passes
        vacuously for every entry. Rendering it in the ctor makes that
        unreachable."""
        self.kind_name = kind_name^
        self.binding_identity = String(binding.identity_hash())
        self.binding_structural_id = String(binding.structural_id)
        self.binding = binding.copy()
        self.labels = List[String]()
        self.witnesses = List[List[String]]()
        self.proj_keys = List[String]()
        self.filter_keys = List[String]()
        self.rendered = List[String]()
        self.control = render_scan_node_plan_text(binding, None, None)

    def add(
        mut self,
        var label: String,
        var witnesses: List[String],
        var projection: Optional[List[String]],
        var filter: Optional[Expr],
    ) raises:
        """Record one variation AND render it.

        Keys and witnesses are derived from the INPUTS, here, before the render
        exists — so no rule below can be satisfied by reading a value back out
        of the very text it is checking.
        """
        self.labels.append(label^)
        self.witnesses.append(witnesses^)
        self.proj_keys.append(_projection_key(projection))
        self.filter_keys.append(_filter_key(filter))
        self.rendered.append(
            render_scan_node_plan_text(self.binding, projection^, filter^)
        )

    def num_entries(self) -> Int:
        return len(self.labels)


def render_scan_node_plan_text(
    binding: ScanBinding,
    var projection: Optional[List[String]],
    var filter: Optional[Expr],
) raises -> String:
    """The plan TEXT a scan over `binding` with these node fields produces.

    ⚠ THE PRODUCTION PATH, for the same reason `render_scan_plan_text` insists
    on it: the claim being checked is a fact about `_write_plan_node`, not about
    a string this file could assemble.

    THE SIGNATURE IS THE ATTRIBUTION ARGUMENT. Three inputs, one of which is
    fixed by the corpus — so two calls that differ only in `projection` produce
    two texts that can differ only where `projection` reaches the render.
    """
    var plan = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(binding.copy()),
        Schema(),
        projection^,
        filter^,
    )
    return String(String(plan).strip())


def _projection_key(projection: Optional[List[String]]) -> String:
    """A canonical identity for a projection, ORDER-SENSITIVE.

    Order is not cosmetic: a kind's projection ORDER can reach the kind's
    fingerprint and not core's derived identity (ORC is one). A
    key that sorted would make the order-only corpus pair look equal, R8 would
    skip it, and a render that sorted the projection would pass.
    """
    if not projection:
        return String("")
    var out = String("[")
    ref names = projection.value()
    for i in range(len(names)):
        if i > 0:
            out += String("\x1f")
        out += names[i]
    out += String("]")
    return out^


def _filter_key(filter: Optional[Expr]) -> String:
    """A canonical identity for a scan-level filter — the expression's own
    text, taken from `Expr.write_to` DIRECTLY rather than from the plan text.

    That directness is the whole point: if `_write_plan_node` stops emitting the
    scan's `filter=`, this value is unchanged and R7a goes red. If `Expr
    .write_to` itself changes, both move together and the rule stays green —
    correct, because the rule is about the value REACHING the text, never about
    its format. Exactly R4a's logic on a different carrier.
    """
    if not filter:
        return String("")
    return String(filter.value())


def _names(var a: String) -> List[String]:
    var out = List[String]()
    out.append(a^)
    return out^


def _names2(var a: String, var b: String) -> List[String]:
    var out = List[String]()
    out.append(a^)
    out.append(b^)
    return out^


def build_scan_node_corpus(
    var kind_name: String, binding: ScanBinding
) raises -> ScanNodeCorpus:
    """CORE's statement of what makes two SCAN NODES over one binding different.

    ⚠ CORE-OWNED, NOT KIND-OWNED, AND THAT IS NOT AN OVERSIGHT. `ScanIdentity
    Corpus` is supplied by the package that owns the kind because only that
    package knows what its `fingerprint()` folds. `projection` and `filter` are
    `ScanData` fields written by ONE branch of `_write_plan_node` that every
    kind shares, so a per-kind corpus would be seven copies of one statement and
    a kind could ship a curated one. Core states it once; the audit runs it over
    EVERY REGISTERED KIND's binding, so a new kind is covered the moment it is
    registered — the same registry-driven property R0 gives the binding axis,
    obtained without asking a kind author for anything.

    THE ENTRIES, AND WHY EACH ONE IS HERE:

      none                     the CONTROL. Pairs with every projection entry as
                               a "the field was not written at all" case.
      projection-alpha         projection reaches the text.
      projection-beta          and it does so by CONTENT, not by presence.
      projection-alpha-beta    a two-column projection.
      projection-beta-alpha    ⚠ THE ORDER-ONLY PAIR. A projection ORDER can
                               reach a kind's fingerprint and not core's
                               identity (see `_projection_key`).
                               Same witnesses as the entry above, so ONLY R8
                               can separate them — a render that sorted the
                               projection would be caught by nothing else.
      filter-alpha-gt-0        filter reaches the text.
      filter-alpha-gt-1        and by its LITERAL.
      filter-beta-gt-0         and by its COLUMN.
    """
    var c = ScanNodeCorpus(kind_name^, binding)

    var alpha = String(NODE_WITNESS_ALPHA)
    var beta = String(NODE_WITNESS_BETA)

    c.add(String("none"), List[String](), None, None)
    c.add(
        String("projection-alpha"),
        _names(String(alpha)),
        Optional(_names(String(alpha))),
        None,
    )
    c.add(
        String("projection-beta"),
        _names(String(beta)),
        Optional(_names(String(beta))),
        None,
    )
    c.add(
        String("projection-alpha-beta"),
        _names2(String(alpha), String(beta)),
        Optional(_names2(String(alpha), String(beta))),
        None,
    )
    c.add(
        String("projection-beta-alpha"),
        _names2(String(alpha), String(beta)),
        Optional(_names2(String(beta), String(alpha))),
        None,
    )
    var f_a0 = col(String(alpha)) > 0
    c.add(
        String("filter-alpha-gt-0"),
        _names(String(f_a0)),
        None,
        Optional(f_a0^),
    )
    var f_a1 = col(String(alpha)) > 1
    c.add(
        String("filter-alpha-gt-1"),
        _names(String(f_a1)),
        None,
        Optional(f_a1^),
    )
    var f_b0 = col(String(beta)) > 0
    c.add(
        String("filter-beta-gt-0"),
        _names(String(f_b0)),
        None,
        Optional(f_b0^),
    )
    return c^


def audit_scan_node_identity(corpus: ScanNodeCorpus) raises:
    """THE SECOND-AXIS GATE. Raises, naming the kind and the entries.

    Three rules, in the order a failure is most useful to read. They are the
    same three shapes the binding axis converged on — non-vacuity, reach,
    separation — because the defect is the same defect on a different carrier.

    R6 NODE NON-VACUITY — the corpus must exercise BOTH axes in isolation.
        At least one pair differing ONLY in `projection` and at least one
        differing ONLY in `filter`. Without the isolation clause a corpus whose
        entries always vary both would let a DELETED `projection=` write pass:
        the surviving `filter=` would still separate every pair, and R8 would
        be green having proven nothing about projection. Same lesson as R1, one
        axis over.

    R7 NODE REACH — the field's own content must be IN the plan text.
        a. REACH  — every entry's witnesses appear in that entry's text.
        b. CAUSED — no witness appears in the CONTROL text (the same binding
           with neither field set). Containment of a short column name is much
           weaker than containment of a 64-bit decimal, so this measures the
           residual away instead of accepting it: a witness the BINDING already
           supplies is RED, not a silent free pass.
        c. INTACT — every entry's text still carries the binding's
           `identity_hash` and `structural_id`. A node axis that passed by
           having DISPLACED the binding half would be a worse defect than the
           one it was closing.

    R8 NODE SEPARATION — differing node fields force differing text.
        For every pair whose `(projection, filter)` keys differ, the rendered
        texts must differ — because `LogicalPlan.structural_hash()` is FNV-1a
        over that text and `EngineContext` uses it as `factory_hash`.

        ⚠ NO ATTRIBUTION CLAUSE, AND THAT IS A STRONGER POSITION THAN R5b'S,
        NOT A WEAKER ONE. R5b could not simply observe a difference, because
        the pair also differed in `bid=` and the wrong field could satisfy it.
        Here `ScanNodeCorpus` holds ONE binding and
        `render_scan_node_plan_text` takes only `(binding, projection, filter)`,
        so every binding-derived field is byte-identical across the corpus by
        construction. There is no other field left to be the cause. R7c pins
        the premise that the binding half is still being rendered at all.
    """
    var kname = String(corpus.kind_name)
    var n = corpus.num_entries()

    if n < 2:
        raise Error(
            String("ScanNode AUDIT R6 (NODE NON-VACUITY): kind '")
            + kname
            + String("' supplies a scan-node corpus of ")
            + String(n)
            + String(" entr(y/ies). The audit is all-pairs and there are no")
            + String(" pairs, so it asserts NOTHING.")
        )

    # -- R6: both axes must be exercised IN ISOLATION. ------------------------
    var has_projection_only = False
    var has_filter_only = False
    for i in range(n):
        for j in range(i + 1, n):
            var p_differs = corpus.proj_keys[i] != corpus.proj_keys[j]
            var f_differs = corpus.filter_keys[i] != corpus.filter_keys[j]
            if p_differs and not f_differs:
                has_projection_only = True
            if f_differs and not p_differs:
                has_filter_only = True
    if not has_projection_only:
        raise Error(
            String("ScanNode AUDIT R6 (NODE NON-VACUITY): kind '")
            + kname
            + String("' has NO pair that differs ONLY in `projection`, so R8")
            + String(" never measures the `projection=` write on its own. A")
            + String(" pair that varies both fields is separated by whichever")
            + String(" one still renders, and would be GREEN with the other")
            + String(" DELETED. Add a pair with one filter and two")
            + String(" projections.")
        )
    if not has_filter_only:
        raise Error(
            String("ScanNode AUDIT R6 (NODE NON-VACUITY): kind '")
            + kname
            + String("' has NO pair that differs ONLY in `filter`, so R8 never")
            + String(" measures the `filter=` write on its own. Add a pair with")
            + String(" one projection and two filters.")
        )

    # -- R7: the node field's own content REACHES the text, and is CAUSED. ----
    for i in range(n):
        ref ws = corpus.witnesses[i]
        for w in range(len(ws)):
            var token = String(ws[w])
            if not (token in corpus.rendered[i]):
                raise Error(
                    String("ScanNode AUDIT R7a (NODE REACH) FAILED for kind '")
                    + kname
                    + String("':\n  entry '")
                    + corpus.labels[i]
                    + String("' sets a scan-node field whose content is '")
                    + token
                    + String("', and that value does NOT APPEAR in the plan")
                    + String(" text the scan renders.\n  So the field reaches")
                    + String(" NOTHING: `LogicalPlan.structural_hash()` is")
                    + String(" FNV-1a over this text and `EngineContext` uses")
                    + String(" it as `factory_hash`, so two scans of ONE path")
                    + String(" differing only in their projection or pushed")
                    + String(" filter share a plan-compile cache key and one")
                    + String(" query's compiled plan is returned for the")
                    + String(" other.\n  This is the rule that goes red when")
                    + String(" `plan_display.mojo` stops emitting the scan's")
                    + String(" `projection=` or `filter=` — a deletion that")
                    + String(" leaves the ENTIRE binding-axis gate green")
                    + String(" with no format golden either.\n  rendered: ")
                    + corpus.rendered[i]
                )
            if token in corpus.control:
                raise Error(
                    String("ScanNode AUDIT R7b (NODE REACH / CAUSED) FAILED")
                    + String(" for kind '")
                    + kname
                    + String("':\n  entry '")
                    + corpus.labels[i]
                    + String("' uses witness '")
                    + token
                    + String("', and that token ALREADY APPEARS in the CONTROL")
                    + String(" render — the same binding with NEITHER a")
                    + String(" projection nor a filter.\n  So R7a's containment")
                    + String(" for this entry proves nothing: it would hold")
                    + String(" with the field's write DELETED, because the")
                    + String(" BINDING supplies the token. Choose a witness")
                    + String(" that this kind's path, kind_name and param map")
                    + String(" cannot contain.\n  control: ")
                    + corpus.control
                )
        if not (corpus.binding_identity in corpus.rendered[i]):
            raise Error(
                String("ScanNode AUDIT R7c (NODE REACH / INTACT) FAILED for")
                + String(" kind '")
                + kname
                + String("':\n  entry '")
                + corpus.labels[i]
                + String("' renders WITHOUT the binding's identity_hash ")
                + corpus.binding_identity
                + String(", which R4a requires of every scan. Setting a")
                + String(" projection or a filter must ADD to the render, never")
                + String(" displace the binding half of it.\n  rendered: ")
                + corpus.rendered[i]
            )
        if not (corpus.binding_structural_id in corpus.rendered[i]):
            raise Error(
                String("ScanNode AUDIT R7c (NODE REACH / INTACT) FAILED for")
                + String(" kind '")
                + kname
                + String("':\n  entry '")
                + corpus.labels[i]
                + String("' renders WITHOUT the binding's structural_id ")
                + corpus.binding_structural_id
                + String(", which R5a requires of every scan. Setting a")
                + String(" projection or a filter must ADD to the render, never")
                + String(" displace the binding half of it.\n  rendered: ")
                + corpus.rendered[i]
            )

    # -- R8: differing node fields force differing text. ----------------------
    for i in range(n):
        for j in range(i + 1, n):
            var p_differs = corpus.proj_keys[i] != corpus.proj_keys[j]
            var f_differs = corpus.filter_keys[i] != corpus.filter_keys[j]
            if not (p_differs or f_differs):
                continue
            if corpus.rendered[i] != corpus.rendered[j]:
                continue
            var which: String
            if p_differs and f_differs:
                which = String("projection AND filter")
            elif p_differs:
                which = String("projection")
            else:
                which = String("filter")
            raise Error(
                String("ScanNode AUDIT R8 (NODE SEPARATION) FAILED for kind '")
                + kname
                + String("':\n  MEASURED: entries '")
                + corpus.labels[i]
                + String("' and '")
                + corpus.labels[j]
                + String("' differ in their ")
                + which
                + String(" (")
                + corpus.proj_keys[i]
                + String(" / ")
                + corpus.filter_keys[i]
                + String("  vs  ")
                + corpus.proj_keys[j]
                + String(" / ")
                + corpus.filter_keys[j]
                + String(") and render IDENTICAL plan text.\n  So")
                + String(" `LogicalPlan.structural_hash()` is EQUAL, so")
                + String(" `factory_hash` (`var factory_hash = plan")
                + String(".structural_hash()`, engine_context.mojo) is")
                + String(" equal, so `plan_cse` and `optimizer_scan_dedup`")
                + String(" treat two different scans as one. A silent wrong")
                + String(" answer, live.\n  ATTRIBUTION IS STRUCTURAL: this")
                + String(" corpus holds ONE binding and the render takes only")
                + String(" (binding, projection, filter), so no other field")
                + String(" can be the cause — it is the scan-node field's")
                + String(" write.\n  rendered: ")
                + corpus.rendered[i]
            )
