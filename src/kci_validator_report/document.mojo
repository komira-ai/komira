# =============================================================================
# kci_validator_report/document.mojo — ★ THE RECORD: `VALIDATION_SCHEMA`,
#   ONE self-contained JSON document per validate STEP.
# =============================================================================
#
# ⛔ THIS RECORD IS EVIDENCE, NOT AUTHORIZATION. NOTHING MAY GATE ON IT.
#
# It is written by the party being gated, into a bucket that party can write.
# A stricter reader of a file the gated party writes is a formality, not evidence.
#
# The gate stays where it already is, in the two places the judged run cannot
# write:
#   * the EXIT CODE of the validate DAG, and
#   * the BUILD GRAPH (a test's pass marker is an INPUT to the artifact).
# A promotion gate between environments keys on DIGEST IDENTITY read from both
# environments' own ledgers. It does not read this document and must never learn
# to.
#
# ⚠ AND THE INVERSION IS THE ONE TO WATCH FOR. This record is strictly MORE
# citable than a red gate's rows in a job's stdout that the DAG cannot read, so a
# durable, queryable, per-target record is exactly what somebody will reach for
# when they want a green light cheaply. EVERY field here answers "what did this
# run OBSERVE". NO field answers "may this PROCEED". If you are adding one, you
# are rebuilding a self-attested pass file with better formatting.
#
# ── ★ WHY ONE SELF-CONTAINED DOCUMENT AND NOT AN ICEBERG COMMIT ─────────────
# Iceberg is the DESTINATION, not the write primitive. A validator writes ONE
# document with ONE PUT — no read, no coordination, no CAS. Two reasons, both
# structural:
#   * A RECORD MUST SURVIVE A BROKEN ENVIRONMENT, and an Iceberg commit is six
#     operations that fail hardest exactly when the env is sick.
#   * A wave runs many steps, each with several matrices; direct commits would
#     race ONE CAS pointer.
# A separate ingestion step appends these documents into the table. THE RAW JSON
# IS THE SOURCE OF TRUTH; THE TABLE IS DERIVED AND REBUILDABLE.
#
# ── ⚠ THE DOCUMENT IS PER STEP, AND THE STEP DOCUMENT IS ONLY HALF THE RECORD
# The validator can see its rows; it CANNOT see the wave, the selector set, the
# emitted `DEPLOY-EVIDENCE:` token, or authored-vs-run step counts — those are
# knowable only after the wave ends. The DAG writes a RUN document carrying them.
# ⛔ UNTIL THAT HALF EXISTS, A STEP DOCUMENT MUST NOT BE READ AS COVERAGE: it can
# say what this step observed and it CANNOT say whether the run was selective.
#
# NO deps beyond this package. Pure `String` work: no clock (timestamps are
# threaded in), no store, no JSON library.
# def-based, Mojo 1.0.0b2.
# =============================================================================

from kci_validator_report.outcome import MatrixOutcome
from kci_validator_report.row import RowResult, NO_TARGET, NO_STATUS
from kci_validator_report.state import row_state_token
from kci_validator_report.target import ReportTarget, ReportGuard


comptime VALIDATION_SCHEMA: String = "komira_ci.validation.v1"
"""The `schema` field — the STABILITY handle the UI and any query tool script
against. Versioning follows the deploy-outputs record's `OUTPUTS_SCHEMA`
(`komira_deploy_outputs`): a backward-incompatible SHAPE change gets a new token (`…v2`);
additive fields do NOT bump it."""

comptime DOC_KIND_STEP: String = "step"
"""Written by the VALIDATOR. One per validate step."""

comptime DOC_KIND_RUN: String = "run"
"""Written by the validate DAG at wave end. Carries the evidence token, the
selector sets and the coverage census."""

comptime NOT_A_GATE_NOTICE: String = (
    "EVIDENCE, not authorization. The gate is the exit code and the build graph."
    " Nothing may read this record back as permission to proceed."
)
"""★ THE DOCTRINE, IN THE DOCUMENT. It is in the bytes and not only in a header
comment because the reader who reaches for this record as a green light will be
reading the JSON, not this file."""

comptime VALIDATION_RAW_PREFIX: String = "raw"
"""The key segment raw step documents live under, INSIDE the store's own
`validation` prefix. Full object path: `validation/raw/<env>/<run_id>/<step>.json`.

★ `<env>` IS LOAD-BEARING, NOT COSMETIC. `env -> bucket` is NOT injective: two
environments that bind the same account resolve to the same bootstrap bucket. A
table located by BUCKET alone silently merges two environments' history."""

comptime RECORD_LINE_WRITTEN: String = "VALIDATION-RECORD: WRITTEN "
"""⛔ AND THE VALIDATOR'S EXIT CODE DOES NOT CHANGE EITHER WAY. The record is not
load-bearing for the deploy, so a failed PUT that REDS a green wave would make it
a gate by the back door; a silently-swallowed PUT would turn "nobody recorded"
into "recorded nothing". The line is printed, the run document carries
`step_records[].status`, and an unwritten step is visible IN the queryable record
itself."""

comptime RECORD_LINE_NOT_WRITTEN: String = "VALIDATION-RECORD: NOT-WRITTEN "


# =============================================================================
# §1 — the KEY derivation. ONE function, so writer and reader cannot drift.
# =============================================================================
def validation_step_key(
    env: String, run_id: String, step: String
) raises -> String:
    """`raw/<env>/<run_id>/<step>.json`, RELATIVE to the store's `validation`
    prefix — the same relationship `OUTPUTS_REGISTRY_PREFIX` has to
    `service/<name>`.

    FAIL-LOUD on a component that would escape the prefix or collide: a `/`, a
    `..`, or an empty component. A step name is authored text and a record that
    silently lands outside its env's tree is a record nobody will find."""
    _refuse_bad_component(String("env"), env)
    _refuse_bad_component(String("run_id"), run_id)
    _refuse_bad_component(String("step"), step)
    return (
        VALIDATION_RAW_PREFIX
        + String("/")
        + env
        + String("/")
        + run_id
        + String("/")
        + step
        + String(".json")
    )


def _refuse_bad_component(what: String, value: String) raises:
    if value.byte_length() == 0:
        raise Error(
            String("validation_step_key: ")
            + what
            + String(
                " is EMPTY. A record written to a path with a missing component"
                " is a record nobody can query back."
            )
        )
    var bs = value.as_bytes()
    for i in range(len(bs)):
        var c = Int(bs[i])
        if c == ord("/"):
            raise Error(
                String("validation_step_key: ")
                + what
                + String(" contains '/': '")
                + value
                + String(
                    "'. A component with a separator escapes its env's tree —"
                    " and `env -> bucket` is not injective, so two environments"
                    " share one bucket and would silently merge."
                )
            )
        if c < 0x20:
            raise Error(
                String("validation_step_key: ")
                + what
                + String(" contains a control byte")
            )
    if value == String("..") or value == String("."):
        raise Error(
            String("validation_step_key: ")
            + what
            + String(" is a path traversal component")
        )


# =============================================================================
# §2 — the PARTITION column. `run_date` is a MATERIALIZED "YYYY-MM-DD" string.
# =============================================================================
def run_date_from_micros(micros: Int) raises -> String:
    """`YYYY-MM-DD` (UTC) for a microsecond epoch stamp.

    ★ MATERIALIZED, NOT DERIVED AT READ TIME, because the destination table's
    only available partition transforms are IDENTITY and BUCKET
    (`komira_iceberg`) — there is no `day(ts)`, and its type set has no
    TIMESTAMP at all. So the partition column
    has to be a real string column in the record.

    ⚠ AND IT IS DERIVED FROM `started_at_us` RIGHT HERE rather than passed in.
    A caller-supplied date string can disagree with the caller-supplied
    timestamp, and a record whose partition contradicts its own clock is
    unqueryable in the one way that matters (a query for
    "everything that failed last week" prunes on exactly this column).

    Civil-from-days (Howard Hinnant's algorithm), integer-only. NEGATIVE stamps
    are REFUSED rather than floored: a pre-epoch validation run is a broken
    clock, and silently rendering `1969-…` would put the record in a partition no
    query looks at."""
    if micros < 0:
        raise Error(
            String("run_date_from_micros: negative epoch stamp ")
            + String(micros)
            + String(
                " — a pre-epoch validation run is a broken clock, and the record"
                " would land in a partition no query prunes to."
            )
        )
    var z = micros // 86400000000
    z += 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (
        String(y) + String("-") + _pad2(m) + String("-") + _pad2(d)
    )


def _pad2(v: Int) -> String:
    if v < 10:
        return String("0") + String(v)
    return String(v)


# =============================================================================
# §3 — byte-faithful JSON quoting.
# =============================================================================
def json_quote(s: String) -> String:
    """Byte-faithful JSON string quoting: minimal escaping (CR/LF/tab/quote/
    backslash), every other byte — including UTF-8 continuation bytes >= 0x80 —
    copied through VERBATIM into an owned byte buffer.

    Byte-fidelity: an `out += chr(c)` accumulation would re-encode each
    non-escaped byte as codepoint U+00XX, double-encoding every multibyte UTF-8
    sequence (an em-dash `e2 80 94` written as `c3 a2 c2 80 c2 94`). Validator
    details carry em-dashes and ⛔ marks in quantity, so this is not a theoretical concern for THIS record."""
    var buf = List[UInt8]()
    buf.append(0x22)
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        var c = bs[i]
        if c == 0x22:
            buf.append(0x5C)
            buf.append(0x22)
        elif c == 0x5C:
            buf.append(0x5C)
            buf.append(0x5C)
        elif c == 0x0D:
            buf.append(0x5C)
            buf.append(0x72)
        elif c == 0x0A:
            buf.append(0x5C)
            buf.append(0x6E)
        elif c == 0x09:
            buf.append(0x5C)
            buf.append(0x74)
        elif c < 0x20:
            # Any other C0 control byte -> \u00XX (JSON forbids them raw).
            buf.append(0x5C)
            buf.append(0x75)
            buf.append(0x30)
            buf.append(0x30)
            buf.append(_hex_nibble(Int(c) // 16))
            buf.append(_hex_nibble(Int(c) % 16))
        else:
            buf.append(c)
        i += 1
    buf.append(0x22)
    return String(unsafe_from_utf8=Span(buf))


def _hex_nibble(v: Int) -> UInt8:
    if v < 10:
        return UInt8(0x30 + v)
    return UInt8(0x61 + (v - 10))


def _kv(key: String, value: String) -> String:
    return json_quote(key) + String(":") + json_quote(value)


def _kn(key: String, value: Int) -> String:
    return json_quote(key) + String(":") + String(value)


def _kb(key: String, value: Bool) -> String:
    var v = String("true") if value else String("false")
    return json_quote(key) + String(":") + v^


# =============================================================================
# §4 — render_step_document — the whole record, as one String.
# =============================================================================
def render_step_document(
    env: String,
    bundle: String,
    wave: String,
    step: String,
    run_id: String,
    validator: String,
    validator_version: String,
    started_at_us: Int,
    finished_at_us: Int,
    targets: List[ReportTarget],
    outcomes: List[MatrixOutcome],
    guards: List[ReportGuard],
    exit_code: Int,
) raises -> String:
    """The `VALIDATION_SCHEMA` STEP document.

    ⛔ REFUSES a row whose `target_index` is out of `targets`' bounds. A dangling
    attribution renders a row as validating a target nobody listed — the
    confidently-wrong shape, and the exact failure this schema exists to delete.
    It is a CALLER error (a broken environment cannot produce one), so it is
    caught by the falsifier rather than degraded at runtime.

    ⚠ IT DOES NOT RE-DERIVE `exit_code`. The code is what the PROCESS exited
    with, threaded in by the caller: a document that computed its own verdict
    could disagree with the gate, and the gate is the exit code."""
    var run_date = run_date_from_micros(started_at_us)

    var out = String("{\n")
    out += String("  ") + _kv(String("schema"), VALIDATION_SCHEMA) + String(",\n")
    out += String("  ") + _kv(String("doc_kind"), DOC_KIND_STEP) + String(",\n")
    out += String("  ") + _kv(String("not_a_gate"), NOT_A_GATE_NOTICE) + String(",\n")
    out += String("  ") + _kv(String("run_id"), run_id) + String(",\n")
    out += String("  ") + _kv(String("env"), env) + String(",\n")
    out += String("  ") + _kv(String("bundle"), bundle) + String(",\n")
    out += String("  ") + _kv(String("wave"), wave) + String(",\n")
    out += String("  ") + _kv(String("step"), step) + String(",\n")
    out += String("  ") + _kv(String("validator"), validator) + String(",\n")
    out += String("  ") + _kv(String("validator_version"), validator_version) + String(",\n")
    out += String("  ") + _kn(String("started_at_us"), started_at_us) + String(",\n")
    out += String("  ") + _kn(String("finished_at_us"), finished_at_us) + String(",\n")
    out += String("  ") + _kv(String("run_date"), run_date^) + String(",\n")

    # ── targets ──────────────────────────────────────────────────────────────
    out += String("  \"targets\": [\n")
    for i in range(len(targets)):
        out += String("    {")
        out += _kv(String("name"), targets[i].name) + String(", ")
        out += _kv(String("kind"), targets[i].kind) + String(", ")
        out += _kv(String("version"), targets[i].version) + String(", ")
        out += _kv(String("version_source"), targets[i].version_source) + String(", ")
        out += _kv(String("version_note"), targets[i].version_note) + String(", ")
        out += _kv(String("endpoint"), targets[i].endpoint)
        out += String("}")
        if i + 1 < len(targets):
            out += String(",")
        out += String("\n")
    out += String("  ],\n")

    # ── legs ─────────────────────────────────────────────────────────────────
    var n_rows = 0
    var n_passed = 0
    var n_failed = 0
    var n_not_run = 0
    var n_not_reached = 0
    var n_unreadable = 0
    var n_asserted = 0

    out += String("  \"legs\": [\n")
    for li in range(len(outcomes)):
        ref oc = outcomes[li]
        n_rows += oc.total()
        n_passed += oc.asserted_passed_count()
        n_failed += oc.failed_count()
        n_not_run += oc.not_run_count()
        n_not_reached += oc.not_reached_count()
        n_unreadable += oc.unreadable_count()
        n_asserted += oc.asserted_count()

        out += String("    {")
        out += _kv(String("leg"), oc.leg) + String(", ")
        out += _kv(String("validator"), oc.validator) + String(", ")
        out += _kn(String("authored"), len(oc.expected)) + String(", ")
        out += _kv(String("accounting_fault"), oc.accounting_fault()) + String(", ")
        out += _kv(String("verdict"), oc.verdict_line()) + String(",\n")
        out += String("     \"rows\": [\n")
        for ri in range(len(oc.rows)):
            ref r = oc.rows[ri]
            if r.target_index != NO_TARGET:
                if r.target_index < 0 or r.target_index >= len(targets):
                    raise Error(
                        String("render_step_document: row '")
                        + r.name.copy()
                        + String("' in leg '")
                        + oc.leg.copy()
                        + String("' has target_index ")
                        + String(r.target_index)
                        + String(" but the document lists ")
                        + String(len(targets))
                        + String(
                            " targets. A row attributed to a target nobody"
                            " listed renders as validating something this run"
                            " never named."
                        )
                    )
            out += String("       {")
            out += _kn(String("row_index"), ri) + String(", ")
            out += _kv(String("name"), r.name) + String(", ")
            out += _kn(String("target_index"), r.target_index) + String(", ")
            out += _kv(String("subject"), r.subject) + String(", ")
            out += _kv(String("observed"), r.observed) + String(", ")
            out += _kv(String("expected"), r.expected) + String(", ")
            out += _kv(String("state"), row_state_token(r.state)) + String(", ")
            out += _kn(String("status"), r.status) + String(", ")
            out += _kv(String("remediation"), r.remediation) + String(", ")
            out += _kv(String("detail"), r.detail)
            out += String("}")
            if ri + 1 < len(oc.rows):
                out += String(",")
            out += String("\n")
        out += String("     ]}")
        if li + 1 < len(outcomes):
            out += String(",")
        out += String("\n")
    out += String("  ],\n")

    # ── guards ───────────────────────────────────────────────────────────────
    var n_held = 0
    var n_broken = 0
    out += String("  \"guards\": [\n")
    for i in range(len(guards)):
        if guards[i].held:
            n_held += 1
        else:
            n_broken += 1
        out += String("    {")
        out += _kv(String("name"), guards[i].name) + String(", ")
        out += _kb(String("held"), guards[i].held) + String(", ")
        out += _kv(String("reason"), guards[i].reason)
        out += String("}")
        if i + 1 < len(guards):
            out += String(",")
        out += String("\n")
    out += String("  ],\n")

    # ── totals ───────────────────────────────────────────────────────────────
    out += String("  \"totals\": {")
    out += _kn(String("rows"), n_rows) + String(", ")
    out += _kn(String("passed"), n_passed) + String(", ")
    out += _kn(String("failed"), n_failed) + String(", ")
    out += _kn(String("not_run"), n_not_run) + String(", ")
    out += _kn(String("not_reached"), n_not_reached) + String(", ")
    out += _kn(String("unreadable"), n_unreadable) + String(", ")
    out += _kn(String("asserted"), n_asserted) + String(", ")
    out += _kn(String("guards_held"), n_held) + String(", ")
    out += _kn(String("guards_broken"), n_broken)
    out += String("},\n")
    out += String("  ") + _kn(String("exit_code"), exit_code) + String("\n")
    out += String("}\n")
    return out^


# =============================================================================
# §5 — ★ THE RUN DOCUMENT. `doc_kind: run`, ONE per validate wave.
# =============================================================================
#
# ⛔⛔ THIS HALF EXISTS BECAUSE A STEP DOCUMENT CANNOT SAY WHETHER THE RUN WAS
# SELECTIVE, AND A PILE OF GREEN STEP DOCUMENTS READS EXACTLY LIKE A FULL PASS.
#
# `§4`'s header states the hazard and defers the fix: *"UNTIL THAT HALF EXISTS, A
# STEP DOCUMENT MUST NOT BE READ AS COVERAGE."* This is that half. The validator
# can see its rows; it CANNOT see the wave, the selector set, the emitted
# `DEPLOY-EVIDENCE:` token, or authored-vs-executed counts — all four are
# knowable only at the DAG, after the wave ends.
#
# ★ THE ACCOUNTING IS REFUSED, NOT REPORTED. `authored` is passed as the LIST of
# every gate the wave declared, and `executed + skipped + deselected` must
# reproduce it EXACTLY — same names, no name in two sets and none in neither. A
# run document that says "N executed" while the wave authored M and names no
# third set is precisely how "N of M" comes to render as "M of M",
# and it is the one thing this document exists to make unrenderable. It is a
# CALLER error, so it RAISES.
#
# ⛔ AND THE EVIDENCE TOKEN IS CARRIED, NEVER DERIVED HERE. The release CLI's
# evidence verdict is the ONE function that
# decides which of the six words a run earned, and it lives on the other side of
# a package boundary this leaf may not cross. Re-deriving it here would produce a
# SECOND answer to a question the deploy already answered out loud, and the two
# would drift the first time a token is added. So the caller passes the token it
# EMITTED — and `render_run_document` refuses an empty one.
# =============================================================================

comptime EVIDENCE_NOT_EMITTED: String = "NOT-EMITTED(run-did-not-pass)"
"""★ WHAT TO PASS AS `deploy_evidence` WHEN THE RUN DID NOT PASS.

`deploy_evidence_line` is stamped ONLY on the success path — a FAILED wave emits
no `DEPLOY-EVIDENCE:` line at all. So there is no token to carry, and the record
must not invent one.

⛔ DO NOT PASS `deploy_evidence_verdict(...)` FOR A FAILED RUN TO FILL THE FIELD.
With `ran_validation=False` and no skips that function returns
`UNVALIDATED(no-gates-authored)` — which, about a wave whose gates ran and
FAILED, is not merely imprecise: it is false in the one direction that matters,
blaming the bundle for authoring nothing when the bundle authored gates that went
red.

⚠ IT IS PREFIX-SAFE UNDER THE SAME `grep`. `NOT-EMITTED(...)` does not contain
`VALIDATED`, so a reader checking the cheap thing still gets the right answer."""

comptime AUDIENCE_OPERATOR_INTERNAL: String = "operator-internal"
"""★★ WHO MAY READ THIS RECORD, STATED IN THE RECORD. Customers will need
validation records, and this record does NOT yet serve them.

TWO reasons this document is INTERNAL until something changes:

  1. ⛔ THE LOCATION IS FLEET-WIDE, NOT TENANT-SCOPED. An environment's bootstrap
     bucket holds `service/`, `staged-content/` and `staged-image/` — every app
     in the env, in one bucket, behind one ACL. Putting `validation/` beside them
     means a reader with bucket read gets EVERY tenant's records. That is correct
     for an operator and disqualifying for a customer, and NO KEY LAYOUT FIXES
     IT: the bucket is the grant boundary, so a per-tenant prefix under a shared
     bucket buys separation of naming and none of access.
  2. ⛔ `detail` IS NOT REDACTED FOR AN EXTERNAL READER. It carries the deploy
     tool's own diagnostic blocks — which can name the operator's project ids,
     runtime service-account emails and cloud CLI commands against the
     operator's projects — plus remediation prose addressed to the operator.

⇒ THE FIELD IS A GATE ON A FUTURE CHANGE, NOT DECORATION. A customer-readable
surface has to (a) land in a per-tenant location and (b) carry a REDACTED
projection of `detail` — and whoever builds it must flip this value deliberately.
A record that silently became customer-visible while still saying
`operator-internal` is a disclosure, and this field is what makes that a diff."""

comptime STEP_RECORD_WRITTEN: String = "WRITTEN"
"""This step's document reached the store."""

comptime STEP_RECORD_NOT_WRITTEN: String = "NOT-WRITTEN"
"""This step's document did NOT reach the store, and the run document says so.

★ THIS IS WHY THE RUN DOCUMENT CARRIES A PER-STEP RECORD STATUS AT ALL. A PUT
fault may not red a green wave (see `RECORD_LINE_NOT_WRITTEN`), so the ONLY thing
standing between "a storage fault" and "that step was never validated" is the run
document saying which of its own siblings failed to land."""

comptime RESERVED_RUN_STEP_NAME: String = "_run"
"""The step-slot name the RUN document occupies. RESERVED — see
`refuse_reserved_step_name`."""

comptime VALIDATION_LATEST_PREFIX: String = "latest"
"""The key segment the per-(target, step) pointers live under, INSIDE the store's
own `validation` prefix: `validation/latest/<env>/<target>/<step>.json`."""

comptime DOC_KIND_LATEST: String = "latest"
"""The per-(target, step) pointer. DERIVED and REBUILDABLE from the raw tree —
never the source of truth."""


def refuse_reserved_step_name(step: String) raises:
    """⛔ REFUSE an authored step named `_run`.

    It would render to the SAME key as the run document, and last-writer-wins
    would silently drop whichever landed first. Losing the step record costs one
    step's rows; losing the RUN record costs the selectivity accounting — the
    thing that keeps "N of M" from reading as "M of M". Neither is worth a
    guess, so the collision is a hard error at the one place both keys derive."""
    if step == String(RESERVED_RUN_STEP_NAME):
        raise Error(
            String("validation record: a validate step may not be named '")
            + String(RESERVED_RUN_STEP_NAME)
            + String(
                "' — that key slot holds the RUN document, which carries the"
                " selector sets and the authored-vs-executed accounting. A"
                " collision would silently drop one of the two, and the run"
                " record is the half that keeps a selective run from reading as"
                " a full one. Rename the step."
            )
        )


def validation_run_key(env: String, run_id: String) raises -> String:
    """`raw/<env>/<run_id>/_run.json` — the RUN document, beside the step
    documents it accounts for. Derived THROUGH `validation_step_key`, so the two
    cannot drift about which directory a run's records live in."""
    return validation_step_key(env, run_id, String(RESERVED_RUN_STEP_NAME))


def validation_latest_key(
    env: String, target: String, step: String
) raises -> String:
    """`latest/<env>/<target>/<step>.json` — the LAST-WRITER-WINS pointer that
    makes "latest per target" ONE cheap listing.

    ★ WHY A POINTER OBJECT AND NOT A QUERY OVER `raw/`. The raw tree is keyed by
    RUN (`raw/<env>/<run_id>/<step>.json`) because a record must be immutable and
    a run must be able to write its documents without reading anything first.
    That layout answers "what happened in run R" in one listing and answers "what
    is the latest state of target T" only by opening every document of every run.
    The pointer inverts exactly that one question, at the cost of one extra small
    PUT per (target, step) — and a pointer PUT that faults is recorded and
    non-fatal like every other write on this path.

    ⚠ KEYED BY (TARGET, STEP), NOT BY TARGET ALONE. Several steps of one wave
    validate the SAME target — a wave can run many steps over a few served
    services — so a per-target pointer would have those steps overwrite
    each other in nondeterministic completion order and the survivor would be
    whichever finished last. "The latest record for my-app" would then mean a
    different step every run.

    The `<env>` segment is load-bearing for the reason `VALIDATION_RAW_PREFIX`
    states: `env -> bucket` is not injective."""
    _refuse_bad_component(String("env"), env)
    _refuse_bad_component(String("target"), target)
    _refuse_bad_component(String("step"), step)
    return (
        VALIDATION_LATEST_PREFIX
        + String("/")
        + env
        + String("/")
        + target
        + String("/")
        + step
        + String(".json")
    )


def render_latest_pointer(
    env: String,
    target: String,
    step: String,
    run_id: String,
    run_date: String,
    state: String,
    record_key: String,
) raises -> String:
    """The pointer document: WHERE the newest record for (target, step) is, and
    what it said.

    It carries `state` so the cheap listing answers "which targets are red right
    now" WITHOUT opening the raw records — that is the whole point of the
    inversion — and `record_key` so answering "why" is one more GET, never a
    scan."""
    var out = String("{")
    out += _kv(String("schema"), VALIDATION_SCHEMA) + String(", ")
    out += _kv(String("doc_kind"), DOC_KIND_LATEST) + String(", ")
    out += _kv(String("not_a_gate"), NOT_A_GATE_NOTICE) + String(", ")
    out += _kv(String("audience"), AUDIENCE_OPERATOR_INTERNAL) + String(", ")
    out += _kv(String("env"), env) + String(", ")
    out += _kv(String("target"), target) + String(", ")
    out += _kv(String("step"), step) + String(", ")
    out += _kv(String("run_id"), run_id) + String(", ")
    out += _kv(String("run_date"), run_date) + String(", ")
    out += _kv(String("state"), state) + String(", ")
    out += _kv(String("record_key"), record_key)
    out += String("}\n")
    return out^


def _name_in(needle: String, hay: List[String]) -> Bool:
    for i in range(len(hay)):
        if hay[i] == needle:
            return True
    return False


def _refuse_unauthored(
    what: String, members: List[String], authored: List[String]
) raises:
    for i in range(len(members)):
        if not _name_in(members[i], authored):
            raise Error(
                String("render_run_document: ")
                + what
                + String(" names '")
                + members[i].copy()
                + String(
                    "', which this wave did not author. A record accounting for"
                    " a gate the wave does not have has a fictional"
                    " denominator."
                )
            )


def _refuse_run_accounting(
    authored: List[String],
    executed: List[String],
    skipped: List[String],
    deselected: List[String],
) raises:
    """⛔ THE RUN-ALTITUDE POSITIONAL ACCOUNTING. `executed + skipped +
    deselected` must reproduce `authored` exactly.

    This is `row_accounting_fault` one altitude up, and for the same
    reason: a count with no census behind it is a number a reader trusts and
    nobody checked. Three arms, each closing a way a partial run reads as a whole
    one:

      1. A gate in NO set — the wave authored it and the record accounts for it
         nowhere. That is the missing third set that makes "N executed" read as
         "N authored, all green".
      2. A gate in TWO sets — the counts then sum past the authored total, and
         they do it in the flattering direction.
      3. A gate in a set but NOT authored — the record accounts for a gate this
         wave does not have, so the denominator is fiction.

    A CALLER error (a broken environment cannot produce one), so it RAISES."""
    for i in range(len(authored)):
        var seen = 0
        if _name_in(authored[i], executed):
            seen += 1
        if _name_in(authored[i], skipped):
            seen += 1
        if _name_in(authored[i], deselected):
            seen += 1
        if seen == 0:
            raise Error(
                String("render_run_document: authored gate '")
                + authored[i].copy()
                + String(
                    "' is in NONE of executed / skipped / deselected. A run"
                    " document accounting for fewer gates than the wave authored"
                    " is exactly how 'N of M' comes to read as 'M of M'."
                )
            )
        if seen > 1:
            raise Error(
                String("render_run_document: authored gate '")
                + authored[i].copy()
                + String(
                    "' is in MORE THAN ONE of executed / skipped / deselected."
                    " The three sets partition the wave; double-counting makes"
                    " the totals sum past the authored count."
                )
            )
    _refuse_unauthored(String("executed"), executed, authored)
    _refuse_unauthored(String("skipped"), skipped, authored)
    _refuse_unauthored(String("deselected"), deselected, authored)


def _json_string_list(names: List[String]) -> String:
    var out = String("[")
    for i in range(len(names)):
        out += json_quote(names[i])
        if i + 1 < len(names):
            out += String(", ")
    out += String("]")
    return out^


def render_run_document(
    env: String,
    bundle: String,
    wave: String,
    run_id: String,
    started_at_us: Int,
    finished_at_us: Int,
    deploy_evidence: String,
    scoped: Bool,
    authored: List[String],
    executed: List[String],
    skipped: List[String],
    deselected: List[String],
    record_steps: List[String],
    record_status: List[String],
    record_detail: List[String],
    exit_code: Int,
) raises -> String:
    """The `VALIDATION_SCHEMA` RUN document — the half a validator cannot
    write.

    ⛔ REFUSES an EMPTY `deploy_evidence`. The token is the one field that
    distinguishes a full pass from a scoped one, and a blank there renders a
    selective run as an unqualified one — see `EVIDENCE_NOT_EMITTED` for what to
    pass when the run emitted no line at all.

    ⛔ REFUSES a census that does not partition the wave
    (`_refuse_run_accounting`).

    ⚠ IT DOES NOT RE-DERIVE `exit_code` OR THE EVIDENCE TOKEN. Both are what the
    RUN produced, threaded in. A document that computed its own verdict could
    disagree with the gate, and the gate is the exit code."""
    if deploy_evidence.byte_length() == 0:
        raise Error(
            "render_run_document: `deploy_evidence` is EMPTY. That field is what"
            " keeps a SCOPED or PARTIAL run from reading as a full pass; a blank"
            " one is the unqualified claim by omission. Pass the token the run"
            " emitted, or EVIDENCE_NOT_EMITTED when it emitted none."
        )
    if len(record_steps) != len(record_status) or len(record_steps) != len(
        record_detail
    ):
        raise Error(
            "render_run_document: the per-step record columns have different"
            " lengths — a status would be attributed to the wrong step, which is"
            " worse than having none."
        )
    _refuse_run_accounting(authored, executed, skipped, deselected)
    var run_date = run_date_from_micros(started_at_us)

    var out = String("{\n")
    out += String("  ") + _kv(String("schema"), VALIDATION_SCHEMA) + String(",\n")
    out += String("  ") + _kv(String("doc_kind"), DOC_KIND_RUN) + String(",\n")
    out += String("  ") + _kv(String("not_a_gate"), NOT_A_GATE_NOTICE) + String(
        ",\n"
    )
    out += String("  ") + _kv(
        String("audience"), AUDIENCE_OPERATOR_INTERNAL
    ) + String(",\n")
    out += String("  ") + _kv(String("run_id"), run_id) + String(",\n")
    out += String("  ") + _kv(String("env"), env) + String(",\n")
    out += String("  ") + _kv(String("bundle"), bundle) + String(",\n")
    out += String("  ") + _kv(String("wave"), wave) + String(",\n")
    out += String("  ") + _kn(String("started_at_us"), started_at_us) + String(
        ",\n"
    )
    out += String("  ") + _kn(String("finished_at_us"), finished_at_us) + String(
        ",\n"
    )
    out += String("  ") + _kv(String("run_date"), run_date^) + String(",\n")
    # ── THE SELECTIVITY, which is the whole reason this document exists ───────
    out += String("  ") + _kv(
        String("deploy_evidence"), deploy_evidence
    ) + String(",\n")
    out += String("  ") + _kb(String("scoped"), scoped) + String(",\n")
    out += String("  \"coverage\": {")
    out += _kn(String("authored"), len(authored)) + String(", ")
    out += _kn(String("executed"), len(executed)) + String(", ")
    out += _kn(String("skipped"), len(skipped)) + String(", ")
    out += _kn(String("deselected"), len(deselected))
    out += String("},\n")
    out += String("  \"authored_steps\": ") + _json_string_list(
        authored
    ) + String(",\n")
    out += String("  \"executed_steps\": ") + _json_string_list(
        executed
    ) + String(",\n")
    out += String("  \"skipped_steps\": ") + _json_string_list(
        skipped
    ) + String(",\n")
    out += String("  \"deselected_steps\": ") + _json_string_list(
        deselected
    ) + String(",\n")
    # ── WHICH STEP RECORDS ACTUALLY LANDED ───────────────────────────────────
    out += String("  \"step_records\": [\n")
    for i in range(len(record_steps)):
        out += String("    {")
        out += _kv(String("step"), record_steps[i]) + String(", ")
        out += _kv(String("status"), record_status[i]) + String(", ")
        out += _kv(String("detail"), record_detail[i])
        out += String("}")
        if i + 1 < len(record_steps):
            out += String(",")
        out += String("\n")
    out += String("  ],\n")
    out += String("  ") + _kn(String("exit_code"), exit_code) + String("\n")
    out += String("}\n")
    return out^
