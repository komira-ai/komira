# =============================================================================
# kci_deploy_compose/unpinned_plan.mojo — THE NO-SPEND DRY RUN: what an
#   UNPINNED `from_build` ref becomes when a `plan` is allowed to compose over
#   it, and the sink that makes every such substitution VISIBLE.
# =============================================================================
#
# ── THE PROBLEM ─────────────────────────────────────────────────────────────
#
#   kci <app> plan --env <env>
#     -> rc=2  "kci: unresolved build ref 'probe_a' — direct plan/apply
#               requires a pinned digest"
#
# The refusal is the mapper's per-service `from_build` guardrail and it is
# CORRECT for an APPLY: shipping the literal string `from_build:<name>` as a
# container image reference creates a service that can never pull. But `plan`
# shares that mapper, and `plan` mutates nothing — so a release machine whose
# images have never been built or staged could not be COMPOSED AT ALL, and the
# first honest signal about whether its wiring was right would arrive MID-APPLY,
# against a live cloud account, after billable resources existed.
#
# THE ANSWER IS NOT A FAKE DIGEST. A plan that invents a `sha256:…` reports a
#    graph nobody can apply, and the invented value is one copy-paste away from a
#    bundle. The substitution below is deliberately NOT DIGEST-SHAPED and NAMES
#    the ref it stands in for, so it is unusable as a pin and self-describing in
#    a rendered diff:
#
#        image: UNPINNED-NOT-A-DIGEST:probe_a
#
# AND A TOLERATED SUBSTITUTION MUST NEVER BE A SILENT ONE. Every substitution
#    is recorded into an `UnpinnedRefAccumulator` the CALLER owns, and the mapper
#    REFUSES to tolerate anything when no sink was threaded — because tolerance
#    with nowhere to report it is precisely the "plan silently succeeded with a
#    placeholder" failure this file exists to prevent. The accumulator is what
#    lets `kci plan` exit with its distinct unpinned code instead of 0/1, so an
#    unpinned plan cannot be mistaken for an apply-ready one by a human reading
#    the output OR by a script reading `$?`.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────────────
# Pure leaf: values in, a value out. No I/O, no cloud, no proto, no reporter, no
# `fn main`. ZERO `UnsafePointer`; the shared interior rides an `ArcPointer`, the
# `EdgeOutcomeAccumulator` shape verbatim (single-threaded synchronous map).
# =============================================================================

from std.memory import ArcPointer


# =============================================================================
# §1 — THE SUBSTITUTION.
# =============================================================================
comptime UNPINNED_PLAN_DIGEST_PREFIX: String = "UNPINNED-NOT-A-DIGEST:"
"""The prefix a `plan --allow-unpinned` puts in place of a digest that no build
and no stage has ever produced.

IT IS SHAPED SO THAT IT CANNOT BE MISTAKEN FOR A PIN, IN BOTH DIRECTIONS.
It does not start with `sha256:` or `content-sha256:` — the two prefixes every
pinned artifact carries — so no reader that keys on those sees it as
one; and it is not hex, not 64 characters, and says NOT-A-DIGEST in words, so a
human who copies it into an `image { digest: … }` block gets a refusal rather
than a deploy of something that does not exist.

IT IS NOT THE REAP SENTINEL AND MUST NOT BE UNIFIED WITH IT. The mapper's reap
sentinel digest is `sha256:reap-sentinel-…` and is deliberately
digest-PREFIXED, because a destroy addresses resources by identity and never
renders the value at all. A plan DOES render it, into a diff a human reads and
decides on, so the two have opposite requirements."""


def unpinned_plan_digest(build_ref: String) -> String:
    """The placeholder that stands in for `build_ref` during an explicitly
    unpinned plan — `UNPINNED-NOT-A-DIGEST:<ref>`.

    THE PARAMETER IS `build_ref`, NOT `ref`: `ref` is a Mojo keyword (the
    borrow-with-an-origin spelling) and will not parse as an identifier.

    THE REF RIDES IN THE VALUE, NOT JUST IN A LOG LINE. A rendered graph is
    the artifact an operator reviews; a placeholder that said only "unpinned"
    would leave them unable to tell WHICH of a multi-service bundle's images is
    missing without cross-referencing a second output."""
    return UNPINNED_PLAN_DIGEST_PREFIX + build_ref


def is_unpinned_plan_digest(value: String) -> Bool:
    """True iff `value` is a placeholder this module produced — the predicate any
    consumer that must refuse to act on one keys off, instead of re-spelling the
    prefix and drifting from it."""
    return value.startswith(UNPINNED_PLAN_DIGEST_PREFIX)


# =============================================================================
# §2 — THE RECORD. WHAT was left unpinned, and on WHICH node.
# =============================================================================
comptime UNPINNED_KIND_SERVICE: String = "ServerlessCompute"
"""A served container's `image_digest` (mapper arm 1, the per-service guard)."""

comptime UNPINNED_KIND_JOB: String = "RunToCompletionJob"
"""A run-to-completion job's `image_digest` (mapper arm 2)."""

comptime UNPINNED_KIND_WEB_CONTENT: String = "WebFrontend content"
"""A static front end's `content_digest` (mapper arm 3). Named "content" because
its pinned form is `content-sha256:…`, not an OCI digest — an operator told
"unpinned image" about a `dist/` tree looks for the wrong build."""


struct _UnpinnedRow(Copyable, Movable, Deinitable):
    """One substitution: the artifact CLASS, the node it was made on, and the
    build ref that was never resolved. Flat value POD."""

    var kind: String
    var logical_id: String
    var build_ref: String

    def __init__(
        out self,
        var kind: String,
        var logical_id: String,
        var build_ref: String,
    ):
        self.kind = kind^
        self.logical_id = logical_id^
        self.build_ref = build_ref^

    def render(self) -> String:
        """The operator-facing line for this row.

        A READABLE ROW, NOT A COUNT AND NOT A BOOL. "3 unpinned refs" tells an
        operator that something is missing and nothing about what to go build."""
        return (
            self.kind
            + String(" node '")
            + self.logical_id
            + String("' -> from_build: '")
            + self.build_ref
            + String("' (rendered as ")
            + unpinned_plan_digest(self.build_ref)
            + String(")")
        )


struct _UnpinnedState(Movable):
    """The accumulator interior — the substitutions in first-recorded order (the
    mapper's own deterministic node order). A typed List of flat Strings, no
    wildcard origin, no byte slab."""

    var rows: List[_UnpinnedRow]

    def __init__(out self):
        self.rows = List[_UnpinnedRow]()


struct UnpinnedRefAccumulator(Movable, Deinitable):
    """The shared sink the mapper records every unpinned-ref substitution into,
    and the CLI reads afterwards to decide the plan's exit code.

    ITS PRESENCE IS THE PRICE OF THE TOLERANCE, NOT A CONVENIENCE. The mapper
    raises if asked to tolerate unpinned refs with no sink threaded: a placeholder
    that reaches a rendered graph and is recorded NOWHERE is exactly the silent
    fake-digest plan this whole mechanism refuses to produce. See
    `map_manifest_to_graph`'s `allow_unpinned_refs` parameter.

    THE HANDLE IS SHARED, NOT COPIED. The caller constructs one, `share()`s it
    into the driver, and reads its own handle back after the map returns — the
    `EdgeOutcomeAccumulator` pattern verbatim, for the same reason: the writer is
    several frames below the reader and the value has to survive the return.
    SAFETY: `ArcPointer` ref-counted shared ownership over a single-threaded
    synchronous map; no concurrent writer exists on this path."""

    var _p: ArcPointer[_UnpinnedState]

    def __init__(out self):
        self._p = ArcPointer[_UnpinnedState](_UnpinnedState())

    def __init__(out self, *, var _share: ArcPointer[_UnpinnedState]):
        self._p = _share^

    def share(self) -> UnpinnedRefAccumulator:
        """A SECOND handle over ONE `_UnpinnedState`."""
        return UnpinnedRefAccumulator(
            _share=ArcPointer[_UnpinnedState](copy=self._p)
        )

    def record(
        mut self, kind: String, logical_id: String, build_ref: String
    ):
        """Record one substitution. Idempotent per (kind, logical_id): a
        re-record overwrites in place, so a node visited twice by a future mapper
        pass cannot inflate the count an operator reads.

        AN EMPTY `build_ref` IS STILL RECORDED. Unlike `EdgeOutcomeAccumulator`, the
        empty case here is not a pre-convergence window that will fill in later —
        it is a manifest carrying the bare marker with no name after it, which is
        a real defect the plan must surface rather than drop."""
        for i in range(len(self._p[].rows)):
            if (
                self._p[].rows[i].kind == kind
                and self._p[].rows[i].logical_id == logical_id
            ):
                self._p[].rows[i].build_ref = build_ref.copy()
                return
        self._p[].rows.append(
            _UnpinnedRow(kind.copy(), logical_id.copy(), build_ref.copy())
        )

    def count(self) -> Int:
        """How many substitutions were made. ZERO is the ordinary answer and is
        what makes `--allow-unpinned` a no-op on a fully pinned bundle."""
        return len(self._p[].rows)

    def refs(self) -> List[String]:
        """The build refs that were left unpinned, in first-recorded order,
        WITHOUT their node context — for a caller that needs the bare names (the
        `build {}` targets an operator would go run)."""
        var out = List[String]()
        for i in range(len(self._p[].rows)):
            out.append(self._p[].rows[i].build_ref.copy())
        return out^

    def rendered_rows(self) -> List[String]:
        """One human-readable line per substitution, in first-recorded order —
        the value `kci plan` carries into its plan verdict and prints.

        RENDERED HERE, NOT AT THE PRINTER. The plan-verdict module is a pure
        leaf with one dependency (the bundle proto) and must not acquire this
        package; handing it finished lines keeps the exit-code decision free of
        the composer tier while still giving the operator the whole record."""
        var out = List[String]()
        for i in range(len(self._p[].rows)):
            out.append(self._p[].rows[i].render())
        return out^
