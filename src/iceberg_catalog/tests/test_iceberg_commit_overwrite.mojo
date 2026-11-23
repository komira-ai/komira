# =============================================================================
# test_iceberg_commit_overwrite.mojo — commit_append with `overwrite`: the
#   snapshot that replaces every row of `main`, against the in-process test
#   catalog.
# =============================================================================
#
#   * test_an_overwrite_of_an_empty_table_has_only_the_added_counts: no parent,
#     so no `deleted-*` or `removed-*` members; totals are the added counts.
#   * test_an_overwrite_counts_what_left_main: operation `overwrite`, the
#     `deleted-*` and `removed-*` members are the parent's totals, the totals
#     are the added counts with 0 delete counters, the parent, sequence number
#     and `main` follow, and `append_snapshot` of the same statement with
#     `overwrite` unset is an append.
#   * test_a_counter_the_parent_lacks_is_omitted: a parent total that is absent
#     or not an integer leaves its `deleted-*` or `removed-*` member out.
#   * test_a_zero_file_overwrite_of_a_table_with_data_empties_it: it commits a
#     snapshot with 0 added and the parent's totals as deleted.
#   * test_a_zero_file_overwrite_of_an_empty_table_sends_nothing: no commit and
#     the writer is never called; a zero-file append is the same.
#   * test_a_conflict_rebases_an_overwrite_on_the_new_parent: after a concurrent
#     append the retried overwrite counts the new parent's totals as deleted.
#   * test_an_overwrite_that_read_its_target_fails_on_conflict: it never
#     rebases, with the committer's exact message.
# No sockets; time is a ManualCommitClock.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from json import parse_json_value

from iceberg_catalog.iceberg_commit import (
    AppendCommit,
    AppendSnapshotWriter,
    ManualCommitClock,
    SequenceCommitIds,
    append_snapshot,
    commit_append,
)
from iceberg_catalog.iceberg_rest_catalog_client import (
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_rest_test_catalog import (
    InMemoryIcebergRestCatalog,
)
from iceberg_catalog.iceberg_table_changes import (
    CreateTableRequest,
    NewSnapshot,
    TableRequirement,
    TableUpdate,
    commit_table_body,
)
from iceberg_catalog.iceberg_table_metadata import SchemaField, TableMetadata


comptime _Client = IcebergRestCatalog[
    InMemoryIcebergRestCatalog, StaticBearerToken
]

comptime _T0: Int64 = 1795132800000

comptime _U1: String = "00000000-0000-4000-8000-000000000001"

comptime _C1: String = "00000000-0000-7000-8000-000000000001"


struct _Writer(AppendSnapshotWriter, Movable):
    """Records each call and returns `snap-<S>-<attempt>-x.avro`."""

    var attempts: List[Int]
    var parents: List[Int64]

    def __init__(out self):
        self.attempts = List[Int]()
        self.parents = List[Int64]()

    def write_manifest_list(
        mut self,
        snapshot_id: Int64,
        attempt: Int,
        base: TableMetadata,
        sequence_number: Int64,
    ) raises -> String:
        self.attempts.append(attempt)
        if base.main_snapshot_id:
            self.parents.append(base.main_snapshot_id.value())
        else:
            self.parents.append(-1)
        return _ml(snapshot_id, attempt)


def _ml(snapshot_id: Int64, attempt: Int) -> String:
    return (
        String("s3://wh/db/t/metadata/snap-")
        + String(snapshot_id)
        + String("-")
        + String(attempt)
        + String("-x.avro")
    )


def _i1(a: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    return l^


def _cols() -> List[SchemaField]:
    var c = List[SchemaField]()
    c.append(SchemaField(1, String("id"), True, String("long")))
    c.append(SchemaField(2, String("name"), False, String("string")))
    return c^


def _new_table() raises -> _Client:
    var cat = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    cat.create_namespace(String("db"))
    var client = _Client(
        String("catalog.example.com"), cat^, StaticBearerToken(String(""))
    )
    var schema = parse_json_value(
        String(
            '{"type":"struct","fields":['
            '{"id":1,"name":"id","required":true,"type":"long"},'
            '{"id":2,"name":"name","required":false,"type":"string"}]}'
        )
    )
    _ = client.create_table(
        String("db"), CreateTableRequest(String("t"), schema^, stage_create=False)
    )
    return client^


def _statement(
    var pins: List[Int64],
    files: Int64,
    records: Int64,
    size: Int64,
    overwrite: Bool,
) -> AppendCommit:
    return AppendCommit(
        String("db"),
        String("t"),
        _U1,
        _cols(),
        pins^,
        files,
        records,
        size,
        overwrite,
    )


def _land(
    mut client: _Client,
    snapshot_id: Int64,
    files: Int64,
    records: Int64,
    size: Int64,
    overwrite: Bool,
    now_ms: Int64,
) raises:
    """Commit a statement that lands as snapshot `snapshot_id`."""
    var writer = _Writer()
    var clock = ManualCommitClock(now_ms)
    var ids = SequenceCommitIds(_i1(snapshot_id))
    var o = commit_append(
        client,
        writer,
        clock,
        ids,
        _statement(List[Int64](), files, records, size, overwrite),
    )
    assert_true(o.committed)
    assert_equal(o.message, String(""))


def _other_writer_body(
    parent: Optional[Int64],
    sequence: Int64,
    id: Int64,
    ts: Int64,
    var names: List[String],
    var values: List[String],
) raises -> String:
    """Another writer's append whose summary is exactly `names`/`values`."""
    var snap = NewSnapshot(
        id,
        parent,
        sequence,
        ts,
        0,
        String("s3://wh/db/t/metadata/other-") + String(id) + String(".avro"),
        String("append"),
        names^,
        values^,
    )
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_snapshot(snap^))
    ups.append(TableUpdate.set_branch(String("main"), id))
    return commit_table_body(List[TableRequirement](), ups)


def _assert_strings(actual: List[String], expected: List[String]) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


def _names(overwrite_members: List[String]) -> List[String]:
    """`operation`, the three added counters, `overwrite_members`, the six
    totals and the commit id, for an overwrite."""
    var n = List[String]()
    n.append(String("operation"))
    n.append(String("added-data-files"))
    n.append(String("added-records"))
    n.append(String("added-files-size"))
    for i in range(len(overwrite_members)):
        n.append(String(overwrite_members[i]))
    n.append(String("total-data-files"))
    n.append(String("total-records"))
    n.append(String("total-files-size"))
    n.append(String("total-delete-files"))
    n.append(String("total-position-deletes"))
    n.append(String("total-equality-deletes"))
    n.append(String("komira.commit-id"))
    return n^


def _values(
    added_files: String,
    added_records: String,
    added_size: String,
    removed: List[String],
    commit_id: String,
) -> List[String]:
    """The values for `_names`: `removed` is the values of the members passed
    to it."""
    var v = List[String]()
    v.append(String("overwrite"))
    v.append(String(added_files))
    v.append(String(added_records))
    v.append(String(added_size))
    for i in range(len(removed)):
        v.append(String(removed[i]))
    v.append(String(added_files))
    v.append(String(added_records))
    v.append(String(added_size))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String(commit_id))
    return v^


def _members(a: Bool, b: Bool, c: Bool) -> List[String]:
    """The `deleted-*` and `removed-*` member names selected by the flags."""
    var out = List[String]()
    if a:
        out.append(String("deleted-data-files"))
    if b:
        out.append(String("deleted-records"))
    if c:
        out.append(String("removed-files-size"))
    return out^


def _s(a: String) -> List[String]:
    var l = List[String]()
    l.append(String(a))
    return l^


def _s2(a: String, b: String) -> List[String]:
    var l = _s(a)
    l.append(String(b))
    return l^


def _s3(a: String, b: String, c: String) -> List[String]:
    var l = _s(a)
    l.append(String(b))
    l.append(String(c))
    return l^


def test_an_overwrite_of_an_empty_table_has_only_the_added_counts() raises:
    var client = _new_table()
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(
        client, writer, clock, ids, _statement(List[Int64](), 2, 10, 1000, True)
    )

    assert_true(o.committed)
    assert_equal(o.message, String(""))
    assert_equal(o.posts, 1)
    assert_equal(o.landed_snapshot_id.value(), 7001)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    ref s = md.snapshots[0]
    assert_false(Bool(s.parent_id))
    _assert_strings(s.summary_names, _names(_members(False, False, False)))
    _assert_strings(
        s.summary_values,
        _values(
            String("2"), String("10"), String("1000"), List[String](), _C1
        ),
    )
    assert_equal(s.summary(String("operation")).value(), String("overwrite"))


def test_an_overwrite_counts_what_left_main() raises:
    var client = _new_table()
    _land(client, 7001, 2, 10, 1000, False, _T0)

    var writer = _Writer()
    var clock = ManualCommitClock(_T0 + 5000)
    var ids = SequenceCommitIds(_i1(7002))
    var o = commit_append(
        client, writer, clock, ids, _statement(List[Int64](), 1, 4, 400, True)
    )

    assert_true(o.committed)
    assert_equal(o.message, String(""))
    assert_equal(o.manifest_list, _ml(7002, 0))
    assert_equal(len(writer.attempts), 1)
    assert_equal(writer.parents[0], 7001)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    assert_equal(md.main_snapshot_id.value(), 7002)
    assert_equal(md.last_sequence_number, 2)
    ref s = md.snapshots[1]
    assert_equal(s.parent_id.value(), 7001)
    assert_equal(s.sequence_number, 2)
    assert_equal(s.timestamp_ms, _T0 + 5000)
    _assert_strings(s.summary_names, _names(_members(True, True, True)))
    _assert_strings(
        s.summary_values,
        _values(
            String("1"),
            String("4"),
            String("400"),
            _s3(String("2"), String("10"), String("1000")),
            _C1,
        ),
    )
    ref cat = client.transport_ref()
    var body = cat.request_bodies[cat.request_count() - 1]
    assert_true(
        body.find(
            String(
                '"summary":{"operation":"overwrite","added-data-files":"1",'
                '"added-records":"4","added-files-size":"400",'
                '"deleted-data-files":"2","deleted-records":"10",'
                '"removed-files-size":"1000","total-data-files":"1",'
            )
        )
        >= 0
    )


def test_the_same_statement_without_overwrite_is_an_append() raises:
    var client = _new_table()
    _land(client, 7001, 2, 10, 1000, False, _T0)
    var base = client.transport_ref().metadata(String("db"), String("t"))

    var as_overwrite = append_snapshot(
        _statement(List[Int64](), 1, 4, 400, True),
        base,
        7002,
        _C1,
        _ml(7002, 0),
        _T0 + 5000,
    )
    var as_append = append_snapshot(
        _statement(List[Int64](), 1, 4, 400, False),
        base,
        7002,
        _C1,
        _ml(7002, 0),
        _T0 + 5000,
    )
    assert_equal(as_overwrite.operation, String("overwrite"))
    assert_equal(as_append.operation, String("append"))
    assert_equal(len(as_append.summary_names), 10)
    assert_equal(as_append.summary_values[3], String("3"))
    assert_equal(as_append.summary_values[4], String("14"))
    assert_equal(as_append.summary_values[5], String("1400"))
    assert_equal(len(as_overwrite.summary_names), 13)
    assert_equal(as_overwrite.summary_names[3], String("deleted-data-files"))
    assert_equal(as_overwrite.summary_values[3], String("2"))
    assert_equal(as_overwrite.summary_values[6], String("1"))


def test_a_counter_the_parent_lacks_is_omitted() raises:
    var client = _new_table()
    # Another writer's snapshot lands first: its summary has `total-records`
    # and a `total-files-size` that is not an integer, and no
    # `total-data-files`. The first POST is answered 409 and the overwrite is
    # rebuilt on that parent.
    client.transport_ref().before_next_commit(
        _other_writer_body(
            None,
            1,
            8001,
            _T0,
            _s2(String("total-records"), String("total-files-size")),
            _s2(String("50"), String("many")),
        )
    )
    var writer = _Writer()
    var clock = ManualCommitClock(_T0 + 10)
    var ids = SequenceCommitIds(_i1(7002))

    var o = commit_append(
        client, writer, clock, ids, _statement(List[Int64](), 1, 4, 400, True)
    )

    assert_true(o.committed)
    assert_equal(writer.parents[1], 8001)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    ref s = md.snapshots[1]
    _assert_strings(s.summary_names, _names(_members(False, True, False)))
    _assert_strings(
        s.summary_values,
        _values(String("1"), String("4"), String("400"), _s(String("50")), _C1),
    )


def test_a_zero_file_overwrite_of_a_table_with_data_empties_it() raises:
    var client = _new_table()
    _land(client, 7001, 2, 10, 1000, False, _T0)

    var writer = _Writer()
    var clock = ManualCommitClock(_T0 + 5000)
    var ids = SequenceCommitIds(_i1(7002))
    var o = commit_append(
        client, writer, clock, ids, _statement(List[Int64](), 0, 0, 0, True)
    )

    assert_true(o.committed)
    assert_equal(o.message, String(""))
    assert_equal(o.posts, 1)
    assert_equal(o.landed_snapshot_id.value(), 7002)
    assert_equal(len(writer.attempts), 1)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    assert_equal(md.main_snapshot_id.value(), 7002)
    ref s = md.snapshots[1]
    _assert_strings(s.summary_names, _names(_members(True, True, True)))
    _assert_strings(
        s.summary_values,
        _values(
            String("0"),
            String("0"),
            String("0"),
            _s3(String("2"), String("10"), String("1000")),
            _C1,
        ),
    )


def test_a_zero_file_overwrite_of_an_empty_table_sends_nothing() raises:
    var client = _new_table()
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var before = client.transport_ref().request_count()

    var o = commit_append(
        client, writer, clock, ids, _statement(List[Int64](), 0, 0, 0, True)
    )
    assert_true(o.committed)
    assert_equal(o.posts, 0)
    assert_equal(o.snapshot_id, 0)
    assert_false(Bool(o.landed_snapshot_id))
    assert_equal(len(writer.attempts), 0)
    assert_equal(client.transport_ref().request_count() - before, 1)
    assert_equal(client.transport_ref().applied_commits, 0)

    # A zero-file append of a table with data is the same: nothing is sent.
    _land(client, 7001, 2, 10, 1000, False, _T0)
    var writer2 = _Writer()
    var clock2 = ManualCommitClock(_T0)
    var ids2 = SequenceCommitIds(_i1(7002))
    var applied = client.transport_ref().applied_commits
    var o2 = commit_append(
        client,
        writer2,
        clock2,
        ids2,
        _statement(List[Int64](), 0, 0, 0, False),
    )
    assert_true(o2.committed)
    assert_equal(o2.posts, 0)
    assert_equal(len(writer2.attempts), 0)
    assert_equal(client.transport_ref().applied_commits, applied)


def test_a_conflict_rebases_an_overwrite_on_the_new_parent() raises:
    var client = _new_table()
    client.transport_ref().before_next_commit(
        _other_writer_body(
            None,
            1,
            8001,
            _T0 + 50,
            _s3(
                String("total-data-files"),
                String("total-records"),
                String("total-files-size"),
            ),
            _s3(String("5"), String("50"), String("5000")),
        )
    )
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(
        client, writer, clock, ids, _statement(List[Int64](), 2, 10, 1000, True)
    )

    assert_true(o.committed)
    assert_equal(o.message, String(""))
    assert_equal(o.posts, 2)
    assert_equal(len(writer.attempts), 2)
    assert_equal(writer.parents[0], -1)
    assert_equal(writer.parents[1], 8001)
    assert_equal(len(o.manifest_lists_to_delete), 1)
    assert_equal(o.manifest_lists_to_delete[0], _ml(7001, 0))
    var md = client.transport_ref().metadata(String("db"), String("t"))
    ref s = md.snapshots[1]
    assert_equal(s.parent_id.value(), 8001)
    assert_equal(s.sequence_number, 2)
    _assert_strings(s.summary_names, _names(_members(True, True, True)))
    _assert_strings(
        s.summary_values,
        _values(
            String("2"),
            String("10"),
            String("1000"),
            _s3(String("5"), String("50"), String("5000")),
            _C1,
        ),
    )


def test_an_overwrite_that_read_its_target_fails_on_conflict() raises:
    var client = _new_table()
    _land(client, 7001, 2, 10, 1000, False, _T0)
    client.transport_ref().before_next_commit(
        _other_writer_body(
            Optional[Int64](7001),
            2,
            8001,
            _T0 + 50,
            _s3(
                String("total-data-files"),
                String("total-records"),
                String("total-files-size"),
            ),
            _s3(String("5"), String("50"), String("5000")),
        )
    )
    var writer = _Writer()
    var clock = ManualCommitClock(_T0 + 100)
    var ids = SequenceCommitIds(_i1(7002))

    var o = commit_append(
        client,
        writer,
        clock,
        ids,
        _statement(_i1(7001), 1, 4, 400, True),
    )

    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_COMMIT_CONFLICT: commit to 'db.t': the statement read the"
            " table at snapshot 7001, and main is now 8001"
        ),
    )
    assert_true(o.delete_statement_files)
    assert_equal(len(clock.waits), 0)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    assert_equal(md.main_snapshot_id.value(), 8001)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
