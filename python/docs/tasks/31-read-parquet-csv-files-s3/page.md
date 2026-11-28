# How do I read Parquet or CSV files from S3?

Bind a SQL name to the objects with `Session.add_sql_binding(name, komira.files("s3://bucket/key-or-glob", credential=komira.AwsKeys(...), region=...))` and query the name with `Session.sql`; Parquet is read, CSV on S3 is not yet.

<!-- include example.py -->
```python
import http.server
import io
import threading

import pyarrow as pa
import pyarrow.parquet as pq

import komira


# A stand-in for S3 on this machine, so the program runs with no account and
# no network: it serves the objects below by path, as an S3 emulator does.
# Against real S3, leave it out and drop endpoint= below.
def parquet_bytes(table):
    out = io.BytesIO()
    pq.write_table(table, out)
    return out.getvalue()


OBJECTS = {
    "/sales/2026/east.parquet": parquet_bytes(pa.table({"region": ["east", "east"], "amount": [120, 45]})),
    "/sales/2026/west.parquet": parquet_bytes(pa.table({"region": ["west", "west"], "amount": [80, 150]})),
}


class StandIn(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path, _, query = self.path.partition("?")
        status, headers = 200, {}
        if "list-type=2" in query:  # ListObjectsV2: every key; the client filters
            keys = "".join(f"<Contents><Key>{k[len('/sales/'):]}</Key><Size>{len(v)}</Size></Contents>"
                           for k, v in sorted(OBJECTS.items()))
            body = f"<ListBucketResult><IsTruncated>false</IsTruncated>{keys}</ListBucketResult>".encode()
        elif path in OBJECTS:
            body = whole = OBJECTS[path]
            headers["ETag"] = f'"{len(whole):x}"'
            if self.command == "GET" and "Range" in self.headers:  # bytes=a-b, bytes=a-, bytes=-n
                a, b = self.headers["Range"][len("bytes="):].split("-")
                first = max(len(whole) - int(b), 0) if a == "" else int(a)
                last = len(whole) - 1 if a == "" or b == "" else min(int(b), len(whole) - 1)
                body, status = whole[first:last + 1], 206
                headers["Content-Range"] = f"bytes {first}-{last}/{len(whole)}"
        else:
            status, body = 404, b"<Error><Code>NoSuchKey</Code></Error>"
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command == "GET":
            self.wfile.write(body)
        self.close_connection = True

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StandIn)
threading.Thread(target=server.serve_forever, daemon=True).start()
endpoint = f"http://127.0.0.1:{server.server_address[1]}"

# The credential: its name is yours to choose; its values come from where you
# keep secrets (these are the stand-in's, which checks none).
keys = komira.AwsKeys("sales-reader", key_id="AKIDEXAMPLE", secret="stand-in-secret")
print(keys)

with komira.Session() as s:
    # One object, or a glob of objects, under a SQL name.
    s.add_sql_binding("east", komira.files(
        "s3://sales/2026/east.parquet", credential=keys, region="eu-west-1", endpoint=endpoint,
    ))
    s.add_sql_binding("sales", komira.files(
        "s3://sales/2026/*.parquet", credential=keys, region="eu-west-1", endpoint=endpoint,
    ))
    print(s.sql("SELECT count(*) AS orders, sum(amount) AS total FROM east").to_arrow().to_pylist())
    by_region = s.sql("SELECT region, sum(amount) AS total FROM sales GROUP BY region ORDER BY region")
    for row in by_region.to_arrow().to_pylist():
        print(row)

    # What komira does not read yet is refused by name when you bind it.
    try:
        s.add_sql_binding("events", komira.files("gs://sales/2026/*.parquet", credential=komira.ANONYMOUS))
    except komira.KomiraError as e:
        print(type(e).__name__, e.code)

server.shutdown()
```

Output:

<!-- include expected_output.txt -->
```text
AwsKeys('sales-reader', key_id=<set>, secret=<set>)
[{'orders': 2, 'total': Decimal('165')}]
{'region': 'east', 'total': Decimal('165')}
{'region': 'west', 'total': Decimal('230')}
UnsupportedOperation STORAGE_URL_REFUSED
```

## Notes

- `komira.files` takes one object (`s3://sales/2026/east.parquet`) or a glob of objects (`*`, `?`, `[...]`, one `**`; not `{a,b}`), which is listed when the source is bound. `s3a://` is the same scheme. The footers are read when the source is bound, so a missing object or a refused credential raises at `add_sql_binding`, not at the query.
- The credential is a value with a name you choose: `komira.AwsKeys(name, key_id=..., secret=..., session_token=None)`. Binding seals its value on the session under that name, and the engine is given only the name, so no secret is in a log record, an error message or a `repr` (`print(keys)` shows `<set>`). Binding another source with a credential of the same name replaces the value for every table bound under it. Read the values from where you keep secrets, never from the program text.
- `region=` is required for `s3://`: a source without one is refused with `STORAGE_REGION_UNKNOWN`. `endpoint=` reaches a store that is not AWS's own (an emulator, as here, or another S3-compatible store; `http://` is plaintext), and is addressed by path; `url_style="vhost"` or `"path"` chooses, as DuckDB's `URL_STYLE` does.
- The program above runs a stand-in for S3 on this machine so that it needs no account; against real S3, leave the stand-in and `endpoint=` out.
- Azure Blob is read the same way, with `komira.AzureKey` or `komira.AzureSas`: [How do I read files from Google Cloud Storage or Azure Blob?](../93-read-files-google-cloud-storage-azure/page.md) (rank 93, partial: `gs://` is not read yet).
- Not read yet, each refused by name when the source is bound: CSV and JSON objects, `gs://` and `https://` locations (`STORAGE_URL_REFUSED`, as the last line shows), the process's own AWS identity (`komira.AMBIENT`, the default credential: `CREDENTIALS_NOT_FOUND`), unsigned reads (`komira.ANONYMOUS`) and `komira.AwsProfile` on `s3://`. A URL written in the SQL text (`FROM 's3://...'`) and the DataFrame readers do not read object stores yet. komira-ai/komira#2337 tracks them.
- `Session.add_sql_binding`, `komira.files` and the credential classes are newer than the PyPI release 0.1.1623.

## Related

- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I read many files matching a pattern into one table?](../19-read-many-files-matching-pattern-table/page.md) (rank 19, partial)
- [How do I run SQL on a CSV or Parquet file (or a DataFrame)?](../37-run-sql-csv-parquet-file/page.md) (rank 37, works)
