# =============================================================================
# komira_objectstore_s3/presign.mojo -- S3PresignSigner, presigned S3 URLs
# as komira_objectstore's ObjectUrlSigner
# =============================================================================
#
# A presigned URL carries its SigV4 signature in the query string
# (`X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`,
# `X-Amz-SignedHeaders`, `X-Amz-Security-Token` for a temporary credential,
# `X-Amz-Signature`), and whoever dials it sends no credential. The signing is
# komira_aws_core's `sigv4_presign`; nothing here signs.
#
# WHAT IS SIGNED. Only `host`, and the payload as `UNSIGNED-PAYLOAD`: the
# client that dials the URL must reproduce every signed header exactly, and
# there is no body at signing time. The path is S3's: not normalized
# (`a//b`, `a/./b` and `a/../b` are three different keys) and not encoded
# twice, so the context is built with `normalize_path=False,
# uri_encode_path=False`, as S3's own header signing is.
#
# WHERE THE URL POINTS is the generated client's: the GetObject / PutObject
# request builder gives the path of the key, and S3's endpoint ruleset (over
# the same S3Config a store takes) gives the host, the addressing and the
# signing scope. A key of the signer's bucket is the only thing a caller
# names, so a URL cannot reach outside that bucket.
#
# THE TTL. komira_objectstore caps a presigned capability at
# `PRESIGN_MAX_TTL_SECONDS` (one hour; `check_presign_ttl`), far below S3's
# seven days, because a presigned URL cannot be revoked.
# =============================================================================

from komira_aws_core import (
    AwsClock,
    AwsCredsSource,
    AwsSigningTarget,
    EndpointRuleSet,
    Header,
    SigV4SigningContext,
    amz_date_from_unix,
    aws_signing_target,
    sigv4_presign,
)
from komira_aws_s3.komira_aws_s3 import (
    S3EndpointConfig,
    S3GetObjectRequest,
    S3PutObjectRequest,
    S3_SERVICE,
    build_get_object_request,
    build_put_object_request,
    komira_aws_s3_endpoint_rules,
    resolve_get_object_endpoint,
    resolve_put_object_endpoint,
)
from komira_objectstore.presign import (
    ObjectUrlSigner,
    PresignedUrl,
    PresignedHeader,
    check_presign_ttl,
)

from .config import S3Config


comptime S3_UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"


struct S3PresignSigner[T: AwsCredsSource, K: AwsClock & Movable & Deinitable](ObjectUrlSigner):
    """`ObjectUrlSigner` over one S3 bucket (module header)."""

    var _bucket: String
    var _region: String
    var _endpoint_config: S3EndpointConfig
    var _rules: EndpointRuleSet
    var _creds: Self.T
    var _clock: Self.K

    def __init__(
        out self,
        var bucket: String,
        config: S3Config,
        var creds: Self.T,
        var clock: Self.K,
    ) raises:
        """A signer for keys of `bucket`, addressed as `config` says. Loads
        S3's endpoint ruleset once, here."""
        if bucket.byte_length() == 0:
            raise Error("S3PresignSigner: the bucket is empty")
        self._bucket = bucket^
        self._region = config.region.copy()
        self._endpoint_config = config.endpoint_config()
        self._rules = komira_aws_s3_endpoint_rules()
        self._creds = creds^
        self._clock = clock^

    def signer_cloud(self) -> String:
        return String("s3")

    def presign_download(mut self, key: String, ttl_seconds: Int) raises -> PresignedUrl:
        """A GET of `key`, valid for `ttl_seconds`."""
        check_presign_ttl(ttl_seconds)
        return self.presign_unchecked(String("GET"), key, ttl_seconds)

    def presign_upload(mut self, key: String, ttl_seconds: Int) raises -> PresignedUrl:
        """A PUT of `key`, valid for `ttl_seconds`."""
        check_presign_ttl(ttl_seconds)
        return self.presign_unchecked(String("PUT"), key, ttl_seconds)

    def _uri(self, method: String, key: String) raises -> String:
        """The path of `key` as the generated request builder writes it."""
        if method == "GET":
            return build_get_object_request(S3GetObjectRequest(self._bucket, key)).uri.copy()
        return build_put_object_request(S3PutObjectRequest(self._bucket, key)).uri.copy()

    def _target(self, method: String, key: String) raises -> AwsSigningTarget:
        """Where S3's endpoint ruleset sends `method` on `key`, and how it
        is signed."""
        if method == "GET":
            return aws_signing_target(
                resolve_get_object_endpoint(
                    self._rules, self._endpoint_config, S3GetObjectRequest(self._bucket, key)
                ),
                self._region,
                String(S3_SERVICE),
            )
        return aws_signing_target(
            resolve_put_object_endpoint(
                self._rules, self._endpoint_config, S3PutObjectRequest(self._bucket, key)
            ),
            self._region,
            String(S3_SERVICE),
        )

    def presign_unchecked(
        mut self, method: String, key: String, expires_seconds: Int
    ) raises -> PresignedUrl:
        """The URL for `method` (GET or PUT) on `key`, with no cap of this
        codebase on `expires_seconds` (SigV4's own bound of 1 s to 7 days
        still holds). The trait verbs call it after `check_presign_ttl`;
        a test calls it directly to sign a custom-endpoint PUT and to check
        the method refusal."""
        if key.byte_length() == 0:
            raise Error("S3PresignSigner: refusing to sign an empty key")
        if method != "GET" and method != "PUT":
            raise Error("S3PresignSigner: only GET and PUT are presigned, not " + method)
        var uri = self._uri(method, key)
        var target = self._target(method, key)
        var endpoint = target.endpoint.copy()
        var host = endpoint.host_header()
        var now = self._clock.now_unix_seconds()
        var ctx = SigV4SigningContext(
            self._creds.credentials(),
            target.signing_region,
            target.signing_name,
            amz_date_from_unix(now),
            normalize_path=False,
            uri_encode_path=False,
        )
        var headers = List[Header]()
        headers.append(Header(String("host"), host))
        var signed = sigv4_presign(
            method,
            endpoint.target_for(uri),
            headers,
            String(S3_UNSIGNED_PAYLOAD),
            ctx,
            expires_seconds,
        )
        return PresignedUrl(
            endpoint.scheme + "://" + host + signed.signed_target,
            method,
            Int64(now + expires_seconds),
            List[PresignedHeader](),
        )
