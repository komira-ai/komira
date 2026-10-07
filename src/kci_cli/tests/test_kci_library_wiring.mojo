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
#
#   The reads around the steps: `platform_env` reads this process's
#   environment (KCI_CLI_TEST_SECRET is set by `test_env`; an unset name is
#   ""), and `committed_file` and `is_ancestor` refuse, naming RUNNER_TEMP,
#   outside a runner. `git_is_ancestor` over a scripted git: a shallow
#   checkout raises, exit 0 is True, 1 False, anything else raises (asked
#   of the full refname `refs/remotes/origin/main`, which no tag answers);
#   `git_first_parent` over a scripted git and `carried_markdown` (what a
#   main-only publish carries); `git_history` over a scripted git (what a
#   never-backward publish holds the channel's newest build against: a
#   shallow checkout or a line that is not a commit id raises, never a
#   short history); and
#   `release_set_hash` is the set the example release's members recompute
#   to, and raises on a release directory that is refused.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_build import ScriptedRunner, ScriptedStep
from kci_cli import (
    ComposedSecretStore,
    LibrarySteps,
    MAIN_TRACKING_REF,
    SecretStoreChoice,
    carried_markdown,
    git_first_parent,
    git_history,
    git_is_ancestor,
    kci_main_with,
    recorder_for,
    write_whole_file,
)
from kci_api import parse_result
from kci_publish.release_fixture import (
    EXAMPLE_ENVIRONMENT,
    EXAMPLE_STAGE,
    EXAMPLE_TOKEN_SECRET,
    ExampleRelease,
    write_example_inputs,
)


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
        + String("\" environment: \"") + String(EXAMPLE_ENVIRONMENT)
        + String("\" step { name: \"publish\" kind: PUBLISH platform: \"") + req.platform
        + String("\" artifacts: \"") + req.artifacts_file + String("\" channels: \"") + req.channels_file
        + String("\" channel: \"example-private\" } }\n"),
    )
    var a = List[String]()
    for s in ["run", "--run-id", "gh-2", "--attempt", "1", "--plan"]:
        a.append(String(s))
    _flag(a, String("--stage"), String(EXAMPLE_STAGE))
    _flag(a, String("--machine"), m)
    _flag(a, String("--revision-id"), req.revision_id)
    _flag(a, String("--release-dir"), req.release_dir)
    _flag(a, String("--release-version"), req.release_version_file)
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
        + String(" artifacts: \"") + d + String("/absent.textproto\" } }\n"),
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
    assert_equal(res.error.id, String("KCI-E-ARTIFACT"))
    assert_equal(res.steps[0].kind, String("BUILD"))
    assert_equal(res.steps[0].name, String("b"))


def test_the_real_platform_env_and_committed_file() raises:
    var steps = LibrarySteps()
    assert_equal(steps.platform_env(String("KCI_CLI_TEST_SECRET")), String("kci-cli-test-value"))
    assert_equal(steps.platform_env(String("KCI_CLI_TEST_UNSET_VARIABLE")), String(""))
    if _read_env("RUNNER_TEMP").byte_length() == 0:
        var why = String("<read>")
        try:
            _ = steps.committed_file(String("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"), String(".github/workflows/kci.yml"))
        except e:
            why = String(e)
        assert_true(why.find(String("RUNNER_TEMP is not set")) >= 0, why)


def _argv(*xs: String) -> List[String]:
    var l = List[String]()
    for x in xs:
        l.append(String(x))
    return l^


def _shallow(answer: String) -> ScriptedStep:
    return ScriptedStep(_argv("rev-parse", "--is-shallow-repository"), stdout_text=answer)


def test_git_is_ancestor_over_a_scripted_git() raises:
    # kci asks of the remote-tracking ref by its FULL name: `origin/main`
    # would resolve a tag of that name first (gitrevisions(7))
    assert_equal(String(MAIN_TRACKING_REF), String("refs/remotes/origin/main"))
    var d = _root(String("ancestor"))
    var rev = String("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
    for code in [0, 1]:
        var g = ScriptedRunner()
        g.expect(_shallow(String("false\n")))
        g.expect(ScriptedStep(_argv("merge-base", "--is-ancestor", rev, "refs/remotes/origin/main"), exit_code=Int32(code)))
        assert_equal(git_is_ancestor(g, d, rev, String("refs/remotes/origin/main")), code == 0)
        assert_equal(g.remaining(), 0)
    # a shallow checkout's history cannot tell: raised, merge-base never asked
    var shallow = ScriptedRunner()
    shallow.expect(_shallow(String("true\n")))
    var why = String("<answered>")
    try:
        _ = git_is_ancestor(shallow, d, rev, String("refs/remotes/origin/main"))
    except e:
        why = String(e)
    assert_true(why.find(String("shallow")) >= 0, why)
    # an unknown ref (exit 128) or a timeout: raised, never False
    var unknown = ScriptedRunner()
    unknown.expect(_shallow(String("false\n")))
    unknown.expect(ScriptedStep(_argv("merge-base", "--is-ancestor", rev, "refs/remotes/origin/main"), exit_code=Int32(128), stderr_text=String("fatal: Not a valid object name origin/main")))
    var why2 = String("<answered>")
    try:
        _ = git_is_ancestor(unknown, d, rev, String("refs/remotes/origin/main"))
    except e:
        why2 = String(e)
    assert_true(why2.find(String("exit 128")) >= 0 and why2.find(String("Not a valid object name")) >= 0, why2)
    var slow = ScriptedRunner()
    slow.expect(_shallow(String("false\n")))
    slow.expect(ScriptedStep(_argv("merge-base", "--is-ancestor", rev, "refs/remotes/origin/main"), timed_out=True))
    var why3 = String("<answered>")
    try:
        _ = git_is_ancestor(slow, d, rev, String("refs/remotes/origin/main"))
    except e:
        why3 = String(e)
    assert_true(why3.find(String("timed out")) >= 0, why3)


def test_git_first_parent_and_what_a_release_carries() raises:
    var d = _root(String("firstparent"))
    var rev = String("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
    var c1 = String("1111111111111111111111111111111111111111")
    var c2 = String("2222222222222222222222222222222222222222")
    var g = ScriptedRunner()
    g.expect(
        ScriptedStep(
            _argv("rev-list", "--first-parent", "--reverse", rev),
            stdout_text=c1 + String("\n") + c2 + String("\n") + rev + String("\n"),
        )
    )
    var fp = git_first_parent(g, d, rev)
    assert_equal(len(fp), 3)
    assert_equal(fp[2], rev)
    # the channel's last build was 1 (c1): c2 and rev ride in build 3
    var md = carried_markdown(String("prod"), 1, 3, fp)
    assert_true(md.startswith(String("#### carried to prod\n\n2 commit(s) of main ride in build 3 (after build 1")), md)
    assert_true(md.find(String("- `") + c2 + String("`\n- `") + rev + String("`\n")) >= 0, md)
    assert_true(md.find(c1) < 0, md)
    # none before: the first build; a previous build past the history: said
    assert_true(carried_markdown(String("prod"), -1, 3, fp).find(String("build 3 is its first")) >= 0)
    assert_true(carried_markdown(String("prod"), 9, 3, fp).find(String("cannot be listed")) >= 0)
    assert_equal(carried_markdown(String("prod"), 1, -1, fp), String(""))
    # a long gap is cut at 40 lines
    var many = List[String]()
    for _ in range(50):
        many.append(c1.copy())
    assert_true(carried_markdown(String("prod"), 0, 50, many).find(String("- ... and 10 more")) >= 0)
    # git that does not print commit ids raises
    var bad = ScriptedRunner()
    bad.expect(ScriptedStep(_argv("rev-list", "--first-parent", "--reverse", rev), stdout_text=String("main\n")))
    var why = String("<answered>")
    try:
        _ = git_first_parent(bad, d, rev)
    except e:
        why = String(e)
    assert_true(why.find(String("not a full commit id")) >= 0, why)


def test_git_history_over_a_scripted_git() raises:
    var d = _root(String("history"))
    var rev = String("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
    var c1 = String("1111111111111111111111111111111111111111")
    var g = ScriptedRunner()
    g.expect(_shallow(String("false\n")))
    g.expect(ScriptedStep(_argv("rev-list", rev), stdout_text=rev + String("\n") + c1 + String("\n")))
    var h = git_history(g, d, rev)
    assert_equal(len(h), 2)
    assert_equal(h[0], rev)
    assert_equal(h[1], c1)
    assert_equal(g.remaining(), 0)
    # a shallow checkout lists part of the history: raised, rev-list never asked
    var shallow = ScriptedRunner()
    shallow.expect(_shallow(String("true\n")))
    var why = String("<answered>")
    try:
        _ = git_history(shallow, d, rev)
    except e:
        why = String(e)
    assert_true(why.find(String("shallow")) >= 0, why)
    # git that does not print commit ids, or exits 1: raised
    var bad = ScriptedRunner()
    bad.expect(_shallow(String("false\n")))
    bad.expect(ScriptedStep(_argv("rev-list", rev), stdout_text=String("main\n")))
    var why2 = String("<answered>")
    try:
        _ = git_history(bad, d, rev)
    except e:
        why2 = String(e)
    assert_true(why2.find(String("not a full commit id")) >= 0, why2)
    var one = ScriptedRunner()
    one.expect(_shallow(String("false\n")))
    one.expect(ScriptedStep(_argv("rev-list", rev), exit_code=Int32(1)))
    var why3 = String("<answered>")
    try:
        _ = git_history(one, d, rev)
    except e:
        why3 = String(e)
    assert_true(why3.find(String("exited 1")) >= 0, why3)


def test_the_real_release_set_hash() raises:
    var d = _root(String("sethash"))
    var r = ExampleRelease()
    var req = write_example_inputs(r, d, String("example-private"), True)
    var steps = LibrarySteps()
    var dir = req.platform_dir()
    assert_equal(steps.release_set_hash(req.artifacts_file, dir), r.set_hash(dir))
    # a member changed after the build: refused, never a hash
    write_whole_file(dir + String("/release.json"), String("{}"))
    var why = String("<recomputed>")
    try:
        _ = steps.release_set_hash(req.artifacts_file, dir)
    except e:
        why = String(e)
    assert_true(why != String("<recomputed>"), why)


def test_is_ancestor_outside_a_runner_refuses() raises:
    if _read_env("RUNNER_TEMP").byte_length() == 0:
        var steps = LibrarySteps()
        var why = String("<read>")
        try:
            _ = steps.is_ancestor(String("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"), String("refs/remotes/origin/main"))
        except e:
            why = String(e)
        assert_true(why.find(String("RUNNER_TEMP is not set")) >= 0, why)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
