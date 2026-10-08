# =============================================================================
# test_cloud_trigger_rules.mojo
# =============================================================================
#
# The trigger rules (triggers.mojo), the firings (firing.mojo) and a
# trigger's identity and edge (grants.mojo), through `graph_findings`, the
# cloud-independent half of validate. No cloud is needed: the fakes in
# kci_cloud_fake run these graphs on every shape.
#
# 1. EVERY TRIGGER REFUSAL, IN ONE PASS, each pinned by resource, field path
#    and reason: a cron that is empty, of four fields, with a double space,
#    a shorthand (`@daily`), a minute of 60, an hour of 24, a day of the
#    month of 0, a month of 13, a day of the week of 7, a name (`MON`), a
#    step of 0, a step after a single number, a range that runs high to
#    low, a range that is not numbers; a time zone that starts with a digit,
#    has an empty part between slashes, ends with a slash, holds a space, or
#    is 65 bytes; a schedule with no target, a missing target, a bucket as
#    target, an output as target, itself as target; `uses` and retention on
#    a schedule and on an event trigger; an event trigger with no source, a
#    service as source, an output as source, no event, an event this kci
#    does not know (3), no target, a container job as target, and a second
#    trigger of one (source, event, target); a grant whose principal is a
#    schedule, and CALL asked of a schedule. Nothing else is reported.
# 2. A GOOD TRIGGER GRAPH IS CLEAN: the cron bounds themselves (0 0 1 1 0,
#    59 23 31 12 6), steps on `*` and on a range, lists, a range; the time
#    zones UTC, a three-part name, `Etc/GMT+5` and none; a schedule on a job
#    and one on a service; event triggers for both events.
# 3. A TRIGGER'S IDENTITY AND EDGE: its identity owner is itself; its one
#    edge is the implicit CALL on its target, at the role `u-<h>` of (its
#    id, the target), and `edges_for` gives it the target's type; it holds
#    no workload identity, so no cell LOGS edge; `edges_of` refuses a
#    trigger with `uses` lines or with no target.
# 4. FIRINGS: `firings_of` lists every schedule whose target is a container
#    job or a service, in order, with the time zone written out (UTC when
#    unwritten), and skips one whose target is a bucket or missing;
#    `firings_into` and `firing_of` select; `schedule_timezone`.
# 5. THE CATALOG ROWS: `schedule` (22) and `event_trigger` (31) are
#    PORTABLE, expose nothing, accept no verb, take no retention, land on
#    `schedule` and `trigger`, and are the eleventh and twentieth arms.
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json, decode_proto
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    FIELD_CONTAINER_JOB,
    FIELD_EVENT_TRIGGER,
    FIELD_SCHEDULE,
    FIELD_SERVICE,
    PORTABLE,
    TIMEZONE_DEFAULT,
    Catalog,
    Finding,
    body_arms,
    cron_problem,
    edges_for,
    edges_of,
    firing_of,
    firings_into,
    firings_of,
    graph_findings,
    holds_own_identity,
    identity_owner,
    schedule_timezone,
    timezone_problem,
    uses_role,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(findings: List[Finding]) -> List[String]:
    var out = List[String]()
    for i in range(len(findings)):
        out.append(findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason)
    return out^


def _expect(lines: List[String], prefix: String, reason: String) raises:
    """Exactly one finding starts with `prefix` (`id|path|`) and holds
    `reason`."""
    var n = 0
    var all = String("")
    for i in range(len(lines)):
        all += lines[i] + String("\n")
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + all)


comptime IMG = '"image":{"digest":"sha256:0011"}'


def _base() -> String:
    """What the triggers name: a job, a service, a bucket."""
    return (
        String('{"id":"job","containerJob":{') + String(IMG) + String("}},")
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{}}},')
        + String('{"id":"media","bucket":{}},')
    )


def _sched(id: String, cron: String, tz: String = String(""), target: String = String('{"resource":"job"}')) -> String:
    var t = String(',"timezone":"') + tz + String('"') if tz.byte_length() > 0 else String("")
    return String('{"id":"') + id + String('","schedule":{"cron":"') + cron + String('"') + t + String(',"target":') + target + String("}},")


def _bytes(n: Int) -> String:
    """A time zone name `n` bytes long: `A` then lowercase letters."""
    var s = String("A")
    for _ in range(n - 1):
        s += String("b")
    return s^


def _event_3() raises -> Resource:
    """`{id: "e-unknown", event_trigger {source media, event 3, target api}}`,
    written as bytes: the event is a number no name has taken."""
    var b = List[UInt8]()
    b.append(0x0A)  # 1: id
    b.append(9)
    for c in String("e-unknown").as_bytes():
        b.append(c)
    var body = List[UInt8]()
    body.append(0x0A)  # 1: source, Ref { 1: "media" }
    body.append(7)
    body.append(0x0A)
    body.append(5)
    for c in String("media").as_bytes():
        body.append(c)
    body.append(0x10)  # 2: event
    body.append(3)
    body.append(0x1A)  # 3: target, Ref { 1: "api" }
    body.append(5)
    body.append(0x0A)
    body.append(3)
    for c in String("api").as_bytes():
        body.append(c)
    b.append(0xFA)  # 31: event_trigger
    b.append(0x01)
    b.append(UInt8(len(body)))
    b.extend(body^)
    return decode_proto[Resource](b^)


# ---- 1. every refusal, in one pass ------------------------------------------------


def test_every_trigger_refusal_in_one_pass() raises:
    """Catches: any one rule dropped (its line is missing), a bound off by one
    (60, 24, 0, 13, 7 accepted), a rule that fires on the wrong resource or
    path, and a rule that fires on a good resource (the total)."""
    var g = _list(
        String('{"resource":[') + _base()
        + _sched(String("c-empty"), String(""))
        + _sched(String("c-four"), String("0 3 * *"))
        + _sched(String("c-double"), String("0  3 * * *"))
        + _sched(String("c-macro"), String("@daily"))
        + _sched(String("c-minute"), String("60 3 * * *"))
        + _sched(String("c-hour"), String("0 24 * * *"))
        + _sched(String("c-dom"), String("0 3 0 * *"))
        + _sched(String("c-month"), String("0 3 * 13 *"))
        + _sched(String("c-dow"), String("0 3 * * 7"))
        + _sched(String("c-name"), String("0 3 * * MON"))
        + _sched(String("c-step0"), String("*/0 * * * *"))
        + _sched(String("c-stepn"), String("5/10 * * * *"))
        + _sched(String("c-desc"), String("0 5-1 * * *"))
        + _sched(String("c-range"), String("0 a-b * * *"))
        + _sched(String("z-digit"), String("0 3 * * *"), String("1Europe"))
        + _sched(String("z-empty"), String("0 3 * * *"), String("Europe//Paris"))
        + _sched(String("z-end"), String("0 3 * * *"), String("Europe/"))
        + _sched(String("z-space"), String("0 3 * * *"), String("Europe Paris"))
        + _sched(String("z-long"), String("0 3 * * *"), _bytes(65))
        + String('{"id":"t-none","schedule":{"cron":"0 3 * * *"}},')
        + _sched(String("t-gone"), String("0 3 * * *"), target=String('{"resource":"nope"}'))
        + _sched(String("t-bucket"), String("0 3 * * *"), target=String('{"resource":"media"}'))
        + _sched(String("t-out"), String("0 3 * * *"), target=String('{"resource":"api","standard":"URL"}'))
        + _sched(String("t-self"), String("0 3 * * *"), target=String('{"resource":"t-self"}'))
        + String('{"id":"s-uses","retention":"KEEP","schedule":{"cron":"0 3 * * *","target":{"resource":"job"}},')
        + String('"uses":[{"target":{"resource":"media"},"access":"READ"}]},')
        + String('{"id":"e-no-src","eventTrigger":{"event":"OBJECT_CREATED","target":{"resource":"api"}}},')
        + String('{"id":"e-src-svc","eventTrigger":{"source":{"resource":"api"},"event":"OBJECT_CREATED",')
        + String('"target":{"resource":"api"}}},')
        + String('{"id":"e-src-out","eventTrigger":{"source":{"resource":"media","standard":"NAME"},')
        + String('"event":"OBJECT_CREATED","target":{"resource":"api"}}},')
        + String('{"id":"e-no-event","eventTrigger":{"source":{"resource":"media"},"target":{"resource":"api"}}},')
        + String('{"id":"e-no-tgt","eventTrigger":{"source":{"resource":"media"},"event":"OBJECT_DELETED"}},')
        + String('{"id":"e-tgt-job","eventTrigger":{"source":{"resource":"media"},"event":"OBJECT_DELETED",')
        + String('"target":{"resource":"job"}}},')
        + String('{"id":"e-first","eventTrigger":{"source":{"resource":"media"},"event":"OBJECT_CREATED",')
        + String('"target":{"resource":"api"}}},')
        + String('{"id":"e-again","retention":"DELETE","eventTrigger":{"source":{"resource":"media"},')
        + String('"event":"OBJECT_CREATED","target":{"resource":"api"}},')
        + String('"uses":[{"target":{"resource":"media"},"access":"READ"}]},')
        + String('{"id":"g-from-sched","grant":{"principal":{"resource":"c-four"},"target":{"resource":"api"},')
        + String('"access":"CALL"}},')
        + String('{"id":"caller","serviceAccount":{},"uses":[{"target":{"resource":"c-four"},"access":"CALL"}]}')
        + String("]}")
    )
    g.append(_event_3())
    var l = _lines(graph_findings(Catalog.v1(), g))
    _expect(l, "c-empty|schedule.cron|", "no cron: write five fields")
    _expect(l, "c-four|schedule.cron|", '"0 3 * *" has 4')
    _expect(l, "c-double|schedule.cron|", "has an empty one")
    _expect(l, "c-macro|schedule.cron|", '"@daily" has 1')
    _expect(l, "c-minute|schedule.cron|", 'the minute field "60": "60" is not a number from 0 to 59')
    _expect(l, "c-hour|schedule.cron|", 'the hour field "24": "24" is not a number from 0 to 23')
    _expect(l, "c-dom|schedule.cron|", 'the day of the month field "0": "0" is not a number from 1 to 31')
    _expect(l, "c-month|schedule.cron|", 'the month field "13": "13" is not a number from 1 to 12')
    _expect(l, "c-dow|schedule.cron|", 'the day of the week field "7": "7" is not a number from 0 to 6')
    _expect(l, "c-name|schedule.cron|", '"MON" is not a number from 0 to 6')
    _expect(l, "c-step0|schedule.cron|", 'step "0" is not a number from 1 to 59')
    _expect(l, "c-stepn|schedule.cron|", 'a step follows `*` or a range, not "5"')
    _expect(l, "c-desc|schedule.cron|", 'range "5-1" runs high to low')
    _expect(l, "c-range|schedule.cron|", 'range "a-b" is not two numbers from 0 to 23')
    _expect(l, "z-digit|schedule.timezone|", "starts with a letter")
    _expect(l, "z-empty|schedule.timezone|", "no empty part between slashes")
    _expect(l, "z-end|schedule.timezone|", "no empty part between slashes")
    _expect(l, "z-space|schedule.timezone|", "letters, digits, '/', '_', '+' and '-' only")
    _expect(l, "z-long|schedule.timezone|", "at most 64 bytes")
    _expect(l, "t-none|schedule.target|", "no target")
    _expect(l, "t-gone|schedule.target|", 'ref to missing resource "nope"')
    _expect(l, "t-bucket|schedule.target|", 'must name a container_job or a service; "media" is neither')
    _expect(l, "t-out|schedule.target|", "names a container_job or a service, not one of its outputs")
    _expect(l, "t-self|schedule.target|", "refers to its own resource")
    var no_uses = String("a trigger reaches its target through its own identity's one edge")
    _expect(l, "s-uses|uses|", no_uses)
    _expect(l, "s-uses|retention|", "a schedule takes no retention")
    _expect(l, "e-again|uses|", no_uses)
    _expect(l, "e-again|retention|", "event_trigger takes no retention")
    _expect(l, "e-no-src|event_trigger.source|", "no source")
    _expect(l, "e-src-svc|event_trigger.source|", 'must name a bucket; "api" is not one')
    _expect(l, "e-src-out|event_trigger.source|", "names a bucket, not one of its outputs")
    _expect(l, "e-no-event|event_trigger.event|", "no event")
    _expect(l, "e-unknown|event_trigger.event|", "event 3 is not one this kci knows (OBJECT_CREATED, OBJECT_DELETED)")
    _expect(l, "e-no-tgt|event_trigger.target|", "no target")
    _expect(l, "e-tgt-job|event_trigger.target|", 'must name a service; "job" is not one')
    _expect(
        l,
        "e-again|event_trigger|",
        'event trigger "e-first" already delivers OBJECT_CREATED of "media" to "api"; a second would deliver',
    )
    _expect(l, "g-from-sched|grant.principal|", 'the principal must be a service_account')
    _expect(l, "caller|uses[0]|", 'schedule "c-four" does not accept access CALL')
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 38, String("nothing else is reported:\n") + all)
    print("  test_every_trigger_refusal_in_one_pass: PASS")


# ---- 2. a good trigger graph is clean ------------------------------------------------


def test_a_good_trigger_graph_is_clean() raises:
    """Catches: a bound refused (0 0 1 1 0, 59 23 31 12 6), a step, a list or
    a range refused, a real time zone name refused (three parts, `+`, `_`),
    no time zone refused, a schedule on a service refused, and an event
    trigger per event refused."""
    var g = _list(
        String('{"resource":[') + _base()
        + _sched(String("lows"), String("0 0 1 1 0"))
        + _sched(String("highs"), String("59 23 31 12 6"), String("UTC"))
        + _sched(String("steps"), String("*/5 0-6/2 1,15 * 1-5"), String("America/Argentina/Buenos_Aires"))
        + _sched(String("lists"), String("0,30 * * 1-12 *"), String("Etc/GMT+5"), String('{"resource":"api"}'))
        + String('{"id":"on-new","eventTrigger":{"source":{"resource":"media"},"event":"OBJECT_CREATED",')
        + String('"target":{"resource":"api"}}},')
        + String('{"id":"on-gone","eventTrigger":{"source":{"resource":"media"},"event":"OBJECT_DELETED",')
        + String('"target":{"resource":"api"}}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 0, String("a good trigger graph is clean:\n") + all)
    assert_equal(cron_problem(String("0 3 * * *")), "")
    assert_equal(timezone_problem(String("")), "", "no time zone is UTC")
    print("  test_a_good_trigger_graph_is_clean: PASS")


# ---- 3. a trigger's identity and edge ------------------------------------------------


def test_a_triggers_identity_and_edge() raises:
    """Catches: a trigger with no identity of its own (its CALL would hang off
    nothing), its edge at a role kci did not derive from (id, target), a
    verb other than CALL, the edge not marked implicit, the target's type
    not resolved, a cell LOGS edge given to a trigger, and `uses` lines or
    a missing target accepted by `edges_of`."""
    var l = _list(
        String('{"resource":[') + _base()
        + _sched(String("nightly"), String("0 3 * * *"))
        + String('{"id":"on-new","eventTrigger":{"source":{"resource":"media"},"event":"OBJECT_CREATED",')
        + String('"target":{"resource":"api"}}}')
        + String("]}")
    )
    var ids = [String("nightly"), String("on-new")]
    var targets = [String("job"), String("api")]
    var fields = [FIELD_CONTAINER_JOB, FIELD_SERVICE]
    for i in range(2):
        ref r = l[3 + i]
        assert_equal(identity_owner(r), ids[i], ids[i] + " is its own identity owner")
        assert_false(holds_own_identity(r), ids[i] + " holds no workload identity")
        var e = edges_for(l, r)
        assert_equal(len(e), 1, ids[i] + ": one edge, no cell LOGS")
        assert_equal(e[0].role, uses_role(ids[i], targets[i]))
        assert_equal(e[0].principal, ids[i])
        assert_equal(e[0].target, targets[i])
        assert_equal(e[0].access, "CALL")
        assert_true(e[0].implicit, "the edge is implicit")
        assert_false(e[0].on_cell())
        assert_equal(e[0].target_field, fields[i], "edges_for resolves the target's type")
    var bad = _list(
        String('{"resource":[{"id":"s","schedule":{"cron":"0 3 * * *","target":{"resource":"j"}},')
        + String('"uses":[{"target":{"resource":"j"},"access":"CALL"}]},')
        + String('{"id":"t","eventTrigger":{"source":{"resource":"b"},"event":"OBJECT_CREATED"}}]}')
    )
    for i in range(2):
        var raised = False
        try:
            _ = edges_of(bad[i])
        except:
            raised = True
        assert_true(raised, bad[i].id + String(": edges_of refuses it"))
    print("  test_a_triggers_identity_and_edge: PASS")


# ---- 4. firings ---------------------------------------------------------------------


def test_firings() raises:
    """Catches: a schedule on a job or a service missing from the firings, a
    schedule on a bucket or on nothing listed, the list out of order, the
    time zone not written out (UTC), and the selectors returning another
    schedule's firing."""
    var l = _list(
        String('{"resource":[') + _base()
        + _sched(String("a"), String("0 3 * * *"), String("Europe/Paris"))
        + _sched(String("b"), String("*/5 * * * *"), target=String('{"resource":"media"}'))
        + _sched(String("c"), String("0 4 * * *"), target=String('{"resource":"api"}'))
        + _sched(String("d"), String("0 5 * * *"), target=String('{"resource":"nope"}'))
        + _sched(String("e"), String("0 6 * * *"))
        + String('{"id":"last","bucket":{}}]}')
    )
    var f = firings_of(l)
    var text = String("")
    for i in range(len(f)):
        text += f[i].schedule + String(">") + f[i].target + String(":") + String(f[i].target_field)
        text += String("@") + f[i].cron + String("@") + f[i].timezone + String(";")
    assert_equal(
        text,
        String("a>job:11@0 3 * * *@Europe/Paris;c>api:10@0 4 * * *@UTC;e>job:11@0 6 * * *@UTC;"),
    )
    var into = firings_into(f, String("job"))
    assert_equal(len(into), 2)
    assert_equal(into[0].schedule, "a")
    assert_equal(into[1].schedule, "e")
    assert_equal(len(firings_into(f, String("media"))), 0)
    assert_equal(firing_of(f, String("c")).value().target, "api")
    assert_false(Bool(firing_of(f, String("b"))), "a schedule on a bucket has no firing")
    assert_equal(schedule_timezone(l[3]), "Europe/Paris")
    assert_equal(schedule_timezone(l[5]), String(TIMEZONE_DEFAULT))
    assert_equal(String(TIMEZONE_DEFAULT), "UTC")
    print("  test_firings: PASS")


# ---- 5. the catalog rows ---------------------------------------------------------------


def test_the_trigger_rows() raises:
    """Catches: a row at another field or arm position (a decoded schedule
    would map to another type), a portability other than PORTABLE, an
    output or a verb a trigger would offer (nothing is granted on one),
    retention on a trigger, and a primary role other than `schedule` and
    `trigger`."""
    assert_equal(FIELD_SCHEDULE, 22)
    assert_equal(FIELD_EVENT_TRIGGER, 31)
    var c = Catalog.v1()
    var arms = body_arms()
    var fields = [FIELD_SCHEDULE, FIELD_EVENT_TRIGGER]
    var names = ["schedule", "event_trigger"]
    var roles = ["schedule", "trigger"]
    var positions = [10, 19]
    for i in range(2):
        ref t = c.types[c.index_of(fields[i])]
        assert_equal(t.name, String(names[i]))
        assert_equal(t.portability, PORTABLE)
        assert_equal(len(t.exposes), 0, String(names[i]) + " exposes nothing")
        assert_equal(len(t.accepts), 0, String(names[i]) + " accepts no verb")
        assert_false(t.takes_retention(), String(names[i]) + " is deleted with its resource")
        assert_equal(t.primary_role, String(roles[i]))
        assert_equal(arms[positions[i]].field, fields[i], String(names[i]) + " by declaration order")
        assert_equal(arms[positions[i]].name, String(names[i]))
    print("  test_the_trigger_rows: PASS")


def main() raises:
    print("test_cloud_trigger_rules")
    test_every_trigger_refusal_in_one_pass()
    test_a_good_trigger_graph_is_clean()
    test_a_triggers_identity_and_edge()
    test_firings()
    test_the_trigger_rows()
    print("ALL kci_cloud TRIGGER RULE TESTS PASSED")
