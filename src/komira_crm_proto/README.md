# `komira_crm_proto`

## Responsibility

The resources of a simple CRM's JSON API, as protobuf messages
(`komira.crm.v1`) and the Mojo structs generated from them. The API is the
proto3 JSON mapping of these messages. People and companies are contacts
cards ([`komira_contacts_proto`](https://github.com/komira-ai/komira/blob/main/src/komira_contacts_proto/README.md));
a CRM row names a card by its id.

- `Account`: a company, backed by an `org` card (`orgCardId`; several
  accounts may name one card), with an owner, a status, an `externalId` set
  at create only, custom fields, a `version` ETag and the change feed's
  `modseq`.
- `AccountContact`: a card linked to an account, once per pair, with a role.
- `Pipeline` and `Stage`: an ordered list of stages, each OPEN, WON or LOST.
- `Deal`: a sale on a pipeline stage. `amountMinor` is an integer count of
  the currency's minor unit and `currency` an ISO 4217 code, so an amount is
  exact.
- `Activity`: a note, call, meeting or logged email on an account, a deal or
  a card. A `STAGE_CHANGED` activity is written by the service (`system`)
  and names the two stages.
- `CustomFieldDef`: a custom field of one entity kind, with a type; values
  are text in an entity's `customFields` map.
- `ChangesResponse` and `FeedEntry`: the rows written after a client's
  cursor, in feed order.
- `EraseSubjectResponse`: what an erasure of one principal rewrote.
- `ErrorResponse` and `ApiError`: the body of every refusal.
- Enums `Status`, `StageKind`, `ActivityKind`, `EntityKind` and
  `FieldType`.

The field numbers and JSON names are the contract:
`tests/test_crm_field_numbers.mojo` pins every number as wire bytes and
every JSON key in a literal document.
[`komira_crm`](https://github.com/komira-ai/komira/blob/main/src/komira_crm/README.md)
stores these messages.

## API

| name | file | what it is |
|---|---|---|
| `Account`, `AccountContact`, `Pipeline`, `Stage`, `Deal`, `Activity`, `CustomFieldDef`, `Principal` | [crm.proto](https://github.com/komira-ai/komira/blob/main/src/komira_crm_proto/komira/crm/v1/crm.proto) | the resources |
| `ListAccountsResponse`, `ListAccountContactsResponse`, `ListPipelinesResponse`, `ListDealsResponse`, `ListActivitiesResponse`, `ListCustomFieldDefsResponse` | [crm.proto](https://github.com/komira-ai/komira/blob/main/src/komira_crm_proto/komira/crm/v1/crm.proto) | list bodies |
| `ChangesResponse`, `FeedEntry`, `EraseSubjectResponse` | [crm.proto](https://github.com/komira-ai/komira/blob/main/src/komira_crm_proto/komira/crm/v1/crm.proto) | the change feed and the erasure summary |
| `ApiError`, `ErrorResponse` | [crm.proto](https://github.com/komira-ai/komira/blob/main/src/komira_crm_proto/komira/crm/v1/crm.proto) | the error envelope |
| `Status`, `StageKind`, `ActivityKind`, `EntityKind`, `FieldType` | [crm.proto](https://github.com/komira-ai/komira/blob/main/src/komira_crm_proto/komira/crm/v1/crm.proto) | the enums |

The Mojo module is `komira_crm_proto.crm`. Each message is a struct whose
constructor takes its fields in declaration order (a message field is an
`Optional`, a `repeated` field a `List`, a `map` a `Dict`), and conforms to
`komira_proto_codec`'s `Serializable`, so `encode_json` and `decode_json`
(and the binary pair) read and write it. The `Timestamp` fields are
`komira_wkt`'s and read and write RFC 3339 in JSON.

## Example

Every example below runs as a test when the package is built.

A deal as a client sends it, read and written back:

```mojo
from komira_crm_proto.crm import Deal
from komira_proto_codec import decode_json, encode_json
from std.testing import assert_equal

var body = String(
    '{"pipelineId":"p1","stageKey":"proposal","title":"Renewal",'
    + '"amountMinor":"125000","currency":"EUR","closeDate":"2026-12-31",'
    + '"customFields":{"source":"web"}}'
)
var deal = decode_json[Deal](body)
assert_equal(deal.amount_minor, Int64(125000))
assert_equal(deal.custom_fields["source"], "web")
assert_equal(encode_json(deal), body)
```

A field at its default is not written, so an active deal (`status` 0) has no
`status` key above.
