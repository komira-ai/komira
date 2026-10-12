# `komira_crm`

## Responsibility

The rows of a simple CRM, stored on any `komira_db` `Database`. The messages
are
[`komira_crm_proto`](https://github.com/komira-ai/komira/blob/main/src/komira_crm_proto/README.md)'s.
People and companies are contacts cards; a CRM row names a card by its id.

- `CrmStore[DB]`: accounts and the cards linked to them, pipelines, deals,
  activities, custom-field definitions, one change feed for the dataset and
  the erasure of a principal. It uses only the backend-neutral `Database`
  operations, so the same store runs on SQLite and on Firestore. It decides
  no permission: the caller has checked the deployment's `read`, `write` or
  `admin` action first, and `owner` is a field to filter on.
- One deployment holds one dataset: no table has a column scoping a row to a
  customer.
- Every update is a compare-and-set on the row's `version`: of two updates
  naming one version, one succeeds and the other is refused with
  `crm: version conflict`.
- An `externalId` is unique per entity kind (an account and a deal may carry
  the same one) and never changes. A custom-field key is unique per entity
  kind. Each rule is a key table whose primary key is the unique tuple; the
  row is written first, then its key, and every read skips a row its key
  does not name, so a create that stopped between the two is never read.
  Several accounts may name one org card.
- A stage change writes the deal and a `STAGE_CHANGED` system activity in
  one transaction; a system activity refuses every update.
- Every write takes its own number from one feed counter. `changes(since,
  limit)` returns the rows written after `since`, lowest first; its cursor is
  the highest number returned. The feed, and the stage change's atomicity,
  are claimed on backends whose transactions commit a write's operations
  together (SQLite), not on Firestore.
- `erase_subject(issuer, subject)`: the accounts and deals the principal
  owns become unowned and the activities it wrote get the actor
  `("", "erased")`, each a write with a new version and feed number; a
  second call rewrites nothing. The owner and the actor are kept only in
  their columns, never in a row's JSON body.
- `parse_amount`, `check_currency`, `check_money`: amounts are integer
  counts of the currency's minor unit; the ISO 4217 codes with a minor unit
  are carried, with their digits.
- `check_*` in validate.mojo: what a client may write.
- `sqlite_schema()`: the SQLite tables. No query needs a composite index on
  a document backend.

Postgres is not tested. The CRM book of contacts cards (the book whose cards
would share the CRM's feed) is not part of this package.

The store's contract is checked against SQLite and Firestore (over
`MockFirestore`) by
[`komira_crm_store_conformance`](https://github.com/komira-ai/komira/blob/main/src/tests/conformance/komira_crm_store_conformance/BUCK).

## API

| name | file | what it is |
|---|---|---|
| `CrmStore` | [store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_crm/store.mojo) | the store over a `Database` |
| `parse_amount`, `check_currency`, `check_money`, `minor_unit_digits`, `CURRENCY_COUNT` | [money.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_crm/money.mojo) | ISO 4217 codes and exact amounts |
| `check_account`, `check_deal`, `check_activity`, `check_pipeline`, `check_custom_field_def`, `check_field_value`, `check_date`, `check_key`, `check_principal` | [validate.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_crm/validate.mojo) | what a client may write |
| `default_pipeline` | [pipelines.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_crm/pipelines.mojo) | the six stages a dataset starts with |
| `sqlite_schema`, `ACCOUNTS`, `ACCOUNT_CONTACTS`, `PIPELINES`, `DEALS`, `ACTIVITIES`, `EXTERNAL_IDS`, `FIELD_DEFS`, `FIELD_KEYS`, `FEED` | [schema.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_crm/schema.mojo) | the tables |
| `ERR_NOT_FOUND`, `ERR_VERSION_CONFLICT`, `ERR_EXTERNAL_ID_TAKEN`, `ERR_FIELD_KEY_TAKEN`, `ERR_SYSTEM_ACTIVITY`, `ERR_NOT_INITIALIZED`, `ERR_INVALID`, `ERR_FRACTIONAL_AMOUNT`, `ERR_UNKNOWN_CURRENCY` | [errors.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_crm/errors.mojo) | the refusal texts |

## Example

Every example below runs as a test when the package is built.

An amount in major units becomes a count of the currency's minor unit, and
a value that is not a whole number of minor units is refused:

```mojo
from komira_crm import ERR_FRACTIONAL_AMOUNT, ERR_UNKNOWN_CURRENCY, parse_amount
from std.testing import assert_equal

assert_equal(parse_amount("1250.50", "EUR"), Int64(125050))
assert_equal(parse_amount("1250", "JPY"), Int64(1250))
assert_equal(parse_amount("0.125", "BHD"), Int64(125))

var refusal = String()
try:
    _ = parse_amount("12.345", "USD")
except e:
    refusal = String(e)
assert_equal(refusal, ERR_FRACTIONAL_AMOUNT)

try:
    _ = parse_amount("10", "XAU")
except e:
    refusal = String(e)
assert_equal(refusal, ERR_UNKNOWN_CURRENCY)
```

A new dataset starts with one pipeline of six stages:

```mojo
from komira_crm import default_pipeline
from std.testing import assert_equal

var p = default_pipeline()
assert_equal(len(p.stages), 6)
assert_equal(p.stages[0].key, "qualification")
assert_equal(p.stages[5].key, "closed_lost")
```
