"""GitHub check-run request bodies, in the order they are sent.

GitHub takes at most 50 annotations per request, so a run is one POST
(`/repos/{owner}/{repo}/check-runs`) and then PATCHes (`.../check-runs/{id}`):

- body 0 (`000.json`): `{name, head_sha, status: "in_progress", output:
  {title, summary, annotations: [the first <= 50]}}`;
- bodies 1.. (`001.json`, ...): `{output: {title, summary, annotations:
  [the next <= 50]}}`, the last one also `status: "completed"` and the
  `conclusion`.

There is always at least one PATCH, so the sender's loop is the same for
any number of annotations: 0 to 100 annotations make two bodies, 120 make
three, 1000 (the default `--max-annotations`) make 20. Every body repeats the title (cut to 255 bytes) and the summary
(given already within GitHub's 65535; see summary.mojo).
"""

from covcheck.annotate import Annotation, write_annotation
from covcheck.jsonw import JsonOut
from covcheck.text import truncate_utf8

comptime BATCH: Int = 50
comptime MAX_TITLE: Int = 255


def valid_sha(s: String) -> Bool:
    """40 lowercase hex digits (a full git commit id)."""
    if s.byte_length() != 40:
        return False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True


def _output(mut j: JsonOut, title: String, summary: String, anns: List[Annotation], start: Int, end: Int):
    j.key(String("output"))
    j.begin_object()
    j.field_str(String("title"), truncate_utf8(title, MAX_TITLE))
    j.field_str(String("summary"), summary)
    j.key(String("annotations"))
    j.begin_array()
    for i in range(start, end):
        j.item()
        write_annotation(j, anns[i])
    j.end_array()
    j.end_object()


def checkrun_bodies(
    name: String,
    head_sha: String,
    title: String,
    summary: String,
    conclusion: String,
    anns: List[Annotation],
) -> List[String]:
    """The request bodies, in send order (see the module header)."""
    var out = List[String]()
    var n = len(anns)
    var first_end = min(n, BATCH)
    var j = JsonOut()
    j.begin_object()
    j.field_str(String("name"), name)
    j.field_str(String("head_sha"), head_sha)
    j.field_str(String("status"), String("in_progress"))
    _output(j, title, summary, anns, 0, first_end)
    j.end_object()
    out.append(j.text() + String("\n"))
    var at = first_end
    while True:
        var end = min(n, at + BATCH)
        var last = end >= n
        var p = JsonOut()
        p.begin_object()
        if last:
            p.field_str(String("status"), String("completed"))
            p.field_str(String("conclusion"), conclusion)
        _output(p, title, summary, anns, at, end)
        p.end_object()
        out.append(p.text() + String("\n"))
        at = end
        if last:
            break
    return out^


def body_name(i: Int) -> String:
    """`000.json`, `001.json`, ...: sorted order is send order."""
    var s = String(i)
    while s.byte_length() < 3:
        s = String("0") + s
    return s + String(".json")
