# =============================================================================
# src/kci_cli/tests/test_kci_args.mojo
#   kci's own options before the verb, the verb, the verb's arguments
#   untouched, and every usage refusal naming what was wrong.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_cli import KCI_USAGE, SecretStoreChoice, parse_kci_args


def _args(*items: String) -> List[String]:
    var l = List[String]()
    for s in items:
        l.append(String(s))
    return l^


def _refusal(args: List[String]) -> String:
    try:
        _ = parse_kci_args(args)
    except e:
        return String(e)
    return String("<parsed>")


def _expect(args: List[String], why: String) raises:
    assert_equal(_refusal(args), String("kci: ") + why + String("\n") + String(KCI_USAGE))


def test_build_args_pass_through_untouched() raises:
    var inv = parse_kci_args(_args("build", "--declarations=d", "--out-dir", "o", "--help", "x"))
    assert_false(inv.help)
    assert_equal(inv.verb, String("build"))
    assert_equal(len(inv.verb_args), 5)
    assert_equal(inv.verb_args[0], String("--declarations=d"))
    assert_equal(inv.verb_args[2], String("o"))
    # --help AFTER the verb is the verb's own.
    assert_equal(inv.verb_args[3], String("--help"))
    assert_equal(inv.verb_args[4], String("x"))
    assert_true(inv.store == SecretStoreChoice.NONE)


def test_publish_defaults_to_no_store() raises:
    var inv = parse_kci_args(_args("publish", "--dry-run"))
    assert_equal(inv.verb, String("publish"))
    assert_true(inv.store == SecretStoreChoice.NONE)
    assert_equal(len(inv.verb_args), 1)
    assert_equal(inv.verb_args[0], String("--dry-run"))


def test_secret_store_both_spellings() raises:
    var a = parse_kci_args(_args("--secret-store", "env", "publish"))
    assert_true(a.store == SecretStoreChoice.ENV)
    assert_equal(len(a.verb_args), 0)
    var b = parse_kci_args(_args("--secret-store=env", "publish", "--channel", "c"))
    assert_true(b.store == SecretStoreChoice.ENV)
    assert_equal(len(b.verb_args), 2)
    var c = parse_kci_args(_args("--secret-store=none", "publish"))
    assert_true(c.store == SecretStoreChoice.NONE)
    assert_equal(SecretStoreChoice.ENV.name(), String("env"))


def test_secret_store_after_the_verb_is_the_verbs() raises:
    # kci does not look past the verb: kci_publish's parser refuses it.
    var inv = parse_kci_args(_args("publish", "--secret-store=env"))
    assert_true(inv.store == SecretStoreChoice.NONE)
    assert_equal(inv.verb_args[0], String("--secret-store=env"))


def test_help_both_spellings() raises:
    assert_true(parse_kci_args(_args("--help")).help)
    assert_true(parse_kci_args(_args("-h")).help)
    assert_true(parse_kci_args(_args("--secret-store=env", "--help", "bogus")).help)


def test_refusals() raises:
    _expect(_args(), String("no verb: build or publish"))
    _expect(_args("--secret-store=env"), String("no verb: build or publish"))
    _expect(_args("deploy"), String("unknown verb 'deploy': build or publish"))
    _expect(_args("Build"), String("unknown verb 'Build': build or publish"))
    _expect(_args("--verbose", "build"), String("unknown option '--verbose' before the verb"))
    _expect(_args("--secret-store"), String("--secret-store needs a value: none or env"))
    _expect(_args("--secret-store=", "publish"), String("--secret-store needs a value: none or env"))
    _expect(
        _args("--secret-store=vault", "publish"),
        String("--secret-store 'vault' is not a store kind: none or env"),
    )
    _expect(
        _args("--secret-store=env", "--secret-store", "none", "publish"),
        String("--secret-store given twice"),
    )
    _expect(
        _args("--secret-store=none", "build"),
        String("--secret-store applies to publish only; kci build resolves no secret"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
