# =============================================================================
# kci_cloud/shape/triggers.mojo: how the shared shapes lower and limit the
# TRIGGERS (schedule, event trigger).
# =============================================================================
#
# A trigger lowers to its identity (clouds.mojo: `<id>/identity`, the
# private identity the cloud's scheduling or eventing service uses), its one
# object below (`lower_trigger`), and its one edge, CALL on its target
# (clouds.mojo, by the shape's grant row for the target's type):
#   schedule       `<id>/schedule` with `cron`, `timezone` (UTC written out
#                  when unwritten) and `target`; it depends on its identity,
#                  on its target (by resource id: kci resolves the target's
#                  primary node) and on its CALL edge, so the permission
#                  exists before the first run.
#   event trigger  `<id>/trigger` with `source`, `event` and `target`; it
#                  depends on its identity, its source, its target and its
#                  CALL edge.
# FOLDED (`schedule_folds`, a shape's data: azure, onprem): a schedule whose
# target is a container job is a setting of the job's own object. Its
# identity, its edge and its `schedule` node are lowered TURNED OFF (the
# closed world removes them if they exist), and the job's run node carries
# `schedule` (the schedule's id), `cron` and `timezone` from kci's firing
# (`folded_fields`, called by workloads.mojo). A schedule that calls a
# service never folds.
#
# THE LIMITS (`trigger_limits`), from the shape's data, never its name:
#   * a cron that names both a day of the month and a day of the week on a
#     shape whose `schedule_day_limit` says why it cannot (aws);
#   * on a folding shape, a second schedule of one container job (the job
#     holds one), and a time zone other than UTC on a shape whose
#     `schedule_utc_limit` says why a folded schedule is read in UTC
#     (azure);
#   * a schedule that calls a service on a shape whose `schedule_call_limit`
#     says why it cannot (onprem, until Q28 is answered).
# ⚠ They are the FAKE clouds' own, chosen to be exercisable; they cite this
# package, not any real cloud.
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud.adapter import (
    FINDING_LIMIT,
    Finding,
    LoweredNode,
    Setting,
)
from kci_cloud.catalog import (
    FIELD_CONTAINER_JOB,
    FIELD_EVENT_TRIGGER,
    FIELD_SCHEDULE,
    FIELD_SERVICE,
    body_field,
    body_is,
)
from kci_cloud.firing import (
    Firing,
    TIMEZONE_DEFAULT,
    firing_of,
    firings_into,
    schedule_timezone,
)
from kci_cloud.grants import GrantEdge
from kci_cloud.triggers import cron_fields
from kci_resource_proto.resource import Resource

from kci_cloud.shape.limits import FAKE_CITATION
from kci_cloud.shape.shapes import ProviderShape, ROLE_IDENTITY, ROLE_SCHEDULE, ROLE_TRIGGER


comptime _DAY_OF_MONTH: Int = 2
comptime _DAY_OF_WEEK: Int = 4


def folds(r: Resource, edges: List[GrantEdge], shape: ProviderShape) -> Bool:
    """True iff `r` is a schedule whose target is a container job on a shape
    that folds it into the job (its target's type is on its CALL edge)."""
    if not shape.schedule_folds or not body_is(r, FIELD_SCHEDULE):
        return False
    for i in range(len(edges)):
        if edges[i].implicit and edges[i].target_field == FIELD_CONTAINER_JOB:
            return True
    return False


def _call_edge(r: Resource, edges: List[GrantEdge]) raises -> String:
    """The node of the trigger's one edge, CALL on its target."""
    for i in range(len(edges)):
        if edges[i].implicit:
            return r.id + String("/") + edges[i].role
    raise Error(String("fake: trigger \"") + r.id + String("\" was handed no CALL edge"))


def lower_trigger(r: Resource, edges: List[GrantEdge], shape: ProviderShape, wanted: Bool) raises -> List[LoweredNode]:
    """The trigger's one object after its identity (file header)."""
    var field = body_field(r)
    var deps = List[String]()
    deps.append(r.id + String("/") + String(ROLE_IDENTITY))
    var fields = List[Setting]()
    var role: String
    if field == FIELD_SCHEDULE:
        ref s = r.schedule.value()
        role = String(ROLE_SCHEDULE)
        var target = s.target.value().resource.copy()
        fields.append(Setting(String("cron"), s.cron.copy()))
        fields.append(Setting(String("timezone"), schedule_timezone(r)))
        fields.append(Setting(String("target"), target.copy()))
        deps.append(target^)
    elif field == FIELD_EVENT_TRIGGER:
        ref e = r.event_trigger.value()
        role = String(ROLE_TRIGGER)
        var source = e.source.value().resource.copy()
        var target = e.target.value().resource.copy()
        fields.append(Setting(String("source"), source.copy()))
        fields.append(Setting(String("event"), e.event.json_name()))
        fields.append(Setting(String("target"), target.copy()))
        deps.append(source^)
        deps.append(target^)
    else:
        raise Error(String("fake: resource \"") + r.id + String("\" is not a trigger"))
    deps.append(_call_edge(r, edges))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + role,
            r.id,
            shape.kind_of(field, role),
            deps^,
            List[InputRef](),
            fields^,
            wanted,
        )
    )
    return out^


def folded_fields(r: Resource, firings: List[Firing], shape: ProviderShape, mut fields: List[Setting]):
    """On a folding shape, the schedule of the container job `r` as fields of
    its run node: `schedule`, `cron`, `timezone` (the first firing; a second
    is a limit). Nothing elsewhere, and nothing for a job no schedule
    starts."""
    if not shape.schedule_folds or not body_is(r, FIELD_CONTAINER_JOB):
        return
    var into = firings_into(firings, r.id)
    if len(into) == 0:
        return
    fields.append(Setting(String("schedule"), into[0].schedule.copy()))
    fields.append(Setting(String("cron"), into[0].cron.copy()))
    fields.append(Setting(String("timezone"), into[0].timezone.copy()))


def _limit(r: Resource, path: String, cloud: String, why: String) -> Finding:
    return Finding(
        FINDING_LIMIT,
        r.id,
        path,
        String("on cloud \"") + cloud + String("\" ") + why,
        String(FAKE_CITATION),
    )


def trigger_limits(r: Resource, firings: List[Firing], shape: ProviderShape, cloud: String, mut out: List[Finding]):
    """The shape's trigger limits (file header) on `r`; nothing for any other
    type."""
    if not body_is(r, FIELD_SCHEDULE):
        return
    var cron = cron_fields(r.schedule.value().cron)
    if (
        shape.schedule_day_limit.byte_length() > 0
        and len(cron) == 5
        and cron[_DAY_OF_MONTH] != "*"
        and cron[_DAY_OF_WEEK] != "*"
    ):
        out.append(
            _limit(
                r,
                String("schedule.cron"),
                cloud,
                String("a cron cannot name both a day of the month and a day of the week: ")
                + shape.schedule_day_limit,
            )
        )
    var found = firing_of(firings, r.id)
    if not found:
        return  # its target is a graph finding
    ref f = found.value()
    if f.target_field == FIELD_SERVICE and shape.schedule_call_limit.byte_length() > 0:
        out.append(
            _limit(r, String("schedule.target"), cloud, String("a schedule cannot call a service: ") + shape.schedule_call_limit)
        )
    if f.target_field != FIELD_CONTAINER_JOB or not shape.schedule_folds:
        return
    var into = firings_into(firings, f.target)
    if into[0].schedule != r.id:
        out.append(
            _limit(
                r,
                String("schedule.target"),
                cloud,
                String("a container job's schedule is a setting of the job, and \"")
                + f.target
                + String("\" already has one: \"")
                + into[0].schedule
                + String("\""),
            )
        )
    if shape.schedule_utc_limit.byte_length() > 0 and f.timezone != String(TIMEZONE_DEFAULT):
        out.append(
            _limit(
                r,
                String("schedule.timezone"),
                cloud,
                String("a container job's schedule is read in UTC: ")
                + shape.schedule_utc_limit
                + String("; write the cron in UTC"),
            )
        )
