# =============================================================================
# komira_objectstore_s3/store.mojo -- S3Store, the object verbs over the
# generated S3 client
# =============================================================================
#
# `S3Store[C, T, K]` is the bucket-agnostic object layer: HEAD, GET (whole,
# ranged, suffix), ListObjectsV2 (one page, or every page), DELETE, the
# conditional PUT, the multipart upload, and a coalesced range fetch. Every
# request is the generated komira_aws_s3 client's: its request builder, its
# endpoint resolution over S3's published ruleset, and its `<op>_with` send,
# which signs through komira_aws_core (SigV4, S3's rules) and sends over
# komira_http_client. There is no S3 wire code here. What is here is what an
# object store decides: which status means what (errors.mojo), what a range
# answer must say (ranges.mojo), how a listing is drained, and when a write
# is conditional.
#
# The parameters: `C` the komira_http_core connector (TCP, TLS, or a
# scripted one in tests), `T` the credential source (komira_aws_core's
# `AwsCredsSource`: a static one, the default chain, or the shared
# refreshing chain a cloned client needs, `SharedCredsSource`), `K` the
# signing clock (`AwsClock`: the system clock, a fixed one in tests). A store holds ONE
# transport over one connector, so its requests share a kept-alive
# connection, and it is not shared between threads: a second thread takes
# its own store (S3ConditionalStore.clone).
#
# Each request runs komira_aws_core's retry loop under `S3Config.retry`,
# paying for each retry from the store's own `AwsRetryQuota` (botocore's
# standard mode keeps one quota per client, and a store is one client). Its
# HTTP client is built from the caller's `HttpClientConfig`, which has no
# default: it bounds each attempt and the response body, and a process
# serving requests under a platform deadline passes
# `HttpClientConfig.for_serving_ceiling(ceiling_us)`. A
# conditional PUT carries its `If-Match` or `If-None-Match`, which the send
# reads: it is resent only when S3 cannot have acted on it (a throttle, a
# request never sent), because a resend of a write S3 applied is answered
# 412 and would read as a lost race.
#
# A range fetch of several requests reads ONE version of the object: every
# request after the first carries `If-Match` with the ETag the HEAD or the
# first answer gave, so an object overwritten between two requests is
# answered 412 and raises PRECONDITION instead of mixing two versions.
#
# THE SENDS BLOCK THEIR THREAD. komira_aws_core's send runs the HTTP client
# on a blocking runtime. So `get_ranges_into` issues its coalesced requests
# one after another over the store's one connection. Concurrency is one
# store per thread: `plan_range_fetch` plans a fetch and `fetch_span_into`
# sends one of its requests, which S3Fs runs on stores of its own, up to its
# in-flight bound at once (s3_fs.mojo). The poll-shaped CAS verbs
# (komira_objectstore's AsyncCasStore) need a non-blocking send in
# komira_aws_core first.
# =============================================================================

from komira_aws_core import (
    AwsClock,
    AwsConnectorTransport,
    AwsCredsSource,
    AwsRetryQuota,
    HttpResult,
    aws_is_error_status,
    aws_xml_body_is_error,
    aws_xml_error_info,
)
from komira_retry import system_retry_loop
from komira_aws_s3.komira_aws_s3 import (
    S3AbortMultipartUploadRequest,
    S3CompleteMultipartUploadRequest,
    S3CompletedMultipartUpload,
    S3CompletedPart,
    S3CreateMultipartUploadRequest,
    S3DeleteObjectRequest,
    S3GetObjectRequest,
    S3HeadObjectRequest,
    S3ListObjectsV2Request,
    S3PutObjectRequest,
    S3Client,
    S3UploadPartRequest,
    S3_ENCODING_TYPE_URL,
    parse_complete_multipart_upload_response,
    parse_create_multipart_upload_response,
    parse_get_object_response,
    parse_head_object_response,
    parse_list_objects_v2_response,
    parse_put_object_response,
    parse_upload_part_response,
)
from komira_buffer.byte_view import ByteView
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_objectstore.coalesce import CoalescePlan, CoalescedRange, plan_coalesce
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    RANGE_FETCH_STATUS_OK,
    RangeFetchResult,
    RangeSet,
    WritePrecondition,
)

from .config import S3Config
from .errors import s3_malformed, s3_store_error
from .ranges import (
    S3ByteRange,
    s3_check_partial,
    s3_parse_content_range,
    s3_suffix_range_header,
)


comptime S3_MAX_PART_NUMBER = 10000
"""S3's highest multipart part number; part numbers start at 1."""


@fieldwise_init
struct S3UploadedPart(Copyable, Movable, Deinitable):
    """One uploaded part of a multipart upload: its number and the ETag
    UploadPart answered."""

    var part_number: Int
    var etag: String


@fieldwise_init
struct S3ListPage(Movable, Deinitable):
    """One ListObjectsV2 page, keys decoded: its objects, its common
    prefixes, and the token of the next page ("" on the last)."""

    var objects: List[ObjectMeta]
    var common_prefixes: List[String]
    var truncated: Bool
    var next_token: String


@fieldwise_init
struct S3RangeRead(Movable, Deinitable):
    """The bytes of one ranged GetObject and the ETag it answered with ("" when
    the answer carried none)."""

    var bytes: List[UInt8]
    var etag: String


@fieldwise_init
struct S3RangePlan(Movable, Deinitable):
    """The coalesced requests of one range fetch and the ETag a HEAD answered
    while planning it ("" when no HEAD was sent)."""

    var plan: CoalescePlan
    var etag: String


@fieldwise_init
struct S3SuffixRead(Movable, Deinitable):
    """The last bytes of an object, where they start, its size, and the ETag
    the answer carried ("" when it had none)."""

    var bytes: List[UInt8]
    var offset: Int64
    var total: Int64
    var etag: String

    def into_bytes(deinit self) -> List[UInt8]:
        """The bytes, moved out (a footer window is not copied again)."""
        return self.bytes^


def _hex(c: UInt8) -> Int:
    var v = Int(c)
    if v >= 48 and v <= 57:
        return v - 48
    if v >= 65 and v <= 70:
        return v - 55
    if v >= 97 and v <= 102:
        return v - 87
    return -1


def s3_url_decode(s: String) raises -> String:
    """A name S3 sent with `encoding-type=url`, decoded as botocore's
    `decode_list_object_v2` does (`unquote_plus`): `%XX` is a byte and `+`
    a space. Refuses a `%` not followed by two hex digits."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(0x2B):
            out.append(UInt8(0x20))
            i += 1
        elif c == UInt8(0x25):
            if i + 2 >= len(b):
                raise Error("a URL-encoded name ends inside an escape: " + s)
            var hi = _hex(b[i + 1])
            var lo = _hex(b[i + 2])
            if hi < 0 or lo < 0:
                raise Error("a URL-encoded name holds a bad escape: " + s)
            out.append(UInt8(hi * 16 + lo))
            i += 3
        else:
            out.append(c)
            i += 1
    # S3 keys are UTF-8, so the decoded bytes are the UTF-8 key S3 holds.
    return String(unsafe_from_utf8=Span(out))


def _unix_ms(seconds: Optional[Float64]) -> Int64:
    if not seconds:
        return Int64(-1)
    return Int64(seconds.value() * 1000.0)


def _failed(res: HttpResult) -> Bool:
    """A failed answer: an error status, or (for every operation but
    GetObject, whose body is the object) S3's 200 whose body is an <Error>,
    which the generated send has already retried as the 500 it is."""
    return aws_is_error_status(res.status) or aws_xml_body_is_error(res.to_response())


struct S3Store[C: Connector, T: AwsCredsSource, K: AwsClock & Movable & Deinitable](Movable):
    """The object verbs over the generated S3 client (module header).

        var store = S3Store[KernelTcpConnector, ProcessCredsSource, SystemAwsClock](
            S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
            mk_connector, HttpClientConfig.defaults(), creds^, SystemAwsClock(),
        )
        var meta = store.conditional_put(
            "lake", "manifest.json", bytes, WritePrecondition.if_none_match_star()
        )
    """

    var _config: S3Config
    var _client: S3Client[Self.C, Self.T]
    var _transport: AwsConnectorTransport[Self.C]
    var _clock: Self.K
    # The retry quota every request of this store spends from.
    var _retry_quota: AwsRetryQuota

    def __init__(
        out self,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        http_config: HttpClientConfig,
        var creds: Self.T,
        var clock: Self.K,
    ) raises:
        """A store over a connector `mk_connector` makes now, through an
        HTTP client built from `http_config` (the caller's; it has no
        default). The client loads S3's endpoint ruleset once, here."""
        self._transport = AwsConnectorTransport[Self.C](
            http_config, mk_connector()
        )
        self._client = S3Client[Self.C, Self.T](
            mk_connector,
            http_config,
            creds^,
            config.region,
            config.endpoint_config(),
        )
        self._config = config^
        self._clock = clock^
        self._retry_quota = AwsRetryQuota()

    def config(self) -> S3Config:
        return self._config.copy()

    def _fail(self, op: String, bucket: String, key: String, res: HttpResult) -> Error:
        var status = res.status
        if not aws_is_error_status(status):
            # S3's 200 whose body is an <Error>: botocore's 500.
            status = 500
        var info = aws_xml_error_info(status, res.body, String(""))
        return s3_store_error(op, bucket, key, status, info.code, info.message)

    # ---- metadata -----------------------------------------------------------

    def head(mut self, bucket: String, key: String) raises -> ObjectMeta:
        """HeadObject: the size, the ETag (also the CAS handle in
        `version`) and the last-modified time. An absent key raises
        NOT_FOUND (S3 sends no body, so the code is "404")."""
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.head_object_with(
            S3HeadObjectRequest(bucket, key),
            self._transport,
            self._clock,
            loop,
            self._retry_quota,
        )
        if _failed(res):
            raise self._fail("HeadObject", bucket, key, res)
        var out = parse_head_object_response(res^.into_response())
        var etag = out.e_tag.value().copy() if out.e_tag else String("")
        return ObjectMeta(
            location=key,
            size=out.content_length.value() if out.content_length else Int64(-1),
            etag=etag.copy(),
            last_modified_unix_ms=_unix_ms(out.last_modified),
            version=etag^,
        )

    # ---- reads -------------------------------------------------------------

    def _get(
        mut self,
        bucket: String,
        key: String,
        range_header: String,
        if_match: String = "",
    ) raises -> HttpResult:
        var input = S3GetObjectRequest(bucket, key)
        if range_header.byte_length() > 0:
            input.set_range_(range_header)
        if if_match.byte_length() > 0:
            input.set_if_match(if_match)
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.get_object_with(
            input, self._transport, self._clock, loop, self._retry_quota
        )
        if aws_is_error_status(res.status):
            raise self._fail("GetObject", bucket, key, res)
        return res^

    def get(mut self, bucket: String, key: String) raises -> List[UInt8]:
        """GetObject without a Range: the whole object."""
        var out = parse_get_object_response(self._get(bucket, key, String("")).into_response())
        if not out.body:
            return List[UInt8]()
        return out.body.take()

    def get_range(
        mut self,
        bucket: String,
        key: String,
        start: Int64,
        length: Int64,
        if_match: String = "",
    ) raises -> List[UInt8]:
        """The bytes `[start, start + length)` (half-open), fewer only when
        the object ends first. The request is `Range: bytes=<start>-<last>`
        (ranges.mojo), and the answer is checked: a 206 must state the
        range asked for, and a 200 (a server that ignored the Range) is cut
        to it. A zero length reads nothing and sends nothing. `if_match`,
        when set, is sent as `If-Match`: an object whose ETag differs is
        answered 412 and raises PRECONDITION."""
        return self.get_range_read(bucket, key, start, length, if_match).bytes.copy()

    def get_range_read(
        mut self,
        bucket: String,
        key: String,
        start: Int64,
        length: Int64,
        if_match: String = "",
    ) raises -> S3RangeRead:
        """`get_range`, with the ETag of the answer ("" when it has none). A
        zero length sends nothing and answers no ETag."""
        if length == 0 and start >= 0:
            return S3RangeRead(List[UInt8](), String(""))
        var r = S3ByteRange.of_length(start, length)
        var res = self._get(bucket, key, r.header(), if_match)
        var status = res.status
        var content_range = res.header(String("content-range"))
        var etag = res.header(String("etag"))
        var out = parse_get_object_response(res^.into_response())
        var body = out.body.take() if out.body else List[UInt8]()
        if status == 206:
            if content_range.byte_length() == 0:
                raise s3_malformed("GetObject", bucket, key, "a 206 without a Content-Range")
            try:
                s3_check_partial(r, s3_parse_content_range(content_range), len(body))
            except e:
                raise s3_malformed("GetObject", bucket, key, String(e))
            return S3RangeRead(body^, etag^)
        # A 200: the whole object, from which the window is cut.
        if r.start >= Int64(len(body)):
            raise s3_malformed(
                "GetObject",
                bucket,
                key,
                String("a 200 of ")
                + String(len(body))
                + " bytes for a range starting at byte "
                + String(r.start),
            )
        var end = min(Int(r.end), len(body))
        var cut = List[UInt8](capacity=end - Int(r.start))
        cut.extend(Span(body)[Int(r.start) : end])
        return S3RangeRead(cut^, etag^)

    def get_suffix(
        mut self, bucket: String, key: String, n: Int64, if_match: String = ""
    ) raises -> S3SuffixRead:
        """The last `n` bytes of an object in ONE request (`bytes=-<n>`),
        with where they start and the object's size, read from the 206's
        Content-Range: what a footer read needs without a HEAD first. An
        `n` past the object's size reads the whole object. `if_match`, when
        set, is sent as `If-Match`: an object whose ETag differs is answered
        412 and raises PRECONDITION."""
        var res = self._get(bucket, key, s3_suffix_range_header(n), if_match)
        var status = res.status
        var content_range = res.header(String("content-range"))
        var etag = res.header(String("etag"))
        var out = parse_get_object_response(res^.into_response())
        var body = out.body.take() if out.body else List[UInt8]()
        if status == 206:
            if content_range.byte_length() == 0:
                raise s3_malformed("GetObject", bucket, key, "a 206 without a Content-Range")
            var cr = s3_parse_content_range(content_range)
            if cr.total < 0:
                raise s3_malformed(
                    "GetObject", bucket, key, "a suffix 206 without the object's length"
                )
            if (
                Int64(len(body)) != cr.last - cr.first + 1
                or cr.last != cr.total - 1
                or cr.last - cr.first + 1 != min(n, cr.total)
            ):
                raise s3_malformed(
                    "GetObject", bucket, key, "a suffix 206 that is not the object's tail: " + content_range
                )
            return S3SuffixRead(body^, cr.first, cr.total, etag^)
        # A 200: the whole object; its tail is the suffix.
        var total = Int64(len(body))
        var keep = min(n, total)
        var tail = List[UInt8](capacity=Int(keep))
        tail.extend(Span(body)[Int(total - keep) : Int(total)])
        return S3SuffixRead(tail^, total - keep, total, etag^)

    def get_ranges_into[
        dst_origin: Origin[mut=True]
    ](
        mut self,
        bucket: String,
        key: String,
        ranges: RangeSet,
        dst: ByteView[mut=True, dst_origin],
        max_concurrency: Int,
    ) raises -> RangeFetchResult:
        """Every range of `ranges`, each written into `dst` at its
        `dst_offsets[i]`, through komira_objectstore's coalescing plan (near
        ranges merged into one request). The result is indexed in INPUT
        order. An offset or suffix range needs the object's size, so a HEAD
        is sent first when the set holds one. Every request after the HEAD,
        or after the first answer, carries `If-Match` with the ETag it gave,
        so the bytes are one version of the object: one overwritten
        meanwhile raises PRECONDITION. This store sends the requests one
        after another over its one connection; `max_concurrency` and
        `S3Config.max_inflight` bound the plan's concurrency field, which
        `S3Fs.read_ranges_prefetched` spreads over stores of its own."""
        var n = ranges.num_ranges()
        var result = RangeFetchResult.with_capacity(n)
        if n == 0:
            return result^
        var planned = self.plan_range_fetch(bucket, key, ranges, max_concurrency)
        var etag = planned.etag.copy()
        for c in range(len(planned.plan.coalesced)):
            ref span = planned.plan.coalesced[c]
            var answered = self.fetch_span_into(bucket, key, span, dst, etag)
            if etag.byte_length() == 0:
                etag = answered^
            for s in range(len(span.slices)):
                ref sl = span.slices[s]
                result.record(sl.orig_index, RANGE_FETCH_STATUS_OK, Int64(sl.length))
                result.total_fetched_bytes += Int64(sl.length)
        return result^

    def plan_range_fetch(
        mut self,
        bucket: String,
        key: String,
        ranges: RangeSet,
        max_concurrency: Int,
    ) raises -> S3RangePlan:
        """The coalesced requests that read `ranges`, with the ETag a HEAD
        answered when the set holds an offset or suffix range (which needs
        the object's size), else "". The plan's concurrency field is
        `max_concurrency` clamped to 1..`S3Config.max_inflight`."""
        var object_size = Int64(-1)
        var etag = String("")
        for i in range(ranges.num_ranges()):
            if not ranges.ranges[i].is_bounded():
                var meta = self.head(bucket, key)
                object_size = meta.size
                etag = meta.etag.copy()
                break
        var policy = CoalescePolicy.default()
        policy.max_concurrency = max(1, min(max_concurrency, self._config.max_inflight))
        return S3RangePlan(plan_coalesce(ranges, policy, object_size), etag^)

    def fetch_span_into[
        dst_origin: Origin[mut=True]
    ](
        mut self,
        bucket: String,
        key: String,
        span: CoalescedRange,
        dst: ByteView[mut=True, dst_origin],
        if_match: String,
    ) raises -> String:
        """One coalesced request of a plan: GetObject of the span's bytes
        (with `If-Match` when `if_match` is set), each of its slices written
        into `dst` at its `dst_offset`. Returns the ETag the answer carried
        ("" when it had none). Writes only the bytes of this span's slices,
        so two spans of one plan may be fetched into one `dst` at once."""
        var read = self.get_range_read(bucket, key, span.start, span.length(), if_match)
        ref bytes = read.bytes
        for s in range(len(span.slices)):
            ref sl = span.slices[s]
            if sl.coalesced_offset + sl.length > len(bytes):
                raise s3_malformed(
                    "GetObject",
                    bucket,
                    key,
                    String("a range ends past the object: wanted ")
                    + String(sl.length)
                    + " bytes at "
                    + String(span.start + Int64(sl.coalesced_offset)),
                )
            if sl.dst_offset + sl.length > dst.len():
                raise Error(
                    String("get_ranges_into: dst holds ")
                    + String(dst.len())
                    + " bytes; range "
                    + String(sl.orig_index)
                    + " ends at "
                    + String(sl.dst_offset + sl.length)
                )
            for b in range(sl.length):
                dst.write_u8_at(sl.dst_offset + b, bytes[sl.coalesced_offset + b])
        return read.etag.copy()

    # ---- listing -------------------------------------------------------------

    def list_page(
        mut self,
        bucket: String,
        prefix: String,
        delimiter: String,
        continuation_token: String,
        max_keys: Int = 0,
    ) raises -> S3ListPage:
        """One ListObjectsV2 page under `prefix`, grouped at `delimiter`
        ("" for none), from `continuation_token` ("" for the first page), of
        at most `max_keys` entries (0 for `S3Config.list_page_size`).
        Names are asked for URL-encoded (`encoding-type=url`), so a key
        holding a byte XML 1.0 cannot carry survives, and are decoded here."""
        if max_keys < 0:
            raise Error(String("S3Store.list_page: max_keys must be >= 0, got ") + String(max_keys))
        var input = S3ListObjectsV2Request(bucket)
        if prefix.byte_length() > 0:
            input.set_prefix(prefix)
        if delimiter.byte_length() > 0:
            input.set_delimiter(delimiter)
        if continuation_token.byte_length() > 0:
            input.set_continuation_token(continuation_token)
        input.set_encoding_type(String(S3_ENCODING_TYPE_URL))
        input.set_max_keys(Int32(max_keys if max_keys > 0 else self._config.list_page_size))
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.list_objects_v2_with(
            input, self._transport, self._clock, loop, self._retry_quota
        )
        if _failed(res):
            raise self._fail("ListObjectsV2", bucket, prefix, res)
        var out = parse_list_objects_v2_response(res^.into_response())
        var encoded = Bool(out.encoding_type) and out.encoding_type.value() == S3_ENCODING_TYPE_URL
        var objects = List[ObjectMeta]()
        if out.contents:
            ref contents = out.contents.value()
            for i in range(len(contents)):
                ref o = contents[i]
                if not o.key:
                    raise s3_malformed("ListObjectsV2", bucket, prefix, "a listed object without a Key")
                var key = o.key.value().copy()
                if encoded:
                    key = s3_url_decode(key)
                var etag = o.e_tag.value().copy() if o.e_tag else String("")
                objects.append(
                    ObjectMeta(
                        location=key^,
                        size=o.size.value() if o.size else Int64(-1),
                        etag=etag.copy(),
                        last_modified_unix_ms=_unix_ms(o.last_modified),
                        version=etag^,
                    )
                )
        var prefixes = List[String]()
        if out.common_prefixes:
            ref cps = out.common_prefixes.value()
            for i in range(len(cps)):
                if not cps[i].prefix:
                    continue
                var p = cps[i].prefix.value().copy()
                if encoded:
                    p = s3_url_decode(p)
                prefixes.append(p^)
        var truncated = out.is_truncated.value() if out.is_truncated else False
        var next = out.next_continuation_token.value().copy() if out.next_continuation_token else String("")
        return S3ListPage(objects^, prefixes^, truncated, next^)

    def list(
        mut self, bucket: String, prefix: String, delimiter: String
    ) raises -> ListResult:
        """Every page of the listing, drained. Refuses a page that says it
        is truncated but names no next token, a next token equal to the one
        just sent (a server that would loop forever), and more pages than
        `S3Config.list_max_pages`: each would otherwise end in a listing
        that is silently short, or never ends."""
        var objects = List[ObjectMeta]()
        var prefixes = List[String]()
        var token = String("")
        var pages = 0
        while True:
            pages += 1
            if pages > self._config.list_max_pages:
                raise s3_malformed(
                    "ListObjectsV2",
                    bucket,
                    prefix,
                    String("more than ") + String(self._config.list_max_pages) + " pages",
                )
            var page = self.list_page(bucket, prefix, delimiter, token)
            for i in range(len(page.objects)):
                objects.append(page.objects[i].copy())
            for i in range(len(page.common_prefixes)):
                prefixes.append(page.common_prefixes[i].copy())
            if not page.truncated:
                break
            if page.next_token.byte_length() == 0:
                raise s3_malformed(
                    "ListObjectsV2", bucket, prefix, "a truncated page without a NextContinuationToken"
                )
            if page.next_token == token:
                raise s3_malformed(
                    "ListObjectsV2",
                    bucket,
                    prefix,
                    "a page whose NextContinuationToken is the token it was asked with",
                )
            token = page.next_token.copy()
        return ListResult(objects^, prefixes^)

    # ---- writes -------------------------------------------------------------

    def delete(mut self, bucket: String, key: String) raises:
        """DeleteObject. Deleting an absent key succeeds: S3 answers 204,
        and an S3-compatible server that answers 404 NoSuchKey (or a 404
        without a body) is read the same way. Any other 404, such as
        NoSuchBucket, raises NOT_FOUND: the key was not deleted, the bucket
        or endpoint is wrong."""
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.delete_object_with(
            S3DeleteObjectRequest(bucket, key),
            self._transport,
            self._clock,
            loop,
            self._retry_quota,
        )
        if res.status == 404:
            if len(res.body) == 0:
                return
            if aws_xml_error_info(404, res.body, String("")).code == "NoSuchKey":
                return
        if _failed(res):
            raise self._fail("DeleteObject", bucket, key, res)

    def conditional_put(
        mut self,
        bucket: String,
        key: String,
        bytes: List[UInt8],
        precond: WritePrecondition,
    ) raises -> ObjectMeta:
        """PutObject of `bytes`, under `precond`.

          * `if_none_match_star()`  `If-None-Match: *`, create if absent;
          * `if_match(etag)`        `If-Match: <etag>`, compare and swap;
          * `none()`                no condition, create or overwrite.

        `if_none_match(etag)` sends `If-None-Match: <etag>`, the
        create-if-absent form of S3-compatible servers that do not take `*`,
        so only to a custom endpoint (`S3Config.endpoint`). To AWS's own
        endpoint it is refused as MALFORMED before anything is sent: S3's
        PutObject takes `If-None-Match` only as `*`, and answers any other
        value 501, which would read as a transport fault.

        A lost condition raises PRECONDITION (a 412, or the 409
        ConditionalRequestConflict of a race with another conditional
        write; errors.mojo). The answer's ETag is the new object's handle,
        in both `etag` and `version`, so the next compare-and-swap needs no
        HEAD. A success without an ETag is refused: it would leave the next
        compare-and-swap nothing to compare."""
        var input = S3PutObjectRequest(bucket, key)
        input.set_body(bytes.copy())
        if precond.is_if_match():
            if precond.etag.byte_length() == 0:
                raise Error("S3Store.conditional_put: If-Match with an empty ETag")
            input.set_if_match(precond.etag)
        elif precond.is_if_none_match_star():
            input.set_if_none_match(String("*"))
        elif precond.is_if_none_match():
            if self._config.endpoint.byte_length() == 0:
                raise s3_malformed(
                    "PutObject",
                    bucket,
                    key,
                    "S3 takes If-None-Match on PutObject only as *, not an ETag",
                )
            if precond.etag.byte_length() == 0:
                raise Error("S3Store.conditional_put: If-None-Match with an empty ETag")
            input.set_if_none_match(precond.etag)
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.put_object_with(
            input, self._transport, self._clock, loop, self._retry_quota
        )
        if _failed(res):
            raise self._fail("PutObject", bucket, key, res)
        var out = parse_put_object_response(res^.into_response())
        if not out.e_tag or out.e_tag.value().byte_length() == 0:
            raise s3_malformed("PutObject", bucket, key, "a success without an ETag")
        var etag = out.e_tag.value().copy()
        return ObjectMeta(
            location=key,
            size=Int64(len(bytes)),
            etag=etag.copy(),
            last_modified_unix_ms=Int64(-1),
            version=etag^,
        )

    # ---- multipart -----------------------------------------------------------

    def create_multipart_upload(mut self, bucket: String, key: String) raises -> String:
        """CreateMultipartUpload: the UploadId every later part, the
        completion and the abort name. An upload once created costs storage
        until it is completed or aborted."""
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.create_multipart_upload_with(
            S3CreateMultipartUploadRequest(bucket, key),
            self._transport,
            self._clock,
            loop,
            self._retry_quota,
        )
        if _failed(res):
            raise self._fail("CreateMultipartUpload", bucket, key, res)
        var out = parse_create_multipart_upload_response(res^.into_response())
        if not out.upload_id or out.upload_id.value().byte_length() == 0:
            raise s3_malformed("CreateMultipartUpload", bucket, key, "a success without an UploadId")
        return out.upload_id.value().copy()

    def upload_part(
        mut self,
        bucket: String,
        key: String,
        upload_id: String,
        part_number: Int,
        bytes: List[UInt8],
    ) raises -> S3UploadedPart:
        """UploadPart: part `part_number` (1 to 10000) of the upload. S3
        refuses a part other than the last below 5 MiB at completion, not
        here."""
        if part_number < 1 or part_number > S3_MAX_PART_NUMBER:
            raise Error(
                String("S3Store.upload_part: part numbers are 1 to 10000, got ")
                + String(part_number)
            )
        var input = S3UploadPartRequest(bucket, key, Int32(part_number), upload_id)
        input.set_body(bytes.copy())
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.upload_part_with(
            input, self._transport, self._clock, loop, self._retry_quota
        )
        if _failed(res):
            raise self._fail("UploadPart", bucket, key, res)
        var out = parse_upload_part_response(res^.into_response())
        if not out.e_tag or out.e_tag.value().byte_length() == 0:
            raise s3_malformed("UploadPart", bucket, key, "a success without an ETag")
        return S3UploadedPart(part_number, out.e_tag.value().copy())

    def complete_multipart_upload(
        mut self,
        bucket: String,
        key: String,
        upload_id: String,
        parts: List[S3UploadedPart],
    ) raises -> ObjectMeta:
        """CompleteMultipartUpload of `parts`, which must be non-empty and in
        ascending part number. S3 can answer a 200 whose body is an <Error>
        (the assembly failed after the 200 was sent): the generated send
        reads it as a 500, and it raises here, never as a success."""
        if len(parts) == 0:
            raise Error("S3Store.complete_multipart_upload: no parts")
        var listed = List[S3CompletedPart]()
        for i in range(len(parts)):
            if i > 0 and parts[i].part_number <= parts[i - 1].part_number:
                raise Error(
                    "S3Store.complete_multipart_upload: parts must be in ascending part number"
                )
            var p = S3CompletedPart()
            p.set_part_number(Int32(parts[i].part_number))
            p.set_e_tag(parts[i].etag.copy())
            listed.append(p^)
        var doc = S3CompletedMultipartUpload()
        doc.set_parts(listed^)
        var input = S3CompleteMultipartUploadRequest(bucket, key, upload_id)
        input.set_multipart_upload(doc^)
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.complete_multipart_upload_with(
            input, self._transport, self._clock, loop, self._retry_quota
        )
        if _failed(res):
            raise self._fail("CompleteMultipartUpload", bucket, key, res)
        var out = parse_complete_multipart_upload_response(res^.into_response())
        var etag = out.e_tag.value().copy() if out.e_tag else String("")
        return ObjectMeta(
            location=key,
            size=Int64(-1),
            etag=etag.copy(),
            last_modified_unix_ms=Int64(-1),
            version=etag^,
        )

    def abort_multipart_upload(
        mut self, bucket: String, key: String, upload_id: String
    ) raises:
        """AbortMultipartUpload. An upload that is already gone (404
        NoSuchUpload) counts as aborted: it is gone either way. Any other
        404, such as NoSuchBucket, raises NOT_FOUND."""
        var loop = system_retry_loop(self._config.retry.copy())
        var res = self._client.abort_multipart_upload_with(
            S3AbortMultipartUploadRequest(bucket, key, upload_id),
            self._transport,
            self._clock,
            loop,
            self._retry_quota,
        )
        if res.status == 404:
            if aws_xml_error_info(404, res.body, String("")).code == "NoSuchUpload":
                return
        if _failed(res):
            raise self._fail("AbortMultipartUpload", bucket, key, res)
