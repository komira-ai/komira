# =============================================================================
# komira_job_supervisor/tests/e2e/job_supervisor_minio_e2e.mojo -- what the
# supervisor's MinIO end-to-end tests share: a process runner that really
# starts the embedded MinIO, an object-store client that really talks to it,
# the opening of the run's test bucket from the test's flags, and the
# supervisor's own S3 store on that bucket.
# =============================================================================
#
# komira_test_bucket and komira_test_minio hold the seams and the fakes; a
# real process runner and a real S3 client live outside them. These two are
# the smallest real ones the job supervisor's tests need:
#
#   * `SpawnedProcessRunner` (komira_test_minio's `ProcessRunner`) starts the
#     server with komira_supervisor's `spawn_detached`, through
#     `/bin/sh -c 'cd DIR && exec setpriv --pdeathsig KILL -- ARGV'`: the
#     shell applies the working directory and setpriv sets
#     PR_SET_PDEATHSIG before it execs the server, so the server keeps the
#     spawned pid and dies with this test. That is Linux only; on any other
#     platform, or when setpriv is missing, `start` raises (a FAIL, never a
#     skip). `wait_port` polls the server's health endpoint and the child's
#     exit; `stop` is SIGTERM, a grace, then SIGKILL, and raises unless the
#     child was reaped.
#   * `MinioObjectStore` (komira_test_bucket's `ObjectStoreClient`) is
#     komira_objectstore_s3's `S3Store` over plaintext TCP, path-style, with
#     the credential read from the shared-credentials FILE the target names
#     (profile `default`); it reads no environment. The bucket is created
#     with one signed `PUT /<bucket>` (komira_aws_s3 generates no
#     CreateBucket). Its messages name the operation and never the bucket.
#
# `open_job_supervisor_test_bucket()` reads the flags and acts on the choice: no flag
# is SKIP (exit 77), and anything but `--test-minio-binary` is CANNOT_TELL
# (exit 3), because these tests run the job supervisor against an embedded MinIO
# only. A test ends with `close()`, which deletes the run's prefix, lists it
# again to prove it empty, and stops the server; `require_clean()` turns a
# verdict that is not CLEAN into a failure.
#
# `point_job_supervisor_at()` makes the AWS default chain the supervisor's S3
# store builds find the embedded server's credential: AWS_SHARED_CREDENTIALS_FILE
# names its credentials file, AWS_CONFIG_FILE an empty file, and every
# variable that would win over the file is removed. The supervisor is the
# code under test, so its credential takes the path any other caller's takes.
# `supervisor_store()` is that store (s3_store.mojo's `make_s3_store`), and
# `SilentReporter` stands in for a heartbeat endpoint: these tests drive the
# supervisor's steps and send no heartbeat.
# =============================================================================

from std.ffi import external_call
from std.os import remove
from std.os.path import exists
from std.sys.info import CompilationTarget

from komira_aws_core import (
    AwsCredential,
    AwsEndpoint,
    AwsRetryQuota,
    Header,
    StaticCredsSource,
    SystemAwsClock,
    parse_profile_file,
    send_sigv4_signed_request,
)
from komira_aws_core.aws_send import AwsConnectorTransport
from komira_aws_core.credential_transport import CredentialHttpRequest
from komira_core_ffi.posix import _read_env
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_objectstore.types import WritePrecondition
from komira_objectstore_s3.config import S3Config
from komira_objectstore_s3.store import S3Store
from komira_supervisor.supervisor import DetachedChild, spawn_detached
from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisor,
    SupervisorS3Store,
    SupervisorHeartbeat,
    make_s3_store,
)
from komira_test_bucket import (
    BACKEND_CHOICE_EMBEDDED_MINIO,
    FLAG_MINIO_BINARY,
    ObjectStoreClient,
    StoreTarget,
    TestBucket,
    TestStoreFlags,
    open_test_bucket_from_flags,
    select_backend,
)
from komira_test_minio import (
    ProcessRunner,
    ProcessSpec,
    Readiness,
)
from komira_test_run_id import SystemClock, UrandomEntropy, mint_run_id
from komira_test_verdict import exit_cannot_tell


comptime SETPRIV: String = "/usr/bin/setpriv"
comptime _P: String = "job supervisor e2e: "


def sleep_ms(ms: Int):
    """usleep: this binary links komira_async, whose reactor declares its own
    nanosleep, so std's time.sleep would not legalize."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def text_of(bytes: List[UInt8]) -> String:
    """The bytes as a String, byte for byte (no decoding)."""
    return String(unsafe_from_utf8=Span(bytes))


# =============================================================================
# §1 -- the process runner.
# =============================================================================
struct SpawnedProcessRunner(ProcessRunner):
    """Starts real children (module header). A handle is 1 + the index of
    its child in `children`."""

    var children: List[DetachedChild]

    def __init__(out self):
        self.children = List[DetachedChild]()

    def _child(self, h: Int) raises -> DetachedChild:
        if h < 1 or h > len(self.children):
            raise Error(_P + "no child with handle " + String(h))
        return self.children[h - 1]

    def start(mut self, spec: ProcessSpec) raises -> Int:
        comptime if not CompilationTarget.is_linux():
            raise Error(
                _P + "die_with_parent needs PR_SET_PDEATHSIG; this runner is Linux only"
            )
        if len(spec.argv) == 0:
            raise Error(_P + "an empty argv")
        if spec.die_with_parent and not exists(SETPRIV):
            raise Error(_P + "die_with_parent needs " + SETPRIV + ", which is missing")
        var argv = List[String]()
        argv.append("-c")
        var script = String('exec "$@"')
        if spec.die_with_parent:
            script = String('exec ') + SETPRIV + ' --pdeathsig KILL -- "$@"'
        if spec.cwd.byte_length() > 0:
            script = String('cd "$0" && ') + script
            argv.append(script)
            argv.append(spec.cwd)
        else:
            argv.append(script)
            argv.append("sh")
        for i in range(len(spec.argv)):
            argv.append(spec.argv[i])
        # The child's whole environment, as the trait requires. An empty list
        # would make spawn_detached inherit ours, so there is always one entry.
        var env = List[String]()
        for i in range(len(spec.child_env)):
            env.append(spec.child_env[i].name + "=" + spec.child_env[i].value)
        if len(env) == 0:
            env.append("KOMIRA_EMPTY_ENV=1")
        var pid = spawn_detached(String("/bin/sh"), argv, env)
        if pid <= Int32(0):
            raise Error(_P + "spawn failed (errno " + String(-Int(pid)) + ")")
        self.children.append(DetachedChild(pid))
        return len(self.children)

    def wait_port(mut self, h: Int, host: String, port: Int, timeout_s: Int) -> Readiness:
        var child: DetachedChild
        try:
            child = self._child(h)
        except:
            return Readiness.exited(-1)
        var waited_ms = 0
        while waited_ms <= timeout_s * 1000:
            var st = child.poll_exit()
            if not st.running:
                return Readiness.exited(Int(st.exit_code) if st.exited else -1)
            if _answers_health(host, port):
                return Readiness.ready()
            sleep_ms(100)
            waited_ms += 100
        return Readiness.timeout()

    def stop(mut self, h: Int, grace_s: Int) raises -> Int:
        var child = self._child(h)
        var st = child.poll_exit()
        if not st.running:
            return _status_of(st.exited, Int(st.exit_code), Int(st.signal), st.error)
        _ = child.term()
        var waited_ms = 0
        while waited_ms < grace_s * 1000:
            sleep_ms(50)
            waited_ms += 50
            st = child.poll_exit()
            if not st.running:
                return _status_of(st.exited, Int(st.exit_code), Int(st.signal), st.error)
        _ = child.kill()
        for _i in range(100):
            sleep_ms(50)
            st = child.poll_exit()
            if not st.running:
                return _status_of(st.exited, Int(st.exit_code), Int(st.signal), st.error)
        raise Error(_P + "the child survived SIGKILL for 5 s; it is not confirmed gone")


def _status_of(exited: Bool, code: Int, signal: Int, error: Bool) raises -> Int:
    if error:
        raise Error(_P + "waitpid failed; the child's end is not confirmed")
    if exited:
        return code
    return 128 + signal


def _answers_health(host: String, port: Int) -> Bool:
    """True when `GET /minio/health/live` answers 200."""
    try:
        var req = CredentialHttpRequest(
            String("GET"), String("http"), host, port, String("/minio/health/live")
        )
        req.headers.append(Header(String("Host"), host + ":" + String(port)))
        var t = AwsConnectorTransport[KernelTcpConnector](KernelTcpConnector.new())
        var res = t.send(req)
        return res.status == 200
    except:
        return False


# =============================================================================
# §2 -- the object store.
# =============================================================================
comptime MinioS3 = S3Store[KernelTcpConnector, StaticCredsSource, SystemAwsClock]


def _mk_plain() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def read_credential_file(path: String) raises -> AwsCredential:
    """The `default` profile's key pair from an AWS shared-credentials file.
    Messages name neither the path nor a value."""
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        raise Error(_P + "cannot read the credentials file")
    var profiles = parse_profile_file(text, False, String("the credentials file"))
    var p = profiles.profile(String("default"))
    var id = p.get(String("aws_access_key_id"))
    var secret = p.get(String("aws_secret_access_key"))
    if id.byte_length() == 0 or secret.byte_length() == 0:
        raise Error(_P + "the credentials file's default profile has no key pair")
    return AwsCredential(id, secret, p.get(String("aws_session_token")))


struct MinioObjectStore(ObjectStoreClient):
    """komira_test_bucket's object-store seam over S3Store (module header).
    Unbound until `bind`."""

    var _store: Optional[MinioS3]
    var _target: Optional[StoreTarget]

    def __init__(out self):
        self._store = None
        self._target = None

    def _fail(self, op: String, e: Error) -> Error:
        var msg = String(e)
        if self._target:
            msg = msg.replace(self._target.value().bucket, "<bucket>")
            msg = msg.replace(self._target.value().endpoint, "<endpoint>")
        return Error(_P + op + ": " + msg)

    def _bucket(self) raises -> String:
        if not self._target:
            raise Error(_P + "the store is not bound")
        return self._target.value().bucket

    def bind(mut self, target: StoreTarget) raises:
        if self._store:
            raise Error(_P + "bind called twice")
        var cred = read_credential_file(target.credentials_file)
        self._store = MinioS3(
            S3Config.custom_endpoint(target.region, target.endpoint),
            _mk_plain,
            HttpClientConfig.defaults(),
            StaticCredsSource(cred),
            SystemAwsClock(),
        )
        self._target = target.copy()

    def create_bucket_if_absent(mut self) raises:
        var bucket = self._bucket()
        ref t = self._target.value()
        var cred = read_credential_file(t.credentials_file)
        var quota = AwsRetryQuota()
        var res = send_sigv4_signed_request[KernelTcpConnector](
            _mk_plain,
            HttpClientConfig.defaults(),
            quota,
            String("PUT"),
            cred,
            t.region,
            String("s3"),
            AwsEndpoint.parse(t.endpoint, String("the embedded MinIO")),
            String("/") + bucket,
            String(""),
            List[UInt8](),
            List[Header](),
        )
        if res.status == 200:
            return
        # Created by an earlier call of this run: BucketAlreadyOwnedByYou.
        if res.status == 409 and text_of(res.body).find("BucketAlreadyOwnedByYou") >= 0:
            return
        raise Error(_P + "CreateBucket answered status " + String(res.status))

    def put(mut self, key: String, body: Span[UInt8, _]) raises:
        var bucket = self._bucket()
        var bytes = List[UInt8]()
        bytes.extend(body)
        try:
            _ = self._store.value().conditional_put(bucket, key, bytes, WritePrecondition.none())
        except e:
            raise self._fail("PutObject", e)

    def get(mut self, key: String) raises -> List[UInt8]:
        """GetObject: the whole object (for a test reading back what the
        job supervisor wrote)."""
        var bucket = self._bucket()
        try:
            return self._store.value().get(bucket, key)
        except e:
            raise self._fail("GetObject", e)

    def list_keys(mut self, prefix: String, mut out: List[String]) raises:
        var bucket = self._bucket()
        try:
            var listed = self._store.value().list(bucket, prefix, String(""))
            for i in range(len(listed.objects)):
                out.append(listed.objects[i].location)
        except e:
            raise self._fail("ListObjectsV2", e)

    def delete_keys(mut self, keys: List[String], mut failed: List[String]) raises:
        var bucket = self._bucket()
        for i in range(len(keys)):
            try:
                self._store.value().delete(bucket, keys[i])
            except:
                failed.append(keys[i])


# =============================================================================
# §3 -- opening the run's bucket, and pointing the job supervisor at it.
# =============================================================================
comptime JobSupervisorTestBucket = TestBucket[MinioObjectStore, SpawnedProcessRunner]


def scratch_root() -> String:
    """TEST_TMPDIR under a test runner, else TMPDIR, else /tmp."""
    var t = _read_env("TEST_TMPDIR")
    if t.byte_length() == 0:
        t = _read_env("TMPDIR")
    if t.byte_length() == 0:
        t = String("/tmp")
    return t^


def open_job_supervisor_test_bucket(target_label: String) raises -> JobSupervisorTestBucket:
    """The run's bucket on the embedded MinIO the flags name; SKIP (77) with
    no flags, CANNOT_TELL (3) for any other store (module header)."""
    var flags = TestStoreFlags.from_process_args()
    if flags.target.byte_length() == 0:
        flags.target = target_label
    var choice = select_backend(flags)
    choice.exit_unless_runnable()
    if choice.kind != BACKEND_CHOICE_EMBEDDED_MINIO:
        exit_cannot_tell(
            String("the job supervisor's MinIO end-to-end tests run on an embedded MinIO only; give ")
            + FLAG_MINIO_BINARY
            + " and no --test-s3-* flag"
        )
    var clock = SystemClock()
    var entropy = UrandomEntropy()
    var run_id = mint_run_id(clock, entropy)
    return open_test_bucket_from_flags(
        choice,
        run_id,
        scratch_root(),
        MinioObjectStore(),
        SpawnedProcessRunner(),
        entropy,
        clock,
    )


def _setenv(name: String, value: String):
    """libc setenv (the test's own process)."""
    var n = name
    var v = value
    _ = external_call["setenv", Int32](
        n.as_c_string_slice().unsafe_ptr(), v.as_c_string_slice().unsafe_ptr(), Int32(1)
    )


def _unsetenv(name: String):
    var n = name
    _ = external_call["unsetenv", Int32](n.as_c_string_slice().unsafe_ptr())


def point_job_supervisor_at(bucket: JobSupervisorTestBucket):
    """Make the AWS default chain the supervisor's store builds find the
    embedded server's credential, and nothing else (module header)."""
    var gone: List[String] = [
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_PROFILE",
        "AWS_DEFAULT_PROFILE",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "AWS_ROLE_ARN",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    ]
    for i in range(len(gone)):
        _unsetenv(gone[i])
    _setenv("AWS_SHARED_CREDENTIALS_FILE", bucket.credentials_file())
    _setenv("AWS_CONFIG_FILE", "/dev/null")
    _setenv("AWS_EC2_METADATA_DISABLED", "true")


def remove_if_present(path: String):
    if exists(path):
        try:
            remove(path)
        except:
            pass


# =============================================================================
# §4 -- the supervisor's side: its S3 store on the run's bucket, and a
# reporter that sends nothing.
# =============================================================================
struct SilentReporter(HeartbeatReporter):
    """Counts heartbeats and delivers none."""

    var beats: Int

    def __init__(out self):
        self.beats = 0

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.beats += 1
        return HeartbeatOutcome(True, False, 200)


comptime E2eStore = SupervisorS3Store[KernelTcpConnector]
comptime E2eSupervisor = JobSupervisor[SilentReporter, E2eStore]


def supervisor_store(bucket: JobSupervisorTestBucket) raises -> E2eStore:
    """The supervisor's own S3 store on the run's bucket, as
    `run_job_supervisor_on_s3` builds it."""
    return make_s3_store[KernelTcpConnector](
        _mk_plain, bucket.bucket(), bucket.region(), Optional[String](bucket.endpoint())
    )
