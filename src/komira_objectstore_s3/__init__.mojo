"""`komira_objectstore_s3` -- Amazon S3 (and S3-compatible services) as a
komira_objectstore store, built on the generated `komira_aws_s3` client.

- `config.mojo`: `S3Config` (region, endpoint, `AddressingStyle`, FIPS and
  dual-stack, retry policy, `max_inflight`, listing page size and cap). Every
  setting is a constructor parameter; nothing reads the environment.
- `errors.mojo`: `classify_http_status` (an S3 answer as a komira_objectstore
  `StoreError` kind, a 409 ConditionalRequestConflict a lost precondition),
  `s3_store_error` (the `StoreError[<KIND>] ...` message every verb raises)
  and `store_error_kind_from_message`.
- `ranges.mojo`: `S3ByteRange`, the one place a half-open window becomes
  HTTP's closed Range, and the checks a 206's Content-Range must pass.
- `store.mojo`: `S3Store[C, T, K]`, the object verbs (HEAD, GET, ranged and
  suffix GET, ListObjectsV2, DELETE, conditional PUT, multipart, coalesced
  range fetch) over the generated client's `<op>_with` sends, through an
  HTTP client built from the caller's `HttpClientConfig` and paying for
  retries from the store's own `AwsRetryQuota`.
- `conditional_store.mojo`: `S3ConditionalStore[C, T, K]`, one bucket as a
  `CloneableConditionalWriteStore` and `RangeFetchStore`.
- `s3_fs.mojo`: `S3Fs[C, T, K]`, one bucket as komira_fs's `FileSystem`
  (listing, shallow listing, ranged reads of one object version per file
  handle, one-request footers, multipart writes, delete, and up to the
  in-flight bounds of requests at once), with `S3FileHandle` and
  `S3WriteFile`; `s3_fs_options.mojo`: `S3FsOptions`; `s3_fs_jobs.mojo`
  (not re-exported): the concurrent requests S3Fs runs.
- `inflight.mojo`: `run_bounded_inflight`, N jobs on at most K threads
  (komira_fork_join), each over a store of its own, and `inflight_workers`.
- `s3_endpoint.mojo`: `s3_endpoint_is_plaintext`, `s3_connector_factory`
  and `s3_prod_fs`, which pick the plaintext connector only for an
  `http://` endpoint and TLS otherwise, over komira_http_client's
  `KernelSchemeConnector`.
- `presign.mojo`: `S3PresignSigner[T, K]`, presigned GET and PUT URLs as an
  `ObjectUrlSigner`, over komira_aws_core's `sigv4_presign`, signing only
  `host`.
"""

from .config import (
    AddressingStyle,
    S3Config,
    S3_DEFAULT_LIST_MAX_PAGES,
    S3_DEFAULT_LIST_PAGE_SIZE,
    S3_DEFAULT_MAX_INFLIGHT,
    s3_standard_retry_policy,
)
from .errors import (
    S3_CONDITIONAL_CONFLICT_CODE,
    classify_http_status,
    s3_malformed,
    s3_store_error,
    store_error_kind_from_message,
    store_error_kind_name,
)
from .ranges import (
    S3ByteRange,
    S3ContentRange,
    s3_check_partial,
    s3_offset_range_header,
    s3_parse_content_range,
    s3_suffix_range_header,
)
from .store import (
    S3ListPage,
    S3RangePlan,
    S3RangeRead,
    S3Store,
    S3SuffixRead,
    S3UploadedPart,
    S3_MAX_PART_NUMBER,
    s3_url_decode,
)
from .conditional_store import S3ConditionalStore
from .presign import S3PresignSigner, S3_UNSIGNED_PAYLOAD
from .inflight import InflightJobs, inflight_workers, run_bounded_inflight
from .s3_fs import S3FileHandle, S3Fs, S3WriteFile
from .s3_endpoint import s3_connector_factory, s3_endpoint_is_plaintext, s3_prod_fs
from .s3_fs_options import (
    S3FsOptions,
    S3_FS_ALL_RANGES,
    S3_FS_DEFAULT_PART_BYTES,
    S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT,
    S3_FS_UPLOAD_MAX_INFLIGHT_CAP,
    S3_MAX_PART_BYTES,
    S3_MIN_PART_BYTES,
)
