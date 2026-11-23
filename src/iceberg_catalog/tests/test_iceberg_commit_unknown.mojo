# =============================================================================
# test_iceberg_commit_unknown.mojo — `commit_append` against the in-process
#   catalog: each answer of "What each response means" and "Unknown outcome"
#   (docs/design/iceberg_tables.md), the idempotency-key rules, and the retry
#   budget, by exact message. No sockets: the catalog is
#   InMemoryIcebergRestCatalog behind a small wrapper that can fail loads; time
#   is ManualCommitClock (every wait is asserted); ids are SequenceCommitIds.
# =============================================================================
#
# Each case holds one behaviour:
#   * A 500, 502, 503, 504 or a dropped connection after the catalog applied
#     the commit is found by S: success, one snapshot, one commit POST, no
#     second body. Before the catalog applied it, the lookup shows main still
#     at P and the attempt is retried once.
#   * A catalog that stores another snapshot id is found by komira.commit-id,
#     and the outcome keeps the landed snapshot's manifest list.
#   * A 200 whose metadata lacks S and C, an unknown outcome after which main
#     moved (with S expired or never applied), reloads that keep failing, and
#     a tainted statement whose 409 ends it, all fail with
#     ICEBERG_COMMIT_STATE_UNKNOWN naming S, C, the table and the manifest
#     list, and allow no deletion.
#   * A tainted statement's later 409 or 403 finds a landed commit; a 403 with
#     main still at P allows deletion, with main moved it does not.
#   * A refused answer on an untainted statement fails with its token and
#     allows deleting every manifest list written.
#   * Idempotency: the key is sent only when advertised; an unknown outcome
#     resends the byte-identical body under the same key and the catalog
#     replays its stored answer; every later attempt has a new key.
#   * The retry budget, the snapshot-id draw, the writer and the endpoint list
#     each end a statement with their own message.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import parse_json_value

from iceberg_catalog.iceberg_commit import (
    AppendCommit,
    AppendCommitOutcome,
    AppendSnapshotWriter,
    ManualCommitClock,
    SequenceCommitIds,
    append_commit_body,
    append_snapshot,
    commit_append,
)
from iceberg_catalog.iceberg_rest_catalog_client import (
    ENDPOINT_COMMIT_TABLE,
    ENDPOINT_CREATE_TABLE,
    ENDPOINT_LOAD_TABLE,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_rest_test_catalog import (
    CommitFault,
    InMemoryIcebergRestCatalog,
)
from iceberg_catalog.iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
    IcebergRestTransport,
)
from iceberg_catalog.iceberg_table_changes import CreateTableRequest
from iceberg_catalog.iceberg_table_metadata import SchemaField, TableMetadata


comptime _TBL: String = "/v1/namespaces/db/tables/t"
comptime _SCHEMA: String = (
    '{"type":"struct","fields":[{"id":1,"name":"a","required":false,'
    '"type":"long"}]}'
)
comptime _UNKNOWN: String = (
    "ICEBERG_COMMIT_STATE_UNKNOWN: commit to 'db.t' may or may not have"
    " landed: snapshot 200, commit id "
)
comptime _E500: String = (
    "ICEBERG_CATALOG_UNAVAILABLE: commitTable 'db.t': HTTP 500:"
    " ServiceFailureException: scripted failure"
)
comptime _E403: String = (
    "ICEBERG_CATALOG_FORBIDDEN: commitTable 'db.t': HTTP 403:"
    " ServiceFailureException: scripted failure"
)
comptime _E400: String = (
    "ICEBERG_CATALOG_REJECTED: commitTable 'db.t': HTTP 400:"
    " ServiceFailureException: scripted failure"
)
comptime _E503_LOAD: String = (
    "ICEBERG_CATALOG_UNAVAILABLE: loadTable 'db.t': HTTP 503"
)
comptime _E404_LOAD: String = (
    "ICEBERG_TABLE_NOT_FOUND: loadTable 'db.t': HTTP 404"
)


# =============================================================================
# doubles and harness.
# =============================================================================


struct LoadFaultCatalog(IcebergRestTransport, Movable):
    """The in-memory catalog, with table GETs that answer a status with no
    body after `pass_loads` of them, `fail_loads` times, and a commit POST
    that can be answered 200 with a fixed (stale) table body, unforwarded."""

    var inner: InMemoryIcebergRestCatalog
    var loads: Int
    var pass_loads: Int
    var fail_loads: Int
    var fail_status: Int
    var stale_commit_body: String

    def __init__(out self, var inner: InMemoryIcebergRestCatalog):
        self.inner = inner^
        self.loads = 0
        self.pass_loads = 1000000
        self.fail_loads = 0
        self.fail_status = 503
        self.stale_commit_body = String("")

    def send(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        if request.path == String(_TBL):
            if not request.method.is_post():
                self.loads += 1
                if self.loads > self.pass_loads and self.fail_loads > 0:
                    self.fail_loads -= 1
                    return IcebergRestResponse(self.fail_status, String(""))
            elif self.stale_commit_body.byte_length() > 0:
                return IcebergRestResponse(200, String(self.stale_commit_body))
        return self.inner.send(request)


struct RecordingWriter(AppendSnapshotWriter, Movable):
    """Names each manifest list `ml-<snapshot id>-<attempt>` and records what
    it was asked for; raises at `fail_attempt`."""

    var snapshot_ids: List[Int64]
    var attempts: List[Int]
    var parents: List[Int64]
    var sequences: List[Int64]
    var fail_attempt: Int

    def __init__(out self):
        self.snapshot_ids = List[Int64]()
        self.attempts = List[Int]()
        self.parents = List[Int64]()
        self.sequences = List[Int64]()
        self.fail_attempt = -1

    def write_manifest_list(
        mut self,
        snapshot_id: Int64,
        attempt: Int,
        base: TableMetadata,
        sequence_number: Int64,
    ) raises -> String:
        self.snapshot_ids.append(snapshot_id)
        self.attempts.append(attempt)
        var p = Int64(-1)
        if base.main_snapshot_id:
            p = base.main_snapshot_id.value()
        self.parents.append(p)
        self.sequences.append(sequence_number)
        if attempt == self.fail_attempt:
            raise Error("writer: disk full")
        return _ml(snapshot_id, attempt)


comptime Cat = IcebergRestCatalog[LoadFaultCatalog, StaticBearerToken]


def _ml(snapshot_id: Int64, attempt: Int) -> String:
    return String("ml-") + String(snapshot_id) + String("-") + String(attempt)


def _u(k: Int) -> String:
    """The k-th uuid SequenceCommitIds hands out."""
    var d = String(k)
    var pad = String("")
    for _ in range(12 - d.byte_length()):
        pad += "0"
    return String("00000000-0000-7000-8000-") + pad + d


def _ids(a: Int64, b: Int64) -> SequenceCommitIds:
    var l = List[Int64]()
    l.append(a)
    l.append(b)
    return SequenceCommitIds(l^)


def _columns() -> List[SchemaField]:
    var c = List[SchemaField]()
    c.append(SchemaField(1, String("a"), False, String("long")))
    return c^


def _commit_for(uuid: String, var pins: List[Int64]) -> AppendCommit:
    return AppendCommit(
        String("db"), String("t"), String(uuid), _columns(), pins^, 1, 10, 1000
    )


struct Harness(Movable):
    var cat: Cat
    var ids: SequenceCommitIds
    var writer: RecordingWriter
    var clock: ManualCommitClock
    var table_uuid: String
    var start: Int
    var applied0: Int

    def __init__(
        out self,
        var cat: Cat,
        var ids: SequenceCommitIds,
        var table_uuid: String,
    ):
        self.cat = cat^
        self.ids = ids^
        self.writer = RecordingWriter()
        self.clock = ManualCommitClock(2000000)
        self.table_uuid = table_uuid^
        self.start = 0
        self.applied0 = 0

    def run(mut self) -> AppendCommitOutcome:
        return self.run_pinned(List[Int64]())

    def run_pinned(mut self, var pins: List[Int64]) -> AppendCommitOutcome:
        return commit_append(
            self.cat,
            self.writer,
            self.clock,
            self.ids,
            _commit_for(self.table_uuid, pins^),
        )

    def fault(mut self, status: Int, apply_first: Bool):
        self.cat.transport_ref().inner.fault_next_commit(
            CommitFault(status, apply_first=apply_first)
        )

    def fault_with(mut self, var f: CommitFault):
        self.cat.transport_ref().inner.fault_next_commit(f^)

    def fail_loads(mut self, pass_loads: Int, count: Int, status: Int):
        self.cat.transport_ref().pass_loads = pass_loads
        self.cat.transport_ref().fail_loads = count
        self.cat.transport_ref().fail_status = status

    def loads(mut self) -> Int:
        return self.cat.transport_ref().loads

    def meta(mut self) raises -> TableMetadata:
        return self.cat.transport_ref().inner.metadata(
            String("db"), String("t")
        )

    def applied(mut self) -> Int:
        return self.cat.transport_ref().inner.applied_commits - self.applied0

    def requests(mut self) -> Int:
        return len(self.cat.transport_ref().inner.request_paths) - self.start

    def posts(mut self) -> List[Int]:
        """Indexes (into the catalog's request log) of the commit POSTs since
        the statement started."""
        var out = List[Int]()
        ref m = self.cat.transport_ref().inner
        for i in range(self.start, len(m.request_paths)):
            if m.request_methods[i] == "POST" and m.request_paths[i] == _TBL:
                out.append(i)
        return out^

    def body(mut self, i: Int) -> String:
        return String(self.cat.transport_ref().inner.request_bodies[i])

    def key(mut self, i: Int) -> String:
        return String(self.cat.transport_ref().inner.request_keys[i])

    def other_writer_body(
        mut self, parent: Int64, last_sequence: Int64, id: Int64
    ) raises -> String:
        """Another writer's append of snapshot `id` on `parent`."""
        var md = self.meta()
        md.main_snapshot_id = Optional[Int64](parent)
        md.last_sequence_number = last_sequence
        var snap = append_snapshot(
            _commit_for(self.table_uuid, List[Int64]()),
            md,
            id,
            String("other-commit"),
            String("ml-other"),
            3000000,
        )
        return append_commit_body(md, snap)


def _harness(
    idem: Bool,
    retries: String,
    seed: Bool,
    endpoints: Bool,
    var ids: SequenceCommitIds,
) raises -> Harness:
    """A catalog with namespace `db` and table `t` (one column); with `seed`,
    `main` is at snapshot 100 (written by a first statement that draws its ids
    from `ids`)."""
    var mem = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    mem.create_namespace(String("db"))
    if idem:
        mem.advertise_idempotency()
    if endpoints:
        var eps = List[String]()
        eps.append(String(ENDPOINT_CREATE_TABLE))
        eps.append(String(ENDPOINT_LOAD_TABLE))
        mem.list_endpoints(eps^)
    var cat = Cat(
        String("catalog.example.com"),
        LoadFaultCatalog(mem^),
        StaticBearerToken(String("k")),
    )
    var req = CreateTableRequest(
        String("t"), parse_json_value(String(_SCHEMA)), stage_create=False
    )
    if retries.byte_length() > 0:
        req.set_property(String("commit.retry.num-retries"), retries)
    _ = cat.create_table(String("db"), req)
    var uuid = cat.transport_ref().inner.metadata(
        String("db"), String("t")
    ).table_uuid
    if seed:
        var w = RecordingWriter()
        var c = ManualCommitClock(1000000)
        var o = commit_append(cat, w, c, ids, _commit_for(uuid, List[Int64]()))
        assert_true(o.committed)
    var h = Harness(cat^, ids^, uuid^)
    h.start = len(h.cat.transport_ref().inner.request_paths)
    h.applied0 = h.cat.transport_ref().inner.applied_commits
    h.cat.transport_ref().loads = 0
    return h^


def _h() raises -> Harness:
    return _harness(False, String(""), True, False, _ids(100, 200))


def _hi() raises -> Harness:
    return _harness(True, String(""), True, False, _ids(100, 200))


def _hr(retries: String, idem: Bool = False) raises -> Harness:
    return _harness(idem, retries, True, False, _ids(100, 200))


# =============================================================================
# assertions.
# =============================================================================


def _strs(got: List[String], want: List[String]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(got)):
        assert_equal(got[i], want[i])


def _ints(got: List[Int64], want: List[Int64]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(got)):
        assert_equal(got[i], want[i])


def _l(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _l2(a: String, b: String) -> List[String]:
    var l = _l(a)
    l.append(b)
    return l^


def _i1(a: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    return l^


def _i2(a: Int64, b: Int64) -> List[Int64]:
    var l = _i1(a)
    l.append(b)
    return l^


def _i3(a: Int64, b: Int64, c: Int64) -> List[Int64]:
    var l = _i2(a, b)
    l.append(c)
    return l^


def _i4(a: Int64, b: Int64, c: Int64, d: Int64) -> List[Int64]:
    var l = _i3(a, b, c)
    l.append(d)
    return l^


def _main_id(md: TableMetadata) -> Int64:
    if md.main_snapshot_id:
        return md.main_snapshot_id.value()
    return -1


def _landed(o: AppendCommitOutcome) -> Int64:
    if o.landed_snapshot_id:
        return o.landed_snapshot_id.value()
    return -1


def _committed(
    o: AppendCommitOutcome, landed: Int64, manifest_list: String
) raises:
    assert_true(o.committed)
    assert_equal(o.message, String(""))
    assert_equal(_landed(o), landed)
    assert_equal(o.manifest_list, manifest_list)
    assert_false(o.delete_statement_files)


def _unknown_message(
    commit_id: String, manifest_list: String, cause: String
) -> String:
    return (
        String(_UNKNOWN)
        + commit_id
        + String(", manifest list ")
        + manifest_list
        + String(": ")
        + cause
    )


def _no_deletion(o: AppendCommitOutcome) raises:
    assert_false(o.committed)
    assert_false(o.delete_statement_files)
    assert_equal(len(o.manifest_lists_to_delete), 0)


# =============================================================================
# 5xx and dropped connections.
# =============================================================================


def _applied_then(status: Int) raises:
    """The catalog applied the commit and then answered `status` (0: dropped
    connection): found by S, nothing sent twice."""
    var h = _h()
    h.fault(status, True)
    var o = h.run()
    _committed(o, 200, _ml(200, 0))
    assert_equal(o.snapshot_id, Int64(200))
    assert_equal(o.commit_id, _u(2))
    assert_equal(o.posts, 1)
    assert_equal(len(h.posts()), 1)
    assert_equal(h.applied(), 1)
    assert_equal(len(h.writer.attempts), 1)
    assert_equal(len(h.meta().snapshots), 2)
    assert_equal(_main_id(h.meta()), Int64(200))
    assert_equal(len(o.manifest_lists_to_delete), 0)
    _ints(h.clock.waits, _i1(100))


def _unapplied_then(status: Int) raises:
    """The catalog answered `status` without applying: main is still at P, so
    the attempt is retried once, on a new manifest list."""
    var h = _h()
    h.fault(status, False)
    var o = h.run()
    _committed(o, 200, _ml(200, 1))
    assert_equal(o.posts, 2)
    var p = h.posts()
    assert_equal(len(p), 2)
    assert_true(h.body(p[0]) != h.body(p[1]))
    assert_equal(h.applied(), 1)
    assert_equal(len(h.meta().snapshots), 2)
    assert_equal(len(h.writer.attempts), 2)
    assert_equal(h.writer.attempts[0], 0)
    assert_equal(h.writer.attempts[1], 1)
    _ints(h.writer.parents, _i2(100, 100))
    _ints(h.writer.sequences, _i2(2, 2))
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))
    _ints(h.clock.waits, _i1(100))


def test_500_after_apply_succeeds_without_second_snapshot() raises:
    _applied_then(500)


def test_500_before_apply_retries_once_and_succeeds() raises:
    _unapplied_then(500)


def test_502_after_apply_is_found_by_snapshot_id() raises:
    _applied_then(502)


def test_502_before_apply_retries_once() raises:
    _unapplied_then(502)


def test_503_after_apply_is_found_by_snapshot_id() raises:
    _applied_then(503)


def test_503_before_apply_retries_once() raises:
    _unapplied_then(503)


def test_504_after_apply_is_found_by_snapshot_id() raises:
    _applied_then(504)


def test_504_before_apply_retries_once() raises:
    _unapplied_then(504)


def test_dropped_connection_after_apply_is_found_by_snapshot_id() raises:
    _applied_then(0)


def test_dropped_connection_before_apply_retries_once() raises:
    _unapplied_then(0)


# =============================================================================
# a rewritten snapshot id, a 200 without the commit.
# =============================================================================


def test_rewritten_snapshot_id_is_found_by_commit_id() raises:
    var h = _h()
    h.fault_with(CommitFault(500, apply_first=True, rewrite_snapshot_id=777))
    var o = h.run()
    # The landed snapshot is the catalog's 777; its manifest list is the one
    # this statement wrote.
    _committed(o, 777, _ml(200, 0))
    assert_equal(o.snapshot_id, Int64(200))
    assert_equal(o.posts, 1)
    var md = h.meta()
    assert_equal(_main_id(md), Int64(777))
    assert_equal(md.snapshot_index(200), -1)
    assert_equal(len(md.snapshots), 2)
    assert_equal(h.applied(), 1)
    assert_equal(len(o.manifest_lists_to_delete), 0)


def test_rewritten_snapshot_found_after_a_retry_keeps_its_manifest_list() raises:
    var h = _h()
    h.fault(500, False)
    h.fault_with(CommitFault(500, apply_first=True, rewrite_snapshot_id=777))
    var o = h.run()
    _committed(o, 777, _ml(200, 1))
    assert_equal(o.posts, 2)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))


def test_200_without_snapshot_or_commit_id_fails_state_unknown() raises:
    var h = _h()
    var stale = (
        String('{"metadata-location":"s3://wh/db/t/metadata/v2.metadata.json",')
        + String('"metadata":')
        + h.cat.transport_ref().inner.metadata_json(String("db"), String("t"))
        + String("}")
    )
    h.cat.transport_ref().stale_commit_body = stale^
    var o = h.run()
    _no_deletion(o)
    assert_equal(o.posts, 1)
    assert_equal(
        o.message,
        _unknown_message(
            _u(2),
            _ml(200, 0),
            String(
                "the catalog answered 200, and its metadata has neither the"
                " snapshot nor the commit id in main's history"
            ),
        ),
    )
    assert_equal(h.applied(), 0)
    assert_equal(len(h.clock.waits), 0)


# =============================================================================
# main moved.
# =============================================================================


def test_main_moved_and_snapshot_expired_fails_state_unknown_exactly() raises:
    var h = _h()
    var other = h.other_writer_body(200, 2, 900)
    h.fault_with(
        CommitFault(500, apply_first=True, then_body=other^, then_expire=200)
    )
    var o = h.run()
    assert_false(o.committed)
    assert_false(o.delete_statement_files)
    assert_equal(len(o.manifest_lists_to_delete), 0)
    assert_equal(
        o.message,
        String(
            "ICEBERG_COMMIT_STATE_UNKNOWN: commit to 'db.t' may or may not"
            " have landed: snapshot 200, commit id "
        )
        + _u(2)
        + String(", manifest list ml-200-0: ")
        + String(_E500)
        + String("; main moved from 100 to 900"),
    )
    # No second append: one POST, one manifest list, nothing else applied.
    assert_equal(o.posts, 1)
    assert_equal(len(h.posts()), 1)
    assert_equal(len(h.writer.attempts), 1)
    assert_equal(h.applied(), 2)
    assert_equal(_main_id(h.meta()), Int64(900))
    assert_equal(o.snapshot_id, Int64(200))
    assert_equal(o.commit_id, _u(2))


def test_main_moved_by_another_writer_without_apply_fails_state_unknown() raises:
    var h = _h()
    var other = h.other_writer_body(100, 1, 900)
    h.fault_with(CommitFault(500, apply_first=False, then_body=other^))
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message,
        _unknown_message(
            _u(2),
            _ml(200, 0),
            String(_E500) + String("; main moved from 100 to 900"),
        ),
    )
    assert_equal(o.posts, 1)
    assert_equal(h.applied(), 1)


def test_main_moved_past_the_landed_commit_is_still_found() raises:
    var h = _h()
    var other = h.other_writer_body(200, 2, 900)
    h.fault_with(CommitFault(500, apply_first=True, then_body=other^))
    var o = h.run()
    _committed(o, 200, _ml(200, 0))
    assert_equal(_main_id(h.meta()), Int64(900))
    assert_equal(h.applied(), 2)
    assert_equal(o.posts, 1)


# =============================================================================
# an unknown outcome, then 409 or 403.
# =============================================================================


def test_unknown_outcome_then_409_finds_the_landed_commit() raises:
    var h = _h()
    h.fault(500, False)
    h.fault(409, True)
    var o = h.run()
    _committed(o, 200, _ml(200, 1))
    assert_equal(o.posts, 2)
    assert_equal(h.applied(), 1)
    assert_equal(len(h.meta().snapshots), 2)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))
    _ints(h.clock.waits, _i1(100))


def test_unknown_outcome_then_a_409_that_changed_nothing_retries() raises:
    var h = _h()
    h.fault(500, False)
    h.fault(409, False)
    var o = h.run()
    _committed(o, 200, _ml(200, 2))
    assert_equal(o.posts, 3)
    _strs(o.manifest_lists_to_delete, _l2(_ml(200, 0), _ml(200, 1)))
    _ints(h.clock.waits, _i2(100, 200))
    assert_equal(h.applied(), 1)


def test_unknown_outcome_then_409_with_main_moved_fails_without_rebasing() raises:
    # The retry after a 500 gets a 409 because another writer moved main.
    # The lookup finds neither S nor C, but the first attempt may have landed
    # and been expired, so the statement must not rebase onto the new main.
    var h = _h()
    h.fault(500, False)
    var other = h.other_writer_body(100, 1, 900)
    h.fault_with(CommitFault(409, apply_first=False, then_body=other^))
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message,
        _unknown_message(
            _u(2),
            _ml(200, 1),
            String("the catalog answered 409; main moved from 100 to 900"),
        ),
    )
    assert_equal(o.posts, 2)
    assert_equal(h.applied(), 1)
    _ints(h.clock.waits, _i1(100))


def test_unknown_outcome_then_403_finds_the_landed_commit() raises:
    var h = _h()
    h.fault(500, False)
    h.fault(403, True)
    var o = h.run()
    _committed(o, 200, _ml(200, 1))
    assert_equal(o.posts, 2)
    assert_equal(h.applied(), 1)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))


def test_unknown_outcome_then_403_with_main_at_p_fails_and_allows_deletion() raises:
    var h = _h()
    h.fault(500, False)
    h.fault(403, False)
    var o = h.run()
    assert_false(o.committed)
    assert_equal(o.message, String(_E403))
    assert_true(o.delete_statement_files)
    _strs(o.manifest_lists_to_delete, _l2(_ml(200, 0), _ml(200, 1)))
    assert_equal(o.posts, 2)
    assert_equal(h.applied(), 0)


def test_unknown_outcome_then_403_with_main_moved_fails_without_deletion() raises:
    var h = _h()
    var other = h.other_writer_body(100, 1, 900)
    h.fault(500, False)
    h.fault_with(CommitFault(403, apply_first=False, then_body=other^))
    var o = h.run()
    _no_deletion(o)
    assert_equal(o.message, String(_E403))
    assert_equal(o.posts, 2)


# =============================================================================
# a statement that read its target.
# =============================================================================


def test_tainted_statement_that_read_its_target_fails_state_unknown_on_409() raises:
    var h = _h()
    h.fault(500, False)
    h.fault(409, False)
    var o = h.run_pinned(_i1(100))
    _no_deletion(o)
    assert_equal(
        o.message,
        _unknown_message(
            _u(2),
            _ml(200, 1),
            String(
                "the statement read the table at snapshot 100, and main is"
                " now 100"
            ),
        ),
    )
    assert_equal(o.posts, 2)
    assert_equal(h.applied(), 0)


def test_untainted_statement_that_read_its_target_fails_conflict_on_409() raises:
    var h = _h()
    h.fault(409, False)
    var o = h.run_pinned(_i2(100, 99))
    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_COMMIT_CONFLICT: commit to 'db.t': the statement read"
            " the table at snapshot 100, 99, and main is now 100"
        ),
    )
    assert_true(o.delete_statement_files)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))
    assert_equal(o.posts, 1)
    assert_equal(len(h.clock.waits), 0)


# =============================================================================
# a refused answer on an untainted statement.
# =============================================================================


def test_400_on_untainted_statement_fails_with_token_and_allows_deletion() raises:
    var h = _h()
    h.fault(400, False)
    var o = h.run()
    assert_false(o.committed)
    assert_equal(o.message, String(_E400))
    assert_true(o.delete_statement_files)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))
    assert_equal(o.posts, 1)
    assert_equal(len(h.clock.waits), 0)
    assert_equal(h.applied(), 0)
    assert_equal(o.snapshot_id, Int64(200))
    assert_equal(o.commit_id, _u(2))


# =============================================================================
# idempotency keys.
# =============================================================================


def test_idempotency_key_is_sent_when_the_catalog_advertises_it() raises:
    var h = _hi()
    var o = h.run()
    _committed(o, 200, _ml(200, 0))
    assert_equal(o.commit_id, _u(3))
    var p = h.posts()
    assert_equal(len(p), 1)
    assert_equal(h.key(p[0]), _u(4))
    # The first statement's commit carried an earlier key.
    assert_equal(h.key(h.start - 1), _u(2))


def test_no_idempotency_key_is_sent_without_an_advertised_lifetime() raises:
    var h = _h()
    var o = h.run()
    _committed(o, 200, _ml(200, 0))
    var p = h.posts()
    assert_equal(len(p), 1)
    assert_equal(h.key(p[0]), String(""))
    assert_equal(o.commit_id, _u(2))


def test_unknown_outcome_resends_identical_body_and_catalog_replays_stored_200() raises:
    var h = _hi()
    h.fault(500, True)
    var o = h.run()
    _committed(o, 200, _ml(200, 0))
    assert_equal(o.posts, 2)
    var p = h.posts()
    assert_equal(len(p), 2)
    assert_equal(h.body(p[0]), h.body(p[1]))
    assert_equal(h.key(p[0]), _u(4))
    assert_equal(h.key(p[1]), _u(4))
    # Replayed, not applied again; no reload was needed (the base load and
    # the two POSTs are the only requests).
    assert_equal(h.applied(), 1)
    assert_equal(len(h.meta().snapshots), 2)
    assert_equal(h.requests(), 3)
    assert_equal(len(h.writer.attempts), 1)
    _ints(h.clock.waits, _i1(100))


def test_resend_of_a_commit_that_was_not_applied_lands_once_under_same_key() raises:
    var h = _hi()
    h.fault(500, False)
    var o = h.run()
    _committed(o, 200, _ml(200, 0))
    assert_equal(o.posts, 2)
    var p = h.posts()
    assert_equal(h.body(p[0]), h.body(p[1]))
    assert_equal(h.key(p[0]), h.key(p[1]))
    assert_equal(h.applied(), 1)
    assert_equal(len(h.meta().snapshots), 2)


def test_resend_that_is_unknown_again_runs_the_lookup_and_retries_with_new_key() raises:
    var h = _hi()
    h.fault(500, False)
    h.fault(502, False)
    var o = h.run()
    _committed(o, 200, _ml(200, 1))
    assert_equal(o.posts, 3)
    var p = h.posts()
    assert_equal(len(p), 3)
    assert_equal(h.body(p[0]), h.body(p[1]))
    assert_true(h.body(p[1]) != h.body(p[2]))
    assert_equal(h.key(p[0]), _u(4))
    assert_equal(h.key(p[1]), _u(4))
    assert_equal(h.key(p[2]), _u(5))
    _ints(h.clock.waits, _i2(100, 200))
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))


def test_retry_after_409_carries_a_new_key() raises:
    var h = _hi()
    h.fault(409, False)
    var o = h.run()
    _committed(o, 200, _ml(200, 1))
    var p = h.posts()
    assert_equal(len(p), 2)
    assert_equal(h.key(p[0]), _u(4))
    assert_equal(h.key(p[1]), _u(5))
    assert_true(h.body(p[0]) != h.body(p[1]))


def test_resend_with_spent_budget_fails_state_unknown_without_resending() raises:
    var h = _hr(String("0"), True)
    h.fault(500, False)
    var o = h.run()
    _no_deletion(o)
    assert_equal(o.message, _unknown_message(_u(3), _ml(200, 0), String(_E500)))
    assert_equal(o.posts, 1)
    assert_equal(len(h.posts()), 1)
    assert_equal(len(h.clock.waits), 0)


def main() raises:
    test_500_after_apply_succeeds_without_second_snapshot()
    test_500_before_apply_retries_once_and_succeeds()
    test_502_after_apply_is_found_by_snapshot_id()
    test_502_before_apply_retries_once()
    test_503_after_apply_is_found_by_snapshot_id()
    test_503_before_apply_retries_once()
    test_504_after_apply_is_found_by_snapshot_id()
    test_504_before_apply_retries_once()
    test_dropped_connection_after_apply_is_found_by_snapshot_id()
    test_dropped_connection_before_apply_retries_once()
    test_rewritten_snapshot_id_is_found_by_commit_id()
    test_rewritten_snapshot_found_after_a_retry_keeps_its_manifest_list()
    test_200_without_snapshot_or_commit_id_fails_state_unknown()
    test_main_moved_and_snapshot_expired_fails_state_unknown_exactly()
    test_main_moved_by_another_writer_without_apply_fails_state_unknown()
    test_main_moved_past_the_landed_commit_is_still_found()
    test_unknown_outcome_then_409_finds_the_landed_commit()
    test_unknown_outcome_then_a_409_that_changed_nothing_retries()
    test_unknown_outcome_then_409_with_main_moved_fails_without_rebasing()
    test_unknown_outcome_then_403_finds_the_landed_commit()
    test_unknown_outcome_then_403_with_main_at_p_fails_and_allows_deletion()
    test_unknown_outcome_then_403_with_main_moved_fails_without_deletion()
    test_tainted_statement_that_read_its_target_fails_state_unknown_on_409()
    test_untainted_statement_that_read_its_target_fails_conflict_on_409()
    test_400_on_untainted_statement_fails_with_token_and_allows_deletion()
    test_idempotency_key_is_sent_when_the_catalog_advertises_it()
    test_no_idempotency_key_is_sent_without_an_advertised_lifetime()
    test_unknown_outcome_resends_identical_body_and_catalog_replays_stored_200()
    test_resend_of_a_commit_that_was_not_applied_lands_once_under_same_key()
    test_resend_that_is_unknown_again_runs_the_lookup_and_retries_with_new_key()
    test_retry_after_409_carries_a_new_key()
    test_resend_with_spent_budget_fails_state_unknown_without_resending()
    print("test_iceberg_commit_unknown: ALL PASS")
