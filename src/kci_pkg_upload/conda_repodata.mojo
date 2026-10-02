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
# ─── WHICH PACKAGE NAMES A SUBDIR HOLDS (`NameListing`) ─────────────────────
# `classify_repodata_names` reads the SAME document for a different question:
# the set of package names with any file in the subdir, from the keys of BOTH
# listings (`<name>-<version>-<build>.conda|.tar.bz2`, split at the last two
# `-`, the name lowercased: a conda name is lowercase). A publisher uses it to
# tell a name it is CLAIMING for the first time from one the channel already
# holds. It also keeps every listed FILE name (`files`, `files_of(name)`), so
# a publisher can tell a name that only its own earlier upload holds (a re-run
# after a partial publish) from a name somebody else's file holds. The same
# discipline holds, in the other direction: a listing that
# was not read yields NO names and the kind UNKNOWN, never an empty PRESENT
# that would read as "every name is new":
#   * a key with neither extension, or not `<name>-<version>-<build>`, is
#     UNKNOWN naming the key: the listing holds a file whose name cannot be
#     told, so the set is not known;
#   * an entry that is not an object is UNKNOWN, as for `read_back`;
#   * each format key present-but-not-an-object, or both absent, is UNKNOWN.
# A 404 is ABSENT: the channel says the subdir holds no repodata, so no name.
# [UNVERIFIED: that prefix.dev answers 404, not an empty repodata, for a subdir
# that never held a file. Either answer yields no names.]
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_json import JSON_OBJECT, JSON_STRING, parse_json_value

from .http_read import GetResult
from .identity import ascii_lower
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


struct NameListing(Copyable, Movable, Deinitable):
    """The package names a conda subdir holds a file under.

      kind   — a READ_* kind. READ_PRESENT: the listing was read, and `names`
               is every name in it (possibly none). READ_ABSENT: the subdir
               has no repodata (404), so no name. Any other kind: the listing
               was NOT read, and `names` is EMPTY and means nothing.
      names  — lowercase, sorted bytewise, each once.
      files  — every file name the listing holds (both formats), exactly as
               listed, sorted bytewise, each once. EMPTY unless READ_PRESENT.
               A publisher asks `files_of(name)` to tell a name only its OWN
               earlier upload holds from one somebody else's file holds.
      detail — for a human, when the kind is not READ_PRESENT.

    Layout: Ints and owned values. No pointer field."""

    var kind: Int
    var status: Int
    var names: List[String]
    var files: List[String]
    var detail: String

    def __init__(
        out self,
        kind: Int,
        status: Int,
        var names: List[String],
        var files: List[String],
        var detail: String,
    ):
        self.kind = kind
        self.status = status
        self.names = names^
        self.files = files^
        self.detail = detail^

    def was_read(self) -> Bool:
        """True iff the answer says which names the subdir holds: a listing
        that was read (READ_PRESENT) or a subdir with no repodata
        (READ_ABSENT). Every other kind is a listing that was not read."""
        return self.kind == READ_PRESENT or self.kind == READ_ABSENT

    def holds(self, name: String) raises -> Bool:
        """Whether the subdir holds a file of package `name` (compared
        lowercased). RAISES when the listing was not read: "not held" must
        never be answered from a listing nobody read."""
        if not self.was_read():
            raise Error(
                String("kci_pkg_upload: asked whether a subdir holds '")
                + name
                + String("' from a listing that was not read: ")
                + self.detail
            )
        var want = ascii_lower(name)
        for i in range(len(self.names)):
            if self.names[i] == want:
                return True
        return False


    def files_of(self, name: String) raises -> List[String]:
        """The listed file names whose package name is `name` (compared
        lowercased), in `files` order. RAISES when the listing was not read,
        for the same reason as `holds`."""
        if not self.was_read():
            raise Error(
                String("kci_pkg_upload: asked which files of '")
                + name
                + String("' a subdir holds from a listing that was not read: ")
                + self.detail
            )
        var want = ascii_lower(name)
        var out = List[String]()
        for i in range(len(self.files)):
            if conda_package_name_of_file(self.files[i]) == want:
                out.append(self.files[i].copy())
        return out^


def conda_package_name_of_file(file_name: String) -> String:
    """The package name of a conda file name `<name>-<version>-<build>.conda`
    (or `.tar.bz2`), lowercased; EMPTY when the file name has neither
    extension or is not three `-`-separated non-empty parts (a name may hold
    `-`, a version and a build may not, so it is split at the last two)."""
    var stem: String
    if file_name.endswith(String(".conda")):
        stem = String(file_name[byte = : file_name.byte_length() - 6])
    elif file_name.endswith(String(".tar.bz2")):
        stem = String(file_name[byte = : file_name.byte_length() - 8])
    else:
        return String("")
    var last = stem.rfind(String("-"))
    if last <= 0 or last == stem.byte_length() - 1:
        return String("")
    var mid = String(stem[byte=:last]).rfind(String("-"))
    if mid <= 0 or mid + 1 == last:
        return String("")
    return ascii_lower(String(stem[byte=:mid]))


def _names_unknown(got: GetResult, var detail: String) -> NameListing:
    return NameListing(READ_UNKNOWN, got.response.status, List[String](), List[String](), detail^)


def _insert_sorted_unique(mut names: List[String], var name: String):
    var at = len(names)
    for i in range(len(names)):
        if names[i] == name:
            return
        if name < names[i]:
            at = i
            break
    names.insert(at, name^)


def classify_repodata_names(
    got: GetResult, authorization: String
) -> NameListing:
    """Turn one repodata GET into the set of package names it lists (see the
    file header). Never raises: every fault is a kind."""
    if not got.ok:
        return NameListing(READ_UNKNOWN, 0, List[String](), List[String](), got.detail.copy())
    var status = got.response.status
    if status == 404:
        return NameListing(
            READ_ABSENT,
            status,
            List[String](),
            List[String](),
            String("the channel answered 404 for ") + got.host + got.path,
        )
    if status == 401 or status == 403:
        return NameListing(
            READ_AUTH_REFUSED,
            status,
            List[String](),
            List[String](),
            withhold_if_echoes(
                String("the channel answered ")
                + String(status)
                + String(": ")
                + excerpt_unless_echoes(got.response.body, authorization),
                authorization,
            ),
        )
    if status == 429:
        return NameListing(
            READ_RATE_LIMITED, status, List[String](), List[String](), String("the channel answered 429")
        )
    if status != 200:
        return _names_unknown(
            got,
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
            return _names_unknown(
                got,
                String("the repodata is not a JSON object: its names cannot")
                + String(" be read"),
            )
        var keys = List[String]()
        keys.append(String(TAR_BZ2_PACKAGES_KEY))
        keys.append(String(CONDA_PACKAGES_KEY))
        var read_one = False
        var names = List[String]()
        var files = List[String]()
        for k in range(len(keys)):
            if not doc.has(keys[k]):
                continue
            var listing = doc.get(keys[k])
            if not listing.is_object():
                return _names_unknown(
                    got,
                    String("the repodata's '")
                    + keys[k]
                    + String("' is not an object: its names cannot be read"),
                )
            read_one = True
            for i in range(listing.num_members()):
                var file_name = listing.key_at(i)
                if listing.value_kind(i) != JSON_OBJECT:
                    return _names_unknown(
                        got,
                        String("the repodata's entry for ")
                        + file_name
                        + String(" is not an object"),
                    )
                var name = conda_package_name_of_file(file_name)
                if name.byte_length() == 0:
                    return _names_unknown(
                        got,
                        String("the repodata lists '")
                        + file_name
                        + String("', which is not <name>-<version>-<build>")
                        + String(".conda or .tar.bz2: its names cannot be told"),
                    )
                _insert_sorted_unique(names, name^)
                _insert_sorted_unique(files, file_name.copy())
        if not read_one:
            return _names_unknown(
                got,
                String("the repodata has neither a 'packages' nor a")
                + String(" 'packages.conda' listing: its names cannot be read"),
            )
        return NameListing(READ_PRESENT, status, names^, files^, String(""))
    except e:
        return _names_unknown(
            got, String("the repodata could not be read: ") + String(e)
        )
