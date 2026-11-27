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
