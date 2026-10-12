# =============================================================================
# komira_crm/store.mojo -- `CrmStore[DB]`: the CRM's rows on any komira_db
#   `Database`.
# =============================================================================
#
# The store owns the database and is generic over the backend-neutral
# `Database` trait: it uses only the transaction verbs and the structured
# operations, so the same code runs on SQLite and on Firestore. Each method
# is the function of the same name in accounts.mojo, pipelines.mojo,
# deals.mojo, activities.mojo, fields.mojo or feed.mojo; core.mojo describes
# the write order and the feed counter they share.
#
# The store decides no permission: the caller has checked `read`, `write` or
# `admin` on the deployment before it calls. `owner` is a field to filter on.
# Every write that records who did it takes the `actor`, and every write that
# stamps a time takes `now`; times are kept to the microsecond.
#
# What a document backend gives (Firestore): a write that stops between its
# row and its key leaves a row no read returns (core.mojo). A stage change is
# not atomic there, and the change feed is not claimed there (feed.mojo).
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database
from komira_wkt import Timestamp

from komira_crm_proto.crm import (
    Account,
    AccountContact,
    Activity,
    ChangesResponse,
    CustomFieldDef,
    Deal,
    EraseSubjectResponse,
    Pipeline,
    Principal,
)

from komira_crm.accounts import (
    create_account as _create_account,
    get_account as _get_account,
    list_accounts as _list_accounts,
    update_account as _update_account,
    link_contact as _link_contact,
    unlink_contact as _unlink_contact,
    list_contacts as _list_contacts,
)
from komira_crm.activities import (
    create_activity as _create_activity,
    get_activity as _get_activity,
    list_activities as _list_activities,
    update_activity as _update_activity,
)
from komira_crm.deals import (
    create_deal as _create_deal,
    get_deal as _get_deal,
    list_deals as _list_deals,
    update_deal as _update_deal,
)
from komira_crm.feed import (
    changes as _changes,
    erase_subject as _erase_subject,
)
from komira_crm.fields import (
    create_field_def as _create_field_def,
    get_field_def as _get_field_def,
    list_field_defs as _list_field_defs,
    update_field_def as _update_field_def,
)
from komira_crm.pipelines import (
    init_dataset as _init_dataset,
    create_pipeline as _create_pipeline,
    get_pipeline as _get_pipeline,
    list_pipelines as _list_pipelines,
    update_pipeline as _update_pipeline,
)


struct CrmStore[DB: Database](Movable):
    """The CRM's accounts, pipelines, deals, activities, custom fields, change
    feed and erasure over one `Database` (see the module header)."""

    var _db: Self.DB

    def __init__(out self, var db: Self.DB):
        self._db = db^

    def database(ref self) -> ref [self._db] Self.DB:
        """Borrow the underlying database."""
        return self._db

    def init_dataset[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises -> Bool:
        """Create the feed counter and the default pipeline, once."""
        return _init_dataset[Self.DB, RT](self._db, reactor)

    # ---- accounts -----------------------------------------------------------

    def create_account[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], account: Account, now: Timestamp) raises -> Account:
        return _create_account[Self.DB, RT](self._db, reactor, account, now)

    def get_account[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], id: String) raises -> Account:
        return _get_account[Self.DB, RT](self._db, reactor, id)

    def list_accounts[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], include_archived: Bool) raises -> List[Account]:
        return _list_accounts[Self.DB, RT](self._db, reactor, include_archived)

    def update_account[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        id: String,
        expected_version: UInt64,
        account: Account,
        now: Timestamp,
    ) raises -> Account:
        return _update_account[Self.DB, RT](self._db, reactor, id, expected_version, account, now)

    def link_contact[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], account_id: String, card_id: String, role: String) raises -> AccountContact:
        return _link_contact[Self.DB, RT](self._db, reactor, account_id, card_id, role)

    def unlink_contact[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], account_id: String, card_id: String) raises -> Bool:
        return _unlink_contact[Self.DB, RT](self._db, reactor, account_id, card_id)

    def list_contacts[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], account_id: String) raises -> List[AccountContact]:
        return _list_contacts[Self.DB, RT](self._db, reactor, account_id)

    # ---- pipelines ----------------------------------------------------------

    def create_pipeline[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], pipeline: Pipeline) raises -> Pipeline:
        return _create_pipeline[Self.DB, RT](self._db, reactor, pipeline)

    def get_pipeline[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], id: String) raises -> Pipeline:
        return _get_pipeline[Self.DB, RT](self._db, reactor, id)

    def list_pipelines[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises -> List[Pipeline]:
        return _list_pipelines[Self.DB, RT](self._db, reactor)

    def update_pipeline[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], id: String, expected_version: UInt64, pipeline: Pipeline) raises -> Pipeline:
        return _update_pipeline[Self.DB, RT](self._db, reactor, id, expected_version, pipeline)

    # ---- deals --------------------------------------------------------------

    def create_deal[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], deal: Deal, now: Timestamp) raises -> Deal:
        return _create_deal[Self.DB, RT](self._db, reactor, deal, now)

    def get_deal[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], id: String) raises -> Deal:
        return _get_deal[Self.DB, RT](self._db, reactor, id)

    def list_deals[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], pipeline_id: String, include_archived: Bool) raises -> List[Deal]:
        return _list_deals[Self.DB, RT](self._db, reactor, pipeline_id, include_archived)

    def update_deal[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        actor: Principal,
        id: String,
        expected_version: UInt64,
        deal: Deal,
        now: Timestamp,
    ) raises -> Deal:
        return _update_deal[Self.DB, RT](self._db, reactor, actor, id, expected_version, deal, now)

    # ---- activities ---------------------------------------------------------

    def create_activity[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], actor: Principal, activity: Activity, now: Timestamp) raises -> Activity:
        return _create_activity[Self.DB, RT](self._db, reactor, actor, activity, now)

    def get_activity[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], id: String) raises -> Activity:
        return _get_activity[Self.DB, RT](self._db, reactor, id)

    def list_activities[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], subject_kind: Int, subject_id: String) raises -> List[Activity]:
        return _list_activities[Self.DB, RT](self._db, reactor, subject_kind, subject_id)

    def update_activity[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], id: String, expected_version: UInt64, activity: Activity) raises -> Activity:
        return _update_activity[Self.DB, RT](self._db, reactor, id, expected_version, activity)

    # ---- custom fields ------------------------------------------------------

    def create_field_def[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], field: CustomFieldDef) raises -> CustomFieldDef:
        return _create_field_def[Self.DB, RT](self._db, reactor, field)

    def get_field_def[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], id: String) raises -> CustomFieldDef:
        return _get_field_def[Self.DB, RT](self._db, reactor, id)

    def list_field_defs[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], entity_kind: Int) raises -> List[CustomFieldDef]:
        return _list_field_defs[Self.DB, RT](self._db, reactor, entity_kind)

    def update_field_def[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], id: String, expected_version: UInt64, field: CustomFieldDef
    ) raises -> CustomFieldDef:
        return _update_field_def[Self.DB, RT](self._db, reactor, id, expected_version, field)

    # ---- the feed and erasure -----------------------------------------------

    def changes[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink], since: UInt64, limit: Int) raises -> ChangesResponse:
        return _changes[Self.DB, RT](self._db, reactor, since, limit)

    def erase_subject[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], issuer: String, subject: String) raises -> EraseSubjectResponse:
        return _erase_subject[Self.DB, RT](self._db, reactor, issuer, subject)
