# The Azure arm's URLs and endpoints, as values: nothing is dialed.
#
# Rows:
#  * parse_azure_url, accepted: az://, abfs:// and abfss:// with the
#    container as the authority (no account, no endpoint named); Hadoop
#    ABFS's container@account.dfs.core.windows.net (and .blob.); DuckDB's
#    az://account.blob.core.windows.net/container/...; the Blob service's
#    https://account.blob.core.windows.net/container/...; an emulator's
#    path-style http://host:port/account/container/...; the scheme and the
#    host compared case-insensitively; $web as a container; an empty path;
#    DuckDB's abfss://account.dfs.core.windows.net/filesystem/... form.
#  * parse_azure_url, refused by exact message: another scheme, no scheme,
#    no container, a container or account name Azure does not allow, an abfs
#    host that is not an Azure storage host, an https host that is not a
#    blob host, plaintext http:// to Azure's own host (in any letter case,
#    with or without a port), an http:// URL that is
#    not path-style, and a query (a SAS token pasted into the URL), whose
#    refusal does not echo the token.
#  * parse_azure_url, encoded paths: the https:// resource URI's, the
#    http:// emulator URL's and Hadoop container@host form's paths are
#    percent-decoded once (year%3D2024 is year=2024), az:// and DuckDB's
#    host-first form are taken as written, and a bad escape (on https://,
#    abfs:// and http://) or a decoded path that is not UTF-8 is refused.
#  * the decoder: lowercase hex escapes decode as uppercase ones do; an
#    overlong lead, a surrogate, a bad continuation byte, a code point above
#    U+10FFFF and a truncated sequence are each refused by exact message.
#  * azure_arm_config_for_url: a URL naming no account or endpoint takes the
#    configuration's; one naming the configured endpoint (scheme and host
#    case-insensitive, a trailing / ignored) uses it; a different account,
#    an endpoint other than the configured one ("" is Azure's own, so a URL
#    naming an emulator or any plaintext host is refused against it), or no
#    account anywhere is refused.
#  * azure_endpoint_is_plaintext and azure_config_for: "" is Azure's own
#    https endpoint, virtual-hosted; http:// is plaintext and https:// TLS,
#    case-insensitively; the host and port land in AzureConfig; another
#    scheme, a path, no host, a port outside 1..65535, no account, an
#    account name Azure does not allow, and path-style without an endpoint
#    are refused by exact message.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_fs_registry import (
    AzureArmConfig,
    AzureUrl,
    azure_arm_config_for_url,
    azure_config_for,
    azure_endpoint_is_plaintext,
    parse_azure_url,
)


def _row(
    url: String,
    account: String,
    container: String,
    path: String,
    names_endpoint: Bool,
    endpoint: String,
    path_style: Bool,
) raises:
    var u = parse_azure_url(url)
    assert_equal(u.account, account, url)
    assert_equal(u.container, container, url)
    assert_equal(u.path, path, url)
    assert_equal(u.names_endpoint, names_endpoint, url)
    assert_equal(u.endpoint, endpoint, url)
    assert_equal(u.path_style, path_style, url)


def test_accepted_urls() raises:
    _row("az://lake/data/a.parquet", "", "lake", "data/a.parquet", False, "", False)
    _row("AZ://lake", "", "lake", "", False, "", False)
    _row("az://lake/", "", "lake", "", False, "", False)
    _row("abfs://lake/x/y", "", "lake", "x/y", False, "", False)
    _row("abfss://lake/x", "", "lake", "x", False, "", False)
    _row(
        "abfss://lake@myacct.dfs.core.windows.net/x/y.parquet",
        "myacct", "lake", "x/y.parquet", True, "", False,
    )
    _row("abfs://lake@MyAcct.Blob.Core.Windows.Net/x", "myacct", "lake", "x", True, "", False)
    _row("az://lake@myacct.blob.core.windows.net/x", "myacct", "lake", "x", True, "", False)
    _row("az://myacct.blob.core.windows.net/lake/x", "myacct", "lake", "x", True, "", False)
    _row(
        "https://myacct.blob.core.windows.net/lake/data/a.parquet",
        "myacct", "lake", "data/a.parquet", True, "", False,
    )
    _row("HTTPS://myacct.blob.core.windows.net/lake", "myacct", "lake", "", True, "", False)
    _row(
        "http://127.0.0.1:10000/devstoreaccount1/lake/k.bin",
        "devstoreaccount1", "lake", "k.bin", True, "http://127.0.0.1:10000", True,
    )
    _row("az://$web/index.html", "", "$web", "index.html", False, "", False)
    _row("abfss://myacct.dfs.core.windows.net/lake/x/y", "myacct", "lake", "x/y", True, "", False)


def test_encoded_paths() raises:
    # The https:// resource URI, the http:// emulator URL and Hadoop's
    # abfs[s]://container@host are percent-encoded and decoded once here (komira_azure_blob encodes the
    # blob name again on the wire); az:// and DuckDB's host-first form are
    # taken as written.
    _row(
        "https://myacct.blob.core.windows.net/lake/year%3D2024/a.parquet",
        "myacct", "lake", "year=2024/a.parquet", True, "", False,
    )
    _row(
        "abfss://lake@myacct.dfs.core.windows.net/a%20b/%C3%A9.bin",
        "myacct", "lake", "a b/é.bin", True, "", False,
    )
    _row(
        "http://127.0.0.1:10000/devstoreaccount1/lake/year%3D2024/a",
        "devstoreaccount1", "lake", "year=2024/a", True, "http://127.0.0.1:10000", True,
    )
    _row("az://lake/year%3D2024/a", "", "lake", "year%3D2024/a", False, "", False)
    _row(
        "az://lake@myacct.blob.core.windows.net/year%3D2024",
        "myacct", "lake", "year%3D2024", True, "", False,
    )
    _row(
        "abfss://myacct.dfs.core.windows.net/lake/year%3D2024",
        "myacct", "lake", "year%3D2024", True, "", False,
    )
    with assert_raises(
        contains="fs_registry: an Azure URL's path has a '%' not followed by two hex digits, got 'https://myacct.blob.core.windows.net/lake/a%2'"
    ):
        _ = parse_azure_url("https://myacct.blob.core.windows.net/lake/a%2")
    with assert_raises(
        contains="fs_registry: an Azure URL's path has a '%' not followed by two hex digits, got 'abfs://lake@myacct.blob.core.windows.net/a%2zb'"
    ):
        _ = parse_azure_url("abfs://lake@myacct.blob.core.windows.net/a%2zb")
    with assert_raises(
        contains="fs_registry: an Azure URL's decoded path is not UTF-8, got 'https://myacct.blob.core.windows.net/lake/a%FF'"
    ):
        _ = parse_azure_url("https://myacct.blob.core.windows.net/lake/a%FF")
    with assert_raises(
        contains="fs_registry: an Azure URL's path has a '%' not followed by two hex digits, got 'http://127.0.0.1:10000/devstoreaccount1/lake/a%G0'"
    ):
        _ = parse_azure_url("http://127.0.0.1:10000/devstoreaccount1/lake/a%G0")


comptime _UTF8_MSG = "fs_registry: an Azure URL's decoded path is not UTF-8, got '"
comptime _BLOB = "https://myacct.blob.core.windows.net/lake/"


def test_decoder_rules() raises:
    # Lowercase hex is the same escape as uppercase (RFC 3986 section 2.1).
    _row(_BLOB + "%c3%a9.bin", "myacct", "lake", "é.bin", True, "", False)
    _row(_BLOB + "a%3d%7E", "myacct", "lake", "a=~", True, "", False)
    # RFC 3629: each malformed sequence is refused, naming the URL.
    # Overlong two-byte lead (C0 AF is an overlong '/').
    with assert_raises(contains=_UTF8_MSG + _BLOB + "%C0%AF'"):
        _ = parse_azure_url(_BLOB + "%C0%AF")
    # A UTF-16 surrogate (U+D800) encoded as ED A0 80.
    with assert_raises(contains=_UTF8_MSG + _BLOB + "%ED%A0%80'"):
        _ = parse_azure_url(_BLOB + "%ED%A0%80")
    # A three-byte sequence whose third byte is not a continuation byte.
    with assert_raises(contains=_UTF8_MSG + _BLOB + "%E1%80%41'"):
        _ = parse_azure_url(_BLOB + "%E1%80%41")
    # U+110000, above U+10FFFF.
    with assert_raises(contains=_UTF8_MSG + _BLOB + "%F4%90%80%80'"):
        _ = parse_azure_url(_BLOB + "%F4%90%80%80")
    # A two-byte lead with nothing after it.
    with assert_raises(contains=_UTF8_MSG + _BLOB + "a%C3'"):
        _ = parse_azure_url(_BLOB + "a%C3")


comptime _SCHEME_MSG = (
    "fs_registry: an Azure URL must start with az://, abfs://, abfss://,"
    " https:// or http://, got '"
)
comptime _CONTAINER_RULE = (
    "' is not an Azure container name (3 to 63 lowercase letters, digits and"
    " single hyphens, starting and ending with a letter or digit, or $root,"
    " $web, $logs)"
)


def test_refused_urls() raises:
    with assert_raises(contains=_SCHEME_MSG + "s3://lake/x'"):
        _ = parse_azure_url("s3://lake/x")
    with assert_raises(contains=_SCHEME_MSG + "lake/x'"):
        _ = parse_azure_url("lake/x")
    with assert_raises(contains="fs_registry: an Azure URL must name a container, got 'az:///x'"):
        _ = parse_azure_url("az:///x")
    with assert_raises(
        contains="fs_registry: an Azure URL must name a container, got 'https://myacct.blob.core.windows.net/'"
    ):
        _ = parse_azure_url("https://myacct.blob.core.windows.net/")
    with assert_raises(contains="fs_registry: 'Lake" + _CONTAINER_RULE):
        _ = parse_azure_url("az://Lake/x")
    with assert_raises(contains="fs_registry: 'a--b" + _CONTAINER_RULE):
        _ = parse_azure_url("az://a--b/x")
    with assert_raises(contains="fs_registry: 'ab" + _CONTAINER_RULE):
        _ = parse_azure_url("abfs://ab/x")
    with assert_raises(
        contains="fs_registry: an Azure URL's host must be <account>.blob.core.windows.net or <account>.dfs.core.windows.net, got 'myacct.example.com'"
    ):
        _ = parse_azure_url("abfss://lake@myacct.example.com/x")
    with assert_raises(
        contains="fs_registry: an https:// Azure URL's host must be <account>.blob.core.windows.net, got 'myacct.dfs.core.windows.net'"
    ):
        _ = parse_azure_url("https://myacct.dfs.core.windows.net/lake/x")
    with assert_raises(
        contains="fs_registry: an https:// Azure URL's host must be <account>.blob.core.windows.net, got 'example.com'"
    ):
        _ = parse_azure_url("https://example.com/lake/x")
    with assert_raises(
        contains="fs_registry: 'my_acct' is not an Azure storage account name (3 to 24 lowercase letters and digits)"
    ):
        _ = parse_azure_url("https://My_Acct.blob.core.windows.net/lake/x")
    with assert_raises(
        contains="fs_registry: an http:// Azure URL names Azure's own endpoint 'myacct.blob.core.windows.net'; plaintext is only for an emulator endpoint, use https://"
    ):
        _ = parse_azure_url("http://myacct.blob.core.windows.net/lake/x")
    with assert_raises(
        contains="fs_registry: an http:// Azure URL names Azure's own endpoint 'MyAcct.Blob.Core.Windows.Net'; plaintext is only for an emulator endpoint, use https://"
    ):
        _ = parse_azure_url("http://MyAcct.Blob.Core.Windows.Net/lake/x")
    with assert_raises(
        contains="fs_registry: an http:// Azure URL names Azure's own endpoint 'myacct.blob.core.windows.net'; plaintext is only for an emulator endpoint, use https://"
    ):
        _ = parse_azure_url("http://myacct.blob.core.windows.net:80/lake/x")
    with assert_raises(
        contains="fs_registry: an http:// Azure URL is path-style, http://<host>[:<port>]/<account>/<container>/<path>, got 'http://127.0.0.1:10000/devstoreaccount1'"
    ):
        _ = parse_azure_url("http://127.0.0.1:10000/devstoreaccount1")
    comptime query_msg = (
        "fs_registry: an Azure URL must not carry a query or fragment (a SAS"
        " token is a credential, not part of the URL)"
    )
    with assert_raises(contains=query_msg):
        _ = parse_azure_url("https://myacct.blob.core.windows.net/lake/x?sv=1&sig=SECRETVALUE")
    with assert_raises(contains=query_msg):
        _ = parse_azure_url("az://lake/x#frag")
    try:
        _ = parse_azure_url("https://myacct.blob.core.windows.net/lake/x?sv=1&sig=SECRETVALUE")
    except e:
        assert_false(String(e).find("SECRETVALUE") >= 0, String(e))


def test_arm_config_for_url() raises:
    var emu = AzureArmConfig(
        account=String("devstoreaccount1"), endpoint=String("http://127.0.0.1:10000"), path_style=True
    )
    var c = azure_arm_config_for_url(parse_azure_url("az://lake/x"), emu)
    assert_equal(c.account, "devstoreaccount1")
    assert_equal(c.endpoint, "http://127.0.0.1:10000")
    assert_true(c.path_style)

    var own = azure_arm_config_for_url(
        parse_azure_url("https://myacct.blob.core.windows.net/lake/x"), AzureArmConfig.azure("myacct")
    )
    assert_equal(own.account, "myacct")
    assert_equal(own.endpoint, "")
    assert_false(own.path_style)

    var from_url = azure_arm_config_for_url(
        parse_azure_url("http://127.0.0.1:10000/devstoreaccount1/lake/k"),
        AzureArmConfig(account=String(""), endpoint=String("HTTP://127.0.0.1:10000/"), path_style=True),
    )
    assert_equal(from_url.account, "devstoreaccount1")
    assert_equal(from_url.endpoint, "HTTP://127.0.0.1:10000/")
    assert_true(from_url.path_style)

    # "" is Azure's own endpoint, never "unset": a URL naming another
    # endpoint (here plaintext) does not override it, configured account or
    # not, so the credential never follows the URL to that host.
    with assert_raises(
        contains="fs_registry: the Azure URL names endpoint 'http://evil.example:80' and the configured endpoint is 'Azure's own'"
    ):
        _ = azure_arm_config_for_url(
            parse_azure_url("http://evil.example:80/myacct/lake/x"), AzureArmConfig.azure("myacct")
        )
    with assert_raises(
        contains="fs_registry: the Azure URL names endpoint 'http://127.0.0.1:10000' and the configured endpoint is 'Azure's own'"
    ):
        _ = azure_arm_config_for_url(
            parse_azure_url("http://127.0.0.1:10000/devstoreaccount1/lake/k"),
            AzureArmConfig(account=String(""), endpoint=String(""), path_style=False),
        )
    with assert_raises(
        contains="fs_registry: the Azure URL names endpoint 'http://127.0.0.1:10001' and the configured endpoint is 'http://127.0.0.1:10000'"
    ):
        _ = azure_arm_config_for_url(
            parse_azure_url("http://127.0.0.1:10001/devstoreaccount1/lake/k"), emu
        )

    with assert_raises(
        contains="fs_registry: the Azure URL names account 'myacct' and the configured account is 'otheracct'"
    ):
        _ = azure_arm_config_for_url(
            parse_azure_url("https://myacct.blob.core.windows.net/lake/x"),
            AzureArmConfig.azure("otheracct"),
        )
    with assert_raises(
        contains="fs_registry: the Azure URL names no account and none is configured"
    ):
        _ = azure_arm_config_for_url(
            parse_azure_url("az://lake/x"),
            AzureArmConfig(account=String(""), endpoint=String(""), path_style=False),
        )
    with assert_raises(
        contains="fs_registry: the Azure URL names endpoint 'Azure's own' and the configured endpoint is 'http://127.0.0.1:10000'"
    ):
        _ = azure_arm_config_for_url(
            parse_azure_url("https://devstoreaccount1.blob.core.windows.net/lake/x"), emu
        )


def test_endpoint_scheme() raises:
    assert_false(azure_endpoint_is_plaintext(""))
    assert_false(azure_endpoint_is_plaintext("https://blob.example.test"))
    assert_false(azure_endpoint_is_plaintext("HTTPS://blob.example.test"))
    assert_true(azure_endpoint_is_plaintext("http://127.0.0.1:10000"))
    assert_true(azure_endpoint_is_plaintext("Http://127.0.0.1:10000"))
    with assert_raises(
        contains="fs_registry: an Azure endpoint must start with http:// or https://, got 'ftp://x'"
    ):
        _ = azure_endpoint_is_plaintext("ftp://x")
    with assert_raises(
        contains="fs_registry: an Azure endpoint must start with http:// or https://, got 'HTTPX://x'"
    ):
        _ = azure_endpoint_is_plaintext("HTTPX://x")


def _cfg(account: String, endpoint: String, path_style: Bool) -> AzureArmConfig:
    return AzureArmConfig(account=account, endpoint=endpoint, path_style=path_style)


def test_azure_config_for() raises:
    var own = azure_config_for(AzureArmConfig.azure("myacct"))
    assert_equal(own.account, "myacct")
    assert_equal(own.endpoint_scheme, "https")
    assert_equal(own.endpoint_host, "myacct.blob.core.windows.net")
    assert_equal(Int(own.endpoint_port), 0)
    assert_false(own.path_style)

    var emu = azure_config_for(_cfg("devstoreaccount1", "http://127.0.0.1:10000", True))
    assert_equal(emu.endpoint_scheme, "http")
    assert_equal(emu.endpoint_host, "127.0.0.1")
    assert_equal(Int(emu.endpoint_port), 10000)
    assert_true(emu.path_style)

    var tls = azure_config_for(_cfg("myacct", "HTTPS://blob.example.test/", False))
    assert_equal(tls.endpoint_scheme, "https")
    assert_equal(tls.endpoint_host, "blob.example.test")
    assert_equal(Int(tls.endpoint_port), 0)
    assert_false(tls.path_style)

    with assert_raises(
        contains="fs_registry: an Azure endpoint must start with http:// or https://, got 'ftp://h'"
    ):
        _ = azure_config_for(_cfg("myacct", "ftp://h", True))
    with assert_raises(
        contains="fs_registry: an Azure endpoint's port must be 1 to 65535, got 'http://h:0'"
    ):
        _ = azure_config_for(_cfg("myacct", "http://h:0", True))
    with assert_raises(
        contains="fs_registry: an Azure endpoint's port must be 1 to 65535, got 'http://h:70000'"
    ):
        _ = azure_config_for(_cfg("myacct", "http://h:70000", True))
    with assert_raises(
        contains="fs_registry: an Azure endpoint's port must be 1 to 65535, got 'http://h:1x'"
    ):
        _ = azure_config_for(_cfg("myacct", "http://h:1x", True))
    with assert_raises(contains="fs_registry: an Azure endpoint names no host, got 'http://:10'"):
        _ = azure_config_for(_cfg("myacct", "http://:10", True))
    with assert_raises(
        contains="fs_registry: an Azure endpoint is scheme://host[:port] with no path, got 'http://h/p'"
    ):
        _ = azure_config_for(_cfg("myacct", "http://h/p", True))
    with assert_raises(contains="fs_registry: an Azure arm needs an account name"):
        _ = azure_config_for(_cfg("", "", False))
    with assert_raises(
        contains="fs_registry: 'My-Acct' is not an Azure storage account name (3 to 24 lowercase letters and digits)"
    ):
        _ = azure_config_for(_cfg("My-Acct", "", False))
    with assert_raises(
        contains="fs_registry: Azure's own endpoint is virtual-hosted; path-style addressing needs an endpoint"
    ):
        _ = azure_config_for(_cfg("myacct", "", True))


def main() raises:
    test_accepted_urls()
    test_encoded_paths()
    test_decoder_rules()
    test_refused_urls()
    test_arm_config_for_url()
    test_endpoint_scheme()
    test_azure_config_for()
    print("OK")
