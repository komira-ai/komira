# =============================================================================
# src/kci_validate/conda_install_env.mojo -- a CONDA_INSTALL_ENV validation:
#   install what a PUBLISH step published, from that step's channel, the way
#   a consumer gets it, on THIS machine with no container, and run each
#   installed library's README examples against it.
# =============================================================================
#
# `run_install_env` runs one validation (`ValidateRequest`, request.mojo)
# in this order. Checks 0 to 4 and their rows are CONDA_INSTALL_SMOKE's
# (conda_install_smoke.mojo); what differs is where the install runs
# (env.mojo) and what program runs (readme_installed.mojo):
#
#   0  release   the release of the step's platform, built from
#                --revision-id; a pin for every install name, then for
#                every member of a named metapackage (request.mojo
#                `with_members`: read from the built metapackage's own
#                depends, at release.json's version and build, equal to
#                the set's libraries). pixi.toml names ONLY the install
#                names, so the solver must bring each member through the
#                metapackage; every later check covers EVERY pin
#   -  network   every declared host asked once (network.mojo): NONE
#                answered is no network, the one case that is not a FAIL:
#                outcome INDETERMINATE (exit 5, never a pass) with
#                `skip_reason`, and nothing else runs; SOME not answering is
#                a FAIL
#   1  channel   the channel read anonymously from this machine
#                (channel_index.mojo), with the wait for an absent file
#   -  host      no system-wide pixi config (env.mojo `system_configs`)
#   -  scratch   a fresh `<scratch>/<validation>/` whose real path is not
#                inside the checkout; work/pixi.toml and work/auth.json
#   -  pixi      bin/pixi links the --pixi given; the bytes through the link
#                have sha256 --pixi-sha256 (the row records the sha256 read)
#   2  install   `pixi install` (cwd <w>, the cleared environment); its
#                exit recorded in out/install.exit; then the environment
#                must be <w>/.pixi/envs/default itself (not a link
#                elsewhere), and every conda-meta record is read back
#   -  readme    for each LIBRARY pin: its installed README, its sha256
#                against metadata.json `doc_files`, made into the runner
#                <w>/readme_<import>.mojo and one program per example beside
#                it, <w>/readme_<import>_<line>.mojo; refused when there is none, when
#                the bytes differ, or when it holds no example. No library
#                among the pins is refused too (a README that runs nothing
#                is not a pass)
#   3  payload   kci hashes each library's installed payload itself and
#                writes out/payload.<name>, the record the container script
#                wrote; then readback.mojo's check
#   4  program   `pixi run --as-is mojo run <w>/readme_<import>.mojo` (cwd
#                <w>) for each README; its exit in out/readme_<import>.exit,
#                its stdout in .out and its stderr in .err, each with every
#                `readme_<import>_<line>.mojo:<n>` (an example's program,
#                whose line n is README line n) rewritten to the README line
#                (an assertion reports its place on stdout, a compile error
#                on stderr); then readback.mojo's count check
#
# FAIL CLOSED: every failure is VALIDATION_FAILED with a named row, apart
# from no network (above). Under `--plan` nothing runs and the row says
# WOULD_VALIDATE.
#
# The row records `environment` ENV, `channel_url` (the step's channel
# location) and `pixi_sha256` (the bytes kci ran through bin/pixi).
#
# A LOCAL CHANNEL (`channel_override`, kci run --channel file:///<dir>):
# the same checks, with that location in place of the step's everywhere:
# check 1 reads its index and files (through file_channel.mojo's
# `FileChannelTransport`), pixi.toml names it, every record's `url` must be
# under it, and the row's `channel_url` records it. It has no host, so the
# network check asks only the compiler and extra channels. This validates a
# release BEFORE it is published, from the directory `komira_pack
# conda-index` writes; which runs may name one is kci_cli's.
#
# The seams: kci_build's `ProcessRunner` starts pixi (ScriptedRunner in the
# welded tests, which plays pixi by writing what it would leave in <w>);
# kci_pkg_upload's `PkgTransport` asks the hosts and reads the channel;
# komira_retry's `Sleeper` waits; an `IndexPollLog` says each poll of the
# index; `EnvHost` names pixi's system config directory.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir, makedirs, symlink
from std.os.path import exists, isdir, islink

from komira_retry import Sleeper
from readme_examples.program import map_report

from kci_build.runner import ProcessRunner, RunResult, RunSpec
from kci_api import (
    OUTCOME_INDETERMINATE,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_ENVIRONMENT_ENV,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
    ResultValidationCheck,
)
from kci_pkg_upload import PkgTransport
from kci_release_set.member import file_sha256_hex

from .channel_index import ChannelUrl, IndexPollLog, check_channel
from .container import MANIFEST_NAME, install_manifest_text, join_path, payload_record_name, work_subdirs
from .env import (
    AUTH_FILE,
    AUTH_FILE_TEXT,
    ENV_INSTALL_TIMEOUT_S,
    ENV_RUN_TIMEOUT_S,
    PIXI_LINK_DIR,
    PIXI_NAME,
    EnvHost,
    env_child_env,
    env_records_dir,
    install_env_argv,
    run_program_argv,
    scratch_refusal,
    system_configs,
)
from .network import CHECK_NETWORK, answered_count, declared_hosts, describe_answers, probe_hosts
from .readback import CHECK_INSTALL, check_installed, check_payloads, check_program, install_exited_zero, read_or_empty
from .readme_installed import ReadmeProgram, installed_readme
from .request import InstallPin, ValidateRequest, install_pins, load_validated_release, mojo_pin_of, with_members

comptime CHECK_HOST: String = "host"
comptime CHECK_SCRATCH: String = "scratch"
comptime CHECK_PIXI: String = "pixi"
comptime CHECK_README: String = "readme"


def _finish(var row: ResultValidation, var checks: List[ResultValidationCheck]) -> ResultValidation:
    var all_ok = len(checks) > 0
    for i in range(len(checks)):
        if not checks[i].ok:
            all_ok = False
    row.outcome = String(OUTCOME_SUCCEEDED) if all_ok else String(OUTCOME_VALIDATION_FAILED)
    row.checks = checks^
    return row^


def _row(check: String, var expected: String, var got: String, ok: Bool) -> ResultValidationCheck:
    return ResultValidationCheck(check.copy(), expected^, got^, ok)


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _fresh_dir(dir: String) -> String:
    """"" when `dir` is absent or empty; why it is not, otherwise."""
    try:
        if not exists(dir) and not islink(dir):
            return String("")
        if not isdir(dir):
            return String(dir + String(" exists and is not a directory"))
        if len(listdir(dir)) > 0:
            return String(dir + String(" exists and is not empty (a scratch directory is never reused)"))
        return String("")
    except e:
        return String(e)


def _exit_record(r: RunResult) -> String:
    """What out/<record>.exit holds: the exit status, or why there is none."""
    if r.timed_out:
        return String("timed out\n")
    if r.signaled:
        return String("signal ") + String(Int(r.exit_code)) + String("\n")
    return String(Int(r.exit_code)) + String("\n")


def _record_of(file: String) -> String:
    """`readme_<import>` for `readme_<import>.mojo`."""
    if file.endswith(String(".mojo")):
        return String(file[byte = 0 : file.byte_length() - 5])
    return file.copy()


def run_install_env[R: ProcessRunner, T: PkgTransport, S: Sleeper, L: IndexPollLog](
    mut runner: R, mut transport: T, mut sleeper: S, mut log: L, req: ValidateRequest, host: EnvHost
) raises -> ResultValidation:
    """One CONDA_INSTALL_ENV validation (file header); each poll of the
    channel's index is a line on `log`. RAISES only on a
    caller's error (another kind); everything about the release, the
    network, the channel, this machine, the install and the README is a
    check."""
    ref v = req.validation
    if v.kind != VALIDATION_KIND_CONDA_INSTALL_ENV:
        raise Error(
            String("validation '") + v.name + String("' is ") + v.kind + String(", not ")
            + String(VALIDATION_KIND_CONDA_INSTALL_ENV)
        )
    if req.plan:
        return ResultValidation(
            v.name.copy(), req.step_name.copy(), v.kind.copy(), String(VALIDATION_WOULD_VALIDATE), String("")
        )
    var row = ResultValidation(
        v.name.copy(), req.step_name.copy(), v.kind.copy(), String(VALIDATION_VALIDATED), String("")
    )
    row.environment = String(VALIDATION_ENVIRONMENT_ENV)
    var checks = List[ResultValidationCheck]()

    # 0. the release, the channel's location, the pins
    var named: List[InstallPin]
    var pins: List[InstallPin]
    var mojo_pin: String
    var channel_url: String
    try:
        var rel = load_validated_release(req)
        named = install_pins(rel.loaded, v.installs)
        pins = with_members(rel.loaded, named)
        mojo_pin = mojo_pin_of(rel.loaded)
        channel_url = rel.channel_url.copy()
        if req.channel_override.byte_length() > 0:
            # the LOCAL channel of a validation-only run (the step's channel
            # is still resolved above, so a step naming none is refused)
            var local = ChannelUrl(req.channel_override)
            if not local.is_local():
                raise Error(
                    String("--channel '") + req.channel_override
                    + String("' is not a file:/// directory: only a local channel replaces the step's")
                )
            channel_url = local.url.copy()
    except e:
        checks.append(
            _row(
                String("release"),
                String("the release of step '") + req.step_name + String("' and a pin for every install name"),
                String("release: ") + String(e),
                False,
            )
        )
        return _finish(row^, checks^)
    row.channel_url = channel_url.copy()
    var names = String("")
    for i in range(len(pins)):
        if i > 0:
            names += String(", ")
        names += pins[i].file_name()
    checks.append(
        _row(
            String("release"),
            String("a pin for every install name"),
            String("release: ") + names + String(" with mojo-compiler ") + mojo_pin,
            True,
        )
    )

    # the network: every declared host, once
    var expected_net = String("every declared host answers an anonymous GET / (any HTTP status is an answer)")
    var hosts: List[String]
    try:
        hosts = declared_hosts(channel_url, v)
    except e:
        checks.append(_row(String(CHECK_NETWORK), expected_net^, String("network: ") + String(e), False))
        return _finish(row^, checks^)
    var answers = probe_hosts(transport, hosts)
    var answered = answered_count(answers)
    var said = describe_answers(answers)
    if answered == 0:
        checks.append(
            _row(String(CHECK_NETWORK), expected_net^, String("network: no declared host answered: ") + said, False)
        )
        row.skip_reason = (
            String("no network: none of the declared hosts answered, so nothing was installed or judged (") + said
            + String(")")
        )
        row.outcome = String(OUTCOME_INDETERMINATE)
        row.checks = checks^
        return row^
    if answered < len(answers):
        checks.append(
            _row(
                String(CHECK_NETWORK), expected_net^,
                String("network: the network is up but a declared host did not answer: ") + said,
                False,
            )
        )
        return _finish(row^, checks^)
    checks.append(_row(String(CHECK_NETWORK), expected_net^, String("network: ") + said, True))

    # 1. the channel, anonymously, from this machine
    if not check_channel(transport, sleeper, log, channel_url, pins, v.wait_for_index_seconds, checks):
        return _finish(row^, checks^)

    # this machine: no pixi config kci did not write
    var configs = system_configs(host.system_config_dir)
    var expected_host = String("no system-wide pixi config under ") + host.system_config_dir
    if len(configs) > 0:
        var listed = String("")
        for i in range(len(configs)):
            if i > 0:
                listed += String(", ")
            listed += configs[i]
        checks.append(
            _row(
                String(CHECK_HOST), expected_host^,
                String("host: pixi reads a system-wide config whatever HOME says, and a local config overrides")
                + String(" its mirrors only key by key; kci will not install under ") + listed,
                False,
            )
        )
        return _finish(row^, checks^)
    checks.append(_row(String(CHECK_HOST), expected_host^, String("host: no system-wide pixi config"), True))

    # the scratch directory, the manifest, the auth file
    var dir = join_path(req.scratch_dir, v.name)
    var work = join_path(dir, String("work"))
    var bin = join_path(dir, String(PIXI_LINK_DIR))
    var why = scratch_refusal(req.scratch_dir, req.repo_root)
    if why.byte_length() == 0:
        why = _fresh_dir(dir)
    if why.byte_length() == 0:
        try:
            makedirs(work, exist_ok=True)
            makedirs(bin, exist_ok=True)
            var subs = work_subdirs()
            for i in range(len(subs)):
                makedirs(join_path(work, subs[i]), exist_ok=True)
            _write(
                join_path(work, String(MANIFEST_NAME)),
                install_manifest_text(v, channel_url, named[0].subdir, named, mojo_pin),
            )
            _write(join_path(work, String(AUTH_FILE)), String(AUTH_FILE_TEXT))
        except e:
            why = String(e)
    checks.append(
        _row(
            String(CHECK_SCRATCH),
            String("a fresh ") + dir + String(" outside the checkout, holding pixi.toml and auth.json"),
            String("scratch: ready") if why.byte_length() == 0 else String("scratch: ") + why,
            why.byte_length() == 0,
        )
    )
    if why.byte_length() > 0:
        return _finish(row^, checks^)

    # the pinned pixi, through the one link on the child's PATH
    var pixi = join_path(bin, String(PIXI_NAME))
    var expected_pixi = String("bin/pixi links --pixi, whose bytes have sha256 ") + req.pixi_sha256
    var pixi_got = String("")
    var pixi_ok = False
    try:
        if not req.pixi.startswith(String("/")):
            raise Error(String("--pixi '") + req.pixi + String("' is not an absolute path"))
        symlink(req.pixi, pixi)
        var sha = file_sha256_hex(pixi)
        row.pixi_sha256 = sha.copy()
        pixi_ok = sha == req.pixi_sha256
        if pixi_ok:
            pixi_got = String("pixi: ") + req.pixi + String(" has sha256 ") + sha + String(", the pin")
        else:
            pixi_got = String("pixi: ") + req.pixi + String(" has sha256 ") + sha + String(", not the pin ") + req.pixi_sha256
    except e:
        pixi_got = String("pixi: ") + String(e)
    checks.append(_row(String(CHECK_PIXI), expected_pixi^, pixi_got^, pixi_ok))
    if not pixi_ok:
        return _finish(row^, checks^)

    # 2. the install, in <w>, with the cleared environment
    var env = env_child_env(bin, work)
    var out_dir = join_path(work, String("out"))
    var install = RunSpec(
        pixi.copy(), install_env_argv(work), work.copy(), ENV_INSTALL_TIMEOUT_S,
        join_path(out_dir, String("install.stdout")), join_path(out_dir, String("install.log")),
    )
    install.set_env(env.copy())
    try:
        var r = runner.run(install)
        _write(join_path(out_dir, String("install.exit")), _exit_record(r))
    except e:
        checks.append(
            _row(String(CHECK_INSTALL), String("pixi install exits 0"), String("install: pixi could not be started: ") + String(e), False)
        )
        return _finish(row^, checks^)
    if not install_exited_zero(out_dir, checks):
        return _finish(row^, checks^)
    var envs = join_path(work, String(".pixi/envs"))
    var env_dir = env_records_dir(work)
    if islink(envs) or not isdir(env_dir):
        checks.append(
            _row(
                String(CHECK_INSTALL),
                String("the environment is ") + env_dir,
                String("install: the environment is not ") + env_dir
                + String(" itself (a link, or absent): kci reads back only what it installed in its scratch directory"),
                False,
            )
        )
        return _finish(row^, checks^)
    _ = check_installed(work, v, channel_url, pins, mojo_pin, checks)

    # each library's installed README, made into a program
    var programs = List[ReadmeProgram]()
    var readme_ok = True
    var libraries = 0
    for i in range(len(pins)):
        ref pin = pins[i]
        if not pin.is_library:
            continue
        libraries += 1
        var expected_readme = (
            String("the installed share/doc/") + pin.name + String("/README.md, the bytes its metadata.json records,")
            + String(" holding at least one ```mojo example")
        )
        try:
            var p = installed_readme(pin, env_dir)
            _write(join_path(work, p.file), p.text)
            for m in range(len(p.modules)):
                _write(join_path(work, p.modules[m].name), p.modules[m].text)
            checks.append(
                _row(
                    String(CHECK_README), expected_readme^,
                    String("readme: ") + p.installed + String(" (") + p.display + String(" at the revision) has the")
                    + String(" recorded sha256 and ") + String(p.examples) + String(" examples, run as ") + p.file,
                    True,
                )
            )
            programs.append(p^)
        except e:
            checks.append(_row(String(CHECK_README), expected_readme^, String("readme: ") + String(e), False))
            readme_ok = False
    if libraries == 0:
        checks.append(
            _row(
                String(CHECK_README),
                String("at least one library among the installs, whose README runs"),
                String("readme: no library among the installs (") + names
                + String("), so no README would run: a validation that runs nothing is not a pass"),
                False,
            )
        )
        readme_ok = False

    # 3. each library's installed payload, hashed here
    for i in range(len(pins)):
        ref pin = pins[i]
        if not pin.is_library:
            continue
        var path = join_path(env_dir, pin.payload_path)
        var line = String("")
        try:
            line = file_sha256_hex(path) + String("  ") + path + String("\n")
        except:
            line = String("")
        _write(join_path(out_dir, payload_record_name(pin)), line)
    _ = check_payloads(out_dir, pins, checks)
    if not readme_ok:
        return _finish(row^, checks^)

    # 4. each README program, from the installed package only
    for i in range(len(programs)):
        ref p = programs[i]
        var record = _record_of(p.file)
        var raw_out = join_path(out_dir, record + String(".stdout"))
        var raw_err = join_path(out_dir, record + String(".stderr"))
        var run = RunSpec(
            pixi.copy(), run_program_argv(work, p.file), work.copy(), ENV_RUN_TIMEOUT_S, raw_out.copy(), raw_err.copy()
        )
        run.set_env(env.copy())
        var started = True
        try:
            var r = runner.run(run)
            _write(join_path(out_dir, record + String(".exit")), _exit_record(r))
        except e:
            started = False
            _write(join_path(out_dir, record + String(".err")), String("not started: ") + String(e) + String("\n"))
        if started:
            # an assertion reports `At <w>/readme_<import>_<line>.mojo:L:C` on
            # stdout, a compile error on stderr: both name the README line
            _write(
                join_path(out_dir, record + String(".out")),
                map_report(read_or_empty(raw_out), p.package, p.display),
            )
            _write(
                join_path(out_dir, record + String(".err")),
                map_report(read_or_empty(raw_err), p.package, p.display),
            )
        if not check_program(out_dir, p.file, checks, record):
            checks[len(checks) - 1].got += (
                String(" (") + p.installed + String(" is the installed copy of ") + p.display
                + String(": the same bytes, so the same lines)")
            )
    return _finish(row^, checks^)
