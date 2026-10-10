# =============================================================================
# kci_cloud/firing.mojo: the FIRINGS kci hands every cloud adapter, and the
# schedule's versioned default.
# =============================================================================
#
# A FIRING is one schedule as kci reads it: (schedule, target, the target's
# type, cron, time zone with the default written out). `firings_of` lists
# every schedule of a list whose target names a container job or a service
# of it, in list order (any other schedule is a graph finding,
# triggers.mojo). kci hands the firings to `CloudAdapter.check` and
# `CloudAdapter.lower` with every resource, as it hands the feeds
# (feed.mojo), because what a container job lowers to can depend on the
# schedules that start it: on a cloud where a job's schedule is a setting of
# the job's own object, the job is lowered from its firing, and a shape that
# cloud cannot host (two schedules on one job) is refused as a limit before
# anything is created. An adapter still lowers one resource without reading
# the others.
#
# THE VERSIONED DEFAULT. An unwritten `timezone` is UTC (`TIMEZONE_DEFAULT`)
# on every cloud; kci writes it out, so a file means the same on a cloud
# whose own default differs.
# =============================================================================

from kci_resource_proto.resource import Resource

from kci_cloud.catalog import FIELD_CONTAINER_JOB, FIELD_SERVICE
from kci_cloud.feed import field_of_id


comptime TIMEZONE_DEFAULT = "UTC"
"""What an unwritten `Schedule.timezone` means."""


@fieldwise_init
struct Firing(Copyable, Movable, Deinitable):
    """One schedule, as kci reads it: `schedule` starts or calls `target` (a
    resource id of type `target_field`) at the times `cron` names, in
    `timezone` (the default written out)."""

    var schedule: String
    var target: String
    var target_field: Int
    var cron: String
    var timezone: String


def schedule_timezone(r: Resource) -> String:
    """Schedule `r`'s time zone: the written one, else the versioned
    default."""
    if r.schedule and r.schedule.value().timezone.byte_length() > 0:
        return r.schedule.value().timezone.copy()
    return String(TIMEZONE_DEFAULT)


def firings_of(resources: List[Resource]) -> List[Firing]:
    """Every schedule of `resources` whose target names a container job or a
    service of it, in list order (the others are graph findings)."""
    var out = List[Firing]()
    for i in range(len(resources)):
        ref r = resources[i]
        if not r.schedule or not r.schedule.value().target:
            continue
        var target = r.schedule.value().target.value().resource.copy()
        var f = field_of_id(resources, target)
        if f != FIELD_CONTAINER_JOB and f != FIELD_SERVICE:
            continue
        out.append(Firing(r.id.copy(), target^, f, r.schedule.value().cron.copy(), schedule_timezone(r)))
    return out^


def firings_into(firings: List[Firing], target: String) -> List[Firing]:
    """The firings whose target is `target`, in order."""
    var out = List[Firing]()
    for i in range(len(firings)):
        if firings[i].target == target:
            out.append(firings[i].copy())
    return out^


def firing_of(firings: List[Firing], schedule: String) -> Optional[Firing]:
    """The firing of the schedule `schedule`, or None."""
    for i in range(len(firings)):
        if firings[i].schedule == schedule:
            return firings[i].copy()
    return None
