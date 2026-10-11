# =============================================================================
# komira_job_supervisor/tests/test_entrypoint_flags.mojo
#   The entrypoint takes exactly its flags, refuses each bad one naming it
#   before anything runs, hands everything after `--` to the job verbatim,
#   and resolves a bare --job-binary on PATH.
# =============================================================================
#
# `EntrypointConfig.from_args` is the binary's whole flag surface. A full
# flag set parses, with the log prefix split into bucket and key prefix. Then
# each refusal, each beside an accepted form: no credential (a supervisor
# that fell back to beating without one would be refused by its endpoint
# forever), both credentials, an empty credential flag, no or a zero maximum
# runtime, no log prefix, a log prefix that is not gs://, a gs:// with no
# bucket or no object prefix, a flag the entrypoint does not take (the
# library's --job-arg and --binary-key included), a flag given twice, the
# library's own required flags.
#
# `--`: every word after it is the job's, one that begins with `--` included
# (a parser that read on past `--` would take the job's `--job-name=...` as
# its own or refuse the job's `--verbose`).
#
# --job-binary: a bare name is found on PATH, an empty PATH entry is skipped,
# a name on no PATH entry and a path that is not executable are refused, and
# a path with a `/` is used as given.
#
# start_and_run refuses before spawning anything: an http heartbeat URL with
# a credential (it would ride in the clear), an unset credential variable.
#
# The exit status: COMPLETED is 0, FAILED and CANCELLED are each 1, a refused
# start is 2 (a mapping that sent FAILED to 0 would report a failed job as a
# success).
# =============================================================================

from std.os import makedirs
from std.pathlib import Path as FsPath
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from komira_job_supervisor import (
    EntrypointConfig,
    entrypoint_flag_names,
    exit_status_of,
    parse_log_location,
    resolve_job_binary,
    run_entrypoint,
    start_and_run,
)
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase


def _args(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _contract(var extra: List[String]) -> List[String]:
    """The full flag set a launcher renders, plus `extra`."""
    var out = _args(
        "--job-name=run-7f3a",
        "--instance-name=attempt-2b9c",
        "--heartbeat-url=https://beats.example.com/v1/beat",
        "--heartbeat-credential-file=/var/run/creds/token",
        "--heartbeat-interval-secs=15",
        "--max-runtime-secs=3600",
        "--log-prefix=gs://job-logs/runs/run-7f3a",
        "--job-binary=/opt/job/run",
    )
    for i in range(len(extra)):
        out.append(extra[i])
    return out^


def _without(var args: List[String], prefix: String) -> List[String]:
    var out = List[String]()
    for i in range(len(args)):
        if not args[i].startswith(prefix):
            out.append(args[i])
    return out^


def _refusal(var args: List[String]) -> String:
    try:
        _ = EntrypointConfig.from_args(args)
    except e:
        return String(e)
    return String("")


def _tmp(name: String) raises -> String:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    return tmp + "/" + name


def test_the_full_flag_set_parses() raises:
    # Names first, so a renamed flag fails here rather than in the parse below.
    var names = entrypoint_flag_names()
    var want = _args(
        "--job-name",
        "--instance-name",
        "--heartbeat-url",
        "--heartbeat-credential-file",
        "--heartbeat-credential-env",
        "--heartbeat-interval-secs",
        "--max-runtime-secs",
        "--log-prefix",
        "--job-binary",
    )
    assert_equal(len(names), len(want), "exactly the nine flags")
    for i in range(len(want)):
        assert_equal(names[i], want[i], "the contract's flag names, in order")
    var c = EntrypointConfig.from_args(_contract(List[String]()))
    assert_equal(c.job.job_name, String("run-7f3a"))
    assert_equal(c.job.instance_name, String("attempt-2b9c"))
    assert_equal(c.job.heartbeat_interval_secs, 15)
    assert_equal(c.job.max_runtime_secs, 3600)
    assert_equal(c.job.job_binary_path, String("/opt/job/run"))
    assert_equal(c.credential_file.value(), String("/var/run/creds/token"))
    assert_false(c.credential_env.__bool__(), "one credential")
    assert_equal(c.log.bucket, String("job-logs"))
    assert_equal(c.log.key_prefix, String("runs/run-7f3a"))
    assert_equal(
        c.job.log_prefix, String("runs/run-7f3a"), "the logs go under the key prefix"
    )
    assert_equal(len(c.job.job_argv), 0)

    var e = EntrypointConfig.from_args(
        _without(
            _contract(_args("--heartbeat-credential-env=JOB_CREDENTIAL")),
            String("--heartbeat-credential-file="),
        )
    )
    assert_equal(e.credential_env.value(), String("JOB_CREDENTIAL"))
    assert_false(e.credential_file.__bool__())
    print("  test_the_full_flag_set_parses: PASS")


def test_a_missing_credential_refuses_the_start() raises:
    var r = _refusal(
        _without(_contract(List[String]()), String("--heartbeat-credential-file="))
    )
    assert_true(
        r.find(String("needs a credential")) >= 0
        and r.find(String("--heartbeat-credential-file")) >= 0
        and r.find(String("--heartbeat-credential-env")) >= 0,
        "no credential: refused naming both flags: " + r,
    )
    r = _refusal(_contract(_args("--heartbeat-credential-env=JOB_CREDENTIAL")))
    assert_true(r.find(String("not both")) >= 0, "both: " + r)
    r = _refusal(
        _without(
            _contract(_args("--heartbeat-credential-env=")),
            String("--heartbeat-credential-file="),
        )
    )
    assert_true(r.find(String("--heartbeat-credential-env is empty")) >= 0, r)
    r = _refusal(
        _without(
            _contract(_args("--heartbeat-credential-file=")),
            String("--heartbeat-credential-file=/"),
        )
    )
    assert_true(r.find(String("--heartbeat-credential-file is empty")) >= 0, r)
    print("  test_a_missing_credential_refuses_the_start: PASS")


def test_each_other_bad_flag_is_refused_naming_it() raises:
    var r = _refusal(
        _without(_contract(List[String]()), String("--max-runtime-secs="))
    )
    assert_true(r.find(String("missing required flag --max-runtime-secs")) >= 0, r)
    r = _refusal(
        _without(_contract(_args("--max-runtime-secs=0")), String("--max-runtime-secs=3"))
    )
    assert_true(r.find(String("--max-runtime-secs must be at least 1")) >= 0, r)
    r = _refusal(_without(_contract(List[String]()), String("--log-prefix=")))
    assert_true(r.find(String("missing required flag --log-prefix")) >= 0, r)
    r = _refusal(
        _without(_contract(_args("--log-prefix=s3://job-logs/runs/x")), String("--log-prefix=gs"))
    )
    assert_true(r.find(String("must be gs://BUCKET/PREFIX")) >= 0, "s3://: " + r)
    r = _refusal(
        _without(_contract(_args("--log-prefix=runs/x")), String("--log-prefix=gs"))
    )
    assert_true(r.find(String("must be gs://BUCKET/PREFIX")) >= 0, "no scheme: " + r)
    r = _refusal(_contract(_args("--job-arg=x")))
    assert_true(r.find(String("unknown flag --job-arg")) >= 0, r)
    r = _refusal(_contract(_args("--binary-key=bin/x")))
    assert_true(r.find(String("unknown flag --binary-key")) >= 0, r)
    r = _refusal(_contract(_args("--job-name=again")))
    assert_true(r.find(String("--job-name given more than once")) >= 0, r)
    r = _refusal(_without(_contract(List[String]()), String("--job-binary=")))
    assert_true(r.find(String("missing required flag --job-binary")) >= 0, r)
    r = _refusal(_without(_contract(List[String]()), String("--heartbeat-url=")))
    assert_true(r.find(String("missing required flag --heartbeat-url")) >= 0, r)
    r = _refusal(_contract(_args("stray")))
    assert_true(r.find(String("unexpected argument")) >= 0, r)
    print("  test_each_other_bad_flag_is_refused_naming_it: PASS")


def test_the_gs_log_location() raises:
    var l = parse_log_location(String("gs://b-1/a/b/c/"))
    assert_equal(l.bucket, String("b-1"))
    assert_equal(l.key_prefix, String("a/b/c"), "one trailing / dropped")
    var refused = 0
    var bads = _args("gs://", "gs://bucket", "gs://bucket/", "gs:///x")
    for i in range(len(bads)):
        try:
            _ = parse_log_location(bads[i])
        except:
            refused += 1
    assert_equal(refused, 4, "no bucket or no object prefix: refused")
    print("  test_the_gs_log_location: PASS")


def test_everything_after_the_separator_is_the_jobs() raises:
    var c = EntrypointConfig.from_args(
        _contract(
            _args("--", "--job-name=not-the-supervisors", "--verbose", "plain", "--")
        )
    )
    assert_equal(c.job.job_name, String("run-7f3a"), "the supervisor's own name")
    assert_equal(len(c.job.job_argv), 4, "every word after -- is the job's")
    assert_equal(c.job.job_argv[0], String("--job-name=not-the-supervisors"))
    assert_equal(c.job.job_argv[1], String("--verbose"))
    assert_equal(c.job.job_argv[2], String("plain"))
    assert_equal(c.job.job_argv[3], String("--"), "a second -- is an argument")
    print("  test_everything_after_the_separator_is_the_jobs: PASS")


def test_a_bare_job_binary_is_found_on_path() raises:
    var empty_dir = _tmp(String("path-empty"))
    makedirs(empty_dir, exist_ok=True)
    # A directory named like the tool, and a non-executable file named like
    # it, both earlier on PATH: skipped.
    var shadow = _tmp(String("path-shadow"))
    makedirs(shadow + String("/sh"), exist_ok=True)
    var plain = _tmp(String("path-plain"))
    makedirs(plain, exist_ok=True)
    FsPath(plain + String("/sh")).write_text(String("#!/bin/sh\n"))
    var search = (
        String(":")
        + empty_dir
        + String("::")
        + shadow
        + String(":")
        + plain
        + String(":/bin:/usr/bin")
    )
    var found = resolve_job_binary(String("sh"), search)
    assert_true(
        found == String("/bin/sh") or found == String("/usr/bin/sh"),
        "a bare name resolves to the first executable on PATH: " + found,
    )
    var not_found = String("")
    try:
        _ = resolve_job_binary(String("komira-no-such-binary"), search)
    except e:
        not_found = String(e)
    assert_true(
        not_found.find(String("--job-binary komira-no-such-binary was not found")) >= 0,
        not_found,
    )
    var empty_path = String("")
    try:
        _ = resolve_job_binary(String("sh"), String(""))
    except e:
        empty_path = String(e)
    assert_true(empty_path.find(String("not found")) >= 0, "an empty PATH finds nothing")

    # A path with a `/` is used as given, and must be executable.
    assert_equal(resolve_job_binary(String("/bin/sh"), search), String("/bin/sh"))
    var not_exec = String("")
    try:
        _ = resolve_job_binary(plain + String("/sh"), search)
    except e:
        not_exec = String(e)
    assert_true(not_exec.find(String("is not an executable file")) >= 0, not_exec)
    print("  test_a_bare_job_binary_is_found_on_path: PASS")


def test_the_start_is_refused_before_anything_runs() raises:
    var token = _tmp(String("start-token"))
    FsPath(token).write_text(String("tok-start"))
    var http_args = _without(
        _without(
            _contract(List[String]()), String("--heartbeat-credential-file=")
        ),
        String("--heartbeat-url="),
    )
    http_args.append(String("--heartbeat-credential-file=") + token)
    http_args.append(String("--heartbeat-url=http://beats.example.com/v1/beat"))
    http_args = _without(http_args^, String("--job-binary="))
    http_args.append(String("--job-binary=/bin/sh"))
    var r = String("")
    try:
        _ = start_and_run(http_args)
    except e:
        r = String(e)
    assert_true(r.find(String("REFUSED heartbeat auth")) >= 0, "http: " + r)
    assert_false(r.find(String("tok-start")) >= 0, "never quotes the token")

    var env_args = _without(
        _without(_contract(List[String]()), String("--heartbeat-credential-file=")),
        String("--job-binary="),
    )
    env_args.append(String("--heartbeat-credential-env=KOMIRA_JOB_SUPERVISOR_TEST_NEVER_SET"))
    env_args.append(String("--job-binary=/bin/sh"))
    r = String("")
    try:
        _ = start_and_run(env_args)
    except e:
        r = String(e)
    assert_true(r.find(String("is not set")) >= 0, "unset variable: " + r)

    # The binary maps a refusal to exit status 2.
    assert_equal(run_entrypoint(_args("--job-name=x")), 2, "refused: exit 2")
    print("  test_the_start_is_refused_before_anything_runs: PASS")


def test_the_exit_status_of_each_end() raises:
    # A failed or cancelled job must not look like a success to whatever
    # started the container: FAILED and CANCELLED are 1, COMPLETED is 0.
    assert_equal(exit_status_of(JobSupervisorPhase.failed()), 1, "FAILED: exit 1")
    assert_equal(
        exit_status_of(JobSupervisorPhase.cancelled()), 1, "CANCELLED: exit 1"
    )
    assert_equal(
        exit_status_of(JobSupervisorPhase.completed()), 0, "COMPLETED: exit 0"
    )
    print("  test_the_exit_status_of_each_end: PASS")


def main() raises:
    test_the_full_flag_set_parses()
    test_a_missing_credential_refuses_the_start()
    test_each_other_bad_flag_is_refused_naming_it()
    test_the_gs_log_location()
    test_everything_after_the_separator_is_the_jobs()
    test_a_bare_job_binary_is_found_on_path()
    test_the_start_is_refused_before_anything_runs()
    test_the_exit_status_of_each_end()
    print("PASS test_entrypoint_flags")
