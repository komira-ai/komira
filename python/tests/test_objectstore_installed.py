"""Object-store sources read through the installed komira wheel
(python/BUCK, `objectstore_installed_test`): a Python caller binds Parquet
objects on the loopback stand-ins of S3 and Azure Blob
(objectstore_fakes.py) with `komira.files` and `Session.add_sql_binding`,
and every answer equals the answer to the same SQL over the same bytes read
from local files.

    <prefix>/bin/python3.13 -I test_objectstore_installed.py --site <dir>
        [--host-lib <lib>]... --fakes <objectstore_fakes.py>
        --readings <readings.parquet>

Run by wheel_install_run.py, which installed komira, pyarrow and protobuf
into `--site` and starts this from an empty working directory. The stand-ins
are HTTP servers on 127.0.0.1, port 0, in this process; each checks every
request's signature (SigV4, Shared Key) or SAS. In order:

- `import komira` is the package installed in `--site`;
- S3 with `AwsKeys` and a region: one object (`--readings`) and a glob of
  two objects (a table of 20000 rows in row groups of 2000, cut in two)
  each answer `SELECT *` in id order and an aggregate exactly as the same
  files bound from local paths do, and as pyarrow reads them; every request
  is signed for the key id, and no request carries the secret;
- Azure Blob with `AzureKey` (one blob) and with `AzureSas` (a glob of two
  blobs): the same answers as the local files; the Shared Key never reaches
  the store, and a SAS request carries no Authorization header;
- GCS: a `gs://` source is refused at bind with STORAGE_URL_REFUSED, word for
  word, as `UnsupportedOperation`: the library has no GCS store, so there is
  no request to send;
- wrong credentials, each in a new session: a wrong S3 secret
  (SignatureDoesNotMatch), a wrong S3 access key id (InvalidAccessKeyId), a
  wrong Azure Shared Key and a SAS with another signature (both
  AuthenticationFailed) are refused at bind, as a store refusal naming the
  location and no secret, with the store's refusals of that one code only;
  the name stays unbound; and the same credential name sealed again with
  the right value then reads the same rows as the local file.

Any failure raises; its last traceback line is what a failing run names.
"""

import ctypes
import importlib.util
import os
import sys
import tempfile

_VALUED = ("--site", "--fakes", "--readings")

KEY_ID = "AKIDEXAMPLE"
SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
WRONG_SECRET = "not-the-secret-0123456789"
WRONG_KEY_ID = "AKIDOTHERKEY"
REGION = "eu-west-1"
ACCOUNT = "acct"
AZURE_KEY = "a29taXJhLWZha2UtYXp1cmUta2V5LWJ5dGVz"
WRONG_AZURE_KEY = "b3RoZXIta29taXJhLWZha2UtYXp1cmUta2V5"
SAS = "sv=2024-08-04&sr=c&sp=rl&sig=c2lnbmF0dXJl"
WRONG_SAS = "sv=2024-08-04&sr=c&sp=rl&sig=b3RoZXJzaWc"
SECRETS = (SECRET, WRONG_SECRET, AZURE_KEY, WRONG_AZURE_KEY, "c2lnbmF0dXJl", "b3RoZXJzaWc")

# What every table is asked: all rows in a fixed order, and an aggregate.
ROWS = "SELECT * FROM {} ORDER BY id"
AGGREGATE = "SELECT count(*) AS n, sum(id) AS ids, min(value) AS lo, max(value) AS hi FROM {}"


def parse(argv):
    opts = {"host_lib": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("test_objectstore_installed: flag {} needs a value".format(flag))
        if flag == "--host-lib":
            opts["host_lib"].append(argv[i + 1])
        elif flag in _VALUED:
            opts[flag[2:]] = argv[i + 1]
        else:
            raise SystemExit("test_objectstore_installed: unknown flag {}".format(flag))
        i += 2
    for flag in _VALUED:
        if flag[2:] not in opts:
            raise SystemExit("test_objectstore_installed: {} is required".format(flag))
    return opts


def load_path(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Data:
    """The Parquet bytes the stores serve, the same bytes as local files
    under `root`, and pyarrow's own read of each table."""

    def __init__(self, root, readings):
        import pyarrow as pa
        import pyarrow.parquet as pq

        with open(readings, "rb") as f:
            self.readings = f.read()
        n = 20000
        wide = pa.table(
            {
                "id": pa.array(range(n), pa.int64()),
                "value": pa.array([i * 0.25 for i in range(n)], pa.float64()),
                "city": pa.array(["c{}".format(i % 97) for i in range(n)], pa.string()),
            }
        )
        self.parts = []
        for k, part in enumerate((wide.slice(0, 12000), wide.slice(12000))):
            path = os.path.join(root, "parts", "part-{}.parquet".format(k))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            pq.write_table(part, path, row_group_size=2000)
            with open(path, "rb") as f:
                self.parts.append(f.read())
        self.readings_path = os.path.join(root, "readings.parquet")
        with open(self.readings_path, "wb") as f:
            f.write(self.readings)
        self.parts_glob = os.path.join(root, "parts", "*.parquet")
        self.readings_rows = pq.read_table(self.readings_path).sort_by("id").to_pylist()
        self.parts_rows = wide.to_pylist()
        assert self.readings_rows and len(self.parts_rows) == n, "the data is empty, so it proves nothing"


def rows(s, query):
    return s.sql(query).to_arrow().to_pylist()


def same_as_local(s, komira, remote, local_location, oracle):
    """`remote` answers ROWS and AGGREGATE as the same bytes bound from
    `local_location` do, and ROWS is pyarrow's read of them."""
    local = remote + "_local"
    s.add_sql_binding(local, komira.files(local_location))
    got = rows(s, ROWS.format(remote))
    want = rows(s, ROWS.format(local))
    assert got == want, "{}: the store answers {} rows, the local files {}".format(remote, len(got), len(want))
    assert want == oracle, "{}: the local files answer {} rows, pyarrow reads {}".format(remote, len(want), len(oracle))
    got = rows(s, AGGREGATE.format(remote))
    want = rows(s, AGGREGATE.format(local))
    assert got == want, "{}: the store's aggregate is {}, the local files' {}".format(remote, got, want)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def no_secret_on_the_wire(fake):
    assert fake.requests, "the store got no request"
    for req in fake.requests:
        for secret in SECRETS:
            assert secret not in req.head, req.head


def s3_store(fakes, data):
    fake = fakes.FakeS3(KEY_ID, SECRET, REGION)
    fake.put("lake", "readings.parquet", data.readings)
    for k, body in enumerate(data.parts):
        fake.put("lake", "parts/part-{}.parquet".format(k), body)
    return fake


def azure_store(fakes, data, **auth):
    fake = fakes.FakeAzure(ACCOUNT, **auth)
    fake.put("box", "readings.parquet", data.readings)
    for k, body in enumerate(data.parts):
        fake.put("box", "parts/part-{}.parquet".format(k), body)
    return fake


def s3_source(komira, fake, location, *, key_id=KEY_ID, secret=SECRET):
    credential = komira.AwsKeys("lake-reader", key_id=key_id, secret=secret)
    return komira.files(location, credential=credential, endpoint=fake.endpoint, region=REGION)


def azure_key_source(komira, fake, location, key=AZURE_KEY):
    credential = komira.AzureKey("box-key", account=ACCOUNT, key=key)
    return komira.files(location, credential=credential, endpoint=fake.endpoint)


def azure_sas_source(komira, fake, location, sas=SAS):
    credential = komira.AzureSas("box-sas", account=ACCOUNT, sas=sas)
    return komira.files(location, credential=credential, endpoint=fake.endpoint)


def check_s3(komira, fakes, data):
    with s3_store(fakes, data) as fake, komira.Session() as s:
        s.add_sql_binding("readings", s3_source(komira, fake, "s3://lake/readings.parquet"))
        same_as_local(s, komira, "readings", data.readings_path, data.readings_rows)
        s.add_sql_binding("parts", s3_source(komira, fake, "s3://lake/parts/*.parquet"))
        same_as_local(s, komira, "parts", data.parts_glob, data.parts_rows)
        assert fake.refusals == [], fake.refusals
        for req in fake.requests:
            auth = req.headers.get("authorization", "")
            assert auth.startswith("AWS4-HMAC-SHA256 Credential=" + KEY_ID + "/"), auth
        no_secret_on_the_wire(fake)


def check_azure(komira, fakes, data):
    with azure_store(fakes, data, key=AZURE_KEY) as fake, komira.Session() as s:
        s.add_sql_binding("readings", azure_key_source(komira, fake, "az://box/readings.parquet"))
        same_as_local(s, komira, "readings", data.readings_path, data.readings_rows)
        assert fake.refusals == [], fake.refusals
        no_secret_on_the_wire(fake)
    with azure_store(fakes, data, sas=SAS) as fake, komira.Session() as s:
        s.add_sql_binding("parts", azure_sas_source(komira, fake, "az://box/parts/*.parquet"))
        same_as_local(s, komira, "parts", data.parts_glob, data.parts_rows)
        assert fake.refusals == [], fake.refusals
        # A SAS travels in the query string by design; no header carries it.
        assert all("authorization" not in req.headers for req in fake.requests)


def check_gcs(komira):
    with komira.Session() as s:
        source = komira.files("gs://lake/readings.parquet", credential=komira.GcpToken("gcs-reader", token="ya29.a0"))
        e = raised(lambda: s.add_sql_binding("readings", source))
        assert type(e) is komira.UnsupportedOperation, repr(e)
        assert str(e) == (
            "STORAGE_URL_REFUSED: add_sql_binding name=readings: no store of this library reads 'gs://' locations;"
            " s3:// and az:// (abfs://, abfss://) are read"
        ), str(e)
        assert (e.status, e.code, e.step) == (-3, "STORAGE_URL_REFUSED", "bind"), (e.status, e.code, e.step)
        assert type(raised(lambda: s.sql("SELECT * FROM readings"))) is komira.BindError


def check_refused(komira, fake, s, wrong, right, location, code, want):
    """Binding `wrong` is refused by the store for `code` alone and binds
    nothing; `right`, the same credential name with the right value, then
    reads `want`, the rows of the local file."""
    e = raised(lambda: s.add_sql_binding("readings", wrong))
    assert isinstance(e, komira.KomiraError), repr(e)
    assert e.status == -3 and e.step == "bind", (e.status, e.step, str(e))
    assert "StoreError[PERMISSION_DENIED]" in str(e), str(e)
    assert location in str(e), str(e)
    for secret in SECRETS:
        assert secret not in str(e), str(e)
    assert fake.refusals and {c for c, _ in fake.refusals} == {code}, fake.refusals
    assert type(raised(lambda: s.sql("SELECT * FROM readings"))) is komira.BindError
    before = len(fake.refusals)
    s.add_sql_binding("readings", right)
    assert rows(s, ROWS.format("readings")) == want
    assert len(fake.refusals) == before, fake.refusals[before:]


def check_wrong_credentials(komira, fakes, data):
    want = data.readings_rows
    location = "s3://lake/readings.parquet"
    with s3_store(fakes, data) as fake, komira.Session() as s:
        wrong = s3_source(komira, fake, location, secret=WRONG_SECRET)
        right = s3_source(komira, fake, location)
        check_refused(komira, fake, s, wrong, right, location, "SignatureDoesNotMatch", want)
    with s3_store(fakes, data) as fake, komira.Session() as s:
        wrong = s3_source(komira, fake, location, key_id=WRONG_KEY_ID)
        right = s3_source(komira, fake, location)
        check_refused(komira, fake, s, wrong, right, location, "InvalidAccessKeyId", want)
    location = "az://box/readings.parquet"
    with azure_store(fakes, data, key=AZURE_KEY) as fake, komira.Session() as s:
        wrong = azure_key_source(komira, fake, location, key=WRONG_AZURE_KEY)
        right = azure_key_source(komira, fake, location)
        check_refused(komira, fake, s, wrong, right, location, "AuthenticationFailed", want)
    with azure_store(fakes, data, sas=SAS) as fake, komira.Session() as s:
        wrong = azure_sas_source(komira, fake, location, sas=WRONG_SAS)
        right = azure_sas_source(komira, fake, location)
        check_refused(komira, fake, s, wrong, right, location, "AuthenticationFailed", want)


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)

    site = os.path.realpath(opts["site"])
    import komira

    init = os.path.realpath(komira.__file__)
    where = os.path.join(site, "komira", "__init__.py")
    assert init == where, "komira was imported from {}, not from {}".format(init, site)

    fakes = load_path("objectstore_fakes", opts["fakes"])
    with tempfile.TemporaryDirectory(dir=os.getcwd()) as root:
        data = Data(root, opts["readings"])
        check_s3(komira, fakes, data)
        check_azure(komira, fakes, data)
        check_gcs(komira)
        check_wrong_credentials(komira, fakes, data)


if __name__ == "__main__":
    main(sys.argv[1:])
