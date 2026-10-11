# =============================================================================
# kci_cloud/triggers.mojo: the rules of the TRIGGER primitives (schedule,
# event trigger).
# =============================================================================
#
# GRAPH findings, true on every cloud, that validate collects for a trigger
# (`trigger_findings`):
#   * a trigger reaches its target through the one edge of its own identity,
#     CALL on the target (grants.mojo), so it has no `uses` lines;
#   * a schedule's `cron` is written, in the form every built-in cloud reads
#     alike: five fields separated by single spaces (minute 0-59, hour 0-23,
#     day of the month 1-31, month 1-12, day of the week 0-6), each `*`, a
#     number or a range `a-b` (low to high), either with a step `/n` (n from
#     1), or a comma-separated list of those; no names, no shorthands
#     (`cron_problem`);
#   * a schedule's `timezone`, when written, has the shape of an IANA name:
#     at most 64 bytes of letters, digits, `/`, `_`, `+` and `-`, a letter
#     first, and no empty part between slashes (`timezone_problem`). Whether
#     the name is in the time zone database is the cloud's to answer;
#   * a schedule's `target` names a `container_job` or a `service` of the
#     list (the resource itself, no output, not the schedule);
#   * an event trigger's `source` names a `bucket` of the list, its `event`
#     is one this kci knows (OBJECT_CREATED, OBJECT_DELETED), and its `target`
#     names a `service` of the list; two event triggers never deliver the
#     same event of the same source to the same target (each event would be
#     delivered twice).
#
# The schedule's versioned default (an unwritten `timezone` is UTC) and the
# FIRINGS kci hands every cloud adapter are firing.mojo's.
# =============================================================================

from kci_resource_proto.refs import Ref
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import FIELD_BUCKET, FIELD_CONTAINER_JOB, FIELD_EVENT_TRIGGER, FIELD_SCHEDULE, FIELD_SERVICE
from kci_cloud.feed import field_of_id
from kci_cloud.messaging import check_typed_ref


comptime TIMEZONE_MAX_BYTES: Int = 64
comptime CRON_FIELDS: Int = 5
comptime EVENT_OBJECT_CREATED: Int = 1
"""`kci.resource.v1.OBJECT_CREATED`."""
comptime EVENT_OBJECT_DELETED: Int = 2
"""`kci.resource.v1.OBJECT_DELETED`."""


def cron_fields(cron: String) -> List[String]:
    """`cron` split at single spaces (an empty entry where two meet)."""
    var out = List[String]()
    for part in cron.split(" "):
        out.append(String(part))
    return out^


def _number(text: String, lo: Int, hi: Int) -> Int:
    """`text` as a number from `lo` to `hi`, or -1: one or two digits."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 2:
        return -1
    var v = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < ord("0") or c > ord("9"):
            return -1
        v = v * 10 + (c - ord("0"))
    if v < lo or v > hi:
        return -1
    return v


def _item_problem(item: String, lo: Int, hi: Int) -> String:
    """Why one list item of a cron field is not `*`, `n` or `a-b`, with an
    optional `/step` after `*` or a range; empty when it is."""
    var base = item.copy()
    var slash = item.find("/")
    if slash >= 0:
        base = String(item[byte=0:slash])
        var step = String(item[byte = slash + 1 : item.byte_length()])
        if _number(step, 1, hi) < 0:
            return String("step \"") + step + String("\" is not a number from 1 to ") + String(hi)
        if base != "*" and base.find("-") < 0:
            return String("a step follows `*` or a range, not \"") + base + String("\"")
    if base == "*":
        return String("")
    var dash = base.find("-")
    if dash < 0:
        if _number(base, lo, hi) < 0:
            return String("\"") + base + String("\" is not a number from ") + String(lo) + String(" to ") + String(hi)
        return String("")
    var a = _number(String(base[byte=0:dash]), lo, hi)
    var b = _number(String(base[byte = dash + 1 : base.byte_length()]), lo, hi)
    if a < 0 or b < 0:
        return String("range \"") + base + String("\" is not two numbers from ") + String(lo) + String(" to ") + String(hi)
    if a > b:
        return String("range \"") + base + String("\" runs high to low")
    return String("")


def cron_problem(cron: String) -> String:
    """Why `cron` is not of the form the file header gives, or empty if it
    is."""
    if cron.byte_length() == 0:
        return String("no cron: write five fields, minute hour day-of-month month day-of-week")
    var names: List[String] = ["minute", "hour", "day of the month", "month", "day of the week"]
    var lows: List[Int] = [0, 0, 1, 1, 0]
    var highs: List[Int] = [59, 23, 31, 12, 6]
    var fields = cron_fields(cron)
    for k in range(len(fields)):
        if fields[k].byte_length() == 0:
            return String("a cron's fields are separated by single spaces; \"") + cron + String("\" has an empty one")
    if len(fields) != CRON_FIELDS:
        return (
            String("a cron is five fields separated by single spaces (minute hour day-of-month month")
            + String(" day-of-week); \"") + cron + String("\" has ") + String(len(fields))
        )
    for k in range(CRON_FIELDS):
        for item in fields[k].split(","):
            var why = _item_problem(String(item), lows[k], highs[k])
            if why.byte_length() > 0:
                return String("the ") + names[k] + String(" field \"") + fields[k] + String("\": ") + why
    return String("")


def timezone_problem(tz: String) -> String:
    """Why `tz` is not empty or of an IANA name's shape (file header), or
    empty if it is."""
    var b = tz.as_bytes()
    var n = len(b)
    if n == 0:
        return String("")
    if n > TIMEZONE_MAX_BYTES:
        return String("a time zone name is at most ") + String(TIMEZONE_MAX_BYTES) + String(" bytes")
    var first = Int(b[0])
    if not ((first >= ord("A") and first <= ord("Z")) or (first >= ord("a") and first <= ord("z"))):
        return String("a time zone name (\"Europe/Paris\") starts with a letter")
    for i in range(n):
        var c = Int(b[i])
        var letter = (c >= ord("A") and c <= ord("Z")) or (c >= ord("a") and c <= ord("z"))
        var digit = c >= ord("0") and c <= ord("9")
        if not letter and not digit and c != ord("/") and c != ord("_") and c != ord("+") and c != ord("-"):
            return String("a time zone name is letters, digits, '/', '_', '+' and '-' only")
        if c == ord("/") and (i == n - 1 or Int(b[i + 1]) == ord("/")):
            return String("a time zone name has no empty part between slashes")
    return String("")


def _check_schedule_target(resources: List[Resource], id: String, t: Ref, mut out: List[Finding]):
    """A schedule's target: a container job or a service of the list, the
    resource itself, not the schedule."""
    var path = String("schedule.target")
    var what = String("a container_job or a service")
    if t._oneof0_case != 0:
        out.append(Finding(FINDING_GRAPH, id, path, String("names ") + what + String(", not one of its outputs")))
        return
    if t.resource == id:
        out.append(Finding(FINDING_GRAPH, id, path, String("refers to its own resource")))
        return
    var found = False
    for i in range(len(resources)):
        if resources[i].id == t.resource:
            found = True
            break
    if not found:
        out.append(Finding(FINDING_GRAPH, id, path, String("ref to missing resource \"") + t.resource + String("\"")))
        return
    var f = field_of_id(resources, t.resource)
    if f != FIELD_CONTAINER_JOB and f != FIELD_SERVICE:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                path,
                String("must name ") + what + String("; \"") + t.resource + String("\" is neither"),
            )
        )


def _schedule_findings(resources: List[Resource], r: Resource, mut out: List[Finding]):
    ref s = r.schedule.value()
    var why = cron_problem(s.cron)
    if why.byte_length() > 0:
        out.append(Finding(FINDING_GRAPH, r.id, String("schedule.cron"), why))
    var tz = timezone_problem(s.timezone)
    if tz.byte_length() > 0:
        out.append(Finding(FINDING_GRAPH, r.id, String("schedule.timezone"), tz))
    if not s.target:
        out.append(Finding(FINDING_GRAPH, r.id, String("schedule.target"), String("no target")))
    else:
        _check_schedule_target(resources, r.id, s.target.value(), out)


def _event_key(r: Resource) -> String:
    """(source, event, target) of event trigger `r`, or empty while one of
    them is missing or names an output (each a finding of its own)."""
    ref e = r.event_trigger.value()
    if not e.source or not e.target or e.event.value == 0:
        return String("")
    if e.source.value()._oneof0_case != 0 or e.target.value()._oneof0_case != 0:
        return String("")
    return (
        e.source.value().resource + String("|") + String(Int(e.event.value)) + String("|")
        + e.target.value().resource
    )


def _event_trigger_findings(resources: List[Resource], r: Resource, mut out: List[Finding]):
    ref e = r.event_trigger.value()
    if not e.source:
        out.append(Finding(FINDING_GRAPH, r.id, String("event_trigger.source"), String("no source")))
    else:
        check_typed_ref(
            resources, r.id, String("event_trigger.source"), e.source.value(), FIELD_BUCKET, String("bucket"), out
        )
    var ev = Int(e.event.value)
    if ev == 0:
        out.append(Finding(FINDING_GRAPH, r.id, String("event_trigger.event"), String("no event")))
    elif ev != EVENT_OBJECT_CREATED and ev != EVENT_OBJECT_DELETED:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("event_trigger.event"),
                String("event ") + String(ev) + String(" is not one this kci knows (OBJECT_CREATED, OBJECT_DELETED)"),
            )
        )
    if not e.target:
        out.append(Finding(FINDING_GRAPH, r.id, String("event_trigger.target"), String("no target")))
    else:
        check_typed_ref(
            resources, r.id, String("event_trigger.target"), e.target.value(), FIELD_SERVICE, String("service"), out
        )
    var key = _event_key(r)
    if key.byte_length() == 0:
        return
    for i in range(len(resources)):
        ref o = resources[i]
        if o.id == r.id:
            break
        if not o.event_trigger or _event_key(o) != key:
            continue
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("event_trigger"),
                String("event trigger \"")
                + o.id
                + String("\" already delivers ")
                + e.event.json_name()
                + String(" of \"")
                + e.source.value().resource
                + String("\" to \"")
                + e.target.value().resource
                + String("\"; a second would deliver every event twice"),
            )
        )
        return


def trigger_findings(resources: List[Resource], field: Int, r: Resource) -> List[Finding]:
    """Every graph finding of the trigger `r` (body field `field`)."""
    var out = List[Finding]()
    if len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("uses"),
                String(
                    "a trigger reaches its target through its own identity's one edge (CALL on the"
                    " target), so it has no uses lines"
                ),
            )
        )
    if field == FIELD_SCHEDULE:
        _schedule_findings(resources, r, out)
    elif field == FIELD_EVENT_TRIGGER:
        _event_trigger_findings(resources, r, out)
    return out^
