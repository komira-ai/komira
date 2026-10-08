# source_scheme_for_url: the source a URL names, by its prefix.
#
# Rows:
#  * a bare path, relative or absolute, and file:// are FS_SCHEME_FILE.
#  * s3:// and s3a:// are FS_SCHEME_S3; gs:// and gcs:// FS_SCHEME_GCS;
#    az://, abfs:// and abfss:// FS_SCHEME_AZURE; the scheme in any letter
#    case maps the same way (S3://, Gs://, ABFSS://, FILE://).
#  * https:// is FS_SCHEME_AZURE on an <account>.blob.core.windows.net host,
#    in any letter case, and with nothing after the host.
#  * text before "://" that is not scheme-shaped (a path, a space, a leading
#    digit or underscore) is a bare path, FS_SCHEME_FILE; a scheme-shaped
#    prefix using '+', '-' and '.' is a scheme, refused by name.
#  * refused by exact message: an empty URL; an empty scheme; another scheme
#    (ftp://, s3n://, named lowercase); an https:// URL on any other host,
#    including an <account>.dfs.core.windows.net host (abfs[s]:// names
#    that endpoint), the bare service host (no account label), a host that
#    only starts with an Azure host, and one whose Azure host is in its user
#    information; an Azure Blob host with a port or user information; every
#    http:// URL, an Azure host's included.
#  * a refusal does not echo the URL: a query's token, a path and user
#    information never appear in the message, whatever precedes "://".
from std.testing import assert_equal, assert_false, assert_raises

from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
)
from komira_source_url import source_scheme_for_url


def _refusal(url: String) raises -> String:
    try:
        _ = source_scheme_for_url(url)
    except e:
        return String(e)
    raise Error("source_scheme_for_url accepted '" + url + "'")


def test_local() raises:
    assert_equal(source_scheme_for_url("data/a.parquet"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("/data/a.parquet"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("a.parquet"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("file:///data/a.parquet"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("FILE:///data/a.parquet"), FS_SCHEME_FILE)


def test_object_stores() raises:
    assert_equal(source_scheme_for_url("s3://lake/a.parquet"), FS_SCHEME_S3)
    assert_equal(source_scheme_for_url("s3a://lake/a.parquet"), FS_SCHEME_S3)
    assert_equal(source_scheme_for_url("S3://lake/a.parquet"), FS_SCHEME_S3)
    assert_equal(source_scheme_for_url("gs://lake/a.parquet"), FS_SCHEME_GCS)
    assert_equal(source_scheme_for_url("gcs://lake/a.parquet"), FS_SCHEME_GCS)
    assert_equal(source_scheme_for_url("Gs://lake/a.parquet"), FS_SCHEME_GCS)
    assert_equal(source_scheme_for_url("az://lake/a.parquet"), FS_SCHEME_AZURE)
    assert_equal(source_scheme_for_url("abfs://lake/a.parquet"), FS_SCHEME_AZURE)
    assert_equal(source_scheme_for_url("abfss://lake/a.parquet"), FS_SCHEME_AZURE)
    assert_equal(
        source_scheme_for_url("ABFSS://lake@myacct.dfs.core.windows.net/a.parquet"),
        FS_SCHEME_AZURE,
    )


def test_azure_https_hosts() raises:
    assert_equal(
        source_scheme_for_url("https://myacct.blob.core.windows.net/lake/a.parquet"),
        FS_SCHEME_AZURE,
    )
    assert_equal(
        source_scheme_for_url("HTTPS://MyAcct.Blob.Core.Windows.Net/lake/a"),
        FS_SCHEME_AZURE,
    )
    assert_equal(
        source_scheme_for_url("https://myacct.blob.core.windows.net"), FS_SCHEME_AZURE
    )


def test_refused() raises:
    with assert_raises(contains="source_url: an empty URL names no source"):
        _ = source_scheme_for_url("")
    with assert_raises(contains="source_url: a URL's scheme is empty"):
        _ = source_scheme_for_url("://lake/a")
    with assert_raises(contains="source_url: no source serves 'ftp://' URLs"):
        _ = source_scheme_for_url("ftp://files.example/a")
    with assert_raises(contains="source_url: no source serves 's3n://' URLs"):
        _ = source_scheme_for_url("S3N://lake/a")
    comptime azure_hint = (
        "' (an Azure Blob URL's host is <account>.blob.core.windows.net;"
        " abfs[s]:// names a .dfs. host)"
    )
    with assert_raises(
        contains="source_url: no source serves https:// URLs on host 'example.com" + azure_hint
    ):
        _ = source_scheme_for_url("https://example.com/a.parquet")
    with assert_raises(
        contains="source_url: no source serves https:// URLs on host 'myacct.dfs.core.windows.net" + azure_hint
    ):
        _ = source_scheme_for_url("https://MyAcct.dfs.core.windows.net/lake/a")
    comptime authority_refusal = (
        "source_url: an Azure Blob https:// URL's authority is the host alone,"
        " <account>.blob.core.windows.net, with no user information or port"
    )
    with assert_raises(contains=authority_refusal):
        _ = source_scheme_for_url("https://myacct.blob.core.windows.net:443/lake/a")
    with assert_raises(contains=authority_refusal):
        _ = source_scheme_for_url("https://u@myacct.blob.core.windows.net/lake/a")
    with assert_raises(
        contains="source_url: no source serves https:// URLs on host 'blob.core.windows.net" + azure_hint
    ):
        _ = source_scheme_for_url("https://blob.core.windows.net/lake/a")
    with assert_raises(
        contains="source_url: no source serves https:// URLs on host 'myacct.blob.core.windows.net.example.com" + azure_hint
    ):
        _ = source_scheme_for_url("https://myacct.blob.core.windows.net.example.com/a")
    with assert_raises(
        contains="source_url: no source serves https:// URLs on host 'example.com" + azure_hint
    ):
        _ = source_scheme_for_url("https://myacct.blob.core.windows.net@example.com/a")
    comptime http_refusal = (
        "source_url: an http:// URL names no source by its prefix; a plaintext"
        " endpoint is the surface's configuration"
    )
    with assert_raises(contains=http_refusal):
        _ = source_scheme_for_url("http://127.0.0.1:10000/devstoreaccount1/lake/a")
    with assert_raises(contains=http_refusal):
        _ = source_scheme_for_url("HTTP://myacct.blob.core.windows.net/lake/a")


def test_a_refusal_does_not_echo_the_url() raises:
    var e = _refusal("https://example.com/secret-path/a?sig=CANARY-TOKEN")
    assert_false(e.find("CANARY") >= 0, e)
    assert_false(e.find("secret-path") >= 0, e)
    e = _refusal("https://user:CANARY-PASSWORD@example.com/a")
    assert_false(e.find("CANARY") >= 0, e)
    assert_false(e.find("user") >= 0, e)
    e = _refusal("ftp://files.example/secret-path?sig=CANARY-TOKEN")
    assert_false(e.find("CANARY") >= 0, e)
    assert_false(e.find("secret-path") >= 0, e)
    e = _refusal("https://login1:CANARY-PASSWORD@myacct.blob.core.windows.net/a")
    assert_false(e.find("CANARY") >= 0, e)
    assert_false(e.find("login1") >= 0, e)
    e = _refusal("http://127.0.0.1:9000/secret-path?sig=CANARY-TOKEN")
    assert_false(e.find("CANARY") >= 0, e)
    assert_false(e.find("127.0.0.1") >= 0, e)


def test_a_path_before_a_separator_is_a_bare_path() raises:
    # Only a scheme-shaped prefix (RFC 3986: a letter, then letters, digits,
    # '+', '-' or '.') is a scheme; anything else before "://" is a path.
    assert_equal(source_scheme_for_url("/data/secret-path/x://y"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("data/x://y.parquet"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("my file://y"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("1s3://lake/a"), FS_SCHEME_FILE)
    assert_equal(source_scheme_for_url("_s3://lake/a"), FS_SCHEME_FILE)
    with assert_raises(contains="source_url: no source serves 'x-y+z.1://' URLs"):
        _ = source_scheme_for_url("X-Y+Z.1://lake/a")


def _assert_no_path_echo(url: String, path_part: String) raises:
    """Whatever `url` maps to, a refusal does not repeat `path_part`."""
    try:
        _ = source_scheme_for_url(url)
    except e:
        var msg = String(e)
        assert_false(msg.find(path_part) >= 0, msg)


def test_a_refusal_never_echoes_a_path() raises:
    _assert_no_path_echo("/data/secret-path/x://y", "secret-path")
    _assert_no_path_echo("data/secret-path:1://y", "secret-path")
    _assert_no_path_echo("ftp://files.example/secret-path", "secret-path")
    _assert_no_path_echo("S3N://lake/secret-path", "secret-path")
    _assert_no_path_echo("https://example.com/secret-path", "secret-path")
    _assert_no_path_echo("http://example.com/secret-path", "secret-path")


def main() raises:
    test_local()
    test_object_stores()
    test_azure_https_hosts()
    test_refused()
    test_a_refusal_does_not_echo_the_url()
    test_a_refusal_never_echoes_a_path()
    test_a_path_before_a_separator_is_a_bare_path()
    print("OK")
