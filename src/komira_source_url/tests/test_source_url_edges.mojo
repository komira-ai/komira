# source_scheme_for_url at the edges of each step it takes, every refusal
# compared to its whole message (test_source_url compares a substring, so a
# refusal that appended the rest of the URL would pass there).
#
# Rows:
#  * scheme shape (RFC 3986 section 3.1: ALPHA *( ALPHA / DIGIT / "+" / "-"
#    / "." )): every byte at each end of each allowed range and the byte
#    just past it, first and later in the prefix. An allowed prefix is a
#    scheme, refused by its lowercase name; any other is a bare path. The
#    empty prefix is not scheme-shaped (_is_scheme read directly: the URL
#    "://x" stops at the empty-scheme refusal before it).
#  * scheme names: each name the table lists maps in lower, upper and mixed
#    case, with and without text after "://"; each with its last letter
#    dropped or a letter added is refused (or is another listed name), and
#    the first "://" is the separator.
#  * the https:// authority ends at the first '/', '?' or '#' (first byte,
#    last byte, absent); the host is what follows the last '@', up to the
#    first ':', lowercase; the refusal names that host and nothing else.
#  * the Azure Blob host is one non-empty label before
#    .blob.core.windows.net: an empty label, a one-letter label, two labels,
#    a label glued to "blob", another top-level domain.
from std.testing import assert_equal, assert_false

from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
)
from komira_source_url import source_scheme_for_url
from komira_source_url.source_url import _is_scheme


comptime _HINT = (
    "' (an Azure Blob URL's host is <account>.blob.core.windows.net;"
    " abfs[s]:// names a .dfs. host)"
)
comptime _AUTHORITY = (
    "source_url: an Azure Blob https:// URL's authority is the host alone,"
    " <account>.blob.core.windows.net, with no user information or port"
)
comptime _HTTP = (
    "source_url: an http:// URL names no source by its prefix; a plaintext"
    " endpoint is the surface's configuration"
)


def _refusal(url: String) raises -> String:
    try:
        var code = source_scheme_for_url(url)
        return "accepted as code " + String(Int(code))
    except e:
        return String(e)


def _refused(url: String, want: String) raises:
    assert_equal(_refusal(url), want, "url '" + url + "'")


def _unserved(scheme: String) -> String:
    return "source_url: no source serves '" + scheme + "://' URLs"


def _no_host(host: String) -> String:
    return "source_url: no source serves https:// URLs on host '" + host + _HINT


def _maps(url: String, want: UInt8) raises:
    assert_equal(source_scheme_for_url(url), want, "url '" + url + "'")


def test_the_empty_prefix_is_not_a_scheme() raises:
    assert_false(_is_scheme(""))


def test_scheme_shape_first_byte() raises:
    # A letter at either end of either case range starts a scheme.
    _refused("A://x", _unserved("a"))
    _refused("Z://x", _unserved("z"))
    _refused("a://x", _unserved("a"))
    _refused("z://x", _unserved("z"))
    # The byte just outside each letter range, and a digit, '+', '-' or '.'
    # first, make the text a bare path.
    var paths: List[String] = ["@", "[", "`", "{", "0", "9", "+", "-", ".", "/", ","]
    for i in range(len(paths)):
        _maps(paths[i] + "x://y", FS_SCHEME_FILE)


def test_scheme_shape_later_bytes() raises:
    var allowed: List[String] = ["A", "Z", "a", "z", "0", "9", "+", "-", "."]
    var lowered: List[String] = ["a", "z", "a", "z", "0", "9", "+", "-", "."]
    for i in range(len(allowed)):
        # The allowed byte in the middle and as the last byte of the prefix.
        _refused("q" + allowed[i] + "q://y", _unserved("q" + lowered[i] + "q"))
        _refused("q" + allowed[i] + "://y", _unserved("q" + lowered[i]))
    var refused: List[String] = ["@", "[", "`", "{", "/", ":", ",", "*", " ", "_"]
    for i in range(len(refused)):
        _maps("q" + refused[i] + "q://y", FS_SCHEME_FILE)
        _maps("qq" + refused[i] + "://y", FS_SCHEME_FILE)


def test_scheme_names_in_every_case() raises:
    var names: List[String] = ["file", "s3", "s3a", "gs", "gcs", "az", "abfs", "abfss"]
    var upper: List[String] = ["FILE", "S3", "S3A", "GS", "GCS", "AZ", "ABFS", "ABFSS"]
    var mixed: List[String] = ["fIlE", "S3", "s3A", "gS", "GcS", "aZ", "AbFs", "aBfSs"]
    var codes: List[UInt8] = [
        FS_SCHEME_FILE,
        FS_SCHEME_S3,
        FS_SCHEME_S3,
        FS_SCHEME_GCS,
        FS_SCHEME_GCS,
        FS_SCHEME_AZURE,
        FS_SCHEME_AZURE,
        FS_SCHEME_AZURE,
    ]
    for i in range(len(names)):
        _maps(names[i] + "://lake/a", codes[i])
        _maps(upper[i] + "://lake/a", codes[i])
        _maps(mixed[i] + "://lake/a", codes[i])
        _maps(names[i] + "://", codes[i])
    # The first "://" separates: what follows is the source's own syntax.
    _maps("s3://lake/x://y", FS_SCHEME_S3)
    _maps("gs://a://b://c", FS_SCHEME_GCS)


def test_scheme_near_misses() raises:
    # A listed name with its last letter dropped or one letter added.
    var unlisted: List[String] = [
        "fil", "files", "s", "s3aa", "s3x", "g", "gss", "gc", "gcss",
        "a", "azz", "abf", "abfsss", "htt", "httpss",
    ]
    for i in range(len(unlisted)):
        _refused(unlisted[i] + "://lake/a", _unserved(unlisted[i]))
        _refused(unlisted[i].upper() + "://lake/a", _unserved(unlisted[i]))


def test_every_refusal_whole_message() raises:
    _refused("", "source_url: an empty URL names no source")
    _refused("://lake/a", "source_url: a URL's scheme is empty")
    _refused(":///", "source_url: a URL's scheme is empty")
    _refused("ftp://files.example/secret-path?sig=CANARY", _unserved("ftp"))
    _refused("http://example.com/secret-path?sig=CANARY", _HTTP)
    _refused("Http://user:CANARY@myacct.blob.core.windows.net/a", _HTTP)
    _refused("http://", _HTTP)
    _refused("https://example.com/secret-path?sig=CANARY", _no_host("example.com"))
    _refused("https://u@myacct.blob.core.windows.net/a?sig=CANARY", _AUTHORITY)
    _refused("https://myacct.blob.core.windows.net:443/a?sig=CANARY", _AUTHORITY)
    _refused("https://myacct.blob.core.windows.net:/a", _AUTHORITY)
    _refused("https://@myacct.blob.core.windows.net/a", _AUTHORITY)


def test_https_authority_ends_at_the_first_delimiter() raises:
    # Each delimiter, after the host and as the authority's last byte.
    _refused("https://example.com/a", _no_host("example.com"))
    _refused("https://example.com?sig=CANARY", _no_host("example.com"))
    _refused("https://example.com#CANARY", _no_host("example.com"))
    _refused("https://example.com/", _no_host("example.com"))
    _refused("https://example.com?", _no_host("example.com"))
    _refused("https://example.com#", _no_host("example.com"))
    # The first delimiter wins, whichever it is.
    _refused("https://example.com?q=/x#y", _no_host("example.com"))
    _refused("https://example.com#f?q/x", _no_host("example.com"))
    _refused("https://example.com/p?q#f", _no_host("example.com"))
    # No delimiter: the whole remainder is the authority.
    _refused("https://example.com", _no_host("example.com"))
    # A delimiter first: the authority, and so the host, is empty.
    _refused("https:///a", _no_host(""))
    _refused("https://?x", _no_host(""))
    _refused("https://#x", _no_host(""))
    _refused("https://", _no_host(""))
    # A query or fragment does not change an Azure Blob host's code.
    _maps("https://myacct.blob.core.windows.net?x", FS_SCHEME_AZURE)
    _maps("https://myacct.blob.core.windows.net#x", FS_SCHEME_AZURE)
    _maps("https://myacct.blob.core.windows.net/", FS_SCHEME_AZURE)


def test_https_host_of_the_authority() raises:
    # The host follows the LAST '@'.
    _refused("https://a@b@example.com/x", _no_host("example.com"))
    _refused("https://@example.com/x", _no_host("example.com"))
    _refused("https://example.com@/x", _no_host(""))
    _refused("https://u:p@example.com:8443/x", _no_host("example.com"))
    # The port starts at the FIRST ':' of the host.
    _refused("https://example.com:1:2/x", _no_host("example.com"))
    _refused("https://:443/x", _no_host(""))
    _refused("https://example.com:/x", _no_host("example.com"))
    # The host is named in ASCII lowercase; bytes outside A..Z are kept.
    _refused("https://AZaz@[`{.Example.COM/x", _no_host("[`{.example.com"))
    _refused("https://Q[Z]@.TEST/x", _no_host(".test"))
    _refused("https://A[Z]`{@.TEST/x", _no_host(".test"))
    _refused("https://A[Z]`{.TEST/x", _no_host("a[z]`{.test"))


def test_azure_blob_host_shape() raises:
    _maps("https://a.blob.core.windows.net/x", FS_SCHEME_AZURE)
    _maps("https://ab.blob.core.windows.net/x", FS_SCHEME_AZURE)
    _maps("https://MYACCT.BLOB.CORE.WINDOWS.NET", FS_SCHEME_AZURE)
    # No account label, two labels, a label glued to "blob", another TLD.
    _refused(
        "https://.blob.core.windows.net/x", _no_host(".blob.core.windows.net")
    )
    _refused(
        "https://a.b.blob.core.windows.net/x", _no_host("a.b.blob.core.windows.net")
    )
    _refused(
        "https://ab.blob.core.windows.net.x/x",
        _no_host("ab.blob.core.windows.net.x"),
    )
    _refused("https://myblob.core.windows.net/x", _no_host("myblob.core.windows.net"))
    _refused(
        "https://myacct.blob.core.windows.org/x",
        _no_host("myacct.blob.core.windows.org"),
    )
    _refused(
        "https://myacctxblob.core.windows.net/x",
        _no_host("myacctxblob.core.windows.net"),
    )
    # The authority's letter case does not matter; a user or port does.
    _maps("https://MyAcct.blob.core.windows.net/x", FS_SCHEME_AZURE)
    _refused("https://MyAcct.blob.core.windows.net:1/x", _AUTHORITY)
    _refused("https://U@MyAcct.blob.core.windows.net/x", _AUTHORITY)


def main() raises:
    test_the_empty_prefix_is_not_a_scheme()
    test_scheme_shape_first_byte()
    test_scheme_shape_later_bytes()
    test_scheme_names_in_every_case()
    test_scheme_near_misses()
    test_every_refusal_whole_message()
    test_https_authority_ends_at_the_first_delimiter()
    test_https_host_of_the_authority()
    test_azure_blob_host_shape()
    print("OK")
