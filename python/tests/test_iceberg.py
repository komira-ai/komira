"""Iceberg catalog and table sources (komira/_iceberg.py), with no library.

What `iceberg(...)`, `catalog.table(...)` and `SigV4(...)` hold and refuse
when they are built: the URI's scheme, host, user, password, query and
fragment; the warehouse; which credential fits a catalog with and without
SigV4 signing; the two values of access_delegation; how a table name splits
into namespace levels and a table, as a str or a tuple; `repr` with the
credential's secrets as `<set>`; no pickle or copy of a value that holds a
credential; and that building one never loads the library.

    test_iceberg.py
"""

import copy
import pickle

import komira
from komira import _native
from komira._credentials import (
    AMBIENT,
    ANONYMOUS,
    AwsKeys,
    AwsProfile,
    AzureSas,
    BearerToken,
    GcpToken,
    OAuth2ClientCredentials,
)
from komira._iceberg import ACCESS_DELEGATIONS, IcebergCatalog, IcebergTable, SigV4, iceberg

URI = "https://catalog.example.com/api/catalog"
NOT_COPIED = "a komira Iceberg catalog or table cannot be pickled or copied: it holds a credential"
NEEDS_NAMESPACE = 'a table name needs a namespace and a table, as "namespace.table" or ("namespace", "table")'
NEEDS_NAMESPACE_TUPLE = (
    'a table name tuple needs a namespace and a table, as "namespace.table" or ("namespace", "table")'
)
PLAIN_KINDS = (
    "a catalog takes komira.AMBIENT, komira.ANONYMOUS, a BearerToken or an OAuth2ClientCredentials "
    "credential, not {}; an AwsKeys credential needs signing=SigV4(...)"
)
SIGV4_KINDS = "a catalog signed with SigV4 takes komira.AMBIENT or an AwsKeys credential, not {}"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def expect(call, kind, message):
    e = raised(call)
    assert type(e) is kind, repr(e)
    assert str(e) == message, str(e)
    return e


def bearer():
    return BearerToken("catalog-etl", token="tok-SECRET")


def keys():
    return AwsKeys("glue-etl", key_id="AKIDSECRET", secret="KEYSECRET")


def test_defaults():
    c = iceberg(URI)
    assert type(c) is IcebergCatalog
    assert c.uri == URI
    assert c.warehouse is None
    assert c.credential is AMBIENT
    assert c.signing is None
    assert c.access_delegation == "vended-credentials"
    assert ACCESS_DELEGATIONS == ("vended-credentials", "none")
    assert repr(c) == "IcebergCatalog('{}', credential=komira.AMBIENT, access_delegation='vended-credentials')".format(
        URI
    )


def test_every_argument_held():
    cred = OAuth2ClientCredentials("catalog-etl", client_id="etl", client_secret="CLIENTSECRET")
    c = iceberg("http://127.0.0.1:8181", warehouse="prod", credential=cred, access_delegation="none")
    assert c.uri == "http://127.0.0.1:8181"
    assert c.warehouse == "prod"
    assert c.credential is cred
    assert c.access_delegation == "none"
    assert repr(c) == (
        "IcebergCatalog('http://127.0.0.1:8181', warehouse='prod', credential=OAuth2ClientCredentials("
        "'catalog-etl', client_id=<set>, client_secret=<set>, scope='catalog'), access_delegation='none')"
    )
    assert "SECRET" not in repr(c)


def test_the_constructor_is_iceberg():
    c = IcebergCatalog(URI, credential=ANONYMOUS)
    assert c.credential is ANONYMOUS
    assert repr(c) == repr(iceberg(URI, credential=ANONYMOUS))


def test_uri_kept_as_written():
    for uri in (
        "HTTPS://Catalog.Example.com",
        "https://catalog.example.com/",
        "http://[::1]:0/api",
        "http://catalog.example:1/a/b",
    ):
        assert iceberg(uri).uri == uri


def test_uri_refused():
    expect(lambda: iceberg(b"https://catalog.example"), TypeError, "uri must be a str, not bytes")
    expect(lambda: iceberg(None), TypeError, "uri must be a str, not NoneType")
    expect(lambda: iceberg(""), ValueError, "uri is empty")
    expect(lambda: iceberg("https://catalog.example/\na"), ValueError, "uri holds a control character")
    expect(lambda: iceberg("https://catalog.example/\x7f"), ValueError, "uri holds a control character")
    for uri in ("s3://bucket/warehouse", "file:///warehouse", "catalog.example.com", "/api/catalog"):
        expect(lambda: iceberg(uri), ValueError, "uri must be an http or https URI")
    expect(lambda: iceberg("https:///api"), ValueError, "uri has no host")
    expect(lambda: iceberg("https://catalog.example:notaport/"), ValueError, "uri is not a URI")
    expect(lambda: iceberg("https://catalog.example:99999/"), ValueError, "uri is not a URI")
    expect(lambda: iceberg("http://[catalog.example/"), ValueError, "uri is not a URI")
    for uri in ("https://etl:PASSWORD@h/api", "https://etl@h/api", "https://:PASSWORD@h/api"):
        e = expect(
            lambda: iceberg(uri),
            ValueError,
            "uri must not hold a user or a password: give the catalog a credential= instead",
        )
        assert "PASSWORD" not in str(e)
    for uri in (
        "https://catalog.example/api?token=x",
        "https://catalog.example/api#x",
        "https://catalog.example/api?",
        "https://catalog.example/api#",
    ):
        expect(lambda: iceberg(uri), ValueError, "uri must not hold a query or a fragment")


def test_warehouse_refused():
    expect(lambda: iceberg(URI, warehouse=1), TypeError, "warehouse= must be a str, not int")
    expect(lambda: iceberg(URI, warehouse=""), ValueError, "warehouse= is empty")
    expect(lambda: iceberg(URI, warehouse="a\tb"), ValueError, "warehouse= holds a control character")


def test_credentials_without_signing():
    for cred in (AMBIENT, ANONYMOUS, bearer(), OAuth2ClientCredentials("c", client_id="i", client_secret="s")):
        assert iceberg(URI, credential=cred).credential is cred
    expect(lambda: iceberg(URI, credential=keys()), ValueError, PLAIN_KINDS.format("AwsKeys"))
    expect(lambda: iceberg(URI, credential=AwsProfile("p", profile="x")), ValueError, PLAIN_KINDS.format("AwsProfile"))
    expect(lambda: iceberg(URI, credential=GcpToken("g", token="t")), ValueError, PLAIN_KINDS.format("GcpToken"))
    expect(
        lambda: iceberg(URI, credential=AzureSas("a", account="acct", sas="SASSECRET")),
        ValueError,
        PLAIN_KINDS.format("AzureSas"),
    )


def test_credentials_with_sigv4():
    signing = SigV4("us-east-1", "glue")
    for cred in (AMBIENT, keys()):
        c = iceberg(URI, credential=cred, signing=signing)
        assert c.credential is cred and c.signing is signing
    expect(
        lambda: iceberg(URI, credential=ANONYMOUS, signing=signing),
        ValueError,
        SIGV4_KINDS.format("komira.ANONYMOUS"),
    )
    expect(lambda: iceberg(URI, credential=bearer(), signing=signing), ValueError, SIGV4_KINDS.format("BearerToken"))
    expect(
        lambda: iceberg(URI, credential=AwsProfile("p", profile="x"), signing=signing),
        ValueError,
        SIGV4_KINDS.format("AwsProfile"),
    )
    c = iceberg(URI, credential=keys(), signing=signing)
    assert repr(c) == (
        "IcebergCatalog('{}', credential=AwsKeys('glue-etl', key_id=<set>, secret=<set>), "
        "signing=SigV4('us-east-1', 'glue'), access_delegation='vended-credentials')".format(URI)
    )
    assert "SECRET" not in repr(c)


def test_credential_refused_by_type():
    expect(
        lambda: iceberg(URI, credential="catalog-etl"),
        TypeError,
        "credential= must be a komira credential, not str",
    )
    expect(lambda: iceberg(URI, credential=None), TypeError, "credential= must be a komira credential, not NoneType")


def test_signing_refused_by_type():
    expect(
        lambda: iceberg(URI, signing=("us-east-1", "glue")),
        TypeError,
        "signing= must be a komira SigV4 or None, not tuple",
    )


def test_access_delegation_refused():
    expect(lambda: iceberg(URI, access_delegation=None), TypeError, "access_delegation= must be a str, not NoneType")
    expect(
        lambda: iceberg(URI, access_delegation="remote-signing"),
        ValueError,
        "access_delegation= 'remote-signing' is not supported: use 'vended-credentials' or 'none'",
    )
    expect(
        lambda: iceberg(URI, access_delegation="None"),
        ValueError,
        "access_delegation= 'None' is not supported: use 'vended-credentials' or 'none'",
    )


def test_keywords_only():
    e = raised(lambda: iceberg(URI, "prod"))
    assert type(e) is TypeError
    e = raised(lambda: IcebergCatalog(URI, "prod"))
    assert type(e) is TypeError


def test_sigv4():
    s = SigV4("eu-west-1", "s3tables")
    assert (s.region, s.service) == ("eu-west-1", "s3tables")
    assert repr(s) == "SigV4('eu-west-1', 's3tables')"
    assert s == SigV4("eu-west-1", "s3tables")
    assert hash(s) == hash(SigV4("eu-west-1", "s3tables"))
    assert s != SigV4("eu-west-1", "glue")
    assert s != SigV4("us-east-1", "s3tables")
    assert s != ("eu-west-1", "s3tables")
    assert copy.copy(s) == s
    assert pickle.loads(pickle.dumps(s)) == s
    expect(lambda: SigV4(1, "glue"), TypeError, "region must be a str, not int")
    expect(lambda: SigV4("", "glue"), ValueError, "region is empty")
    expect(lambda: SigV4("us-east-1", None), TypeError, "service must be a str, not NoneType")
    expect(lambda: SigV4("us-east-1", ""), ValueError, "service is empty")
    expect(lambda: SigV4("us-east-1", "glue\n"), ValueError, "service holds a control character")


def test_table_from_a_str():
    c = iceberg(URI, credential=bearer())
    t = c.table("sales.orders")
    assert type(t) is IcebergTable
    assert t.catalog is c
    assert t.namespace == ("sales",)
    assert t.name == "orders"
    assert t.catalog.credential is c.credential
    deep = c.table("a.b.c.orders")
    assert (deep.namespace, deep.name) == (("a", "b", "c"), "orders")
    assert c.table("Sales.Orders").namespace == ("Sales",)  # sent as written


def test_table_from_a_tuple():
    c = iceberg(URI)
    t = c.table(("sales.eu", "orders.v2"))
    assert (t.namespace, t.name) == (("sales.eu",), "orders.v2")
    t = c.table(("a", "b", "orders"))
    assert (t.namespace, t.name) == (("a", "b"), "orders")


def test_table_repr():
    c = iceberg(URI, credential=bearer())
    assert repr(c.table("sales.orders")) == (
        "IcebergCatalog('{}', credential=BearerToken('catalog-etl', token=<set>), "
        "access_delegation='vended-credentials').table(('sales', 'orders'))".format(URI)
    )
    assert "SECRET" not in repr(c.table("sales.orders"))


def test_table_name_refused():
    c = iceberg(URI)
    expect(lambda: c.table(None), TypeError, "a table name must be a str or a tuple of str, not NoneType")
    expect(lambda: c.table(["sales", "orders"]), TypeError, "a table name must be a str or a tuple of str, not list")
    expect(lambda: c.table(b"sales.orders"), TypeError, "a table name must be a str or a tuple of str, not bytes")
    expect(lambda: c.table("orders"), ValueError, NEEDS_NAMESPACE)
    expect(lambda: c.table(("orders",)), ValueError, NEEDS_NAMESPACE_TUPLE)
    expect(lambda: c.table(()), ValueError, NEEDS_NAMESPACE_TUPLE)
    for name in ("", ".", "sales.", ".orders", "sales..orders"):
        expect(lambda: c.table(name), ValueError, "a table name has an empty part")
    expect(lambda: c.table(("sales", "")), ValueError, "a table name tuple has an empty part")
    expect(lambda: c.table(("", "orders")), ValueError, "a table name tuple has an empty part")
    expect(lambda: c.table(("sales", 1)), TypeError, "each part of a table name tuple must be a str, not int")
    expect(lambda: c.table("sales.ord\x00ers"), ValueError, "a table name holds a control character")
    expect(lambda: c.table(("sales", "a\x7f")), ValueError, "a table name tuple holds a control character")


def test_table_constructor_refused():
    c = iceberg(URI)
    expect(
        lambda: IcebergTable("catalog", ("sales",), "orders"),
        TypeError,
        "catalog must be a komira IcebergCatalog, not str",
    )
    expect(lambda: IcebergTable(c, ["sales"], "orders"), TypeError, "an IcebergTable is built by catalog.table(name)")
    expect(lambda: IcebergTable(c, ("sales",), 1), TypeError, "an IcebergTable is built by catalog.table(name)")
    expect(lambda: IcebergTable(c, (), "orders"), ValueError, NEEDS_NAMESPACE_TUPLE)
    t = IcebergTable(c, ("sales",), "orders")
    assert (t.catalog, t.namespace, t.name) == (c, ("sales",), "orders")


def test_no_pickle_or_copy():
    c = iceberg(URI, credential=bearer())
    for value in (c, c.table("sales.orders"), iceberg(URI)):
        expect(lambda: pickle.dumps(value), TypeError, NOT_COPIED)
        expect(lambda: copy.copy(value), TypeError, NOT_COPIED)
        expect(lambda: copy.deepcopy(value), TypeError, NOT_COPIED)


def test_values_are_closed():
    c = iceberg(URI)
    for value, attr in ((c, "uri"), (c.table("s.t"), "name"), (SigV4("r", "s"), "region")):
        assert type(raised(lambda: setattr(value, attr, "x"))) is AttributeError
        assert type(raised(lambda: setattr(value, "extra", 1))) is AttributeError


def test_identity_not_value():
    # A catalog or a table compares by identity, as the credential it holds does.
    a, b = iceberg(URI), iceberg(URI)
    assert a == a and a != b
    assert a.table("s.t") != a.table("s.t")


def test_no_library_and_not_public():
    iceberg(URI, credential=bearer()).table("sales.orders")
    SigV4("us-east-1", "glue")
    assert _native._loaded is None
    for name in ("iceberg", "IcebergCatalog", "IcebergTable", "SigV4"):
        assert name not in komira.__all__


def main():
    tests = [
        value
        for name, value in list(globals().items())
        if name.startswith("test_") and callable(value) and value.__module__ == __name__
    ]
    for test in tests:
        test()
    print(f"test_iceberg: {len(tests)} tests passed")


if __name__ == "__main__":
    main()
