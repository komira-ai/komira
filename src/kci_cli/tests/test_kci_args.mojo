# =============================================================================
# src/kci_cli/tests/test_kci_args.mojo -- the one parser and kci's one
#   command, `kci run`: every usage refusal (`ci check`, `--workflow`,
#   `--claim-new-name` and `--expect-set-hash` are gone), `--summary-file`,
#   the `--only` grammar, `--plan` on any stage, and the flags the selected
#   steps' kinds take (`require_stage_flags`), and `--build-budget-s`, the
#   per-change check's alone.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_cli import (
    KCI_USAGE,
    CLI_VERB_HELP,
    CLI_VERB_RUN,
    find_result_file,
    find_summary_file,
    parse_kci_args,
    require_stage_flags,
    selectors_of,
)
from kci_api import DEFAULT_MACHINE_FILE, Selector
from kci_release_machine import Selection, Stage, parse_machine_file, resolve_selection

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
    # the one default is kci_api's; kci_cli spells no path of its own
    assert_equal(String(DEFAULT_MACHINE_FILE), String("release/machine.textproto"))
    assert_equal(parse_kci_args(_run()).machine, String(DEFAULT_MACHINE_FILE))


def test_publish_flags() raises:
    var c = parse_kci_args(
        _run("--plan", "--release-version", "rv", "--concurrency", "4", "--secret-store", "env")
    )
    assert_true(c.plan)
    assert_equal(c.release_version, String("rv"))
    assert_equal(c.concurrency, 4)
    assert_equal(c.store.name(), String("env"))


def _selector_refused(args: List[String], needle: String) raises:
    var c = parse_kci_args(args)
    try:
        _ = selectors_of(c)
    except e:
        if String(e).find(needle) < 0:
            raise Error(String("expected '") + needle + String("' in: ") + String(e))
        return
    raise Error(String("not refused, expected: ") + needle)


def test_only_is_repeatable_and_positive() raises:
    var c = parse_kci_args(_run("--only", "step:publish", "--only=validation:smoke", "--only", "step:build"))
    assert_equal(len(c.only), 3)
    var s = selectors_of(c)
    assert_equal(len(s), 3)
    assert_equal(s[0].canonical(), String("step:publish"))
    assert_true(s[1].is_validation())
    assert_equal(s[2].name, String("build"))
    assert_equal(len(selectors_of(parse_kci_args(_run()))), 0)
    # grammar errors: refused before anything is read (KCI-E-SELECTOR, exit 2)
    _selector_refused(_run("--only", "publish"), String("--only 'publish' is not step:<name> or validation:<name>"))
    _selector_refused(_run("--only", "stage:prod"), String("'stage' is not a selector kind"))
    _selector_refused(_run("--only", "step:Build"), String("name 'Build' is not"))
    _selector_refused(_run("--only", "step:b", "--only=step:b"), String("--only 'step:b' is given twice"))
    _refused(_run("--only"), String("--only needs a value"))
    _refused(_run("--only="), String("--only is EMPTY"))


def test_no_other_operation_selector() raises:
    # the old spellings of a selection are not flags
    _refused(_run("--only-validations"), String("unknown flag '--only-validations'"))
    _refused(_run("--skip", "step:b"), String("unknown flag '--skip'"))
    _refused(_run("--steps", "b"), String("unknown flag '--steps'"))


def test_a_usage_refusal_carries_no_kci_prefix() raises:
    # The message is recorded as is and printed after the one `kci: ` the
    # dispatcher's `_stop` writes: a prefix here would print `kci: kci: `.
    try:
        _ = parse_kci_args(_run("--no-such-flag"))
    except e:
        assert_equal(String(e), String("unknown flag '--no-such-flag' for kci run"))
        return
    raise Error(String("--no-such-flag is not refused"))


def test_help() raises:
    assert_equal(parse_kci_args(_args("--help")).verb, String(CLI_VERB_HELP))
    assert_equal(parse_kci_args(_args("run", "-h")).verb, String(CLI_VERB_HELP))


def test_one_command() raises:
    _refused(_args(), String("no command: there is one, kci run --stage <S>"))
    _refused(_args("build", "--stage", "build"), String("unknown command 'build'"))
    _refused(_args("build", "--stage", "build"), String("no build, publish or other verb"))
    _refused(_args("publish", "--stage", "prod"), String("unknown command 'publish'"))
    _refused(_args("deploy"), String("unknown command 'deploy'"))
    _refused(_args("trust"), String("unknown command 'trust'"))
    _refused(_args("--stage", "x", "run"), String("kci run comes first"))
    # `kci ci check` is gone: the workflow check is what `kci run` does at start-up
    _refused(_args("ci", "check", "--workflow", "w.yml"), String("there is one command: kci run"))
    _refused(_args("ci"), String("there is one command: kci run"))
    # the usage text shows one command
    assert_true(String(KCI_USAGE).find(String("kci ci")) < 0, String(KCI_USAGE))
    assert_true(String(KCI_USAGE).find(String("--claim-new-name")) < 0, String(KCI_USAGE))
    assert_true(String(KCI_USAGE).find(String("--expect-set-hash")) < 0, String(KCI_USAGE))
    assert_true(String(KCI_USAGE).find(String("--summary-file")) >= 0, String(KCI_USAGE))


def test_removed_flags_are_refused() raises:
    _refused(_run("--workflow", "w"), String("unknown flag '--workflow' for kci run"))
    _refused(_run("--claim-new-name", "komira_all"), String("unknown flag '--claim-new-name' for kci run"))
    _refused(_run("--expect-set-hash", "ab"), String("unknown flag '--expect-set-hash' for kci run"))


def test_summary_file() raises:
    # accepted on any stage, by either spelling; not repeatable
    assert_equal(parse_kci_args(_run("--summary-file", "/s.md")).summary_file, String("/s.md"))
    assert_equal(parse_kci_args(_run("--summary-file=/t.md")).summary_file, String("/t.md"))
    assert_equal(parse_kci_args(_run()).summary_file, String(""))
    _refused(_run("--summary-file", "/a", "--summary-file", "/b"), String("--summary-file is given twice"))
    _refused(_run("--summary-file="), String("--summary-file is EMPTY"))
    assert_equal(find_summary_file(_args("ci", "--summary-file", "/s.md")), String("/s.md"))
    assert_equal(find_summary_file(_args("run", "--summary-file=/q.md", "--bogus")), String("/q.md"))


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


def test_pixi_flags_values() raises:
    var c = parse_kci_args(
        _run("--pixi", "/t/pixi", "--pixi-sha256", "807eabf195b13d6393b832ecccf93bf59bf784425674a60c7b50b1b84a58367f")
    )
    assert_equal(c.pixi, String("/t/pixi"))
    assert_equal(c.pixi_sha256, String("807eabf195b13d6393b832ecccf93bf59bf784425674a60c7b50b1b84a58367f"))
    _refused(_run("--pixi", "pixi"), String("--pixi 'pixi' is not an absolute path"))
    _refused(_run("--pixi-sha256", "ABC"), String("--pixi-sha256 'ABC' is not 64 lowercase hex characters"))
    # an empty sha (an unset variable in the job) is a usage error before any pixi runs
    _refused(_run("--pixi-sha256", ""), String("--pixi-sha256 is EMPTY"))
    _refused(_run("--pixi-sha256="), String("--pixi-sha256 is EMPTY"))
    _refused(
        _run("--pixi-sha256", "807EABF195B13D6393B832ECCCF93BF59BF784425674A60C7B50B1B84A58367F"),
        String("is not 64 lowercase hex characters"),
    )


def test_channel_is_a_plain_absolute_file_location() raises:
    var c = parse_kci_args(_run("--channel", "file:///home/u/channel"))
    assert_equal(c.channel, String("file:///home/u/channel"))
    _refused(_run("--channel", "https://prefix.dev/komira-ai/gamma"), String("it is not a file:/// location"))
    _refused(_run("--channel", "gamma"), String("--channel 'gamma' is not file:///<absolute directory>, a local channel"))
    for bad in ["file:///", "file://host/c", "file:///a/../c", "file:///a/./c", "file:///a//c", "/home/u/channel"]:
        _refused(_run("--channel", bad), String("--channel '") + String(bad) + String("' is not file:///<absolute directory>"))
    _refused(_run("--channel", "file:///a", "--channel", "file:///b"), String("--channel is given twice"))


def test_find_result_file() raises:
    assert_equal(find_result_file(_args("build", "--result-file", "/r.json")), String("/r.json"))
    assert_equal(find_result_file(_args("run", "--result-file=/q.json", "--bogus")), String("/q.json"))
    assert_equal(find_result_file(_args("run")), String(""))


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" } }\n"
    "stage { name: \"prod\" after: \"build\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\""
    " artifacts: \"d\" channels: \"c\" channel: \"komira\" } }\n"
    "stage { name: \"all\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" }"
    " step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d\" channels: \"c\" channel: \"komira\" } }\n"
)


def _all(stage: Stage) raises -> Selection:
    return resolve_selection(stage, List[Selector]())


def _stage_refused(args: List[String], stage: String, needle: String) raises:
    var g = parse_machine_file(String(_MACHINE), String("m"))
    var c = parse_kci_args(args)
    try:
        require_stage_flags(c, g.stage(stage), resolve_selection(g.stage(stage), selectors_of(c)))
    except e:
        if String(e).find(needle) < 0:
            raise Error(String("expected '") + needle + String("' in: ") + String(e))
        return
    raise Error(String("not refused, expected: ") + needle)


def test_stage_flags() raises:
    var g = parse_machine_file(String(_MACHINE), String("m"))
    require_stage_flags(parse_kci_args(_run("--work-dir", "/w", "--log-dir", "/l")), g.stage(String("build")), _all(g.stage(String("build"))))
    require_stage_flags(parse_kci_args(_run("--release-version", "rv", "--plan")), g.stage(String("prod")), _all(g.stage(String("prod"))))
    require_stage_flags(
        parse_kci_args(_run("--work-dir", "/w", "--log-dir", "/l", "--release-version", "rv")),
        g.stage(String("all")),
        _all(g.stage(String("all"))),
    )
    _stage_refused(_run("--log-dir", "/l"), String("build"), String("stage 'build' has a BUILD step: kci run needs --work-dir"))
    # --plan is the whole run's dry run: accepted on a build-only stage
    require_stage_flags(parse_kci_args(_run("--work-dir", "/w", "--log-dir", "/l", "--plan")), g.stage(String("build")), _all(g.stage(String("build"))))
    _stage_refused(_run("--work-dir", "/w", "--log-dir", "/l", "--release-version", "rv"), String("build"), String("--release-version is a PUBLISH step's flag, and stage 'build' has no PUBLISH step"))
    _stage_refused(_run("--release-version", "rv", "--work-dir", "/w"), String("prod"), String("--work-dir is a BUILD step's flag"))
    _stage_refused(_run("--plan"), String("prod"), String("stage 'prod' has a PUBLISH step: kci run needs --release-version"))
    _stage_refused(_run("--work-dir", "/w", "--log-dir", "/l"), String("all"), String("kci run needs --release-version"))
    # --summary-file is no step's flag: any stage takes it
    require_stage_flags(parse_kci_args(_run("--work-dir", "/w", "--log-dir", "/l", "--summary-file", "/s")), g.stage(String("build")), _all(g.stage(String("build"))))


def test_flags_follow_the_selected_steps() raises:
    var g = parse_machine_file(String(_MACHINE), String("m"))
    var st = g.stage(String("all"))
    # only the PUBLISH step selected: the BUILD flags are neither needed nor taken
    var p = parse_kci_args(_run("--only", "step:p", "--release-version", "rv"))
    require_stage_flags(p, st, resolve_selection(st, selectors_of(p)))
    _stage_refused(
        _run("--only", "step:p", "--release-version", "rv", "--work-dir", "/w"),
        String("all"),
        String("--work-dir is a BUILD step's flag, and the steps --only selects in stage 'all' hold no BUILD step"),
    )
    # only the BUILD step selected: the PUBLISH flags are not required
    var b = parse_kci_args(_run("--only", "step:b", "--work-dir", "/w", "--log-dir", "/l"))
    require_stage_flags(b, st, resolve_selection(st, selectors_of(b)))
    _stage_refused(
        _run("--only", "step:b", "--work-dir", "/w"),
        String("all"),
        String("the steps --only selects in stage 'all' include a BUILD step: kci run needs --log-dir"),
    )


comptime _BASE: String = "0123456789abcdef0123456789abcdef01234567"


def _pr(*extra: String) -> List[String]:
    """A per-change check: --affected-by, and no --release-dir."""
    var l = _args("run", "--stage", "build", "--revision-id", _REV, "--run-id", "gh-1", "--attempt", "1", "--affected-by", _BASE)
    for s in extra:
        l.append(String(s))
    return l^


def test_affected_by() raises:
    var g = parse_machine_file(String(_MACHINE), String("m"))
    var c = parse_kci_args(_pr("--work-dir", "/w", "--log-dir", "/l"))
    assert_equal(c.affected_by, String(_BASE))
    assert_equal(c.release_dir, String(""))
    require_stage_flags(c, g.stage(String("build")), _all(g.stage(String("build"))))
    # --plan asks and builds nothing; it combines
    assert_true(parse_kci_args(_pr("--plan", "--work-dir", "/w", "--log-dir", "/l")).plan)
    _refused(_pr("--work-dir", "/w", "--log-dir", "/l", "--affected-by", _BASE), String("--affected-by is given twice"))
    var short = _pr("--work-dir", "/w", "--log-dir", "/l")
    short[10] = String("0123456")  # --affected-by's value
    _refused(short, String("--affected-by '0123456' is not a full commit id"))
    _refused(
        _pr("--only", "step:b", "--work-dir", "/w", "--log-dir", "/l"),
        String("--affected-by and --only both select what runs"),
    )
    _refused(
        _pr("--release-dir", "/r", "--work-dir", "/w", "--log-dir", "/l"),
        String("--release-dir is not used with --affected-by: the per-change check releases nothing"),
    )
    # a stage holding anything but BUILD steps is refused before any flag check
    _stage_refused(
        _pr("--release-version", "rv"),
        String("prod"),
        String("--affected-by builds what a change reaches and nothing else, and stage 'prod' has the PUBLISH step 'p'"),
    )
    _stage_refused(
        _pr("--work-dir", "/w", "--log-dir", "/l"),
        String("all"),
        String("stage 'all' has the PUBLISH step 'p'"),
    )
    # the BUILD step's flags are still needed
    _stage_refused(_pr("--log-dir", "/l"), String("build"), String("kci run needs --work-dir"))


comptime _PRE: String = "registry.example.invalid/busybox@sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
comptime _UNPINNED: String = "unpinned.invalid/busybox@sha256:0000000000000000000000000000000000000000000000000000000000000000"
comptime _PROBE_IMAGE: String = "registry.example.invalid/probe@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def test_preflight_image_values() raises:
    assert_equal(parse_kci_args(_run("--preflight-image", _PRE)).preflight_image, String(_PRE))
    _refused(
        _run("--preflight-image", "busybox:1.37"),
        String("--preflight-image 'busybox:1.37' is not pinned by digest, <reference>@sha256:<64 lowercase hex> (a tag is refused)"),
    )
    _refused(_run("--preflight-image", "busybox@sha256:abc"), String("is not pinned by digest"))
    _refused(_run("--preflight-image", ""), String("--preflight-image is EMPTY"))
    _refused(_run("--preflight-image", _PRE, "--preflight-image", _PRE), String("--preflight-image is given twice"))
    # the table's placeholder is well-formed: refused only where a probe would run
    assert_equal(parse_kci_args(_run("--preflight-image", _UNPINNED)).preflight_image, String(_UNPINNED))


def _probe_block(name: String) -> String:
    return (
        String(" validation { name: \"") + name + String("\" kind: DEPLOY_PROBE image: \"") + String(_PROBE_IMAGE)
        + String("\" timeout_seconds: 60 expect: \"health\" }")
    )


def _probe_machine() -> String:
    """A DEPLOY step with two probes, and a stage with an ENV validation."""
    return (
        String("schema_version: 1\nname: \"shop\"\n")
        + String("stage { name: \"staging\" step { name: \"deploy\" kind: DEPLOY cells: \"c\" cell: \"staging\"")
        + String(" resources: \"r\"") + _probe_block(String("p1")) + _probe_block(String("p2")) + String(" } }\n")
        + String("stage { name: \"gamma\" step { name: \"p\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d\"")
        + String(" channels: \"c\" channel: \"komira\" validation { name: \"env\" kind: CONDA_INSTALL_ENV")
        + String(" install: \"komira\" compiler_channel: \"https://conda.example.invalid/max\" } } }\n")
    )


def _probe_flags(stage: String, *extra: String) raises:
    """`require_stage_flags` of a validation-only run of `stage`."""
    var g = parse_machine_file(_probe_machine(), String("m"))
    var l = _args("run", "--stage", stage, "--revision-id", _REV, "--run-id", "gh-1", "--attempt", "1", "--release-dir", "/r")
    for s in extra:
        l.append(String(s))
    var c = parse_kci_args(l)
    require_stage_flags(c, g.stage(stage), resolve_selection(g.stage(stage), selectors_of(c)))


def _probe_refused(stage: String, needle: String, *extra: String) raises:
    var g = parse_machine_file(_probe_machine(), String("m"))
    var l = _args("run", "--stage", stage, "--revision-id", _REV, "--run-id", "gh-1", "--attempt", "1", "--release-dir", "/r")
    for s in extra:
        l.append(String(s))
    var c = parse_kci_args(l)
    try:
        require_stage_flags(c, g.stage(stage), resolve_selection(g.stage(stage), selectors_of(c)))
    except e:
        if String(e).find(needle) < 0:
            raise Error(String("expected '") + needle + String("' in: ") + String(e))
        return
    raise Error(String("not refused, expected: ") + needle)


def test_a_selected_probe_needs_a_pinned_preflight_image() raises:
    _probe_flags(String("staging"), "--only", "validation:p1", "--scratch-dir", "/s", "--preflight-image", _PRE)
    # the SECOND probe alone selected: still needs it
    _probe_refused(
        String("staging"),
        String("--only in stage 'staging' selects the DEPLOY_PROBE validation 'p2': kci run needs --preflight-image"),
        "--only", "validation:p2", "--scratch-dir", "/s",
    )
    _probe_refused(
        String("staging"), String("selects the DEPLOY_PROBE validation 'p1': kci run needs --preflight-image"),
        "--scratch-dir", "/s",
    )
    # the table's placeholder fails closed at start
    _probe_refused(
        String("staging"),
        String("selects the DEPLOY_PROBE validation 'p2': --preflight-image '") + String(_UNPINNED)
        + String("' is the platform table's placeholder"),
        "--only", "validation:p2", "--scratch-dir", "/s", "--preflight-image", _UNPINNED,
    )
    # any validation takes it (kci.yml passes it beside --pixi), placeholder or not
    _probe_flags(
        String("gamma"), "--only", "validation:env", "--scratch-dir", "/s", "--pixi", "/t/pixi",
        "--pixi-sha256", "807eabf195b13d6393b832ecccf93bf59bf784425674a60c7b50b1b84a58367f", "--preflight-image", _UNPINNED,
    )
    # a run that selects no validation refuses it
    _probe_refused(
        String("gamma"),
        String("--preflight-image is a validation's flag, and --only in stage 'gamma' selects no validation"),
        "--only", "step:p", "--release-version", "rv", "--preflight-image", _PRE,
    )


def test_build_budget_is_the_per_change_check_s() raises:
    var g = parse_machine_file(String(_MACHINE), String("m"))
    var c = parse_kci_args(_pr("--work-dir", "/w", "--log-dir", "/l", "--build-budget-s", "6900"))
    assert_equal(c.build_budget_s, 6900)
    require_stage_flags(c, g.stage(String("build")), _all(g.stage(String("build"))))
    assert_equal(parse_kci_args(_pr("--build-budget-s=60")).build_budget_s, 60)
    # absent: no budget
    assert_equal(parse_kci_args(_pr("--work-dir", "/w", "--log-dir", "/l")).build_budget_s, 0)
    _refused(_pr("--build-budget-s", "0"), String("--build-budget-s '0' is not a positive decimal integer"))
    _refused(_pr("--build-budget-s", "-12"), String("--build-budget-s '-12' is not a positive decimal integer"))
    _refused(_pr("--build-budget-s", "60", "--build-budget-s", "61"), String("--build-budget-s is given twice"))
    # at most a week, so the deadline arithmetic stays far inside an Int
    assert_equal(parse_kci_args(_pr("--build-budget-s", "604800")).build_budget_s, 604800)
    _refused(_pr("--build-budget-s", "604801"), String("--build-budget-s '604801' is more than 604800 (a week)"))
    _refused(_pr("--build-budget-s", "999999999"), String("is more than 604800"))
    # komira#1153: under a budget every build run may take all the budget left,
    # so a per-run cap beside it is refused, never silently ignored; either
    # alone is still taken
    _refused(
        _pr("--work-dir", "/w", "--log-dir", "/l", "--build-budget-s", "6900", "--build-timeout-s", "3600"),
        String("--build-timeout-s is not used with --build-budget-s: every build run may take all the budget left"),
    )
    assert_equal(parse_kci_args(_pr("--work-dir", "/w", "--log-dir", "/l", "--build-timeout-s", "60")).build_timeout_s, 60)
    # a release build has no budget to share: refused, never silently ignored
    _refused(
        _run("--work-dir", "/w", "--log-dir", "/l", "--build-budget-s", "60"),
        String("--build-budget-s bounds the per-change check's build of the units: it is used only with --affected-by"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
