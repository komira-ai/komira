# =============================================================================
# komira_deploy_bundle/datastore_identity.mojo — ★ THE ONE READER
#   of a service's datastore identity: does this bundle OWN the database, or does
#   it merely REFERENCE one another release machine owns?
# =============================================================================
#
# ── WHY OWNERSHIP IS A DECLARED CONCEPT ─────────────────────────────────────
# A release machine may own a resource (its deploy creates it) or merely
# reference a resource another release machine owns. Control-plane services
# share ONE database that a single machine owns; a customer managed app owns a
# separate database of its own.
#
# Without the distinction, several bundles that each declare a serverless
# datastore and name the SAME database all run the same create-or-adopt ensure:
# the first deploy CREATES it and the others silently ADOPT whatever they find —
# many claimants, no owner. That costs three ways:
#   * The database NAME becomes a compile-time constant, because no single bundle
#     is entitled to choose one.
#   * A fresh environment's first deploy can fail at datastore first-contact:
#     nobody owns CREATING the database, so the ordering is whatever the operator
#     happens to type.
#   * An app can STAMP one database while its deploy ENSURES another — the app
#     opens a database the deploy never indexed.
#
# A managed app that states `datastore_database: "<its own>"` already has the
# right shape: it owns a private database and is never part of a shared race.
#
# ── ⛔ THE XOR IS THE WHOLE POINT, AND IT IS ENFORCED IN EXACTLY ONE PLACE ────
# `AppSpec` carries TWO strings — `datastore_database` (I OWN it) and
# `datastore_database_ref` (I REFERENCE it). Read either one directly and you have
# re-created the ambiguity they exist to remove. So NOTHING reads them directly
# except `resolve_datastore_identity` below, and every consumer — the bundle
# validator, the release CLI's deploy seam, the compose pass — goes through it.
#
# THE FOUR STATES, AND WHY "NEITHER" HAD TO BE REPRESENTABLE:
#   OWNED       — `datastore_database` set, ref empty.  This deploy ensures it.
#   REFERENCED  — `datastore_database_ref` set, own empty. This deploy REFUSES if
#                 it is absent, and never creates, updates or deletes it.
#   NEITHER     — a datastore-bearing service that names no database at all. This
#                 is a REFUSAL, and making it representable is what makes it
#                 refusable. It is also the CUSTOMER case: a managed app deployed
#                 into an account with no shared infrastructure has nothing to
#                 reference, so it is forced to declare its own.
#   BOTH        — a REFUSAL. A service cannot both own and borrow one database,
#                 and a tie-break rule here would be a silent policy nobody reads.
#
# def-based, PURE, ZERO I/O, ZERO credentials — which is what keeps bundle
# validation offline. The LIVE
# half of the question ("is the referenced database actually there?") is a
# different source and lives at plan time in the mapper's datastore arm; neither
# half can answer the other's question. Mojo 1.0.0b2.
# =============================================================================

from komira_rpc_bundle.app_bundle import AppSpec
from komira_rpc_bundle.deploy_model import DatastoreNeed


# ── the four states ──────────────────────────────────────────────────────────
comptime DATASTORE_IDENTITY_NONE: Int = 0
"""The service declares no datastore need at all — there is no database to name,
and naming one would be an error (a name that addresses nothing reads as the thing
in control, and the next author threads it somewhere)."""

comptime DATASTORE_IDENTITY_OWNED: Int = 1
"""This bundle OWNS the database: its deploy CREATES it if absent and ensures every
composite index. Exactly one release machine may say this about one database."""

comptime DATASTORE_IDENTITY_REFERENCED: Int = 2
"""This bundle REFERENCES a database another release machine owns: its deploy
probes it read-only, NOOPs when present, and REFUSES when absent. It never
creates, updates or deletes it."""

comptime DATASTORE_IDENTITY_OWNED_AND_REFERENCED: Int = 3
"""★ A **BUNDLE-ONLY** state (a consolidated control-plane bundle): within ONE bundle,
exactly ONE service OWNS the database and N other services REFERENCE it.

⛔ `resolve_datastore_identity` NEVER returns this — a SERVICE that authored both
`datastore_database` and `datastore_database_ref` is still the `BOTH` refusal the
header names, and that refusal is untouched. This value exists only as the answer
`bundle_datastore_identity` gives for a bundle whose SERVICES disagree in the ONE
way that is coherent.

★ WHY IT IS COHERENT AND `BOTH`-ON-ONE-SERVICE IS NOT. `BOTH` on one service asks
one deploy to both create and refuse to create the same resource in the same act —
there is no ordering that resolves it. One owner + N referencers has exactly one
resolving order, and the composer emits it: the referencing nodes `depends_on` the
owner's node, so the database is ENSURED before anything probes it. The XOR is a
per-SERVICE rule: when several machines are consolidated into one bundle, the
bundle is the deploy unit and the service is the ownership unit, and the rule
follows the service.

★ WHAT A CONSUMER MUST DO WITH IT: build BOTH seams. `owns()` and `references()`
are deliberately NOT mutually exclusive for this value — they are two independent
questions, and a consumer that treats them as a fork (`if references(): … else:
…`) silently drops one of them. The mapper already handles the cardinality with no
change: ONE owned node consumes the single-consume `EnsureIndexes`, and N
referenced nodes share the refcounted read-only probe."""


@fieldwise_init
struct DatastoreIdentity(Copyable, Movable):
    """A service's datastore identity as ONE value: which of the three legal states
    it is in, and the database id that goes with it.

    ⚠ `bundle_datastore_identity` reuses this type to answer the same question for a
    whole BUNDLE, and a bundle has one more legal answer than a service does —
    `DATASTORE_IDENTITY_OWNED_AND_REFERENCED`. See that constant.

    ★ WHY A STRUCT AND NOT TWO RETURN VALUES. The failure this type exists to make
    untypeable is a caller that reads the id from one field and the ownership from
    somewhere else. `kind` and `database` are produced together, from one pass over
    one spec, and a caller that holds this value cannot have sourced them
    independently — the same reason `_DatastoreSeams` binds the ensure step and the
    id together one layer down."""

    var kind: Int
    """`DATASTORE_IDENTITY_NONE` / `_OWNED` / `_REFERENCED` /
    `_OWNED_AND_REFERENCED` (bundle-level only)."""

    var database: String
    """The database id — for OWNED and REFERENCED alike. EMPTY iff `kind` is NONE.
    Both arms yield the SAME string type on purpose: the id the app is STAMPED with
    must not depend on who owns it, or the two would drift the moment ownership
    moved.

    ★ AND THAT INDIFFERENCE IS WHAT MAKES THE MIXED STATE HAVE ONE id AT ALL: the
    owner and every referencer must name the SAME database (a second name is still
    refused), so a mixed bundle has exactly one id to report."""

    def owns(self) -> Bool:
        """True iff this deploy must ENSURE the database (create-if-absent + every
        composite index).

        ⚠ NOT the complement of `references()` — see
        `DATASTORE_IDENTITY_OWNED_AND_REFERENCED`, for which BOTH are true."""
        return (
            self.kind == DATASTORE_IDENTITY_OWNED
            or self.kind == DATASTORE_IDENTITY_OWNED_AND_REFERENCED
        )

    def references(self) -> Bool:
        """True iff this deploy must PROBE the database read-only and refuse when it
        is absent.

        ⚠ NOT the complement of `owns()` — see
        `DATASTORE_IDENTITY_OWNED_AND_REFERENCED`, for which BOTH are true. A
        consumer that writes `if references(): … else: …` drops the ensure step for
        a consolidated bundle, and the database is then STAMPED but never
        INDEXED — a green deploy and a 400 FAILED_PRECONDITION on the first
        list-query."""
        return (
            self.kind == DATASTORE_IDENTITY_REFERENCED
            or self.kind == DATASTORE_IDENTITY_OWNED_AND_REFERENCED
        )

    def declared(self) -> Bool:
        """True iff a database is named at all (OWNED or REFERENCED) — i.e. iff the
        `${datastore_database}` marker has a value to resolve to."""
        return self.kind != DATASTORE_IDENTITY_NONE


# =============================================================================
# ★ THE PLACEMENT RULE — a managed app's database lives in the CUSTOMER'S
#   project, created by that app's own deploy. A managed app never names or
#   references the operator's control-plane database.
# =============================================================================
#
# ── ⛔ WHY THIS IS IN THE VALIDATOR AND NOT ONLY IN A TEST ───────────────────
# A rule asserted over a hand-written list of bundles covers only the bundles on
# the list: a bundle added later is unchecked, and the gate stays green on the
# day it grows a database. A rule enforced by a list somebody must remember to
# extend is not enforced; it is documented, and it is documented most
# convincingly right up until it matters. A refusal of a customer SERVICE in a
# control-plane environment says nothing about the DATABASE, which is a
# different node with a different seam.
#
# So the rule lives HERE, in `validate_bundle`, where it applies to every spec
# of every bundle that is parsed — including the ones nobody has written yet.
#
# ── THE THREE REFUSALS, AND WHY EACH IS A SEPARATE ONE ──────────────────────
#
#   R1 REFERENCE   A customer bundle may not `datastore_database_ref`. Referencing
#                  means "another release machine owns this database" — and in a
#                  customer's account there IS no other release machine. The
#                  reference can only resolve to the OPERATOR's database, which is
#                  the exact failure the placement rule names.
#   R2 CP NAME     A customer bundle may not name an operator database. This is
#                  the placement rule restated at authoring time.
#   R3 SILENCE     A customer bundle may not leave `datastore` UNSPECIFIED.
#
# ── ★ R3 IS THE ONE THAT IS NOT OBVIOUS, AND IT IS THE ROOT CAUSE ───────────
# `DatastoreNeed`'s zero value is `DATASTORE_NEED_UNSPECIFIED`, and the proto says
# so in words: "UNSPECIFIED ⇒ NONE (no datastore)". So an author who never thought
# about the datastore produces bytes IDENTICAL to one who decided the app is
# stateless. That bundle stamps no `*_FIRESTORE_DATABASE` env, and the deployed
# binary then falls back to ITS OWN COMPILED-IN DEFAULT — a value the bundle's
# author never chose and cannot see from the bundle. Different binaries carry
# different defaults (`(default)`, the app's own name, or even the operator's
# `control-plane`), so the silence is dangerous rather than merely untidy.
#
# ⚠ CONTRAST `Tenancy`, whose own proto comment says it has no default
# DELIBERATELY: "defaulting a new project to 'not control plane' is how a managed
# app reaches Komira's account". `DatastoreNeed` has a zero value, so R3 applies
# the same discipline WITHOUT a proto change: silence is refused,
# `DATASTORE_NEED_NONE` must be said OUT LOUD, and the two states stop being
# byte-identical.
#
# ── ⚠ WHAT THIS DOES **NOT** CATCH, STATED PLAINLY ──────────────────────────
# A bundle that declares `DATASTORE_NEED_NONE` while its binary writes documents
# anyway is still ACCEPTED here. This validator reads the BUNDLE; it cannot read
# the binary. That is the "declared by NOBODY" shape, and it is strictly worse
# than a wrong name: a wrong target fails LOUDLY against one database, an absent
# declaration fails SILENTLY against every one. Closing it needs the bundle's
# declaration cross-checked against the shipped binary's declared tables — a
# different oracle.
#
# PURE, ZERO I/O — same contract as everything else in this file.
# =============================================================================

comptime CONTROL_PLANE_DATABASE_ID: StaticString = "control-plane"
"""The OPERATOR's ROOT database id, and the STEM of the operator's whole naming
namespace (see `CONTROL_PLANE_DATABASE_SEP` / `is_control_plane_database_id`).
Spelled once so the check and the message cannot drift apart."""

comptime CONTROL_PLANE_DATABASE_SEP: StaticString = "control-plane-"
"""The operator's REGIONAL/qualified stem. Every operator database id is either
`control-plane` exactly or begins with this."""


def is_control_plane_database_id(id: String) -> Bool:
    """True iff `id` is a database in the OPERATOR's namespace.

    ★ IT IS A RULE, NOT A LIST. An operator may own more than one database (for
    example a root `control-plane` and a regional `control-plane-us-central1`). An
    equality test against one name would let a `TENANCY_CUSTOMER` bundle author

        datastore_database: "control-plane-us-central1"

    and validate clean, so a managed app would ensure its schema into the
    operator's own regional database.

    The rule: `control-plane`, or anything under
    `control-plane-`. It is TOTAL over ids that do not exist yet: the operator's
    NEXT regional database (`control-plane-europe-west1`, …) is refused to managed
    apps the moment it is named, with no edit here and nobody to remember.

    ★ AND THE RULE'S COMPLETENESS IS ITSELF GATED, IN BOTH DIRECTIONS, because a
    naming rule is only as good as the operator's willingness to obey it:
      * `control_plane_database_namespace_error` (below) refuses an OPERATOR bundle
        that owns a database this predicate does NOT match — so the operator cannot
        acquire a database outside the namespace the rule can see. That is the arm
        that keeps this predicate total going forward; without it the rule decays
        into a list again the first time someone names one `operator-meta`.
      * an offline check over checked-in bundles should read THIS constant rather
        than restate it, so the offline gate and the in-binary refusal cannot drift
        to two different spellings.

    ⚠ THE PREFIX IS `control-plane-` AND NOT `control-plane`, deliberately. A bare
    stem test would also claim `control-planet` / `control-planning` — plausible app
    names — for the operator, and refusing a managed app a name it is entitled to is
    a false refusal that teaches authors to route around the gate. The separator
    makes the namespace exact.

    PURE. Same contract as everything else in this file."""
    return id == String(CONTROL_PLANE_DATABASE_ID) or id.startswith(
        String(CONTROL_PLANE_DATABASE_SEP)
    )


def control_plane_database_namespace_error(
    ctx: String, is_customer_tenancy: Bool, sp: AppSpec
) -> String:
    """The OTHER HALF OF THE PARTITION: an OPERATOR bundle may not OWN a database
    outside the operator's namespace. EMPTY if there is none. Returns a message
    (never raises) for the same two-presentation reason as its neighbours.

    ★ WHY THIS ARM EXISTS AT ALL, AND WHY IT IS NOT REDUNDANT WITH R2.
    ==================================================================
    R2 stops a managed app from reaching INTO the operator's namespace. Nothing
    else stops the operator from reaching OUT of it. Those are different failures
    with the same outcome: an operator project holding app-named databases, or a
    customer project holding a `control-plane` database.

    A rule that only fires in one direction leaves the id namespace OVERLAPPING,
    and while it overlaps no gate downstream can tell an operator database from an
    app database BY ITS NAME — which is exactly what a deployed-topology check must
    do to compare deployed topology against the declared boundary. This arm is
    what makes the name a DECISION PROCEDURE rather than a convention.

    ⚠ IT DOES NOT REFUSE A REFERENCE. An operator bundle referencing an
    operator-named database is the correct arrangement (control-plane services
    `datastore_database_ref: "control-plane"`). Only OWNERSHIP is checked here,
    because ownership is what CREATES a database, and creation is the
    irreversible half."""
    if is_customer_tenancy:
        return String("")
    if sp.datastore_database.byte_length() == 0:
        return String("")
    if is_control_plane_database_id(sp.datastore_database):
        return String("")
    return (
        ctx
        + String(
            ": is an OPERATOR bundle (not `tenancy: TENANCY_CUSTOMER`) and may not"
            " OWN the database `"
        )
        + sp.datastore_database
        + String(
            "`. The Firestore database id namespace is PARTITIONED BY TENANCY: `"
        )
        + String(CONTROL_PLANE_DATABASE_ID)
        + String("` and `")
        + String(CONTROL_PLANE_DATABASE_SEP)
        + String(
            "*` are the OPERATOR's names; every other name belongs to an APP and may"
            " only be owned by a `tenancy: TENANCY_CUSTOMER` bundle, whose deploy"
            " creates it IN THE CUSTOMER'S PROJECT. An operator bundle owning an"
            " app-shaped name is how the operator's own project comes to hold a"
            " managed app's database. If this really is an operator"
            " database, name it `"
        )
        + String(CONTROL_PLANE_DATABASE_SEP)
        + String(
            "<what it holds>`; if it is an app's, move the declaration to that app's"
            " `tenancy: TENANCY_CUSTOMER` bundle."
        )
    )


def managed_app_placement_error(
    ctx: String, is_customer_tenancy: Bool, sp: AppSpec
) -> String:
    """The placement refusal for `sp` under a `TENANCY_CUSTOMER` bundle, or EMPTY if
    there is none. Returns a message (never raises) so `validate_bundle` can
    accumulate it with its other findings — the same two-presentation contract
    `datastore_identity_error` above already uses.

    `is_customer_tenancy` is passed as a Bool rather than read off the bundle so this
    module keeps its per-SPEC shape and takes no new import: the tenancy axis lives
    on the BUNDLE, the datastore axis lives on the SPEC, and this is the one place
    they meet.

    A non-customer bundle returns EMPTY for every input — the rule is DELIBERATELY
    ASYMMETRIC, exactly as `refuse_customer_workload_in_control_plane` is. The
    control plane owning `control-plane` is the correct and intended arrangement."""
    if not is_customer_tenancy:
        return String("")

    # ── R3 SILENCE ──────────────────────────────────────────────────────────
    if sp.datastore.value == DatastoreNeed.DATASTORE_NEED_UNSPECIFIED:
        return (
            ctx
            + String(
                ": a `tenancy: TENANCY_CUSTOMER` bundle must STATE its `datastore`"
                " intent. `DatastoreNeed`'s zero value is UNSPECIFIED and means"
                " NONE, so leaving it out is byte-identical to deciding this app"
                " is stateless — and a bundle that declares no datastore stamps no"
                " `*_FIRESTORE_DATABASE` env, which leaves the deployed binary to"
                " fall back to its own default (which may be the operator's"
                " `control-plane` database). Write `datastore:"
                " DATASTORE_NEED_NONE` if this app truly stores nothing, or"
                " `DATASTORE_NEED_SERVERLESS` with a `datastore_database` it owns."
            )
        )

    # ── R1 REFERENCE ────────────────────────────────────────────────────────
    if sp.datastore_database_ref.byte_length() > 0:
        return (
            ctx
            + String(": is a MANAGED APP (`tenancy: TENANCY_CUSTOMER`) and may not")
            + String(" `datastore_database_ref: \"")
            + sp.datastore_database_ref
            + String(
                "\"`. A REFERENCE means another release machine owns that database"
                " — and a managed app runs in a CUSTOMER's account, where there is"
                " exactly one tenant and no shared infrastructure to reference. So"
                " the reference can only resolve to the OPERATOR's database, which"
                " is the placement this rule exists to make impossible. Own it:"
                " `datastore_database:`."
            )
        )

    # ── R2 CP NAME ──────────────────────────────────────────────────────────
    # A namespace rule, not an equality test: see `is_control_plane_database_id`.
    if is_control_plane_database_id(sp.datastore_database):
        return (
            ctx
            + String(
                ": is a MANAGED APP (`tenancy: TENANCY_CUSTOMER`) and may not name"
                " the database `"
            )
            + sp.datastore_database
            + String("`, which is in the OPERATOR's namespace (`")
            + String(CONTROL_PLANE_DATABASE_ID)
            + String("`, or anything under `")
            + String(CONTROL_PLANE_DATABASE_SEP)
            + String(
                "`). A managed app's database is created IN THE CUSTOMER'S PROJECT"
                " by that app's own deploy, and putting the operator's"
                " control-plane name on a customer's database is the violation the"
                " placement rule names: a managed app never references the"
                " control-plane database at all. Name it after what it HOLDS."
            )
        )

    return String("")


def spec_declares_datastore(sp: AppSpec) -> Bool:
    """True iff this service's `datastore` intent emits a DATASTORE node — the SAME
    predicate `compose_api` keys node emission on (SERVERLESS/DEDICATED), restated
    here so this resolver's answer cannot drift from whether a node will actually be
    composed."""
    return (
        sp.datastore.value != DatastoreNeed.DATASTORE_NEED_UNSPECIFIED
        and sp.datastore.value != DatastoreNeed.DATASTORE_NEED_NONE
    )


def is_valid_firestore_database_id(id: String) -> Bool:
    """A valid Firestore database id: the literal `(default)`, or 4-63 chars of
    `[a-z0-9-]` beginning with a letter and ending alphanumeric. Checked at
    AUTHORING time because the alternative place to find out is a 400 from
    `databases.create` in the middle of an apply that has already provisioned half a
    graph."""
    if id == String("(default)"):
        return True
    var n = id.byte_length()
    if n < 4 or n > 63:
        return False
    var b = id.as_bytes()
    var first = Int(b[0])
    if first < ord("a") or first > ord("z"):
        return False
    var last = Int(b[n - 1])
    var last_alnum = (last >= ord("a") and last <= ord("z")) or (
        last >= ord("0") and last <= ord("9")
    )
    if not last_alnum:
        return False
    for i in range(n):
        var c = Int(b[i])
        var ok = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
        )
        if not ok:
            return False
    return True


def datastore_identity_error(ctx: String, sp: AppSpec) -> String:
    """The refusal `resolve_datastore_identity` would raise for `sp`, or EMPTY if it
    would succeed — so the bundle VALIDATOR can accumulate this alongside its other
    findings (it reports ALL errors, it does not stop at the first) while the deploy
    seam RAISES on the same condition. ONE rule, two presentations; the alternative
    is two copies of a four-case policy that can disagree.

    `ctx` prefixes the message (`spec` / `services[2] 'orders'`) so the finding names
    the service, not just the bundle."""
    var declares = spec_declares_datastore(sp)
    var owned = sp.datastore_database.copy()
    var borrowed = sp.datastore_database_ref.copy()
    var has_owned = owned.byte_length() > 0
    var has_ref = borrowed.byte_length() > 0

    # ── BOTH: a service cannot own and borrow the same database ──────────────
    if has_owned and has_ref:
        return (
            ctx
            + String(": names BOTH `datastore_database` ('")
            + owned
            + String("') AND `datastore_database_ref` ('")
            + borrowed
            + String(
                "'). These are MUTUALLY EXCLUSIVE — the first says this release"
                " machine OWNS the database (its deploy creates it and ensures every"
                " composite index), the second says another release machine owns it"
                " and this deploy may only open it. A service cannot be both, and"
                " there is deliberately no tie-break: a precedence rule here would be"
                " a silent policy that decides who provisions your data. Keep the arm"
                " that is true and delete the other."
            )
        )

    # ── NEITHER, on a datastore-bearing service: the refusal that IS the
    #    customer case ──────────────────────────────────────────────────────
    if declares and not has_owned and not has_ref:
        return (
            ctx
            + String(
                ": declares `datastore: SERVERLESS/DEDICATED` but names NO database."
                " State exactly ONE of:\n"
                "  * `datastore_database: \"<id>\"` — this release machine OWNS the"
                " database and its deploy creates and indexes it. This is the answer"
                " for a MANAGED APP: a customer account has one tenant and no shared"
                " infrastructure to share, so a managed app always owns its own"
                " (for example an app `orders` -> database `orders`).\n"
                "  * `datastore_database_ref: \"<id>\"` — another release machine owns"
                " it and this deploy only opens it. This is the answer for a CONTROL"
                " PLANE service sharing the operator's `control-plane` database, which"
                " a shared-infrastructure bundle owns.\n"
                "There is deliberately NO default. `control-plane` as a default is"
                " what named EVERY account's database after the control plane; a name"
                " derived from the app would silently repoint an existing deploy at a"
                " fresh EMPTY database — create-if-absent succeeds, the indexes get"
                " ensured, the deploy goes green, and every document written before"
                " that day is invisible, with no error anywhere in the sequence."
            )
        )

    # ── A NAME ON A SERVICE WITH NO DATASTORE addresses nothing ─────────────
    if not declares and (has_owned or has_ref):
        var which = String("datastore_database")
        var val = owned.copy()
        if has_ref:
            which = String("datastore_database_ref")
            val = borrowed.copy()
        return (
            ctx
            + String(": '")
            + which
            + String("' is set to '")
            + val
            + String(
                "' but 'datastore' is NONE/unset — this service provisions and opens"
                " no database, so the name addresses nothing while reading as the"
                " thing in control. Declare `datastore: DATASTORE_NEED_SERVERLESS` or"
                " drop the name."
            )
        )

    # ── SHAPE ───────────────────────────────────────────────────────────────
    if has_owned and not is_valid_firestore_database_id(owned):
        return (
            ctx
            + String(": 'datastore_database' value '")
            + owned
            + String(
                "' is not a valid Firestore database id — use `(default)`, or 4-63"
                " chars of [a-z0-9-] starting with a letter and ending alphanumeric."
            )
        )
    if has_ref and not is_valid_firestore_database_id(borrowed):
        return (
            ctx
            + String(": 'datastore_database_ref' value '")
            + borrowed
            + String(
                "' is not a valid Firestore database id — use `(default)`, or 4-63"
                " chars of [a-z0-9-] starting with a letter and ending alphanumeric."
            )
        )
    return String("")


def resolve_datastore_identity(ctx: String, sp: AppSpec) raises -> DatastoreIdentity:
    """★ THE ONE READER of `datastore_database` / `datastore_database_ref`. Returns
    the service's identity, or RAISES the refusal `datastore_identity_error` states.

    Call this; never read the two fields. A reader that picks one of them has
    silently chosen an ownership policy, which is the class of decision this whole
    change exists to take out of the hands of whoever edits next."""
    var err = datastore_identity_error(ctx, sp)
    if err.byte_length() > 0:
        raise Error(err)
    if sp.datastore_database_ref.byte_length() > 0:
        return DatastoreIdentity(
            DATASTORE_IDENTITY_REFERENCED, sp.datastore_database_ref.copy()
        )
    if sp.datastore_database.byte_length() > 0:
        return DatastoreIdentity(
            DATASTORE_IDENTITY_OWNED, sp.datastore_database.copy()
        )
    return DatastoreIdentity(DATASTORE_IDENTITY_NONE, String(""))
