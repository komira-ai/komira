# =============================================================================
# iceberg_catalog/iceberg_commit_summary.mojo — the members of the summary of
#   the snapshot a statement commits: an append's or an overwrite's.
# =============================================================================
#
# `snapshot_summary` appends, in this order, to the names and values of a new
# snapshot's summary (the operation and `komira.commit-id` are the caller's):
#
#   * append:    `added-data-files`, `added-records`, `added-files-size`, then
#                the six `total-*` counters, each the parent's plus what the
#                statement added.
#   * overwrite: the same three `added-*` members; then
#                `deleted-data-files`, `deleted-records` and
#                `removed-files-size`, the parent's `total-data-files`,
#                `total-records` and `total-files-size` (every row of `main`
#                leaves); then the `total-*` counters of what the snapshot
#                holds, which is what the statement added, with 0 delete
#                files, position deletes and equality deletes.
#
# A counter taken from the parent is omitted when the parent's summary lacks
# it or holds something that is not an integer, rather than guessed. A table
# with no parent snapshot has no `deleted-*` or `removed-*` members, and an
# append's totals start at the added counts.
# =============================================================================

from .iceberg_table_metadata import TableMetadata


def snapshot_summary(
    base: TableMetadata,
    parent_index: Int,
    overwrite: Bool,
    added_files: Int64,
    added_records: Int64,
    added_size: Int64,
    mut names: List[String],
    mut values: List[String],
):
    """Append the summary members of one attempt on `base` (module header).
    `parent_index` is the index in `base.snapshots` of `main`'s snapshot, or
    -1 when there is none or the table no longer lists it."""
    names.append(String("added-data-files"))
    values.append(String(added_files))
    names.append(String("added-records"))
    values.append(String(added_records))
    names.append(String("added-files-size"))
    values.append(String(added_size))
    if overwrite:
        _removed(
            base,
            parent_index,
            names,
            values,
            String("deleted-data-files"),
            String("total-data-files"),
        )
        _removed(
            base,
            parent_index,
            names,
            values,
            String("deleted-records"),
            String("total-records"),
        )
        _removed(
            base,
            parent_index,
            names,
            values,
            String("removed-files-size"),
            String("total-files-size"),
        )
        names.append(String("total-data-files"))
        values.append(String(added_files))
        names.append(String("total-records"))
        values.append(String(added_records))
        names.append(String("total-files-size"))
        values.append(String(added_size))
        names.append(String("total-delete-files"))
        values.append(String("0"))
        names.append(String("total-position-deletes"))
        values.append(String("0"))
        names.append(String("total-equality-deletes"))
        values.append(String("0"))
        return
    _total(base, parent_index, names, values, String("total-data-files"), added_files)
    _total(base, parent_index, names, values, String("total-records"), added_records)
    _total(base, parent_index, names, values, String("total-files-size"), added_size)
    _total(base, parent_index, names, values, String("total-delete-files"), 0)
    _total(base, parent_index, names, values, String("total-position-deletes"), 0)
    _total(base, parent_index, names, values, String("total-equality-deletes"), 0)


def _parent_count(
    base: TableMetadata, parent_index: Int, name: String
) -> Optional[Int64]:
    """The parent snapshot's summary member `name` as an integer; None when
    there is no parent snapshot, its summary lacks the member or the member is
    not an integer."""
    if parent_index < 0:
        return None
    var prev = base.snapshots[parent_index].summary(name)
    if not prev:
        return None
    try:
        return Optional[Int64](Int64(Int(prev.value())))
    except:
        return None


def _removed(
    base: TableMetadata,
    parent_index: Int,
    mut names: List[String],
    mut values: List[String],
    name: String,
    parent_name: String,
):
    """Append `name` = the parent's `parent_name`; omitted when the parent has
    no integer one."""
    var n = _parent_count(base, parent_index, parent_name)
    if not n:
        return
    names.append(name)
    values.append(String(n.value()))


def _total(
    base: TableMetadata,
    parent_index: Int,
    mut names: List[String],
    mut values: List[String],
    name: String,
    added: Int64,
):
    """Append `name` = parent's `name` + `added`; with no parent snapshot,
    `added`; omitted when the parent's summary lacks it or it is not an
    integer."""
    if parent_index < 0:
        if base.main_snapshot_id:
            return  # main names a snapshot the table no longer lists
        names.append(name)
        values.append(String(added))
        return
    var prev = _parent_count(base, parent_index, name)
    if not prev:
        return
    names.append(name)
    values.append(String(prev.value() + added))
