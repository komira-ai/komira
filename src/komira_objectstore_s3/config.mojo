# =============================================================================
# komira_objectstore_s3/config.mojo -- S3Config, the store's configuration
# =============================================================================
#
# Every setting a store takes is a constructor parameter: the region, the
# endpoint (a custom one for MinIO or LocalStack), the addressing style, FIPS
# and dual-stack, the retry policy of each request, the page size of a
# listing, and the bound on a range fetch's requests. Nothing here reads the
# environment. A caller that wants the AWS SDKs' standard settings
# (`AWS_ENDPOINT_URL_S3`, `AWS_REGION`, a profile) resolves them through
# komira_aws_core's credential chain and its endpoint settings reader, and passes
# the values in. The credential source and the signing clock are the
# store's own type parameters (store.mojo), so they are parameters too.
#
# WHERE A REQUEST GOES is not decided here. The config becomes the generated
# client's `S3EndpointConfig`, and S3's published endpoint ruleset picks the
# host, the addressing and the signing scope per call.
# =============================================================================

from komira_aws_s3.komira_aws_s3 import S3EndpointConfig
from komira_aws_core import aws_standard_retry_policy
from komira_retry import RetryPolicy


comptime S3_DEFAULT_MAX_INFLIGHT = 64
"""The default bound on the requests one range fetch plans, as the
prefetch depth S3's guidance suggests for a standard bucket."""

comptime S3_DEFAULT_LIST_PAGE_SIZE = 1000
"""S3's own page size for ListObjectsV2 (`MaxKeys`)."""

comptime S3_DEFAULT_LIST_MAX_PAGES = 100_000
"""The pages one listing may read before it is refused: a listing that
never ends is a server fault, not a large bucket (10^8 keys at the default
page size)."""


comptime _ADDRESSING_RULESET = UInt8(1)
comptime _ADDRESSING_PATH = UInt8(2)


@fieldwise_init
struct AddressingStyle(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """How a bucket is addressed.

    `virtual_hosted()` leaves it to S3's endpoint ruleset: the bucket is in
    the host (`<bucket>.s3.<region>.amazonaws.com`) unless it cannot be a
    host name (a dotted bucket under TLS, an IP-literal endpoint), when the
    ruleset puts it in the path. `path()` always puts it in the path
    (`<endpoint>/<bucket>/<key>`), as MinIO and LocalStack are usually
    addressed; it is the ruleset's `ForcePathStyle`."""

    var tag: UInt8

    @staticmethod
    def virtual_hosted() -> AddressingStyle:
        return AddressingStyle(_ADDRESSING_RULESET)

    @staticmethod
    def path() -> AddressingStyle:
        return AddressingStyle(_ADDRESSING_PATH)

    def is_path(self) -> Bool:
        return self.tag == _ADDRESSING_PATH


struct S3Config(Copyable, Movable, Deinitable):
    """An S3 store's configuration. Every field is set by the caller.

    - `region`: the signing and endpoint region, such as "us-east-1".
    - `endpoint`: a custom endpoint URL (`http://127.0.0.1:9000` for a local
      MinIO), or "" for AWS's own, which the ruleset derives from the region.
    - `addressing`: virtual-hosted (the ruleset decides) or path.
    - `use_fips`, `use_dual_stack`: the ruleset's FIPS and dual-stack
      endpoints.
    - `retry`: the policy of every request's retry loop (attempts, backoff,
      deadline). komira_aws_core's classifier decides what is retried.
    - `max_inflight`: the most requests of one range fetch in flight at
      once: the concurrency of its plan, and the cap on
      `S3FsOptions.prefetch_max_inflight` (S3Fs sends them on stores of its
      own, one per thread).
    - `list_page_size`: `MaxKeys` of each ListObjectsV2 page.
    - `list_max_pages`: the pages one listing may read before it is refused.
    """

    var region: String
    var endpoint: String
    var addressing: AddressingStyle
    var use_fips: Bool
    var use_dual_stack: Bool
    var retry: RetryPolicy
    var max_inflight: Int
    var list_page_size: Int
    var list_max_pages: Int

    def __init__(
        out self,
        region: String,
        *,
        endpoint: String = "",
        addressing: AddressingStyle = AddressingStyle.virtual_hosted(),
        use_fips: Bool = False,
        use_dual_stack: Bool = False,
        var retry: RetryPolicy,
        max_inflight: Int = S3_DEFAULT_MAX_INFLIGHT,
        list_page_size: Int = S3_DEFAULT_LIST_PAGE_SIZE,
        list_max_pages: Int = S3_DEFAULT_LIST_MAX_PAGES,
    ) raises:
        """Refuses an empty region, a `max_inflight` below 1, and a page size
        outside S3's 1..1000."""
        if region.byte_length() == 0:
            raise Error("S3Config: the region is empty")
        if max_inflight < 1:
            raise Error(
                String("S3Config: max_inflight must be >= 1, got ")
                + String(max_inflight)
            )
        if list_page_size < 1 or list_page_size > 1000:
            raise Error(
                String("S3Config: list_page_size must be 1 to 1000, got ")
                + String(list_page_size)
            )
        if list_max_pages < 1:
            raise Error(
                String("S3Config: list_max_pages must be >= 1, got ")
                + String(list_max_pages)
            )
        self.region = region
        self.endpoint = endpoint
        self.addressing = addressing
        self.use_fips = use_fips
        self.use_dual_stack = use_dual_stack
        self.retry = retry^
        self.max_inflight = max_inflight
        self.list_page_size = list_page_size
        self.list_max_pages = list_max_pages

    @staticmethod
    def aws(region: String) raises -> S3Config:
        """AWS's own endpoint for `region`, the ruleset's addressing, and
        the AWS SDKs' standard retry policy."""
        return S3Config(region, retry=s3_standard_retry_policy())

    @staticmethod
    def custom_endpoint(region: String, endpoint: String) raises -> S3Config:
        """An S3-compatible service at `endpoint` (MinIO, LocalStack),
        addressed by path, with the standard retry policy."""
        if endpoint.byte_length() == 0:
            raise Error("S3Config.custom_endpoint: the endpoint is empty")
        return S3Config(
            region,
            endpoint=endpoint,
            addressing=AddressingStyle.path(),
            retry=s3_standard_retry_policy(),
        )

    def endpoint_config(self) -> S3EndpointConfig:
        """The generated client's ruleset parameters for this config."""
        var c = S3EndpointConfig(self.region)
        if self.endpoint.byte_length() > 0:
            c.endpoint = Optional[String](self.endpoint)
        if self.addressing.is_path():
            c.force_path_style = Optional[Bool](True)
        if self.use_fips:
            c.use_fips = Optional[Bool](True)
        if self.use_dual_stack:
            c.use_dual_stack = Optional[Bool](True)
        return c^


def s3_standard_retry_policy() raises -> RetryPolicy:
    """The AWS SDKs' standard retry mode (komira_aws_core's
    `aws_standard_retry_policy`): three sends, full-jitter backoff from 1 s
    doubling to 20 s, within the window a credential is guaranteed to stay
    valid."""
    return aws_standard_retry_policy()
