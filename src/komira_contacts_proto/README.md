# `komira_contacts_proto`

## Responsibility

The resources of a simple contacts service's JSON API, as protobuf messages
(`komira.contacts.v1`) and the Mojo structs generated from them. The API is
the proto3 JSON mapping of these messages.

- `AddressBook`: a container of cards. `PERSONAL` books belong to one
  subject, `SHARED` books are read by every caller and written by an admin,
  and a `DIRECTORY` book is projected from a user directory and read-only.
- `Card`: one person, organization or contact group, a subset derived from
  JSContact (RFC 9553) and vCard 4.0 (RFC 6350). `uid` is unique within one
  address book; `vcardExtra` keeps unmapped vCard lines verbatim; `version` is
  the ETag of a conditional write and `modseq` the book's change number at
  the card's last write.
- `Name`, `Organization`, `Email`, `Phone`, `PostalAddress`: a card's parts.
- `ChangesResponse` and `CardChange`: the cards of one book written or
  deleted after a change number.
- `ImportCardsRequest`, `ImportCardsResponse` and `ImportRefusal`: a vCard
  import and its summary.
- `ErrorResponse` and `ApiError`: the body of every refusal,
  `{"error":{"code":...,"message":...,"field":...}}`.
- Enums `BookKind` and `CardKind`.

The card is not JSContact on the wire: `name` is one flat message,
`nickname`, `organization` and `title` are singular, and the multi-valued
properties are arrays rather than Id-keyed maps. The field numbers and JSON
names are the contract: `tests/test_contacts_field_numbers.mojo` pins every
number as wire bytes and every JSON key in a literal document.
[`komira_contacts`](https://github.com/komira-ai/komira/blob/main/src/komira_contacts/README.md)
stores these messages.

## API

| name | file | what it is |
|---|---|---|
| `AddressBook`, `Card`, `Name`, `Organization`, `Email`, `Phone`, `PostalAddress` | [contacts.proto](https://github.com/komira-ai/komira/blob/main/src/komira_contacts_proto/komira/contacts/v1/contacts.proto) | the resources |
| `ListAddressBooksResponse`, `ListCardsResponse`, `ChangesResponse`, `CardChange` | [contacts.proto](https://github.com/komira-ai/komira/blob/main/src/komira_contacts_proto/komira/contacts/v1/contacts.proto) | list and change-feed bodies |
| `ImportCardsRequest`, `ImportCardsResponse`, `ImportRefusal` | [contacts.proto](https://github.com/komira-ai/komira/blob/main/src/komira_contacts_proto/komira/contacts/v1/contacts.proto) | a vCard import |
| `ApiError`, `ErrorResponse` | [contacts.proto](https://github.com/komira-ai/komira/blob/main/src/komira_contacts_proto/komira/contacts/v1/contacts.proto) | the error envelope |
| `BookKind`, `CardKind` | [contacts.proto](https://github.com/komira-ai/komira/blob/main/src/komira_contacts_proto/komira/contacts/v1/contacts.proto) | the enums |

The Mojo module is `komira_contacts_proto.contacts`. Each message is a struct
whose constructor takes its fields in declaration order (a message field is
an `Optional`, a `repeated` field a `List`), and conforms to
`komira_proto_codec`'s `Serializable`, so `encode_json` and `decode_json` (and
the binary pair) read and write it.

## Example

Every example below runs as a test when the package is built.

A card as a client sends it, read and written back:

```mojo
from komira_contacts_proto.contacts import Card, CardKind
from komira_proto_codec import decode_json, encode_json
from std.testing import assert_equal

var body = String(
    '{"uid":"urn:uuid:7f1c","kind":"INDIVIDUAL","name":{"full":"Jane Doe",'
    + '"given":"Jane","surname":"Doe"},"emails":[{"address":"jane@example.org",'
    + '"label":"work","pref":1}]}'
)
var card = decode_json[Card](body)
assert_equal(card.kind.value, CardKind.INDIVIDUAL)
assert_equal(card.name.value().surname, "Doe")
assert_equal(card.emails[0].pref, UInt32(1))
assert_equal(
    encode_json(card),
    '{"uid":"urn:uuid:7f1c","name":{"full":"Jane Doe","given":"Jane","surname":"Doe"},'
    + '"emails":[{"address":"jane@example.org","label":"work","pref":1}]}',
)
```

A field at its default is not written, so the zero value of `kind`
(`INDIVIDUAL`) disappears from the output above.

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_contacts_proto`, version 0.1.0
(`mopm.toml`). Its library is the generator's output, committed at `generated/komira_contacts_proto_generated/` and
compiled as the module `komira_contacts_proto` (`[targets] lib` of `mopm.toml`); its tests are `tests/`. It depends on one sibling package, `komira_proto_codec` (`{ path = "../komira_proto_codec", version = "0.1" }`), so the `.conda` of this package records `mojo-komira_proto_codec >=0.1,<0.2` as its dependency
and holds none of their files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The `.proto` files are the inputs of the generator. `komira_contacts_proto_generated_gen` writes the Mojo for them,
`komira_contacts_proto_generated_fresh` compares it with the committed directory and fails when they differ, and
`:lib` is built only after that check has passed. Regenerate with
`./buck2 run komira//tools/build/gen:regen -- komira//src/komira_contacts_proto:komira_contacts_proto_generated`.
`mojo_package` does not run that check itself, so the gate is a target beside it (`BUCK`).

After any change to a `.proto` file, a test, or a manifest of this package or of a sibling, regenerate, run
`buildrules mojo sync` with the packages staged, commit what it writes, and build `komira//src/komira_contacts_proto:lib`
on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`, packed with the manifests of the path dependencies beside its own
(`members`); `:conda_holds` reads it back and fails when the dependencies are not exactly the ones above.
`:komira_contacts_proto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from.
It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`.
