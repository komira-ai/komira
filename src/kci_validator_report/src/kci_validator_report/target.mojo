# =============================================================================
# kci_validator_report/target.mojo — ★ WHAT WAS VALIDATED: (NAME, VERSION), and
#   the GUARD a leg holds around its rows.
# =============================================================================
#
# ⛔ EVIDENCE, NOT AUTHORIZATION — see `state.mojo`'s header.
#
# ── ★ A TARGET IS A NAME AND A VERSION ───────────────────────────────────────
# A validation record must name both the target AND its version / hash.
#
# And the consequence that has to be DESIGNED for, not bolted on: ONE RUN
# VALIDATES MULTIPLE TARGETS AT DIFFERENT VERSIONS. One wave can run many steps
# across several served services live on different digests of the same logical
# image. So there is NO top-level `target` field anywhere in this schema;
# attribution is per ROW, through `RowResult.target_index`.
#
# That is the structural fix for a stale green: steps that passed against a
# revision that no longer serves.
#
# ── ⚠ AND `version` ALONE IS NOT ENOUGH EITHER ───────────────────────────────
# A digest with no label cannot answer "what did I validate", because the three
# available sources can give three DIFFERENT answers (see `state.mojo` §2). Hence
# `version_source` is REQUIRED and closed-vocabulary, and `VERSION_SOURCE_NONE`
# REQUIRES a `version_note` — an unlabelled empty digest reads as "we did not
# look", which is exactly the claim it must not be able to make.
#
# NO deps beyond `state.mojo`. def-based, Mojo 1.0.0b2.
# =============================================================================

from kci_validator_report.state import (
    VERSION_SOURCE_LIVE_SERVING,
    VERSION_SOURCE_NONE,
    version_source_is_known,
    TARGET_KIND_SERVICE,
    TARGET_KIND_SHARED_INFRASTRUCTURE,
)


# =============================================================================
# §1 — ReportTarget — (NAME, VERSION/HASH), plus what makes the
#      version citable.
# =============================================================================
@fieldwise_init
struct ReportTarget(Copyable, Movable, Deinitable):
    """ONE thing this step validated.

      * `name`           — `ServiceSpec.name` / the bundle's logical id. The NAME.
      * `kind`           — service | web_content | probe | shared_infrastructure.
      * `version`        — the canonical digest. The VERSION/HASH.
      * `version_source` — WHERE that digest came from (closed vocabulary). ★ NOT
                           optional: the three sources can disagree.
      * `version_note`   — REQUIRED non-empty when `version_source` is `NONE`.
      * `endpoint`       — the URL actually DIALLED, which is not necessarily the
                           published one."""

    var name: String
    var kind: String
    var version: String
    var version_source: String
    var version_note: String
    var endpoint: String

    def fault(self) -> String:
        """WHY this target cannot be cited, or `""`.

        FOUR arms, each closing a way a target silently stops naming anything:

          1. NO NAME — a version with nothing to attach it to.
          2. UNKNOWN SOURCE — a label outside the closed vocabulary is a label a
             reader cannot interpret, and an uninterpretable label is worse than
             none because it LOOKS answered.
          3. `NONE` WITH NO NOTE — see the header.
          4. ★ A DIGEST WITH SOURCE `NONE`, or `NONE`-source carrying a version.
             The two contradict: either we read a version somewhere, in which
             case say where, or we did not, in which case the digest column must
             be empty."""
        if self.name.byte_length() == 0:
            return String(
                "a target with NO NAME — a version with nothing to attach it to"
                " cannot answer 'what did I validate'"
            )
        if not version_source_is_known(self.version_source):
            return (
                String("target '")
                + self.name.copy()
                + String("': version_source '")
                + self.version_source.copy()
                + String(
                    "' is outside the closed vocabulary (LIVE_SERVING |"
                    " AUTHORED_MANIFEST | STAGED_LEDGER | NONE). An"
                    " uninterpretable label is worse than an absent one: it"
                    " looks answered."
                )
            )
        if self.version_source == VERSION_SOURCE_NONE:
            if self.version_note.byte_length() == 0:
                return (
                    String("target '")
                    + self.name.copy()
                    + String(
                        "': version_source is NONE with NO version_note. An"
                        " unexplained empty digest reads as 'we did not look'."
                    )
                )
            if self.version.byte_length() > 0:
                return (
                    String("target '")
                    + self.name.copy()
                    + String(
                        "': version_source is NONE but a version is present."
                        " Either the digest was read somewhere — say where — or"
                        " it was not, and the column must be empty."
                    )
                )
            return String("")
        if self.version.byte_length() == 0:
            return (
                String("target '")
                + self.name.copy()
                + String("': version_source is ")
                + self.version_source.copy()
                + String(
                    " but the version is EMPTY. A named source that produced"
                    " nothing is a read that failed; label it NONE and state"
                    " why in version_note."
                )
            )
        return String("")


def served_target(
    var name: String, var version: String, var endpoint: String
) -> ReportTarget:
    """The common case: a SERVED service whose digest was read LIVE."""
    return ReportTarget(
        name^, String(TARGET_KIND_SERVICE), version^,
        String(VERSION_SOURCE_LIVE_SERVING), String(""), endpoint^,
    )


comptime _DIGEST_PREFIX: StaticString = "sha256:"


def digest_pinned_by(image_ref: String) -> String:
    """The `sha256:…` an image reference PINS, or `""` when it pins none.

    ⛔ THIS IS NOT `digest_of_image_ref`, AND THE DIFFERENCE IS THE WHOLE POINT.
    That helper (`komira_ci_revision`) returns a value with no `@` UNCHANGED, on
    purpose: it splits a value already KNOWN to be a digest-bearing artifact ref,
    and emptying a bare `sha256:…` there would make two different builds compare
    equal. Here the input is a LIVE READ of whatever a serving container is
    running, which is frequently `<repo>:<tag>` — and a tag is a MUTABLE POINTER,
    not a version. Passing `my-app:latest` through as the `version` of a
    LIVE_SERVING target would be precisely the invented digest `version_source`
    exists to make impossible: the record would name a "hash" that identifies a
    different image tomorrow.

    THREE SHAPES, and only two of them pin anything:
      * `<repo>@sha256:…` -> `sha256:…`   (the pinned form every applier writes)
      * `sha256:…`        -> `sha256:…`   (already narrow — a bundle-authored
                                           `image { digest: … }`)
      * anything else     -> `""`          (a tag, an empty read, a digest
                                           algorithm this function has never been
                                           taught to recognise)

    ⚠ THE `else` ARM IS DELIBERATELY CONSERVATIVE. An unrecognised algorithm
    (`sha512:…`) returns `""` and the caller renders an honest NONE naming what it
    saw, rather than this function guessing that an unfamiliar prefix is a hash.
    Widening it is a one-line change with a test; guessing is not."""
    var at = image_ref.rfind(String("@"))
    var candidate = image_ref.copy()
    if at >= 0:
        candidate = String(image_ref[byte = at + 1 :])
    if not candidate.startswith(String(_DIGEST_PREFIX)):
        return String("")
    if candidate.byte_length() <= String(_DIGEST_PREFIX).byte_length():
        # `sha256:` with nothing after it is a prefix, not a digest. An empty
        # version under a NAMED source is a `ReportTarget.fault()` — catch it
        # here, where the reason can still be stated.
        return String("")
    return candidate^


def live_serving_target(
    var name: String, var live_image_ref: String, var endpoint: String
) -> ReportTarget:
    """The SAFE `LIVE_SERVING` constructor: a target versioned by what a LIVE
    READ found this service running, or an honest NONE saying why it could not be.

    ── ★ WHY THE LIVE READ IS THE ONE THAT ANSWERS THE QUESTION ────────────────
    There are two candidate versions for a validated service and they answer
    DIFFERENT questions:

      * the deploy's MANIFEST artifact set — *what we intended to deploy*;
      * a LIVE read of the service — *what was actually serving when we
        validated*.

    Only the second can make a STALE GREEN detectable: steps that are green
    while describing a revision that no longer serves. A record built from intent is
    green in exactly the situation it exists to catch — the rollout that did not
    take — because intent is unchanged by a service that never moved.

    ⛔ IT REFUSES A TAG. `digest_pinned_by` returns `""` for `<repo>:<tag>`, and
    this then renders an `unversioned_target` NAMING the ref it saw. That is not
    a degradation: a mutable tag presented as a version/hash is worse than no
    version, because the reader cannot tell it is mutable and the record silently
    stops being true the next time that tag moves.

    ⚠ `served_target` IS THE UNSAFE SIBLING and stays that way on purpose: it
    stamps `LIVE_SERVING` on whatever version the caller hands it, which is right
    for a validator that has already resolved a digest by its own means. THIS is
    what a caller holding a RAW live image reference must use."""
    var pinned = digest_pinned_by(live_image_ref)
    if pinned.byte_length() > 0:
        return ReportTarget(
            name^,
            String(TARGET_KIND_SERVICE),
            pinned^,
            String(VERSION_SOURCE_LIVE_SERVING),
            String(""),
            endpoint^,
        )
    if live_image_ref.byte_length() == 0:
        return ReportTarget(
            name^,
            String(TARGET_KIND_SERVICE),
            String(""),
            String(VERSION_SOURCE_NONE),
            String(
                "this run took no live read of what this service is serving, so"
                " there is no version to name. A verb that applies nothing"
                " (a standalone `validate`) resolves its endpoints from what a PRIOR"
                " deploy RECORDED, and the registry records a URL, not a digest."
                " Re-run through `deploy-and-validate`, or close the gap by"
                " threading a live read into the standalone verb."
            ),
            endpoint^,
        )
    var why = String("the live read returned '")
    why += live_image_ref
    why += String(
        "', which pins no immutable digest. A `<repo>:<tag>` reference is a"
        " MUTABLE POINTER, and recording it as this target's version/hash would"
        " make the record silently false the next time that tag moves. The"
        " version is absent because it was not readable, NOT because nobody"
        " looked."
    )
    return ReportTarget(
        name^,
        String(TARGET_KIND_SERVICE),
        String(""),
        String(VERSION_SOURCE_NONE),
        why^,
        endpoint^,
    )


def unversioned_target(
    var name: String, var kind: String, var note: String
) -> ReportTarget:
    """A target with NO digest to name, and the required sentence saying why.

    The live case is `APP_KIND_SHARED_INFRASTRUCTURE` — it composes no `-svc`
    node and serves nothing, yet a validate step can name it."""
    var why = note^
    if why.byte_length() == 0:
        why = String(
            "⛔ NO REASON STATED for an absent version. State why this target has"
            " no digest, or the record cannot distinguish 'nothing to read' from"
            " 'nobody read it'."
        )
    return ReportTarget(
        name^, kind^, String(""), String(VERSION_SOURCE_NONE), why^, String(""),
    )


def shared_infrastructure_target(var name: String) -> ReportTarget:
    """`unversioned_target` with the note a shared-infrastructure app warrants,
    so validators do not each phrase it differently."""
    return unversioned_target(
        name^,
        String(TARGET_KIND_SHARED_INFRASTRUCTURE),
        String(
            "APP_KIND_SHARED_INFRASTRUCTURE — composes no -svc node and serves"
            " nothing; there is no image to name."
        ),
    )


# =============================================================================
# §2 — ReportGuard — a precondition the leg held (or did not) AROUND its rows.
# =============================================================================
@fieldwise_init
struct ReportGuard(Copyable, Movable, Deinitable):
    """A leg-level precondition.

    ⛔ A GUARD WITH `held = False` AND A BLANK REASON IS A BROKEN GUARD, not a
    broken subject: it reds the run and says nothing about why, which is the
    fail-quiet shape one altitude up from a row. `guard_broken` refuses one."""

    var name: String
    var held: Bool
    var reason: String

    def fault(self) -> String:
        """WHY this guard cannot be read, or `""`."""
        if self.name.byte_length() == 0:
            return String("a guard with NO NAME")
        if not self.held and self.reason.byte_length() == 0:
            return (
                String("guard '")
                + self.name.copy()
                + String(
                    "' is BROKEN with no stated reason. A guard that reds a run"
                    " without saying why is the fail-quiet shape one altitude up"
                    " from a row."
                )
            )
        return String("")


def guard_held(var name: String) -> ReportGuard:
    """A guard that HELD. No reason required — "it held" is the whole claim."""
    return ReportGuard(name^, True, String(""))


def guard_broken(var name: String, var reason: String) -> ReportGuard:
    """A guard that did NOT hold. REFUSES a blank reason by substituting the
    fault sentence — the guard stays broken either way, so the refusal costs the
    verdict nothing and buys the record the one thing it is for."""
    var why = reason^
    if why.byte_length() == 0:
        why = String(
            "⛔ NO REASON STATED. A broken guard reds the run; name the"
            " precondition that failed."
        )
    return ReportGuard(name^, False, why^)


def targets_fault(targets: List[ReportTarget]) -> String:
    """The FIRST reason this target list cannot be cited, or `""`.

    ⛔ AN EMPTY LIST IS A FAULT. A step that names no target produced a record
    that cannot answer "what did I validate" — and "which target?" unanswered is
    exactly the state of a stale green."""
    if len(targets) == 0:
        return String(
            "NO TARGETS. A validation record that names no (target, version)"
            " cannot say what it validated — the defect this schema exists to"
            " close."
        )
    for i in range(len(targets)):
        var f = targets[i].fault()
        if f.byte_length() > 0:
            return String("targets[") + String(i) + String("]: ") + f^
    for i in range(len(targets)):
        for j in range(i + 1, len(targets)):
            if targets[i].name == targets[j].name:
                return (
                    String("DUPLICATE target name '")
                    + targets[i].name.copy()
                    + String("' at indices ")
                    + String(i)
                    + String(" and ")
                    + String(j)
                    + String(
                        " — a row's target_index would then be ambiguous about"
                        " which version it validated against."
                    )
                )
    return String("")


def guards_fault(guards: List[ReportGuard]) -> String:
    """The FIRST reason this guard list cannot be read, or `""`. An EMPTY guard
    list is legal — a leg may hold no preconditions."""
    for i in range(len(guards)):
        var f = guards[i].fault()
        if f.byte_length() > 0:
            return String("guards[") + String(i) + String("]: ") + f^
    return String("")
