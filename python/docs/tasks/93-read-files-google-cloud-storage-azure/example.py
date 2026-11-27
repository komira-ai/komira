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
