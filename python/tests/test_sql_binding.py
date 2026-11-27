"""`Session.add_sql_binding` and `komira.files` on the real libkomira (ABI
1.10), against the loopback stand-ins of S3 and Azure Blob
(objectstore_fakes.py), which check every request's signature or SAS:

- an `s3://` key and an `s3://` glob, bound with `AwsKeys`, a region and the
  fake's endpoint, answer SQL with the rows of their Parquet objects; every
  request the store got is signed for that key id and region, and no request
  carries the secret; `url_style="path"` reads the same; the name is found in
  any case;
- an `az://` blob bound with `AzureKey`, and an `az://` glob with `AzureSas`,
  answer SQL; the Shared Key never reaches the store;
- binding a name again replaces its table, also a table `register_csv`
  registered; a local Parquet file binds by `pathlib.Path` and by a relative
  path resolved when the source is built;
- a wrong secret is refused at bind by the store (SignatureDoesNotMatch),
  with an error that names neither secret, and binds nothing; the same
  credential name sealed again with the right secret then reads;
- the library's named refusals, each the exact message with status -3 and
  step "bind", the class `_errors` picks from its code, and the name's earlier
  table kept: `AMBIENT` on S3 (`CredentialsError`, `CREDENTIALS_NOT_FOUND`),
  no region (`StorageError`, `STORAGE_REGION_UNKNOWN`, the no-leak case: the
  sealed secret is not in it), `gs://` (`UnsupportedOperation`,
  `STORAGE_URL_REFUSED`), an endpoint with a query (`STORAGE_URL_REFUSED`),
  `ANONYMOUS` and an `AwsProfile` on S3, a region on Azure, a scope as a
  table, a bucket another table reads with another region (`BindError`, the
  `BIND_*` codes), a glob that matches nothing (`PARQUET_GLOB_NO_MATCH`) and
  a missing object;
- the logger "komira" at DEBUG records nothing that holds a secret while a
  source is bound and queried, and `repr` of a source shows each secret as
  `<set>`, by exact equality;
- the arguments `files` and `add_sql_binding` refuse before any library
  call, each by its exact message; a source refuses pickle and copy and
  compares by identity; `_wire` gives the exact `WireBoundSource` bytes; a
  closed session refuses a binding.

    test_sql_binding.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import copy
import io
import logging
import os
import pathlib
import pickle
import sys
import tempfile

import pyarrow as pa
import pyarrow.parquet as pq
from objectstore_fakes import FakeAzure, FakeS3

import komira
from komira import (
    AMBIENT,
    ANONYMOUS,
    AwsKeys,
    AwsProfile,
    AzureKey,
    AzureSas,
    BindError,
    CredentialsError,
    GcpToken,
    KomiraError,
    StorageError,
    UnsupportedOperation,
    _native,
    files,
)

KEY_ID = "AKIDEXAMPLE"
SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
WRONG = "not-the-secret-0123456789"
REGION = "eu-west-1"
AZURE_KEY = "a29taXJhLWZha2UtYXp1cmUta2V5LWJ5dGVz"
SAS = "sv=2024-08-04&sr=c&sp=rl&sig=c2lnbmF0dXJl"
SECRETS = (SECRET, WRONG, AZURE_KEY, "c2lnbmF0dXJl")


def parquet(rows):
    """The bytes of a Parquet file of `rows` [(id, city)]."""
    out = io.BytesIO()
    table = pa.table({"id": pa.array([r[0] for r in rows], pa.int64()), "city": [r[1] for r in rows]})
    pq.write_table(table, out)
    return out.getvalue()


PART_0 = parquet([(1, "Oslo"), (2, "Lima")])
PART_1 = parquet([(3, "Pune")])


def rows(s, query):
    return s.sql(query).to_arrow().to_pylist()


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def expect(call, cls, message):
    e = raised(call)
    assert type(e) is cls, repr(e)
    assert str(e) == message, str(e)
    return e


def refused(call, cls, code, message):
    """`call` raises the library's refusal `message` at bind, as `cls`."""
    e = expect(call, cls, message)
    assert e.status == -3 and e.code == code and e.step == "bind", (e.status, e.code, e.step)
    for secret in SECRETS:
        assert secret not in str(e), str(e)
    return e


def s3(fake, location, *, secret=SECRET, name="raw-etl", **settings):
    settings.setdefault("endpoint", fake.endpoint)
    settings.setdefault("region", REGION)
    return files(location, credential=AwsKeys(name, key_id=KEY_ID, secret=secret), **settings)


def s3_fake():
    fake = FakeS3(KEY_ID, SECRET, REGION)
    fake.put("lake", "orders/part-0.parquet", PART_0)
    fake.put("lake", "orders/part-1.parquet", PART_1)
    fake.put("lake", "orders/notes.txt", b"not parquet")
    return fake


def no_secret_on_the_wire(fake):
    assert fake.requests, "the store got no request"
    for req in fake.requests:
        for secret in SECRETS:
            assert secret not in req.head, req.head


def test_s3_key_and_glob():
    with s3_fake() as fake, komira.Session() as s:
        s.add_sql_binding("orders", s3(fake, "s3://lake/orders/part-0.parquet"))
        assert rows(s, "SELECT id, city FROM orders ORDER BY id") == [
            {"id": 1, "city": "Oslo"},
            {"id": 2, "city": "Lima"},
        ]
        # The name is found without regard to case.
        assert rows(s, "SELECT count(*) AS n FROM ORDERS") == [{"n": 2}]
        # A glob is listed when the source is bound; notes.txt is not matched.
        s.add_sql_binding("all_orders", s3(fake, "s3://lake/orders/*.parquet"))
        assert rows(s, "SELECT count(*) AS n, sum(id) AS ids FROM all_orders") == [{"n": 3, "ids": 6}]
        s.add_sql_binding("by_path", s3(fake, "s3://lake/orders/part-1.parquet", url_style="path"))
        assert rows(s, "SELECT city FROM by_path") == [{"city": "Pune"}]
        assert fake.refusals == [], fake.refusals
        for req in fake.requests:
            auth = req.headers["authorization"]
            assert auth.startswith("AWS4-HMAC-SHA256 Credential=" + KEY_ID + "/"), auth
            assert "/" + REGION + "/s3/aws4_request" in auth, auth
        no_secret_on_the_wire(fake)


def test_azure_key_and_sas():
    with FakeAzure("acct", key=AZURE_KEY) as fake, komira.Session() as s:
        fake.put("box", "orders/part-0.parquet", PART_0)
        source = files(
            "az://box/orders/part-0.parquet",
            credential=AzureKey("az-key", account="acct", key=AZURE_KEY),
            endpoint=fake.endpoint,
        )
        s.add_sql_binding("orders", source)
        assert rows(s, "SELECT id FROM orders ORDER BY id") == [{"id": 1}, {"id": 2}]
        assert fake.refusals == [], fake.refusals
        no_secret_on_the_wire(fake)
    with FakeAzure("acct", sas=SAS) as fake, komira.Session() as s:
        fake.put("box", "orders/part-0.parquet", PART_0)
        fake.put("box", "orders/part-1.parquet", PART_1)
        source = files(
            "az://box/orders/*.parquet",
            credential=AzureSas("az-sas", account="acct", sas=SAS),
            endpoint=fake.endpoint,
        )
        s.add_sql_binding("orders", source)
        assert rows(s, "SELECT count(*) AS n FROM orders") == [{"n": 3}]
        # A SAS travels in the query string by design; nothing else is sent.
        assert fake.refusals == [], fake.refusals
        assert all("authorization" not in req.headers for req in fake.requests)


def test_rebinding_and_local_paths():
    with s3_fake() as fake, komira.Session() as s:
        s.add_sql_binding("orders", s3(fake, "s3://lake/orders/part-0.parquet"))
        s.add_sql_binding("orders", s3(fake, "s3://lake/orders/part-1.parquet"))
        assert rows(s, "SELECT id FROM orders") == [{"id": 3}]

        # A table of another kind is replaced too.
        csv = os.path.join(tempfile.mkdtemp(), "people.csv")
        pathlib.Path(csv).write_text("id,city\n9,Rome\n")
        s.register_csv("people", csv)
        s.add_sql_binding("people", s3(fake, "s3://lake/orders/part-1.parquet"))
        assert rows(s, "SELECT id FROM people") == [{"id": 3}]

        # A local file: by pathlib.Path, and by a relative path resolved when
        # the source is built, not when it is bound.
        where = tempfile.mkdtemp()
        pathlib.Path(where, "local.parquet").write_bytes(PART_0)
        s.add_sql_binding("local", files(pathlib.Path(where, "local.parquet")))
        assert rows(s, "SELECT count(*) AS n FROM local") == [{"n": 2}]
        cwd = os.getcwd()
        os.chdir(where)
        try:
            relative = files("local.parquet")
        finally:
            os.chdir(cwd)
        # getcwd() is the directory's real path, which abspath joins to.
        assert repr(relative) == "komira.files({!r}, credential=komira.AMBIENT)".format(
            os.path.join(os.path.realpath(where), "local.parquet")
        ), repr(relative)
        s.add_sql_binding("relative", relative)
        assert rows(s, "SELECT max(id) AS m FROM relative") == [{"m": 2}]


def test_wrong_secret():
    with s3_fake() as fake, komira.Session() as s:
        e = raised(lambda: s.add_sql_binding("orders", s3(fake, "s3://lake/orders/part-0.parquet", secret=WRONG)))
        assert isinstance(e, KomiraError), repr(e)
        assert e.status == -3 and e.step == "bind", (e.status, e.step, str(e))
        for secret in SECRETS + (KEY_ID,):
            assert secret not in str(e), str(e)
        # The store refused the request it was sent (a client may send more
        # than one before it gives up), for the signature alone.
        assert fake.refusals and {code for code, _ in fake.refusals} == {"SignatureDoesNotMatch"}, fake.refusals
        # Nothing was bound.
        assert type(raised(lambda: s.sql("SELECT * FROM orders"))) is BindError
        # The name raw-etl sealed again, with the right secret, reads.
        s.add_sql_binding("orders", s3(fake, "s3://lake/orders/part-0.parquet"))
        assert rows(s, "SELECT count(*) AS n FROM orders") == [{"n": 2}]
        no_secret_on_the_wire(fake)


def test_named_refusals():
    with s3_fake() as fake, komira.Session() as s:
        s.add_sql_binding("t", s3(fake, "s3://lake/orders/part-0.parquet"))
        keys = AwsKeys("raw-etl", key_id=KEY_ID, secret=SECRET)

        def bind(source, name="t"):
            return lambda: s.add_sql_binding(name, source)

        refused(
            bind(files("s3://lake/orders/part-0.parquet", endpoint=fake.endpoint, region=REGION)),
            CredentialsError,
            "CREDENTIALS_NOT_FOUND",
            "CREDENTIALS_NOT_FOUND: add_sql_binding name=t: the source names no credential, or ambient, which this"
            " library does not resolve; name a sealed credential",
        )
        refused(
            bind(files("s3://lake/orders/part-0.parquet", credential=keys, endpoint=fake.endpoint)),
            StorageError,
            "STORAGE_REGION_UNKNOWN",
            "STORAGE_REGION_UNKNOWN: add_sql_binding name=t: s3://lake/orders/part-0.parquet names no region;"
            " give the source its region",
        )
        refused(
            bind(files("gs://lake/orders/part-0.parquet", credential=GcpToken("g", token="ya29.a0"))),
            UnsupportedOperation,
            "STORAGE_URL_REFUSED",
            "STORAGE_URL_REFUSED: add_sql_binding name=t: no store of this library reads 'gs://' locations;"
            " s3:// and az:// (abfs://, abfss://) are read",
        )
        refused(
            bind(s3(fake, "s3://lake/orders/part-0.parquet", endpoint=fake.endpoint + "/?a=b")),
            UnsupportedOperation,
            "STORAGE_URL_REFUSED",
            "STORAGE_URL_REFUSED: add_sql_binding name=t: an endpoint must not carry a query or a fragment",
        )
        refused(
            bind(files("s3://lake/orders/part-0.parquet", credential=ANONYMOUS, region=REGION)),
            BindError,
            "BIND_SOURCE_UNSUPPORTED",
            "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: credential=anonymous: unsigned s3:// reads are not"
            " served",
        )
        refused(
            bind(files("s3://lake/orders/part-0.parquet", credential=AwsProfile("dev", profile="x"), region=REGION)),
            BindError,
            "BIND_SOURCE_UNSUPPORTED",
            "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: credential=dev: an AwsProfile is not read by this"
            " library; seal AwsKeys",
        )
        refused(
            bind(
                files(
                    "az://box/a.parquet",
                    credential=AzureKey("az-key", account="acct", key=AZURE_KEY),
                    endpoint=fake.endpoint,
                    region=REGION,
                )
            ),
            BindError,
            "BIND_SOURCE_UNSUPPORTED",
            "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: an az:// source takes no region",
        )
        refused(
            bind(s3(fake, "s3://lake/orders/")),
            BindError,
            "BIND_SCOPE_NOT_A_TABLE",
            "BIND_SCOPE_NOT_A_TABLE: add_sql_binding name=t: s3://lake/orders/ is a scope, not a table; name an"
            " object or a glob",
        )
        refused(
            bind(s3(fake, "s3://lake/orders/part-1.parquet", region="us-east-1"), name="other"),
            BindError,
            "BIND_STORE_CONFLICT",
            "BIND_STORE_CONFLICT: add_sql_binding name=other: s3://lake is read by table 't' with another"
            " credential or other settings; one session reads a bucket one way",
        )
        e = raised(bind(s3(fake, "s3://lake/orders/*.csv")))
        assert isinstance(e, KomiraError) and e.status == -3 and e.step == "bind", repr(e)
        assert str(e).startswith("PARQUET_GLOB_NO_MATCH: no file matches '"), str(e)
        e = raised(bind(s3(fake, "s3://lake/orders/missing.parquet")))
        assert isinstance(e, KomiraError) and e.status == -3 and e.step == "bind", repr(e)
        for secret in SECRETS:
            assert secret not in str(e), str(e)

        # Every refusal left the table t as it was, and bound nothing else.
        assert rows(s, "SELECT count(*) AS n FROM t") == [{"n": 2}]
        assert type(raised(lambda: s.sql("SELECT * FROM other"))) is BindError
        assert fake.refusals == [], fake.refusals


class Records(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(self.format(record))


def test_no_secret_in_logs_or_repr():
    logger = logging.getLogger("komira")
    handler = Records()
    logger.addHandler(handler)
    level = logger.level
    logger.setLevel(logging.DEBUG)
    try:
        with s3_fake() as fake, komira.Session() as s:
            source = s3(fake, "s3://lake/orders/*.parquet")
            s.add_sql_binding("orders", source)
            assert rows(s, "SELECT count(*) AS n FROM orders") == [{"n": 3}]
            raised(lambda: s.add_sql_binding("bad", s3(fake, "s3://lake/orders/part-0.parquet", secret=WRONG)))
    finally:
        logger.removeHandler(handler)
        logger.setLevel(level)
    for line in handler.lines:
        for secret in SECRETS:
            assert secret not in line, line
    assert repr(source) == (
        "komira.files('s3://lake/orders/*.parquet', credential=AwsKeys('raw-etl', key_id=<set>, secret=<set>),"
        " endpoint={!r}, region='eu-west-1')".format(fake.endpoint)
    ), repr(source)
    sas = files("az://box/a.parquet", credential=AzureSas("s", account="acct", sas=SAS))
    assert repr(sas) == "komira.files('az://box/a.parquet', credential=AzureSas('s', account='acct', sas=<set>))"


def test_arguments():
    keys = AwsKeys("k", key_id=KEY_ID, secret=SECRET)
    url = "s3://lake/a.parquet"
    expect(lambda: files(7), TypeError, "location must be a str or os.PathLike[str], not int")
    expect(lambda: files(b"x.parquet"), TypeError, "location must be a str or os.PathLike[str], not bytes")
    expect(lambda: files(""), ValueError, "location is empty")
    expect(lambda: files("s3://lake/\ud800"), ValueError, "location is not valid UTF-8")
    expect(lambda: files("s3://lake/a\0b"), ValueError, "location holds a NUL byte")
    expect(lambda: files(url, credential="raw-etl"), TypeError, "credential= must be a komira credential, not str")
    expect(lambda: files(url, credential=keys, region=1), TypeError, "region= must be a str or None, not int")
    expect(lambda: files(url, credential=keys, endpoint=""), ValueError, "endpoint= is empty")
    expect(lambda: files(url, credential=keys, endpoint="http://store.example.com\ud800"), ValueError, "endpoint= is not valid UTF-8")
    expect(
        lambda: files(url, credential=keys, url_style="Path"),
        ValueError,
        "url_style= must be 'vhost' or 'path', not 'Path'",
    )
    expect(
        lambda: files(url, credential=AzureKey("a", account="acct", key=AZURE_KEY)),
        ValueError,
        "credential= is AzureKey, which does not read s3:// locations",
    )
    expect(
        lambda: files("abfss://box/a.parquet", credential=keys),
        ValueError,
        "credential= is AwsKeys, which does not read abfss:// locations",
    )
    expect(
        lambda: files("GS://b/a.parquet", credential=keys),
        ValueError,
        "credential= is AwsKeys, which does not read gs:// locations",
    )
    expect(
        lambda: files("a.parquet", credential=ANONYMOUS),
        ValueError,
        "a local path is read under the process's own identity: credential= takes only komira.AMBIENT,"
        " not komira.ANONYMOUS",
    )
    expect(
        lambda: files("a.parquet", credential=keys),
        ValueError,
        "a local path is read under the process's own identity: credential= takes only komira.AMBIENT, not AwsKeys",
    )
    expect(lambda: files("a.parquet", region=REGION), ValueError, "a local path takes no endpoint=, region= or url_style=")
    # Every store takes AMBIENT and ANONYMOUS when built (the library decides
    # which it reads), and a scheme no store fits is left to the library.
    for location in (url, "az://box/a.parquet", "gs://b/a.parquet"):
        files(location, credential=AMBIENT)
        files(location, credential=ANONYMOUS)
    files("https://example.com/a.parquet", credential=keys)

    source = files(url, credential=keys, region=REGION)
    for call in (lambda: pickle.dumps(source), lambda: copy.copy(source), lambda: copy.deepcopy(source)):
        expect(call, TypeError, "a komira source cannot be pickled or copied: it holds a credential")
    assert source == source and source != files(url, credential=keys, region=REGION)

    # The exact WireBoundSource: files = 1 { location = 1, access = 2 {
    # credential = 1, endpoint = 2, region = 3, addressing = 4 } }.
    full = files(url, credential=keys, endpoint="http://store.example.com:1", region=REGION, url_style="vhost")
    assert full._wire() == (
        b"\x0a\x43"
        + b"\x0a\x13s3://lake/a.parquet"
        + b"\x12\x2c"
        + b"\x0a\x01k"
        + b"\x12\x1ahttp://store.example.com:1"
        + b"\x1a\x09eu-west-1"
        + b"\x20\x01"
    ), full._wire()
    assert files(url, credential=keys, url_style="path")._wire()[-2:] == b"\x20\x02"
    assert files("/data/a.parquet")._wire() == b"\x0a\x1c\x0a\x0f/data/a.parquet\x12\x09\x0a\x07ambient"

    with komira.Session() as s:
        expect(lambda: s.add_sql_binding(5, source), TypeError, "name must be a str, not int")
        expect(lambda: s.add_sql_binding("", source), ValueError, "name is empty")
        expect(lambda: s.add_sql_binding("a\0b", source), ValueError, "name holds a NUL byte")
        expect(lambda: s.add_sql_binding("t", url), TypeError, "source must be a komira.files source, not str")
        expect(lambda: s.add_sql_binding("t", keys), TypeError, "source must be a komira.files source, not AwsKeys")
    expect(lambda: s.add_sql_binding("t", source), KomiraError, "the session is closed")


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1010, komira.abi_version()
    tests = [
        value
        for name, value in list(globals().items())
        if name.startswith("test_") and callable(value) and value.__module__ == __name__
    ]
    for test in tests:
        test()
    print("sql_binding: {} cases on libkomira {}".format(len(tests), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
