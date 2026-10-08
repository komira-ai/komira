# Contacts and CRM: the data model, the store, keys, erasure and authorization

Status: design, no code. It decides the data model that `komira_contacts_proto`, `komira_contacts`, `komira_crm_proto`
and `komira_crm` will implement; none of them is in the tree yet. It builds on `komira_vcard` and `komira_content_line`
(the vCard reader and writer, open in #799), on the `Database` trait of `komira_db` ([databases](databases.md)) and on
`AuthzPort` and `AuthzResource` in `komira_authz_api` (the `{kind, id, attributes}` resource shape is open in #790).
Related: #828 (the `unique_together` emitter).

## What is it for, and what is out of scope?

Two small services with an open JSON API:

- **Contacts**: address books, the cards in them and contact groups, with vCard import and export, and a read-only
  book projected from an identity provider's user directory.
- **CRM**: accounts, deals on a pipeline and activities, on top of the contacts library. People and companies in the
  CRM are contacts cards; the CRM adds no second person model.

This document fixes the entities, the stored rows, the keys and uniqueness rules, the change feed, erasure and the
authorization resource kinds. The HTTP routes, the binaries' flags and the UI are not designed here.

Out of scope for v1, each a deliberate choice:

- A sync protocol. Neither CardDAV (RFC 6352) nor JMAP Contacts (RFC 9610) is served; clients exchange `.vcf` files and
  use the JSON API. The schema keeps a stable `uid`, a per-card `version` and a per-book `modseq` from the first row, so
  a CardDAV `sync-collection` (RFC 6578) or a JMAP `/changes` front end can be added without a migration.
- JSContact on the wire. The JSON card reuses JSContact (RFC 9553) property names where the meaning is the same, but its
  shapes are simpler (see [the mapping table](#how-does-a-card-map-to-jscontact-vcard-outlook-and-apple)).
- Photos and other blobs, linked or unified person views, merge and dedupe, dynamic groups, per-person sharing of a
  personal book, organizational units and hierarchical directory browsing.
- Anything HR: manager, reports, org chart, employment type.
- In the CRM: products, quotes, forecasting, currency conversion, per-deal access lists (the owner is a field, not a
  permission), deals derived from mail, and any push into another system. Other systems pull the change feed.

## How do Outlook and Apple model contacts?

The model below follows the two vendors where they agree. What each source says, read from its public reference:

| concept | Outlook / Exchange (Microsoft Graph) | Apple (Contacts framework) | open standards |
|---|---|---|---|
| a person or company entry | `contact`: "an item in Outlook where you can organize and save information about the people and organizations you communicate with. Contacts are contained in contact folders." Flat fields (`givenName`, `surname`, `emailAddresses`, `businessPhones`, `companyName`, `department`, `jobTitle`), a `changeKey` that changes on every edit, a `parentFolderId`, and an `id` that by default changes when the item moves to another folder. [G1] | `CNContact`: "an immutable copy of a contact's information"; "Every contact in the contacts database has a unique ID". `contactType` is person or organization; multi-valued fields (`emailAddresses`, `phoneNumbers`, `postalAddresses`, `urlAddresses`) are labeled values. [A1] | vCard 4.0 (RFC 6350); JSContact `Card` (RFC 9553), whose `kind` is individual, group, org, location, device or application (§2.1.4) and whose `uid` "associates the object as the same across different systems, address books, and views" (§2.1.9) |
| the container | `contactFolder`: "A folder that contains contacts", with `parentFolderId` and `childFolders`. [G2] | `CNContainer`: "A contact can be in only one container. CardDAV accounts usually have only one container whereas Exchange accounts may have multiple containers, where each container represents an Exchange folder." Container types are local, exchange and cardDAV. [A2] | a CardDAV address-book collection (RFC 6352); a JMAP `AddressBook`, where one card may sit in several books (`addressBookIds`, RFC 9610 §3) |
| a contact managed by administrators | `orgContact`: "managed by an organization's administrators and are different from personal contacts ... synchronized from on-premises directories or from Exchange Online, and are read-only in Microsoft Graph." [G3] Active Directory's `contact` class holds "information about a person or company that you may need to contact on a regular basis", sits under a domain or an organizational unit, and is not a security principal. [G4] | not modeled: the device shows what its server account serves | none |
| directory users | directory `user` objects (the global address list) | not modeled | SCIM 2.0 `User` (RFC 7643) |
| groups | directory groups: Microsoft 365, security, mail-enabled security and distribution groups; the last two are read-only in Graph, and an organizational contact may be a member of a security group. [G5] Personal contact groups are not part of the Graph `contact` and `contactFolder` resources. | `CNGroup`: "Contacts may be members of one or more groups, depending upon their accounts"; groups are found per container, and subgroups exist (`predicateForSubgroupsInGroup`). [A3] | vCard `KIND:group` with `MEMBER` (RFC 6350 §6.1.4, §6.6.5); JSContact `members` (§2.1.6) |
| scoped administration | an `administrativeUnit` "provides a conceptual container for user, group, and device directory objects" so that an administrator can delegate management of what it contains; membership is assigned or dynamic. [G6] Active Directory's organizational unit is a container for accounts. | none | JSContact `organizations[].units` is only a descriptive unit path on a card (§2.2.3) |

What the model takes from this:

- **One container per card**, as both vendors do. A JMAP-style card in several books is not supported.
- **Administrator-managed entries live apart from personal ones.** Outlook keeps `orgContact` read-only and apart from
  `contact`; Active Directory keeps `contact` objects in the directory. Here that is a SHARED book (written by
  administrators, read by everyone) and a DIRECTORY book (projected, read-only).
- **A personal contact group is a card**, as vCard and JSContact model it (`kind=group` with members), not a separate
  table. Directory groups are not in v1; when the directory source provides groups, they become read-only group cards
  in the DIRECTORY book, so the card shape does not change.
- **The id a client keeps is `uid`**, not the server id. Graph's `id` changes on a move by default and Apple's
  identifier is local to the device's store; `uid` is the identifier the standards define as stable across systems.
- **"Roughly Active Directory"** means: directory users correspond to directory `user` objects, the SHARED book to
  `contact` objects, and group cards to personal distribution lists. Organizational units and administrative units are
  not modeled.

## What are the entities?

### Contacts

**AddressBook** `{id, kind, owner, name, is_default, modseq, version, created_at, updated_at}`

- `kind` is one of:
  - `PERSONAL`: owned by one principal (`owner`); at most one is the owner's default book.
  - `SHARED`: written by principals holding the service's `admin` action, read by every principal allowed `read`.
    There may be several.
  - `DIRECTORY`: exactly one per dataset, read-only to every caller, written only by the directory projection. It is
    added with the directory projection, after the first release of the library.
- `owner` is the pair `(issuer, subject)` of the principal, never the subject alone: a service that trusts two
  issuers must not let two different principals with the same `sub` share a book. It is empty for SHARED and DIRECTORY.
- `modseq` is the book's change counter (see [the change feed](#how-does-the-change-feed-work)).
- `is_default` is not stored on the book row: it is read from the owner's `contacts_default_books` row, so "at most one
  default book" is one key row and not a flag that two rows could both carry.

**Card** `{id, book_id, uid, kind, name, nickname, organization, title, emails, phones, addresses, urls, birthday,
notes, members, vcard_extra, version, modseq, deleted, created_at, updated_at}`

- `id` is minted by the server. `uid` is the vCard `UID` when an import carries one, otherwise the server mints
  `urn:uuid:<UUID v4>` (RFC 9553 §2.1.9 recommends that form). `uid` never changes after create.
- `kind` is `individual`, `org` or `group` (the JSContact names). The other JSContact kinds are refused.
- A card in the DIRECTORY book is the projection of one directory subject `(issuer, subject)`; the pair is kept in the
  key table `contacts_directory_subjects`, not on the card, so the card shape is the same in every book.
- `name` is `{full, given, surname, middle, prefix, suffix}`; `organization` is `{name, units[]}`; `emails`, `phones`
  and `urls` are lists of `{value, label, pref}`; `addresses` is a list of structured addresses with a label and `pref`.
- `birthday` is text in the RFC 6350 date form, so a date without a year (`--MMDD`) survives. It is not a timestamp:
  Graph's `birthday` is a `DateTimeOffset` [G1], which cannot hold a year-less date.
- `members` (group cards only) is a list of member `uid`s in the same book. A member that does not resolve is kept and
  shown as unresolved; the store does not enforce it, because a vCard `MEMBER` may name a card that was not imported.
- `vcard_extra` keeps every vCard property the mapping does not read, verbatim, so an export does not lose what an
  import carried (RFC 9555 §2.15.1 keeps such properties in `vCardProps` for the same reason).
- `version` is the compare-and-swap counter for updates; `modseq` is the book's counter at the card's last change;
  `deleted` marks a tombstone, which keeps only `id`, `book_id`, `uid` and `modseq`.

### CRM

The CRM embeds the contacts library and keeps its people and companies in one SHARED book of its own dataset, the CRM
book. People are `individual` cards and companies are `org` cards. A CRM deployment does not call a contacts
deployment: two services that depend on each other at run time cannot be deployed alone. The cost is that a person can
exist both in the CRM book and in someone's personal book of a contacts deployment; vCard export moves them between.

| entity | fields |
|---|---|
| **Account** | `id, org_card_id, owner, domain, status (active, archived), external_id, custom_fields, version, created_at, updated_at` |
| **AccountContact** | `account_id, card_id, role` |
| **Pipeline** | `id, name, stages (ordered {key, label, kind: open, won, lost}), version` |
| **Deal** | `id, pipeline_id, stage_key, title, account_id (optional), primary_contact_card_id (optional), amount_minor (int64), currency (ISO 4217 alphabetic code), close_date (a calendar date), owner, external_id, status (active, archived), custom_fields, last_activity_at, version, created_at, updated_at` |
| **Activity** | `id, kind (note, call, meeting, email_logged, stage_changed), subject_kind (deal, account, card), subject_id, body, actor (issuer, subject), occurred_at, system (bool), version` |
| **CustomFieldDef** | `id, entity_kind (account, deal, card), key, label, type (text, number, date, bool), version` |

- Money is an integer count of the currency's minor unit, with the code beside it. An amount is exact and sortable,
  and a value that is not a whole number of minor units is refused. A code not in the ISO 4217 table the library
  carries is refused.
- A stage change writes a `stage_changed` activity with `system = true` in the same transaction as the deal. System
  activities refuse every update.
- Archiving hides an account or a deal from lists; reads by id, and deals of an archived account, still resolve.
  Activities have no archive.
- `custom_fields` is a map from a `CustomFieldDef.key` of the entity's kind to a value of the definition's type.
- A new dataset is seeded with one pipeline of six stages: `qualification`, `discovery`, `proposal` and `negotiation`
  (kind `open`), `closed_won` (kind `won`) and `closed_lost` (kind `lost`). Stage keys are unique within a pipeline;
  the library checks that when a pipeline is written, since the stages are one JSON column.

## How are the rows stored?

Every store is generic over `DB: Database` and uses only the structured operations, so the same store source runs on
SQLite, Postgres and the Firestore driver. Nested values (a card's name, its lists, `custom_fields`, a pipeline's stages)
are each one JSON column, as `DbStorable` already stores nested messages. The JSON stays a storage detail: the store
filters only on the scalar columns below.

| table | primary key | scalar columns the store filters or orders on |
|---|---|---|
| `contacts_books` | `id` | `kind`, `owner_iss`, `owner_sub`, `modseq`, `version` |
| `contacts_cards` | `id` | `book_id`, `uid`, `kind`, `modseq`, `deleted`, `version` |
| `contacts_card_uids` (key table) | `(book_id, uid)` | `card_id` |
| `contacts_default_books` (key table) | `(owner_iss, owner_sub)` | `book_id` |
| `contacts_book_roles` (key table) | `role` | `book_id` |
| `contacts_directory_subjects` (key table) | `(subject_iss, subject_sub)` | `card_id` |
| `crm_accounts` | `id` | `org_card_id`, `owner_iss`, `owner_sub`, `status`, `external_id`, `version` |
| `crm_account_contacts` (key table) | `(account_id, card_id)` | `role` |
| `crm_account_org_cards` (key table) | `org_card_id` | `account_id` |
| `crm_pipelines` | `id` | `version` |
| `crm_deals` | `id` | `pipeline_id`, `stage_key`, `account_id`, `owner_iss`, `owner_sub`, `status`, `close_date`, `version` |
| `crm_activities` | `id` | `subject_kind`, `subject_id`, `actor_iss`, `actor_sub`, `occurred_at`, `system`, `version` |
| `crm_external_ids` (key table) | `(entity_kind, external_id)` | `entity_id` |
| `crm_custom_field_defs` | `id` | `entity_kind`, `key` |
| `crm_custom_field_keys` (key table) | `(entity_kind, key)` | `def_id` |
| `crm_feed` | `id` (one row) | `modseq` |

There is no scope column. One deployment holds one dataset; a second dataset is a second deployment with its own
database. This removes a class of defects instead of testing for it: a query that forgets a scope filter, a check made
against the wrong scope, and a global UNIQUE column that rejects one dataset's value because another dataset holds it
(which also tells the first dataset's users that the value exists). The cost is more deployments.

## How is uniqueness enforced?

Every uniqueness rule is a **key table** whose primary key is the unique tuple, created with `create_if_absent` (one
column) or `create_if_absent_composite` (several). No row table carries a secondary UNIQUE constraint, for two
reasons:

- A document backend has no secondary unique constraint. The Firestore driver implements `create_if_absent_composite`
  as a create on a document id derived from the tuple, and the index emitter refuses a `unique` composite index for
  Firestore. A key table is exactly that derived document.
- A row table keyed by `id` can then be read with `get_by_key` on every backend, while the key table answers "who holds
  this tuple".

On SQLite and Postgres, `ON CONFLICT (c1, c2)` needs a constraint over exactly those columns; the key table's composite
primary key is that constraint. No table here uses `(komira.db.unique_together)`, so this model does not wait on #828.

| rule | key table | what a duplicate gets |
|---|---|---|
| a `uid` is unique within a book, and the same `uid` may exist in two books | `contacts_card_uids (book_id, uid)` | create: a conflict; import: an update of the existing card (import is an upsert on `uid`) |
| an owner has at most one default book | `contacts_default_books (owner_iss, owner_sub)` | changing the default is a `conditional_update` of that row |
| exactly one DIRECTORY book, exactly one CRM book | `contacts_book_roles (role)` with roles `directory` and `crm` | the second create loses and reads the winner |
| a directory subject has at most one card in the DIRECTORY book | `contacts_directory_subjects (subject_iss, subject_sub)` | the projection updates the existing card |
| an org card backs at most one account | `crm_account_org_cards (org_card_id)` | a conflict |
| a card is linked to an account once | `crm_account_contacts (account_id, card_id)` | the link's role is updated |
| an `external_id` is unique per entity kind, so an account and a deal may carry the same one | `crm_external_ids (entity_kind, external_id)` | CSV import: an update of the existing entity (import is an upsert on `external_id`) |
| a custom-field key is unique per entity kind | `crm_custom_field_keys (entity_kind, key)` | a conflict |

**Write order and crashes.** On SQLite and Postgres the row and its key row are written in one transaction. The
Firestore driver has no multi-document transaction: each operation commits alone, and the driver's `begin` and
`rollback` keep a journal of the documents created since `begin` and delete them on `rollback`. The store uses the same
order on every backend, the order that driver is built for:

1. `begin`; write the row; create the key row pointing at it; `commit` when the key create wins, `rollback` when it
   loses (on Firestore the rollback deletes the row just written).
2. **A row whose uniqueness is held by a key table is live only while its key row points back at it.** Every read
   that returns such a row (by id, by `uid`, in a list) checks the key row and skips a row the key does not name. On
   SQLite and Postgres the check never skips anything, because the two writes commit together; the store runs it on
   every backend so that one store source serves them all.
3. A key row is never deleted to make room for a create. A writer that loses a key reads the holder; a create reports
   a conflict and an import updates the holder.

What a crash or a slow writer leaves behind, and why uniqueness still holds:

- A crash after the row and before the key leaves an orphan row. No key names it, so no read returns it, and the next
  create of the same tuple wins the key. Orphan rows are kept in v1; deleting them is a later sweep, which must skip
  rows younger than a stated age, because a row whose key create is still in flight looks the same as an orphan.
- A slow writer A that has written row X but not yet its key, racing writer B on the same tuple: whichever key create
  lands first wins. If B wins, A's create loses and its rollback deletes X; if A's process dies first, X is an orphan
  as above. In neither case do two rows with one tuple become live.
- Rejected: write the key first and let a loser delete a key whose target is absent. A loser cannot tell a crashed
  writer from one between its two writes, so it deletes a live writer's key, and both rows end up live with one `uid`.
  It is one of the mutants the always-hold test below must turn red.
- Erasure and other deletes remove the key row before the row, so a crash between the two leaves an orphan row, never a
  key naming a row that is gone.

The cost is one key read per returned row of a guarded table. Rows that no key row guards need no check: activities,
pipelines, books that hold no role, and deals without an `external_id`.

## How does the change feed work?

`GET .../changes?since=<modseq>` returns, in `modseq` order, every card of one book changed after `since`, tombstones
included, and a cursor for the next call. The CRM has one feed for the dataset (`crm_feed`) covering accounts, deals,
activities, pipelines and the CRM book's cards. Nothing is pushed: a search index, a knowledge graph or a UI that wants
the data pulls this feed.

- **Allocation.** A write bumps the counter row (the book row, or the `crm_feed` row) with `conditional_update` and
  `bump_version_col = modseq`, reads the new value back, and stamps it on the changed row, all in the write's
  transaction.
- **Why that gives a feed with no gaps a reader can miss:** on Postgres the bumped counter row stays locked until the
  transaction commits, and SQLite serializes writers (`BEGIN IMMEDIATE`). Changes therefore commit in `modseq` order, so
  a reader that has seen `modseq = n` will never later find a committed change below `n`.
- **On the Firestore driver this does not hold.** Each operation commits alone, so a writer that took `n` may commit
  after a writer that took `n + 1`, and a reader can pass `n` before it lands. The store does not claim a change feed on
  a backend without multi-statement transactions; the feed and the stage-change atomicity are tested on SQLite (and
  Postgres when a test target for it exists), and every other store property on SQLite and the Firestore mock.
- The CRM's single counter row serializes every CRM write. That is the price of one ordered feed and is acceptable for
  the write rates a CRM sees; it is a limit, not a goal.
- **The cursor is the highest `modseq` among the returned rows**, and `since` itself when no row is returned. With a
  page limit the rows are the lowest `modseq`s above `since` and the cursor is the last row's. The cursor is never the
  counter row's value: a reader that reads the counter after its row query (each statement takes its own snapshot on
  Postgres READ COMMITTED, and on SQLite outside one transaction) would return a counter that covers a change committed
  between the two reads and that the rows did not include, and the client would skip it for good. Because changes
  commit in `modseq` order (above), every change the row query did not see has a `modseq` above every row it did see,
  so it is above the cursor.
- Tombstones are kept in v1. Purging them below a horizon, and answering a `since` below the horizon with "resync from
  scratch", is a later change.

## Who may do what?

Authentication is a bearer-token middleware in front of the route table (the JWT verifier is not in the tree yet);
a request without a valid token gets 401 before any handler runs. Every route is declared in a route table, and the router calls `AuthzPort.check` before the handler.
An undeclared route is denied.

**Resource kinds.** Each service declares its kinds as data in its own package; the generic packages name none.

| service | kind checked with `AuthzPort` | id | actions |
|---|---|---|---|
| contacts | `contacts.instance` | the deployment's OAuth client id | `read`, `write`, `admin` |
| CRM | `crm.instance` | the deployment's OAuth client id | `read`, `write`, `admin` |

The policy decision point is asked one coarse question per request: may this principal `read`, `write` or `admin` this
deployment. No v1 object is shareable through the policy decision point, so no per-object grant lives outside the
service. Every route maps to one of the three actions, and the service enforces the per-object rules itself:

- a PERSONAL book and its cards are reachable only by its owner `(issuer, subject)`; anyone else gets 404, not 403, so
  a guessed id does not confirm that the object exists;
- SHARED books of a contacts deployment are written only with `admin`;
- the CRM book (the book `contacts_book_roles` names under role `crm`) is a SHARED book whose cards are written with
  the CRM's `write`, like every other CRM object; the admin-only rule above does not apply to it;
- the DIRECTORY book refuses every write from a caller with 403, `admin` included;
- CRM objects are readable with `read` and writable with `write`; `owner` is a field to filter on, not a permission;
- erasure needs `admin`.

The service writes the real object kind and id of every decision into its own audit record: `contacts.book`,
`contacts.card`, `crm.account`, `crm.deal`, `crm.activity`, `crm.pipeline` and `crm.custom_field_def`. A check made
against another kind, or with an empty id, is a defect the recording-authorization test catches.

## How is a subject erased?

An administrator's erase call, `POST /v1/admin/erase {subject: {iss, sub}}`, is idempotent and returns a count per
table. A second call returns zeros.

Each step names the columns it filters on; every one is a scalar column of the table above. Key rows go before the
rows they guard (see [write order](#how-is-uniqueness-enforced)).

- **Contacts**
  - books: `contacts_books` where `kind = PERSONAL`, `owner_iss = iss` and `owner_sub = sub`;
  - for each such book: `contacts_card_uids` where `book_id` is the book, then `contacts_cards` where `book_id` is the
    book (cards and tombstones), then the book row;
  - the default-book row: `contacts_default_books` by its key `(iss, sub)`;
  - the directory card: `contacts_directory_subjects` by its key `(iss, sub)` gives `card_id`; the key row, then the
    card's `contacts_card_uids` row, then the card row are deleted.
  Cards in other principals' books and in SHARED books are not searched or changed: they are those owners' data.
- **CRM** keeps the dataset's business records and removes the subject from them:
  - `crm_accounts` and `crm_deals` where `owner_iss = iss` and `owner_sub = sub`: both owner columns become empty
    (unowned);
  - `crm_activities` where `actor_iss = iss` and `actor_sub = sub`: `actor_iss` becomes empty and `actor_sub` the fixed
    value `erased`.
  Each rewrite is a write like any other: it bumps `version` and the `crm_feed` counter, so a consumer of the feed sees
  it. Whether erasure should also delete activity bodies the subject wrote is open (see below).
- A directory entry with `active = false` (SCIM, RFC 7643 §4.1.1) is not erasure. SCIM `active` is often a reversible
  suspension, so it only disables access: the subject's requests get 403 and their card leaves the DIRECTORY book, and
  their PERSONAL rows stay until an erase call.

## How does a card map to JSContact, vCard, Outlook and Apple?

| our card | JSContact (RFC 9553) | vCard 4.0 (RFC 6350) | Graph `contact` [G1] | Apple `CNContact` [A1] |
|---|---|---|---|---|
| `id` | none (server id) | none | `id` | `identifier` |
| `uid` | `uid` (§2.1.9) | `UID` (§6.7.6) | none | none |
| `kind` (`individual`, `org`, `group`) | `kind` (§2.1.4), a subset | `KIND` (§6.1.4) | none (no kind field; an organization is a contact with only `companyName`) | `contactType` (person, organization); groups are `CNGroup` |
| `name.full` | `name.full` (§2.2.1) | `FN` (§6.2.1) | `displayName` | none (formatted on the device) |
| `name.given`, `surname`, `middle` | `name.components` of kind `given`, `surname`, `given2` | `N` (§6.2.2) components 2, 1, 3 | `givenName`, `surname`, `middleName` | `givenName`, `familyName`, `middleName` |
| `name.prefix`, `suffix` | components of kind `title`, `credential` | `N` components 4, 5 | `title`, `generation` | `namePrefix`, `nameSuffix` |
| `nickname` (one) | `nicknames` (§2.2.2, an Id map) | `NICKNAME` (§6.2.3) | `nickName` | `nickname` |
| `organization{name, units[]}` (one) | `organizations` (§2.2.3, an Id map) | `ORG` (§6.6.4) | `companyName`, `department` | `organizationName`, `departmentName` |
| `title` (one) | `titles` (§2.2.5, an Id map) | `TITLE` (§6.6.1) | `jobTitle` | `jobTitle` |
| `emails[{value, label, pref}]` | `emails` (§2.3.1, an Id map with `contexts`, `pref`) | `EMAIL` (§6.4.2) with `TYPE`, `PREF` | `emailAddresses` | `emailAddresses` (labeled values) |
| `phones[...]` | `phones` (§2.3.3) | `TEL` (§6.4.1) | `businessPhones`, `homePhones`, `mobilePhone` | `phoneNumbers` |
| `addresses[...]` | `addresses` (§2.5.1) | `ADR` (§6.3.1) | `businessAddress`, `homeAddress`, `otherAddress` | `postalAddresses` |
| `urls[...]` | `links` (§2.6.3) | `URL` (§6.7.8) | `businessHomePage` | `urlAddresses` |
| `birthday` (text) | `anniversaries` of kind `birth` (§2.8.1) | `BDAY` (§6.2.5) | `birthday` (a timestamp) | `birthday` (date components) |
| `notes` (one text) | `notes` (§2.8.3, an Id map) | `NOTE` (§6.7.2) | `personalNotes` | `note` |
| `members[uid]` | `members` (§2.1.6, `uid` to `true`) | `MEMBER` (§6.6.5) | none | group membership through `CNGroup` |
| `vcard_extra` | `vCardProps` (RFC 9555 §2.15.1) | every property not mapped above | extended properties | none |
| `version` | none | none | `changeKey` | none |

Where the JSON card differs from JSContact, and why:

- JSContact keeps most multi-valued properties as Id-keyed maps, `name` as ordered `components`, `members` as a
  `String[Boolean]` map, and an `@type` on every object; proto3 JSON cannot emit `@type`. The card uses lists, a flat
  name and single `nickname`, `organization`, `title` and `notes`, because that is what a form, a CSV column and a
  simple client need.
- A JMAP Contacts front end would therefore need a translation function over the card, not only a new route, and no
  JSContact client reads the card's JSON directly. vCard is the interchange format both vendors read and write, and it
  is the one this design commits to.

## What must always hold?

Each rule names the test the implementing change must carry and the mutant that must turn it red. None exists yet.

- **A `uid` is unique per book, not globally.** The same `uid` in two books is accepted; twice in one book is refused.
  Mutant: key the uid table on `uid` alone.
- **Exactly one of two concurrent updates with the same `version` wins**, and the loser gets a conflict. Mutant: drop
  the version guard from `conditional_update`.
- **`modseq` strictly increases within a book across creates, updates and deletes, and a delete leaves a tombstone in
  the feed.** Mutants: stamp `modseq` outside the write transaction; skip the bump on delete.
- **One live row per unique tuple, with a writer paused between its two writes.** Over a `Database` wrapper that can
  pause a writer after a named operation, on SQLite and the Firestore mock: writer A writes card X with `uid` U and is
  paused before its key create; writer B creates a card with `uid` U and wins; A resumes, loses and rolls back. The
  book then lists exactly one card with `uid` U and `get` by `uid` returns B's. A second case kills A at the pause:
  X is returned by no read, and the next create of U wins. Mutants: a read that skips the back-pointer check (two
  cards with U listed); the key-first order with a loser that deletes a key whose target is absent (A's late row and
  B's both live).
- **The feed cursor never passes an unseen change.** A writer commits between the reader's row query and the building
  of its response; the next call with the returned cursor returns that change. Mutant: return the book's counter read
  after the row query.
- **A stage change and its `stage_changed` activity commit together.** A fault injected between them leaves neither.
  Mutant: write them in two transactions.
- **An `external_id` is unique per entity kind.** An account and a deal with one `external_id` both insert; two accounts
  with it conflict; a CSV file imported twice creates nothing new. Mutants: key on `external_id` alone; insert instead
  of upsert.
- **Money is exact.** A fractional minor unit and an unknown currency code are refused, each with its own error text.
- **Requests without a valid token get 401 and zero row bytes; a principal the authorization port denies gets 403 and
  zero row bytes; another owner's PERSONAL card gets 404.** Mutants: a route that skips the principal; an allow-all
  port; no owner check.
- **Every route asks for the action and resource the route table declares.** A recording `AuthzPort` asserts the
  action, kind and id per route. Mutant: one route that skips the check.
- **The DIRECTORY book refuses every caller's write, `admin` included.** Mutant: drop the read-only guard.
- **The CRM book is written with `write`, other SHARED books only with `admin`.** A principal allowed `write` and not
  `admin` adds a card to the CRM book, and gets 403 writing a SHARED book of a contacts deployment. Mutants: apply the
  admin-only rule to the CRM book; drop it for the other SHARED books.
- **Erasure removes every row of the subject in every declared table and nothing else.** A closed-world test seeds
  every table for two subjects, erases one, and compares the full table contents. Mutants: skip one table; delete by
  `sub` without `iss`; skip the `contacts_directory_subjects` lookup.
- **`active = false` disables and does not delete.** Mutants: erase on `active = false`; skip the disable.

## What are its limits and open questions?

- **Limit: no change feed on a backend without multi-statement transactions** (see the change feed). Running the CRM
  or the contacts feed on Firestore needs a watermark design that is not part of this document.
- **Limit: one ordered CRM feed serializes CRM writes.**
- **Limit: orphan rows stay until a sweep exists** (see write order); the sweep needs an age guard.
- **Limit: no proven vendor export fixtures.** What Outlook and Apple actually write into a `.vcf` (vCard 2.1, 3.0 or
  4.0, and which extensions) is not established here; the vCard conformance package carries synthetic fixtures until
  real exports are captured.
- **Open: erasure of activity bodies.** This design keeps an erased subject's activity text as a business record. An
  operator whose policy requires deleting it would need a per-deployment switch.
- **Open: directory groups.** If the identity provider's directory exposes groups (SCIM `Groups`), they become
  read-only group cards in the DIRECTORY book. Organizational units remain out of scope.
- **Open: package and binary names** of the two services beyond the library names used here.

## Sources

- [G1] Microsoft Graph, contact resource type: https://learn.microsoft.com/en-us/graph/api/resources/contact?view=graph-rest-1.0
- [G2] Microsoft Graph, contactFolder resource type: https://learn.microsoft.com/en-us/graph/api/resources/contactfolder?view=graph-rest-1.0
- [G3] Microsoft Graph, orgContact resource type: https://learn.microsoft.com/en-us/graph/api/resources/orgcontact?view=graph-rest-1.0
- [G4] Active Directory schema, Contact class: https://learn.microsoft.com/en-us/windows/win32/adschema/c-contact
- [G5] Microsoft Graph, working with groups: https://learn.microsoft.com/en-us/graph/api/resources/groups-overview?view=graph-rest-1.0
- [G6] Microsoft Graph, administrativeUnit resource type: https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit?view=graph-rest-1.0
- [A1] Apple Contacts framework, CNContact: https://developer.apple.com/documentation/contacts/cncontact
- [A2] Apple Contacts framework, CNContainer: https://developer.apple.com/documentation/contacts/cncontainer
- [A3] Apple Contacts framework, CNGroup: https://developer.apple.com/documentation/contacts/cngroup
- RFC 6350 (vCard 4.0): https://www.rfc-editor.org/rfc/rfc6350
- RFC 9553 (JSContact): https://www.rfc-editor.org/rfc/rfc9553
- RFC 9555 (JSContact and vCard conversion): https://www.rfc-editor.org/rfc/rfc9555
- RFC 9610 (JMAP for Contacts), RFC 6352 (CardDAV), RFC 6578 (WebDAV sync), RFC 7643 (SCIM core schema): https://www.rfc-editor.org/rfc/rfc9610
