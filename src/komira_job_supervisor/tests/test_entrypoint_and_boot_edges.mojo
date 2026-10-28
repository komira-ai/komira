# =============================================================================
# komira_job_supervisor/tests/test_entrypoint_and_boot_edges.mojo
#   The refusals at the start that the other tests leave out: the entrypoint's
#   log store with no storage credential, an empty --job-binary, the numeric
#   flags at their bounds, an empty --binary-key, an upper-case digest, the
#   fetch with nothing to fetch, a key with no digest in it, a chmod that
#   fails; and the crash report's stamp for years with fewer than four digits.
# =============================================================================
#
#   test_no_storage_credential_refuses_the_start_after_the_credential_is_taken
#       start_and_run with GOOGLE_APPLICATION_CREDENTIALS naming a missing
#       file: refused with the credential search's own words, the job (a
#       `touch` of a marker) never ran, and the heartbeat credential variable
#       is already gone from the environment (the module header's order: the
#       credential, then the reporter, then the log store).
#   test_with_a_storage_credential_the_start_reaches_the_run
#       With a usable storage credential (an authorized_user file; then the
#       metadata server at a closed loopback port) and a job whose interpreter
#       does not exist, start_and_run builds the log store and reaches the
#       run, which raises at the spawn. Nothing is fetched, no token is asked
#       for, and no object is written: the run ends before the job starts.
#   test_an_empty_job_binary_is_refused
#   test_a_positive_integer_flag_has_one_to_eighteen_digits
#       Empty and 19 digits are refused naming the flag; 18 digits parse.
#   test_an_empty_binary_key_and_an_upper_case_digest_are_refused
#   test_the_fetch_refusals_and_a_key_with_no_digest
#       No --binary-key: the fetch refuses. A key with no 64-hex segment has
#       no expected digest. A chmod of a path that does not exist raises
#       naming it.
#   test_the_stamp_pads_every_year_to_four_digits
#       Years 12, 99, 123, 999 and 1000 (the pad's three bounds and the first
#       year it does not pad).
# =============================================================================

from std.os import setenv
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_objectstore import InMemoryConditionalStore
from komira_secret_env import ProcessEnv

from komira_job_supervisor import (
    JobSupervisorConfig,
    download_binary,
    expected_sha_from_key,
    resolve_job_binary,
    start_and_run,
)
from komira_job_supervisor.boot import _chmod
from komira_job_supervisor.clock_helper import utc_stamp_from_unix_ms


def _args(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _tmp(name: String) raises -> String:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    return tmp + "/" + name


def test_no_storage_credential_refuses_the_start_after_the_credential_is_taken() raises:
    var var_name = String("KOMIRA_JOB_SUPERVISOR_EDGE_START_TOKEN")
    _ = setenv(var_name, String("tok-start-0123456789"), True)
    _ = setenv(
        String("GOOGLE_APPLICATION_CREDENTIALS"), _tmp(String("no-such-adc.json")), True
    )
    var marker = _tmp(String("the-job-ran"))
    var args = _args(
        "--job-name=adc-refusal",
        "--heartbeat-url=https://beats.example.com/v1/beat",
        "--heartbeat-credential-env=KOMIRA_JOB_SUPERVISOR_EDGE_START_TOKEN",
        "--max-runtime-secs=60",
        "--log-prefix=gs://job-logs/runs/adc-refusal",
        "--job-binary=/bin/sh",
        "--",
        "-c",
    )
    args.append(String("touch ") + marker)
    var r = String("")
    try:
        _ = start_and_run(args)
    except e:
        r = String(e)
    assert_true(
        r.find(String("GOOGLE_APPLICATION_CREDENTIALS names the file")) >= 0, r
    )
    assert_false(r.find(String("tok-start")) >= 0, "never quotes the token")
    assert_false(exists(marker), "the job never ran")
    var env = ProcessEnv()
    assert_false(
        env.lookup(var_name).__bool__(),
        "the heartbeat credential was taken before the log store was built",
    )
    print(
        "  test_no_storage_credential_refuses_the_start_after_the_credential_is_taken:"
        " PASS"
    )


def _run_refusal(var name: String, job: String, token_file: String) -> String:
    var args = _args(
        "--heartbeat-url=https://127.0.0.1:1/v1/beat",
        "--max-runtime-secs=60",
        "--log-prefix=gs://job-logs/runs/reaches-run",
    )
    args.append(String("--job-name=") + name)
    args.append(String("--heartbeat-credential-file=") + token_file)
    args.append(String("--job-binary=") + job)
    try:
        _ = start_and_run(args)
    except e:
        return String(e)
    return String("<ran>")


def test_with_a_storage_credential_the_start_reaches_the_run() raises:
    var job = _tmp(String("job-with-no-interpreter"))
    with open(job, "w") as f:
        f.write(String("#!/nonexistent.invalid/interpreter\n"))
    _chmod(job, Int32(0o755))
    var token = _tmp(String("reaches-run-token"))
    with open(token, "w") as f:
        f.write(String("tok-reaches-run-0123456789\n"))

    var adc = _tmp(String("authorized-user.json"))
    with open(adc, "w") as f:
        f.write(
            String(
                '{"type":"authorized_user","client_id":"cid",'
                '"client_secret":"s","refresh_token":"r"}'
            )
        )
    _ = setenv(String("GOOGLE_APPLICATION_CREDENTIALS"), adc, True)
    var r = _run_refusal(String("user-cred"), job, token)
    assert_true(r.find(String("spawn failed for job user-cred")) >= 0, r)

    # The metadata server: no credentials file, no gcloud directory, and
    # GCE_METADATA_HOST at a closed loopback port (never dialled here).
    _ = setenv(String("GOOGLE_APPLICATION_CREDENTIALS"), String(""), True)
    _ = setenv(String("CLOUDSDK_CONFIG"), _tmp(String("no-gcloud-config")), True)
    _ = setenv(String("GCE_METADATA_HOST"), String("127.0.0.1:1"), True)
    r = _run_refusal(String("metadata-cred"), job, token)
    assert_true(r.find(String("spawn failed for job metadata-cred")) >= 0, r)
    print("  test_with_a_storage_credential_the_start_reaches_the_run: PASS")


def test_an_empty_job_binary_is_refused() raises:
    var r = String("")
    try:
        _ = resolve_job_binary(String(""), String("/bin:/usr/bin"))
    except e:
        r = String(e)
    assert_true(r.find(String("--job-binary is empty")) >= 0, r)
    print("  test_an_empty_job_binary_is_refused: PASS")


def _base() -> List[String]:
    return _args(
        "--job-name=edge",
        "--job-binary=/bin/true",
        "--heartbeat-url=https://hb.example.com/beat",
    )


def _with(flag: String) -> List[String]:
    var a = _base()
    a.append(flag)
    return a^


def _refusal(var args: List[String]) -> String:
    try:
        _ = JobSupervisorConfig.from_args(args)
    except e:
        return String(e)
    return String("")


def test_a_positive_integer_flag_has_one_to_eighteen_digits() raises:
    var empty = _refusal(_with(String("--max-runtime-secs=")))
    assert_true(
        empty.find(String("--max-runtime-secs is not a positive integer")) >= 0, empty
    )
    var nineteen = _refusal(_with(String("--max-runtime-secs=1000000000000000000")))
    assert_true(
        nineteen.find(String("--max-runtime-secs is not a positive integer")) >= 0,
        nineteen,
    )
    var c = JobSupervisorConfig.from_args(
        _with(String("--max-runtime-secs=999999999999999999"))
    )
    assert_equal(c.max_runtime_secs, 999999999999999999, "eighteen digits parse")
    print("  test_a_positive_integer_flag_has_one_to_eighteen_digits: PASS")


def test_an_empty_binary_key_and_an_upper_case_digest_are_refused() raises:
    var key = _refusal(_with(String("--binary-key=")))
    assert_true(key.find(String("--binary-key is empty")) >= 0, key)
    var hex63 = String("")
    for _ in range(63):
        hex63 += "0"
    var upper = _refusal(_with(String("--binary-sha256=A") + hex63))
    assert_true(
        upper.find(String("--binary-sha256 is not 64 lowercase hex characters")) >= 0,
        upper,
    )
    # CONTROL: the same digest in lower case parses.
    var c = JobSupervisorConfig.from_args(_with(String("--binary-sha256=a") + hex63))
    assert_equal(c.binary_sha256.value(), String("a") + hex63)
    print("  test_an_empty_binary_key_and_an_upper_case_digest_are_refused: PASS")


def test_the_fetch_refusals_and_a_key_with_no_digest() raises:
    var cfg = JobSupervisorConfig(
        String("no-key"),
        String("i"),
        String("/bin/true"),
        List[String](),
        String("http://127.0.0.1:1/beat"),
    )
    var r = String("")
    try:
        _ = download_binary[InMemoryConditionalStore](cfg, InMemoryConditionalStore())
    except e:
        r = String(e)
    assert_true(r.find(String("no --binary-key to download")) >= 0, r)

    assert_false(
        expected_sha_from_key(String("bin/latest/job")).__bool__(),
        "no 64-hex segment: no expected digest",
    )
    var hex64 = String("")
    for _ in range(16):
        hex64 += "0a1f"
    assert_equal(
        expected_sha_from_key(String("bin/") + hex64 + "/job").value(), hex64
    )

    r = String("")
    try:
        _chmod(String("/nonexistent.invalid/job"), Int32(0o755))
    except e:
        r = String(e)
    assert_true(r.find(String("chmod(/nonexistent.invalid/job) failed")) >= 0, r)
    print("  test_the_fetch_refusals_and_a_key_with_no_digest: PASS")


def test_the_stamp_pads_every_year_to_four_digits() raises:
    # Milliseconds since the epoch of each instant (proleptic Gregorian, UTC).
    assert_equal(utc_stamp_from_unix_ms(Int64(-61783066433000)), "00120304T050607Z")
    assert_equal(utc_stamp_from_unix_ms(Int64(-59037980277000)), "00990228T010203Z")
    assert_equal(utc_stamp_from_unix_ms(Int64(-58256841601000)), "01231130T235959Z")
    assert_equal(utc_stamp_from_unix_ms(Int64(-30610224001000)), "09991231T235959Z")
    assert_equal(utc_stamp_from_unix_ms(Int64(-30610224000000)), "10000101T000000Z")
    print("  test_the_stamp_pads_every_year_to_four_digits: PASS")


def main() raises:
    print("test_entrypoint_and_boot_edges:")
    test_no_storage_credential_refuses_the_start_after_the_credential_is_taken()
    test_with_a_storage_credential_the_start_reaches_the_run()
    test_an_empty_job_binary_is_refused()
    test_a_positive_integer_flag_has_one_to_eighteen_digits()
    test_an_empty_binary_key_and_an_upper_case_digest_are_refused()
    test_the_fetch_refusals_and_a_key_with_no_digest()
    test_the_stamp_pads_every_year_to_four_digits()
    print("test_entrypoint_and_boot_edges: ALL PASS")
