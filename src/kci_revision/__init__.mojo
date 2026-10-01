# =============================================================================
# kci_revision — THE REVISION SUBSTRATE:
#   `kci <app> build` MINTS a per-app monotonic revision id and every
#   downstream verb takes `--revision <id>`, never a hand-copied sha256 digest.
# =============================================================================
#
# ── WHAT A REVISION IS ───────────────────────────────────────────────────────
# A revision is a version-set record: ONE immutable binding from a revision id
# to the full set of artifact references a build produced, kept in a store.
#
# The store is the object store, not a database table, and that is the
# requirement rather than a shortcut: kci is an open-source deploy CLI, so
# MINTING and RESOLVING a revision must work with no hosted account and no
# database. The only thing a revision needs is a bucket (or a directory —
# `LocalFsConditionalStore` conforms to the same trait), which is why this file
# is generic over `Store: ConditionalWriteStore` and names no cloud.
#
# ── WHY THE ARTIFACT SET, NOT JUST THE SERVICE DIGEST ────────────────────────
# A validator/probe image is resolved at RUN time, by NAME:TAG, so a release
# that owns its service images but not its validator images can run a probe
# that asserts the OLD contract and exits 0 — a FALSE GREEN. A revision that
# names the service image but NOT the probe image it was gated by reproduces
# exactly that hole in the release record. So a `RevisionRecord` holds the FULL
# set: the service image, any web content, AND every gate/probe image from the
# same build.
#
# ── THE ALLOCATOR (the only genuinely subtle part) ───────────────────────────
# THE RECORD KEY'S CREATE-IF-ABSENT *IS* THE ALLOCATOR. `HEAD` is a derived
# monotone-max cache and NEVER the source of truth. On a create-412 we PROBE
# FORWARD (n+1) and deliberately DO NOT re-read HEAD — re-reading HEAD is the
# spin bug, because the winner may not have advanced HEAD yet, so a loser that
# re-derives n from HEAD recomputes the SAME ordinal forever. Probing forward
# terminates in at most (number of concurrent minters) attempts.
#
# The CAS shape is a monotonic pointer advance with an explicit loser branch,
# NOT a last-writer-wins registration with a retry-once-then-RAISE budget. That
# second shape is right for a registry whose entries carry no ordering contract
# (a service URL has none); for an allocator it would fail one of two concurrent
# builds. An ordinal has the opposite contract.
#
# A lost HEAD CAS is NOT an error: the record is already durable, and HEAD is
# monotone-max either way, so the mint succeeds and HEAD converges.
#
# TWO ROBUSTNESS PROPERTIES FOLLOW FROM "HEAD IS ONLY A CACHE", and each is
# pinned by a test:
#
#   * A LOSING MINTER MUST TOLERATE AN UNREADABLE WINNER. Create-if-absent does
#     not have to publish the KEY and the BODY at the same instant —
#     `LocalFsConditionalStore` creates `O_EXCL` and writes AFTER — so a 412'd
#     minter can `get` the winner's key and receive zero/partial bytes. That is
#     a TAKEN ordinal, not a fault: probe forward (`_read_slot_tolerant`). The
#     operator-facing `resolve` stays fail-loud on the same bytes.
#   * LOSING HEAD MUST BE RECOVERABLE. If HEAD is a cache, its loss cannot be
#     terminal. The floor comes from the store itself when HEAD is unusable
#     (`_recover_floor_ordinal`, one LIST), because restarting at ordinal 1 with
#     a 64-probe ceiling permanently bricks any app past 64 revisions.
#
# ── ONE SOURCE OF TRUTH FOR THE ORDINAL ──────────────────────────────────────
# `ordinal` is STORED in the record and VALIDATED against `revision_id` on
# decode — it is never silently re-derived by a reader (a reader that
# re-derives an identity from a formatted string is the drift shape). And
# `ordinal_of` requires the caller's `app_id`, which the reader always knows
# from the key path, rather than an `rfind("-r")` heuristic: app ids contain
# hyphens (`orders-coordinator`) and a heuristic gets those wrong.
#
# Encapsulation: ZERO UnsafePointer in any signature, zero wildcard origins,
# zero FFI. The `Store` is a moved-in generic value; the record is flat Strings
# + Int64 plus one level of `List` of flat-String structs (a typed List, not a
# byte slab). Mojo 1.0 (def-only).
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from komira_serde import JsonValue, parse_json_value


# =============================================================================
# §0 — the constants (the wire + key-layout contract).
# =============================================================================

comptime REVISION_REGISTRY_PREFIX: String = "revisions"
"""The key prefix every revision object lives under, sibling to the service
registry's `service` prefix and the staging ledgers' `staged-image` /
`staged-content` prefixes in the SAME bucket (distinct prefixes, so the ledgers
can never collide)."""

comptime REVISION_SCHEMA: String = "kci.revision.v1"
"""The record's stability token. Additive fields may appear WITHOUT a bump; a
removal or a retype bumps it."""

comptime REVISION_HEAD_KEY: String = "HEAD"
"""The per-app monotone-max pointer object. Cannot collide with a revision id:
an id always contains `-r<digits>`."""

comptime REVISION_ORDINAL_SEP: String = "-r"
"""`<app_id>-r<N>` — the id format.

⚠ THIS ORDINAL IS **NOT** A RELEASE CHANNEL'S VERSION ORDINAL, and must not be
stamped into one: `publish` puts the revision id in the channel's version LABEL
only. A channel's version ordinal is a per-CHANNEL DENSE sequence, which is what
makes "releases behind" computable by subtraction. THIS ordinal is per-APP and
therefore SPARSE on any channel that receives only some builds (one channel
publishes every build r14…r20; another receives r14 and r20), so a consumer
exactly ONE release behind would compute 20−14 = 6 behind, permanently, with no
threshold that tunes it out."""

comptime MINT_MAX_PROBES: Int = 64
"""Probe-forward bound. One probe is burned per CONCURRENT minter that beat us
to an ordinal, so 64 is astronomically past any real build fan-out.

It bounds CONCURRENCY, never HISTORY: the starting ordinal comes from HEAD or,
when HEAD is unusable, from `_recover_floor_ordinal`'s LIST of the prefix. That
distinction is load-bearing — while a lost HEAD restarted probing at 1, this
constant silently doubled as a cap on how many revisions an app could ever have
before a lost HEAD bricked minting forever."""

comptime HEAD_CAS_MAX_ATTEMPTS: Int = 5
"""HEAD-advance CAS budget. Exhausting it is NOT a mint failure — see
`_advance_head`. Reused by `_record_reproduction`, which makes the same
lost-race-is-not-an-error call for the same reason."""

comptime MAX_REPRODUCED_COMMITS: Int = 64
"""How many reproducing commits one record may name — see
`RevisionRecord.reproduced_at`.

The field grows by one per rebuild-at-a-new-commit of an artifact set that has
not changed, so on a stable component (one that has not changed in weeks while
the trunk moves dozens of commits a day) it would otherwise grow without limit
on a record an operator is expected to read.

64 is not a correctness boundary and nothing depends on the exact value. It
bounds only how many commits the provenance notice lists, and hitting it costs
nothing but a shorter report."""

comptime REVISION_ROLE_SERVICE: String = "service"
comptime REVISION_ROLE_WEB_CONTENT: String = "web_content"
comptime REVISION_ROLE_PROBE: String = "probe"


# =============================================================================
# §1 — the value types (pure, transport-free, hermetically testable).
# =============================================================================


@fieldwise_init
struct RevisionArtifact(Copyable, Movable, Deinitable):
    """ONE artifact in a revision.

    Field layout (flat Strings only):
      var logical_id: String — the manifest node `logical_id` for a service /
                               web artifact, or the `validate.run_container.
                               image.from_build` NAME for a probe. This is the
                               `{logical_id -> sha256:…}` key.
      var role: String       — `service` | `web_content` | `probe`.
      var digest: String     — `sha256:…` (image) or `content-sha256:…` (web).
      var image_ref: String  — the FULL pullable ref (`<repo>@sha256:…`), or ""
                               when the artifact has no ref form (web content).

    `image_ref` is deliberately EXCLUDED from artifact-set equality (see
    `artifacts_equal`): it is a rendering of `digest` + a repo, and a registry
    rename must not mint a phantom revision."""

    var logical_id: String
    var role: String
    var digest: String
    var image_ref: String


# ---------------------------------------------------------------------------
# THE SPLIT. Both feeders into a revision receive ONE string from the build seam
# and must fill TWO fields from it. These are the two halves, defined ONCE here —
# next to the field contract they implement — so `collect_artifact_set` (the
# manifest-node feeder in kci's deploy driver) and
# `build_validate_probe_artifacts` (the probe feeder in kci's validator image
# build) cannot disagree about which half goes where.
#
# A feeder that assigns the resolver's return straight into `.digest` with
# `image_ref=""` inverts this struct's documented layout, which makes
# `publish --revision` structurally impossible and inverts the phantom-revision
# invariant for the only class where the repo is actually present.
def digest_of_image_ref(image_ref: String) -> String:
    """`<repo>@sha256:…` -> `sha256:…`; a value with no `@` passes through.

    The `BuildResolver` contract (`parse_pushed_digest`) is a FULL pullable by-digest
    ref, so a revision record stores BOTH: the ref (what a puller needs) and the bare
    digest (what artifact-set EQUALITY compares on, so a registry move is not a new
    revision — and what `publish`/`stage` require, since both refuse a `from_digest`
    that is not `sha256:`-prefixed).

    A value with no `@` is returned UNCHANGED rather than emptied: a bundle that
    authored `image { digest: "sha256:…" }` directly is already in the narrow form,
    and an empty digest would silently make two different builds compare equal."""
    var at = image_ref.rfind(String("@"))
    if at < 0:
        return image_ref.copy()
    return String(image_ref[byte = at + 1 :])


def pullable_ref_of(image_value: String) -> String:
    """The `image_ref` half of the same split: `image_value` when it is a full
    `<repo>@…` ref, `""` when it carries no repo.

    "" is the honest answer for a bare digest — `RevisionArtifact.image_ref`'s
    contract is "the FULL pullable ref, or "" when the artifact has no ref form", and
    fabricating a repo around a bare digest would be a second, unverified rendering
    (the shape that prints the repo twice). The `@` test is the same one
    `digest_of_image_ref` splits on, so the two halves cannot disagree about which
    shape they were handed."""
    if image_value.rfind(String("@")) < 0:
        return String("")
    return image_value.copy()


def _commits_name_the_same(a: String, b: String) -> Bool:
    """True iff two git SHAs name the same commit, allowing one to be an ABBREVIATION
    of the other.

    ⚠ DEFINED HERE RATHER THAN IMPORTED. The property this file enforces — the
    bytes you deploy came from a commit that can be named — is a property of the
    artifact, and must not acquire a dependency on any mechanism for establishing
    that a commit was tested. Which commit produced the bytes outlives any
    particular answer to "was that commit tested", so this file keeps its own
    comparison.

    An EMPTY value never matches, including against another empty: "" means "could not
    resolve a commit", and two failures to resolve are not an agreement.

    ⚠ DEFINED ABOVE `RevisionRecord` because `was_built_at` calls it."""
    if a.byte_length() == 0 or b.byte_length() == 0:
        return False
    if a == b:
        return True
    if a.byte_length() < b.byte_length():
        return b.startswith(a)
    return a.startswith(b)


struct RevisionRecord(Copyable, Movable, Deinitable):
    """The release record stored at `revisions/<app_id>/<revision_id>`.

    Field layout:
      var schema: String      — `REVISION_SCHEMA`; the stability token.
      var app_id: String      — == `bundle.name` (the bundle's single
                                load-bearing id).
      var revision_id: String — `<app_id>-r<N>`.
      var ordinal: Int64      — N. STORED, not re-derived (see the header).
      var git_commit: String  — the short SHA the build was tagged with. Under
                                artifact-set REUSE this stays the FIRST commit
                                that produced these bytes; `build` prints both
                                rather than hiding the difference.
      var built_at_us: Int64  — epoch micros of that FIRST build.
      var bundle_name: String — provenance; == app_id today, may diverge.
      var artifacts: List[RevisionArtifact] — >= 1, sorted by (logical_id, role).
      var reproduced_at: List[String] — every OTHER commit at which a build was
                                RUN and OBSERVED to produce this exact artifact
                                set. APPEND-ONLY. See below.

    ★ THE ONE MUTABLE FIELD, AND WHY IT IS NOT A HOLE.

    Everything above `reproduced_at` is immutable, and `reproduced_at` is
    append-only: a commit enters it in exactly one place — `RevisionStore.mint`,
    inside the branch where a build's freshly-resolved artifact digests just
    compared EQUAL to this record's. It is therefore not a claim anyone makes
    about the bytes; it is a MEASUREMENT the builder recorded at the moment it
    made it. Nothing at deploy time can add to it, and there is no flag,
    environment variable or file that injects a commit into it.

    That distinction is the whole design. The alternative shapes both fail:
      * RE-STAMPING `git_commit` on a reproducing rebuild destroys the answer to
        "when was this release first cut", and makes an immutable record mutable
        in the one field every provenance question reads.
      * ADMITTING at deploy time on a "the rebuild was byte-identical" assertion
        moves the evidence to the party being gated. A stricter reader of a file
        the gated party writes is a formality, not evidence.

    ⚠ WHAT IT IS FOR. It does not admit a deploy: the provenance check does not
    compare against the operator's working tree (`check_revision_provenance`).
    It is load-bearing for a narrower property: a record whose `git_commit` is
    empty but which names a reproduction is still TRACEABLE, and the provenance
    notice reports the full set. Do not delete it as dead — and do not build a
    working-tree gate around it.

    WHAT IT CANNOT DO. It cannot admit bytes nobody can trace: every member is a
    commit at which this exact artifact set was BUILT, so each one independently
    answers "where did these bytes come from"."""

    var schema: String
    var app_id: String
    var revision_id: String
    var ordinal: Int64
    var git_commit: String
    var built_at_us: Int64
    var bundle_name: String
    var artifacts: List[RevisionArtifact]
    var reproduced_at: List[String]

    def __init__(
        out self,
        var schema: String,
        var app_id: String,
        var revision_id: String,
        ordinal: Int64,
        var git_commit: String,
        built_at_us: Int64,
        var bundle_name: String,
        var artifacts: List[RevisionArtifact],
        var reproduced_at: List[String] = List[String](),
    ):
        """⚠ `reproduced_at` IS DEFAULTED AND THAT IS SAFE — note the asymmetry
        with `RevisionExpectation.of`'s `deploy_commit`, which is deliberately
        NOT defaulted. A forgotten `deploy_commit` would make the provenance
        check PASS (degrade to a no-op); a forgotten `reproduced_at` makes it
        STRICTER, since an empty set admits nothing extra. The default fails
        CLOSED, so it cannot hide a caller that dropped it."""
        self.schema = schema^
        self.app_id = app_id^
        self.revision_id = revision_id^
        self.ordinal = ordinal
        self.git_commit = git_commit^
        self.built_at_us = built_at_us
        self.bundle_name = bundle_name^
        self.artifacts = artifacts^
        self.reproduced_at = reproduced_at^

    def was_built_at(self, commit: String) -> Bool:
        """True iff `commit` names a commit at which these exact bytes were
        built — the original build, or any recorded reproduction.

        This is the record's own answer to "did these bytes come from this
        commit"; the deploy gate asks it rather than comparing `git_commit`
        directly, so there is one definition of the property and not two."""
        if _commits_name_the_same(self.git_commit, commit):
            return True
        for i in range(len(self.reproduced_at)):
            if _commits_name_the_same(String(self.reproduced_at[i]), commit):
                return True
        return False

    def artifact_digest(self, logical_id: String) raises -> String:
        """The digest of the artifact named `logical_id`. Fail-loud on absence —
        a caller that asks for an artifact this revision does not name has a
        wrong expectation, and returning "" would let it degrade to `:latest`."""
        for i in range(len(self.artifacts)):
            if self.artifacts[i].logical_id == logical_id:
                return self.artifacts[i].digest.copy()
        raise Error(
            String("kci revision: '")
            + self.revision_id
            + String("' names no artifact '")
            + logical_id
            + String("' (it has ")
            + String(len(self.artifacts))
            + String(": ")
            + self.artifact_ids()
            + String(")")
        )

    def artifact_ids(self) -> String:
        """A comma-joined render of this record's artifact logical ids (for the
        fail-loud messages — an operator must be told what IS there)."""
        var out = String("")
        for i in range(len(self.artifacts)):
            if i > 0:
                out += String(", ")
            out += self.artifacts[i].logical_id
        return out^

    def service_digest(self) raises -> String:
        """The FIRST `service`-role artifact's digest — what `publish` / `stage`
        pin as their `from_digest`. Fail-loud when a revision carries no service
        image (a probe-only record is not publishable, and silently publishing
        `:latest` instead is the fail-quiet shape this substrate exists to
        remove)."""
        for i in range(len(self.artifacts)):
            if self.artifacts[i].role == REVISION_ROLE_SERVICE:
                return self.artifacts[i].digest.copy()
        raise Error(
            String("kci revision: '")
            + self.revision_id
            + String(
                "' carries no `service`-role artifact — there is nothing to"
                " publish/stage from it (artifacts: "
            )
            + self.artifact_ids()
            + String(")")
        )


def sole_service_digest(rec: RevisionRecord) raises -> String:
    """The digest of the record's ONE service artifact — what `publish` and `stage`
    pin as their `from_digest`. RAISES on all three ways that can go wrong.

    ★ WHY THIS EXISTS RATHER THAN `service_digest()`. That method returns the FIRST
    `service`-role artifact and is honest about it, but nothing above it guarded
    `>= 2`. A bundle with two ServerlessCompute nodes (`api` and `worker`) would
    publish ONE OF THEM, chosen by artifact sort order, and EXIT 0 — a wrong-artifact
    release that reports success. `publish` / `stage` are single-image by
    construction today (one `app_id = bundle.name`, one `from_digest`), so refusing
    the ambiguous case is a strict TIGHTENING that rejects no working invocation; it
    just stops the silent pick. The error names BOTH candidates, because an operator
    cannot fix an ambiguity they cannot see.

    ★ AND WHY THE `sha256:` CHECK IS HERE. Both `run_publish_stage` and
    `channel_image_ref` hard-reject a `from_digest` that is not `sha256:`-prefixed.
    Catching it at the RECORD names the cause — "revision shop-r14's service
    artifact 'shop-svc' carries content-sha256:…" — instead of surfacing six frames
    down as a registry-path error, which is where a field inversion in a feeder
    would otherwise surface.

    Zero service artifacts stays `service_digest()`'s own fail-loud message: a
    probe-only revision is not publishable."""
    var found = -1
    var second = -1
    for i in range(len(rec.artifacts)):
        if rec.artifacts[i].role == REVISION_ROLE_SERVICE:
            if found < 0:
                found = i
            else:
                second = i
                break
    if found < 0:
        # Delegate so the "nothing to publish" wording lives in ONE place.
        return rec.service_digest()
    if second >= 0:
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String("' carries ")
            + String(_count_service_artifacts(rec))
            + String(
                " `service`-role artifacts, and publish/stage promote exactly ONE"
                " image (keyed on one app id) — picking the first would ship the"
                " wrong one and exit 0. Candidates: "
            )
            + _service_artifact_ids(rec)
            + String(
                ". Split the bundle, or give the promotion a per-artifact selector"
                " (which this surface deliberately does not have)."
            )
        )
    var digest = rec.artifacts[found].digest.copy()
    if not digest.startswith(String("sha256:")):
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String("' service artifact '")
            + rec.artifacts[found].logical_id
            + String("' has digest '")
            + digest
            + String(
                "', which is not a `sha256:` image digest. publish/stage copy an OCI"
                " image BY DIGEST and both reject any other scheme; a"
                " `content-sha256:` value here means the artifact was recorded with"
                " the wrong role (web content is not a service image)."
            )
        )
    return digest^


def sole_web_content_digest(rec: RevisionRecord) raises -> String:
    """The digest of the record's ONE `web_content` artifact — what a CONTENT-ONLY
    revision names. A static-frontend bundle's `build` mints exactly that shape: web
    content plus its validate probes, and NO `service` artifact, so
    `sole_service_digest` has nothing to return for it.

    RAISES on the same three failures as `sole_service_digest`, for the same reasons:
    zero (nothing to assert), two or more (a first-match would assert the wrong
    artifact and exit 0), and a digest that is not a `content-sha256:` address (the
    artifact was recorded under the wrong role; name it at the record, not six
    frames down)."""
    var found = -1
    var count = 0
    for i in range(len(rec.artifacts)):
        if rec.artifacts[i].role == REVISION_ROLE_WEB_CONTENT:
            count += 1
            if found < 0:
                found = i
    if count == 0:
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String(
                "' carries neither a `service` nor a `web_content` artifact —"
                " there is nothing a deploy could assert it against (artifacts: "
            )
            + rec.artifact_ids()
            + String(")")
        )
    if count >= 2:
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String("' carries ")
            + String(count)
            + String(
                " `web_content` artifacts; a deploy asserts exactly ONE, and"
                " picking the first would assert the wrong one and exit 0"
                " (artifacts: "
            )
            + rec.artifact_ids()
            + String(")")
        )
    var digest = rec.artifacts[found].digest.copy()
    if not digest.startswith(String("content-sha256:")):
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String("' web_content artifact '")
            + rec.artifacts[found].logical_id
            + String("' has digest '")
            + digest
            + String(
                "', which is not a `content-sha256:` content address. The"
                " artifact was recorded with the wrong role."
            )
        )
    return digest^


# =============================================================================
# §2a — THE PER-SERVICE SELECTOR — what a MULTI-SERVICE revision publishes,
#       WITHOUT reintroducing the silent pick.
# =============================================================================
#
# ── THE BLOCKER ─────────────────────────────────────────────────────────────
# `sole_service_digest` above RAISES on >= 2 `service`-role artifacts, and it is
# RIGHT to: a bundle with two ServerlessCompute nodes would otherwise publish ONE
# OF THEM, chosen by artifact sort order, and EXIT 0. A bundle with several
# services therefore could not be staged through it at all.
#
# ⛔ AND THE FIX IS NOT "TAKE THEM ALL", EITHER. `sole_service_digest` guards TWO
# distinct things and only one of them is the arity:
#   * ARITY — "which of the N do I publish?" That question has an answer: the
#     one the CALLER NAMES. `service_digest_for(rec, "api")` is not a pick,
#     it is a lookup.
#   * AMBIGUITY — TWO artifacts resolving to the SAME service name. That has no
#     answer, and it is the original defect exactly. It stays a refusal.
# A blanket "return every service artifact's first match" satisfies the arity and
# silently re-creates the ambiguity, which is why the selector below raises on a
# duplicate name rather than returning the first.
#
# ── ★ THE LEDGER KEY IS THE SERVICE, AND THE READ SIDE ALREADY SAYS SO ──────
# `staged-image/<app>` was singular because a bundle had one image. It is keyed
# by SERVICE — `staged-image/<service>` — and that is not a new convention:
#
#   * `kci_staged_ref_resolver.prefer_env_local_staged_refs` resolves PER NODE,
#     on `_strip_svc_suffix(node.logical_id)` — i.e. on the SERVICE name. The
#     reader keys per-service.
#   * `service/<svc.name>` (the peer-URL registry kci writes after converge) is
#     flat per-service in the same bucket, and `staged-image/<probe>` is flat
#     per-probe in the same prefix. Both are the same shape.
#   * SINGLE-SERVICE BUNDLES ARE BYTE-IDENTICAL, BY DERIVATION AND NOT BY A
#     SPECIAL CASE. The bundle composer synthesizes the lone service with
#     `name = bundle.name`, so its node is `<bundle.name>-svc` and its service
#     name IS the app id. Every existing ledger entry keeps its key and there is
#     no migration.
#
# ⚠ WHY FLAT AND NOT `staged-image/<app>/<service>`. The nested form would
# require threading the app id into a read pass that does not have it and does
# not need it: two apps cannot own two services of the same name, because a
# service name is a serverless service name in one project. Flat is what the
# reader already does, what the two sibling ledgers already do, and what makes
# the single-service case a no-op.
# =============================================================================

comptime SERVICE_NODE_SUFFIX: String = "-svc"
"""The ServerlessCompute node's logical-id suffix (the bundle composer derives
every service's served node id as `<svc.name>-svc`).

⚠ MIRRORED, deliberately, in kci's manifest mapper and in
`kci_staged_ref_resolver._SVC_SUFFIX`. `service_name_of` below and the
resolver's `_strip_svc_suffix` must remain the SAME inverse: the writer keys the
ledger with one and the reader looks it up with the other, so a divergence is a
deploy that stages an image nothing ever reads."""


def service_name_of(logical_id: String) -> String:
    """The SERVICE name behind a `service`-role artifact's `logical_id` — which is
    the ServerlessCompute node id `<service>-svc`. This is the ledger key `stage`
    records under and the deploy's staged-ref resolver reads back.

    A logical_id that does not end in `-svc` (or is exactly `-svc`) is returned
    VERBATIM — byte-for-byte `kci_staged_ref_resolver._strip_svc_suffix`, on
    purpose. These two are inverses of each other across a durable ledger, so
    "what does the odd shape do" must have ONE answer, not two."""
    if logical_id.endswith(SERVICE_NODE_SUFFIX) and (
        logical_id.byte_length() > SERVICE_NODE_SUFFIX.byte_length()
    ):
        return String(
            logical_id[
                byte=0 : logical_id.byte_length()
                - SERVICE_NODE_SUFFIX.byte_length()
            ]
        )
    return logical_id.copy()


def service_artifact_names(rec: RevisionRecord) -> List[String]:
    """Every `service`-role artifact's SERVICE name, in RECORD ORDER.

    ⚠ NOT DEDUPLICATED, and that is the point: a repeated name is the AMBIGUITY
    `service_digest_for` refuses, and silently collapsing it here would hide the
    condition from the only function positioned to refuse it. Callers iterate this
    and call `service_digest_for` per name; the duplicate then raises."""
    var out = List[String]()
    for i in range(len(rec.artifacts)):
        if rec.artifacts[i].role == REVISION_ROLE_SERVICE:
            out.append(service_name_of(rec.artifacts[i].logical_id))
    return out^


def service_digest_for(
    rec: RevisionRecord, service_name: String
) raises -> String:
    """The digest of the `service`-role artifact belonging to `service_name` — what
    `stage` pins as that service's `from_digest`. RAISES on all four ways this can
    go wrong, and NEVER picks.

    ★ THE ARITY REFUSAL IS GONE AND THE AMBIGUITY REFUSAL IS NOT. `service_digest_for`
    is `sole_service_digest` with the question changed from "which one?" (unanswerable)
    to "this one" (a lookup). Everything `sole_service_digest` refused for a reason
    OTHER than arity is refused here too:

      ZERO SERVICE ARTIFACTS  -> `rec.service_digest()`'s own message. A probe-only
                                 revision is not publishable, and that sentence lives
                                 in one place.
      NO SUCH SERVICE         -> RAISES naming what IS there. A caller asking for a
                                 service the revision does not carry has a real
                                 mismatch (a service added to the bundle after the
                                 revision was built), and defaulting to any other
                                 artifact is precisely the wrong-image-exit-0 defect
                                 one name over.
      TWO ARTIFACTS, ONE NAME -> RAISES naming both candidates. This is the original
                                 defect, unchanged: nothing can choose between them,
                                 and a first-match would ship one and report success.
      NOT `sha256:`           -> RAISES at the RECORD. Both `run_publish_stage` and
                                 `channel_image_ref` hard-reject a non-`sha256:`
                                 `from_digest`; catching it here names the cause
                                 instead of surfacing six frames down as a registry
                                 path error."""
    var found = -1
    var second = -1
    for i in range(len(rec.artifacts)):
        if rec.artifacts[i].role != REVISION_ROLE_SERVICE:
            continue
        if service_name_of(rec.artifacts[i].logical_id) != service_name:
            continue
        if found < 0:
            found = i
        else:
            second = i
            break
    if found < 0:
        if _count_service_artifacts(rec) == 0:
            # Delegate so the "nothing to publish" wording lives in ONE place.
            return rec.service_digest()
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String("' carries no `service`-role artifact for service '")
            + service_name
            + String(
                "'. The services it DOES carry are: "
            )
            + _service_artifact_ids(rec)
            + String(
                ". A service named in the bundle but absent from the revision was"
                " added after the revision was built — rebuild it. Staging some"
                " OTHER service's image under this name is the wrong-artifact"
                " release that exits 0, which is what this lookup exists to"
                " prevent."
            )
        )
    if second >= 0:
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String("' carries TWO `service`-role artifacts for the SAME service '")
            + service_name
            + String("' — '")
            + rec.artifacts[found].logical_id
            + String("' and '")
            + rec.artifacts[second].logical_id
            + String(
                "'. One service publishes exactly ONE image (keyed on one ledger"
                " entry); picking the first would ship the wrong one and exit 0."
                " This is the ambiguity `sole_service_digest` was written to"
                " refuse, and widening `stage` to N services does not answer it."
            )
        )
    var digest = rec.artifacts[found].digest.copy()
    if not digest.startswith(String("sha256:")):
        raise Error(
            String("kci revision: '")
            + rec.revision_id
            + String("' service artifact '")
            + rec.artifacts[found].logical_id
            + String("' has digest '")
            + digest
            + String(
                "', which is not a `sha256:` image digest. publish/stage copy an OCI"
                " image BY DIGEST and both reject any other scheme; a"
                " `content-sha256:` value here means the artifact was recorded with"
                " the wrong role (web content is not a service image)."
            )
        )
    return digest^


# =============================================================================
# §2b — THE DEPLOY-SIDE REVISION ASSERTION + the value that carries it INTO the
#       image-resolution pass.
# =============================================================================
#
# The assertion is called from INSIDE `prefer_env_local_staged_refs`
# (`kci_staged_ref_resolver`) — the pass that actually rewrites the image the
# deploy runs — rather than as a standalone pre-flight statement in the CLI's
# `main`. Every consumer of that pass already depends on this library, so living
# here costs no new dependency edge.


struct RevisionExpectation(Copyable, Movable, Deinitable):
    """WHAT `--revision R` ASSERTS about the env's `staged-image/<app>` ledger, carried
    as a VALUE from the CLI edge into the image-resolution pass.

    ★ WHY A VALUE AND NOT A PRE-FLIGHT CALL. A pre-flight statement at the top of
    the deploy verbs lives in the file that defines `main()`, which nothing
    co-compiles, so it can be deleted with every test staying green. Threading the
    expectation into the pass makes the assertion run where the image is CHOSEN,
    in code that tests drive by value.

    FIELDS. `requested` is `cli.revision` VERBATIM — kept alongside the resolved values
    precisely so the pass can tell "no revision was named" (nothing to assert) apart from
    "a revision was named and the wiring dropped it" (a fail-LOUD bug, not a no-op).
    `revision_id` is the resolved id (a `latest` request resolves to a concrete id);
    `service_digest` is that revision's sole service digest.

    `built_commit` is the record's `git_commit` — THE COMMIT THE BYTES CAME FROM — and
    `reproduced_at` carries the record's OTHER build commits (see
    `RevisionRecord.reproduced_at`). Together they are the artifact's PROVENANCE, and
    they are fields rather than a lookup because this value is the ONE thing that
    crosses from the CLI edge into the pass: a provenance check that had to re-read the
    record could be dropped without the pass noticing.

    `built_at_us` is the record's first-build timestamp and `now_us` is the deploy-time
    clock. They exist for the AGE line of the provenance notice and for nothing else —
    see `check_revision_provenance`. Both default to 0 ("not known"), which suppresses
    that one line and changes no admission, because a report cannot gate anything.

    ⚠ `deploy_commit` IS NOT EVIDENCE. It is the commit the operator's working
    tree happens to be standing on, and it is carried for the notice's CONTEXT
    line only. See `check_revision_provenance` for why it is the wrong property to
    gate on. Do not gate on it.

    `content_digest` is set ONLY for a CONTENT-ONLY revision — a
    record with a `web_content` artifact and NO `service` one, which is what a
    static-frontend bundle's `build` mints. Such an expectation has an EMPTY
    `service_digest`, and the assertion moves from the image pass to the content
    pass (`prefer_env_local_staged_content`): the content this deploy publishes
    must BE this digest. A revision that carries a service keeps `content_digest`
    empty, so its deploy is byte-identical to before this field existed."""

    var requested: String
    var app_id: String
    var revision_id: String
    var service_digest: String
    var built_commit: String
    var deploy_commit: String
    var reproduced_at: List[String]
    var built_at_us: Int64
    var now_us: Int64
    var content_digest: String

    def __init__(
        out self,
        var requested: String,
        var app_id: String,
        var revision_id: String,
        var service_digest: String,
        var built_commit: String,
        var deploy_commit: String,
        var reproduced_at: List[String] = List[String](),
        built_at_us: Int64 = 0,
        now_us: Int64 = 0,
        var content_digest: String = String(""),
    ):
        """⚠ EVERY DEFAULT HERE FAILS CLOSED — that is the rule they are chosen by, and
        it is the only reason they may be defaults at all.

        An omitted `reproduced_at` makes the provenance check STRICTER (an empty set
        traces the bytes to FEWER commits, never more). An omitted `built_at_us` /
        `now_us` drops one line from a report that gates nothing. `deploy_commit` stays
        non-defaulted even though it is now report-only: a caller that silently stopped
        supplying it would emit a notice that quietly lost its context line, and every
        failure this file records is something that got quieter.

        An omitted `content_digest` also fails closed: with an empty
        `service_digest` too, `is_resolved()` is False and the driver REFUSES
        (`require_revision_path_available`); with a service digest it is the
        service-only expectation exactly."""
        self.requested = requested^
        self.app_id = app_id^
        self.revision_id = revision_id^
        self.service_digest = service_digest^
        self.built_commit = built_commit^
        self.deploy_commit = deploy_commit^
        self.reproduced_at = reproduced_at^
        self.built_at_us = built_at_us
        self.now_us = now_us
        self.content_digest = content_digest^

    @staticmethod
    def none() -> RevisionExpectation:
        """NO `--revision` was named — the pass asserts nothing and the deploy behaves
        byte-identically to a pre-revision deploy."""
        return RevisionExpectation(
            String(""), String(""), String(""), String(""),
            String(""), String(""), List[String](),
        )

    @staticmethod
    def of(
        requested: String,
        app_id: String,
        rec: RevisionRecord,
        deploy_commit: String,
        now_us: Int64 = 0,
    ) raises -> RevisionExpectation:
        """The expectation for a resolved record. `sole_service_digest` RAISES on a
        record with zero or two service artifacts, so an ambiguous revision can never
        become a silently-first-match expectation.

        `deploy_commit` stays a REQUIRED argument — see the `__init__` docstring; it is
        report-only now, and required so it cannot go missing silently.

        `now_us` is defaulted because it feeds one line of a report. Note which way
        that default cuts: a caller that forgets it loses the age line and nothing
        else. The PROVENANCE this method carries — `rec.git_commit` plus
        `rec.reproduced_at` — has no default anywhere, and that is the part the gate
        reads.

        ★ A CONTENT-ONLY RECORD (no `service` artifact, one `web_content`) resolves
        to its content digest instead, so `deploy-and-validate --revision R` can be
        spelled for a static-frontend bundle, as `stage --revision R` can. A record
        with NEITHER still raises, and a record with a service still takes
        `sole_service_digest`."""
        if _count_service_artifacts(rec) == 0 and _has_role(
            rec, REVISION_ROLE_WEB_CONTENT
        ):
            return RevisionExpectation(
                requested.copy(),
                app_id.copy(),
                rec.revision_id.copy(),
                String(""),
                rec.git_commit.copy(),
                deploy_commit.copy(),
                rec.reproduced_at.copy(),
                rec.built_at_us,
                now_us,
                content_digest=sole_web_content_digest(rec),
            )
        return RevisionExpectation(
            requested.copy(),
            app_id.copy(),
            rec.revision_id.copy(),
            sole_service_digest(rec),
            rec.git_commit.copy(),
            deploy_commit.copy(),
            rec.reproduced_at.copy(),
            rec.built_at_us,
            now_us,
        )

    def is_requested(self) -> Bool:
        """True iff the operator named a `--revision`."""
        return self.requested.byte_length() > 0

    def is_resolved(self) -> Bool:
        """True iff a concrete revision was resolved AND it names something to
        assert: a service digest, or (content-only) a content digest."""
        return self.revision_id.byte_length() > 0 and (
            self.service_digest.byte_length() > 0
            or self.content_digest.byte_length() > 0
        )

    def is_content_only(self) -> Bool:
        """True iff this names web content and NO service — the content pass owns
        the assertion, and the image pass has nothing to assert."""
        return (
            self.content_digest.byte_length() > 0
            and self.service_digest.byte_length() == 0
        )


# The age past which the provenance notice CALLS the artifact old. It is a
# REPORTING threshold and can gate nothing, which is the entire reason a bare
# number is acceptable here: the worst a wrong value can do is print or omit one
# line. Two weeks is chosen to be quiet for a normal release cadence and loud for
# a revision that has been sitting.
# Deliberately NOT a flag: a flag on a report is just a way to silence it.
comptime REVISION_AGE_NOTICE_US: Int64 = 1209600000000  # 14 * 24 * 3600 * 1e6
comptime _MICROS_PER_DAY: Int64 = 86400000000


def revision_build_commits(expectation: RevisionExpectation) -> List[String]:
    """Every commit at which THIS EXACT ARTIFACT SET was built: the record's
    `git_commit` first, then every recorded reproduction, with EMPTY entries dropped.

    Empty entries are dropped rather than carried because "" means "nobody resolved a
    commit", and a record containing one is not thereby traceable. That is the same
    rule `_commits_name_the_same` applies from the other direction (an empty never
    matches anything, including another empty), kept in ONE place so the refusal and
    the notice below can never disagree about what counts as known provenance."""
    var out = List[String]()
    if expectation.built_commit.byte_length() > 0:
        out.append(expectation.built_commit.copy())
    for i in range(len(expectation.reproduced_at)):
        var c = String(expectation.reproduced_at[i])
        if c.byte_length() > 0:
            out.append(c^)
    return out^


def _join_commits(commits: List[String]) -> String:
    var out = String("")
    for i in range(len(commits)):
        if i > 0:
            out += String(", ")
        out += commits[i]
    return out^


def _age_line(expectation: RevisionExpectation) -> String:
    """The one line of the notice that says HOW OLD the bytes are, measured from the
    RECORD's own `builtAtUs` — never from the operator's checkout.

    Returns "" when either endpoint is unknown, and says so in the caller rather than
    inventing an age. A clock running backwards yields a "clock skew" render instead
    of a negative day count: a nonsense number in a report teaches operators to stop
    reading the report."""
    if expectation.built_at_us <= 0 or expectation.now_us <= 0:
        return String("")
    var age = expectation.now_us - expectation.built_at_us
    if age < 0:
        return String(
            "\n  built           in the FUTURE by this machine's clock (skew?)"
        )
    var days = age / _MICROS_PER_DAY
    var line = String("\n  built           ") + String(days) + String(" day")
    if days != Int64(1):
        line += String("s")
    line += String(" ago")
    if age >= REVISION_AGE_NOTICE_US:
        line += String(
            "   <- ANCIENT. Check this is the release you mean; a revision"
            " deploys the\n                  bytes it recorded, and they do not"
            " age into the current ones."
        )
    return line^


def check_revision_provenance(
    expectation: RevisionExpectation
) raises -> String:
    """REFUSE a `--revision` deploy whose bytes cannot be traced to ANY commit; return
    the operator-facing provenance notice for one that can.

    ★ THE PROPERTY. The question is *"do these bytes have a known provenance?"*,
    not *"is your working tree standing on the commit these bytes were built
    at?"*. Whether the bytes' tests passed is not this file's question: when the
    build makes an artifact's tests a BUILD INPUT to it (a red welded test means
    the artifact never exists), bytes that exist are bytes whose tests passed,
    and the revision record already names the commit those bytes came from.

    Requiring HEAD to EQUAL that commit would add only *"...and you are standing
    there too"* — a different and strictly weaker property, since it says
    nothing about the artifact and everything about a shell. It makes deploying
    a good build impossible after any landing, including a converge run purely to
    REMEDIATE drift. A gate that blocks remediation is worse than one that blocks
    a deploy.

    ★ WHAT IS REFUSED. It must remain impossible to deploy bytes
    whose source cannot be identified — a record with no `gitCommit` and no
    reproduction is an artifact nobody can trace, and no amount of test-gating rescues
    it, because the gate that passed was the gate of SOME build and we cannot say
    which. `resolve_build_git_commit` already fails loud rather than recording "", so
    such a record is one written by something that bypassed it, and that is exactly
    when a deployer should stop. This is the LAST line of the refusal, and it is
    deliberately not satisfiable by anything the deployer controls.

    ★ ANCIENT IS REPORTED, NOT REFUSED — and measured against the RECORD. The notice
    carries the age from the record's own `builtAtUs` (see `_age_line`), not from a
    diff against the operator's checkout. "You are shipping something old" is a fact
    about the artifact and stays true whoever runs the command from wherever; "your
    tree has moved" is a fact about a shell and was never the same statement. Both are
    printed; neither refuses.

    ★ WHY IT LIVES HERE AND RETURNS A STRING. It is called from inside
    `prefer_env_local_staged_refs`, the pass that rewrites the image the deploy runs, so
    removing it means removing the rewrite the deploy needs. It RETURNS the notice
    rather than printing it so a test drives both halves BY VALUE — the refusal and the
    report are one call and cannot be half-deleted. A pre-flight statement in the
    CLI's `main` would carry zero test signal: nothing co-compiles the file that
    defines `main()`."""
    if not expectation.is_requested():
        return String("")
    var commits = revision_build_commits(expectation)
    if len(commits) == 0:
        raise Error(
            String(
                "kci deploy: REFUSING TO DEPLOY — these bytes cannot be traced"
                " to any commit\n\n  revision      "
            )
            + expectation.revision_id
            + String("\n  app           ")
            + expectation.app_id
            + String(
                "\n  built at      <no commit recorded, and no reproduction>\n\n "
                " A revision record names the commit its artifacts were built from"
                " (`gitCommit`),\n  plus every commit at which a rebuild was"
                " OBSERVED to reproduce them\n  (`reproducedAt`). This record has"
                " neither, so there is no source anyone can\n  point at for the"
                " image this deploy would run.\n\n  Note what does NOT rescue it:"
                " the tests these bytes passed are the tests of\n  SOME build, and"
                " with no commit recorded we cannot say which. `kci <app>"
                " build`\n  resolves the commit through `resolve_build_git_commit`,"
                " which FAILS LOUD rather\n  than recording an empty one — so a"
                " record in this state was written by something\n  that bypassed"
                " it, and that is the thing to go find.\n\n  Re-run `kci <app>"
                " build` to mint a record with a commit, and deploy that\n "
                " revision.\n"
            )
        )
    var notice = (
        String("kci deploy: revision ")
        + expectation.revision_id
        + String(" (app ")
        + expectation.app_id
        + String(")\n  bytes built at  ")
        + _join_commits(commits)
    )
    notice += _age_line(expectation)
    # Say WHICH endpoint is missing. "age unavailable" alone sends an operator to
    # look at the record when the caller is what dropped the clock.
    if expectation.built_at_us <= 0:
        notice += String(
            "\n  built           <age unavailable — the record carries no build"
            " timestamp>"
        )
    elif expectation.now_us <= 0:
        notice += String(
            "\n  built           <age unavailable — this deploy supplied no"
            " clock>"
        )
    # The CONTEXT line. Report it, never gate on it: see the property above.
    var here = expectation.deploy_commit.copy()
    if here.byte_length() == 0:
        notice += String(
            "\n  your tree       <could not resolve HEAD> (context only — the"
            " artifact's provenance\n                  above is what admits this"
            " deploy)"
        )
        return notice^
    var stands_on_a_build_commit = False
    for i in range(len(commits)):
        if _commits_name_the_same(commits[i], here):
            stands_on_a_build_commit = True
            break
    notice += String("\n  your tree       ") + here
    if not stands_on_a_build_commit:
        notice += String(
            " — NOT a commit these bytes were built at.\n                  That is"
            " information, not a problem: the bytes carry their own\n            "
            "      provenance and their own passed gate. Confirm the revision is"
            "\n                  the one you mean."
        )
    return notice^


def assert_staged_matches_revision(
    app_id: String,
    revision_id: String,
    staged_ref: Optional[String],
    expected_digest: String,
) raises:
    """REFUSE a deploy whose env-local `staged-image/<app>` record is not the named
    revision's service image.

    ★ WHY THIS EXISTS. The deploy path resolves the image it will ACTUALLY RUN from
    the env-local `staged-image/<app>` ledger, and that ledger is a LAST-KNOWN POINTER
    WITH NO REVISION IDENTITY. The SIBLING ledger, `staged-content/<app>`, has the
    same shape: a last-known pointer with no commit identity, so without a gate a
    deploy cannot tell its own commit's artifact apart from some earlier commit's,
    and can serve a frontend built at one commit against an API built at another,
    exit 0.

    Same class, different ledger. Without this assertion: `stage --revision r14`, then
    someone else `stage --revision r15`, then `deploy-and-validate --revision r14`
    deploys **r15** and reports SUCCESS. The operator named a revision and got another
    one, with a green result to prove it.

    A MISSING record is refused too, and separately: "nothing is staged" and "something
    else is staged" have different remedies, and collapsing them would send an operator
    hunting for a mismatch that is really an omission.

    PURE — the caller reads the ledger and passes the value in."""
    if not staged_ref:
        raise Error(
            String("kci deploy: --revision ")
            + revision_id
            + String(" was named, but NOTHING is staged for '")
            + app_id
            + String(
                "' in this env (no `staged-image/` record). Stage the revision"
                " first: `kci <app> stage <env> --revision "
            )
            + revision_id
            + String("`.")
        )
    var got = staged_ref.value().copy()
    var got_digest = digest_of_image_ref(got)
    if got_digest != expected_digest:
        raise Error(
            String("kci deploy: --revision ")
            + revision_id
            + String(" names service digest ")
            + expected_digest
            + String(", but this env's staged-image/")
            + app_id
            + String(" record points at ")
            + got_digest
            + String(" (")
            + got
            + String(
                "). The staged ledger is a last-known pointer with no revision"
                " identity, so deploying anyway would ship a DIFFERENT revision than"
                " the one you named — and exit 0. Re-stage: `kci <app> stage"
                " <env> --revision "
            )
            + revision_id
            + String("`.")
        )


def _has_role(rec: RevisionRecord, role: String) -> Bool:
    for i in range(len(rec.artifacts)):
        if rec.artifacts[i].role == role:
            return True
    return False


def _count_service_artifacts(rec: RevisionRecord) -> Int:
    var n = 0
    for i in range(len(rec.artifacts)):
        if rec.artifacts[i].role == REVISION_ROLE_SERVICE:
            n += 1
    return n


def _service_artifact_ids(rec: RevisionRecord) -> String:
    """The comma-joined logical ids of the `service`-role artifacts (for the
    ambiguity message — the operator must be shown WHICH ones collide)."""
    var out = String("")
    for i in range(len(rec.artifacts)):
        if rec.artifacts[i].role == REVISION_ROLE_SERVICE:
            if out.byte_length() > 0:
                out += String(", ")
            out += rec.artifacts[i].logical_id
    return out^


@fieldwise_init
struct MintOutcome(Copyable, Movable, Deinitable):
    """`RevisionStore.mint`'s result: the record + whether it is NEW.

    `minted == False` is a REUSE — either this build's artifact set equals
    HEAD's (§ identical-rebuild), or a concurrent minter created the identical
    record first. Both are successes; the caller prints "reused" rather than
    pretending a new release happened."""

    var record: RevisionRecord
    var minted: Bool


# =============================================================================
# §2 — the id format (`ordinal_of` is the inverse; both are total).
# =============================================================================


def format_revision_id(app_id: String, ordinal: Int64) -> String:
    """`("shop", 14)` -> `"shop-r14"`."""
    return app_id + REVISION_ORDINAL_SEP + String(ordinal)


def ordinal_of(app_id: String, revision_id: String) raises -> Int64:
    """`("shop", "shop-r14")` -> `14`.

    REQUIRES the caller's `app_id` — which the reader always knows, because it
    is a path segment of the key the record was read from. This is what makes
    the parse total and unambiguous for a HYPHENATED app id: a `rfind("-r")`
    heuristic reads `orders-coordinator-r7` as app `orders-coordinato`,
    ordinal-token `7`... or worse, silently accepts `cart-r3` as a `shop`
    revision. Both raise here."""
    var head = app_id + REVISION_ORDINAL_SEP
    if not revision_id.startswith(head):
        raise Error(
            String("kci revision: '")
            + revision_id
            + String("' is not a revision of app '")
            + app_id
            + String("' (expected the form '")
            + head
            + String("<N>')")
        )
    var digits = String(revision_id[byte = head.byte_length() :])
    if digits.byte_length() == 0:
        raise Error(
            String("kci revision: '")
            + revision_id
            + String("' has no ordinal after '")
            + head
            + String("'")
        )
    var db = digits.as_bytes()
    var value: Int64 = 0
    for i in range(len(db)):
        var c = Int(db[i])
        if c < 48 or c > 57:
            raise Error(
                String("kci revision: '")
                + revision_id
                + String("' has a non-numeric ordinal '")
                + digits
                + String("'")
            )
        value = value * Int64(10) + Int64(c - 48)
    return value


# =============================================================================
# §3 — the artifact set: sort + equality (the REUSE decision's whole basis).
# =============================================================================


def _artifact_sort_key(a: RevisionArtifact) -> String:
    """The total order: `<logical_id>\\x1f<role>\\x1f<digest>`. `image_ref` is excluded
    for the same reason it is excluded from equality."""
    return a.logical_id + String("\x1f") + a.role + String("\x1f") + a.digest


def sort_artifacts(mut a: List[RevisionArtifact]):
    """Stable-order the set in place by `(logical_id, role, digest)`. Insertion
    sort — a revision names a handful of artifacts, not thousands, and the
    determinism matters more than the asymptote (it is what makes the encoding
    byte-deterministic, which is what lets a test compare bytes)."""
    for i in range(1, len(a)):
        var j = i
        while j > 0 and _artifact_sort_key(a[j]) < _artifact_sort_key(a[j - 1]):
            a.swap_elements(j, j - 1)
            j -= 1


def artifacts_equal(
    a: List[RevisionArtifact], b: List[RevisionArtifact]
) -> Bool:
    """Set equality: same cardinality and, after sorting, equal
    `(logical_id, role, digest)` triples.

    `image_ref` is EXCLUDED (a rendering of digest + repo — a registry move must not
    mint a phantom revision). `git_commit` / `built_at_us` are excluded by
    construction: they are record fields, not artifact fields, and the whole
    point of the identical-rebuild rule is that the same bytes rebuilt from a
    later commit are the SAME release."""
    if len(a) != len(b):
        return False
    var sa = a.copy()
    var sb = b.copy()
    sort_artifacts(sa)
    sort_artifacts(sb)
    for i in range(len(sa)):
        if sa[i].logical_id != sb[i].logical_id:
            return False
        if sa[i].role != sb[i].role:
            return False
        if sa[i].digest != sb[i].digest:
            return False
    return True


def merge_artifacts(
    var head: List[RevisionArtifact], tail: List[RevisionArtifact]
) -> List[RevisionArtifact]:
    """Append `tail` onto `head`, DROPPING any `(logical_id, role)` already
    present. The two feeders (the pinned manifest's service/web nodes and the
    bundle's validate probes) are independently deduped but can in principle
    name the same logical id, and a duplicated artifact would make an otherwise
    identical rebuild compare unequal."""
    for i in range(len(tail)):
        var dup = False
        for j in range(len(head)):
            if (
                head[j].logical_id == tail[i].logical_id
                and head[j].role == tail[i].role
            ):
                dup = True
                break
        if not dup:
            head.append(tail[i].copy())
    return head^


# =============================================================================
# §4 — the codec (JSON via komira_serde).
# =============================================================================
#
# WHY JSON AND NOT `komira_objectstore`'s CAS-MANIFEST LE-BINARY FRAMING. That
# framing exists only because the object-store layer must not depend on a JSON
# library (it would invert the dependency graph). That constraint is local to
# the object-store layer and does not apply to a record kci owns. And an
# operator WILL `cat` this object out of the bucket — a release ledger a human
# cannot read is a release ledger nobody audits.
#
# `JsonValue.set_member` APPENDS and `key_at(i)` is index-ordered, so
# `serialize()` is insertion-ordered and therefore BYTE-DETERMINISTIC. Combined
# with `sort_artifacts` that makes two encodes of an equal record byte-identical
# — which is what lets a test assert "the stored bytes were not rewritten".


comptime _K_SCHEMA: String = "schema"
comptime _K_APP_ID: String = "appId"
comptime _K_REVISION_ID: String = "revisionId"
comptime _K_ORDINAL: String = "ordinal"
comptime _K_GIT_COMMIT: String = "gitCommit"
comptime _K_BUILT_AT_US: String = "builtAtUs"
comptime _K_BUNDLE_NAME: String = "bundleName"
comptime _K_ARTIFACTS: String = "artifacts"
comptime _K_REPRODUCED_AT: String = "reproducedAt"
comptime _K_LOGICAL_ID: String = "logicalId"
comptime _K_ROLE: String = "role"
comptime _K_DIGEST: String = "digest"
comptime _K_REF: String = "ref"


def revision_json(rec: RevisionRecord) raises -> String:
    """The record's canonical JSON text (what lands in the object)."""
    var root = JsonValue.empty_object()
    root.set_member(String(_K_SCHEMA), JsonValue.from_string(rec.schema.copy()))
    root.set_member(String(_K_APP_ID), JsonValue.from_string(rec.app_id.copy()))
    root.set_member(
        String(_K_REVISION_ID), JsonValue.from_string(rec.revision_id.copy())
    )
    root.set_member(
        String(_K_ORDINAL), JsonValue.from_number(String(rec.ordinal))
    )
    root.set_member(
        String(_K_GIT_COMMIT), JsonValue.from_string(rec.git_commit.copy())
    )
    root.set_member(
        String(_K_BUILT_AT_US), JsonValue.from_number(String(rec.built_at_us))
    )
    root.set_member(
        String(_K_BUNDLE_NAME), JsonValue.from_string(rec.bundle_name.copy())
    )
    var arr = JsonValue.empty_array()
    for i in range(len(rec.artifacts)):
        var a = JsonValue.empty_object()
        a.set_member(
            String(_K_LOGICAL_ID),
            JsonValue.from_string(rec.artifacts[i].logical_id.copy()),
        )
        a.set_member(
            String(_K_ROLE), JsonValue.from_string(rec.artifacts[i].role.copy())
        )
        a.set_member(
            String(_K_DIGEST),
            JsonValue.from_string(rec.artifacts[i].digest.copy()),
        )
        a.set_member(
            String(_K_REF), JsonValue.from_string(rec.artifacts[i].image_ref.copy())
        )
        arr.push(a^)
    root.set_member(String(_K_ARTIFACTS), arr^)
    # OMITTED WHEN EMPTY — the overwhelmingly common case. This keeps a record
    # that has never been reproduced byte-identical to what the previous encoder
    # wrote, so the "the stored bytes were not rewritten" assertions above stay
    # true and no existing record acquires a spurious diff.
    if len(rec.reproduced_at) > 0:
        var rep = JsonValue.empty_array()
        for i in range(len(rec.reproduced_at)):
            rep.push(JsonValue.from_string(rec.reproduced_at[i].copy()))
        root.set_member(String(_K_REPRODUCED_AT), rep^)
    return root.serialize()


def encode_revision(rec: RevisionRecord) raises -> List[UInt8]:
    """The stored object bytes for `rec` (its canonical JSON, no framing)."""
    var text = revision_json(rec)
    var b = text.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def decode_revision(
    bytes: List[UInt8], app_id: String
) raises -> RevisionRecord:
    """Parse a stored revision object back to a `RevisionRecord`, VALIDATING it
    against `app_id` (the key path the bytes came from).

    Three fail-loud checks, each guarding a real drift:
      * `schema` must be `REVISION_SCHEMA` — a future/foreign record must not be
        silently half-read;
      * `appId` must equal the key path's `app_id` — a record filed under the
        wrong app is a corrupted ledger, not a rename;
      * `ordinal` must equal `ordinal_of(app_id, revisionId)` — the stored
        ordinal and the id are two renderings of ONE fact, and this is the check
        that keeps them from becoming a hand-maintained parallel map."""
    var text = String("")
    for i in range(len(bytes)):
        text += chr(Int(bytes[i]))
    var root = parse_json_value(text)
    if not root.is_object():
        raise Error(
            String("kci revision: ")
            + app_id
            + String(" record is not a JSON object")
        )
    var schema = root.get(String(_K_SCHEMA)).as_string()
    if schema != REVISION_SCHEMA:
        raise Error(
            String("kci revision: unknown record schema '")
            + schema
            + String("' (this kci understands '")
            + String(REVISION_SCHEMA)
            + String("') — upgrade kci rather than reading it partially")
        )
    var rec_app = root.get(String(_K_APP_ID)).as_string()
    if rec_app != app_id:
        raise Error(
            String("kci revision: record filed under app '")
            + app_id
            + String("' declares appId '")
            + rec_app
            + String("' — the revision ledger is corrupted")
        )
    var revision_id = root.get(String(_K_REVISION_ID)).as_string()
    var ordinal = root.get(String(_K_ORDINAL)).as_int64()
    var derived = ordinal_of(app_id, revision_id)
    if ordinal != derived:
        raise Error(
            String("kci revision: '")
            + revision_id
            + String("' stores ordinal ")
            + String(ordinal)
            + String(" but its id says ")
            + String(derived)
            + String(" — refusing to guess which is the release order")
        )
    var artifacts = List[RevisionArtifact]()
    var arr = root.get(String(_K_ARTIFACTS))
    if not arr.is_array():
        raise Error(
            String("kci revision: '")
            + revision_id
            + String("' has no `artifacts` array")
        )
    for i in range(arr.array_len()):
        var a = arr.element_at(i)
        artifacts.append(
            RevisionArtifact(
                a.get(String(_K_LOGICAL_ID)).as_string(),
                a.get(String(_K_ROLE)).as_string(),
                a.get(String(_K_DIGEST)).as_string(),
                a.get(String(_K_REF)).as_string(),
            )
        )
    # ABSENT == EMPTY. Every record written before `reproducedAt` existed has no
    # such key, and the honest reading of that is "no reproduction was ever
    # observed" — which is the STRICT answer (it admits no extra commit), so an
    # old record cannot be read into a weaker gate than it was written under.
    var reproduced_at = List[String]()
    if root.has(String(_K_REPRODUCED_AT)):
        var rep = root.get(String(_K_REPRODUCED_AT))
        if not rep.is_array():
            raise Error(
                String("kci revision: '")
                + revision_id
                + String(
                    "' has a `reproducedAt` that is not an array — refusing to"
                    " read a provenance field whose shape is wrong"
                )
            )
        for i in range(rep.array_len()):
            reproduced_at.append(rep.element_at(i).as_string())
    return RevisionRecord(
        schema^,
        rec_app^,
        revision_id^,
        ordinal,
        root.get(String(_K_GIT_COMMIT)).as_string(),
        root.get(String(_K_BUILT_AT_US)).as_int64(),
        root.get(String(_K_BUNDLE_NAME)).as_string(),
        artifacts^,
        reproduced_at^,
    )


def _encode_head(revision_id: String) -> List[UInt8]:
    """The HEAD object bytes: the bare id + `\\n` — the git loose-ref shape. One
    value, no envelope."""
    var b = revision_id.as_bytes()
    var out = List[UInt8](capacity=len(b) + 1)
    for i in range(len(b)):
        out.append(b[i])
    out.append(UInt8(10))
    return out^


def _decode_head(bytes: List[UInt8]) -> String:
    """Parse a HEAD object back to the bare id, tolerating trailing whitespace."""
    var end = len(bytes)
    while end > 0:
        var c = bytes[end - 1]
        if c == UInt8(10) or c == UInt8(13) or c == UInt8(32) or c == UInt8(9):
            end -= 1
        else:
            break
    var out = String("")
    for i in range(end):
        out += chr(Int(bytes[i]))
    return out^


# -----------------------------------------------------------------------------
# Error taxonomy probes — duplicated per object-store consumer ON PURPOSE: each
# classifies on the canonical uppercase `StoreError[…]` token FIRST, with the
# legacy mixed-case / numeric substrings kept for the XML-conformer + generic
# shapes.
# -----------------------------------------------------------------------------


def _is_precondition_failed(e: Error) -> Bool:
    """True iff `e` is a conditional-write precondition failure (412) — the
    create-collision that the allocator PROBES FORWARD on and the stale-etag
    that the HEAD advance retries on."""
    var msg = String(e)
    return (
        msg.find("StoreError[PRECONDITION]") >= 0
        or msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("PreconditionFailed") >= 0
        or msg.find("412") >= 0
    )


def _is_not_found(e: Error) -> Bool:
    """True iff `e` is a store not-found (404) — an absent HEAD (nothing built
    yet) or an absent record (a torn HEAD / an operator typo)."""
    var msg = String(e)
    return (
        msg.find("StoreError[NOT_FOUND]") >= 0
        or msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("NoSuchKey") >= 0
        or msg.find("404") >= 0
    )


# =============================================================================
# §5 — RevisionStore[Store] — mint / resolve / head over the CAS object store.
# =============================================================================


struct RevisionStore[Store: ConditionalWriteStore](Movable):
    """The per-app revision ledger over a `ConditionalWriteStore`.

    Key layout (under one shared bucket, alongside `service/…`,
    `staged-image/…`, `staged-content/…`):

        revisions/<app_id>/HEAD           -> "<app_id>-r<N>"   (monotone-max)
        revisions/<app_id>/<revision_id>  -> the JSON record   (IMMUTABLE)

    Portable by inheritance from the `Store` type-param — the SAME code runs on
    `InMemoryConditionalStore` (hermetic tests), `LocalFsConditionalStore` (the
    "no hosted account" arm) and a cloud bucket conformer."""

    var _store: Self.Store
    var _prefix: String

    def __init__(out self, var store: Self.Store):
        """Construct over `store` with the default `revisions` key prefix."""
        self._store = store^
        self._prefix = String(REVISION_REGISTRY_PREFIX)

    def __init__(out self, var store: Self.Store, var prefix: String):
        """Construct over `store` with an explicit key prefix."""
        self._store = store^
        self._prefix = prefix^

    def into_store(deinit self) -> Self.Store:
        """Recover the underlying store (share the backing handle back)."""
        return self._store^

    @always_inline
    def prefix(self) -> String:
        return String(self._prefix)

    @always_inline
    def _app_prefix(self, app_id: String) -> String:
        return self._prefix + String("/") + app_id + String("/")

    @always_inline
    def _record_key(self, app_id: String, revision_id: String) -> String:
        return self._app_prefix(app_id) + revision_id

    @always_inline
    def _head_key(self, app_id: String) -> String:
        return self._app_prefix(app_id) + String(REVISION_HEAD_KEY)

    # =========================================================================
    # resolve — the record for an id. RAISES on absence (never "latest").
    # =========================================================================
    def resolve(self, app_id: String, revision_id: String) raises -> RevisionRecord:
        """Resolve `revision_id` to its record.

        RAISES on a missing revision, deliberately. An operator typo
        (`--revision shop-r41` for `shop-r14`) MUST NOT degrade into "well,
        deploy latest then" — that is the fail-quiet shape the whole
        `--revision` design exists to remove, and it would silently ship a
        different build than the one the operator named. Same fail-loud contract
        as kci's build-target resolution."""
        # Validate the id belongs to this app BEFORE the round trip: a
        # cross-app id is an operator error we can name precisely.
        _ = ordinal_of(app_id, revision_id)
        var found = self.try_resolve(app_id, revision_id)
        if not found:
            var known = String("")
            try:
                var ids = self.list_ids(app_id)
                for i in range(len(ids)):
                    if i > 0:
                        known += String(", ")
                    known += ids[i]
            except e:
                known = String("<unlistable>")
            raise Error(
                String("kci revision: no revision '")
                + revision_id
                + String("' for app '")
                + app_id
                + String("' at key '")
                + self._record_key(app_id, revision_id)
                + String("' (known: ")
                + (known if known.byte_length() > 0 else String("<none>"))
                + String(")")
            )
        return found.value().copy()

    def try_resolve(
        self, app_id: String, revision_id: String
    ) raises -> Optional[RevisionRecord]:
        """`resolve` without the raise: `None` when the record is absent, and
        FAIL-LOUD on a record that is present but unreadable.

        This is the OPERATOR-FACING read (`resolve` rides it). A corrupt record
        under an id an operator explicitly named MUST be reported — degrading it
        to `None` here would make `resolve` say "no such revision" about a
        revision that exists, which is the same fail-quiet shape as degrading a
        typo to "latest". The ALLOCATOR deliberately does NOT ride this — see
        `_read_slot_tolerant`."""
        var path = Path.parse(self._record_key(app_id, revision_id))
        try:
            var bytes = self._store.get(path)
            return Optional[RevisionRecord](decode_revision(bytes, app_id))
        except e:
            if _is_not_found(e):
                return Optional[RevisionRecord]()
            raise e^

    def _read_slot_tolerant(
        self, app_id: String, revision_id: String
    ) raises -> Optional[RevisionRecord]:
        """The ALLOCATOR's read of an ordinal slot: `None` when the slot's
        record is absent OR present-but-unreadable. TOLERANT where
        `try_resolve` is fail-loud, and the difference is load-bearing.

        WHY A SECOND READ EXISTS. Create-if-absent is NOT required to publish
        the KEY and the BODY at the same instant. `LocalFsConditionalStore` —
        the conformer the "works with no hosted account" arm rests on — does
        `open(O_CREAT|O_EXCL)` FIRST and `write_bytes`/`fsync`/`close` AFTER,
        and its own documentation concedes the window: "a torn-create chunk —
        present but zero/partial". So two `kci <app> build` processes over one
        revisions directory produce exactly this: A wins the O_EXCL create of
        `shop-r2` and has not yet written; B's `conditional_put` 412s, B `get`s
        the winner's key and receives ZERO bytes, and `decode_revision` raises
        `JsonError: unexpected end of input` — which matches neither
        `_is_not_found` nor any other arm of `try_resolve` and therefore would
        kill B's build while `shop-r3` was free and probing forward was the
        correct move.

        A slot we cannot READ is a slot we cannot ADOPT — but it is emphatically
        TAKEN (the 412 proved that), so the allocator's only correct move is to
        probe forward, which is precisely what returning `None` here does. This
        can never cause an overwrite: every write in the probe loop carries
        `if_none_match_star()`, so a losing minter is structurally incapable of
        clobbering the torn winner's slot once its body lands.

        Genuine store faults (auth / transport / 5xx) still PROPAGATE — only the
        DECODE is tolerated, and it is tolerated LOUDLY (one warning line, so a
        persistently unreadable record is visible in the build log rather than
        silently skipped forever)."""
        var path = Path.parse(self._record_key(app_id, revision_id))
        var bytes: List[UInt8]
        try:
            bytes = self._store.get(path)
        except e:
            if _is_not_found(e):
                return Optional[RevisionRecord]()
            raise e^
        try:
            return Optional[RevisionRecord](decode_revision(bytes, app_id))
        except e:
            print(
                String("kci revision: WARNING — '")
                + revision_id
                + String(
                    "' exists but its body is not readable ("
                )
                + String(e)
                + String(
                    "); treating the ordinal as TAKEN and probing forward. This"
                    " is the expected transient when a concurrent minter has"
                    " created the key and not yet written it."
                )
            )
            return Optional[RevisionRecord]()

    # =========================================================================
    # head — the current revision (None = nothing built yet, NOT an error).
    # =========================================================================
    def head_id(self, app_id: String) raises -> Optional[String]:
        """The id `revisions/<app>/HEAD` points at, or `None` if unset. Nothing
        built yet is a STATE, not an error (the same contract as the service
        registry's resolve)."""
        var path = Path.parse(self._head_key(app_id))
        try:
            return Optional[String](_decode_head(self._store.get(path)))
        except e:
            if _is_not_found(e):
                return Optional[String]()
            raise e^

    def head(self, app_id: String) raises -> Optional[RevisionRecord]:
        """The record HEAD points at, or `None` when HEAD is unset OR when it
        points at a record that is absent or UNREADABLE (a TORN HEAD).

        A torn HEAD is treated as "nothing known", which makes the allocator
        recover its floor from the store (`_recover_floor_ordinal`) instead of
        raising and bricking every subsequent build. "Unreadable" is included
        for the same reason "absent" is: HEAD is a CACHE, and a cache that can
        brick the build is worse than no cache. The read is
        `_read_slot_tolerant`, NOT `try_resolve` — `resolve` keeps its fail-loud
        contract for the id an operator actually typed."""
        var hid = self.head_id(app_id)
        if not hid:
            return Optional[RevisionRecord]()
        return self._read_slot_tolerant(app_id, hid.value())

    # =========================================================================
    # _recover_floor_ordinal — the TRUE max ordinal, derived from the store.
    # =========================================================================
    def _recover_floor_ordinal(self, app_id: String) raises -> Int64:
        """The highest ordinal actually recorded under `revisions/<app_id>/`,
        or `0` when the app has no revisions. ONE `list_with_delimiter`.

        WHY THIS EXISTS (and why probing from 1 is not good enough). HEAD is a
        derived cache, and `_advance_head` is explicitly allowed to give up on it
        ("a lost HEAD CAS is not an error"). So HEAD CAN be absent, stale,
        deleted or unreadable while the ledger is fine. Probing from `n0 = 1`
        with a `MINT_MAX_PROBES = 64` ceiling would mean an app that has passed
        64 revisions could NEVER MINT AGAIN: every probe 412s against an
        existing record and the loop gives up. A derived cache whose loss is
        permanent and unrecoverable is not a cache.

        Probing from 1 is not merely SLOW past 64 revisions; it is terminal. The
        local-filesystem conformer already relies on a LIST recovery for a torn
        create, so this closes both halves with one mechanism.

        WHY LIST-THE-FLOOR AND NOT A BIGGER/ADAPTIVE CEILING. The probe budget
        is supposed to bound CONCURRENT MINTERS, not HISTORY LENGTH — one probe
        is burned per minter that beat us to an ordinal. Once the FLOOR is
        right, 64 is astronomically past any real build fan-out, and no constant
        is ever right if the floor can be wrong. Raising the ceiling to "however
        many revisions exist" would also turn one LIST into k round trips.

        COSTS NOTHING ON THE HAPPY PATH: only reached when HEAD is unusable
        (greenfield — where the LIST returns empty — or torn), never when HEAD
        resolves. Pinned by an op-count test.

        A store that cannot LIST degrades to the old behaviour (floor 0 ⇒ probe
        from 1) with a warning rather than failing the build."""
        var ids: List[String]
        try:
            ids = self.list_ids(app_id)
        except e:
            print(
                String(
                    "kci revision: WARNING — HEAD is unusable for app '"
                )
                + app_id
                + String("' and its revision prefix could not be listed (")
                + String(e)
                + String(
                    "); falling back to probing from ordinal 1, which cannot"
                    " recover an app with more than "
                )
                + String(MINT_MAX_PROBES)
                + String(" revisions")
            )
            return Int64(0)
        var max_n: Int64 = 0
        for i in range(len(ids)):
            # A key under this prefix that is not one of THIS app's revision
            # ids (a stray upload, a foreign object) contributes nothing — it
            # must not raise, and it must not be counted.
            var n: Int64
            try:
                n = ordinal_of(app_id, ids[i])
            except e:
                n = 0
            if n > max_n:
                max_n = n
        return max_n

    # =========================================================================
    # list_ids — every revision id recorded for `app_id` (HEAD excluded).
    # =========================================================================
    def list_ids(self, app_id: String) raises -> List[String]:
        """Every revision id under `revisions/<app_id>/`, in the store's listing
        order (callers that need a stable order should sort). HEAD is excluded —
        it is a pointer, not a revision."""
        var prefix = self._app_prefix(app_id)
        var res = self._store.list_with_delimiter(Path.parse(prefix))
        var out = List[String]()
        for i in range(len(res.objects)):
            var key = res.objects[i].location
            if not key.startswith(prefix):
                continue
            var name = String(key[byte = prefix.byte_length() :])
            if name == REVISION_HEAD_KEY or name.byte_length() == 0:
                continue
            out.append(name^)
        return out^

    # =========================================================================
    # mint — allocate (or REUSE) a revision for this build's artifact set.
    # =========================================================================
    def mint(
        mut self,
        app_id: String,
        var artifacts: List[RevisionArtifact],
        git_commit: String,
        bundle_name: String,
        now_us: Int64,
    ) raises -> MintOutcome:
        """Mint a revision for `artifacts`, returning `(record, minted_new)`.

        (A) FAST PATH — REUSE. If HEAD's artifact set equals this one, return
            HEAD with `minted=False`: no new record, no HEAD write, no ordinal
            burned. Every input is content-addressed, so a no-change rebuild is
            EXPECTED to reproduce the digests (a fresh build of unchanged inputs
            resolves to the digest already on the registry). Reuse compares
            against HEAD **only, never history** — see the boundary note below.

            ★ REUSE RECORDS THE REPRODUCTION (`_record_reproduction`). When the
            rebuild ran at a DIFFERENT commit than the record names, that commit
            is appended to `reproduced_at`. This is the ONLY writer of that
            field, and it writes only what it just measured: these artifacts, at
            this commit, compared equal.

            ⚠ WHAT IT IS FOR. It does not decide admission
            (`check_revision_provenance` does not compare against the operator's
            HEAD); it widens the set of commits the artifact is TRACEABLE to and
            is reported in the provenance notice. Keep writing it: a record whose
            `git_commit` is unreadable is still traceable through it.

        (B) ALLOCATE by create-if-absent, PROBING FORWARD on a 412. The create
            is the linearization point; HEAD is only a hint. On a 412 we read the
            record that won: identical artifacts -> adopt it (the concurrent
            twin of the reuse in (A)); different -> n+1 and try again. We
            deliberately DO NOT re-read HEAD here (the spin bug — see header).

        THE REUSE BOUNDARY (deliberate, pinned by a test): reuse is HEAD-ONLY.
        If r14=A, r15=B and someone rebuilds A, this mints **r16**, not r14,
        because consumers treat ordinals as monotone with RELEASE TIME, and
        re-releasing older bytes after a newer release is a genuinely distinct
        release event an auditor must see. Making reuse history-wide would also
        need a third `by-artifacts/` index the two-key layout does not have.

        (C) RECOVER THE FLOOR rather than bricking. HEAD is a derived cache and
            is allowed to be absent / stale / torn, so `n0` is only a HINT. When
            HEAD is unusable the floor comes from the store itself
            (`_recover_floor_ordinal`, one LIST), and if a full probe budget is
            burned we re-derive the floor once more and probe again from there.
            Without that, losing HEAD on an app with >= `MINT_MAX_PROBES`
            revisions made minting PERMANENTLY IMPOSSIBLE: probing restarted at
            1 and every one of the 64 probes 412'd against an existing record.

        RAISES only on a genuine store fault, or when even a store-derived floor
        cannot find a free ordinal within `MINT_MAX_PROBES` (which means 64
        concurrent minters, or a keyspace this code should not guess about)."""
        sort_artifacts(artifacts)

        # --- (A) fast path: identical to HEAD? -------------------------------
        var n0: Int64 = 1
        var prior = self.head(app_id)

        # --- (A') HEAD unusable: RECONSTRUCT it from the store, don't restart.
        # The "true HEAD" when the pointer is lost is the MAX-ORDINAL record, so
        # recovering it restores BOTH properties the pointer carried: the floor
        # to allocate from, AND the record to compare artifacts against. Taking
        # only the floor would silently drop the reuse/adopt contract — a
        # rebuild of identical bytes with a lost HEAD would burn a fresh
        # ordinal, and the concurrent-twin convergence would mint two
        # records for one release. Greenfield lands here too: the LIST returns
        # empty, floor 0, n0 stays 1, no extra read.
        var head_was_lost = False
        if not prior:
            head_was_lost = True
            var floor = self._recover_floor_ordinal(app_id)
            if floor > Int64(0):
                n0 = floor + Int64(1)
                # Unreadable (torn) max record -> `prior` stays empty: nothing to
                # reuse, and n0 is already past it because it is TAKEN.
                prior = self._read_slot_tolerant(
                    app_id, format_revision_id(app_id, floor)
                )

        if prior:
            if artifacts_equal(prior.value().artifacts, artifacts):
                if head_was_lost:
                    # Reuse via a RECONSTRUCTED head — repair the cache on the
                    # way out, so the next mint is back on the fast path.
                    self._advance_head(
                        app_id,
                        prior.value().revision_id,
                        prior.value().ordinal,
                    )
                return MintOutcome(
                    self._record_reproduction(
                        app_id, prior.value(), artifacts, git_commit
                    ),
                    False,
                )
            n0 = prior.value().ordinal + Int64(1)

        # --- (B) allocate: create-if-absent, probe forward on 412 ------------
        var got = self._probe_allocate(
            app_id, artifacts, git_commit, bundle_name, now_us, n0
        )
        if got:
            return got.value().copy()

        # --- (C) the probe budget is spent. ONE store-derived recovery pass. --
        # Reached when the floor we started from was wrong by more than the
        # whole budget — a HEAD restored from an old backup, a partially
        # re-uploaded prefix. Re-derive the true floor and probe again from
        # there, but only if it is genuinely BEYOND everything we just probed
        # (otherwise this is real concurrency, not a lost floor, and re-probing
        # the same ordinals would only burn ops).
        var floor = self._recover_floor_ordinal(app_id)
        var n1 = floor + Int64(1)
        if n1 > n0 + Int64(MINT_MAX_PROBES - 1):
            var got2 = self._probe_allocate(
                app_id, artifacts, git_commit, bundle_name, now_us, n1
            )
            if got2:
                return got2.value().copy()

        raise Error(
            String("kci revision: could not allocate an ordinal for app '")
            + app_id
            + String("' after ")
            + String(MINT_MAX_PROBES)
            + String(" probes starting at ")
            + String(n0)
            + String(" (store-derived floor: ")
            + String(floor)
            + String(") — the revision keyspace looks corrupted")
        )

    def _probe_allocate(
        mut self,
        app_id: String,
        artifacts: List[RevisionArtifact],
        git_commit: String,
        bundle_name: String,
        now_us: Int64,
        n0: Int64,
    ) raises -> Optional[MintOutcome]:
        """`mint`'s probe loop: create-if-absent at `n0`, `n+1` on a 412, up to
        `MINT_MAX_PROBES` times. `None` == the budget was spent (the caller
        decides whether a re-derived floor is worth another pass); it is NOT an
        error by itself.

        Deliberately does NOT re-read HEAD between probes — that is the spin bug
        (the winner may not have advanced HEAD yet, so a loser re-deriving n
        from HEAD recomputes the SAME ordinal forever)."""
        var n = n0
        for _probe in range(MINT_MAX_PROBES):
            var rid = format_revision_id(app_id, n)
            var rec = RevisionRecord(
                String(REVISION_SCHEMA),
                app_id.copy(),
                rid.copy(),
                n,
                git_commit.copy(),
                now_us,
                bundle_name.copy(),
                artifacts.copy(),
            )
            var path = Path.parse(self._record_key(app_id, rid))
            var won = False
            try:
                _ = self._store.conditional_put(
                    path,
                    encode_revision(rec),
                    WritePrecondition.if_none_match_star(),
                )
                won = True
            except e:
                if not _is_precondition_failed(e):
                    raise e^
            if won:
                self._advance_head(app_id, rid, n)
                return Optional[MintOutcome](MintOutcome(rec^, True))

            # A 412: someone else owns r<n>. Who, and is it the same build?
            # TOLERANT read — a winner whose KEY exists but whose BODY has not
            # landed yet (LocalFs creates O_EXCL first, writes after) is a TAKEN
            # ordinal, not a fault. `_read_slot_tolerant` returns `None` for it
            # and we probe forward, which is the same move as "a different
            # build owns it".
            var existing = self._read_slot_tolerant(app_id, rid)
            if existing:
                if artifacts_equal(existing.value().artifacts, artifacts):
                    # The concurrent twin of (A): both operators are told the
                    # SAME id and exactly ONE record was written. The loser
                    # records its reproduction for the same reason (A) does —
                    # its commit really did produce these bytes, and omitting it
                    # here would make admission depend on who won a race.
                    self._advance_head(app_id, rid, n)
                    return Optional[MintOutcome](
                        MintOutcome(
                            self._record_reproduction(
                                app_id,
                                existing.value(),
                                artifacts,
                                git_commit,
                            ),
                            False,
                        )
                    )
            n += Int64(1)
        return Optional[MintOutcome]()

    # =========================================================================
    # _record_reproduction — APPEND this build's commit to a REUSED record.
    # =========================================================================
    def _record_reproduction(
        mut self,
        app_id: String,
        rec: RevisionRecord,
        artifacts: List[RevisionArtifact],
        git_commit: String,
    ) raises -> RevisionRecord:
        """Append `git_commit` to `rec.reproduced_at` and CAS the record back,
        returning the record as it now stands.

        Called ONLY from `mint`'s two reuse branches, and only with the artifact
        list THIS BUILD just resolved — which is what makes the appended commit a
        measurement rather than an assertion. See `RevisionRecord.reproduced_at`.

        FOUR REASONS TO WRITE NOTHING, each returning `rec` unchanged:
          * an EMPTY `git_commit` — there is nothing to record, and "" is what
            `_commits_name_the_same` already refuses to match;
          * the commit ALREADY answers for this record (it is `git_commit`, or is
            already in the set) — the common case on a repeat build, and skipping
            it keeps a rebuild loop from rewriting the object every time;
          * the set is at `MAX_REPRODUCED_COMMITS` — a record is a release ledger
            an operator reads, not a git log, and an unbounded field on a
            long-lived stable artifact would grow one entry per rebuild forever;
          * the CAS was lost `HEAD_CAS_MAX_ATTEMPTS` times.

        ⚠ THE FAILURE DIRECTION IS DELIBERATE. Every give-up path leaves the
        commit UNRECORDED, which UNDER-states the artifact's provenance and never
        over-states it. The opposite direction — a build that fails because a
        provenance annotation was contended, or a commit recorded without the
        artifact comparison — is either unrecoverable by retrying or actively
        false. This is the same call `_advance_head` makes for the same reason.

        ⚠ THE COST OF NOT RECORDING IS SMALL. `check_revision_provenance` does not
        compare the record's commit with the operator's HEAD, so a missed append
        costs one line of a report. That makes this path cheap, not less correct
        — do not take it as licence to record a commit the artifact comparison
        did not confirm.

        ⚠ THE RE-READ IS RE-VERIFIED. On a CAS loss the record is read again and
        `artifacts_equal` is CHECKED AGAIN before retrying. Records are otherwise
        immutable so this should never fail — but "should never" is exactly the
        condition under which appending a commit to a record whose bytes are no
        longer the ones we compared would be silent and wrong."""
        if git_commit.byte_length() == 0:
            return rec.copy()
        if rec.was_built_at(git_commit):
            return rec.copy()

        var path = Path.parse(self._record_key(app_id, rec.revision_id))
        var current = rec.copy()
        for _attempt in range(HEAD_CAS_MAX_ATTEMPTS):
            if current.was_built_at(git_commit):
                return current^
            if len(current.reproduced_at) >= MAX_REPRODUCED_COMMITS:
                print(
                    String("kci revision: WARNING — ")
                    + current.revision_id
                    + String(" already records ")
                    + String(MAX_REPRODUCED_COMMITS)
                    + String(
                        " reproducing commits; NOT recording this one. Deploys"
                        " are unaffected — the provenance notice will simply not"
                        " list this commit. Cut a new revision (any source change"
                        " reaching these artifacts will do it) rather than"
                        " growing this record."
                    )
                )
                return current^

            var etag: String
            try:
                var meta = self._store.head(path)
                etag = meta.etag
            except e:
                if not _is_not_found(e):
                    raise e^
                # The record vanished under us. It is not this function's job to
                # recreate a release record, and a blind put would resurrect one
                # whose deletion we know nothing about.
                print(
                    String("kci revision: WARNING — ")
                    + current.revision_id
                    + String(
                        " disappeared while recording that this commit"
                        " reproduces it; recorded nothing."
                    )
                )
                return current^

            var updated = current.copy()
            updated.reproduced_at.append(git_commit.copy())
            var swapped = False
            try:
                _ = self._store.compare_and_swap(
                    path, encode_revision(updated), etag
                )
                swapped = True
            except e:
                if not _is_precondition_failed(e):
                    raise e^
            if swapped:
                return updated^

            # Someone else wrote this record. Re-read, RE-VERIFY the artifact set
            # (see above), and try again.
            var fresh = self._read_slot_tolerant(app_id, rec.revision_id)
            if not fresh:
                return current^
            if not artifacts_equal(fresh.value().artifacts, artifacts):
                print(
                    String("kci revision: WARNING — ")
                    + current.revision_id
                    + String(
                        " changed artifact set while recording a reproducing"
                        " commit; recorded NOTHING (the bytes this build"
                        " compared against are no longer the record's)."
                    )
                )
                return fresh.value().copy()
            current = fresh.value().copy()

        print(
            String("kci revision: WARNING — lost ")
            + String(HEAD_CAS_MAX_ATTEMPTS)
            + String(" consecutive CAS races recording that ")
            + git_commit
            + String(" reproduces ")
            + current.revision_id
            + String(
                "; the build is complete, the artifacts are unaffected, and"
                " deploys are unaffected — this commit simply will not appear in"
                " the revision's provenance notice until a rebuild records it."
            )
        )
        return current^

    # =========================================================================
    # _advance_head — MONOTONE-MAX pointer advance. A lost race is NOT an error.
    # =========================================================================
    def _advance_head(
        mut self, app_id: String, revision_id: String, ordinal: Int64
    ) raises:
        """Point `revisions/<app>/HEAD` at `revision_id`, but ONLY forward.

        Three properties, each load-bearing:
          * MONOTONE-MAX — if HEAD already names a HIGHER ordinal we return
            without writing. A blind last-writer-wins put would let a slower
            machine walk HEAD backwards, which would make the next mint reuse an
            ordinal that is already taken (and then probe-forward-storm).
          * A LOST CAS IS NOT AN ERROR — the record is already durable and HEAD
            is monotone-max either way, so after `HEAD_CAS_MAX_ATTEMPTS` losses
            we WARN and return success. A retry-once-then-RAISE budget here
            would fail an otherwise-complete build because a *cache pointer* was
            contended.
          * A TORN/GARBAGE HEAD (one that does not parse as this app's id) is
            OVERWRITTEN rather than raised on — it is a cache, and a cache that
            can brick the build is worse than no cache."""
        var path = Path.parse(self._head_key(app_id))
        for _attempt in range(HEAD_CAS_MAX_ATTEMPTS):
            var cur_etag = Optional[String]()
            try:
                var meta = self._store.head(path)
                cur_etag = Optional[String](meta.etag)
            except e:
                if not _is_not_found(e):
                    raise e^

            if not cur_etag:
                # CREATE: no HEAD yet (greenfield bucket / first build).
                var created = False
                try:
                    _ = self._store.conditional_put(
                        path,
                        _encode_head(revision_id),
                        WritePrecondition.if_none_match_star(),
                    )
                    created = True
                except e:
                    if not _is_precondition_failed(e):
                        raise e^
                if created:
                    return
                continue  # a concurrent create won — re-read and re-decide

            var cur = _decode_head(self._store.get(path))
            var cur_ordinal: Int64
            try:
                cur_ordinal = ordinal_of(app_id, cur)
            except e:
                cur_ordinal = -1  # torn/garbage HEAD — safe to overwrite
            if cur_ordinal >= ordinal:
                return  # already at or past us; monotone-max satisfied

            var swapped = False
            try:
                _ = self._store.compare_and_swap(
                    path, _encode_head(revision_id), cur_etag.value()
                )
                swapped = True
            except e:
                if not _is_precondition_failed(e):
                    raise e^
            if swapped:
                return
            # HEAD moved under us — loop, re-read, re-decide (we may now be
            # BEHIND the new HEAD, in which case the next pass returns early).

        print(
            String(
                "kci revision: WARNING — minted "
            )
            + revision_id
            + String(" but lost ")
            + String(HEAD_CAS_MAX_ATTEMPTS)
            + String(
                " consecutive HEAD CAS races; the record is durable and HEAD"
                " will converge (HEAD is a monotone-max cache, not the"
                " allocator)"
            )
        )
