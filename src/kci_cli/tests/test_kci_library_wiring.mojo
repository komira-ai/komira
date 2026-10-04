# =============================================================================
# src/kci_cli/tests/test_kci_library_wiring.mojo
#   The REAL steps (`LibrarySteps`, as bin/kci runs them) reached through a
#   machine file: a BUILD step reaches kci_build, a PUBLISH step reaches
#   kci_publish with the secret store --secret-store composes. No socket and
#   no build: every run here stops before its first request or program.
#
#   The store proof, in two halves:
#   * `ComposedSecretStore` (the one store a PUBLISH step is handed) resolves
#     a secret by NAME from the environment for `env` (KCI_CLI_TEST_SECRET is
#     set by `test_env`), refuses an unset name naming the variable, and for
#     `none` refuses naming the flag;
#   * end to end through `kci_main_with`: `kci run --plan` of a stage whose
#     PUBLISH step targets a PRIVATE channel with an API token resolves the
#     token BEFORE any read; EXAMPLE_CONDA_TOKEN is unset, so the run ends
#     FAILED (KCI-E-CREDENTIAL, exit 4) with no artifact row, whichever store.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_cli import ComposedSecretStore, LibrarySteps, SecretStoreChoice, kci_main_with, recorder_for, write_whole_file
from kci_api import parse_result
from kci_publish.release_fixture import EXAMPLE_STAGE, EXAMPLE_TOKEN_SECRET, ExampleRelease, write_example_inputs


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kci_cli_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _flag(mut a: List[String], flag: String, value: String):
    a.append(flag.copy())
    a.append(value.copy())


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


def test_none_store_refuses_naming_the_flag() raises:
    var store = ComposedSecretStore(SecretStoreChoice.NONE)
    var why = _refusal(store, String("KCI_CLI_TEST_SECRET"))
    assert_true(why.find(String("kci was run with --secret-store=none, so the secret 'KCI_CLI_TEST_SECRET'")) >= 0, why)
    assert_true(why.find(String("pass --secret-store=env")) >= 0, why)


def _plan_private(tag: String, store: String) raises -> Tuple[Int, String]:
    """`kci run --plan` of a PUBLISH stage on the fixture's PRIVATE API-token
    channel; returns the exit number and the result file."""
    var d = _root(tag)
    var r = ExampleRelease()
    var req = write_example_inputs(r, d, String("example-private"), True)
    var m = d + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\nstage { name: \"") + String(EXAMPLE_STAGE)
        + String("\" step { name: \"publish\" kind: PUBLISH platform: \"") + req.platform
        + String("\" declarations: \"") + req.declarations_file + String("\" channels: \"") + req.channels_file
        + String("\" channel: \"example-private\" } }\n"),
    )
    var a = List[String]()
    for s in ["run", "--stage", "prod", "--run-id", "gh-2", "--attempt", "1", "--plan"]:
        a.append(String(s))
    _flag(a, String("--machine"), m)
    _flag(a, String("--revision-id"), req.revision_id)
    _flag(a, String("--release-dir"), req.release_dir)
    _flag(a, String("--release-version"), req.release_version_file)
    _flag(a, String("--expect-set-hash"), req.expect_set_hash)
    _flag(a, String("--secret-store"), store)
    _flag(a, String("--result-file"), d + String("/result.json"))
    var steps = LibrarySteps()
    var rec = recorder_for(a)
    var rc = kci_main_with(a, steps, rec)
    return (rc, Path(d + String("/result.json")).read_text())


def test_publish_resolves_the_channel_secret_before_any_read() raises:
    assert_equal(_read_env("EXAMPLE_CONDA_TOKEN"), String(""))
    for store in [String("env"), String("none")]:
        var out = _plan_private(String("e2e_") + store, store)
        assert_equal(out[0], 4, out[1])
        var res = parse_result(out[1], String("result"))
        assert_equal(res.outcome, String("FAILED"))
        assert_equal(res.error.id, String("KCI-E-CREDENTIAL"))
        assert_true(res.plan)
        assert_equal(len(res.artifacts), 0)
        assert_equal(res.steps[0].kind, String("PUBLISH"))
        assert_equal(res.steps[0].name, String("publish"))


def test_a_build_step_reaches_kci_build() raises:
    var d = _root(String("build"))
    var m = d + String("/machine.textproto")
    write_whole_file(
        m,
        String("schema_version: 1\nstage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\"")
        + String(" declarations: \"") + d + String("/absent.textproto\" } }\n"),
    )
    makedirs(d + String("/work"), exist_ok=True)
    var a = List[String]()
    for s in ["run", "--stage", "build", "--run-id", "gh-4", "--attempt", "1", "--revision-id", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"]:
        a.append(String(s))
    _flag(a, String("--machine"), m)
    _flag(a, String("--release-dir"), d + String("/release"))
    _flag(a, String("--work-dir"), d + String("/work"))
    _flag(a, String("--log-dir"), d + String("/logs"))
    _flag(a, String("--result-file"), d + String("/result.json"))
    var steps = LibrarySteps()
    var rec = recorder_for(a)
    assert_equal(kci_main_with(a, steps, rec), 3)
    var res = parse_result(Path(d + String("/result.json")).read_text(), String("result"))
    assert_equal(res.error.id, String("KCI-E-DECLARATION"))
    assert_equal(res.steps[0].kind, String("BUILD"))
    assert_equal(res.steps[0].name, String("b"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
