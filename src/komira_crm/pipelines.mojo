# =============================================================================
# komira_crm/pipelines.mojo -- pipelines and the dataset's first pipeline.
# =============================================================================
#
# A pipeline is one row; its stages are one JSON column, so the store checks
# that their keys are unique (validate.mojo) when a pipeline is written.
# No key table guards a pipeline. `init_dataset` creates the feed counter
# row and, the first time only, the default pipeline of six stages.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbValue, Filter, Order, generate_uuidv7

from komira_crm_proto.crm import Pipeline, Stage, StageKind

from komira_crm.core import cas, load, next_modseq, no_limit, order_of, row_updates
from komira_crm.errors import invalid, not_found
from komira_crm.rows import int8, pipeline_from_row, pipeline_row, text
from komira_crm.schema import FEED, FEED_ROW_ID, PIPELINES, feed_cols, pipeline_cols, strs
from komira_crm.validate import check_pipeline


def _stage(key: StaticString, label: StaticString, kind: Int) -> Stage:
    return Stage(key=String(key), label=String(label), kind=StageKind(kind))


def default_pipeline() -> Pipeline:
    """The pipeline a new dataset starts with."""
    var stages = List[Stage]()
    stages.append(_stage("qualification", "Qualification", StageKind.OPEN))
    stages.append(_stage("discovery", "Discovery", StageKind.OPEN))
    stages.append(_stage("proposal", "Proposal", StageKind.OPEN))
    stages.append(_stage("negotiation", "Negotiation", StageKind.OPEN))
    stages.append(_stage("closed_won", "Closed won", StageKind.WON))
    stages.append(_stage("closed_lost", "Closed lost", StageKind.LOST))
    return Pipeline(id=String(), name=String("Sales"), stages=stages^, version=UInt64(0), modseq=UInt64(0))


def init_dataset[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink]) raises -> Bool:
    """Create the feed counter and the default pipeline, once. True when this
    call created them, False when the dataset already existed."""
    db.begin[RT](reactor)
    try:
        var vals = List[DbValue]()
        vals.append(text(String(FEED_ROW_ID)))
        vals.append(int8(UInt64(0)))
        var won = db.create_if_absent[RT](
            reactor, String(FEED), String("id"), text(String(FEED_ROW_ID)), feed_cols(), vals^
        )
        if won:
            var p = default_pipeline()
            p.id = generate_uuidv7().to_hyphenated()
            p.version = UInt64(1)
            p.modseq = next_modseq[DB, RT](db, reactor)
            _ = db.put[RT](reactor, String(PIPELINES), pipeline_cols(), pipeline_row(p))
        db.commit[RT](reactor)
        return won
    except e:
        db.rollback[RT](reactor)
        raise e^


def create_pipeline[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], pipeline: Pipeline) raises -> Pipeline:
    check_pipeline(pipeline)
    var p = pipeline.copy()
    p.id = generate_uuidv7().to_hyphenated()
    p.version = UInt64(1)
    db.begin[RT](reactor)
    try:
        p.modseq = next_modseq[DB, RT](db, reactor)
        _ = db.put[RT](reactor, String(PIPELINES), pipeline_cols(), pipeline_row(p))
        db.commit[RT](reactor)
        return p^
    except e:
        db.rollback[RT](reactor)
        raise e^


def get_pipeline[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink], id: String) raises -> Pipeline:
    var got = load[DB, RT](db, reactor, PIPELINES, pipeline_cols(), id)
    if not got:
        raise not_found()
    return pipeline_from_row(got.take())


def list_pipelines[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink]) raises -> List[Pipeline]:
    """Every pipeline, by name, then id."""
    var rows = db.query_rows[RT](reactor, String(PIPELINES), pipeline_cols(), Filter.none(), List[Order](), no_limit())
    var all = List[Pipeline]()
    var keys = List[String]()
    for i in range(rows.__len__()):
        var p = pipeline_from_row(rows.row(i))
        keys.append(p.name + String("\x00") + p.id)
        all.append(p^)
    var out = List[Pipeline]()
    for i in order_of(keys):
        out.append(all[i].copy())
    return out^


def update_pipeline[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], id: String, expected_version: UInt64, pipeline: Pipeline) raises -> Pipeline:
    """Replace a pipeline's name and stages if its version is still
    `expected_version`. A deal keeps its stage key when its stage is removed;
    its next update must name a stage the pipeline has."""
    check_pipeline(pipeline)
    db.begin[RT](reactor)
    try:
        _ = get_pipeline[DB, RT](db, reactor, id)
        var p = pipeline.copy()
        p.id = String(id)
        p.version = expected_version + 1
        p.modseq = next_modseq[DB, RT](db, reactor)
        cas[DB, RT](db, reactor, PIPELINES, id, expected_version, row_updates(pipeline_cols(), pipeline_row(p), strs()))
        db.commit[RT](reactor)
        return p^
    except e:
        db.rollback[RT](reactor)
        raise e^


def check_stage[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], pipeline_id: String, stage_key: String) raises:
    """The pipeline exists and has a stage `stage_key`."""
    var got = load[DB, RT](db, reactor, PIPELINES, pipeline_cols(), pipeline_id)
    if not got:
        raise invalid("pipelineId", "no such pipeline")
    var p = pipeline_from_row(got.take())
    for s in p.stages:
        if s.key == stage_key:
            return
    raise invalid("stageKey", "not a stage of the pipeline")
