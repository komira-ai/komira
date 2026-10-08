# =============================================================================
# kci_cloud_fake/roles.mojo: the fakes' role table, for a shape whose grants
#   are DERIVED member bindings.
# =============================================================================
#
# A member binding holds a ROLE, and attribution reads the access verb back
# from it through the adapter's table (kci_cloud/derived.mojo). A real
# adapter's table is the cloud's own roles; the fakes' is generated from the
# shape, one row per (target, access):
#   * every provider kind of the shape's rows (each primary object a grant can
#     target), with every catalog access verb and `ACCESS_PUBLIC`;
#   * every cell resource (`cell/LOGS`, `cell/METRICS`, `cell/ARTIFACTS`) with
#     each verb it accepts.
# The role is `roles/fake/<target>:<access>`. No access word holds `:`, so
# the role reads back to exactly one row: the table is injective by
# construction, and `role_table_problems` is empty for it (a test says so).
# A role outside the table (`fake_store.UNMAPPED_ROLE`) maps to nothing.
# =============================================================================

from kci_cloud import (
    ACCESS_CALL,
    ACCESS_DESCRIBE,
    ACCESS_PUBLIC,
    ACCESS_READ,
    ACCESS_READ_WRITE,
    ACCESS_RECEIVE,
    ACCESS_SEND,
    ACCESS_WRITE,
    CELL_ARTIFACTS,
    CELL_LOGS,
    CELL_METRICS,
    CELL_PATH_PREFIX,
    ProviderShape,
    RoleRow,
    cell_accepts,
    cell_name,
)


comptime FAKE_ROLE_PREFIX = "roles/fake/"


def fake_role(target: String, access: String) -> String:
    """The fakes' role for `access` on `target` (a kind, or `cell/<NAME>`)."""
    return String(FAKE_ROLE_PREFIX) + target + String(":") + access


def _verbs() -> List[String]:
    return [
        String(ACCESS_CALL),
        String(ACCESS_READ),
        String(ACCESS_WRITE),
        String(ACCESS_READ_WRITE),
        String(ACCESS_DESCRIBE),
        String(ACCESS_SEND),
        String(ACCESS_RECEIVE),
        String(ACCESS_PUBLIC),
    ]


def fake_role_table(shape: ProviderShape) -> List[RoleRow]:
    """The role table of a fake built with `shape` (the file header)."""
    var out = List[RoleRow]()
    var kinds = List[String]()
    for i in range(len(shape.rows)):
        ref k = shape.rows[i].kind
        var seen = False
        for j in range(len(kinds)):
            if kinds[j] == k:
                seen = True
        if not seen:
            kinds.append(k.copy())
    var verbs = _verbs()
    for i in range(len(kinds)):
        for v in range(len(verbs)):
            out.append(RoleRow(kinds[i].copy(), verbs[v].copy(), fake_role(kinds[i], verbs[v])))
    for cell in [CELL_LOGS, CELL_METRICS, CELL_ARTIFACTS]:
        var target = String(CELL_PATH_PREFIX) + cell_name(cell)
        for v in range(len(verbs)):
            if cell_accepts(cell, verbs[v]):
                out.append(RoleRow(target.copy(), verbs[v].copy(), fake_role(target, verbs[v])))
    return out^
