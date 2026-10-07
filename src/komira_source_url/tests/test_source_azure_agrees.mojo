# Every Azure-shaped URL the mapping sends to Azure is one komira_azure_blob's
# parse_azure_url reads, and every one parse_azure_url reads over https://,
# az:// or abfs[s]:// the mapping sends to Azure. Without this, a surface
# would put FS_SCHEME_AZURE into a plan for a URL the Azure package then
# refuses (or refuse a URL the Azure package serves).
#
# The rows name a valid account and container throughout: the account and
# container names, and what follows the host, are parse_azure_url's syntax
# alone (the mapping reads only the scheme and, for https://, the host). The
# rows cover each Azure form (az://, abfs://, abfss:// with no host, with
# container@host on a .dfs. and a .blob. host, and with the host first), the
# Blob service's https:// host in either letter case, and the https:// hosts
# both must refuse: a .dfs. host (abfs[s]:// names that endpoint), a port,
# user information, another host, the bare service host, a lookalike suffix
# and an Azure host hidden in the user information. For each row, the
# mapping returns FS_SCHEME_AZURE exactly when parse_azure_url accepts it,
# and the accepted count is pinned so a row cannot drop out unnoticed.
#
# The one intended difference: an emulator's path-style http:// URL, which
# parse_azure_url reads and the mapping refuses (a plaintext endpoint is the
# surface's configuration, not a prefix).
from std.testing import assert_equal, assert_false, assert_true

from komira_azure_blob import parse_azure_url
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_AZURE
from komira_source_url import source_scheme_for_url


def _mapping_says_azure(url: String) -> Bool:
    try:
        return source_scheme_for_url(url) == FS_SCHEME_AZURE
    except:
        return False


def _parser_reads(url: String) -> Bool:
    try:
        _ = parse_azure_url(url)
        return True
    except:
        return False


def test_the_mapping_and_the_parser_agree() raises:
    var urls: List[String] = [
        "az://lake/a.parquet",
        "abfs://lake/a.parquet",
        "abfss://lake/a.parquet",
        "ABFSS://lake@myacct.dfs.core.windows.net/a.parquet",
        "abfss://lake@myacct.blob.core.windows.net/a.parquet",
        "az://lake@myacct.dfs.core.windows.net/a.parquet",
        "abfss://myacct.dfs.core.windows.net/lake/a.parquet",
        "abfs://myacct.blob.core.windows.net/lake/a.parquet",
        "https://myacct.blob.core.windows.net/lake/a.parquet",
        "HTTPS://MyAcct.Blob.Core.Windows.Net/lake/a.parquet",
        "https://myacct.dfs.core.windows.net/lake/a.parquet",
        "HTTPS://MyAcct.DFS.Core.Windows.Net/lake/a.parquet",
        "https://myacct.blob.core.windows.net:443/lake/a.parquet",
        "https://u@myacct.blob.core.windows.net/lake/a.parquet",
        "https://a.b.blob.core.windows.net/lake/a.parquet",
        "https://myacct.dfs.core.windows.net:443/lake/a.parquet",
        "https://example.com/lake/a.parquet",
        "https://blob.core.windows.net/lake/a.parquet",
        "https://myacct.blob.core.windows.net.example.com/lake/a.parquet",
        "https://myacct.blob.core.windows.net@example.com/lake/a.parquet",
    ]
    var accepted = 0
    for i in range(len(urls)):
        var url = urls[i]
        var mapped = _mapping_says_azure(url)
        var parsed = _parser_reads(url)
        assert_equal(
            mapped,
            parsed,
            "source_scheme_for_url and parse_azure_url disagree on '" + url + "'",
        )
        if parsed:
            accepted += 1
    assert_equal(accepted, 10)


def test_an_emulator_url_is_the_one_difference() raises:
    var url = String("http://127.0.0.1:10000/devstoreaccount1/lake/a.parquet")
    assert_true(_parser_reads(url))
    assert_false(_mapping_says_azure(url))


def main() raises:
    test_the_mapping_and_the_parser_agree()
    test_an_emulator_url_is_the_one_difference()
    print("OK")
