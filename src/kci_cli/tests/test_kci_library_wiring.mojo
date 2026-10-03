# =============================================================================
# src/kci_cli/tests/test_kci_library_wiring.mojo
#   The REAL verbs (`LibraryVerbs`, as bin/kci runs them) reach their
#   libraries: each verb's --help and usage refusal, and the secret store
#   --secret-store composes is the one that resolves the channel's secret
#   NAME. No socket: every publish run here stops before step 1.
#
#   The store proof, in two halves:
#   * `ComposedSecretStore` (the one store `publish` is handed) resolves a
#     secret by NAME from the environment for `env` (KCI_CLI_TEST_SECRET is
#     set by `test_env`), refuses an unset name naming the variable, and for
#     `none` refuses naming the option;
#   * end to end through `kci_main_with` and the real verbs: a dry run of a
#     PRIVATE channel whose credential is an API token resolves the token
#     BEFORE any read; EXAMPLE_CONDA_TOKEN is unset, so it exits 4 with no
#     file in the report (the refusal is printed; the report carries no
#     reason text by design).
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_cli import ComposedSecretStore, LibraryVerbs, SecretStoreChoice, kci_main_with
from kci_publish import EXIT_FAILED
from kci_publish.release_fixture import (
    EXAMPLE_CHANNELS,
    EXAMPLE_TOKEN_SECRET,
    ExampleRelease,
    write_text_file,
)


def _args(*items: String) -> List[String]:
    var l = List[String]()
    for s in items:
        l.append(String(s))
    return l^


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_cli_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _private_dry_run(tag: String, store: String) raises -> Tuple[Int, String]:
    """Runs `kci --secret-store=<store> publish --dry-run` on the fixture's
    PRIVATE API-token channel; returns the exit code and the report text."""
    var r = ExampleRelease()
    var d = _root(tag)
    r.write(d + String("/release"))
    write_text_file(d + String("/decls.textproto"), r.declarations_text())
    write_text_file(d + String("/channels.textproto"), String(EXAMPLE_CHANNELS))
    write_text_file(d + String("/rv.txt"), r.release_version_text())
    var verbs = LibraryVerbs()
    var rc = kci_main_with(
        _args(
            String("--secret-store=") + store,
            "publish",
            "--declarations", d + String("/decls.textproto"),
            "--artifacts", d + String("/release"),
            "--channels", d + String("/channels.textproto"),
            "--channel", "example-private",
            "--release-version", d + String("/rv.txt"),
            "--expect-set-hash", r.set_hash(d + String("/release")),
            "--report", d + String("/report.json"),
            "--dry-run",
        ),
        verbs,
    )
    return (rc, Path(d + String("/report.json")).read_text())


def test_each_verbs_help_is_its_librarys() raises:
    var v = LibraryVerbs()
    assert_equal(kci_main_with(_args("build", "--help"), v), 0)
    assert_equal(kci_main_with(_args("publish", "--help"), v), 0)
    assert_equal(kci_main_with(_args("--secret-store=env", "publish", "--help"), v), 0)


def test_each_verbs_usage_refusal_is_its_librarys() raises:
    var v = LibraryVerbs()
    # No flags: each library refuses its first missing flag, exit 2.
    assert_equal(kci_main_with(_args("build"), v), 2)
    assert_equal(kci_main_with(_args("publish"), v), 2)
    # A flag of the other verb is unknown to this one.
    assert_equal(kci_main_with(_args("build", "--dry-run"), v), 2)
    assert_equal(kci_main_with(_args("publish", "--revision-id", "x"), v), 2)
    assert_equal(v.publish(_args("--bogus"), SecretStoreChoice.ENV), 2)


def _refusal(mut store: ComposedSecretStore, name: String) -> String:
    try:
        _ = store.resolve(name)
    except e:
        return String(e)
    return String("<resolved>")


def test_env_store_resolves_a_secret_by_name() raises:
    var store = ComposedSecretStore(SecretStoreChoice.ENV)
    var v = store.resolve(String("KCI_CLI_TEST_SECRET"))
    assert_equal(v.len(), String("kci-cli-test-value").byte_length())
    var got = String("")
    var b = v.revealed_bytes()
    for i in range(len(b)):
        got += chr(Int(b[i]))
    assert_equal(got, String("kci-cli-test-value"))
    assert_equal(
        _refusal(store, String(EXAMPLE_TOKEN_SECRET)),
        String("EnvSecretStore: environment variable ") + String(EXAMPLE_TOKEN_SECRET) + String(" is not set"),
    )


def test_none_store_refuses_naming_the_option() raises:
    var store = ComposedSecretStore(SecretStoreChoice.NONE)
    var why = _refusal(store, String("KCI_CLI_TEST_SECRET"))
    assert_true(why.find(String("kci was run with --secret-store=none, so the secret 'KCI_CLI_TEST_SECRET'")) >= 0, why)
    assert_true(why.find(String("pass --secret-store=env")) >= 0, why)


def test_publish_resolves_the_channel_secret_before_any_read() raises:
    assert_equal(_read_env("EXAMPLE_CONDA_TOKEN"), String(""))
    for store in [String("env"), String("none")]:
        var out = _private_dry_run(String("e2e_") + store, store)
        assert_equal(out[0], EXIT_FAILED, out[1])
        assert_true(out[1].find(String('"dry_run":true')) >= 0, out[1])
        assert_true(out[1].find(String('"files":[]')) >= 0, out[1])
        assert_true(out[1].find(String('"verdict":"FAILED"')) >= 0, out[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
