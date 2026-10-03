# =============================================================================
# src/kci_cli/tests/test_kci_library_wiring.mojo
#   The REAL verbs (`LibraryVerbs`, as bin/kci runs them) reach their
#   libraries: each verb's --help and usage refusal, and the secret store
#   --secret-store composes is the one that resolves the channel's secret
#   NAME. No socket: every publish run here stops before step 1.
#
#   The store proof: a dry run of a PRIVATE channel whose credential is an
#   API token resolves the token BEFORE any read. The secret's variable
#   (EXAMPLE_CONDA_TOKEN) is not set in the test's environment, so
#     --secret-store=env  -> komira_secret_env refuses, naming the variable;
#     --secret-store=none -> RefusingSecretStore refuses, naming the option;
#   both exit 4 with the reason in the report, and nothing is sent.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_cli import LibraryVerbs, SecretStoreChoice, kci_main_with
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
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
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


def test_env_store_resolves_the_secret_by_name() raises:
    assert_equal(getenv(String(EXAMPLE_TOKEN_SECRET)), String(""))
    var out = _private_dry_run(String("env"), String("env"))
    assert_equal(out[0], EXIT_FAILED, out[1])
    assert_true(
        out[1].find(String("EnvSecretStore: environment variable ") + String(EXAMPLE_TOKEN_SECRET) + String(" is not set")) >= 0,
        out[1],
    )
    assert_false(out[1].find(String("--secret-store=none")) >= 0, out[1])


def test_none_store_refuses_naming_the_option() raises:
    var out = _private_dry_run(String("none"), String("none"))
    assert_equal(out[0], EXIT_FAILED, out[1])
    assert_true(
        out[1].find(String("kci was run with --secret-store=none, so the secret '") + String(EXAMPLE_TOKEN_SECRET)) >= 0,
        out[1],
    )
    assert_false(out[1].find(String("EnvSecretStore")) >= 0, out[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
