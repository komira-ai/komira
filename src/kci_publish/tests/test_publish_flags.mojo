# =============================================================================
# src/kci_publish/tests/test_publish_flags.mojo -- design 2.1: every flag,
#   both spellings; each refusal names its flag; the deleted flags are
#   unknown.
# =============================================================================
#
# ROWS
#   (1) every flag parses as `--flag value` and as `--flag=value`;
#       `--claim-new-name` repeats; `--dry-run`, `--require-environment` and
#       `--concurrency` (default 4, 1..16) are optional;
#   (2) each required flag missing is refused naming it (all at once);
#   (3) `--credential` and `--approved-names` are unknown
#       flags; so is anything else;
#   (4) a value flag given twice, a claim given twice (any case), an EMPTY
#       value, a positional argument, `--dry-run=x`, an `--expect-set-hash`
#       that is not 64 lowercase hex, and a `--concurrency` outside 1..16 or
#       not a whole number are refused;
#   (5) `--help` wins and checks nothing else.
#
# Pure: no file is read.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_publish.flags import PublishFlags, parse_publish_flags


comptime _HASH: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _base() -> List[String]:
    var a = List[String]()
    a.append(String("--declarations"))
    a.append(String("decls.textproto"))
    a.append(String("--artifacts=release"))
    a.append(String("--channels"))
    a.append(String("channels.textproto"))
    a.append(String("--channel=example-stable"))
    a.append(String("--release-version"))
    a.append(String("rv.txt"))
    a.append(String("--expect-set-hash=") + String(_HASH))
    a.append(String("--report"))
    a.append(String("report.json"))
    return a^


def _refused(args: List[String], needle: String) raises:
    var raised = False
    try:
        _ = parse_publish_flags(args)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String("refusal '") + String(e) + String("' does not name '") + needle + String("'"))
        assert_true(String(e).find(String("usage: kci publish")) >= 0, String(e))
    assert_true(raised, String("not refused; expected: ") + needle)


def _with(var extra: List[String]) -> List[String]:
    var a = _base()
    for i in range(len(extra)):
        a.append(extra[i].copy())
    return a^


def _one(s: String) -> List[String]:
    var l = List[String]()
    l.append(s.copy())
    return l^


def _two(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a.copy())
    l.append(b.copy())
    return l^


def test_every_flag_both_spellings() raises:
    var extra = List[String]()
    extra.append(String("--claim-new-name"))
    extra.append(String("komira_alpha"))
    extra.append(String("--claim-new-name=komira"))
    extra.append(String("--require-environment"))
    extra.append(String("release"))
    extra.append(String("--dry-run"))
    extra.append(String("--concurrency"))
    extra.append(String("2"))
    var f = parse_publish_flags(_with(extra^))
    assert_equal(f.declarations_file, String("decls.textproto"))
    assert_equal(f.artifacts_dir, String("release"))
    assert_equal(f.channels_file, String("channels.textproto"))
    assert_equal(f.channel, String("example-stable"))
    assert_equal(f.release_version_file, String("rv.txt"))
    assert_equal(f.expect_set_hash, String(_HASH))
    assert_equal(f.report_file, String("report.json"))
    assert_equal(len(f.claims), 2)
    assert_equal(f.claims[0], String("komira_alpha"))
    assert_equal(f.claims[1], String("komira"))
    assert_equal(f.require_environment, String("release"))
    assert_true(f.dry_run)
    assert_equal(f.concurrency, 2)
    var g = parse_publish_flags(_base())
    assert_false(g.dry_run)
    assert_equal(len(g.claims), 0)
    assert_equal(g.concurrency, 4, String("--concurrency defaults to 4"))
    var lo = parse_publish_flags(_with(_one(String("--concurrency=1"))))
    assert_equal(lo.concurrency, 1)
    var hi = parse_publish_flags(_with(_one(String("--concurrency=16"))))
    assert_equal(hi.concurrency, 16)
    print("  test_every_flag_both_spellings: PASS")


def test_missing_flags_are_named() raises:
    var none = List[String]()
    var raised = False
    try:
        _ = parse_publish_flags(none)
    except e:
        raised = True
        var t = String(e)
        var flags = List[String]()
        flags.append(String("--declarations"))
        flags.append(String("--artifacts"))
        flags.append(String("--channels"))
        flags.append(String("--channel"))
        flags.append(String("--release-version"))
        flags.append(String("--expect-set-hash"))
        flags.append(String("--report"))
        for i in range(len(flags)):
            assert_true(t.find(flags[i]) >= 0, t + String(" does not name ") + flags[i])
    assert_true(raised)
    # each one alone
    var names = List[String]()
    names.append(String("--declarations"))
    names.append(String("--artifacts"))
    names.append(String("--channels"))
    names.append(String("--release-version"))
    names.append(String("--report"))
    for n in range(len(names)):
        var a = List[String]()
        var b = _base()
        var skip = False
        for i in range(len(b)):
            if skip:
                skip = False
                continue
            if b[i] == names[n]:
                skip = True
                continue
            if b[i].startswith(names[n] + String("=")):
                continue
            a.append(b[i].copy())
        _refused(a, String("missing required flag(s): ") + names[n])
    print("  test_missing_flags_are_named: PASS")


def test_deleted_flags_are_unknown() raises:
    _refused(_with(_two(String("--credential"), String("oidc"))), String("unknown flag '--credential'"))
    _refused(_with(_two(String("--approved-names"), String("a.txt"))), String("unknown flag '--approved-names'"))
    _refused(_with(_one(String("--force"))), String("unknown flag '--force'"))
    print("  test_deleted_flags_are_unknown: PASS")


def test_each_refusal_names_its_flag() raises:
    _refused(_with(_two(String("--channel"), String("other"))), String("--channel is given twice"))
    _refused(_with(_two(String("--report"), String("r2.json"))), String("--report is given twice"))
    _refused(
        _with(_two(String("--claim-new-name=komira"), String("--claim-new-name=KOMIRA"))),
        String("--claim-new-name 'KOMIRA' is given twice"),
    )
    _refused(_with(_one(String("--claim-new-name="))), String("--claim-new-name has an EMPTY value"))
    _refused(_with(_one(String("--require-environment"))), String("--require-environment needs a value"))
    _refused(_with(_one(String("stray"))), String("unexpected argument 'stray'"))
    _refused(_with(_one(String("--dry-run=yes"))), String("--dry-run takes no value"))
    _refused(_with(_two(String("--dry-run"), String("--dry-run"))), String("--dry-run is given twice"))
    _refused(_with(_one(String("--concurrency=0"))), String("--concurrency must be a whole number from 1 to 16; got '0'"))
    _refused(_with(_one(String("--concurrency=17"))), String("--concurrency must be a whole number from 1 to 16; got '17'"))
    _refused(_with(_one(String("--concurrency=4x"))), String("--concurrency must be a whole number from 1 to 16; got '4x'"))
    _refused(_with(_one(String("--concurrency=-1"))), String("--concurrency must be a whole number from 1 to 16; got '-1'"))
    _refused(_with(_one(String("--concurrency="))), String("--concurrency has an EMPTY value"))
    _refused(
        _with(_two(String("--concurrency=2"), String("--concurrency=3"))),
        String("--concurrency is given twice"),
    )
    var short = List[String]()
    short.append(String("--expect-set-hash=abc"))
    var a = List[String]()
    var b = _base()
    for i in range(len(b)):
        if not b[i].startswith(String("--expect-set-hash")):
            a.append(b[i].copy())
    a.append(String("--expect-set-hash=") + String(_HASH).upper())
    _refused(a, String("--expect-set-hash must be 64 lowercase hex"))
    var c = List[String]()
    for i in range(len(b)):
        if not b[i].startswith(String("--expect-set-hash")):
            c.append(b[i].copy())
    c.append(String("--expect-set-hash=abc"))
    _refused(c, String("--expect-set-hash must be 64 lowercase hex"))
    print("  test_each_refusal_names_its_flag: PASS")


def test_help_wins() raises:
    var a = List[String]()
    a.append(String("--bogus"))
    var f = parse_publish_flags(_one(String("--help")))
    assert_true(f.help)
    var g = parse_publish_flags(_two(String("-h"), String("--bogus")))
    assert_true(g.help)
    print("  test_help_wins: PASS")


def main() raises:
    test_every_flag_both_spellings()
    test_missing_flags_are_named()
    test_deleted_flags_are_unknown()
    test_each_refusal_names_its_flag()
    test_help_wins()
    print("test_publish_flags: ALL PASS")
