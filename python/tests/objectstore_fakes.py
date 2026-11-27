"""Loopback stand-ins for S3 and Azure Blob, for tests that bind object-store
sources with `Session.add_sql_binding` and query them through libkomira.

`FakeS3` and `FakeAzure` are HTTP/1.1 servers on 127.0.0.1, on a port the
kernel picks (port 0), each serving on a thread of its own; a test gives a
source the fake's `endpoint` (`http://127.0.0.1:<port>`), which the library
reads in plaintext and addresses by path, as it does any endpoint of the
source's own. Each keeps its objects in memory and answers what a reader of
Parquet sends, as the service does: a HEAD, a GET of the whole object or of
a range (`bytes=a-b`, `bytes=a-`, and for S3 the suffix `bytes=-n`), and a
listing (S3's ListObjectsV2, Azure's List Blobs) with a prefix. Every answer
closes its connection. Anything else is 405.

Each checks the request's credential the way its service does, so a read
succeeds only with the right secret:

- `FakeS3(key_id, secret, region)` verifies the AWS Signature Version 4 of
  every request: the access key id and the region of the credential scope,
  then the signature over the canonical request (method, path as sent, the
  sorted re-encoded query, the signed headers, the payload hash of
  `x-amz-content-sha256`), with the signing key derived from `secret`.
- `FakeAzure(account, key=...)` verifies the Shared Key signature of every
  request (the twelve standard header lines, the `x-ms-*` headers, and the
  canonicalized resource, as the Azurite emulator reads a path-style request:
  `/<account>` before the path, which already starts with the account; the
  form without the second account is accepted too). `FakeAzure(account,
  sas=...)` requires every parameter of the SAS in the query, with its value,
  and no Authorization header.

A refused request is answered 403 with the service's error code, and
`refusals` holds (code, why) for it; `why` holds the string the fake signed
when a signature did not match, so a test that expects none can print it.
`requests` holds every request as received: method, path, query, headers
(names in lower case) and the head as one text, so a test can check that no
secret ever reached the store. A fake is a context manager; leaving it shuts
the server down.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import http.server
import threading
from urllib.parse import quote, unquote
from xml.sax.saxutils import escape

_EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


class Request:
    """One request as the fake received it."""

    __slots__ = ("method", "path", "query", "headers", "head")

    def __init__(self, method: str, path: str, query: str, headers: dict[str, str], head: str) -> None:
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.head = head


def _params(query: str) -> list[tuple[str, str]]:
    """The query's parameters, decoded, in order. `+` stays `+`: the clients
    percent-encode a space."""
    out = []
    for part in query.split("&") if query else []:
        k, _, v = part.partition("=")
        out.append((unquote(k), unquote(v)))
    return out


def _range(spec: str | None, size: int, suffix: bool) -> tuple[int, int] | None:
    """(first, last) of the bytes `spec` asks for, the whole object when
    `spec` is None, or None when the range cannot be satisfied."""
    if spec is None:
        return 0, size - 1
    if not spec.startswith("bytes="):
        return None
    first, dash, last = spec[len("bytes=") :].partition("-")
    if not dash:
        return None
    if not first:
        if not suffix or not last or size == 0:
            return None
        return max(0, size - int(last)), size - 1
    a = int(first)
    b = size - 1 if not last else min(int(last), size - 1)
    if a >= size or b < a:
        return None
    return a, b


class _Fake:
    """The server, the objects (`"<bucket>/<key>"` -> bytes) and what was
    received; a subclass answers (`answer`)."""

    # Azure has no suffix range.
    _SUFFIX_RANGES = True

    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}
        self.requests: list[Request] = []
        self.refusals: list[tuple[str, str]] = []
        self._lock = threading.Lock()
        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _handler(self))
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        self.endpoint = "http://127.0.0.1:{}".format(self._server.server_address[1])

    def put(self, bucket: str, key: str, body: bytes) -> None:
        self.objects[bucket + "/" + key] = body

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join()

    def __enter__(self) -> _Fake:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _refuse(self, status: int, code: str, why: str) -> tuple[int, list[tuple[str, str]], bytes]:
        with self._lock:
            self.refusals.append((code, why))
        return self._error(status, code)

    def _error(self, status: int, code: str) -> tuple[int, list[tuple[str, str]], bytes]:
        body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>{}</Code><Message>fake</Message></Error>"
        return status, [("Content-Type", "application/xml"), ("x-ms-error-code", code)], body.format(code).encode()

    def _object(self, req: Request, name: str) -> tuple[int, list[tuple[str, str]], bytes]:
        body = self.objects.get(name)
        if body is None:
            return self._error(404, self._NOT_FOUND)
        etag = [("ETag", '"{}"'.format(hashlib.md5(body).hexdigest()))]
        if req.method == "HEAD":
            return 200, etag, body
        spec = req.headers.get("x-ms-range", req.headers.get("range"))
        span = _range(spec, len(body), self._SUFFIX_RANGES)
        if span is None:
            return self._error(416, "InvalidRange")
        if spec is None:
            return 200, etag, body
        first, last = span
        headers = etag + [("Content-Range", "bytes {}-{}/{}".format(first, last, len(body)))]
        return 206, headers, body[first : last + 1]

    _NOT_FOUND = "NoSuchKey"

    def answer(self, req: Request) -> tuple[int, list[tuple[str, str]], bytes]:
        raise NotImplementedError


def _handler(fake: _Fake) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _serve(self) -> None:
            path, _, query = self.path.partition("?")
            headers = {k.lower(): v for k, v in self.headers.items()}
            req = Request(self.command, path, query, headers, self.requestline + "\r\n" + str(self.headers))
            with fake._lock:
                fake.requests.append(req)
            if self.command in ("GET", "HEAD"):
                status, extra, body = fake.answer(req)
            else:
                status, extra, body = fake._error(405, "MethodNotAllowed")
            self.send_response(status)
            for k, v in extra:
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            self.close_connection = True

        do_GET = do_HEAD = do_PUT = do_POST = do_DELETE = _serve

        def log_message(self, format: str, *args: object) -> None:
            pass

    return Handler


class FakeS3(_Fake):
    """S3, path-style, for one access key."""

    def __init__(self, key_id: str, secret: str, region: str) -> None:
        self.key_id = key_id
        self.secret = secret
        self.region = region
        super().__init__()

    def answer(self, req: Request) -> tuple[int, list[tuple[str, str]], bytes]:
        refused = self._check_signature(req)
        if refused is not None:
            return self._refuse(403, *refused)
        bucket, _, key = unquote(req.path[1:]).partition("/")
        params = dict(_params(req.query))
        if not key and params.get("list-type") == "2" and req.method == "GET":
            return self._list(bucket, params)
        return self._object(req, bucket + "/" + key)

    def _check_signature(self, req: Request) -> tuple[str, str] | None:
        auth = req.headers.get("authorization", "")
        algorithm = "AWS4-HMAC-SHA256 "
        if not auth.startswith(algorithm):
            return "AccessDenied", "the request is not signed with SigV4"
        parts = {}
        for item in auth[len(algorithm) :].split(","):
            k, _, v = item.strip().partition("=")
            parts[k] = v
        scope = parts.get("Credential", "").split("/")
        if len(scope) != 5 or scope[0] != self.key_id:
            return "InvalidAccessKeyId", "the credential names another access key id"
        if scope[2:] != [self.region, "s3", "aws4_request"]:
            return "AuthorizationHeaderMalformed", "the credential scope is " + "/".join(scope[1:])
        signed = parts.get("SignedHeaders", "")
        canonical_query = "&".join(
            "{}={}".format(k, v)
            for k, v in sorted((quote(k, safe="-_.~"), quote(v, safe="-_.~")) for k, v in _params(req.query))
        )
        canonical = "\n".join(
            [
                req.method,
                req.path,
                canonical_query,
                "".join("{}:{}\n".format(h, " ".join(req.headers.get(h, "").split())) for h in signed.split(";")),
                signed,
                req.headers.get("x-amz-content-sha256", _EMPTY_SHA256),
            ]
        )
        to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                req.headers.get("x-amz-date", ""),
                "/".join(scope[1:]),
                hashlib.sha256(canonical.encode()).hexdigest(),
            ]
        )
        key = ("AWS4" + self.secret).encode()
        for part in scope[1:]:
            key = hmac.new(key, part.encode(), hashlib.sha256).digest()
        want = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(want, parts.get("Signature", "")):
            return "SignatureDoesNotMatch", "the fake signed:\n" + to_sign + "\nover:\n" + canonical
        return None

    def _list(self, bucket: str, params: dict[str, str]) -> tuple[int, list[tuple[str, str]], bytes]:
        prefix = params.get("prefix", "")
        delimiter = params.get("delimiter", "")
        after = params.get("continuation-token", params.get("start-after", ""))
        max_keys = int(params.get("max-keys", "1000"))
        entries, groups, count, truncated, last = [], [], 0, False, ""
        for name in sorted(self.objects):
            if not name.startswith(bucket + "/" + prefix):
                continue
            key = name[len(bucket) + 1 :]
            if after and key <= after:
                continue
            group = ""
            if delimiter:
                rest = key[len(prefix) :]
                d = rest.find(delimiter)
                if d >= 0:
                    group = prefix + rest[: d + len(delimiter)]
            if group and group in groups:
                last = key
                continue
            if count == max_keys:
                truncated = True
                break
            count += 1
            last = key
            if group:
                groups.append(group)
                entries.append("<CommonPrefixes><Prefix>{}</Prefix></CommonPrefixes>".format(escape(group)))
            else:
                body = self.objects[name]
                entries.append(
                    "<Contents><Key>{}</Key><Size>{}</Size><ETag>\"{}\"</ETag></Contents>".format(
                        escape(key), len(body), hashlib.md5(body).hexdigest()
                    )
                )
        xml = '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        xml += "<Name>{}</Name><Prefix>{}</Prefix><KeyCount>{}</KeyCount><MaxKeys>{}</MaxKeys>".format(
            escape(bucket), escape(prefix), count, max_keys
        )
        xml += "<IsTruncated>{}</IsTruncated>".format("true" if truncated else "false") + "".join(entries)
        if truncated:
            xml += "<NextContinuationToken>{}</NextContinuationToken>".format(escape(last))
        xml += "</ListBucketResult>"
        return 200, [("Content-Type", "application/xml")], xml.encode()


class FakeAzure(_Fake):
    """Azure Blob, path-style (`/<account>/<container>/<blob>`), for one
    account read with its Shared Key (`key`, base64) or a SAS (`sas`)."""

    _SUFFIX_RANGES = False
    _NOT_FOUND = "BlobNotFound"

    def __init__(self, account: str, *, key: str | None = None, sas: str | None = None) -> None:
        self.account = account
        self.key = key
        self.sas = _params(sas) if sas is not None else None
        super().__init__()

    def answer(self, req: Request) -> tuple[int, list[tuple[str, str]], bytes]:
        refused = self._check_auth(req)
        if refused is not None:
            return self._refuse(403, *refused)
        account, _, rest = unquote(req.path[1:]).partition("/")
        if account != self.account:
            return self._refuse(403, "InvalidUri", "the path names account " + account)
        container, _, blob = rest.partition("/")
        params = dict(_params(req.query))
        if not blob and params.get("comp") == "list" and req.method == "GET":
            return self._list(container, params)
        return self._object(req, container + "/" + blob)

    def _check_auth(self, req: Request) -> tuple[str, str] | None:
        auth = req.headers.get("authorization")
        if self.sas is not None:
            if auth is not None:
                return "AuthenticationFailed", "a SAS request carries an Authorization header"
            got = _params(req.query)
            missing = [k for k, v in self.sas if (k, v) not in got]
            if missing:
                return "AuthenticationFailed", "the query lacks the SAS parameters " + ",".join(missing)
            return None
        if self.key is None:
            return None
        prefix = "SharedKey {}:".format(self.account)
        if auth is None or not auth.startswith(prefix):
            return "AuthenticationFailed", "the request is not signed with the account's Shared Key"
        h = req.headers
        length = h.get("content-length", "")
        lines = [
            req.method,
            h.get("content-encoding", ""),
            h.get("content-language", ""),
            "" if length == "0" else length,
            h.get("content-md5", ""),
            h.get("content-type", ""),
            "" if "x-ms-date" in h else h.get("date", ""),
            h.get("if-modified-since", ""),
            h.get("if-match", ""),
            h.get("if-none-match", ""),
            h.get("if-unmodified-since", ""),
            h.get("range", ""),
        ]
        headers = "".join("{}:{}\n".format(k, h[k].strip()) for k in sorted(k for k in h if k.startswith("x-ms-")))
        grouped: dict[str, list[str]] = {}
        for k, v in _params(req.query):
            grouped.setdefault(k.lower(), []).append(v)
        query = "".join("\n{}:{}".format(k, ",".join(sorted(grouped[k]))) for k in sorted(grouped))
        without_account = req.path[len(self.account) + 1 :] if req.path.startswith("/" + self.account + "/") else ""
        secret = base64.b64decode(self.key)
        tried = []
        for path in (req.path, without_account):
            if not path:
                continue
            to_sign = "\n".join(lines) + "\n" + headers + "/" + self.account + path + query
            want = base64.b64encode(hmac.new(secret, to_sign.encode(), hashlib.sha256).digest()).decode()
            if hmac.compare_digest(want, auth[len(prefix) :]):
                return None
            tried.append(to_sign)
        return "AuthenticationFailed", "the fake signed:\n" + "\n--- or:\n".join(tried)

    def _list(self, container: str, params: dict[str, str]) -> tuple[int, list[tuple[str, str]], bytes]:
        prefix = params.get("prefix", "")
        blobs = []
        for name in sorted(self.objects):
            if not name.startswith(container + "/" + prefix):
                continue
            body = self.objects[name]
            blobs.append(
                "<Blob><Name>{}</Name><Properties><Content-Length>{}</Content-Length>"
                "<Etag>\"{}\"</Etag><BlobType>BlockBlob</BlobType></Properties></Blob>".format(
                    escape(name[len(container) + 1 :]), len(body), hashlib.md5(body).hexdigest()
                )
            )
        xml = '<?xml version="1.0" encoding="utf-8"?><EnumerationResults ContainerName="{}">'.format(escape(container))
        xml += "<Prefix>{}</Prefix><Blobs>{}</Blobs><NextMarker /></EnumerationResults>".format(
            escape(prefix), "".join(blobs)
        )
        return 200, [("Content-Type", "application/xml")], xml.encode()
