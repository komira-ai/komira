# =============================================================================
# src/kci_pkg_upload/index_lookup.mojo — "which files does the index
#   list for this project, and what digest and URL does it give each?", for
#   the two JSON shapes the python arms read.
# =============================================================================
#
#   PyPI JSON API (warehouse)   GET /pypi/<normalized>/<version>/json
#       {"urls": [{"filename": …, "digests": {"sha256": …}, "url": …}, …]}
#   PEP 691 simple index        GET <repo>/simple/<normalized>/
#       Accept: application/vnd.pypi.simple.v1+json
#       {"files": [{"filename": …, "hashes": {"sha256": …}, "url": …}, …]}
#
# The answer is a `READ_*` kind plus, when the file is listed, its exposed
# sha256 (EMPTY = the entry names no sha256) and its URL. A 404 for the project
# or version is ABSENT.
#
# ⛔ ABSENT ONLY FROM A LISTING THAT WAS READ. ABSENT is the presence answer on
# which a publisher UPLOADS, so a listing that could not be read must never
# produce it:
#   * the array key missing, or present but not an array (`null`, an object, a
#     string), is UNKNOWN naming the key. `JsonValue.array_len()` is 0 for ANY
#     non-array, so a bare loop over it would read `{"files": null}` as an
#     empty listing and answer ABSENT;
#   * an entry that is not an object, or has no string `filename`, is
#     UNREADABLE. The file found in some other entry is still PRESENT. A
#     listing is ABSENT only when EVERY entry was readable and none names the
#     file (an empty array included); otherwise it is UNKNOWN, because the
#     unreadable entry could be the file.
# The PEP 691 shape is kept for a python index that serves only the simple
# API; the PyPI arm reads the JSON API.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_json import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NULL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
)

from .http_read import GetResult
from .outcome import (
    READ_ABSENT,
    READ_AUTH_REFUSED,
    READ_PRESENT,
    READ_RATE_LIMITED,
    READ_UNKNOWN,
    excerpt_unless_echoes,
    withhold_if_echoes,
)
from .wire import decode_utf8


comptime PEP691_JSON: String = "application/vnd.pypi.simple.v1+json"


struct IndexEntry(Copyable, Movable, Deinitable):
    """One index answer about one file.

      kind        — a `READ_*` kind (PRESENT = the index lists the file;
                    ABSENT only from a listing read in full, see the header).
      status      — the HTTP status that decided (0 = no answer).
      sha256_hex  — the sha256 the index exposes for it, EMPTY if none.
      url         — the file's URL as the index wrote it (maybe relative).
      page_host / page_path — where the listing came from (to resolve `url`).
      not_json    — the index answered 200 in a shape that is not the JSON
                    asked for (an HTML simple page): the listing could not be
                    read, which is neither ABSENT nor PRESENT.
      detail      — why, for a human.

    Layout: Ints, a Bool and owned Strings. No pointer field."""

    var kind: Int
    var status: Int
    var sha256_hex: String
    var url: String
    var page_host: String
    var page_path: String
    var not_json: Bool
    var detail: String

    def __init__(
        out self,
        kind: Int,
        status: Int,
        var sha256_hex: String,
        var url: String,
        var page_host: String,
        var page_path: String,
        not_json: Bool,
        var detail: String,
    ):
        self.kind = kind
        self.status = status
        self.sha256_hex = sha256_hex^
        self.url = url^
        self.page_host = page_host^
        self.page_path = page_path^
        self.not_json = not_json
        self.detail = detail^


def _answer(
    kind: Int, got: GetResult, var detail: String, not_json: Bool = False
) -> IndexEntry:
    return IndexEntry(
        kind,
        got.response.status,
        String(""),
        String(""),
        got.host.copy(),
        got.path.copy(),
        not_json,
        detail^,
    )


def _json_kind_word(tag: Int) -> String:
    if tag == JSON_NULL:
        return String("null")
    if tag == JSON_BOOL:
        return String("a boolean")
    if tag == JSON_NUMBER:
        return String("a number")
    if tag == JSON_STRING:
        return String("a string")
    if tag == JSON_ARRAY:
        return String("an array")
    if tag == JSON_OBJECT:
        return String("an object")
    return String("JSON kind ") + String(tag)


def _entry_is_readable(entry: JsonValue) -> Bool:
    """An index entry this reader can match: an object whose `filename` is
    a string. Any other entry is UNREADABLE, and a listing holding one cannot
    be ABSENT (see the file header)."""
    if not entry.is_object() or not entry.has(String("filename")):
        return False
    try:
        return entry.get(String("filename")).kind_tag() == JSON_STRING
    except:
        return False  # cov: unreachable get() raises only on a non-object or a missing key, both checked above


def classify_index_answer(
    got: GetResult,
    file_name: String,
    array_key: String,
    digests_key: String,
    json_content_type: String,
    authorization: String,
) -> IndexEntry:
    """Turn one index GET into an `IndexEntry`.

      array_key         `urls` (PyPI JSON API) | `files` (PEP 691)
      digests_key       `digests` | `hashes`
      json_content_type EMPTY = do not check (PyPI's JSON API is always JSON);
                        otherwise a 200 whose Content-Type does not start with
                        it is `not_json` (an index that ignored the Accept)."""
    if not got.ok:
        return _answer(READ_UNKNOWN, got, got.detail.copy())
    var status = got.response.status
    if status == 404:
        return _answer(
            READ_ABSENT, got, String("the index answered 404 for ") + got.host + got.path
        )
    if status == 401 or status == 403:
        return _answer(
            READ_AUTH_REFUSED,
            got,
            withhold_if_echoes(
                String("the index answered ")
                + String(status)
                + String(": ")
                + excerpt_unless_echoes(got.response.body, authorization),
                authorization,
            ),
        )
    if status == 429:
        return _answer(READ_RATE_LIMITED, got, String("the index answered 429"))
    if status != 200:
        return _answer(
            READ_UNKNOWN,
            got,
            withhold_if_echoes(
                String("the index answered HTTP ")
                + String(status)
                + String(": ")
                + excerpt_unless_echoes(got.response.body, authorization),
                authorization,
            ),
        )
    if json_content_type.byte_length() > 0:
        var ct = got.response.header(String("content-type"))
        if not ct.startswith(json_content_type):
            return _answer(
                READ_UNKNOWN,
                got,
                String("the index answered 200 as '")
                + ct
                + String("', not ")
                + json_content_type,
                not_json=True,
            )
    try:
        var text = decode_utf8(Span(got.response.body), String("the index listing"))
        var doc = parse_json_value(text)
        if not doc.has(array_key):
            return _answer(
                READ_UNKNOWN,
                got,
                String("the index listing has no '") + array_key + String("' array"),
            )
        var arr = doc.get(array_key)
        if arr.kind_tag() != JSON_ARRAY:
            return _answer(
                READ_UNKNOWN,
                got,
                String("the index listing's '")
                + array_key
                + String("' is ")
                + _json_kind_word(arr.kind_tag())
                + String(", not an array: the listing cannot be read, so it is not ABSENT"),
            )
        var unreadable = 0
        for i in range(arr.array_len()):
            var entry = arr.element_at(i)
            if not _entry_is_readable(entry):
                unreadable += 1
                continue
            if entry.get(String("filename")).as_string() != file_name:
                continue
            var sha = String("")
            if entry.has(digests_key):
                var d = entry.get(digests_key)
                if d.has(String("sha256")):
                    sha = d.get(String("sha256")).as_string()
            var url = String("")
            if entry.has(String("url")):
                url = entry.get(String("url")).as_string()
            return IndexEntry(
                READ_PRESENT,
                status,
                sha^,
                url^,
                got.host.copy(),
                got.path.copy(),
                False,
                String(""),
            )
        if unreadable > 0:
            return _answer(
                READ_UNKNOWN,
                got,
                String("the index listing's '")
                + array_key
                + String("' names no file ")
                + file_name
                + String(", but ")
                + String(unreadable)
                + String(" of its ")
                + String(arr.array_len())
                + String(
                    " entries could not be read (not an object, or no string"
                    " 'filename'), and one of them could be it: not ABSENT"
                ),
            )
        return _answer(
            READ_ABSENT,
            got,
            String("the index lists no file named ") + file_name,
        )
    except e:
        return _answer(
            READ_UNKNOWN,
            got,
            String("the index listing could not be read: ") + String(e),
        )
