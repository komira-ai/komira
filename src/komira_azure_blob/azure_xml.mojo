# =============================================================================
# komira_azure_blob/azure_xml.mojo — minimal Azure Blob response XML parser
# =============================================================================
#
# The Azure Blob REST "List Blobs" operation returns a DIFFERENT XML shape
# from the S3 / GCS XML APIs:
#
#   List Blobs response  — GET /<container>?restype=container&comp=list
#                          [&prefix=X][&delimiter=Y][&marker=Z]
#     <?xml version="1.0" encoding="utf-8"?>
#     <EnumerationResults ServiceEndpoint="..." ContainerName="...">
#       <Prefix>...</Prefix>
#       <Marker>...</Marker>
#       <Delimiter>...</Delimiter>
#       <Blobs>
#         <Blob>
#           <Name>foo/bar.parquet</Name>
#           <Properties>
#             <Content-Length>123</Content-Length>
#             <Etag>0x8D...</Etag>
#             <Last-Modified>Thu, 01 Oct 2026 12:00:00 GMT</Last-Modified>
#             <BlobType>BlockBlob</BlobType>
#           </Properties>
#         </Blob>
#         <BlobPrefix>
#           <Name>foo/</Name>
#         </BlobPrefix>
#       </Blobs>
#       <NextMarker>opaque-continuation</NextMarker>
#     </EnumerationResults>
#
#   Key divergences from S3/GCS <ListBucketResult>:
#     1. Root element is <EnumerationResults> (with attributes) — match on
#        the tag-open prefix `<EnumerationResults` to tolerate them.
#     2. Per-blob name is <Name> nested in <Blob>, size is
#        <Content-Length> nested in <Properties>, ETag is <Etag> (lower
#        'tag') NOT <ETag>.
#     3. Pagination is <NextMarker> (empty element <NextMarker /> when no
#        more pages) driven by ?marker= on the next request — same shape
#        as GCS but the element can be self-closing.
#     4. Common-prefix elements are <BlobPrefix><Name>foo/</Name> (NOT
#        <CommonPrefixes><Prefix>).
#
#   Error response  — body for any 4xx/5xx (with x-ms-error-code header
#                     also carrying the code):
#     <?xml version="1.0" encoding="utf-8"?>
#     <Error>
#       <Code>BlobNotFound</Code>
#       <Message>The specified blob does not exist. RequestId:...</Message>
#     </Error>
#
# Design: not a full XML parser — a tag finder. The element set is
# tightly constrained;
# Azure does not emit CDATA on the elements we read.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================


from komira_xml import xml_unescape


# -----------------------------------------------------------------------------
# AzureBlobEntry — one <Blob>...</Blob> element parsed
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureBlobEntry(
    Movable, Copyable, ImplicitlyCopyable, Deinitable
):
    """One entry from <Blob>...</Blob>.

    Field layout:
      var name: String           — the blob name (Azure path)
      var size: Int64            — Content-Length in bytes
      var etag: String           — the <Etag> value (NOT quote-wrapped on
                                   Azure — the raw "0x8D..." form)
      var last_modified: String  — RFC-1123 timestamp
      var blob_type: String      — BlockBlob / PageBlob / AppendBlob
                                   (empty if absent)
    """

    var name: String
    var size: Int64
    var etag: String
    var last_modified: String
    var blob_type: String


# -----------------------------------------------------------------------------
# AzureListBlobsResult — parsed <EnumerationResults>
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureListBlobsResult(Movable, Deinitable):
    """The full <EnumerationResults>...</EnumerationResults> parse.

    Field layout:
      var container: String                  — ContainerName attribute
                                              value (empty if not parsed)
      var prefix: String                      — the requested <Prefix>
      var delimiter: String                   — the requested <Delimiter>
      var next_marker: String                 — for pagination; empty if
                                              absent OR self-closing
      var blobs: List[AzureBlobEntry]          — one per <Blob>
      var blob_prefixes: List[String]          — one per <BlobPrefix><Name>
    """

    var container: String
    var prefix: String
    var delimiter: String
    var next_marker: String
    var blobs: List[AzureBlobEntry]
    var blob_prefixes: List[String]

    @staticmethod
    def empty() -> AzureListBlobsResult:
        return AzureListBlobsResult(
            String(""),
            String(""),
            String(""),
            String(""),
            List[AzureBlobEntry](),
            List[String](),
        )

    @always_inline
    def is_truncated(self) -> Bool:
        """Azure has no <IsTruncated> element — truncation is implied by a
        non-empty <NextMarker>. This derives it."""
        return self.next_marker.byte_length() > 0


# -----------------------------------------------------------------------------
# AzureParsedError — parsed <Error>
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureParsedError(
    Movable, Copyable, ImplicitlyCopyable, Deinitable
):
    """Parsed <Error>...</Error> Azure protocol error body.

    Field layout:
      var code: String        — Azure error code (BlobNotFound,
                               AuthenticationFailed, etc.)
      var message: String     — human-readable detail (often carries a
                               RequestId / Time suffix)
    """

    var code: String
    var message: String

    @staticmethod
    def empty() -> AzureParsedError:
        return AzureParsedError(String(""), String(""))


# -----------------------------------------------------------------------------
# Internal: minimal tag finder
# -----------------------------------------------------------------------------


def _find_after(body: String, needle: String, start: Int) -> Int:
    """Find `needle` in `body` starting at byte offset `start`; returns
    the byte offset of `needle` or -1 if not found."""
    if start < 0:
        return -1
    var bn = body.byte_length()
    var nn = needle.byte_length()
    if nn == 0 or start + nn > bn:
        return -1
    var body_bs = body.as_bytes()
    var nd_bs = needle.as_bytes()
    var i = start
    while i + nn <= bn:
        var found = True
        var j = 0
        while j < nn:
            if body_bs[i + j] != nd_bs[j]:
                found = False
                break
            j += 1
        if found:
            return i
        i += 1
    return -1


def _slice_string(s: String, lo: Int, hi: Int) -> String:
    """Return s[lo:hi] as a new owned String. lo/hi clamped to valid range."""
    var bs = s.as_bytes()
    var n = len(bs)
    var a = lo if lo >= 0 else 0
    var b = hi if hi <= n else n
    if b < a:
        b = a
    var sub = bs[a:b]
    return String(StringSlice(unsafe_from_utf8=sub))


def _decode_xml_entities(s: String) -> String:
    """Decode XML entity references in `s`, via the general codec.

    ⚠ THIS FUNCTION USED TO CARRY A SILENT DATA-CORRUPTION BUG, byte-for-byte
    the same one `komira_aws_s3/s3_xml.mojo` carried — the two hand-written
    scanners were written from the same template, so they had the same defect
    in the same place. It built its output with `out += chr(Int(c))` per BYTE;
    `chr()` takes a CODEPOINT and emits UTF-8, so every byte >= 0x80 was
    re-encoded as the two-byte form of that byte's numeric value, and every
    Azure blob name containing a non-ASCII character came back mojibaked:
    "café" (63 61 66 C3 A9) returned as "cafÃ©" (63 61 66 C3 83 C2 A9). The
    result is well-formed UTF-8, so nothing raised.

    It now delegates to `komira_xml.xml_unescape`, which is byte-oriented and
    also decodes numeric character references. A third hand-rolled copy is not
    written here on purpose: duplicating this decoder is how one bug came to
    exist in two files.
    """
    return xml_unescape(s)


def _element_text(body: String, tag: String, search_start: Int) -> String:
    """Find the FIRST occurrence of <tag>...</tag> at-or-after
    `search_start`, return the text content (with XML entities decoded).
    Returns empty string if not found."""
    var open_str = String("<") + tag + String(">")
    var close_str = String("</") + tag + String(">")
    var open_pos = _find_after(body, open_str, search_start)
    if open_pos < 0:
        return String("")
    var content_start = open_pos + open_str.byte_length()
    var close_pos = _find_after(body, close_str, content_start)
    if close_pos < 0:
        return String("")
    var raw = _slice_string(body, content_start, close_pos)
    return _decode_xml_entities(raw)


def _element_text_within(
    body: String, tag: String, region_lo: Int, region_hi: Int
) -> String:
    """Like _element_text but constrained to the byte range
    [region_lo, region_hi). Used when parsing nested elements within a
    <Blob>...</Blob> block."""
    var open_str = String("<") + tag + String(">")
    var close_str = String("</") + tag + String(">")
    var open_pos = _find_after(body, open_str, region_lo)
    if open_pos < 0 or open_pos >= region_hi:
        return String("")
    var content_start = open_pos + open_str.byte_length()
    var close_pos = _find_after(body, close_str, content_start)
    if close_pos < 0 or close_pos >= region_hi:
        return String("")
    var raw = _slice_string(body, content_start, close_pos)
    return _decode_xml_entities(raw)


# -----------------------------------------------------------------------------
# parse_azure_list_blobs_result — public surface
# -----------------------------------------------------------------------------


def parse_azure_list_blobs_result(body: String) raises -> AzureListBlobsResult:
    """Parse a <EnumerationResults> XML response from the Azure Blob
    "List Blobs" REST operation.

    The root element carries attributes (ServiceEndpoint, ContainerName)
    so we match on `<EnumerationResults` (no trailing `>`) to tolerate
    them.

    Pagination: Azure uses <NextMarker> (NOT <IsTruncated> — truncation
    is implied by a non-empty NextMarker). When there are no more pages
    Azure emits `<NextMarker />` (self-closing) which our <tag>...</tag>
    finder treats as absent (returns empty) — the desired behavior.

    On any malformed/unparseable input we raise — caller maps to
    StoreError.malformed. Empty input raises.
    """
    if body.byte_length() == 0:
        raise Error("Azure XML: empty body")

    var root_pos = _find_after(body, String("<EnumerationResults"), 0)
    if root_pos < 0:
        raise Error("Azure XML: missing <EnumerationResults> root")

    var prefix = _element_text(body, String("Prefix"), 0)
    var delimiter = _element_text(body, String("Delimiter"), 0)
    var next_marker = _element_text(body, String("NextMarker"), 0)

    # Walk <Blob>...</Blob> blocks. We use the close tag </Blob> as the
    # region boundary; <BlobPrefix> blocks are handled separately and do
    # NOT contain a </Blob> close.
    var blobs = List[AzureBlobEntry]()
    var blob_open = String("<Blob>")
    var blob_close = String("</Blob>")
    var search_from = 0
    while True:
        var open_pos = _find_after(body, blob_open, search_from)
        if open_pos < 0:
            break
        var region_lo = open_pos + blob_open.byte_length()
        var close_pos = _find_after(body, blob_close, region_lo)
        if close_pos < 0:
            raise Error("Azure XML: unterminated <Blob>")
        var name = _element_text_within(
            body, String("Name"), region_lo, close_pos
        )
        var etag = _element_text_within(
            body, String("Etag"), region_lo, close_pos
        )
        var last_mod = _element_text_within(
            body, String("Last-Modified"), region_lo, close_pos
        )
        var size_str = _element_text_within(
            body, String("Content-Length"), region_lo, close_pos
        )
        var size_val = Int64(0)
        if size_str.byte_length() > 0:
            try:
                size_val = Int64(Int(size_str))
            except:
                raise Error("Azure XML: malformed <Content-Length>: " + size_str)
        var blob_type = _element_text_within(
            body, String("BlobType"), region_lo, close_pos
        )
        blobs.append(
            AzureBlobEntry(name^, size_val, etag^, last_mod^, blob_type^)
        )
        search_from = close_pos + blob_close.byte_length()

    # Walk <BlobPrefix><Name>...</Name></BlobPrefix> blocks.
    var blob_prefixes = List[String]()
    var bp_open = String("<BlobPrefix>")
    var bp_close = String("</BlobPrefix>")
    var bp_search = 0
    while True:
        var open_pos = _find_after(body, bp_open, bp_search)
        if open_pos < 0:
            break
        var region_lo = open_pos + bp_open.byte_length()
        var close_pos = _find_after(body, bp_close, region_lo)
        if close_pos < 0:
            raise Error("Azure XML: unterminated <BlobPrefix>")
        var bp_text = _element_text_within(
            body, String("Name"), region_lo, close_pos
        )
        blob_prefixes.append(bp_text^)
        bp_search = close_pos + bp_close.byte_length()

    return AzureListBlobsResult(
        String(""),
        prefix^,
        delimiter^,
        next_marker^,
        blobs^,
        blob_prefixes^,
    )


# -----------------------------------------------------------------------------
# parse_azure_error — public surface
# -----------------------------------------------------------------------------


def parse_azure_error(body: String) raises -> AzureParsedError:
    """Parse a <Error>...</Error> Azure protocol error response body.

    Raises if the body is empty. If <Error> is absent (e.g. the server
    returned a non-XML response), returns a best-effort AzureParsedError
    with the raw body as `message` so callers can still surface
    something to the user.
    """
    if body.byte_length() == 0:
        raise Error("Azure XML: empty error body")
    var has_error_root = _find_after(body, String("<Error>"), 0) >= 0
    if not has_error_root:
        return AzureParsedError(String("Unknown"), body)
    var code = _element_text(body, String("Code"), 0)
    var message = _element_text(body, String("Message"), 0)
    return AzureParsedError(code^, message^)
