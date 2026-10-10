# The Azure Blob response XML parser: List Blobs entries, prefixes and the
# continuation marker, the root's ContainerName attribute (entities decoded,
# either quote), the error body, entity decoding, and the refusal of a body
# that is not well-formed XML.
#
# Entity decoding works per UTF-8 BYTE, never through `chr()`: `chr()` takes a
# CODEPOINT and emits its UTF-8 encoding, so a byte-wise `chr(Int(c))` turns
# every byte >= 0x80 into the two-byte form of its numeric value ("é", C3 A9,
# would come back as "Ã©", C3 83 C2 A9) — well-formed UTF-8, so nothing would
# raise. Each non-ASCII case below fails against such a decoder.
from std.testing import assert_equal, assert_raises, assert_true

from komira_azure_blob import (
    AzureBlobEntry,
    AzureListBlobsResult,
    AzureParsedError,
    parse_azure_error,
    parse_azure_list_blobs_result,
)


def _one_blob_body(name: String) -> String:
    """A minimal EnumerationResults carrying exactly one blob."""
    return String(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<EnumerationResults ServiceEndpoint="https://x.blob.core.windows.net/"'
        ' ContainerName="c">'
        "<Blobs><Blob><Name>"
    ) + name + String(
        "</Name><Properties>"
        "<Content-Length>7</Content-Length>"
        "<Etag>0x8D123</Etag>"
        "<Last-Modified>Thu, 01 Oct 2026 12:00:00 GMT</Last-Modified>"
        "<BlobType>BlockBlob</BlobType>"
        "</Properties></Blob></Blobs>"
        "<NextMarker />"
        "</EnumerationResults>"
    )


# -----------------------------------------------------------------------------
# Non-ASCII blob names — the corruption regression
# -----------------------------------------------------------------------------


def test_blob_name_accented() raises:
    """2-byte UTF-8. Was "cafÃ©/rÃ©sumÃ©.parquet"."""
    var expect = String("café/résumé.parquet")
    var r = parse_azure_list_blobs_result(_one_blob_body(expect))
    assert_equal(len(r.blobs), 1)
    assert_equal(r.blobs[0].name, expect)
    # 19 ASCII bytes + 3 two-byte accents = 22. The bug produced 25.
    assert_equal(r.blobs[0].name.byte_length(), 22)


def test_blob_name_cjk() raises:
    """3-byte UTF-8 — each char became 6 bytes under the bug."""
    var expect = String("日本語/データ.parquet")
    var r = parse_azure_list_blobs_result(_one_blob_body(expect))
    assert_equal(r.blobs[0].name, expect)
    assert_equal(r.blobs[0].name.byte_length(), 27)


def test_blob_name_emoji_four_byte() raises:
    """4-byte UTF-8 — where a byte-vs-codepoint bug is most obvious.

    U+1F680 is F0 9F 9A 80; the bug expanded it to 8 bytes.
    """
    var expect = String("launch/🚀.parquet")
    var r = parse_azure_list_blobs_result(_one_blob_body(expect))
    assert_equal(r.blobs[0].name, expect)
    # "launch/" (7) + rocket (4) + ".parquet" (8) = 19.
    assert_equal(r.blobs[0].name.byte_length(), 19)


def test_blob_name_non_ascii_with_entities() raises:
    """A literal multi-byte char AND named entities in one name."""
    var r = parse_azure_list_blobs_result(
        _one_blob_body(String("café&amp;b/日本&lt;x&gt;.txt"))
    )
    assert_equal(r.blobs[0].name, String("café&b/日本<x>.txt"))


def test_blob_prefix_non_ascii() raises:
    """<BlobPrefix><Name> runs through the same decoder."""
    var body = String(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<EnumerationResults ContainerName="c">'
        "<Blobs><BlobPrefix><Name>données/</Name></BlobPrefix></Blobs>"
        "<NextMarker />"
        "</EnumerationResults>"
    )
    var r = parse_azure_list_blobs_result(body)
    assert_equal(len(r.blob_prefixes), 1)
    assert_equal(r.blob_prefixes[0], String("données/"))


def test_error_message_non_ascii() raises:
    """The <Error> path shares the decoder."""
    var body = String(
        '<?xml version="1.0" encoding="utf-8"?>'
        "<Error><Code>BlobNotFound</Code>"
        "<Message>Le blob « café » n'existe pas</Message></Error>"
    )
    var err = parse_azure_error(body)
    assert_equal(err.code, String("BlobNotFound"))
    assert_equal(err.message, String("Le blob « café » n'existe pas"))


# -----------------------------------------------------------------------------
# The five predefined entities still decode (the fix must not break them)
# -----------------------------------------------------------------------------


def test_predefined_entities_still_decode() raises:
    var r = parse_azure_list_blobs_result(
        _one_blob_body(String("a&amp;b/&lt;c&gt;/&quot;d&apos;e.txt"))
    )
    assert_equal(r.blobs[0].name, String("a&b/<c>/\"d'e.txt"))


# -----------------------------------------------------------------------------
# Numeric character references — where chr() legitimately belongs.
#
# `&#233;` genuinely IS a codepoint and DOES need UTF-8 encoding. The pre-fix
# decoder did not decode these at all (its docstring declared them out of
# scope); delegating to the general codec gains them.
# -----------------------------------------------------------------------------


def test_numeric_char_ref_decimal() raises:
    var r = parse_azure_list_blobs_result(
        _one_blob_body(String("caf&#233;.txt"))
    )
    assert_equal(r.blobs[0].name, String("café.txt"))


def test_numeric_char_ref_hex() raises:
    var r = parse_azure_list_blobs_result(
        _one_blob_body(String("caf&#xE9;.txt"))
    )
    assert_equal(r.blobs[0].name, String("café.txt"))


def test_numeric_char_ref_four_byte() raises:
    var r = parse_azure_list_blobs_result(
        _one_blob_body(String("go&#x1F680;.txt"))
    )
    assert_equal(r.blobs[0].name, String("go🚀.txt"))
    # "go" (2) + rocket (4) + ".txt" (4) = 10.
    assert_equal(r.blobs[0].name.byte_length(), 10)


def test_malformed_reference_is_refused() raises:
    """A bare '&' is not well-formed XML (Azure escapes it as `&amp;`), so
    the body is refused with the reader's reason rather than guessed at."""
    with assert_raises(
        contains=(
            "Azure XML: List Blobs body is not well-formed XML: xml: undeclared"
            " entity or malformed reference (only &amp; &lt; &gt; &quot; &apos;"
            " and character references exist without a DTD) at byte 147"
        )
    ):
        _ = parse_azure_list_blobs_result(_one_blob_body(String("a&b&#c&#12.txt")))


# -----------------------------------------------------------------------------
# ASCII sanity — the shape parse itself still works
# -----------------------------------------------------------------------------


def test_plain_blob_fields() raises:
    var r = parse_azure_list_blobs_result(_one_blob_body(String("a/b.parquet")))
    assert_equal(len(r.blobs), 1)
    assert_equal(r.blobs[0].name, String("a/b.parquet"))
    assert_equal(r.blobs[0].size, Int64(7))
    assert_equal(r.blobs[0].etag, String("0x8D123"))
    assert_equal(r.blobs[0].blob_type, String("BlockBlob"))


def test_empty_body_raises() raises:
    with assert_raises():
        var _ = parse_azure_list_blobs_result(String(""))


def test_container_name_attribute_is_read() raises:
    """`AzureListBlobsResult.container` is the root's ContainerName
    attribute."""
    var r = parse_azure_list_blobs_result(_one_blob_body(String("a/b.parquet")))
    assert_equal(r.container, String("c"))


def _root_with(attrs: String) -> String:
    return (
        String('<?xml version="1.0" encoding="utf-8"?><EnumerationResults ')
        + attrs
        + String("><Blobs></Blobs><NextMarker /></EnumerationResults>")
    )


def test_container_attribute_entities_are_decoded() raises:
    """The five predefined entities and character references decode in an
    attribute value; `&amp;` is the one a container name never needs but an
    endpoint URL with a query does."""
    var r = parse_azure_list_blobs_result(
        _root_with(
            String(
                'ServiceEndpoint="https://x.blob.core.windows.net/?a=1&amp;b=2"'
                ' ContainerName="c&amp;d&lt;&gt;&quot;&apos;&#38;&#x41;"'
            )
        )
    )
    assert_equal(r.container, String("c&d<>\"'&A"))


def test_container_attribute_single_quoted() raises:
    """XML allows either quote; a double quote inside single quotes is a
    literal character."""
    var r = parse_azure_list_blobs_result(
        _root_with(String("ContainerName='my\"container' ServiceEndpoint='x'"))
    )
    assert_equal(r.container, String('my"container'))


def test_container_attribute_absent_is_empty() raises:
    var r = parse_azure_list_blobs_result(_root_with(String('ServiceEndpoint="x"')))
    assert_equal(r.container, String(""))


def test_container_attribute_is_the_roots_only() raises:
    """A ContainerName attribute on a nested element is not the root's."""
    var r = parse_azure_list_blobs_result(
        String(
            '<EnumerationResults><Blobs><Blob ContainerName="nested"><Name>n</Name>'
            "</Blob></Blobs><NextMarker /></EnumerationResults>"
        )
    )
    assert_equal(r.container, String(""))
    assert_equal(len(r.blobs), 1)
    assert_equal(r.blobs[0].name, String("n"))


def test_other_root_is_refused() raises:
    with assert_raises(
        contains="Azure XML: missing <EnumerationResults> root (got <Error>)"
    ):
        _ = parse_azure_list_blobs_result(
            String("<Error><Code>X</Code></Error>")
        )


def main() raises:
    # Non-ASCII regression guard.
    test_blob_name_accented()
    test_blob_name_cjk()
    test_blob_name_emoji_four_byte()
    test_blob_name_non_ascii_with_entities()
    test_blob_prefix_non_ascii()
    test_error_message_non_ascii()
    # Predefined entities.
    test_predefined_entities_still_decode()
    # Numeric character references.
    test_numeric_char_ref_decimal()
    test_numeric_char_ref_hex()
    test_numeric_char_ref_four_byte()
    test_malformed_reference_is_refused()
    # ASCII sanity.
    test_plain_blob_fields()
    test_empty_body_raises()
    # The root's attributes.
    test_container_name_attribute_is_read()
    test_container_attribute_entities_are_decoded()
    test_container_attribute_single_quoted()
    test_container_attribute_absent_is_empty()
    test_container_attribute_is_the_roots_only()
    test_other_root_is_refused()
    print("OK — test_azure_xml (19 tests)")
