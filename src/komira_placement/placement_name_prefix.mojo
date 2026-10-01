# =============================================================================
# komira_placement/placement_name_prefix.mojo — the ONE spelling of the name
#   prefix every job-manager placement carries by default.
# =============================================================================
#
# The job manager names each unit it places (a pod, a Cloud Run job or service,
# an ECS task-definition family) `<prefix>-<id>`, and its config default for that
# prefix is THIS constant; a deployment overrides it through the job manager's
# configuration. The reconciler uses the same prefix to decide which rows it
# owns (`placement_types.reconciler_owns_placement`).
#
# ⛔ A SECOND READER MAY DEPEND ON THIS EXACT LINE. A cloud-resource leak
# checker that enumerates placements by name prefix should read the
# `comptime DEFAULT_PLACEMENT_NAME_PREFIX` assignment below rather than restate
# it. So:
#   * keep it a single-line `comptime ... : StaticString = "..."` assignment;
#     a reader that cannot parse it must refuse rather than guess, and treat an
#     empty value the same way;
#   * never spell the prefix anywhere else. A job manager default written as a
#     literal elsewhere could drift from this one, and a checker would keep
#     enumerating a prefix nothing is placed under: it would report a clean
#     fleet over standing placements.
#
# ⚠ THE VALUE NAMES LIVE CLOUD RESOURCES. Changing it strands every placement
# already created under the old prefix, because nothing would enumerate them
# any more. A deployment with placements under another prefix must set that
# prefix explicitly, or reap the old ones first and prove zero, then rename.
# =============================================================================

comptime DEFAULT_PLACEMENT_NAME_PREFIX: StaticString = "komira-job"
