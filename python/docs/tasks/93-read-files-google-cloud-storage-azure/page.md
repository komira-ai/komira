# How do I read files from Google Cloud Storage or Azure Blob?

For Azure Blob, bind a SQL name to the blobs with `Session.add_sql_binding(name, komira.files("az://container/blob-or-glob", credential=komira.AzureSas(...)))` (or `komira.AzureKey`) and query the name with `Session.sql`; Google Cloud Storage (`gs://`) is not read yet.

<!-- include example.py -->
```python
import http.server
import io
import threading

import pyarrow as pa
import pyarrow.parquet as pq

import komira


# A stand-in for Azure Blob Storage on this machine, so the program runs with
# no account and no network: it serves the blobs below by path
# (/<account>/<container>/<blob>), as the Azurite emulator does. Against
# Azure, leave it out and drop endpoint= below.
def parquet_bytes(table):
    out = io.BytesIO()
    pq.write_table(table, out)
    return out.getvalue()


BLOBS = {
    "2026/q1.parquet": parquet_bytes(pa.table({"product": ["tea", "cake"], "units": [30, 12]})),
    "2026/q2.parquet": parquet_bytes(pa.table({"product": ["tea", "cake"], "units": [41, 9]})),
}


class StandIn(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path, _, query = self.path.partition("?")
        blob = path[len("/salesacct/reports/"):]
        status, headers = 200, {}
        if "comp=list" in query:  # List Blobs: every blob; the client filters
            names = "".join(f"<Blob><Name>{name}</Name><Properties><Content-Length>{len(data)}</Content-Length>"
                            "</Properties></Blob>" for name, data in sorted(BLOBS.items()))
            body = f"<EnumerationResults><Blobs>{names}</Blobs><NextMarker /></EnumerationResults>".encode()
        elif path.startswith("/salesacct/reports/") and blob in BLOBS:
            body = whole = BLOBS[blob]
            headers["ETag"] = f'"{len(whole):x}"'
            headers["x-ms-blob-type"] = "BlockBlob"
            asked = self.headers.get("x-ms-range") or self.headers.get("Range")
            if self.command == "GET" and asked:  # bytes=a-b or bytes=a-
                a, b = asked[len("bytes="):].split("-")
                first, last = int(a), len(whole) - 1 if b == "" else min(int(b), len(whole) - 1)
                body, status = whole[first:last + 1], 206
                headers["Content-Range"] = f"bytes {first}-{last}/{len(whole)}"
        else:
            status, body = 404, b"<Error><Code>BlobNotFound</Code></Error>"
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

# A shared access signature for the container (komira.AzureKey takes the
# account key instead). Its name is yours to choose; its value comes from
# where you keep secrets (this one is the stand-in's, which checks none).
sas = komira.AzureSas("reports-reader", account="salesacct", sas="sv=2024-08-04&sr=c&sp=rl&sig=stand-in")
print(sas)

with komira.Session() as s:
    s.add_sql_binding("sales", komira.files("az://reports/2026/*.parquet", credential=sas, endpoint=endpoint))
    totals = s.sql("SELECT product, sum(units) AS units FROM sales GROUP BY product ORDER BY product")
    for row in totals.to_arrow().to_pylist():
        print(row)

    # Google Cloud Storage is not read yet: binding a gs:// location is
    # refused by name.
    try:
        s.add_sql_binding("events", komira.files("gs://events/2026/*.parquet", credential=komira.ANONYMOUS))
    except komira.KomiraError as e:
        print(type(e).__name__, e.code)

server.shutdown()
```

Output:

<!-- include expected_output.txt -->
```text
AzureSas('reports-reader', account='salesacct', sas=<set>)
{'product': 'cake', 'units': 21}
{'product': 'tea', 'units': 71}
UnsupportedOperation STORAGE_URL_REFUSED
```

## Notes

- `az://container/blob` names the container and the blob; `abfs://` and `abfss://` locations are read too. The account is the credential's: `komira.AzureSas(name, account=..., sas=...)` with a shared access signature, or `komira.AzureKey(name, account=..., key=...)` with the account's Shared Key. The blob may be a glob (`*`, `?`, `[...]`, `{a,b}`, one `**`), listed when the source is bound, and every footer is read then, so a missing blob or a refused credential raises at `add_sql_binding`.
- The credential's name is yours to choose. Binding seals its value on the session under that name and gives the engine the name only, so no secret is in a log record, an error message or a `repr` (`print(sas)` shows `<set>`). Read the values from where you keep secrets, never from the program text.
- `endpoint=` reaches a service that is not Azure's own, addressed by path as here; `http://` is plaintext. An `az://` source takes no `region=`.
- The program above runs a stand-in for Azure Blob on this machine so that it needs no account; against Azure, leave the stand-in and `endpoint=` out.
- Google Cloud Storage is the gap: a `gs://` location is refused by name (`STORAGE_URL_REFUSED`, the last line of the output), with any credential. So are CSV and JSON blobs, a URL written in the SQL text (`FROM 'az://...'`), and the DataFrame readers on a URL. komira-ai/komira#2337 tracks them.
- `Session.add_sql_binding`, `komira.files` and the credential classes are newer than the PyPI release 0.1.1623.

## Related

- [How do I read Parquet or CSV files from S3?](../31-read-parquet-csv-files-s3/page.md) (rank 31, partial)
- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I read many files matching a pattern into one table?](../19-read-many-files-matching-pattern-table/page.md) (rank 19, partial)
