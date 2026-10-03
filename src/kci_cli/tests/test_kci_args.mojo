# =============================================================================
# src/kci_cli/tests/test_kci_args.mojo -- the one parser: `kci run` and
#   `kci ci check`, every usage refusal, and the flags a stage's step kinds
#   take (`require_stage_flags`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_cli import CLI_VERB_CI_CHECK, CLI_VERB_HELP, CLI_VERB_RUN, find_result_file, parse_kci_args, require_stage_flags
from kci_stage_graph import parse_machine_file

comptime _REV: String = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"


def _args(*items: String) -> List[String]:
    var l = List[String]()
    for s in items:
        l.append(String(s))
    return l^


def _run(*extra: String) -> List[String]:
    var l = _args("run", "--stage", "build", "--revision-id", _REV, "--run-id", "gh-1", "--attempt", "1", "--release-dir", "/r")
    for s in extra:
        l.append(String(s))
    return l^


def _refused(args: List[String], needle: String) raises:
    try:
        _ = parse_kci_args(args)
    except e:
        if String(e).find(needle) < 0:
            raise Error(String("expected '") + needle + String("' in: ") + String(e))
        return
    raise Error(String("not refused, expected: ") + needle)


def test_run_reads_every_flag() raises:
    var c = parse_kci_args(
        _run(
            "--machine", "m.textproto", "--context", "event=push", "--context=ref=refs/heads/main",
            "--result-file=/tmp/r.json", "--work-dir", "/w", "--log-dir", "/l", "--build-timeout-s", "60",
        )
    )
    assert_equal(c.verb, String(CLI_VERB_RUN))
    assert_equal(c.machine, String("m.textproto"))
    assert_equal(c.stage, String("build"))
    assert_equal(c.revision_id, String(_REV))
    assert_equal(c.attempt, 1)
    assert_equal(len(c.context), 2)
    assert_equal(c.context[1].key, String("ref"))
    assert_equal(c.context[1].value, String("refs/heads/main"))
    assert_equal(c.result_file, String("/tmp/r.json"))
    assert_equal(c.build_timeout_s, 60)
    var id = c.run_identity()
    assert_equal(id.run_id, String("gh-1"))


def test_the_machine_file_defaults() raises:
    assert_equal(parse_kci_args(_run()).machine, String("release/machine.textproto"))
    var ci = parse_kci_args(_args("ci", "check", "--workflow", "w.yml"))
    assert_equal(ci.verb, String(CLI_VERB_CI_CHECK))
    assert_equal(ci.machine, String("release/machine.textproto"))


def test_publish_flags() raises:
    var c = parse_kci_args(
        _run("--plan", "--expect-set-hash", "ab", "--claim-new-name", "x", "--claim-new-name", "y",
             "--release-version", "rv", "--concurrency", "4", "--secret-store", "env")
    )
    assert_true(c.plan)
    assert_equal(len(c.claims), 2)
    assert_equal(c.concurrency, 4)
    assert_equal(c.store.name(), String("env"))


def test_help() raises:
    assert_equal(parse_kci_args(_args("--help")).verb, String(CLI_VERB_HELP))
    assert_equal(parse_kci_args(_args("run", "-h")).verb, String(CLI_VERB_HELP))


def test_one_verb_for_stages() raises:
    _refused(_args(), String("no verb"))
    _refused(_args("build", "--stage", "build"), String("unknown verb 'build'"))
    _refused(_args("build", "--stage", "build"), String("there is no build or publish verb"))
    _refused(_args("publish", "--stage", "prod"), String("unknown verb 'publish'"))
    _refused(_args("deploy"), String("unknown verb 'deploy'"))
    _refused(_args("--stage", "x", "run"), String("the verb comes first"))
    _refused(_args("ci"), String("`kci ci` takes one verb: check"))
    _refused(_args("ci", "lint"), String("`kci ci` takes one verb: check"))


def test_run_refusals() raises:
    for f in ["--stage", "--revision-id", "--run-id", "--attempt", "--release-dir"]:
        var a = List[String]()
        var full = _run()
        var i = 0
        while i < len(full):
            if full[i] == String(f):
                i += 2
                continue
            a.append(full[i].copy())
            i += 1
        _refused(a, String("kci run needs ") + String(f))
    _refused(_run("--dry-run"), String("unknown flag '--dry-run' for kci run"))
    _refused(_run("--workflow", "w"), String("unknown flag '--workflow' for kci run"))
    _refused(_run("--stage", "prod"), String("--stage is given twice"))
    _refused(_run("--plan=yes"), String("--plan takes no value"))
    _refused(_run("--work-dir"), String("--work-dir needs a value"))
    _refused(_run("--work-dir", ""), String("--work-dir is EMPTY"))
    _refused(_run("extra"), String("unexpected argument 'extra'"))
    _refused(_run("--build-timeout-s", "0"), String("is not a positive decimal integer"))
    _refused(_run("--secret-store", "vault"), String("is not a store kind"))


def test_run_identity_grammar() raises:
    var a = _run()
    a[2 + 4] = String("GH-1")  # --run-id's value
    _refused(a, String("--run-id 'GH-1'"))
    var b = _run()
    b[2 + 6] = String("0")  # --attempt's value
    _refused(b, String("--attempt '0'"))
    var c = _run()
    c[2 + 2] = String("abc")  # --revision-id's value
    _refused(c, String("--revision-id"))
    _refused(_run("--context", "noequals"), String("is not key=value"))
    _refused(_run("--context", "Event=x"), String("is not [a-z][a-z0-9_]*"))
    _refused(_run("--context", "a=1", "--context", "a=2"), String("--context a is given twice"))


def test_ci_check_refusals() raises:
    _refused(_args("ci", "check"), String("kci ci check needs --workflow"))
    _refused(_args("ci", "check", "--workflow", "w", "--run-id", "x"), String("unknown flag '--run-id' for kci ci check"))
    _refused(_args("ci", "check", "--workflow", "w", "--stage", "x"), String("unknown flag '--stage'"))


def test_find_result_file() raises:
    assert_equal(find_result_file(_args("build", "--result-file", "/r.json")), String("/r.json"))
    assert_equal(find_result_file(_args("run", "--result-file=/q.json", "--bogus")), String("/q.json"))
    assert_equal(find_result_file(_args("run")), String(""))


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" } }\n"
    "stage { name: \"prod\" after: \"build\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\""
    " declarations: \"d\" channels: \"c\" channel: \"komira\" } }\n"
    "stage { name: \"all\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" }"
    " step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d\" channels: \"c\" channel: \"komira\" } }\n"
)


def _stage_refused(args: List[String], stage: String, needle: String) raises:
    var g = parse_machine_file(String(_MACHINE), String("m"))
    var c = parse_kci_args(args)
    try:
        require_stage_flags(c, g.stage(stage))
    except e:
        if String(e).find(needle) < 0:
            raise Error(String("expected '") + needle + String("' in: ") + String(e))
        return
    raise Error(String("not refused, expected: ") + needle)


def test_stage_flags() raises:
    var g = parse_machine_file(String(_MACHINE), String("m"))
    require_stage_flags(parse_kci_args(_run("--work-dir", "/w", "--log-dir", "/l")), g.stage(String("build")))
    require_stage_flags(parse_kci_args(_run("--expect-set-hash", "h", "--release-version", "rv", "--plan")), g.stage(String("prod")))
    require_stage_flags(
        parse_kci_args(_run("--work-dir", "/w", "--log-dir", "/l", "--expect-set-hash", "h", "--release-version", "rv")),
        g.stage(String("all")),
    )
    _stage_refused(_run("--log-dir", "/l"), String("build"), String("stage 'build' has a BUILD step: kci run needs --work-dir"))
    _stage_refused(_run("--work-dir", "/w", "--log-dir", "/l", "--plan"), String("build"), String("--plan is a PUBLISH step's flag, and stage 'build' has no PUBLISH step"))
    _stage_refused(_run("--expect-set-hash", "h", "--release-version", "rv", "--work-dir", "/w"), String("prod"), String("--work-dir is a BUILD step's flag"))
    _stage_refused(_run("--release-version", "rv"), String("prod"), String("kci run needs --expect-set-hash"))
    _stage_refused(_run("--work-dir", "/w", "--log-dir", "/l", "--expect-set-hash", "h"), String("all"), String("kci run needs --release-version"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
