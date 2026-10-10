# =============================================================================
# komira_test_s3_adapter/object_store.mojo -- `MinioObjectStore`, a
# komira_test_bucket `ObjectStoreClient` over komira_objectstore_s3's
# `S3Store`.
# =============================================================================
#
# The store is path-style plaintext HTTP to the target's endpoint (the
# embedded MinIO on 127.0.0.1), with the credential read from the
# shared-credentials FILE the target names (profile `default`); it reads no
# environment. The connector is a type parameter and its factory a value, so
# the welded tests drive every verb over komira_http_core's
# `ScriptedConnector`; `minio_object_store()` is the real one, over
# `KernelTcpConnector`.
#
# The bucket is created with one signed `PUT /<bucket>` (komira_aws_s3
# generates no CreateBucket): 200 is created, a 409 whose body says
# `BucketAlreadyOwnedByYou` is "created by an earlier call of this run", and
# anything else raises (`create_bucket_status_ok`). Every error names the
# operation; the bucket and the endpoint are replaced by `<bucket>` and
# `<endpoint>`, so a deployment fact never reaches a log.
# =============================================================================

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
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_objectstore.types import WritePrecondition
from komira_objectstore_s3.config import S3Config
from komira_objectstore_s3.store import S3Store
from komira_test_bucket import ObjectStoreClient, StoreTarget


comptime _P: String = "minio object store: "


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
    if profiles.index_of(String("default")) < 0:
        raise Error(_P + "the credentials file has no default profile, so no key pair")
    var p = profiles.profile(String("default"))
    var id = p.get(String("aws_access_key_id"))
    var secret = p.get(String("aws_secret_access_key"))
    if id.byte_length() == 0 or secret.byte_length() == 0:
        raise Error(_P + "the credentials file's default profile has no key pair")
    return AwsCredential(id, secret, p.get(String("aws_session_token")))


def create_bucket_status_ok(status: Int, body: Span[UInt8, _]) -> Bool:
    """Whether a `PUT /<bucket>` answer means the bucket is ours: 200, or a
    409 `BucketAlreadyOwnedByYou` (an earlier call of this run created it).
    `BucketAlreadyExists` (someone else's) and every other answer are not."""
    if status == 200:
        return True
    if status != 409:
        return False
    return _contains(body, "BucketAlreadyOwnedByYou")


def _contains(hay: Span[UInt8, _], needle: StaticString) -> Bool:
    """Whether `needle` occurs in `hay`, compared as bytes: the body is the
    server's and need not be UTF-8."""
    var nb = needle.as_bytes()
    var n = len(nb)
    for i in range(len(hay) - n + 1):
        var hit = True
        for j in range(n):
            if hay[i + j] != nb[j]:
                hit = False
                break
        if hit:
            return True
    return False


struct MinioObjectStore[C: Connector](ObjectStoreClient):
    """komira_test_bucket's object-store seam over `S3Store` (module header).
    Unbound until `bind`."""

    comptime Store = S3Store[Self.C, StaticCredsSource, SystemAwsClock]

    var _mk_connector: def () raises thin -> Self.C
    var _store: Optional[Self.Store]
    var _target: Optional[StoreTarget]

    def __init__(out self, mk_connector: def () raises thin -> Self.C):
        """A store whose connections come from `mk_connector`."""
        self._mk_connector = mk_connector
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
        self._store = Self.Store(
            S3Config.custom_endpoint(target.region, target.endpoint),
            self._mk_connector,
            HttpClientConfig.defaults(),
            StaticCredsSource(cred),
            SystemAwsClock(),
        )
        self._target = target.copy()

    def create_bucket_if_absent(mut self) raises:
        var bucket = self._bucket()
        var status = 0
        var ok = False
        try:
            ref t = self._target.value()
            var cred = read_credential_file(t.credentials_file)
            var quota = AwsRetryQuota()
            var res = send_sigv4_signed_request[Self.C](
                self._mk_connector,
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
            status = res.status
            ok = create_bucket_status_ok(res.status, Span(res.body))
        except e:
            raise self._fail("CreateBucket", e)
        if not ok:
            raise self._fail("CreateBucket", Error("answered status " + String(status)))

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
        code under test wrote). Not part of `ObjectStoreClient`."""
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


def _mk_kernel_tcp() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


comptime KernelMinioObjectStore = MinioObjectStore[KernelTcpConnector]
"""The real store: plaintext TCP to the target's endpoint."""


def minio_object_store() -> KernelMinioObjectStore:
    """An unbound store over `KernelTcpConnector`."""
    return KernelMinioObjectStore(_mk_kernel_tcp)
