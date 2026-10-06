# =============================================================================
# tests/test_validator_report.mojo — THE FALSIFIER for the shared report library.
# =============================================================================
#
# WHAT THIS PINS, AND WHY EACH ASSERTION EXISTS.
#
# ★ `test_unreadable_is_not_a_pass_and_not_a_fail` — a probe that could not read
#   its subject must not report greens for checks that never ran, because "I
#   could not observe the subject" has somewhere to go other than `passed: Bool`.
#   The row must leave the DENOMINATOR and drive the run to exit 3.
#
# ★ `test_not_reached_is_red_and_typed` — a not-reached row is `passed=False`,
#   not a `"NOT REACHED: "` DETAIL PREFIX on a failed row. The verdict must not
#   move; only the reason becomes queryable.
#
# ★ `test_all_abstentions_cannot_pass` — `VERDICT: PASS (6/6 rows)` must never
#   print for a run where two of the six were abstentions.
#
# ★ `test_truncated_leg_is_a_census_fault_not_a_failure` — exit 3 OUTRANKS exit
#   1. A run that cannot say what it ran cannot support any claim, including a
#   negative one.
#
# ★ `test_a_record_with_no_target_is_refused` — a record that names no
#   (target, version) is exactly the state of a stale green.
#
# ★ `test_staged_ledger_and_live_serving_are_different_claims` — a staged-image
#   ledger can diverge from what is serving, in repository AND digest. An
#   unlabelled digest cannot answer "what did I validate".
#
# ★ `test_dangling_target_index_is_refused` — one step validates several targets
#   at DIFFERENT digests. A row attributed to a target nobody listed renders as
#   validating something the run never named.
#
# ★ `test_the_document_says_it_is_not_a_gate` — asserted over the BYTES. The
#   reader who reaches for this record as a green light is reading the JSON, not
#   the header comment.
#
# Hermetic: pure String work. No process, no environment, no network, no clock,
# no store.
# =============================================================================

# ── MUTATION TO CHECK, THE VERSION-HALF CASE ────────────────────
# The mutation below, applied to `target.mojo`, is expected to turn this test RED
# (the test is welded to the `.mojoc`, so a red test is a red BUILD). A falsifier
# nobody falsified is a green light.
#
#   MUTATION                                          RED IN
#   `digest_pinned_by` returns the value with       -> `test_a_tag_is_not_a_
#   no `sha256:` prefix UNCHANGED                      version_…` (a MUTABLE TAG
#                                                      rendered as a LIVE_SERVING
#                                                      version)

from std.testing import assert_equal, assert_true, assert_false

from kci_validator_rows import ExpectedRow, expected_row

from kci_validator_report import (
    ROW_PASSED,
    ROW_FAILED,
    ROW_NOT_RUN,
    ROW_NOT_REACHED,
    ROW_UNREADABLE,
    row_state_token,
    row_state_is_known,
    VERSION_SOURCE_LIVE_SERVING,
    VERSION_SOURCE_STAGED_LEDGER,
    VERSION_SOURCE_NONE,
    TARGET_KIND_SERVICE,
    REPORT_EXIT_OK,
    REPORT_EXIT_FAILED,
    REPORT_EXIT_CENSUS_FAULT,
    RowResult,
    NO_TARGET,
    NO_STATUS,
    row_passed,
    row_failed,
    row_not_run,
    row_not_reached,
    row_unreadable,
    http_row,
    with_target,
    ReportTarget,
    ReportGuard,
    served_target,
    digest_pinned_by,
    live_serving_target,
    unversioned_target,
    shared_infrastructure_target,
    guard_held,
    guard_broken,
    targets_fault,
    MatrixOutcome,
    single_row_outcome,
    combine_outcomes,
    run_census_fault,
    report_exit_code,
    VALIDATION_SCHEMA,
    NOT_A_GATE_NOTICE,
    validation_step_key,
    run_date_from_micros,
    json_quote,
    render_step_document,
)


comptime _V: String = "test_validator"
comptime _LEG: String = "app_surface"


def _contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _spec3() -> List[ExpectedRow]:
    var s = List[ExpectedRow]()
    s.append(expected_row(String("livez_200"), String("the app answers liveness")))
    s.append(expected_row(String("unauth_401"), String("no bearer is refused")))
    s.append(expected_row(String("send_relayed"), String("the message LEFT the boundary")))
    return s^


def _one_target() -> List[ReportTarget]:
    var t = List[ReportTarget]()
    t.append(
        served_target(
            String("example-mail-region-a"),
            String("sha256:7c11aa"),
            String("https://example-mail-x.run.app"),
        )
    )
    return t^


def _no_guards() -> List[ReportGuard]:
    return List[ReportGuard]()


# -----------------------------------------------------------------------------
# §1 — the state vocabulary is CLOSED and FAIL-CLOSED.
# -----------------------------------------------------------------------------
def test_state_tokens_are_closed_and_fail_closed() raises:
    assert_equal(row_state_token(ROW_PASSED), String("PASSED"))
    assert_equal(row_state_token(ROW_FAILED), String("FAILED"))
    assert_equal(row_state_token(ROW_NOT_RUN), String("NOT_RUN"))
    assert_equal(row_state_token(ROW_NOT_REACHED), String("NOT_REACHED"))
    assert_equal(row_state_token(ROW_UNREADABLE), String("UNREADABLE"))
    # ⛔ An ordinal outside the vocabulary must NEVER render a pass.
    assert_equal(row_state_token(99), String("UNREADABLE"))
    assert_equal(row_state_token(-1), String("UNREADABLE"))
    assert_false(row_state_is_known(99))
    assert_true(row_state_is_known(ROW_UNREADABLE))


# -----------------------------------------------------------------------------
# §2 — a healthy leg.
# -----------------------------------------------------------------------------
def _healthy_leg() raises -> MatrixOutcome:
    var oc = MatrixOutcome(String(_V), String(_LEG), _spec3())
    oc.add(http_row(String("livez_200"), String("GET"), String("/livez"), 200, 200, True, String("")))
    oc.add(http_row(String("unauth_401"), String("GET"), String("/v1/me"), 401, 401, True, String("")))
    oc.add(
        row_passed(
            String("send_relayed"),
            String("POST /messages/m/send"),
            String("202 relayed"),
            String("2xx AND disposition relayed"),
        )
    )
    return oc^


def test_a_healthy_leg_is_green_at_every_altitude() raises:
    var oc = _healthy_leg()
    assert_equal(oc.total(), 3)
    assert_equal(oc.asserted_count(), 3)
    assert_equal(oc.asserted_passed_count(), 3)
    assert_equal(oc.accounting_fault(), String(""))
    assert_true(oc.all_passed())
    var legs = List[MatrixOutcome]()
    legs.append(oc^)
    assert_equal(report_exit_code(legs, _one_target(), _no_guards()), REPORT_EXIT_OK)


# -----------------------------------------------------------------------------
# §3 ★ UNREADABLE — neither a pass nor a fail; a RUN-LEVEL fault (exit 3).
# -----------------------------------------------------------------------------
def test_unreadable_is_not_a_pass_and_not_a_fail() raises:
    var oc = MatrixOutcome(String(_V), String(_LEG), _spec3())
    oc.add(http_row(String("livez_200"), String("GET"), String("/livez"), 200, 200, True, String("")))
    oc.add(http_row(String("unauth_401"), String("GET"), String("/v1/me"), 401, 401, True, String("")))
    oc.add(
        row_unreadable(
            String("send_relayed"),
            String("POST /messages/m/send"),
            String("the run holds no credential for the send route"),
            String("grant the validator SA roles/run.invoker on example-mail"),
        )
    )
    assert_equal(oc.total(), 3)
    # It left BOTH sides of the ratio.
    assert_equal(oc.asserted_count(), 2)
    assert_equal(oc.asserted_passed_count(), 2)
    assert_equal(oc.unreadable_count(), 1)
    # ⛔ Two of two asserted rows passed and the leg still cannot pass.
    assert_false(oc.all_passed())
    assert_true(_contains(oc.census_fault(), String("could not OBSERVE its subject")))
    var legs = List[MatrixOutcome]()
    legs.append(oc^)
    assert_equal(
        report_exit_code(legs, _one_target(), _no_guards()),
        REPORT_EXIT_CENSUS_FAULT,
    )


def test_unreadable_without_remediation_is_refused() raises:
    """⛔ The state removes the row from the denominator; the price is saying what
    would make the subject readable. A blank remediation buys the refusal."""
    var r = row_unreadable(
        String("send_relayed"), String("POST /send"),
        String("no credential"), String(""),
    )
    assert_equal(r.state, ROW_FAILED)
    assert_true(_contains(r.detail, String("NO REMEDIATION")))


# -----------------------------------------------------------------------------
# §4 ★ NOT-REACHED — red, and typed rather than a detail PREFIX.
# -----------------------------------------------------------------------------
def test_not_reached_is_red_and_typed() raises:
    var r = row_not_reached(
        String("delivery_outbound_accepted"),
        String("domain_close failed; the delivery legs assert about a domain this"
               " run could not return to a known state"),
    )
    assert_equal(r.state, ROW_NOT_REACHED)
    assert_true(r.is_failure())
    assert_true(r.is_asserted())          # it is in the DENOMINATOR.
    assert_false(r.is_not_run())          # ⛔ it is NOT an abstention.
    assert_equal(r.state_token(), String("NOT_REACHED"))
    assert_true(_contains(r.detail, String("domain_close failed")))
    assert_true(_contains(r.tag(), String("NOT-REACHED")))


def test_not_reached_reds_the_leg_at_exit_1_not_3() raises:
    var oc = MatrixOutcome(String(_V), String(_LEG), _spec3())
    oc.add(http_row(String("livez_200"), String("GET"), String("/livez"), 200, 200, True, String("")))
    oc.add(row_failed(String("unauth_401"), String("GET /v1/me"), String("200"),
                      String("401"), String("an unauthenticated read was SERVED")))
    oc.add(row_not_reached(String("send_relayed"), String("unauth_401 failed")))
    assert_false(oc.all_passed())
    assert_equal(oc.census_fault(), String(""))   # the report is trustworthy.
    var legs = List[MatrixOutcome]()
    legs.append(oc^)
    assert_equal(report_exit_code(legs, _one_target(), _no_guards()), REPORT_EXIT_FAILED)


# -----------------------------------------------------------------------------
# §5 ★ ABSTENTIONS leave the ratio, and an all-abstention leg cannot pass.
# -----------------------------------------------------------------------------
def test_all_abstentions_cannot_pass() raises:
    var oc = MatrixOutcome(String(_V), String(_LEG), _spec3())
    oc.add(row_not_run(String("livez_200"), String("the standing leg does not deploy")))
    oc.add(row_not_run(String("unauth_401"), String("the standing leg does not deploy")))
    oc.add(row_not_run(String("send_relayed"), String("the standing leg does not deploy")))
    assert_equal(oc.total(), 3)
    assert_equal(oc.asserted_count(), 0)
    assert_false(oc.all_passed())
    assert_true(_contains(oc.verdict_line(), String("EVERY row abstained")))
    assert_true(_contains(oc.verdict_line(), String("FAIL")))


def test_abstention_without_a_reason_is_refused() raises:
    var r = row_not_run(String("livez_200"), String(""))
    assert_equal(r.state, ROW_FAILED)
    assert_true(_contains(r.detail, String("ABSTENTION WITH NO REASON")))


# -----------------------------------------------------------------------------
# §6 ★ TRUNCATION is a CENSUS fault (3), which OUTRANKS a failure (1).
# -----------------------------------------------------------------------------
def test_truncated_leg_is_a_census_fault_not_a_failure() raises:
    var oc = MatrixOutcome(String(_V), String(_LEG), _spec3())
    oc.add(http_row(String("livez_200"), String("GET"), String("/livez"), 200, 200, True, String("")))
    oc.add(http_row(String("unauth_401"), String("GET"), String("/v1/me"), 401, 401, True, String("")))
    # The third authored row never emitted — every emitted row PASSED.
    assert_equal(oc.asserted_passed_count(), oc.asserted_count())
    assert_false(oc.all_passed())
    assert_true(_contains(oc.accounting_fault(), String("FIRST MISSING at index 2")))
    var legs = List[MatrixOutcome]()
    legs.append(oc^)
    assert_equal(
        report_exit_code(legs, _one_target(), _no_guards()),
        REPORT_EXIT_CENSUS_FAULT,
    )


def test_a_run_with_no_legs_is_a_census_fault() raises:
    var legs = List[MatrixOutcome]()
    assert_false(combine_outcomes(legs))
    assert_true(_contains(run_census_fault(legs, _one_target(), _no_guards()), String("NO LEGS")))
    assert_equal(
        report_exit_code(legs, _one_target(), _no_guards()),
        REPORT_EXIT_CENSUS_FAULT,
    )


# -----------------------------------------------------------------------------
# §7 ★ THE TARGET IS (NAME, VERSION).
# -----------------------------------------------------------------------------
def test_a_record_with_no_target_is_refused() raises:
    var none = List[ReportTarget]()
    assert_true(_contains(targets_fault(none), String("NO TARGETS")))
    var legs = List[MatrixOutcome]()
    legs.append(_healthy_leg())
    assert_equal(report_exit_code(legs, none, _no_guards()), REPORT_EXIT_CENSUS_FAULT)


def test_staged_ledger_and_live_serving_are_different_claims() raises:
    """The two sources can give different repositories AND different
    digests. Both are well-formed targets;
    the LABEL is what makes them distinguishable, so it is required."""
    var live = ReportTarget(
        String("example-api-region-a"), String(TARGET_KIND_SERVICE),
        String("sha256:0aa1"), String(VERSION_SOURCE_LIVE_SERVING),
        String(""), String("https://example-api-x.run.app"),
    )
    var staged = ReportTarget(
        String("example-api-region-a"), String(TARGET_KIND_SERVICE),
        String("sha256:0bb2"), String(VERSION_SOURCE_STAGED_LEDGER),
        String(""), String(""),
    )
    assert_equal(live.fault(), String(""))
    assert_equal(staged.fault(), String(""))
    assert_true(live.version != staged.version)
    assert_true(live.version_source != staged.version_source)


def test_an_unknown_version_source_is_refused() raises:
    var t = ReportTarget(
        String("svc"), String(TARGET_KIND_SERVICE), String("sha256:aa"),
        String("PROBABLY_LIVE"), String(""), String(""),
    )
    assert_true(_contains(t.fault(), String("outside the closed vocabulary")))


def test_a_named_source_that_produced_no_version_is_refused() raises:
    var t = ReportTarget(
        String("svc"), String(TARGET_KIND_SERVICE), String(""),
        String(VERSION_SOURCE_LIVE_SERVING), String(""), String(""),
    )
    assert_true(_contains(t.fault(), String("the version is EMPTY")))


def test_shared_infrastructure_has_no_digest_and_says_why() raises:
    """`APP_KIND_SHARED_INFRASTRUCTURE` composes no `-svc` node and serves
    nothing, yet a validate step can name it. A digest-shaped field is
    simply wrong for it — and an unexplained empty digest reads as "we did not
    look"."""
    var t = shared_infrastructure_target(String("infra-app"))
    assert_equal(t.version, String(""))
    assert_equal(t.version_source, VERSION_SOURCE_NONE)
    assert_equal(t.fault(), String(""))
    assert_true(_contains(t.version_note, String("no -svc node")))
    var bare = unversioned_target(String("x"), String("probe"), String(""))
    assert_true(_contains(bare.version_note, String("NO REASON STATED")))


def test_none_source_carrying_a_version_is_a_contradiction() raises:
    var t = ReportTarget(
        String("svc"), String(TARGET_KIND_SERVICE), String("sha256:aa"),
        String(VERSION_SOURCE_NONE), String("no image"), String(""),
    )
    assert_true(_contains(t.fault(), String("NONE but a version is present")))


def test_duplicate_target_names_make_attribution_ambiguous() raises:
    var ts = List[ReportTarget]()
    ts.append(served_target(String("svc"), String("sha256:a"), String("u1")))
    ts.append(served_target(String("svc"), String("sha256:b"), String("u2")))
    assert_true(_contains(targets_fault(ts), String("DUPLICATE target name")))


# -----------------------------------------------------------------------------
# §7b ★ THE VERSION HALF OF THE TARGET — a LIVE READ becomes a version, or an
#      HONEST NONE. A target names both the target and its version / hash.
# -----------------------------------------------------------------------------
def test_a_live_read_that_pins_a_digest_becomes_the_version() raises:
    """★ A LIVE read of what the service is serving answers "what did I
    validate", and it is the ONLY source that can make a stale green detectable."""
    var t = live_serving_target(
        String("example-api-region-a"),
        String(
            "registry.example/example-project/example/example-api@sha256:0aa1"
        ),
        String("https://example-api-x.run.app"),
    )
    assert_equal(t.version, String("sha256:0aa1"))
    assert_equal(t.version_source, VERSION_SOURCE_LIVE_SERVING)
    assert_equal(t.name, String("example-api-region-a"))
    assert_equal(t.endpoint, String("https://example-api-x.run.app"))
    # A well-formed target: a NAMED source with a real version and no note owed.
    assert_equal(t.fault(), String(""))


def test_a_narrow_digest_is_already_the_version() raises:
    """A bundle that authored `image { digest: "sha256:…" }` is already in the
    narrow form and carries no `@`. It still PINS, so it still versions."""
    var t = live_serving_target(
        String("svc"), String("sha256:0bb2"), String("https://x")
    )
    assert_equal(t.version, String("sha256:0bb2"))
    assert_equal(t.version_source, VERSION_SOURCE_LIVE_SERVING)
    assert_equal(t.fault(), String(""))


def test_a_tag_is_not_a_version_and_renders_none_not_a_guess() raises:
    """⛔ THE REFUSAL THAT MATTERS. `<repo>:<tag>` is a MUTABLE POINTER. Passing
    it through as a LIVE_SERVING version would make the record silently false the
    next time that tag moves — an invented version wearing a real label, which is
    exactly what `version_source` exists to prevent. The honest answer is NONE
    plus the ref we actually saw."""
    var t = live_serving_target(
        String("example-api"),
        String("registry.example/example-project/example/example-api:latest"),
        String("https://example-api-x.run.app"),
    )
    assert_equal(t.version, String(""))
    assert_equal(t.version_source, VERSION_SOURCE_NONE)
    # NAMED, so the half that already works is not lost with the half that does not.
    assert_equal(t.name, String("example-api"))
    # …and the reason names the ref, so a reader can see WHY it was refused.
    assert_true(_contains(t.version_note, String("pins no immutable digest")))
    assert_true(_contains(t.version_note, String("example-api:latest")))
    # A NONE carrying a note and no version is well-formed, not a fault.
    assert_equal(t.fault(), String(""))


def test_no_live_read_at_all_says_so_rather_than_reading_as_nothing_found() raises:
    """"We did not look" and "there was nothing to find" are different claims,
    and a blank digest cannot distinguish them. The standalone `validate` verb
    resolves endpoints from what a PRIOR deploy RECORDED — the registry stores a
    URL and no digest — so its bindings land HERE, and the note has to say that
    rather than imply a failed read."""
    var t = live_serving_target(
        String("example-worker"), String(""), String("https://worker-x.run.app")
    )
    assert_equal(t.version, String(""))
    assert_equal(t.version_source, VERSION_SOURCE_NONE)
    assert_true(_contains(t.version_note, String("took no live read")))
    assert_equal(t.fault(), String(""))


def test_digest_pinned_by_refuses_every_shape_that_does_not_pin() raises:
    """⚠ DELIBERATELY NOT `digest_of_image_ref`, which passes a value with no `@`
    through UNCHANGED. That is right for splitting a known artifact ref and wrong
    for a live read, where the input is frequently a tag."""
    assert_equal(digest_pinned_by(String("r/a@sha256:ab")), String("sha256:ab"))
    assert_equal(digest_pinned_by(String("sha256:ab")), String("sha256:ab"))
    assert_equal(digest_pinned_by(String("r/a:latest")), String(""))
    assert_equal(digest_pinned_by(String("r/a")), String(""))
    assert_equal(digest_pinned_by(String("")), String(""))
    # `sha256:` with nothing after it is a PREFIX, not a digest — and an empty
    # version under a named source is a `fault()`, so it must be caught here.
    assert_equal(digest_pinned_by(String("r/a@sha256:")), String(""))
    # An algorithm this function was never taught is NOT guessed at.
    assert_equal(digest_pinned_by(String("r/a@sha512:ab")), String(""))


# -----------------------------------------------------------------------------
# §8 ★ GUARDS.
# -----------------------------------------------------------------------------
def test_a_broken_guard_reds_the_run_and_must_say_why() raises:
    var gs = List[ReportGuard]()
    gs.append(guard_held(String("lifecycle_close_row_count")))
    gs.append(guard_broken(String("domain_close_row_count"),
                           String("the close contract is unmet")))
    var legs = List[MatrixOutcome]()
    legs.append(_healthy_leg())
    assert_equal(report_exit_code(legs, _one_target(), gs), REPORT_EXIT_FAILED)
    var blank = guard_broken(String("g"), String(""))
    assert_true(_contains(blank.reason, String("NO REASON STATED")))
    assert_false(blank.held)


# -----------------------------------------------------------------------------
# §9 ★ THE FOUR-LINE CASE still carries the accounting.
# -----------------------------------------------------------------------------
def test_single_row_outcome_is_four_lines_and_still_accounted() raises:
    var oc = single_row_outcome(
        String("service_probe"), String("probe_200"),
        String("GET /healthz"), String("200"), String("200"), True,
    )
    assert_true(oc.all_passed())
    assert_equal(oc.accounting_fault(), String(""))
    var bad = single_row_outcome(
        String("service_probe"), String("probe_200"),
        String("GET /healthz"), String("503"), String("200"), False,
    )
    assert_false(bad.all_passed())


# -----------------------------------------------------------------------------
# §10 ★ THE KEY DERIVATION — one function, so writer and reader cannot drift.
# -----------------------------------------------------------------------------
def test_the_key_is_env_scoped_and_refuses_a_separator() raises:
    assert_equal(
        validation_step_key(String("staging"), String("01JC8Q"), String("example-e2e")),
        String("raw/staging/01JC8Q/example-e2e.json"),
    )
    # ★ `env -> bucket` is NOT injective: two environments can share one
    # bootstrap bucket, so the <env> component is load-bearing.
    assert_equal(
        validation_step_key(String("staging-region-a"), String("01JC8Q"), String("s")),
        String("raw/staging-region-a/01JC8Q/s.json"),
    )
    var raised = False
    try:
        _ = validation_step_key(String("staging"), String("r"), String("a/b"))
    except e:
        raised = True
        assert_true(_contains(String(e), String("contains '/'")))
    assert_true(raised, "a step name with a separator must be refused")
    var raised2 = False
    try:
        _ = validation_step_key(String(""), String("r"), String("s"))
    except e:
        raised2 = True
    assert_true(raised2, "an empty env must be refused")


# -----------------------------------------------------------------------------
# §11 ★ THE PARTITION COLUMN is materialized, and the derivation is pinned.
# -----------------------------------------------------------------------------
def test_run_date_is_materialized_utc() raises:
    assert_equal(run_date_from_micros(0), String("1970-01-01"))
    # 2026-09-01T00:00:00Z = 1788220800 s.
    assert_equal(run_date_from_micros(1788220800000000), String("2026-09-01"))
    # 2400-03-01 (a 400-year era boundary the civil-from-days algorithm pivots on).
    assert_equal(run_date_from_micros(13574649600000000), String("2400-03-01"))
    # 2028-02-29 — a leap day.
    assert_equal(run_date_from_micros(1835395200000000), String("2028-02-29"))
    var raised = False
    try:
        _ = run_date_from_micros(-1)
    except e:
        raised = True
    assert_true(raised, "a pre-epoch stamp is a broken clock, not a partition")


# -----------------------------------------------------------------------------
# §12 ★ JSON byte fidelity — validator details carry em-dashes and ⛔ marks.
# -----------------------------------------------------------------------------
def test_json_quote_is_byte_faithful() raises:
    assert_equal(json_quote(String("a\"b")), String("\"a\\\"b\""))
    assert_equal(json_quote(String("a\nb")), String("\"a\\nb\""))
    # An em-dash must survive as its own three UTF-8 bytes, not be re-encoded.
    var q = json_quote(String("a—b"))
    assert_equal(q.byte_length(), String("a—b").byte_length() + 2)
    assert_true(_contains(q, String("—")))


# -----------------------------------------------------------------------------
# §13 ★ THE DOCUMENT.
# -----------------------------------------------------------------------------
def _render_healthy() raises -> String:
    var legs = List[MatrixOutcome]()
    legs.append(_healthy_leg())
    var gs = List[ReportGuard]()
    gs.append(guard_held(String("lifecycle_close_row_count")))
    return render_step_document(
        String("staging"), String("example-mail"), String("staging"),
        String("example-e2e"), String("01JC8Q"), String("example_validator"),
        String("sha256:9ab1"), 1788220800000000, 1788220860000000,
        _one_target(), legs, gs, 0,
    )


def test_the_document_says_it_is_not_a_gate() raises:
    """⛔ Asserted over the BYTES. An unauthenticated text file written by the
    party being gated is not authorization; this record is that shape and must
    say so where it will be read."""
    var doc = _render_healthy()
    assert_true(_contains(doc, String("\"not_a_gate\"")))
    assert_true(_contains(doc, String("EVIDENCE, not authorization")))
    assert_true(_contains(doc, String("The gate is the exit code and the build graph")))
    # ⛔ AND THERE IS NO TOP-LEVEL `target` FIELD — attribution is per row.
    assert_false(_contains(doc, String("\"target\":")))
    assert_true(_contains(doc, String("\"targets\": [")))


def test_the_document_carries_the_schema_and_the_partition_column() raises:
    var doc = _render_healthy()
    assert_true(_contains(doc, VALIDATION_SCHEMA))
    assert_true(_contains(doc, String("\"doc_kind\":\"step\"")))
    assert_true(_contains(doc, String("\"run_date\":\"2026-09-01\"")))
    assert_true(_contains(doc, String("\"env\":\"staging\"")))
    assert_true(_contains(doc, String("\"validator_version\":\"sha256:9ab1\"")))
    assert_true(_contains(doc, String("\"leg\":\"app_surface\"")))


def test_the_document_carries_the_failure_reason_per_row() raises:
    """★ The reason a row went red must be in the record, not only in a job's
    stdout, which the validate DAG structurally cannot read."""
    var oc = MatrixOutcome(String(_V), String("domain_close"), _spec3())
    oc.add(http_row(String("livez_200"), String("GET"), String("/livez"), 200, 200, True, String("")))
    oc.add(http_row(String("unauth_401"), String("GET"), String("/v1/me"), 401, 401, True, String("")))
    oc.add(
        row_failed(
            String("send_relayed"),
            String("DELETE /v1/domains/{d}"),
            String("409"),
            String("the domain is gone from the relay"),
            String("teardown refused: domain still has 1 active binding"
                   " (binding_id=rb_7f21)"),
        )
    )
    var legs = List[MatrixOutcome]()
    legs.append(oc^)
    var doc = render_step_document(
        String("staging"), String("example-mail"), String("staging"),
        String("example-e2e"), String("01JC8Q"), String("example_validator"),
        String("sha256:9ab1"), 1788220800000000, 1788220860000000,
        _one_target(), legs, _no_guards(), 1,
    )
    assert_true(_contains(doc, String("binding_id=rb_7f21")))
    assert_true(_contains(doc, String("\"state\":\"FAILED\"")))
    assert_true(_contains(doc, String("\"exit_code\":1")))
    assert_true(_contains(doc, String("\"failed\":1")))


def test_one_step_can_attribute_rows_to_targets_at_different_digests() raises:
    """★ One wave can run many steps across several served services on
    different digests of one logical image. A single top-level target field
    can only be right for one."""
    var ts = List[ReportTarget]()
    ts.append(served_target(String("example-api-region-a"),
                            String("sha256:0aa1"), String("u1")))
    ts.append(served_target(String("example-worker-region-a"),
                            String("sha256:0cc3"), String("u2")))
    var spec = List[ExpectedRow]()
    spec.append(expected_row(String("api_livez"), String("the API answers")))
    spec.append(expected_row(String("worker_livez"), String("the worker answers")))
    var oc = MatrixOutcome(String(_V), String("probe"), spec^)
    oc.add(with_target(row_passed(String("api_livez"), String("GET /livez"),
                                  String("200"), String("200")), 0))
    oc.add(with_target(row_passed(String("worker_livez"), String("GET /livez"),
                                  String("200"), String("200")), 1))
    var legs = List[MatrixOutcome]()
    legs.append(oc^)
    var doc = render_step_document(
        String("staging"), String("example-bundle"), String("staging"),
        String("example-probe"), String("01JC8Q"), String("service_probe"),
        String("sha256:dd"), 1788220800000000, 1788220860000000,
        ts, legs, _no_guards(), 0,
    )
    assert_true(_contains(doc, String("sha256:0aa1")))
    assert_true(_contains(doc, String("sha256:0cc3")))
    assert_true(_contains(doc, String("\"target_index\":0")))
    assert_true(_contains(doc, String("\"target_index\":1")))


def test_dangling_target_index_is_refused() raises:
    var spec = List[ExpectedRow]()
    spec.append(expected_row(String("api_livez"), String("the API answers")))
    var oc = MatrixOutcome(String(_V), String("probe"), spec^)
    oc.add(with_target(row_passed(String("api_livez"), String("GET /livez"),
                                  String("200"), String("200")), 4))
    var legs = List[MatrixOutcome]()
    legs.append(oc^)
    var raised = False
    try:
        _ = render_step_document(
            String("staging"), String("b"), String("w"), String("s"),
            String("r"), String("v"), String("sha256:dd"),
            1788220800000000, 1788220860000000,
            _one_target(), legs, _no_guards(), 0,
        )
    except e:
        raised = True
        assert_true(_contains(String(e), String("target nobody")))
    assert_true(raised, "a row attributed to an unlisted target must be refused")


# -----------------------------------------------------------------------------
# §14 ★ THE NON-HTTP ROW — a (name, passed, detail) claim against a subject
#      that is not an HTTP exchange.
# -----------------------------------------------------------------------------
def test_add_claim_takes_its_demand_from_the_authored_spec() raises:
    var spec = List[ExpectedRow]()
    spec.append(expected_row(String("cold_create_accepted"),
                             String("POST /api/v1/items on a COLD unit answers 201")))
    spec.append(expected_row(String("probe_items_deleted"),
                             String("every item this run created was deleted")))
    var oc = MatrixOutcome(String("example_validator"), String("claim"), spec^)
    oc.add_claim(String("cold_create_accepted"), True, String("201 itemId=i-7"))
    oc.add_claim(String("probe_items_deleted"), False, String("delete returned 500"))
    assert_equal(oc.total(), 2)
    assert_false(oc.all_passed())
    assert_equal(oc.accounting_fault(), String(""))
    # ★ The demand is the SPEC'S sentence, not a second one written at the emit
    # site — two sentences would drift and the reader sees the unreviewed one.
    assert_true(_contains(oc.rows[0].expected, String("answers 201")))
    # A PASS keeps its detail as the OBSERVATION.
    assert_equal(oc.rows[0].observed, String("201 itemId=i-7"))
    # A FAIL keeps it as the detail an operator acts on.
    assert_true(_contains(oc.rows[1].detail, String("delete returned 500")))


def test_add_claim_marks_an_unauthored_row_rather_than_demanding_nothing() raises:
    var spec = List[ExpectedRow]()
    spec.append(expected_row(String("a"), String("a holds")))
    var oc = MatrixOutcome(String("v"), String("l"), spec^)
    oc.add_claim(String("b"), True, String(""))
    assert_true(_contains(oc.rows[0].expected, String("UNAUTHORED ROW")))
    # And the positional accounting reds it independently.
    assert_true(_contains(oc.accounting_fault(), String("FIRST DIVERGENCE")))


def main() raises:
    test_state_tokens_are_closed_and_fail_closed()
    test_a_healthy_leg_is_green_at_every_altitude()
    test_unreadable_is_not_a_pass_and_not_a_fail()
    test_unreadable_without_remediation_is_refused()
    test_not_reached_is_red_and_typed()
    test_not_reached_reds_the_leg_at_exit_1_not_3()
    test_all_abstentions_cannot_pass()
    test_abstention_without_a_reason_is_refused()
    test_truncated_leg_is_a_census_fault_not_a_failure()
    test_a_run_with_no_legs_is_a_census_fault()
    test_a_record_with_no_target_is_refused()
    test_staged_ledger_and_live_serving_are_different_claims()
    test_an_unknown_version_source_is_refused()
    test_a_named_source_that_produced_no_version_is_refused()
    test_shared_infrastructure_has_no_digest_and_says_why()
    test_none_source_carrying_a_version_is_a_contradiction()
    test_duplicate_target_names_make_attribution_ambiguous()
    test_a_live_read_that_pins_a_digest_becomes_the_version()
    test_a_narrow_digest_is_already_the_version()
    test_a_tag_is_not_a_version_and_renders_none_not_a_guess()
    test_no_live_read_at_all_says_so_rather_than_reading_as_nothing_found()
    test_digest_pinned_by_refuses_every_shape_that_does_not_pin()
    test_a_broken_guard_reds_the_run_and_must_say_why()
    test_single_row_outcome_is_four_lines_and_still_accounted()
    test_the_key_is_env_scoped_and_refuses_a_separator()
    test_run_date_is_materialized_utc()
    test_json_quote_is_byte_faithful()
    test_the_document_says_it_is_not_a_gate()
    test_the_document_carries_the_schema_and_the_partition_column()
    test_the_document_carries_the_failure_reason_per_row()
    test_one_step_can_attribute_rows_to_targets_at_different_digests()
    test_dangling_target_index_is_refused()
    test_add_claim_takes_its_demand_from_the_authored_spec()
    test_add_claim_marks_an_unauthored_row_rather_than_demanding_nothing()
    print("test_validator_report: ALL PASS")
