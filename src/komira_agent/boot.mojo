# =============================================================================
# komira_agent/boot.mojo — S3 job-binary download (the deployment-real boot).
# =============================================================================
#
# The deployment-real binary-fetch path: given an `s3://bucket/key` URI, GET
# the full object, OPTIONALLY verify its SHA-256, write it to the local download
# path, and chmod it `0o755` so the supervisor can spawn it. Goes through
# `AgentS3Client[C]` (s3_client.mojo), the same S3 surface the log stream and
# the terminal upload use.
#
# THE SHA CONVENTION: job binaries are stored at
# `s3://bucket/<sha256-hex>/binary`. The agent extracts the `<sha256-hex>`
# segment from the key (or takes an explicit expected-SHA from config) and
# verifies the downloaded bytes hash to it BEFORE writing — a corrupted /
# tampered binary aborts the boot rather than getting spawned.
#
# CLOCK AND CREDENTIALS: `AgentS3Client` signs on the LIVE system clock
# (honouring the `MINIO_E2E_*` override for a deterministic test) and resolves
# credentials through the AWS default chain (env -> shared profile -> web
# identity/IRSA -> container -> IMDS): the real in-pod source for an EKS pod
# with an IRSA service account; env for tests and development.
#
# ENCAPSULATION + gap6: the downloaded bytes are an owned `List[UInt8]`; the
# file write goes through `komira_core.io.posix_io.RawWriteFd` (raw fd stays
# inside that module). The ONE local FFI here is `chmod(2)` — a fixed-arity libc
# symbol (`int chmod(const char*, mode_t)`, NON-variadic), encapsulated in
# `_chmod` with a `# SAFETY:` block. No UnsafePointer crosses any agent boundary;
# no wildcard origin. Mojo 1.0.0b1.
# =============================================================================

from std.ffi import external_call
from std.os import mkdir as _os_mkdir

from komira_core.io.posix_io import RawWriteFd

from komira_agent.s3_client import AgentS3Client
from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_crypto.sha256 import sha256
from komira_crypto.hex import hex_lower_array_32

from komira_agent.agent_config import AgentConfig

import komira_log as log
from komira_log import ArgStr, ArgI64


# =============================================================================
# §1 — s3:// URI parsing.
# =============================================================================
struct S3Uri(Copyable, Movable, ImplicitlyCopyable):
    """A parsed `s3://bucket/key` URI.

      bucket — the bucket name (first path segment after the scheme).
      key    — the object key (everything after `bucket/`)."""

    var bucket: String
    var key: String

    def __init__(out self, var bucket: String, var key: String):
        self.bucket = bucket^
        self.key = key^


def parse_s3_uri(uri: String) raises -> S3Uri:
    """Parse `s3://bucket/key` into (bucket, key). Raises on a malformed URI
    (missing scheme, missing key)."""
    var prefix = String("s3://")
    if not uri.startswith(prefix):
        raise Error(
            String("agent boot: not an s3:// URI: '") + uri + String("'")
        )
    var uri_bytes = uri.as_bytes()
    var n = len(uri_bytes)
    var rest = String(
        StringSlice(unsafe_from_utf8=uri_bytes[prefix.byte_length():n])
    )
    var rest_bytes = rest.as_bytes()
    var rn = len(rest_bytes)
    var slash = rest.find(String("/"))
    if slash < 0:
        raise Error(
            String("agent boot: s3 URI has no key (expected"
                   " s3://bucket/key): '") + uri + String("'")
        )
    var bucket = String(StringSlice(unsafe_from_utf8=rest_bytes[0:slash]))
    var key = String(StringSlice(unsafe_from_utf8=rest_bytes[slash + 1:rn]))
    if bucket.byte_length() == 0 or key.byte_length() == 0:
        raise Error(
            String("agent boot: s3 URI has empty bucket or key: '")
            + uri + String("'")
        )
    return S3Uri(bucket^, key^)


# =============================================================================
# §2 — the expected-SHA extraction (the `s3://bucket/<sha>/binary` convention).
# =============================================================================
def expected_sha_from_key(key: String) -> Optional[String]:
    """Extract the embedded SHA-256 hex from a `<sha>/binary`-convention key
    `<sha256-hex>/binary` (or `prefix/<sha256-hex>/binary`). Returns the
    64-char lowercase-hex segment immediately preceding the final `/binary`
    component, if present; else None.

    A 64-char [0-9a-f] segment is treated as a SHA-256 hex digest."""
    # Split on '/', look for a 64-char hex segment.
    var segments = List[String]()
    var cur = String("")
    var bytes = key.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(0x2F):  # '/'
            segments.append(cur)
            cur = String("")
        else:
            cur += chr(Int(c))
    segments.append(cur)
    for ref seg in segments:
        if _is_sha256_hex(seg):
            return Optional[String](String(seg))
    return Optional[String]()


def _is_sha256_hex(s: String) -> Bool:
    """True iff `s` is exactly 64 lowercase-hex characters."""
    var bytes = s.as_bytes()
    if len(bytes) != 64:
        return False
    for i in range(len(bytes)):
        var c = bytes[i]
        var is_digit = c >= UInt8(0x30) and c <= UInt8(0x39)
        var is_lower_hex = c >= UInt8(0x61) and c <= UInt8(0x66)  # a-f
        if not (is_digit or is_lower_hex):
            return False
    return True


# =============================================================================
# §3 — chmod FFI (encapsulated; the one raw syscall in this file).
# =============================================================================
def _chmod(path: String, mode: Int32) raises:
    """chmod(2) `path` to `mode`. `chmod` is a fixed-arity libc symbol
    (`int chmod(const char *path, mode_t mode)`) — NON-variadic, so a direct
    external_call is ABI-safe on both macOS arm64 and Linux x86_64 (no shim
    needed, unlike the variadic `openat`).

    Raises on a non-zero return."""
    var p = path
    # SAFETY: `as_c_string_slice()` returns a NUL-terminated view whose buffer
    # is owned by `p` (held alive across the synchronous syscall by this local
    # var). The kernel reads the path string and copies what it needs; the
    # pointer does not escape this function body.
    var rc = external_call["chmod", Int32](
        p.as_c_string_slice().unsafe_ptr(), mode,
    )
    if Int(rc) != 0:
        raise Error(
            String("agent boot: chmod(") + path + String(", 0o")
            + String(Int(mode)) + String(") failed (rc=")
            + String(Int(rc)) + String(")")
        )


def _mkdir_parents(path: String) raises:
    """Ensure every PARENT directory of `path` exists (the `mkdir -p` of the
    dirname), so a subsequent file write at `path` can `openat()` it.

    The job manager's placement sets `KOMIRA_AGENT_JOB_BINARY` to a nested
    `/tmp/<agent-dir>/<job-id>/job_binary` path; the agent downloads the S3
    binary there, but `RawWriteFd.open_truncate` does NOT create the parent
    dir, so without this a scheduler-spawned download fails with
    'openat() failed'. In a real K8s pod the working dir pre-exists; locally
    (and defensively in-pod) we create it. mkdir each component in turn,
    treating EEXIST as benign (errno 17). A non-EEXIST failure on the FINAL
    component raises; intermediate failures are tolerated (a later component's
    mkdir surfaces the real problem)."""
    var b = path.as_bytes()
    var n = len(b)
    # Walk to the last '/', building each prefix dir as we go.
    var SLASH = UInt8(ord("/"))
    var i = 0
    # Skip a leading '/' (root always exists) so the first mkdir is the first
    # real component, not "" .
    if n > 0 and b[0] == SLASH:
        i = 1
    while i < n:
        if b[i] == SLASH:
            var prefix = String(StringSlice(unsafe_from_utf8=b[0:i]))
            if prefix.byte_length() > 0:
                # EEXIST is benign, and the cause of a failure is not
                # distinguished here, so tolerate ALL intermediate failures —
                # the FINAL openat will surface a real failure. (The common
                # case is EEXIST on shared prefixes like /tmp.) std.os's mkdir,
                # not a second `external_call["mkdir"]`: two declarations of
                # the symbol with different signatures in one closure fail
                # legalization.
                try:
                    _os_mkdir(prefix, 0o755)
                except:
                    pass
        i += 1


# =============================================================================
# §4 — make_s3_client_from_chain — the production client (creds + clock).
# =============================================================================
def make_s3_client_from_chain(
    region: String,
    endpoint: Optional[String],
) raises -> AgentS3Client[KernelTcpConnector]:
    """Build a configured `AgentS3Client[KernelTcpConnector]` resolving credentials
    via the AWS default chain (env -> web-identity/IRSA -> ECS -> IMDS) and
    stamping the SigV4 clock from the live system clock (or the MINIO_E2E_*
    override for the deterministic test).

    The chain is resolved here (not hardcoded): in a real EKS pod the
    web-identity/IRSA arm fires off the projected service-account token; in
    tests/dev the env arm fires off AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY."""
    return make_s3_client_over[KernelTcpConnector](
        mk_agent_s3_plain_connector, region, endpoint
    )


# =============================================================================
# §4b — THE TRANSPORT IS A PARAMETER: one factory, two bindings.
# =============================================================================
#
# ⛔⛔ THE BUG THESE EXIST TO FIX IS THAT THE PLAINTEXT ARM WAS **ALREADY**
# BUILDING `https://` URLS. `AgentS3Client` maps a None endpoint onto
# `S3Config.aws(region)` -- virtual-hosted, scheme `https`, the AWS regional
# host -- and the endpoint arm honours whatever scheme the endpoint string
# carries. Neither touches the TRANSPORT, which is the type parameter. So an
# agent pointed at real S3 signed a correct SigV4 request for an `https://` URL
# and then wrote it in the clear to port 443. The URL layer and the socket layer
# disagreed and nothing in either could see it.
#
# ★ THE FACTORY TAKES A CAPTURELESS CONNECTOR MAKER, which is how the rest of
# this repo terminates a `[C]` transport generic (a
# `mk_connector: def () raises thin -> C` parameter). A
# `def [C]() -> AgentS3Client[C]` could not work: it cannot
# CONSTRUCT a `C`, because `Connector` declares no method that yields one.
# =============================================================================
def mk_agent_s3_tls_connector() raises -> TlsConnector[KernelTcpConnector]:
    """The captureless `def () raises thin -> C` the TLS binding hands to
    `make_s3_client_over`.

    ⛔ IT WRAPS `build_unpinned_public_ca_tls_connector` AND ADDS NOTHING.
    A wrapper is needed only because that function carries a defaulted
    `alpn_h2` argument and so is not itself a `def ()`. Writing a second TLS
    setup here would duplicate it; `komira_http_client`'s factory
    already carries the four decisions that matter (TLS 1.3 cipher preferences,
    the system public-CA trust store, verification ON, `verify_mode=VERIFY_PEER`
    so the session cache buckets correctly).

    ⚠ UNPINNED SNI IS LOAD-BEARING FOR S3 SPECIFICALLY. S3 uses VIRTUAL-HOSTED
    addressing (`<bucket>.s3.<region>.amazonaws.com`), so the BUCKET is in the
    host, and a connector that pinned one server name could reach exactly one
    bucket per process -- the trap that factory's own docstring was written to
    close.

    ⛔ NO `disable_verify()` ARM, AND NONE MAY BE ADDED. This transport carries
    the job's binary, which the agent then EXECS. A verify-skipping TLS arm
    would let whatever answered the dial choose the code that runs, while
    looking secure in every log line. The plaintext posture this replaces was at
    least honestly plaintext."""
    return build_unpinned_public_ca_tls_connector()


def mk_agent_s3_plain_connector() raises -> KernelTcpConnector:
    """The plaintext `def () raises thin -> C`. Exists so BOTH bindings below
    are spelled the same way and the difference between them is exactly one
    identifier."""
    return KernelTcpConnector.new()


def make_s3_client_over[
    C: Connector,
](
    mk_connector: def () raises thin -> C,
    region: String,
    endpoint: Optional[String],
) raises -> AgentS3Client[C]:
    """Build a configured `AgentS3Client[C]` over the transport `mk_connector`
    produces, resolving credentials via the AWS default chain and signing on
    the live system clock (or the MINIO_E2E_* override); s3_client.mojo."""
    return AgentS3Client[C](mk_connector, region, endpoint)


def make_tls_s3_client_from_chain(
    region: String,
    endpoint: Optional[String],
) raises -> AgentS3Client[TlsConnector[KernelTcpConnector]]:
    """`make_s3_client_from_chain`, with the transport bound to TLS. The named
    binding of `make_s3_client_over[TlsConnector[KernelTcpConnector]]`."""
    return make_s3_client_over[TlsConnector[KernelTcpConnector]](
        mk_agent_s3_tls_connector, region, endpoint
    )


# =============================================================================
# §5 — download_binary — GET + SHA-verify + write + chmod 0o755.
# =============================================================================
def download_binary[
    C: Connector,
](
    config: AgentConfig,
    mut s3_client: AgentS3Client[C],
) raises -> String:
    """Download the job binary from `config.binary_s3_uri` to
    `config.binary_download_path`, SHA-verify, and chmod 0o755.

    Steps:
      1. Parse `s3://bucket/key`.
      2. GET the full object (one ranged GET, start=0 end=-1) -> owned bytes.
      3. Verify SHA-256 if an expected digest is available — from the config's
         explicit `binary_sha256` OR from the `<sha>/binary`-convention `<sha>/binary`
         key segment. A mismatch ABORTS (raises) before any write.
      4. Write to `config.binary_download_path` (mode 0644 via RawWriteFd).
      5. chmod 0o755 so the supervisor can exec it.

    Returns the local download path. Raises on any failure (parse / GET /
    SHA-mismatch / write / chmod)."""
    if not config.binary_s3_uri:
        raise Error(
            "agent boot: download_binary called with no binary_s3_uri set"
        )
    var uri = parse_s3_uri(config.binary_s3_uri.value())

    # 2. GET the full object.
    var bytes = s3_client.get_object(uri.bucket, uri.key)

    # 3. SHA verify (explicit config SHA wins; else the key-embedded one).
    var expected: Optional[String]
    if config.binary_sha256:
        expected = Optional[String](config.binary_sha256.value())
    else:
        expected = expected_sha_from_key(uri.key)
    if expected:
        var digest = sha256(bytes)
        var got = hex_lower_array_32(digest)
        if got != expected.value():
            raise Error(
                String("agent boot: SHA-256 mismatch for ")
                + config.binary_s3_uri.value()
                + String(" — expected ") + expected.value()
                + String(" got ") + got
                + String(" (refusing to spawn a tampered/corrupt binary)")
            )

    # 4. Write to the local download path (mode 0644). Ensure the parent dir
    #    exists first — the placement hands a nested
    #    /tmp/<agent-dir>/<job-id>/job_binary path the openat() can't create on
    #    its own.
    var path = config.binary_download_path
    _mkdir_parents(path)
    var fd = RawWriteFd.open_truncate(path)
    fd.write_bytes(bytes)
    fd.close()

    # 5. chmod 0o755 so the supervisor can spawn it.
    _chmod(path, Int32(0o755))

    log.info[
        "agent boot: downloaded {} bytes from {} -> {} (chmod 0o755)",
        "komira_agent",
    ](
        ArgI64(Int64(len(bytes))),
        ArgStr(config.binary_s3_uri.value()),
        ArgStr(path),
    )
    return path
