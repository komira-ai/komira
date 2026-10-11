# =============================================================================
# komira_crm -- the rows of a simple CRM: accounts, pipelines, deals,
#   activities and custom fields, with one change feed and erasure.
# =============================================================================
#
#   store.mojo       CrmStore[DB]: every operation, over any komira_db
#                    `Database`
#   core.mojo        the write order, the feed counter and key tables
#   accounts.mojo    accounts and the cards linked to them
#   pipelines.mojo   pipelines and the dataset's default pipeline
#   deals.mojo       deals, and the activity a stage change writes
#   activities.mojo  activities
#   fields.mojo      custom-field definitions and value checks
#   feed.mojo        the change feed and erasure
#   validate.mojo    what a client may write
#   money.mojo       ISO 4217 codes and exact amounts
#   rows.mojo        the messages as rows
#   schema.mojo      the tables and the SQLite DDL
#   errors.mojo      the refusal texts
# =============================================================================

from .errors import (
    ERR_EXTERNAL_ID_TAKEN,
    ERR_FIELD_KEY_TAKEN,
    ERR_FRACTIONAL_AMOUNT,
    ERR_INVALID,
    ERR_NOT_FOUND,
    ERR_NOT_INITIALIZED,
    ERR_SYSTEM_ACTIVITY,
    ERR_UNKNOWN_CURRENCY,
    ERR_VERSION_CONFLICT,
)
from .money import CURRENCY_COUNT, check_currency, check_money, minor_unit_digits, parse_amount
from .pipelines import default_pipeline
from .schema import (
    ACCOUNTS,
    ACCOUNT_CONTACTS,
    ACTIVITIES,
    DEALS,
    EXTERNAL_IDS,
    FEED,
    FIELD_DEFS,
    FIELD_KEYS,
    PIPELINES,
    sqlite_schema,
)
from .store import CrmStore
from .validate import (
    check_account,
    check_activity,
    check_custom_field_def,
    check_date,
    check_deal,
    check_field_value,
    check_key,
    check_pipeline,
    check_principal,
)
