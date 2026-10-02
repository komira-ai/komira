# =============================================================================
# src/kci_publish/tests/test_publish_flags.mojo -- the `kci publish` flags.
# =============================================================================
#
# ROWS
#   (1) every flag in both spellings (`--f v` and `--f=v`); --artifacts
#       repeats; --dry-run sets the plan-only mode;
#   (2) the three credential forms, each with its argument;
#   (3) each refusal, naming the flag: every missing required flag at once,
#       a repeated flag, an unknown flag, a positional, an empty value, a
#       value-less flag at the end, --dry-run with a value, an unknown
#       credential form, a credential form with no argument, and
#       --require-environment without --credential oidc;
#   (4) --help short-circuits;
#   (5) `publish_main` turns a flag refusal into exit 2 before reading or
#       sending anything (the inputs named do not exist).
#
# Hermetic: pure parsing; no file read, no network.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_publish import (
    CREDENTIAL_OIDC,
    CREDENTIAL_TOKEN_FILE,
    CREDENTIAL_TOKEN_SECRET,
    EXIT_OK,
    EXIT_USAGE,
    PublishFlags,
    parse_publish_flags,
    publish_main,
)


def _args(s: String) -> List[String]:
    var out = List[String]()
    var parts = s.split(String(" "))
    for i in range(len(parts)):
        if String(parts[i]).byte_length() > 0:
            out.append(String(parts[i]))
    return out^


comptime _BASE: String = (
    "--channels c.textproto --channel stable --artifacts a.json"
    " --approved-names names.txt"
)


def _refusal(s: String) -> String:
    try:
        _ = parse_publish_flags(_args(s))
    except e:
        return String(e)
    return String("")


def test_both_spellings_and_repeats() raises:
    var f = parse_publish_flags(
        _args(
            String("--channels=c.textproto --channel stable --artifacts a.json")
            + String(" --artifacts=b.json --approved-names names.txt")
            + String(" --credential=oidc --require-environment release --dry-run")
        )
    )
    assert_equal(f.channels_file, String("c.textproto"))
    assert_equal(f.channel, String("stable"))
    assert_equal(len(f.artifacts), 2)
    assert_equal(f.artifacts[0], String("a.json"))
    assert_equal(f.artifacts[1], String("b.json"))
    assert_equal(f.approved_names_file, String("names.txt"))
    assert_equal(f.credential_kind, CREDENTIAL_OIDC)
    assert_equal(f.require_environment, String("release"))
    assert_true(f.dry_run)
    assert_false(f.help)
    var g = parse_publish_flags(_args(String(_BASE) + String(" --credential oidc")))
    assert_false(g.dry_run)
    assert_equal(g.require_environment, String(""))


def test_credential_forms() raises:
    var a = parse_publish_flags(
        _args(String(_BASE) + String(" --credential token-file:/run/secrets/tok"))
    )
    assert_equal(a.credential_kind, CREDENTIAL_TOKEN_FILE)
    assert_equal(a.credential_arg, String("/run/secrets/tok"))
    var b = parse_publish_flags(
        _args(String(_BASE) + String(" --credential=token-secret:PUBLISH_TOKEN"))
    )
    assert_equal(b.credential_kind, CREDENTIAL_TOKEN_SECRET)
    assert_equal(b.credential_arg, String("PUBLISH_TOKEN"))


def _assert_refused(args: String, needle: String) raises:
    var why = _refusal(args)
    assert_true(why.byte_length() > 0, String("not refused: ") + args)
    assert_true(why.find(needle) >= 0, why)
    assert_true(why.find(String("usage: kci publish")) >= 0, why)


def test_refusals_name_the_flag() raises:
    var why = _refusal(String(""))
    var need = _args(
        String("--channels --channel --artifacts --approved-names --credential")
    )
    for i in range(len(need)):
        assert_true(why.find(need[i]) >= 0, why)
    _assert_refused(String(_BASE), String("missing required flag(s): --credential"))
    _assert_refused(
        String(_BASE) + String(" --credential oidc --channel other"),
        String("--channel is given twice"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential oidc --token abc"),
        String("unknown flag '--token'"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential oidc extra"),
        String("unexpected argument 'extra'"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential= "), String("--credential has an EMPTY value")
    )
    _assert_refused(String(_BASE) + String(" --credential"), String("--credential needs a value"))
    _assert_refused(
        String(_BASE) + String(" --credential oidc --dry-run=yes"),
        String("--dry-run takes no value"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential oidc --dry-run --dry-run"),
        String("--dry-run is given twice"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential password:hunter2"),
        String("--credential must be oidc, token-file:<path> or token-secret:<name>"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential token-file:"),
        String("token-file: names no path"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential token-secret:"),
        String("token-secret: names no secret"),
    )
    _assert_refused(
        String(_BASE) + String(" --credential token-file:/t --require-environment release"),
        String("needs --credential oidc"),
    )


def test_help() raises:
    var f = parse_publish_flags(_args(String("--channel x --help --bogus")))
    assert_true(f.help)
    assert_equal(publish_main(_args(String("--help"))), EXIT_OK)


def test_publish_main_refuses_before_reading() raises:
    # Every input named here is absent: exit 2 proves the flags were refused
    # first (an input refusal would be exit 3).
    assert_equal(publish_main(_args(String(""))), EXIT_USAGE)
    assert_equal(
        publish_main(_args(String(_BASE) + String(" --credential token-file:"))),
        EXIT_USAGE,
    )


def main() raises:
    test_both_spellings_and_repeats()
    test_credential_forms()
    test_refusals_name_the_flag()
    test_help()
    test_publish_main_refuses_before_reading()
    print("test_publish_flags: ALL PASS")
