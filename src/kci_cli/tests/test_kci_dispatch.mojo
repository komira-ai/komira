# =============================================================================
# src/kci_cli/tests/test_kci_dispatch.mojo
#   argv -> exactly one verb call, over a recording fake `KciVerbs`: the
#   verb's arguments as given, the composed store, the verb's exit code
#   returned as is; a usage error or --help calls no verb.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_cli import EXIT_KCI_OK, EXIT_KCI_USAGE, KciVerbs, SecretStoreChoice, kci_main_with


struct RecordingVerbs(KciVerbs, Movable):
    """Records each call: `<verb> <store> <args joined by |>`."""

    var calls: List[String]
    var code: Int

    def __init__(out self, code: Int):
        self.calls = List[String]()
        self.code = code

    def build(mut self, args: List[String]) -> Int:
        self.calls.append(String("build - ") + String("|").join(args))
        return self.code

    def publish(mut self, args: List[String], store: SecretStoreChoice) -> Int:
        self.calls.append(String("publish ") + store.name() + String(" ") + String("|").join(args))
        return self.code


def _args(*items: String) -> List[String]:
    var l = List[String]()
    for s in items:
        l.append(String(s))
    return l^


def test_build_calls_build_once() raises:
    var v = RecordingVerbs(0)
    var rc = kci_main_with(_args("build", "--revision-id", "abc", "--out-dir=o"), v)
    assert_equal(rc, 0)
    assert_equal(len(v.calls), 1)
    assert_equal(v.calls[0], String("build - --revision-id|abc|--out-dir=o"))


def test_publish_gets_the_store_and_the_args() raises:
    var v = RecordingVerbs(0)
    _ = kci_main_with(_args("--secret-store=env", "publish", "--dry-run", "--channel", "c"), v)
    var w = RecordingVerbs(0)
    _ = kci_main_with(_args("publish", "--dry-run"), w)
    assert_equal(len(v.calls), 1)
    assert_equal(v.calls[0], String("publish env --dry-run|--channel|c"))
    assert_equal(w.calls[0], String("publish none --dry-run"))


def test_the_verbs_exit_code_is_returned() raises:
    for code in [0, 3, 4, 6, 7, 10]:
        var b = RecordingVerbs(code)
        assert_equal(kci_main_with(_args("build"), b), code)
        var p = RecordingVerbs(code)
        assert_equal(kci_main_with(_args("publish"), p), code)


def test_usage_errors_call_no_verb() raises:
    var cases = List[List[String]]()
    cases.append(_args())
    cases.append(_args("deploy"))
    cases.append(_args("--bogus", "publish"))
    cases.append(_args("--secret-store=vault", "publish"))
    cases.append(_args("--secret-store=env", "build"))
    for i in range(len(cases)):
        var v = RecordingVerbs(0)
        assert_equal(kci_main_with(cases[i], v), EXIT_KCI_USAGE)
        assert_equal(len(v.calls), 0)


def test_help_calls_no_verb() raises:
    var v = RecordingVerbs(9)
    assert_equal(kci_main_with(_args("--help"), v), EXIT_KCI_OK)
    assert_equal(len(v.calls), 0)
    # The verb's --help is the verb's: it IS called.
    var w = RecordingVerbs(0)
    assert_equal(kci_main_with(_args("publish", "--help"), w), 0)
    assert_equal(w.calls[0], String("publish none --help"))
    assert_true(len(w.calls) == 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
