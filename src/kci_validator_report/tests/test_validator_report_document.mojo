# =============================================================================
# tests/test_validator_report_document.mojo — the record's KEYS, its JSON
# quoting, its partition column and the RUN half (`document.mojo` §1-§5).
# =============================================================================
#
# Welded beside `test_validator_report.mojo`; this file pins what that one
# leaves unasserted. Each test names the defect it catches:
#
#   * `test_key_refuses_control_bytes_and_traversal` — a control byte or a
#     `.`/`..` component accepted into an object key (and the boundary: a
#     SPACE, 0x20, and a `...` component are legal).
#   * `test_json_quote_escapes_every_c0_byte` — `\\`, CR, tab and the `\u00XX`
#     form, with BOTH hex-nibble arms (0x01 and 0x1f), lower-case.
#   * `test_run_date_matches_a_day_counting_oracle` — every day 1970..2104 and
#     2396..2404, first AND last microsecond, against an independent
#     day-by-day civil calendar (every month end, every leap rule).
#   * `test_step_document_separates_legs_and_counts_guards` — the exact bytes
#     of a two-leg, two-guard document (separators, held/broken totals).
#   * `test_reserved_step_name_and_run_key` / `test_latest_key_*` /
#     `test_latest_pointer_bytes` — the reserved `_run` slot and the two other
#     key derivations, exactly.
#   * `test_run_document_*` — the RUN document's exact bytes and each of its
#     refusals (empty evidence, ragged columns, the three accounting arms).
#
# Hermetic: pure String work.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_validator_rows import ExpectedRow, expected_row

from kci_validator_report import (
    ReportTarget,
    ReportGuard,
    MatrixOutcome,
    served_target,
    guard_held,
    guard_broken,
    row_passed,
    row_failed,
    validation_step_key,
    run_date_from_micros,
    json_quote,
    render_step_document,
    EVIDENCE_NOT_EMITTED,
    STEP_RECORD_WRITTEN,
    STEP_RECORD_NOT_WRITTEN,
    refuse_reserved_step_name,
    validation_run_key,
    validation_latest_key,
    render_latest_pointer,
    render_run_document,
)


def _contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _step_key_error(env: String, run_id: String, step: String) -> String:
    """The error `validation_step_key` raises, or "" when it accepts."""
    try:
        _ = validation_step_key(env, run_id, step)
    except e:
        return String(e)
    return String("")


# -----------------------------------------------------------------------------
# §1 — the key refuses a control byte and a traversal component.
# -----------------------------------------------------------------------------
def test_key_refuses_control_bytes_and_traversal() raises:
    # A control byte anywhere in a component, at both ends of the C0 range.
    var e1 = _step_key_error(String("staging"), String("r") + chr(1), String("s"))
    assert_true(_contains(e1, String("run_id contains a control byte")), e1)
    var e2 = _step_key_error(String("staging"), String("r"), String("s") + chr(0x1F))
    assert_true(_contains(e2, String("step contains a control byte")), e2)
    # The boundary: 0x20 (a space) is NOT a control byte.
    assert_equal(
        validation_step_key(String("staging"), String("r"), String("a b")),
        String("raw/staging/r/a b.json"),
    )
    # `..` and `.` are traversal components; `...` and `.a` are names.
    var e3 = _step_key_error(String(".."), String("r"), String("s"))
    assert_true(_contains(e3, String("env is a path traversal component")), e3)
    var e4 = _step_key_error(String("staging"), String("."), String("s"))
    assert_true(_contains(e4, String("run_id is a path traversal component")), e4)
    assert_equal(
        validation_step_key(String("staging"), String("..."), String(".a")),
        String("raw/staging/.../.a.json"),
    )


# -----------------------------------------------------------------------------
# §2 — json_quote's escapes.
# -----------------------------------------------------------------------------
def test_json_quote_escapes_every_c0_byte() raises:
    assert_equal(json_quote(String("a\\b")), String("\"a\\\\b\""))
    assert_equal(json_quote(String("a\rb")), String("\"a\\rb\""))
    assert_equal(json_quote(String("a\tb")), String("\"a\\tb\""))
    # The \u00XX form: a nibble under 10 and one at or over 10, lower-case.
    assert_equal(json_quote(chr(0x01)), String("\"\\u0001\""))
    assert_equal(json_quote(chr(0x1F)), String("\"\\u001f\""))
    assert_equal(json_quote(chr(0x0B)), String("\"\\u000b\""))
    assert_equal(json_quote(chr(0x1A)), String("\"\\u001a\""))
    # 0x20 and 0x7f are not C0 controls: copied through.
    assert_equal(json_quote(String(" ") + chr(0x7F)), String("\" ") + chr(0x7F) + String("\""))


# -----------------------------------------------------------------------------
# §3 — the partition column against an independent calendar.
# -----------------------------------------------------------------------------
def _is_leap(y: Int) -> Bool:
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


def _month_len(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if _is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _ymd(y: Int, m: Int, d: Int) -> String:
    var out = String(y) + String("-")
    if m < 10:
        out += String("0")
    out += String(m) + String("-")
    if d < 10:
        out += String("0")
    out += String(d)
    return out^


def test_run_date_matches_a_day_counting_oracle() raises:
    comptime DAY_US = 86400000000
    var day = 0
    var y = 1970
    var checked = 0
    while y < 2405:
        # Compare 1970..2104 and 2396..2404 (the 2400 era pivot); only count
        # days in between.
        var compare = y < 2105 or y >= 2396
        for m in range(1, 13):
            for d in range(1, _month_len(y, m) + 1):
                if compare:
                    var want = _ymd(y, m, d)
                    assert_equal(run_date_from_micros(day * DAY_US), want)
                    assert_equal(
                        run_date_from_micros(day * DAY_US + DAY_US - 1), want
                    )
                    checked += 1
                day += 1
        y += 1
    # 135 + 9 years of days were compared.
    assert_true(checked > 52000, String(checked))


# -----------------------------------------------------------------------------
# §4 — a two-leg, two-guard step document, byte for byte.
# -----------------------------------------------------------------------------
def _leg(var leg: String, var row: String, ok: Bool) -> MatrixOutcome:
    var spec = List[ExpectedRow]()
    spec.append(expected_row(row.copy(), String("holds")))
    var oc = MatrixOutcome(String("v"), leg^, spec^)
    if ok:
        oc.add(row_passed(row^, String("-"), String("ok"), String("holds")))
    else:
        oc.add(row_failed(row^, String("-"), String("no"), String("holds"), String("bad")))
    return oc^


def test_step_document_separates_legs_and_counts_guards() raises:
    var targets = List[ReportTarget]()
    targets.append(served_target(String("t"), String("sha256:aa"), String("u")))
    var legs = List[MatrixOutcome]()
    legs.append(_leg(String("one"), String("r1"), True))
    legs.append(_leg(String("two"), String("r2"), False))
    var gs = List[ReportGuard]()
    gs.append(guard_broken(String("g1"), String("why")))
    gs.append(guard_held(String("g2")))
    var doc = render_step_document(
        String("e"), String("b"), String("w"), String("s"), String("r"),
        String("v"), String("vv"), 0, 1, targets, legs, gs, 1,
    )
    var want = String(
        "  \"legs\": [\n"
        "    {\"leg\":\"one\", \"validator\":\"v\", \"authored\":1,"
        " \"accounting_fault\":\"\", \"verdict\":\"VERDICT: PASS (1/1 asserted rows)\",\n"
        "     \"rows\": [\n"
        "       {\"row_index\":0, \"name\":\"r1\", \"target_index\":-1,"
        " \"subject\":\"-\", \"observed\":\"ok\", \"expected\":\"holds\","
        " \"state\":\"PASSED\", \"status\":-1, \"remediation\":\"\", \"detail\":\"\"}\n"
        "     ]},\n"
        "    {\"leg\":\"two\", \"validator\":\"v\", \"authored\":1,"
        " \"accounting_fault\":\"\", \"verdict\":\"VERDICT: FAIL (0/1 asserted rows)\",\n"
        "     \"rows\": [\n"
        "       {\"row_index\":0, \"name\":\"r2\", \"target_index\":-1,"
        " \"subject\":\"-\", \"observed\":\"no\", \"expected\":\"holds\","
        " \"state\":\"FAILED\", \"status\":-1, \"remediation\":\"\", \"detail\":\"bad\"}\n"
        "     ]}\n"
        "  ],\n"
        "  \"guards\": [\n"
        "    {\"name\":\"g1\", \"held\":false, \"reason\":\"why\"},\n"
        "    {\"name\":\"g2\", \"held\":true, \"reason\":\"\"}\n"
        "  ],\n"
        "  \"totals\": {\"rows\":2, \"passed\":1, \"failed\":1, \"not_run\":0,"
        " \"not_reached\":0, \"unreadable\":0, \"asserted\":2, \"guards_held\":1,"
        " \"guards_broken\":1},\n"
        "  \"exit_code\":1\n"
        "}\n"
    )
    var at = doc.find(String("  \"legs\": ["))
    assert_true(at > 0)
    assert_equal(String(doc[byte=at:]), want)


# -----------------------------------------------------------------------------
# §5 — the reserved `_run` slot and the other two key derivations.
# -----------------------------------------------------------------------------
def test_reserved_step_name_and_run_key() raises:
    var refused = String("")
    try:
        refuse_reserved_step_name(String("_run"))
    except e:
        refused = String(e)
    assert_true(_contains(refused, String("may not be named '_run'")), refused)
    # Only the exact name is reserved.
    refuse_reserved_step_name(String("_run2"))
    refuse_reserved_step_name(String("run"))
    assert_equal(
        validation_run_key(String("staging"), String("01JC")),
        String("raw/staging/01JC/_run.json"),
    )
    var raised = String("")
    try:
        _ = validation_run_key(String("staging"), String("a/b"))
    except e:
        raised = String(e)
    assert_true(_contains(raised, String("run_id contains '/'")), raised)


def test_latest_key_is_env_target_step_and_refuses_each() raises:
    assert_equal(
        validation_latest_key(String("staging"), String("my-app"), String("e2e")),
        String("latest/staging/my-app/e2e.json"),
    )
    var errs = List[String]()
    for i in range(3):
        var env = String("..") if i == 0 else String("staging")
        var target = String("a/b") if i == 1 else String("t")
        var step = String("") if i == 2 else String("s")
        try:
            _ = validation_latest_key(env, target, step)
            errs.append(String(""))
        except e:
            errs.append(String(e))
    assert_true(_contains(errs[0], String("env is a path traversal")), errs[0])
    assert_true(_contains(errs[1], String("target contains '/'")), errs[1])
    assert_true(_contains(errs[2], String("step is EMPTY")), errs[2])


def test_latest_pointer_bytes() raises:
    var p = render_latest_pointer(
        String("staging"), String("my-app"), String("e2e"), String("01JC"),
        String("2026-09-01"), String("FAILED"), String("raw/staging/01JC/e2e.json"),
    )
    assert_equal(
        p,
        String(
            "{\"schema\":\"komira_ci.validation.v1\", \"doc_kind\":\"latest\","
            " \"not_a_gate\":\"EVIDENCE, not authorization. The gate is the exit"
            " code and the build graph. Nothing may read this record back as"
            " permission to proceed.\", \"audience\":\"operator-internal\","
            " \"env\":\"staging\", \"target\":\"my-app\", \"step\":\"e2e\","
            " \"run_id\":\"01JC\", \"run_date\":\"2026-09-01\","
            " \"state\":\"FAILED\", \"record_key\":\"raw/staging/01JC/e2e.json\"}\n"
        ),
    )


# -----------------------------------------------------------------------------
# §6 — the RUN document.
# -----------------------------------------------------------------------------
def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    if a.byte_length() > 0:
        out.append(a.copy())
    if b.byte_length() > 0:
        out.append(b.copy())
    return out^


def _run_doc(
    evidence: String,
    authored: List[String],
    executed: List[String],
    skipped: List[String],
    deselected: List[String],
    steps: List[String],
    status: List[String],
    detail: List[String],
    scoped: Bool = True,
    exit_code: Int = 0,
) raises -> String:
    return render_run_document(
        String("staging"), String("b"), String("w"), String("01JC"),
        1788220800000000, 1788220860000000, evidence, scoped,
        authored, executed, skipped, deselected, steps, status, detail,
        exit_code,
    )


def _run_doc_error(
    evidence: String,
    authored: List[String],
    executed: List[String],
    skipped: List[String],
    deselected: List[String],
    steps: List[String],
    status: List[String],
    detail: List[String],
) -> String:
    try:
        _ = _run_doc(evidence, authored, executed, skipped, deselected, steps, status, detail)
    except e:
        return String(e)
    return String("")


def test_run_document_bytes() raises:
    var e = String("")
    var abcd = _names(String("a"), String("b"))
    abcd.append(String("c"))
    abcd.append(String("d"))
    var doc = _run_doc(
        String("VALIDATED(scoped)"),
        abcd,
        _names(String("a"), String("b")),
        _names(String("c"), e),
        _names(String("d"), e),
        _names(String("a"), String("b")),
        _names(String(STEP_RECORD_WRITTEN), String(STEP_RECORD_NOT_WRITTEN)),
        _names(String("-"), String("put failed")),
    )
    assert_equal(
        doc,
        String(
            "{\n"
            "  \"schema\":\"komira_ci.validation.v1\",\n"
            "  \"doc_kind\":\"run\",\n"
            "  \"not_a_gate\":\"EVIDENCE, not authorization. The gate is the exit"
            " code and the build graph. Nothing may read this record back as"
            " permission to proceed.\",\n"
            "  \"audience\":\"operator-internal\",\n"
            "  \"run_id\":\"01JC\",\n"
            "  \"env\":\"staging\",\n"
            "  \"bundle\":\"b\",\n"
            "  \"wave\":\"w\",\n"
            "  \"started_at_us\":1788220800000000,\n"
            "  \"finished_at_us\":1788220860000000,\n"
            "  \"run_date\":\"2026-09-01\",\n"
            "  \"deploy_evidence\":\"VALIDATED(scoped)\",\n"
            "  \"scoped\":true,\n"
            "  \"coverage\": {\"authored\":4, \"executed\":2, \"skipped\":1,"
            " \"deselected\":1},\n"
            "  \"authored_steps\": [\"a\", \"b\", \"c\", \"d\"],\n"
            "  \"executed_steps\": [\"a\", \"b\"],\n"
            "  \"skipped_steps\": [\"c\"],\n"
            "  \"deselected_steps\": [\"d\"],\n"
            "  \"step_records\": [\n"
            "    {\"step\":\"a\", \"status\":\"WRITTEN\", \"detail\":\"-\"},\n"
            "    {\"step\":\"b\", \"status\":\"NOT-WRITTEN\", \"detail\":\"put failed\"}\n"
            "  ],\n"
            "  \"exit_code\":0\n"
            "}\n"
        ),
    )


def test_run_document_full_run_and_failed_exit_are_rendered() raises:
    # `scoped` and `exit_code` are passed through, not defaulted: a full
    # (unscoped) run must not render as scoped, and a failed run must not
    # be recorded as exit 0. Both lines are asserted whole.
    var one = _names(String("a"), String(""))
    var none = List[String]()
    var doc = _run_doc(
        String("VALIDATED"), one, one, none, none, none, none, none,
        scoped=False, exit_code=3,
    )
    assert_true(_contains(doc, String("  \"scoped\":false,\n")), doc)
    assert_true(_contains(doc, String("  \"exit_code\":3\n}\n")), doc)
    assert_false(_contains(doc, String("\"scoped\":true")), doc)


def test_run_document_refuses_empty_evidence_and_ragged_columns() raises:
    var e = String("")
    var one = _names(String("a"), e)
    var none = List[String]()
    var err = _run_doc_error(e, one, one, none, none, one, one, one)
    assert_true(_contains(err, String("`deploy_evidence` is EMPTY")), err)
    # The not-emitted token is accepted.
    _ = _run_doc(String(EVIDENCE_NOT_EMITTED), one, one, none, none, one, one, one)
    # A short status column, then a short detail column.
    err = _run_doc_error(String("x"), one, one, none, none, one, none, one)
    assert_true(_contains(err, String("different lengths")), err)
    err = _run_doc_error(String("x"), one, one, none, none, one, one, none)
    assert_true(_contains(err, String("different lengths")), err)
    # Empty columns everywhere are a legal (if empty) run.
    var doc = _run_doc(String("x"), none, none, none, none, none, none, none)
    assert_true(_contains(doc, String("\"authored_steps\": [],\n")), doc)
    assert_true(_contains(doc, String("\"step_records\": [\n  ],\n")), doc)


def test_run_document_refuses_a_census_that_does_not_partition() raises:
    var e = String("")
    var none = List[String]()
    var ab = _names(String("a"), String("b"))
    var a = _names(String("a"), e)
    var b = _names(String("b"), e)
    # 1. `b` (the LAST authored gate) is in no set.
    var err = _run_doc_error(String("t"), ab, a, none, none, none, none, none)
    assert_true(_contains(err, String("gate 'b' is in NONE")), err)
    # 2. a gate in two sets, for each pair.
    err = _run_doc_error(String("t"), ab, ab, b, none, none, none, none)
    assert_true(_contains(err, String("gate 'b' is in MORE THAN ONE")), err)
    err = _run_doc_error(String("t"), ab, a, b, b, none, none, none)
    assert_true(_contains(err, String("gate 'b' is in MORE THAN ONE")), err)
    err = _run_doc_error(String("t"), ab, ab, none, b, none, none, none)
    assert_true(_contains(err, String("gate 'b' is in MORE THAN ONE")), err)
    # 3. a member nobody authored, in each set.
    var ax = _names(String("a"), String("x"))
    err = _run_doc_error(String("t"), ab, ax, b, none, none, none, none)
    assert_true(_contains(err, String("executed names 'x'")), err)
    err = _run_doc_error(String("t"), ab, a, _names(String("b"), String("x")), none, none, none, none)
    assert_true(_contains(err, String("skipped names 'x'")), err)
    err = _run_doc_error(String("t"), ab, a, none, _names(String("b"), String("x")), none, none, none)
    assert_true(_contains(err, String("deselected names 'x'")), err)
    # Each set alone may carry the whole wave.
    _ = _run_doc(String("t"), ab, none, ab, none, none, none, none)
    _ = _run_doc(String("t"), ab, none, none, ab, none, none, none)


def main() raises:
    test_key_refuses_control_bytes_and_traversal()
    test_json_quote_escapes_every_c0_byte()
    test_run_date_matches_a_day_counting_oracle()
    test_step_document_separates_legs_and_counts_guards()
    test_reserved_step_name_and_run_key()
    test_latest_key_is_env_target_step_and_refuses_each()
    test_latest_pointer_bytes()
    test_run_document_bytes()
    test_run_document_full_run_and_failed_exit_are_rendered()
    test_run_document_refuses_empty_evidence_and_ragged_columns()
    test_run_document_refuses_a_census_that_does_not_partition()
    print("test_validator_report_document: ALL PASS")
