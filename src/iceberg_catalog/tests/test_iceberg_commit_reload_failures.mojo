# =============================================================================
# test_iceberg_commit_reload_failures.mojo — `commit_append` when its reloads fail, when
#   its retry budget is spent, and when its ids, writer or endpoint list stop
#   it, by exact message. Same doubles as test_iceberg_commit_unknown.mojo:
#   InMemoryIcebergRestCatalog behind a wrapper that can fail loads,
#   ManualCommitClock (every wait is asserted) and SequenceCommitIds.
# =============================================================================
#
# Each case holds one behaviour:
#   * Reloads that answer 503 until the budget is spent end an unknown outcome
#     with ICEBERG_COMMIT_STATE_UNKNOWN naming the load error; 503s followed by
#     a 200 let the retry go on; another load error is not retried; a base
#     load that fails ends the statement before any snapshot is drawn.
#   * A spent budget ends an unknown outcome (without an idempotency
#     key) with STATE_UNKNOWN, an untainted 409 with ICEBERG_COMMIT_CONFLICT
#     and a tainted 409 with STATE_UNKNOWN.
#   * A malformed retry property, a snapshot id the table already has (drawn
#     again, or never free), a writer that raises and an endpoint list
#     without the commit route each end the statement with their message.
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
# reloads that keep failing.
# =============================================================================


def test_reloads_that_keep_failing_exhaust_the_budget_state_unknown() raises:
    var h = _h()
    h.fault(500, False)
    h.fail_loads(1, 100, 503)
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message, _unknown_message(_u(2), _ml(200, 0), String(_E503_LOAD))
    )
    _ints(h.clock.waits, _i4(100, 200, 400, 800))
    assert_equal(h.loads(), 5)
    assert_equal(o.posts, 1)


def test_reload_answering_503_twice_then_200_retries_the_attempt() raises:
    var h = _h()
    h.fault(500, False)
    h.fail_loads(1, 2, 503)
    var o = h.run()
    _committed(o, 200, _ml(200, 1))
    _ints(h.clock.waits, _i3(100, 200, 400))
    assert_equal(o.posts, 2)


def test_reload_failing_with_another_error_is_not_retried() raises:
    var h = _h()
    h.fault(500, False)
    h.fail_loads(1, 1, 404)
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message, _unknown_message(_u(2), _ml(200, 0), String(_E404_LOAD))
    )
    _ints(h.clock.waits, _i1(100))


def test_base_load_failing_fails_without_a_snapshot_and_allows_deletion() raises:
    var h = _h()
    h.fail_loads(0, 1, 404)
    var o = h.run()
    assert_false(o.committed)
    assert_equal(o.message, String(_E404_LOAD))
    assert_true(o.delete_statement_files)
    assert_equal(len(o.manifest_lists_to_delete), 0)
    assert_equal(o.snapshot_id, Int64(0))
    assert_equal(o.commit_id, String(""))
    assert_equal(o.posts, 0)
    assert_equal(len(h.writer.attempts), 0)


def test_reload_after_409_failing_on_untainted_statement_fails_with_load_error() raises:
    var h = _h()
    h.fault(409, False)
    h.fail_loads(1, 100, 503)
    var o = h.run()
    assert_false(o.committed)
    assert_equal(o.message, String(_E503_LOAD))
    assert_true(o.delete_statement_files)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))
    _ints(h.clock.waits, _i4(100, 200, 400, 800))


def test_reload_after_409_failing_on_tainted_statement_fails_state_unknown() raises:
    var h = _h()
    h.fault(500, False)
    h.fault(409, False)
    h.fail_loads(2, 100, 503)
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message, _unknown_message(_u(2), _ml(200, 1), String(_E503_LOAD))
    )
    _ints(h.clock.waits, _i4(100, 200, 400, 800))


def test_reload_after_refusal_failing_on_tainted_statement_fails_state_unknown() raises:
    var h = _h()
    h.fault(500, False)
    h.fault(403, False)
    h.fail_loads(2, 100, 503)
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message, _unknown_message(_u(2), _ml(200, 1), String(_E503_LOAD))
    )


# =============================================================================
# the retry budget, ids, the writer and the endpoint.
# =============================================================================


def test_unknown_outcome_with_spent_budget_fails_state_unknown() raises:
    var h = _hr(String("0"))
    h.fault(500, False)
    var o = h.run()
    _no_deletion(o)
    assert_equal(o.message, _unknown_message(_u(2), _ml(200, 0), String(_E500)))
    assert_equal(o.posts, 1)
    assert_equal(len(h.clock.waits), 0)
    # The base load and the one POST: no reload after the spent budget.
    assert_equal(h.requests(), 2)


def test_409_with_spent_budget_fails_conflict_and_allows_deletion() raises:
    var h = _hr(String("0"))
    h.fault(409, False)
    var o = h.run()
    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_COMMIT_CONFLICT: commit to 'db.t': the table changed"
            " under each of 1 attempts and the retry budget is spent; main"
            " is now 100"
        ),
    )
    assert_true(o.delete_statement_files)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))


def test_tainted_409_with_spent_budget_fails_state_unknown() raises:
    var h = _hr(String("1"))
    h.fault(500, False)
    h.fault(409, False)
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message,
        _unknown_message(
            _u(2),
            _ml(200, 1),
            String(
                "the table changed under each of 2 attempts and the retry"
                " budget is spent; main is now 100"
            ),
        ),
    )
    _ints(h.clock.waits, _i1(100))


def test_bad_retry_property_fails_before_any_commit() raises:
    var h = _harness(False, String("abc"), False, False, _ids(200, 201))
    var o = h.run()
    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: table property"
            " 'commit.retry.num-retries' is not a non-negative integer: 'abc'"
        ),
    )
    assert_true(o.delete_statement_files)
    assert_equal(o.posts, 0)


def test_snapshot_id_already_in_the_table_is_drawn_again() raises:
    var h = _harness(False, String(""), True, False, SequenceCommitIds(_i3(100, 100, 200)))
    var o = h.run()
    _committed(o, 200, _ml(200, 0))
    assert_equal(o.snapshot_id, Int64(200))


def test_no_unused_snapshot_id_fails_conflict() raises:
    var l = List[Int64]()
    for _ in range(65):
        l.append(100)
    var h = _harness(False, String(""), True, False, SequenceCommitIds(l^))
    var o = h.run()
    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_COMMIT_CONFLICT: commit to 'db.t': no unused snapshot id"
            " after 64 draws"
        ),
    )
    assert_true(o.delete_statement_files)
    assert_equal(o.posts, 0)


def test_writer_failure_on_untainted_statement_fails_and_allows_deletion() raises:
    var h = _h()
    h.writer.fail_attempt = 0
    var o = h.run()
    assert_false(o.committed)
    assert_equal(o.message, String("writer: disk full"))
    assert_true(o.delete_statement_files)
    assert_equal(len(o.manifest_lists_to_delete), 0)
    assert_equal(o.posts, 0)


def test_writer_failure_on_tainted_statement_fails_state_unknown() raises:
    var h = _h()
    h.fault(500, False)
    h.writer.fail_attempt = 1
    var o = h.run()
    _no_deletion(o)
    assert_equal(
        o.message,
        _unknown_message(_u(2), _ml(200, 0), String("writer: disk full")),
    )
    assert_equal(o.posts, 1)


def test_endpoint_not_listed_fails_before_sending_and_allows_deletion() raises:
    var h = _harness(False, String(""), False, True, _ids(200, 201))
    var o = h.run()
    assert_false(o.committed)
    assert_equal(
        o.message,
        String("ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED: the catalog does not list '")
        + String(ENDPOINT_COMMIT_TABLE)
        + String("'"),
    )
    assert_true(o.delete_statement_files)
    _strs(o.manifest_lists_to_delete, _l(_ml(200, 0)))
    assert_equal(o.posts, 0)
    assert_equal(len(h.posts()), 0)
    _ints(h.writer.parents, _i1(-1))


def main() raises:
    test_reloads_that_keep_failing_exhaust_the_budget_state_unknown()
    test_reload_answering_503_twice_then_200_retries_the_attempt()
    test_reload_failing_with_another_error_is_not_retried()
    test_base_load_failing_fails_without_a_snapshot_and_allows_deletion()
    test_reload_after_409_failing_on_untainted_statement_fails_with_load_error()
    test_reload_after_409_failing_on_tainted_statement_fails_state_unknown()
    test_reload_after_refusal_failing_on_tainted_statement_fails_state_unknown()
    test_unknown_outcome_with_spent_budget_fails_state_unknown()
    test_409_with_spent_budget_fails_conflict_and_allows_deletion()
    test_tainted_409_with_spent_budget_fails_state_unknown()
    test_bad_retry_property_fails_before_any_commit()
    test_snapshot_id_already_in_the_table_is_drawn_again()
    test_no_unused_snapshot_id_fails_conflict()
    test_writer_failure_on_untainted_statement_fails_and_allows_deletion()
    test_writer_failure_on_tainted_statement_fails_state_unknown()
    test_endpoint_not_listed_fails_before_sending_and_allows_deletion()
    print("test_iceberg_commit_reload_failures: ALL PASS")
