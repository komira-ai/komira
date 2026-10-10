# =============================================================================
# test_shared_key_oracle.mojo -- the fake service's string-to-sign, pinned to
# literals spelled from the Shared Key document
# =============================================================================
#
# The loopback test proves the signer and this oracle AGREE. Agreement alone
# cannot show that both read the document the same wrong way, so the oracle
# is pinned here to strings that do not come from either implementation:
#
#   test_document_get_vector -- the document's own Get Container Metadata
#     example (x-ms-date set, so Date is empty; query names sorted).
#   test_document_put_zero_length -- the document's own example for version
#     2015-02-21 and later: Content-Length 0 signs as an empty line.
#   test_document_list_blobs_resource -- the document's List Blobs example:
#     a parameter repeated three times signs once, its values sorted and
#     joined with `,`.
#   test_hand_built_vector -- what the examples above do not reach, spelled
#     by hand from the numbered rules: an x-ms-* name in mixed case
#     (lowercased, sorted with the others), a value with leading, inner and
#     trailing runs of spaces and tabs (rule 4: one space, ends trimmed), a
#     name that starts `x-ms` but not `x-ms-` (left out), a non-zero
#     Content-Length and a Content-Type in their fields, a Range in the last
#     field, a mixed-case query name (lowercased), percent-encoded query
#     values (signed decoded), and the emulator path (account twice).
#
# Each catches a defect in the oracle that the loopback test would miss
# whenever the signer shares it: a dropped lowercase step, a lookup by the
# lowercased name that loses a mixed-case header's value, no whitespace fold,
# values left encoded, the multi-value sort or the field order.
# =============================================================================

from std.testing import assert_equal

from komira_azure_blob_e2e import shared_key_string_to_sign


def _doc_headers(date: String, version: String) -> Dict[String, String]:
    var h = Dict[String, String]()
    h[String("x-ms-date")] = date
    h[String("x-ms-version")] = version
    return h^


def test_document_get_vector() raises:
    var h = _doc_headers(
        String("Fri, 26 Jun 2015 23:39:12 GMT"), String("2015-02-21")
    )
    var got = shared_key_string_to_sign(
        String("GET"), h, String("/mycontainer"),
        String("restype=container&comp=metadata&timeout=20"),
        String("myaccount"),
    )
    var want = String(
        "GET\n\n\n\n\n\n\n\n\n\n\n\n"
        "x-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\nx-ms-version:2015-02-21\n"
        "/myaccount/mycontainer\ncomp:metadata\nrestype:container\ntimeout:20"
    )
    assert_equal(got, want, "the document's Get Container Metadata example")
    print("  test_document_get_vector PASS")


def test_document_put_zero_length() raises:
    var h = _doc_headers(
        String("Fri, 26 Jun 2015 23:39:12 GMT"), String("2015-02-21")
    )
    h[String("content-length")] = String("0")
    var got = shared_key_string_to_sign(
        String("PUT"), h, String("/mycontainer"),
        String("restype=container&timeout=30"), String("myaccount"),
    )
    var want = String(
        "PUT\n\n\n\n\n\n\n\n\n\n\n\n"
        "x-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\nx-ms-version:2015-02-21\n"
        "/myaccount/mycontainer\nrestype:container\ntimeout:30"
    )
    assert_equal(got, want, "the document's Content-Length 0 example")
    print("  test_document_put_zero_length PASS")


def test_document_list_blobs_resource() raises:
    var h = _doc_headers(
        String("Fri, 26 Jun 2015 23:39:12 GMT"), String("2015-02-21")
    )
    var got = shared_key_string_to_sign(
        String("GET"), h, String("/mycontainer"),
        String(
            "restype=container&comp=list&include=snapshots"
            "&include=metadata&include=uncommittedblobs"
        ),
        String("myaccount"),
    )
    var want = String(
        "GET\n\n\n\n\n\n\n\n\n\n\n\n"
        "x-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\nx-ms-version:2015-02-21\n"
        "/myaccount/mycontainer\ncomp:list"
        "\ninclude:metadata,snapshots,uncommittedblobs\nrestype:container"
    )
    assert_equal(got, want, "the document's List Blobs example")
    print("  test_document_list_blobs_resource PASS")


def test_hand_built_vector() raises:
    var h = Dict[String, String]()
    h[String("X-MS-Version")] = String("2025-01-05")
    h[String("x-ms-meta-Note")] = String("  a \t  b   c \t")
    h[String("x-ms-date")] = String("Tue, 06 Oct 2026 12:00:00 GMT")
    h[String("x-msx-other")] = String("not a canonicalized header")
    h[String("date")] = String("Mon, 05 Oct 2026 00:00:00 GMT")
    h[String("content-length")] = String("12")
    h[String("content-type")] = String("application/xml")
    h[String("range")] = String("bytes=0-9")
    var got = shared_key_string_to_sign(
        String("GET"), h, String("/devstoreaccount1/lake/a%26b"),
        String(
            "Comp=list&restype=container&include=snapshots&include=metadata"
            "&marker=2%21mk%3D4%2Fp&prefix=data%2F"
        ),
        String("devstoreaccount1"),
    )
    var want = String(
        "GET\n"
        "\n"  # Content-Encoding
        "\n"  # Content-Language
        "12\n"  # Content-Length
        "\n"  # Content-MD5
        "application/xml\n"  # Content-Type
        "\n"  # Date: empty, x-ms-date is set
        "\n\n\n\n"  # If-Modified-Since, If-Match, If-None-Match, If-Unmodified-Since
        "bytes=0-9\n"  # Range
        "x-ms-date:Tue, 06 Oct 2026 12:00:00 GMT\n"
        "x-ms-meta-note:a b c\n"
        "x-ms-version:2025-01-05\n"
        "/devstoreaccount1/devstoreaccount1/lake/a%26b"
        "\ncomp:list"
        "\ninclude:metadata,snapshots"
        "\nmarker:2!mk=4/p"
        "\nprefix:data/"
        "\nrestype:container"
    )
    assert_equal(got, want, "the hand-built vector")
    print("  test_hand_built_vector PASS")


def main() raises:
    test_document_get_vector()
    test_document_put_zero_length()
    test_document_list_blobs_resource()
    test_hand_built_vector()
    print("PASS komira_azure_blob_e2e shared_key_oracle")
