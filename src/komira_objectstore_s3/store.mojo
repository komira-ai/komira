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
# `AwsCredsSource`: a static one, the default chain), `K` the signing clock
# (`AwsClock`: the system clock, a fixed one in tests). A store holds ONE
# transport over one connector, so its requests share a kept-alive
# connection, and it is not shared between threads: a second thread takes
# its own store (S3ConditionalStore.clone).
#
# Each request runs komira_aws_core's retry loop under `S3Config.retry`. A
# conditional PUT is sent with `conditional=True`: it is resent only when
# S3 cannot have acted on it (a throttle, a request never sent), because a
# resend of a write S3 applied is answered 412 and would read as a lost race.
#
# THE SENDS BLOCK THEIR THREAD. komira_aws_core's send runs the HTTP client
# on a blocking runtime. So `get_ranges_into` issues its coalesced requests
# one after another over the store's one connection; `S3Config.max_inflight`
# bounds the requests one call plans, not requests in flight. A concurrent
# fan-out, and the poll-shaped CAS verbs (komira_objectstore's
# AsyncCasStore), need a non-blocking send in komira_aws_core first.
# =============================================================================

from komira_aws_core import (
    AwsClock,
    AwsConnectorTransport,
    AwsCredsSource,
    HttpResult,
    aws_is_error_status,
    aws_system_retry_loop,
    aws_xml_body_is_error,
    aws_xml_error_info,
)
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
    S3S3Client,
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
from komira_core.collections.byte_view import ByteView
from komira_http_core.transport.io_stream import Connector
from komira_objectstore.coalesce import plan_coalesce
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    RANGE_FETCH_STATUS_OK,
    RangeFetchResult,
    RangeSet,
    WritePrecondition,
)
from komira_retry import NoBudget

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
struct S3SuffixRead(Movable, Deinitable):
    """The last bytes of an object, where they start, and its size."""

    var bytes: List[UInt8]
    var offset: Int64
    var total: Int64


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

        var store = S3Store[KernelTcpConnector, StaticCredsSource, SystemAwsClock](
            S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
            mk_connector, creds^, SystemAwsClock(),
        )
        var meta = store.conditional_put(
            "lake", "manifest.json", bytes, WritePrecondition.if_none_match_star()
        )
    """

    var _config: S3Config
    var _client: S3S3Client[Self.C, Self.T]
    var _transport: AwsConnectorTransport[Self.C]
    var _clock: Self.K

    def __init__(
        out self,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        var creds: Self.T,
        var clock: Self.K,
    ) raises:
        """A store over a connector `mk_connector` makes now. The client
        loads S3's endpoint ruleset once, here."""
        self._transport = AwsConnectorTransport[Self.C](mk_connector())
        self._client = S3S3Client[Self.C, Self.T](
            mk_connector, creds^, config.region, config.endpoint_config()
        )
        self._config = config^
        self._clock = clock^

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
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.head_object_with(
            S3HeadObjectRequest(bucket, key), self._transport, self._clock, loop, budget
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
        mut self, bucket: String, key: String, range_header: String
    ) raises -> HttpResult:
        var input = S3GetObjectRequest(bucket, key)
        if range_header.byte_length() > 0:
            input.set_range_(range_header)
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.get_object_with(
            input, self._transport, self._clock, loop, budget
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
        mut self, bucket: String, key: String, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        """The bytes `[start, start + length)` (half-open), fewer only when
        the object ends first. The request is `Range: bytes=<start>-<last>`
        (ranges.mojo), and the answer is checked: a 206 must state the
        range asked for, and a 200 (a server that ignored the Range) is cut
        to it. A zero length reads nothing and sends nothing."""
        if length == 0 and start >= 0:
            return List[UInt8]()
        var r = S3ByteRange.of_length(start, length)
        var res = self._get(bucket, key, r.header())
        var status = res.status
        var content_range = res.header(String("content-range"))
        var out = parse_get_object_response(res^.into_response())
        var body = out.body.take() if out.body else List[UInt8]()
        if status == 206:
            if content_range.byte_length() == 0:
                raise s3_malformed("GetObject", bucket, key, "a 206 without a Content-Range")
            try:
                s3_check_partial(r, s3_parse_content_range(content_range), len(body))
            except e:
                raise s3_malformed("GetObject", bucket, key, String(e))
            return body^
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
        return cut^

    def get_suffix(mut self, bucket: String, key: String, n: Int64) raises -> S3SuffixRead:
        """The last `n` bytes of an object in ONE request (`bytes=-<n>`),
        with where they start and the object's size, read from the 206's
        Content-Range: what a footer read needs without a HEAD first. An
        `n` past the object's size reads the whole object."""
        var res = self._get(bucket, key, s3_suffix_range_header(n))
        var status = res.status
        var content_range = res.header(String("content-range"))
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
            if Int64(len(body)) != cr.last - cr.first + 1 or cr.last != cr.total - 1:
                raise s3_malformed(
                    "GetObject", bucket, key, "a suffix 206 that is not the object's tail: " + content_range
                )
            return S3SuffixRead(body^, cr.first, cr.total)
        # A 200: the whole object; its tail is the suffix.
        var total = Int64(len(body))
        var keep = min(n, total)
        var tail = List[UInt8](capacity=Int(keep))
        tail.extend(Span(body)[Int(total - keep) : Int(total)])
        return S3SuffixRead(tail^, total - keep, total)

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
        is sent first when the set holds one. The requests are sent one
        after another (module header); `max_concurrency` and
        `S3Config.max_inflight` bound the plan's concurrency field."""
        var n = ranges.num_ranges()
        var result = RangeFetchResult.with_capacity(n)
        if n == 0:
            return result^
        var object_size = Int64(-1)
        for i in range(n):
            if not ranges.ranges[i].is_bounded():
                object_size = self.head(bucket, key).size
                break
        var policy = CoalescePolicy.default()
        policy.max_concurrency = max(1, min(max_concurrency, self._config.max_inflight))
        var plan = plan_coalesce(ranges, policy, object_size)
        for c in range(len(plan.coalesced)):
            ref span = plan.coalesced[c]
            var bytes = self.get_range(bucket, key, span.start, span.length())
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
                result.record(sl.orig_index, RANGE_FETCH_STATUS_OK, Int64(sl.length))
                result.total_fetched_bytes += Int64(sl.length)
        return result^

    # ---- listing -------------------------------------------------------------

    def list_page(
        mut self,
        bucket: String,
        prefix: String,
        delimiter: String,
        continuation_token: String,
    ) raises -> S3ListPage:
        """One ListObjectsV2 page under `prefix`, grouped at `delimiter`
        ("" for none), from `continuation_token` ("" for the first page).
        Names are asked for URL-encoded (`encoding-type=url`), so a key
        holding a byte XML 1.0 cannot carry survives, and are decoded here."""
        var input = S3ListObjectsV2Request(bucket)
        if prefix.byte_length() > 0:
            input.set_prefix(prefix)
        if delimiter.byte_length() > 0:
            input.set_delimiter(delimiter)
        if continuation_token.byte_length() > 0:
            input.set_continuation_token(continuation_token)
        input.set_encoding_type(String(S3_ENCODING_TYPE_URL))
        input.set_max_keys(Int32(self._config.list_page_size))
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.list_objects_v2_with(
            input, self._transport, self._clock, loop, budget
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
        and an S3-compatible server that answers 404 is read the same way."""
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.delete_object_with(
            S3DeleteObjectRequest(bucket, key), self._transport, self._clock, loop, budget
        )
        if res.status == 404:
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
          * `if_none_match(etag)`   `If-None-Match: <etag>`;
          * `none()`                no condition, create or overwrite.

        A lost condition raises PRECONDITION (a 412, or the 409
        ConditionalRequestConflict of a race with another conditional
        write; errors.mojo). The answer's ETag is the new object's handle,
        in both `etag` and `version`, so the next compare-and-swap needs no
        HEAD. A success without an ETag is refused: it would leave the next
        compare-and-swap nothing to compare."""
        var input = S3PutObjectRequest(bucket, key)
        input.set_body(bytes.copy())
        var conditional = not precond.is_none()
        if precond.is_if_match():
            if precond.etag.byte_length() == 0:
                raise Error("S3Store.conditional_put: If-Match with an empty ETag")
            input.set_if_match(precond.etag)
        elif precond.is_if_none_match_star():
            input.set_if_none_match(String("*"))
        elif precond.is_if_none_match():
            if precond.etag.byte_length() == 0:
                raise Error("S3Store.conditional_put: If-None-Match with an empty ETag")
            input.set_if_none_match(precond.etag)
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.put_object_with(
            input, self._transport, self._clock, loop, budget, conditional=conditional
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
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.create_multipart_upload_with(
            S3CreateMultipartUploadRequest(bucket, key),
            self._transport,
            self._clock,
            loop,
            budget,
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
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.upload_part_with(
            input, self._transport, self._clock, loop, budget
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
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.complete_multipart_upload_with(
            input, self._transport, self._clock, loop, budget
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
        NoSuchUpload) counts as aborted: it is gone either way."""
        var loop = aws_system_retry_loop(self._config.retry.copy())
        var budget = NoBudget()
        var res = self._client.abort_multipart_upload_with(
            S3AbortMultipartUploadRequest(bucket, key, upload_id),
            self._transport,
            self._clock,
            loop,
            budget,
        )
        if res.status == 404:
            return
        if _failed(res):
            raise self._fail("AbortMultipartUpload", bucket, key, res)
