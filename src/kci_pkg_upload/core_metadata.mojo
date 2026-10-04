# =============================================================================
# src/kci_pkg_upload/core_metadata.mojo — a wheel's `METADATA`, read
#   the way `uv publish` reads it, and the legacy upload form built from it.
# =============================================================================
#
# ⭐ THE FORM IS `uv publish`'s FORM, FIELD FOR FIELD AND IN ITS ORDER. The
# legacy upload repeats the core metadata as form fields. Which fields, in what
# order, with what value transformations, is not something to invent: it is
# what `uv publish` sends, MEASURED by recording its request against a loopback
# server (`tests/fidelity/capture_uv_publish.py`) and pinned byte for byte by
# `tests/test_pkg_upload_uv_fidelity.mojo`. The order below is uv's:
#
#   :action, sha256_digest, blake2_256_digest, protocol_version,
#   metadata_version, name, version, filetype, pyversion,
#   author, author_email, description, description_content_type,
#   download_url, home_page, keywords, license, license_expression,
#   maintainer, maintainer_email, summary,
#   requires_python            (ALWAYS sent, EMPTY when absent — uv does, for
#                               a GitLab index that requires it),
#   classifiers, dynamic, license_file, obsoletes_dist, platform,
#   project_urls, provides_dist, provides_extra, import_names,
#   import_namespaces, requires_dist, requires_external
#
# ⭐ NO `md5_digest`. The index's documentation describes md5 as a digest the
# form may carry; the index actually compares it as HEX, contrary to that
# documentation. uv sends sha256 and BLAKE2b-256 and no md5, and so do we.
#
# MEASURED VALUE TRANSFORMATIONS (uv, against the loopback recorder):
#   * a header's value starts after the colon with leading spaces/tabs
#     stripped; TRAILING whitespace is kept;
#   * `Project-URL: Label ,  url` is re-rendered `Label, url` (split at the
#     first comma, both halves trimmed);
#   * `Keywords` is sent verbatim;
#   * the description is the BODY after the blank line, verbatim, when it is
#     not blank; otherwise the `Description` header;
#   * raw UTF-8 in a value is sent as the same UTF-8 bytes;
#   * header names match ASCII-case-insensitively; a single-valued field takes
#     its FIRST occurrence, a multi-valued one every occurrence in order.
#
# ⛔ REFUSED, NOT GUESSED (a local fault, naming the field):
#   * a FOLDED header (a continuation line starting with a space or a tab).
#     uv unfolds `first\n  second` to `first second`, but the edge cases —
#     whitespace before the fold, a blank continuation — were not measured, and
#     a guess that disagreed with uv would upload metadata the index renders
#     differently from what was reviewed. No producer here folds;
#   * an RFC 2047 encoded word (`=?charset?…?=`), which uv's header parser
#     decodes and this one would not;
#   * a missing `Metadata-Version`, `Name` or `Version`;
#   * a `Project-URL` with no comma;
#   * a METADATA whose Name/Version disagree with the file name's — a stamp
#     that rewrote one and not the other.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from .coordinate import normalize_distribution_name
from .transport import ascii_eq_ignore_case


struct FormField(Copyable, Movable, Deinitable):
    """One text field of the multipart upload form.

    Layout: two owned Strings. No pointer field."""

    var name: String
    var value: String

    def __init__(out self, var name: String, var value: String):
        self.name = name^
        self.value = value^


struct _Header(Copyable, Movable, Deinitable):
    var name: String
    var value: String

    def __init__(out self, var name: String, var value: String):
        self.name = name^
        self.value = value^


struct CoreMetadata(Movable, Deinitable):
    """A parsed `METADATA`: the headers in file order, and the body.

    Layout: owned lists / Strings. No pointer field."""

    var _headers: List[_Header]
    var body: String

    def __init__(out self, var headers: List[_Header], var body: String):
        self._headers = headers^
        self.body = body^

    def first(self, name: String) -> String:
        """The FIRST value of header `name`, or EMPTY when absent."""
        for i in range(len(self._headers)):
            if ascii_eq_ignore_case(self._headers[i].name, name):
                return self._headers[i].value.copy()
        return String("")

    def has(self, name: String) -> Bool:
        for i in range(len(self._headers)):
            if ascii_eq_ignore_case(self._headers[i].name, name):
                return True
        return False

    def all(self, name: String) -> List[String]:
        """Every value of header `name`, in file order."""
        var out = List[String]()
        for i in range(len(self._headers)):
            if ascii_eq_ignore_case(self._headers[i].name, name):
                out.append(self._headers[i].value.copy())
        return out^


def _strip_line_end(line: String) -> String:
    if line.endswith(String("\r")):
        return String(line[byte = : line.byte_length() - 1])
    return line.copy()


def _lstrip_blank(s: String) -> String:
    var b = s.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    return String(s[byte=i:])


def _strip_blank(s: String) -> String:
    var b = s.as_bytes()
    var i = 0
    var j = len(b)
    while i < j and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    while j > i and (b[j - 1] == UInt8(32) or b[j - 1] == UInt8(9)):
        j -= 1
    return String(s[byte=i:j])


def _is_blank(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c != UInt8(32) and c != UInt8(9) and c != UInt8(10) and c != UInt8(13):
            return False
    return True


def parse_core_metadata(text: String) raises -> CoreMetadata:
    """Parse a `METADATA` file (RFC 822-style headers, a blank line, a body).

    RAISES on the shapes the file header lists as refused."""
    var headers = List[_Header]()
    var pos = 0
    var n = text.byte_length()
    var body_start = n
    while pos < n:
        var nl = text.find(String("\n"), pos)
        var line_end = nl if nl >= 0 else n
        var line = _strip_line_end(String(text[byte=pos:line_end]))
        var next_pos = line_end + 1 if nl >= 0 else n
        if line.byte_length() == 0:
            body_start = next_pos
            break
        if line.startswith(String(" ")) or line.startswith(String("\t")):
            var prev = String("(none)")
            if len(headers) > 0:
                prev = headers[len(headers) - 1].name.copy()
            raise Error(
                String("METADATA: header '")
                + prev
                + String(
                    "' is FOLDED onto a continuation line. The upload form is"
                    " uv's form, and uv's unfolding of the edge cases was not"
                    " measured, so a folded header is refused rather than"
                    " guessed. Write the value on one line"
                )
            )
        var colon = line.find(String(":"))
        if colon <= 0:
            raise Error(
                String("METADATA: line '")
                + line
                + String("' is not a `Name: value` header")
            )
        var name = String(line[byte=:colon])
        var value = _lstrip_blank(String(line[byte = colon + 1 :]))
        if value.find(String("=?")) >= 0 and value.find(String("?=")) >= 0:
            raise Error(
                String("METADATA: header '")
                + name
                + String(
                    "' carries an RFC 2047 encoded word, which uv decodes and"
                    " this client would not; write the value as raw UTF-8"
                )
            )
        headers.append(_Header(name^, value^))
        pos = next_pos
    var body = String("")
    if body_start < n:
        body = String(text[byte=body_start:])
    var meta = CoreMetadata(headers^, body^)
    var required = List[String]()
    required.append(String("Metadata-Version"))
    required.append(String("Name"))
    required.append(String("Version"))
    for i in range(len(required)):
        if not meta.has(required[i]):
            raise Error(
                String("METADATA: the required header '")
                + required[i]
                + String("' is missing")
            )
    return meta^


def _project_url_rendered(raw: String) raises -> String:
    var comma = raw.find(String(","))
    if comma < 0:
        raise Error(
            String("METADATA: Project-URL '")
            + raw
            + String("' has no comma; the shape is `Label, url`")
        )
    return (
        _strip_blank(String(raw[byte=:comma]))
        + String(", ")
        + _strip_blank(String(raw[byte = comma + 1 :]))
    )


struct WheelName(Copyable, Movable, Deinitable):
    """The parts of a wheel file name the form needs (PEP 427):
    `{distribution}-{version}(-{build})?-{python}-{abi}-{platform}.whl`.

    Layout: owned Strings. No pointer field."""

    var distribution: String
    var version: String
    var python_tag: String

    def __init__(
        out self,
        var distribution: String,
        var version: String,
        var python_tag: String,
    ):
        self.distribution = distribution^
        self.version = version^
        self.python_tag = python_tag^


def parse_wheel_name(file_name: String) raises -> WheelName:
    """Split a wheel file name. RAISES unless it ends `.whl` and has 5 or 6
    dash-separated parts. `python_tag` is the python-tag component verbatim —
    for a compressed tag set (`py2.py3`) that IS uv's `pyversion` (the tags
    joined by `.`)."""
    if not file_name.endswith(String(".whl")):
        raise Error(
            String("kci_pkg_upload: '")
            + file_name
            + String(
                "' is not a wheel. The legacy upload arm serves python_wheel"
                " files only"
            )
        )
    var stem = String(file_name[byte = : file_name.byte_length() - 4])
    var parts = List[String]()
    var start = 0
    while True:
        var d = stem.find(String("-"), start)
        if d < 0:
            parts.append(String(stem[byte=start:]))
            break
        parts.append(String(stem[byte=start:d]))
        start = d + 1
    if len(parts) != 5 and len(parts) != 6:
        raise Error(
            String("kci_pkg_upload: wheel file name '")
            + file_name
            + String("' does not have 5 or 6 dash-separated parts (PEP 427)")
        )
    var n = len(parts)
    return WheelName(parts[0].copy(), parts[1].copy(), parts[n - 3].copy())


def legacy_upload_fields(
    meta: CoreMetadata,
    file_name: String,
    sha256_hex: String,
    blake2_256_hex: String,
) raises -> List[FormField]:
    """The text fields of the legacy upload form, in `uv publish`'s order
    (see the file header), for a wheel `file_name` whose digests are given.

    RAISES when METADATA's Name/Version disagree with the file name's."""
    var wheel = parse_wheel_name(file_name)
    var name = meta.first(String("Name"))
    var version = meta.first(String("Version"))
    if normalize_distribution_name(name) != normalize_distribution_name(wheel.distribution):
        raise Error(
            String("kci_pkg_upload: METADATA Name '")
            + name
            + String("' is not the distribution of file '")
            + file_name
            + String("'")
        )
    if version != wheel.version:
        raise Error(
            String("kci_pkg_upload: METADATA Version '")
            + version
            + String("' is not the version of file '")
            + file_name
            + String("' (a stamp that rewrote one and not the other)")
        )

    var out = List[FormField]()
    out.append(FormField(String(":action"), String("file_upload")))
    out.append(FormField(String("sha256_digest"), sha256_hex.copy()))
    out.append(FormField(String("blake2_256_digest"), blake2_256_hex.copy()))
    out.append(FormField(String("protocol_version"), String("1")))
    out.append(
        FormField(String("metadata_version"), meta.first(String("Metadata-Version")))
    )
    out.append(FormField(String("name"), name^))
    out.append(FormField(String("version"), version^))
    out.append(FormField(String("filetype"), String("bdist_wheel")))
    out.append(FormField(String("pyversion"), wheel.python_tag.copy()))

    # Single-valued, sent only when present — uv's `add_option` arm.
    _opt(out, meta, String("author"), String("Author"))
    _opt(out, meta, String("author_email"), String("Author-email"))
    if not _is_blank(meta.body):
        out.append(FormField(String("description"), meta.body.copy()))
    else:
        _opt(out, meta, String("description"), String("Description"))
    _opt(
        out,
        meta,
        String("description_content_type"),
        String("Description-Content-Type"),
    )
    _opt(out, meta, String("download_url"), String("Download-URL"))
    _opt(out, meta, String("home_page"), String("Home-page"))
    _opt(out, meta, String("keywords"), String("Keywords"))
    _opt(out, meta, String("license"), String("License"))
    _opt(out, meta, String("license_expression"), String("License-Expression"))
    _opt(out, meta, String("maintainer"), String("Maintainer"))
    _opt(out, meta, String("maintainer_email"), String("Maintainer-email"))
    _opt(out, meta, String("summary"), String("Summary"))

    # ALWAYS sent, EMPTY when absent (uv: a GitLab index requires it).
    out.append(
        FormField(String("requires_python"), meta.first(String("Requires-Python")))
    )

    # Multi-valued, every occurrence in order — uv's `add_vec` arm.
    _all(out, meta, String("classifiers"), String("Classifier"))
    _all(out, meta, String("dynamic"), String("Dynamic"))
    _all(out, meta, String("license_file"), String("License-File"))
    _all(out, meta, String("obsoletes_dist"), String("Obsoletes-Dist"))
    _all(out, meta, String("platform"), String("Platform"))
    var urls = meta.all(String("Project-URL"))
    for i in range(len(urls)):
        out.append(FormField(String("project_urls"), _project_url_rendered(urls[i])))
    _all(out, meta, String("provides_dist"), String("Provides-Dist"))
    _all(out, meta, String("provides_extra"), String("Provides-Extra"))
    _all(out, meta, String("import_names"), String("Import-Name"))
    _all(out, meta, String("import_namespaces"), String("Import-Namespace"))
    _all(out, meta, String("requires_dist"), String("Requires-Dist"))
    _all(out, meta, String("requires_external"), String("Requires-External"))
    return out^


def _opt(
    mut out: List[FormField], meta: CoreMetadata, field: String, header: String
):
    if meta.has(header):
        out.append(FormField(field.copy(), meta.first(header)))


def _all(
    mut out: List[FormField], meta: CoreMetadata, field: String, header: String
):
    var vals = meta.all(header)
    for i in range(len(vals)):
        out.append(FormField(field.copy(), vals[i].copy()))
