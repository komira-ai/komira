# =============================================================================
# src/kci_pkg_upload/conda_repodata.mojo — "does this conda subdir list the
#   file, and with what sha256?", read from the subdir's `repodata.json`.
# =============================================================================
#
#   GET <channel>/<subdir>/repodata.json
#   {"info": {"subdir": "linux-64"},
#    "packages":       {"<name>-<ver>-<build>.tar.bz2": {"sha256": ..., ...}},
#    "packages.conda": {"<name>-<ver>-<build>.conda":   {"sha256": ..., ...}}}
#
# A `.conda` file is listed under `packages.conda`, a `.tar.bz2` file under
# `packages`; each entry is keyed by the exact file name and carries `sha256`
# (also `md5` and `size`, which this reader does not compare).
#
# ⛔ ABSENT ONLY FROM A LISTING THAT WAS READ. ABSENT is the presence answer on
# which a publisher UPLOADS, so a listing that could not be read must never
# produce it:
#   * a 200 whose body is not a JSON object is UNKNOWN;
#   * the format's key present but not an object (`null`, an array, a string)
#     is UNKNOWN naming the key;
#   * the format's key MISSING is ABSENT only when the other format's key is
#     present as an object (a repodata written before `.conda` existed lists
#     no `.conda` file); a document carrying neither key is UNKNOWN;
#   * an entry that names the file but is not an object, or whose `sha256` is
#     not a string, is UNKNOWN — the entry is there and cannot be compared.
# A listed entry with no `sha256` is PRESENT with no exposed digest, which
# `presence` turns into NO_COMMON_FIELD, never IDENTICAL.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_json import JSON_STRING, parse_json_value

from .http_read import GetResult
from .index_lookup import IndexEntry
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


comptime CONDA_PACKAGES_KEY: String = "packages.conda"
"""The repodata key that lists `.conda` files."""

comptime TAR_BZ2_PACKAGES_KEY: String = "packages"
"""The repodata key that lists `.tar.bz2` files."""


def repodata_key_for(file_name: String) raises -> String:
    """The repodata key that lists `file_name`: `packages.conda` for a
    `.conda` file, `packages` for a `.tar.bz2` one. RAISES (a local fault) for
    any other extension: a conda channel serves no other file kind."""
    if file_name.endswith(String(".conda")):
        return String(CONDA_PACKAGES_KEY)
    if file_name.endswith(String(".tar.bz2")):
        return String(TAR_BZ2_PACKAGES_KEY)
    raise Error(
        String("kci_pkg_upload: '")
        + file_name
        + String("' is not a conda package file (.conda or .tar.bz2)")
    )


def _entry(
    kind: Int, got: GetResult, var sha256_hex: String, var detail: String
) -> IndexEntry:
    return IndexEntry(
        kind,
        got.response.status,
        sha256_hex^,
        String(""),
        got.host.copy(),
        got.path.copy(),
        False,
        detail^,
    )


def classify_repodata_answer(
    got: GetResult, file_name: String, authorization: String
) raises -> IndexEntry:
    """Turn one repodata GET into an `IndexEntry` for `file_name`.
    RAISES only for a file name with no repodata key (a local fault)."""
    var key = repodata_key_for(file_name)
    if not got.ok:
        return _entry(READ_UNKNOWN, got, String(""), got.detail.copy())
    var status = got.response.status
    if status == 404:
        return _entry(
            READ_ABSENT,
            got,
            String(""),
            String("the channel answered 404 for ") + got.host + got.path,
        )
    if status == 401 or status == 403:
        return _entry(
            READ_AUTH_REFUSED,
            got,
            String(""),
            withhold_if_echoes(
                String("the channel answered ")
                + String(status)
                + String(": ")
                + excerpt_unless_echoes(got.response.body, authorization),
                authorization,
            ),
        )
    if status == 429:
        return _entry(
            READ_RATE_LIMITED, got, String(""), String("the channel answered 429")
        )
    if status != 200:
        return _entry(
            READ_UNKNOWN,
            got,
            String(""),
            withhold_if_echoes(
                String("the channel answered HTTP ")
                + String(status)
                + String(": ")
                + excerpt_unless_echoes(got.response.body, authorization),
                authorization,
            ),
        )
    try:
        var text = decode_utf8(Span(got.response.body), String("the repodata"))
        var doc = parse_json_value(text)
        if not doc.is_object():
            return _entry(
                READ_UNKNOWN,
                got,
                String(""),
                String("the repodata is not a JSON object: it cannot be read,")
                + String(" so it is not ABSENT"),
            )
        if not doc.has(key):
            var other = String(TAR_BZ2_PACKAGES_KEY)
            if key == String(TAR_BZ2_PACKAGES_KEY):
                other = String(CONDA_PACKAGES_KEY)
            if doc.has(other) and doc.get(other).is_object():
                return _entry(
                    READ_ABSENT,
                    got,
                    String(""),
                    String("the repodata has no '")
                    + key
                    + String("' listing, so it lists no file named ")
                    + file_name,
                )
            return _entry(
                READ_UNKNOWN,
                got,
                String(""),
                String("the repodata has neither a '")
                + key
                + String("' nor a '")
                + other
                + String("' listing: it cannot be read, so it is not ABSENT"),
            )
        var listing = doc.get(key)
        if not listing.is_object():
            return _entry(
                READ_UNKNOWN,
                got,
                String(""),
                String("the repodata's '")
                + key
                + String("' is not an object: the listing cannot be read, so")
                + String(" it is not ABSENT"),
            )
        if not listing.has(file_name):
            return _entry(
                READ_ABSENT,
                got,
                String(""),
                String("the repodata lists no file named ") + file_name,
            )
        var entry = listing.get(file_name)
        if not entry.is_object():
            return _entry(
                READ_UNKNOWN,
                got,
                String(""),
                String("the repodata's entry for ")
                + file_name
                + String(" is not an object"),
            )
        var sha = String("")
        if entry.has(String("sha256")):
            var v = entry.get(String("sha256"))
            if v.kind_tag() != JSON_STRING:
                return _entry(
                    READ_UNKNOWN,
                    got,
                    String(""),
                    String("the repodata's sha256 for ")
                    + file_name
                    + String(" is not a string"),
                )
            sha = v.as_string()
        return _entry(READ_PRESENT, got, sha^, String(""))
    except e:
        return _entry(
            READ_UNKNOWN,
            got,
            String(""),
            String("the repodata could not be read: ") + String(e),
        )
