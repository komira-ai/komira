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
#     1. Root element is <EnumerationResults>, and the container's name is
#        its ContainerName ATTRIBUTE, not a child element.
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
# Design: each body is parsed by komira_xml's `parse_xml` into a tree, and the
# fields are read by element position under the root: the root's attributes
# (ContainerName, with entity and character references decoded and either
# quote accepted), its direct <Prefix>, <Delimiter> and <NextMarker>, and the
# <Blob> / <BlobPrefix> children of <Blobs>. A List Blobs body that is not
# well-formed XML 1.0 is refused, naming the reader's reason; Azure escapes
# `&` and `<` in every name it returns.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================


from komira_xml import XmlNode, parse_xml


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
# Internal: reading the tree
# -----------------------------------------------------------------------------


def _child_text(node: XmlNode, local: StringSlice) -> String:
    """The text of `node`'s first direct child named `local`, references
    decoded, or "" if there is none (a self-closing `<NextMarker />` is
    "")."""
    var i = node.child_index(local)
    if i < 0:
        return String("")
    return node.children[i].text.copy()


def _blob_entry(blob: XmlNode) raises -> AzureBlobEntry:
    var name = _child_text(blob, "Name")
    var etag = String("")
    var last_mod = String("")
    var blob_type = String("")
    var size_val = Int64(0)
    var p = blob.child_index("Properties")
    if p >= 0:
        ref props = blob.children[p]
        etag = _child_text(props, "Etag")
        last_mod = _child_text(props, "Last-Modified")
        blob_type = _child_text(props, "BlobType")
        var size_str = _child_text(props, "Content-Length")
        if size_str.byte_length() > 0:
            try:
                size_val = Int64(Int(size_str))
            except:
                raise Error("Azure XML: malformed <Content-Length>: " + size_str)
    return AzureBlobEntry(name^, size_val, etag^, last_mod^, blob_type^)


# -----------------------------------------------------------------------------
# parse_azure_list_blobs_result — public surface
# -----------------------------------------------------------------------------


def parse_azure_list_blobs_result(body: String) raises -> AzureListBlobsResult:
    """Parse a <EnumerationResults> XML response from the Azure Blob
    "List Blobs" REST operation.

    `container` is the root's ContainerName attribute ("" when absent).
    Pagination: Azure uses <NextMarker> (NOT <IsTruncated> — truncation
    is implied by a non-empty NextMarker); `<NextMarker />` reads as "".

    Raises on an empty body, on a body that is not well-formed XML (the
    message carries the reader's reason and byte offset), on a root other
    than <EnumerationResults>, and on a <Content-Length> that is not an
    integer. The caller maps each to StoreError.malformed.
    """
    if body.byte_length() == 0:
        raise Error("Azure XML: empty body")
    var root: XmlNode
    try:
        root = parse_xml(body)
    except e:
        raise Error("Azure XML: List Blobs body is not well-formed XML: " + String(e))
    if root.local != "EnumerationResults":
        raise Error(
            "Azure XML: missing <EnumerationResults> root (got <"
            + root.local
            + ">)"
        )

    var blobs = List[AzureBlobEntry]()
    var blob_prefixes = List[String]()
    var b = root.child_index("Blobs")
    if b >= 0:
        ref blobs_node = root.children[b]
        for i in range(len(blobs_node.children)):
            ref child = blobs_node.children[i]
            if child.local == "Blob":
                blobs.append(_blob_entry(child))
            elif child.local == "BlobPrefix":
                blob_prefixes.append(_child_text(child, "Name"))

    return AzureListBlobsResult(
        root.attr("ContainerName"),
        _child_text(root, "Prefix"),
        _child_text(root, "Delimiter"),
        _child_text(root, "NextMarker"),
        blobs^,
        blob_prefixes^,
    )


# -----------------------------------------------------------------------------
# parse_azure_error — public surface
# -----------------------------------------------------------------------------


def parse_azure_error(body: String) raises -> AzureParsedError:
    """Parse a <Error>...</Error> Azure protocol error response body.

    Raises if the body is empty. If the body is not well-formed XML or its
    root is not <Error> (e.g. the server returned a non-XML response),
    returns AzureParsedError("Unknown", body) so callers can still surface
    something to the user.
    """
    if body.byte_length() == 0:
        raise Error("Azure XML: empty error body")
    var root: XmlNode
    try:
        root = parse_xml(body)
    except:
        return AzureParsedError(String("Unknown"), body)
    if root.local != "Error":
        return AzureParsedError(String("Unknown"), body)
    return AzureParsedError(_child_text(root, "Code"), _child_text(root, "Message"))
