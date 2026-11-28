# The app integration framework: the registration record, the environment settings, the v1 wire and its errors

Status: design, not built. This document is the contract four pieces are built from:

- the **registry**, which stores registration records and serves `/v1/apps`;
- the **issuer**, the OIDC issuer that mints tokens for people and apps;
- the **notification service**, which serves publish, acknowledge, resolve, the inbox and history under
  `/v1/notifications`;
- the **framework library**, which an app links to read its settings, verify tokens, get its own service token, and
  call publish and health.

None of the four exists yet. They build on komira packages in the states [HTTP authentication](http_auth.md) gives:
`jwks` and `json` are on `main`; `jose` verifies ES256, EdDSA and RS256 and signing is target; `http_auth`'s
bearer-JWT middleware is partly built (one RS256 trust anchor, `typ` `JWT` only, with `at+jwt` a target); `oauth`
has the client-credentials client and the RFC 7591 registration codec. Where a piece below needs a target of one of
those packages, the line says so.

**Tags.** Every shape here is a **[proposal]** that waits on decision **D12** of the project's maintainers, unless a
line names another decision. The decisions are listed with what each one governs in
[Open decisions](#open-decisions). A line marked **[decided here]** is a choice this document makes where the
proposal left a case open; each says why. When the decisions are settled, the tags go and the text stays.

## What is it for, and what is out of scope?

An organization runs several services ("apps") and wants one sign-in, one place where alerts land, and one list of
what exists. The framework is how an app hooks into that:

1. The app declares itself once, in a **registration record**: who it is, where it is, who runs it, the OIDC client
   it uses, the roles it understands, the alerts it emits and the settings it needs.
2. The app takes **four environment settings** that point it at the central services, as command-line flags.
3. The app and the people using it call a small **HTTP/JSON wire under `/v1`**.

An **environment** is one set of central services: one registry, one issuer, one notification service and one
relay, each owned by an environment id. An app is registered in exactly one environment and talks only to that
environment's services. Several environments are several independent instances of the same model.

Two clients of the wire are named below. The **hub** is the web app where a person signs in once and finds every
app: its **launcher** lists the active records (name, link, health), and its **inbox** shows the person's
notifications. The hub is an ordinary registered app; it has no wire of its own here. A **command-line tool** for
registrars uses the issuer's built-in client ([Bootstrap](#bootstrap)).

Out of scope here: how an app is deployed (the registry is a catalog; it never deploys, starts, stops or upgrades
anything), the relay's own wire (grant, publish, send, bridge, close, list), the sign-in and consent screens, the
identity provider the issuer federates to, assigning roles to people, mail and push delivery, subscriptions (D4),
and fan-out across environments.

## The registration record

The record is one JSON object. Its members, in the order the registry renders them:

| member | type | required | per environment | rule |
|---|---|---|---|---|
| `name` | string | yes | no | the app's id ([Names](#names)). Immutable. It is also the app's OIDC client id |
| `environment_id` | string | yes | yes | the environment the record belongs to; must equal the registry's own id. Immutable |
| `display_name` | string | yes | no | 1 to 64 code points, one line ([Text](#text)) |
| `description` | string | yes | no | 0 to 500 code points ([Text](#text)) |
| `url` | string | yes | yes | where a person opens the app ([URLs](#urls)) |
| `owner` | object | yes | yes | `{"person": SUB}`: the person who runs the app and receives its notifications |
| `auth` | object | no | partly | the app's OIDC client. Absent means a [pointer-only entry](#pointer-only-entries) |
| `roles` | array | yes | no | 0 to 32 roles, each `{name, description}` |
| `notification_kinds` | array | yes | no | 0 to 64 kinds, each `{name, default_severity, description}` |
| `health_url` | string | yes | yes | a URL whose 2xx reply means the app is up ([Health](#health)) |
| `status_url` | string | no | yes | a page a person reads for status; shown in the launcher, never polled |
| `settings` | array | yes | no | 0 to 64 declarations, each `{name, type, required, description}`: names and types only, never values |

**[decided here]** `owner` names one person. A team owner needs a team store and its membership, which no piece
here holds; `{"team": ...}` can be added later as a second form of `owner`, which is additive.

`auth` holds:

| member | type | required | per environment | rule |
|---|---|---|---|---|
| `token_endpoint_auth_method` | string | yes | no | `private_key_jwt` (a confidential app: a server) or `none` (a public client: a desktop, mobile or browser app; PKCE required) |
| `token_endpoint_auth_signing_alg` | string | with `private_key_jwt` | no | `ES256` or `EdDSA`: the algorithm of the app's client assertions, the two `oauth` signs with |
| `grant_types` | array | yes | no | 1 to 3 distinct values of `authorization_code`, `refresh_token`, `client_credentials` |
| `redirect_uris` | array | yes | yes | 0 to 10 distinct redirect URIs ([Redirect URIs](#redirect-uris)) |
| `jwks_url` | string | with `private_key_jwt` | yes | where the app publishes the public keys of its client assertions (RFC 7523 section 2.2); RFC 7591's `jwks_uri` |
| `removal_notice_url` | string | no | yes | where the issuer posts a [removal notice](#removal-notice) |

The cross-member rules of `auth`:

- `client_credentials` needs `private_key_jwt`. A public client never gets a service token, so it cannot publish or
  push health.
- `authorization_code` needs at least one redirect URI, and redirect URIs need `authorization_code`, so no URI is
  registered that nothing uses.
- `refresh_token` needs `authorization_code`.
- `token_endpoint_auth_signing_alg` and `jwks_url` are required with `private_key_jwt` and refused with `none`.

**[decided here]** A confidential app authenticates with `private_key_jwt`, never with a client secret. An earlier
draft had Register return "the OIDC client secret once". komira's `oauth` client authenticates only with
`private_key_jwt` ([HTTP authentication](http_auth.md#client-credentials-oauth)), so a secret would need a second,
weaker method in every app. With a key pair the registry never holds or returns a secret, which keeps the rule that
the record holds no secret values, and makes Register safe to retry.

**[decided here]** The OIDC client id is the app's `name`, so the record has no `client_id` member: within one
issuer the name is already unique and never reused.

### Which members are per environment

`environment_id`, `url`, `owner`, `auth.redirect_uris`, `auth.jwks_url`, `auth.removal_notice_url`, `health_url`
and `status_url` differ from one environment to the next. Everything else is the same for the app in every
environment. The record is not split in two: with one environment there is nothing to share yet. Marking the
members now keeps a later split additive (a shared part and a per-environment part, each a subset of today's
members).

### Names

| what | grammar | length |
|---|---|---|
| app `name`, `environment_id` | `^[a-z][a-z0-9]*(-[a-z0-9]+)*$`: lowercase ASCII letters and digits, single hyphens between them, starting with a letter | name 2 to 40, environment id 2 to 32 |
| role, kind and setting `name` | `^[a-z][a-z0-9]*(_[a-z0-9]+)*$`: the same with single underscores | roles 1 to 32, kinds and settings 1 to 64 |
| `owner.person` | the person's `sub` at the environment's issuer: printable ASCII `!` to `~` without `:` | 1 to 255 |

- An app `name` is unique in its environment and is **never reused**, not even after Retire: notification ids,
  history and old tokens name it. A Register of a retired name is refused (`name_retired`). [decided here]
- The app name `environment` is reserved: it is the issuer's built-in client and the key of the environment's own
  roles in a token ([Tokens](#tokens)).
- The role name `publisher` is reserved: the issuer gives it to the app's own service identity.
- The kind names `health` and `removal_failed` are reserved: the central services publish them for the app.
- The setting names of [the library's flags](#the-flags-the-library-owns) are reserved.
- Role, kind and setting names are each unique within their array.

### Text

Every text member (`display_name`, `description`, the nested `description`s, and on the wire `title`, `body`,
`note` and `detail`) is a UTF-8 string, counted in Unicode code points, that:

- is in Unicode Normalization Form C, so two equal-looking texts are equal code point for code point;
- holds no character of general category `Cc` (U+0000 to U+001F, U+007F to U+009F), except U+000A (line feed) in a
  member named `description`, `body` or `note`;
- holds no U+2028 or U+2029 in a one-line member (`display_name`, `title`, `detail`);
- has no leading or trailing character with the Unicode `White_Space` property.

The nested `description` of a role, kind or setting is 1 to 200 code points. [decided here: NFC makes record
equality, which Register and Update idempotency rest on, well defined]

### URLs

Every URL member (`url`, `health_url`, `status_url`, `auth.jwks_url`, `auth.removal_notice_url`, and a Publish
`link`) matches this grammar, which the schema's `https_url` pattern holds:

- `https://`, then a host of DNS labels: each label 1 to 63 of `a-z`, `0-9`, `-`, not starting or ending with `-`,
  labels joined by `.`, the last label starting with a letter. No IP literal, no userinfo, no uppercase.
- An optional port `:1` to `:65535`, no leading zero.
- An optional path from `/` and an optional query from `?`, both of printable ASCII from RFC 3986's unreserved,
  reserved and `%HH` characters, except `#`, `@` and white space.
- At most 2048 characters; the grammar is ASCII, so that is also 2048 bytes.

A URL is stored as sent and compared byte for byte; nothing is normalized. Nothing in a record names a cloud
provider or a cloud account: a URL is where the app is, not how it was deployed. [decided here: DNS names only keeps
the registry's poller off addresses nobody registered by name, and no normalization keeps comparison exact]

### Redirect URIs

A redirect URI is either an `https` URL as above (iOS uses this form, as a claimed link), or the loopback form for
desktop apps (RFC 8252 section 7.3): `http://127.0.0.1/PATH` or `http://[::1]/PATH`, with a path and registered
**without a port**.

At authorization the request's `redirect_uri` must equal a registered one byte for byte. The one exception is a
loopback URI: the request may add `:PORT` (1 to 65535, no leading zero) after the host, and must equal the
registered URI once that is removed. The query, if any, must match as well. The name `localhost` is refused
(RFC 8252 section 8.3), and so are private-use schemes (`com.example.app:/cb`), wildcards (any `*`) and fragments;
private-use schemes can be added later, additively. [decided here: the desktop clients run on macOS, Linux and
Windows, where loopback works]

### Settings

A setting declaration says that the app needs a value, what kind of value, and whether it may be left out:

| member | type | rule |
|---|---|---|
| `name` | string | see [Names](#names); the flag is the name with `_` turned into `-`: `database_url` is `--database-url` |
| `type` | string | one of `string`, `integer`, `boolean`, `duration`, `url`, `secret_ref` |
| `required` | boolean | `false` means the app starts without it and turns the feature off (an environment with no job service leaves `jobs_url` out) |
| `description` | string | what the value is, 1 to 200 code points |

The value types, as the library's flag parser reads them:

| type | value on the flag |
|---|---|
| `string` | 1 to 4096 bytes of UTF-8 holding no `Cc` character |
| `integer` | `-?(0\|[1-9][0-9]*)` within the signed 64-bit range; `-0` is refused |
| `boolean` | `true` or `false` |
| `duration` | `(0\|[1-9][0-9]*)` and one unit, `s`, `m` or `h` (`0s`, `90s`, `30m`, `1h`), at most 2<sup>31</sup> seconds; no compound forms like `1h30m` |
| `url` | an absolute URI (RFC 3986: a scheme, `:`, and the rest), at most 4096 bytes; the scheme is the app's to check. A password in it (`user:pass@`) is refused: a credential is a `secret_ref` |
| `secret_ref` | a reference the app resolves in its secret store, 1 to 1024 bytes of printable ASCII; never the secret itself |

**The record holds no values.** Any signed-in person can list records, so a database URL, a password or a key
never enters the registry. Whoever deploys the app (a person today) passes the values as flags. A setting whose
value is a credential is a `secret_ref`, and its name ends in `_ref`, so the flag that carries it says it carries a
reference: `--database-password-ref=...`.

### What the registry refuses as secret-looking

A **secret-looking word** is, exactly, one of `secret`, `secrets`, `password`, `passwords`, `passwd`,
`passphrase`, `passphrases`, `token`, `credential`, `credentials`, `apikey`, `privatekey`; or two adjacent words
`api key`, `private key`, `access key`, `client secret`. A name is split into words at `_`, `-` and before an
uppercase letter that follows a lowercase one, and each word is lowercased: `client_secret`, `privateKey` and
`DB-Password` each hold one. Plural and compound forms not in the list do not: `max_tokens` and `tokenizer` hold
none.

The checks, by code (all 400):

| code | refused | where it applies |
|---|---|---|
| `secret_field_refused` | an object member with a secret-looking name **that the call's schema does not define** | every object in a Register or Update body. The schema's own members (`token_endpoint_auth_method`, `token_endpoint_auth_signing_alg`) are defined, so they pass; this code exists so a stray `client_secret` is refused with a reason, before it would be `unknown_field` |
| `setting_value_refused` | a member `value`, `values`, `default` or `example` in a setting declaration | `/settings/*` |
| `secret_value_refused` | a string that contains PEM armour (the substring `-----BEGIN `), a JWT-shaped substring (`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`), or a URL with userinfo (`[A-Za-z][A-Za-z0-9+.-]*://[^/?#\s@]+@`) | every string member of a Register or Update body; a Publish `title`, `body` and `link`; an Acknowledge `note`; a Report health `detail` |
| `secret_setting_not_ref` | a setting with a secret-looking `name` whose `type` is not `secret_ref`, or a `secret_ref` whose name does not end in `_ref` | `/settings/*`, checked after the schema |

The message of each names the member's JSON pointer and never repeats the value. Adding a word or a pattern later
is not additive, since a stored record could start to fail; the list grows only with a migration that re-checks
every stored version, and a stored version is never refused on read. [the word list and patterns are decided here]

### Pointer-only entries

A record with no `auth` member is a **pointer-only entry**: a link in the launcher, with a `health_url`, for
something that does not sign people in through the issuer (a static docs site, a service with its own sign-in).

- It has no OIDC client, so it gets no tokens: it cannot publish notifications or push health.
- Its `roles` and `notification_kinds` must be empty (`pointer_only_field`, checked after the schema), because no
  token would carry those roles and nothing could publish those kinds.
- It may declare `settings`: a pointer-only service may still be deployed with flags.
- The registry polls its `health_url` and publishes its `health` notifications like any other app's. Its owner and
  any `registrar` may acknowledge and resolve them.
- An Update may add `auth` later; the client id is still the name. An Update that removes `auth` must also empty
  `roles` and `notification_kinds`; the client is disabled as it is for Retire ([Retire](#retire)), its roles leave
  new tokens, and the app stays listed. Its existing notifications stay as they are; the owner resolves them.
- An Update may change `token_endpoint_auth_method`; it takes effect for new authorizations and tokens.

### The JSON schema

The schema is JSON Schema 2020-12 and holds the rules a schema can say. The rest are checked after it, in the order
of [Validation order](#validation-order): the secret-looking checks, uniqueness of names within the role, kind and
setting arrays, reserved names, `secret_setting_not_ref`, `pointer_only_field`, `environment_id` against the
registry, and the [Text](#text) rules beyond length. How a schema failure becomes an error code is in
[Errors from the schema](#errors-from-the-schema).

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "app_integration_framework/v1/record.schema.json",
  "title": "App registration record, v1",
  "type": "object",
  "additionalProperties": false,
  "required": ["name", "environment_id", "display_name", "description", "url", "owner",
               "roles", "notification_kinds", "health_url", "settings"],
  "properties": {
    "name": {"type": "string", "minLength": 2, "maxLength": 40,
             "pattern": "^[a-z][a-z0-9]*(-[a-z0-9]+)*$"},
    "environment_id": {"type": "string", "minLength": 2, "maxLength": 32,
                       "pattern": "^[a-z][a-z0-9]*(-[a-z0-9]+)*$"},
    "display_name": {"type": "string", "minLength": 1, "maxLength": 64},
    "description": {"type": "string", "minLength": 0, "maxLength": 500},
    "url": {"$ref": "#/$defs/https_url"},
    "owner": {
      "type": "object", "additionalProperties": false, "required": ["person"],
      "properties": {"person": {"type": "string", "minLength": 1, "maxLength": 255,
                                "pattern": "^[!-9;-~]+$"}}
    },
    "auth": {"$ref": "#/$defs/auth"},
    "roles": {"type": "array", "maxItems": 32, "items": {"$ref": "#/$defs/role"}},
    "notification_kinds": {"type": "array", "maxItems": 64, "items": {"$ref": "#/$defs/kind"}},
    "health_url": {"$ref": "#/$defs/https_url"},
    "status_url": {"$ref": "#/$defs/https_url"},
    "settings": {"type": "array", "maxItems": 64, "items": {"$ref": "#/$defs/setting"}}
  },
  "$defs": {
    "member_name": {"type": "string", "minLength": 1, "maxLength": 64,
                    "pattern": "^[a-z][a-z0-9]*(_[a-z0-9]+)*$"},
    "short_text": {"type": "string", "minLength": 1, "maxLength": 200},
    "https_url": {
      "type": "string", "maxLength": 2048,
      "pattern": "^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)*[a-z]([a-z0-9-]{0,61}[a-z0-9])?(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?(/[A-Za-z0-9._~!$&'()*+,;=:/%-]*)?(\\?[A-Za-z0-9._~!$&'()*+,;=:/?%-]*)?$"
    },
    "redirect_uri": {
      "type": "string", "maxLength": 2048,
      "anyOf": [
        {"$ref": "#/$defs/https_url"},
        {"pattern": "^http://(127\\.0\\.0\\.1|\\[::1\\])/[A-Za-z0-9._~!$&'()+,;=:/%-]*(\\?[A-Za-z0-9._~!$&'()+,;=:/?%-]*)?$"}
      ],
      "not": {"pattern": "\\*"}
    },
    "auth": {
      "type": "object",
      "additionalProperties": false,
      "required": ["token_endpoint_auth_method", "grant_types", "redirect_uris"],
      "properties": {
        "token_endpoint_auth_method": {"enum": ["private_key_jwt", "none"]},
        "token_endpoint_auth_signing_alg": {"enum": ["ES256", "EdDSA"]},
        "grant_types": {"type": "array", "minItems": 1, "maxItems": 3, "uniqueItems": true,
                        "items": {"enum": ["authorization_code", "refresh_token", "client_credentials"]}},
        "redirect_uris": {"type": "array", "maxItems": 10, "uniqueItems": true,
                          "items": {"$ref": "#/$defs/redirect_uri"}},
        "jwks_url": {"$ref": "#/$defs/https_url"},
        "removal_notice_url": {"$ref": "#/$defs/https_url"}
      },
      "allOf": [
        {"if": {"properties": {"token_endpoint_auth_method": {"const": "private_key_jwt"}}},
         "then": {"required": ["jwks_url", "token_endpoint_auth_signing_alg"]},
         "else": {"allOf": [{"not": {"required": ["jwks_url"]}},
                            {"not": {"required": ["token_endpoint_auth_signing_alg"]}}]}},
        {"if": {"properties": {"grant_types": {"contains": {"const": "client_credentials"}}}},
         "then": {"properties": {"token_endpoint_auth_method": {"const": "private_key_jwt"}}}},
        {"if": {"properties": {"grant_types": {"contains": {"const": "authorization_code"}}}},
         "then": {"properties": {"redirect_uris": {"minItems": 1}}},
         "else": {"properties": {"redirect_uris": {"maxItems": 0},
                                 "grant_types": {"not": {"contains": {"const": "refresh_token"}}}}}}
      ]
    },
    "role": {
      "type": "object", "additionalProperties": false, "required": ["name", "description"],
      "properties": {
        "name": {"type": "string", "minLength": 1, "maxLength": 32,
                 "pattern": "^[a-z][a-z0-9]*(_[a-z0-9]+)*$"},
        "description": {"$ref": "#/$defs/short_text"}
      }
    },
    "kind": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "default_severity", "description"],
      "properties": {
        "name": {"$ref": "#/$defs/member_name"},
        "default_severity": {"enum": ["info", "warning", "error", "critical"]},
        "description": {"$ref": "#/$defs/short_text"}
      }
    },
    "setting": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "type", "required", "description"],
      "properties": {
        "name": {"$ref": "#/$defs/member_name"},
        "type": {"enum": ["string", "integer", "boolean", "duration", "url", "secret_ref"]},
        "required": {"type": "boolean"},
        "description": {"$ref": "#/$defs/short_text"}
      }
    }
  }
}
```

### A full record

The worked examples use the environment `demo`, the app `ledger`, the person `u7f3k2m9q` and hosts under the
reserved `example` top-level domain.

```json
{
  "name": "ledger",
  "environment_id": "demo",
  "display_name": "Ledger",
  "description": "Expense reports and approvals.",
  "url": "https://ledger.demo.example/",
  "owner": {"person": "u7f3k2m9q"},
  "auth": {
    "token_endpoint_auth_method": "private_key_jwt",
    "token_endpoint_auth_signing_alg": "ES256",
    "grant_types": ["authorization_code", "refresh_token", "client_credentials"],
    "redirect_uris": ["https://ledger.demo.example/auth/callback", "http://127.0.0.1/auth/callback"],
    "jwks_url": "https://ledger.demo.example/.well-known/jwks.json",
    "removal_notice_url": "https://ledger.demo.example/hooks/member-removed"
  },
  "roles": [
    {"name": "viewer", "description": "Reads reports."},
    {"name": "approver", "description": "Approves or rejects reports."},
    {"name": "admin", "description": "Manages cost centres and approval rules."}
  ],
  "notification_kinds": [
    {"name": "export_failed", "default_severity": "error", "description": "A nightly export did not finish."},
    {"name": "approval_overdue", "default_severity": "warning", "description": "A report waited over five days."}
  ],
  "health_url": "https://ledger.demo.example/healthz",
  "status_url": "https://ledger.demo.example/status",
  "settings": [
    {"name": "listen", "type": "string", "required": true, "description": "The address and port the app serves on."},
    {"name": "database_url", "type": "url", "required": true, "description": "The Postgres database, without a password."},
    {"name": "database_password_ref", "type": "secret_ref", "required": true, "description": "The database password in the secret store."},
    {"name": "object_store_url", "type": "url", "required": true, "description": "Where exports are written."},
    {"name": "jobs_url", "type": "url", "required": false, "description": "The job service; nightly exports are off without it."}
  ]
}
```

### A pointer-only record

```json
{
  "name": "docs",
  "environment_id": "demo",
  "display_name": "Docs",
  "description": "The product documentation site.",
  "url": "https://docs.demo.example/",
  "owner": {"person": "u7f3k2m9q"},
  "roles": [],
  "notification_kinds": [],
  "health_url": "https://docs.demo.example/",
  "settings": []
}
```

### Versioning the record

- The record is data. A change to its shape is additive only: a new **optional** member with a stated meaning when
  absent, a new enum value, a new member in a nested object, a new form of `owner`. Never a new required member, a
  renamed or removed member, a changed meaning, a tightened limit (a stored version could stop being valid), or a
  new secret-looking word without a migration that re-checks stored versions.
- Readers (the library, the hub, tools) **ignore** members they do not know in a reply, and show an enum value they
  do not know as text and otherwise skip it.
- The registry **refuses** members it does not know in a write (`unknown_field`). It is the one writer and the gate
  in front of stored data: a member dropped silently would be a lost declaration, and a member stored unread could
  carry a value past the secret checks. So a new member ships in every registry instance of an environment before
  any writer sends it. This is the write side of the rule that formats change additively; no reader refuses stored
  or replied data it does not know. [decided here]
- Every stored version stays readable by every later registry: versions are never rewritten.
- There is no `v2`. The wire and the record grow under `/v1`.

## The four environment settings

Every app takes four settings from its environment, with the same names in every environment, so no host name is in
app code. They are not declared in the record (the names are reserved there); the library parses them.

| setting | flag | value | used for |
|---|---|---|---|
| `issuer_url` | `--issuer-url=URL` | the issuer's identifier, exactly the `iss` of its tokens | the `iss` check, the key set at `{issuer_url}/.well-known/jwks.json`, the [issuer endpoints](#the-issuer) |
| `registry_url` | `--registry-url=URL` | the base URL of the registry | `/v1/apps` calls, and the `resource` and `aud` of tokens for the registry |
| `notifications_url` | `--notifications-url=URL` | the base URL of the notification service | `/v1/notifications` calls, and the `resource` and `aud` of tokens for it |
| `relay_url` | `--relay-url=URL` | the base URL of the relay | the relay calls (their wire is out of scope here) |

The four values are `https` URLs as in [URLs](#urls), with no query and no trailing `/`, and with no `:443`. A base
URL may have a path (`https://central.demo.example/registry`); `/v1/...` is appended to it. Because `iss` and `aud`
are compared byte for byte, the value must be exactly the form the environment's services are configured with: the
library does not normalize it. All four are required: an app without one does not start.

### Flags, never environment variables

- The library reads no environment variable for these four, for its own flags, or for any declared setting. A value
  reaches the app only on its command line. There is no config file.
- Every flag is `--name=value`, the name in lowercase with `-`; only `--help` and `--version` take no value. A bare
  word, any other flag without `=` (a boolean too), an empty value, an unknown flag (`--database_url` with an underscore is unknown), a repeated flag, or a value that
  does not parse as its type is refused at start: the app writes one line naming the flag (never the value) to
  standard error and exits with status 2. The same grammar as [HTTP authentication](http_auth.md#flags).
- The app's flags are exactly the library's own ([below](#the-flags-the-library-owns)) and its declared settings.
  An app knob that is not one of those is declared as a setting; that is what the declaration is for.
- A declared setting with `required: true` that is missing stops the start the same way. One with `required: false`
  that is missing turns its feature off, and the app logs one line naming the flag.

### The flags the library owns

| flag | value |
|---|---|
| `--issuer-url`, `--registry-url`, `--notifications-url`, `--relay-url` | the four environment settings |
| `--client-key-ref` | a `secret_ref` to the app's private signing key for client assertions; required when the record's `auth` uses `private_key_jwt` |
| `--help` | prints every flag with its declaration's description and exits 0; it takes no value |
| `--version` | prints the app's version and exits 0; it takes no value |

These names, with `_` for `-` (`issuer_url`, `registry_url`, `notifications_url`, `relay_url`, `client_key_ref`,
`help`, `version`), are refused as setting names (`reserved_setting`). The library configures `http_auth` itself
from the four settings ([The framework library](#the-framework-library)), so `http_auth`'s flag names are reserved
too: `issuer`, `audience`, `jwks_url`, `jwks_alg`, `accept_typ`, `max_ttl`, `trust_anchor`, `copy_claim`,
`leeway_s` and `jwks_max_stale`.

An app's start line in the `demo` environment:

```text
ledger \
  --issuer-url=https://issuer.demo.example \
  --registry-url=https://registry.demo.example \
  --notifications-url=https://notify.demo.example \
  --relay-url=https://relay.demo.example \
  --client-key-ref=store:ledger/client-key \
  --listen=0.0.0.0:8443 \
  --database-url=postgres://ledger@db.demo.example:5432/ledger \
  --database-password-ref=store:ledger/database \
  --object-store-url=https://objects.demo.example/ledger-exports
```

`--jobs-url` is left out, so nightly exports are off.

## Tokens

The issuer mints JWT access tokens (RFC 9068), header `typ` `at+jwt`, signed RS256 with a key of 2048 to 4096 bits
and a `kid`, valid for 15 minutes. [decided here: RS256 is what `http_auth` verifies today. `at+jwt` is what RFC 9068
requires; `http_auth` accepts only `JWT` today and `at+jwt` is its target, so the framework library depends on that
target landing] One algorithm is used per environment: changing it means reconfiguring every verifier, not adding a
key.

| claim | value |
|---|---|
| `iss` | `issuer_url`, byte for byte |
| `aud` | one string: `registry_url`, `notifications_url`, or `app:{name}` for an app's own API |
| `sub` | a person's subject (never holds `:`); `app:{name}` for an app's service token; `central:{service}` for a central service |
| `client_id` | the client the token was issued to: an app name, `environment` for the built-in client, or a central client id (`central:registry`, `central:notifications`) |
| `app_roles` | a map from an app name to that person's role names on it; the key `environment` holds the environment's own roles: `registrar`, `viewer`, `admin` |
| `exp`, `iat`, `jti` | as RFC 9068; `exp - iat` is 900 |
| `org`, `name`, `email`, `picture` | person tokens only, from the `profile` and `email` scopes |

- **[decided here]** The claim is `app_roles`, not `roles`: RFC 9068 registers `roles` as a list of strings, and a
  map under that name would break a reader that follows the RFC.
- **[decided here]** Token kinds are told apart by `sub`: a person's subject never holds `:`, so `app:` and
  `central:` cannot be a person. No new claim is needed, and a service can never pass for a person. This extends the
  `sub = client_id` that [HTTP authentication](http_auth.md#client-credentials-oauth) describes for client
  credentials: here a service token's `sub` is `app:{client_id}`.
- A person token's `app_roles` holds the person's roles on every active app that has roles, and the `environment`
  key. A retired app's roles are not in it, nor are roles its current record no longer declares.
- An app's service token carries `app_roles: {"<its name>": ["publisher"]}`. Only the app's own service identity
  ever holds `publisher`; there is no grant step, the issuer adds it to every client-credentials token of an active
  app.
- Roles are scoped to the environment: a token from one environment's issuer is refused by every other
  environment's services, because `iss` does not match.
- A verifier allows the clock skew `http_auth` allows (`--leeway-s`, default 30 s).

Who may make each call is written in [The v1 wire](#the-v1-wire) as one of these checks on the token:

| written as | the token must be |
|---|---|
| any signed-in person | a person token |
| `registrar` | a person token with `registrar` in `app_roles.environment` [D3] |
| `viewer` | a person token with `viewer`, `registrar` or `admin` in `app_roles.environment` |
| may act on the notification | a person token that is the app's `owner`, or has any role in `app_roles[app]`, or has `registrar` [D6] |
| the app's `publisher` role | a token whose `sub` is `app:{app}` and whose `app_roles[app]` holds `publisher` |
| `central` | a token whose `sub` is `central:{service}` |

`admin` grants nothing on this wire beyond `viewer`; it is the role that assigns roles to people, which is out of
scope here [D2]. Any `registrar` may update or retire any app: the record's `owner` is not consulted [D3].

### Central identities

The registry, the issuer and the notification service call each other. Each has a **central identity**, `sub`
`central:registry`, `central:issuer` or `central:notifications`, with no `app_roles`. The issuer signs its own
tokens for its calls. The registry and the notification service get theirs by client credentials with
`private_key_jwt`, as an app does, with client ids `central:registry` and `central:notifications` whose key sets
the issuer is given by flag ([Service flags](#service-flags)). A `central` token may:

- call List, Get and History on the registry (they read records: the issuer for clients, the notification service
  for kinds, owners and state);
- Publish a reserved kind (`health`, `removal_failed`) for a named app, with the extra member `app`;
- call Retire-resolve on the notification service ([Retire](#retire)).

[decided here: the proposal has the registry publish `health` and the issuer post removal notices, but gives
neither a credential]

## The issuer

One OIDC issuer per environment [D1]. Paths are under `issuer_url`. Its endpoints follow the RFCs named; their
errors use the RFC's own shapes (RFC 6749 section 5.2 `{"error", "error_description"}`), not the `/v1` error body.

| endpoint | what it does |
|---|---|
| `GET /.well-known/openid-configuration` | OIDC Discovery 1.0 metadata: the endpoints below, `response_types_supported` `["code"]`, `grant_types_supported`, `code_challenge_methods_supported` `["S256"]`, `token_endpoint_auth_methods_supported` `["private_key_jwt", "none"]`, `token_endpoint_auth_signing_alg_values_supported` `["ES256", "EdDSA"]`, `id_token_signing_alg_values_supported` `["RS256"]`, `scopes_supported` |
| `GET /.well-known/jwks.json` | the key set ([Keys](#keys)) |
| `GET /authorize` | authorization code with PKCE (RFC 6749 section 4.1, RFC 7636): `response_type=code`, `client_id`, `redirect_uri`, `state` (required), `code_challenge` with `code_challenge_method=S256` (required; `plain` refused), `scope`, `nonce` (required with `openid`), `resource` |
| `POST /token` | `authorization_code`, `refresh_token` and `client_credentials` grants; client authentication `private_key_jwt` or `none` |
| `POST /revoke` | RFC 7009 revocation of a refresh token; ends that sign-in |

Rules:

- **Scopes.** `openid` (an ID token), `profile` (`name`, `picture`, `org`), `email` (`email`), `offline_access` (a
  refresh token; needs the client's `refresh_token` grant). Unknown scopes are refused (`invalid_scope`). There is no
  userinfo endpoint: the claims are in the tokens.
- **Resource.** Every token request names exactly one `resource` (RFC 8707): `registry_url`, `notifications_url` or
  `app:{name}` of an active app with `auth`. The token's `aud` is that value. A missing, repeated or unknown
  `resource` is `invalid_target`. A refresh request may name another `resource` than the first, so one sign-in gets
  one token per service.
- **Codes.** An authorization code lives 60 seconds and is used once; a second use is refused and revokes the
  tokens the first use issued (RFC 6749 section 4.1.2).
- **Refresh tokens** rotate on every use; using a rotated one revokes the whole sign-in. A sign-in lasts at most
  `--session-max` on the issuer; its value is D12's open session length, and the issuer has no default for it.
- **ID token.** RS256, `aud` the client id, `nonce` echoed, the person claims of the granted scopes, 15 minutes.
- **Client assertions** (`private_key_jwt`, RFC 7523 section 3): `iss` and `sub` the client id, `aud` exactly
  `{issuer_url}/token`, `exp` at most 5 minutes after `iat`, a `jti` the issuer has not seen before `exp`, signed
  with the record's `token_endpoint_auth_signing_alg` by a key in the app's `jwks_url` set.
- **Fetching an app's `jwks_url`:** no redirects followed, 10-second limit, body at most 64 KiB, cached 5 minutes,
  refetched on an unknown `kid` at most once a minute. A set that cannot be fetched fails the token request
  (`invalid_client`).
- **Clients come from the registry.** The issuer reads an app's current record (Get, as `central:issuer`) when it
  needs the client, and caches it for at most 30 seconds. The registry is the only source of truth: there is no
  separate client store to keep in step, so a Register, an Update or a Retire takes effect at the issuer within
  30 seconds. Register needs no call to the issuer and cannot half-succeed. [decided here]
- **Retired apps and removed people.** A retired app, or one without `auth`, gets no new code or token, and its
  refresh tokens stop working at their next use. A removed person's sign-ins are revoked.

### Bootstrap

The issuer has one built-in public client, `environment`: `token_endpoint_auth_method` `none`, grants
`authorization_code` and `refresh_token`, redirect URIs `http://127.0.0.1/callback` and `http://[::1]/callback`.
Command-line tools sign in through it. It has no record, and `environment` is reserved as an app name so none can
take it. The issuer flag `--bootstrap-registrar=SUB` gives that one person `registrar` and `admin` in
`app_roles.environment`; it is how the first record (the hub's) is registered before any role can be assigned.
[decided here]

### Keys

`GET {issuer_url}/.well-known/jwks.json`, no token. The reply is a JWK Set (RFC 7517) that `jwks` parses: each key
has `kty` `RSA`, `kid`, `use` `sig`, `alg` `RS256`, `n` and `e`. The reply carries `Cache-Control: max-age=300`.
A new key is in the set at least 10 minutes (twice `max-age`) before its first token, and stays at least 15 minutes
and 60 seconds after its last (the token lifetime plus twice the default leeway), so a verifier that refreshes on an
unknown `kid` never refuses a good token. Rotation is the issuer operator's step; this document sets no schedule.

```json
{
  "keys": [
    {"kty": "RSA", "kid": "rs-2026-12-a", "use": "sig", "alg": "RS256",
     "n": "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
     "e": "AQAB"}
  ]
}
```

### Removal notice

When a person is removed from the environment (how that happens is out of scope), the issuer posts a signed notice
to the `removal_notice_url` of every active app that has one.

- The body is one compact JWS, `Content-Type: application/jwt`, signed with the issuer's key, header `typ`
  `removal-notice+jwt`, so it can never pass for an access token (RFC 8725 section 3.11).
- Its claims: `iss` (`issuer_url`), `aud` (the app's name), `sub` (the person removed), `removed_at` (a timestamp),
  `iat`, `exp` (`iat` + 300), `jti`. Each attempt is signed afresh, with a new `iat` and `exp` and the same `jti`, so
  a notice is accepted only for 5 minutes after it was sent and a retry is still the same notice.
- The app verifies it with `jose` directly, not through the bearer middleware (an `http_auth` trust anchor pins one
  `typ`): signature against the issuer's key set, `typ`, `iss`, `aud`, `exp` with the default leeway, and it acts
  once per `jti`. The library does this ([The framework library](#the-framework-library)). The app replies 2xx when
  it has taken the notice; its reply body is ignored.
- Any other reply, a redirect (never followed), or no reply in 10 seconds is a failure. The issuer tries again after
  1 minute, then doubling to once an hour, for 7 days, keeping the pending notices in its store so a restart
  resumes them. It stops early when the app is retired or its `removal_notice_url` is removed; a changed URL is used
  from the next attempt.
- After 7 days of failures the issuer publishes `removal_failed` for the app, severity `error`, `dedupe_key`
  `removal:{jti}`, as `central:issuer`. The owner or a `registrar` resolves it. [decided here]

```json
{
  "iss": "https://issuer.demo.example",
  "aud": "ledger",
  "sub": "u4n8w2c6x",
  "removed_at": "2026-12-04T16:03:00.000Z",
  "iat": 1796400180,
  "exp": 1796400480,
  "jti": "rn_01M90WPTS0D9M3P6R8T1V4X7Z0"
}
```

## The v1 wire

HTTP/JSON over HTTPS. Every path is under the base URL of its service: `/v1/apps` under `registry_url`,
`/v1/notifications` under `notifications_url`.

**Common to every call.**

- A request body is UTF-8 JSON, one object, with `Content-Type: application/json` (an optional `; charset=utf-8`,
  any case, is accepted). Another content type is 415 `unsupported_media_type`. A body over its limit is 413
  `body_too_large`: 256 KiB for Register and Update, 64 KiB for every other call, counted in bytes after any
  transfer coding is removed, and refused as soon as the count passes the limit. A body that is not one JSON object
  is `invalid_json`; duplicate object keys are `duplicate_key` (`json.refuse_duplicate_keys`).
- A call that takes no body accepts an empty body (with any or no content type) or `{}`. Any member is
  `unknown_field`.
- Paths match exactly: no trailing `/`, case as written. A `{name}` that does not match the name grammar is 404
  `app_not_found`; a notification `{id}` that does not match the id grammar is 404 `notification_not_found`. A path
  that exists with a method it does not take (`HEAD` and `OPTIONS` included) is 405 with `Allow`.
- There are no CORS headers: browser code reaches these calls through its own app's server. Adding CORS later is
  additive. [decided here]
- Query parameters are for `GET` calls only. Each appears at most once; a repeated, empty or unknown parameter, or a
  parameter on a `POST`, `PUT` or `DELETE`, is `invalid_param`.
- Timestamps are RFC 3339 in UTC, exactly `YYYY-MM-DDTHH:MM:SS.mmmZ`: `2026-11-30T09:15:02.118Z`. A query
  parameter in another form is `invalid_param`.
- **Lists are paged.** Every list call takes `?limit=` (1 to 200, default 50) and `?cursor=`, and its reply carries
  `next_cursor`: a string, or `null` exactly when no item follows. A cursor is opaque, valid for 24 hours, and
  belongs to one call with the same filters; another is `invalid_cursor`. Paging is by a key that does not change
  (named per call), so a page never repeats or skips an item that existed when the first page was read.
- Every JSON reply body of a 2xx carries `environment_id`, the environment that served it. 204 replies have no body.
- v1 sets no rate limits and no quotas. A service that cannot serve replies 503 `unavailable`.

A record in a reply is wrapped in a **version envelope**:

| member | value |
|---|---|
| `version` | the record's version, from 1 up, one per change |
| `state` | `active` or `retired` |
| `changed_by` | `{"person": SUB}` |
| `changed_at` | the timestamp of this version |
| `health` | the current health, on List and Get of the current version only: `{"state", "since"}`, `state` one of `unknown`, `up`, `degraded`, `down` ([Health](#health)) |
| `record` | the record as stored at that version |

### Calls

| call | method and path | who | request | reply | idempotent |
|---|---|---|---|---|---|
| Register | `POST /v1/apps` | `registrar` | the record | 201, the envelope of version 1 | an identical repeat is 200 |
| Update | `PUT /v1/apps/{name}` | `registrar` | `{"base_version", "record"}` | 200, the new envelope | see [the base_version rule](#the-base_version-rule) |
| Retire | `DELETE /v1/apps/{name}` | `registrar` | none | 204 | a repeat is 204 |
| List | `GET /v1/apps` | any signed-in person, `central` | `?include_retired=` | 200, `{"apps", "next_cursor"}` | read |
| Get | `GET /v1/apps/{name}` | any signed-in person, `central` | `?version=` | 200, one envelope | read |
| History | `GET /v1/apps/{name}/versions` | `viewer`, `central` | none | 200, `{"versions", "next_cursor"}` | read |
| Report health | `POST /v1/apps/{name}/health` | the app's `publisher` role | `{"state", "detail"}` | 204 | yes |
| Publish | `POST /v1/notifications` | the app's `publisher` role; `central` for reserved kinds | `kind`, `severity`, `title`, `body`, `link`, `dedupe_key`, `resolve` | 201 new, 200 existing: `{"id", "state"}` | with a `dedupe_key` |
| Acknowledge | `POST /v1/notifications/{id}/ack` | may act on the notification | `{"note"}` optional | 200, the notification | a repeat is 200, unchanged |
| Resolve | `POST /v1/notifications/{id}/resolve` | may act on the notification | none | 200, the notification | a repeat is 200, unchanged |
| List inbox | `GET /v1/notifications` | any signed-in person | `?state=`, `?app=`, `?min_severity=` | 200, `{"notifications", "next_cursor"}` | read |
| Query history | `GET /v1/notifications/history` | any signed-in person | `?app=`, `?kind=`, `?from=`, `?to=` | 200, `{"notifications", "next_cursor"}` | read |
| Retire-resolve | `POST /v1/notifications/apps/{name}/retire` | `central` | none | 204 | a repeat is 204 |
| Keys | `GET {issuer_url}/.well-known/jwks.json` | public | none | 200, the issuer's JWK Set | read |

Retire-resolve is the one call this document adds to the proposal's list: it is how Retire resolves the app's
notifications in another service ([Retire](#retire)). [decided here]

### Register

The registry checks the record ([Validation order](#validation-order)) and stores it as version 1. Nothing else is
called: the issuer reads the new client from the registry ([The issuer](#the-issuer)).

- A `name` that exists and is active, with a record equal to its current version: 200 with the current envelope,
  and nothing changes. A retry after a lost reply is safe.
- A `name` that exists and is active, with a different record: 409 `name_taken`.
- A `name` that was retired: 409 `name_retired`.
- Two Registers of one name at once: the store makes one version 1; the other is then one of the cases above.

Records are equal when they are equal as JSON values: the same members with equal values, arrays in the same
order, strings code point for code point (they are NFC, [Text](#text)).

```http
POST /v1/apps HTTP/1.1
Host: registry.demo.example
Authorization: Bearer eyJhbGciOi...
Content-Type: application/json

{ ...the full record above... }
```

```json
{
  "environment_id": "demo",
  "version": 1,
  "state": "active",
  "changed_by": {"person": "u7f3k2m9q"},
  "changed_at": "2026-11-30T09:15:02.118Z",
  "record": {"name": "ledger", "environment_id": "demo", "...": "the record as sent"}
}
```

### Update

The request is `{"base_version": n, "record": {...}}`: `base_version` is the version the caller read and changed.
The whole record is replaced; there is no patch.

- `record.name` must equal `{name}` (`name_mismatch`); `record.environment_id` must equal the registry's id
  (`environment_mismatch`), which is also the stored one, so it cannot change.
- An Update of a retired app is 409 `app_retired`, whatever well-formed `base_version` it sends. This is checked before the
  base_version rule, so a retried Update that arrives after a Retire gets `app_retired`, not 200.
- Every write to one record (Update or Retire) is a compare-and-swap on its current version: two writes at once
  are applied one after the other, and the second is judged against the version the first made.
- A change to `auth`, the roles or the kinds reaches the issuer and the notification service within 30 seconds
  (their cache). Tokens already minted live out their 15 minutes.

#### The base_version rule

`base_version` is required and is an integer of at least 1; anything else is refused by the schema step (`missing_field`
or `invalid_value`, `field` `/base_version`). The rest is checked after the app is known to exist and be active:

| `base_version` | submitted record | reply |
|---|---|---|
| above the current version | any | 400 `invalid_value`, `field` `/base_version` |
| equals the current version | differs from the current record | 200, the new version `n + 1` |
| equals the current version | equals the current record | 200, the current envelope; no new version |
| is older than the current version | equals the current record | 200, the current envelope (the change already happened: a retry after a lost reply) |
| is older than the current version | differs from the current record | 409 `version_conflict` with `current_version` |

On a 409 the caller reads the current version (Get), applies its change to it and sends it again with the new
`base_version`. [the retry rows are decided here]

```json
{
  "base_version": 1,
  "record": {"name": "ledger", "...": "the full record, with one more redirect URI"}
}
```

```json
{
  "environment_id": "demo",
  "version": 2,
  "state": "active",
  "changed_by": {"person": "u7f3k2m9q"},
  "changed_at": "2026-12-02T14:40:51.006Z",
  "record": {"name": "ledger", "...": "the record as sent"}
}
```

A conflict:

```json
{
  "error": {
    "code": "version_conflict",
    "message": "the record changed since version 1; read version 3 and send the change again",
    "current_version": 3
  }
}
```

### Retire

Retire stores a new version with `state` `retired` and the record unchanged. From then:

- the issuer stops issuing to the app within 30 seconds, and its roles leave new tokens;
- List leaves it out unless `?include_retired=true`, so it drops from the launcher;
- the registry stops polling it;
- the registry calls Retire-resolve on the notification service, which resolves the app's `open` and
  `acknowledged` notifications with the note `app retired`, by `{"central": "registry"}`. The retired version is
  stored first and marked as not yet resolved; the registry repeats the call, after 1 minute and then doubling to
  once an hour, until it gets a 2xx, and resumes after a restart. Retire-resolve is idempotent.
- a Publish or Report health with a token minted before Retire gets 409 `app_retired`.

Its versions and its notifications stay. A repeat Retire is 204 and adds no version; Retire of an unknown name is
404 `app_not_found`.

```http
DELETE /v1/apps/ledger HTTP/1.1
Host: registry.demo.example
Authorization: Bearer eyJhbGciOi...
```

The reply is `204 No Content` with no body.

### List

Current versions of active records, sorted by `name` (the paging key). `?include_retired=true` adds retired ones;
the default is `false`; any other value is `invalid_param`.

```json
{
  "environment_id": "demo",
  "apps": [
    {"version": 1, "state": "active", "changed_by": {"person": "u7f3k2m9q"},
     "changed_at": "2026-11-30T09:20:44.310Z", "health": {"state": "up", "since": "2026-11-30T09:21:40.002Z"},
     "record": {"name": "docs", "...": "the record"}},
    {"version": 2, "state": "active", "changed_by": {"person": "u7f3k2m9q"},
     "changed_at": "2026-12-02T14:40:51.006Z", "health": {"state": "up", "since": "2026-11-30T09:16:01.550Z"},
     "record": {"name": "ledger", "...": "the record"}}
  ],
  "next_cursor": null
}
```

### Get

The current version, retired or not, with `health`. `?version=n` (digits, no sign, no leading zero, at least 1)
reads version `n`, without `health`; a version that does not exist is 404 `version_not_found`; any other value is
`invalid_param`.

```http
GET /v1/apps/ledger?version=1 HTTP/1.1
Host: registry.demo.example
Authorization: Bearer eyJhbGciOi...
```

The reply is one envelope, as under Register.

### History

Every version of one record, oldest first (the paging key is `version`), each as an envelope without `health`.

```json
{
  "environment_id": "demo",
  "versions": [
    {"version": 1, "state": "active", "changed_by": {"person": "u7f3k2m9q"},
     "changed_at": "2026-11-30T09:15:02.118Z", "record": {"name": "ledger", "...": "the record"}},
    {"version": 2, "state": "active", "changed_by": {"person": "u7f3k2m9q"},
     "changed_at": "2026-12-02T14:40:51.006Z", "record": {"name": "ledger", "...": "the record"}}
  ],
  "next_cursor": null
}
```

### Report health

The app pushes its own state. `{name}` must be the app the token names (`sub` `app:{name}`), or 403 `wrong_app`.
`state` is `up`, `degraded` or `down` (required); `detail` is optional one-line text of 1 to 500 code points. The
reply is 204. [Health](#health) says what the registry does with it.

```json
{"state": "degraded", "detail": "export queue is 40 minutes behind"}
```

### Publish

| member | type | when `resolve` is false or absent | when `resolve` is true |
|---|---|---|---|
| `kind` | string | required: a kind the app's current record declares (`unknown_kind`) | required |
| `severity` | string | optional: `info`, `warning`, `error` or `critical`; default the kind's `default_severity` | refused (`field_not_allowed`) |
| `title` | string | required: 1 to 120 code points, one line | refused |
| `body` | string | optional: 0 to 2000 code points | optional: the resolve note, 1 to 500 code points |
| `link` | string | optional: a URL as in [URLs](#urls) | refused |
| `dedupe_key` | string | optional | required |
| `resolve` | boolean | optional, default `false` | `true` |
| `app` | string | only with a `central` token: the app it publishes for | same |

A `dedupe_key` is 1 to 128 characters of `A-Z a-z 0-9 . _ : -`. The producer is the app in the token; an app's
Publish never names another app (`app` with an app token is `field_not_allowed`). The kinds `health` and
`removal_failed` are published only with a `central` token (an app gets `reserved_kind`); they are not declared in
any record. Severity order is `info` < `warning` < `error` < `critical`.

The **dedupe scope** is (environment, app, kind, `dedupe_key`). All publishes in one scope are applied one at a time,
in the order the service receives them. What happens:

1. **`resolve: true`.** Every notification in the scope that is `open` or `acknowledged` becomes `resolved`, by
   `{"app": NAME}` (or `{"central": SERVICE}`), with `body` as the note. The reply is 200 with the newest of them
   (by `first_seen_at`, then `id`). If none is open or acknowledged and the scope has a resolved one, the reply is
   200 with the newest and nothing changes. If the scope was never used: 404 `no_open_notification`.
2. **The scope has an `open` notification** (at most one is ever open): it is updated. `count` goes up by one (it
   stops at 2<sup>53</sup> − 1), `last_seen_at` is now, `title`, `body` and `link` take the new values (an absent
   `body` or `link` becomes `null`: a repeat states the whole alert), and `severity` becomes the higher of the stored
   one and this publish's (given or default). [decided here: a repeat never lowers an alert's severity without a
   resolve] Recipients do not change. The reply is 200 with `state` `open`.
3. **Otherwise** a new notification is made, `open`, `count` 1. A scope whose notification is `acknowledged` gets a
   new one too, and the acknowledged one stays as it was, so a scope can hold several acknowledged notifications.
   The reply is 201. A Publish without a `dedupe_key` always makes a new notification.

A Publish without a `dedupe_key` that is retried after a lost reply makes a second notification; a producer that
retries sets one.

**Recipients** are worked out when a notification is made: in v1, the app's `owner`. Subscriptions by kind and
severity add more later [D4]. A notification whose owner has been removed is still made, and is reachable through
history.

```json
{
  "kind": "export_failed",
  "title": "Nightly export did not finish",
  "body": "The export of cost centre 4100 stopped after 3 of 12 files.",
  "link": "https://ledger.demo.example/exports/9921",
  "dedupe_key": "export:9921"
}
```

```json
{"environment_id": "demo", "id": "demo:01M8WT2WGMQ4X2M8N5R3T6V9W0", "state": "open"}
```

The resolve, later:

```json
{"kind": "export_failed", "dedupe_key": "export:9921", "resolve": true, "body": "Rerun finished."}
```

```json
{"environment_id": "demo", "id": "demo:01M8WT2WGMQ4X2M8N5R3T6V9W0", "state": "resolved"}
```

### The notification object

| member | value |
|---|---|
| `id` | `{environment_id}:{26 characters of 0-9 A-H J K M N P-T V-Z}`, unique across environments; opaque past the `:` |
| `environment_id`, `app`, `kind`, `severity`, `title`, `body`, `link`, `dedupe_key` | as published; absent optional members are `null` |
| `state` | `open`, `acknowledged` or `resolved` |
| `count` | how many publishes this notification holds, from 1 |
| `first_seen_at`, `last_seen_at` | the first and the latest publish |
| `acknowledged` | `null`, or `{"by": ACTOR, "at", "note"}` |
| `resolved` | `null`, or `{"by": ACTOR, "at", "note"}` |

An `ACTOR` is `{"person": SUB}`, `{"app": NAME}` or `{"central": SERVICE}`. A `note` is a string or `null`.

### Acknowledge

The body is empty, `{}`, or `{"note": TEXT}`, the note 1 to 500 code points.

The notification is looked up before the caller's right to act on it, since that right depends on its app: an
unknown id, or one of another environment, is 404 `notification_not_found`; then a caller who may not act on it is
403 `role_missing`. Every signed-in person can read every notification through history, so the order leaks nothing.

- `open` becomes `acknowledged`, with who, when and the note.
- An `acknowledged` notification: 200, unchanged; the first acknowledgement stays. No note is required for a repeat.
- A `resolved` notification: 409 `notification_resolved`.
- An `open` `critical` notification without a note: 400 `note_required`. [D6]

```json
{"note": "Looking at it; the export host ran out of disk."}
```

```json
{
  "environment_id": "demo",
  "id": "demo:01M8WT2WGMQ4X2M8N5R3T6V9W0",
  "app": "ledger",
  "kind": "export_failed",
  "severity": "error",
  "title": "Nightly export did not finish",
  "body": "The export of cost centre 4100 stopped after 3 of 12 files.",
  "link": "https://ledger.demo.example/exports/9921",
  "dedupe_key": "export:9921",
  "state": "acknowledged",
  "count": 2,
  "first_seen_at": "2026-12-03T02:00:11.540Z",
  "last_seen_at": "2026-12-03T02:30:12.004Z",
  "acknowledged": {"by": {"person": "u7f3k2m9q"}, "at": "2026-12-03T07:48:30.221Z",
                   "note": "Looking at it; the export host ran out of disk."},
  "resolved": null
}
```

### Resolve

No body. The lookup and the right to act are checked as for Acknowledge. `open` or `acknowledged` becomes
`resolved` by the person, with a `null` note. A repeat on a `resolved` notification is 200 and changes nothing. The
reply is the notification, as under Acknowledge, with `state` `resolved` and `resolved` set. A person may resolve a
`health` notification while the app is still down; the registry publishes a new one only on the app's next change
to `down`.

```http
POST /v1/notifications/demo:01M8WT2WGMQ4X2M8N5R3T6V9W0/resolve HTTP/1.1
Host: notify.demo.example
Authorization: Bearer eyJhbGciOi...
```

### List inbox

The caller's notifications: those they are a recipient of. Newest first, paged by (`first_seen_at`, `id`)
descending, a key that a repeat publish does not change.

| parameter | value | default |
|---|---|---|
| `state` | `open`, `acknowledged`, `resolved` or `active` (open and acknowledged) | `active` |
| `app` | an app name; one that does not exist gives an empty list | every app |
| `min_severity` | a severity; that level and above | `info` |

```http
GET /v1/notifications?state=active&min_severity=error HTTP/1.1
Host: notify.demo.example
Authorization: Bearer eyJhbGciOi...
```

```json
{
  "environment_id": "demo",
  "notifications": [{"id": "demo:01M8WT2WGMQ4X2M8N5R3T6V9W0", "...": "the notification object"}],
  "next_cursor": null
}
```

### Query history

Every notification of the environment that matches, oldest first, paged by (`first_seen_at`, `id`). Each carries
`changes`: every state change in order, as `{"state", "by", "at", "note"}`, the first being `open` by its producer.
A repeat publish is not a state change; `count` and `last_seen_at` show it. History is never edited.

- `from` and `to` bound `first_seen_at`, `from` inclusive and `to` exclusive, each optional. `from` at or after
  `to` is `invalid_param`. An `app` or `kind` that does not exist gives an empty list.
- Any signed-in person may read the environment's whole history, as they may list every record. [proposal, D12:
  notifications are operational alerts, readable by everyone signed in to the environment; a producer puts no
  personal data in them] How long history is kept is D5.

```http
GET /v1/notifications/history?app=ledger&kind=export_failed&from=2026-12-01T00:00:00.000Z&to=2026-12-08T00:00:00.000Z HTTP/1.1
Host: notify.demo.example
Authorization: Bearer eyJhbGciOi...
```

```json
{
  "environment_id": "demo",
  "notifications": [
    {
      "id": "demo:01M8WT2WGMQ4X2M8N5R3T6V9W0",
      "app": "ledger",
      "kind": "export_failed",
      "state": "resolved",
      "...": "the rest of the notification object",
      "changes": [
        {"state": "open", "by": {"app": "ledger"}, "at": "2026-12-03T02:00:11.540Z", "note": null},
        {"state": "acknowledged", "by": {"person": "u7f3k2m9q"}, "at": "2026-12-03T07:48:30.221Z",
         "note": "Looking at it; the export host ran out of disk."},
        {"state": "resolved", "by": {"app": "ledger"}, "at": "2026-12-03T09:02:47.893Z", "note": "Rerun finished."}
      ]
    }
  ],
  "next_cursor": null
}
```

## Health

How the registry knows an app is up. [proposal, D10]

**Poll.** One poller per environment (the registry instance that holds the poller lease in its store) sends
`GET {health_url}` with no token, from inside the app's environment. It starts a poll every 60 seconds from the
start of the last one, the first within 60 seconds of Register or of the poller starting. [the 60 seconds is
inferred; the rest is decided here] A poll's result:

| reply | result |
|---|---|
| 2xx in 2 seconds or less, and not a JSON `degraded` reply (next row) | success |
| 2xx in over 2 seconds, up to 10; or a 2xx with `Content-Type: application/json` whose body (read up to 4 KiB) is `{"state": "degraded"}` | degraded |
| any other status (a redirect included: none is followed), a TLS or connection failure, or no complete reply in 10 seconds | failure |

**Push.** An app may push its state instead ([Report health](#report-health)). While the latest push is under
3 minutes old the registry does not poll that app; when pushes stop for 3 minutes, polling starts again and the
failure count starts from zero.

**State.** The state is held by the poller, in memory; a new poller starts every app at `unknown`.

| from | event | to | notification |
|---|---|---|---|
| any | a success, or a push of `up` | `up` | resolve the open `health` notification, if any |
| any | a degraded result, or a push of `degraded` | `degraded` | resolve the open `health` notification, if any (the app is serving) |
| `unknown`, `up`, `degraded` | a failure, the third in a row | `down` | publish `health` |
| `unknown`, `up`, `degraded` | a failure, the first or second in a row | unchanged | none |
| any but `down` | a push of `down` | `down` | publish `health` |
| `down` | a failure, or a push of `down` | `down` | none |

The `health` notification is published as `central:registry` for the app: kind `health`, severity `error`,
`dedupe_key` the app's name, title `{display_name} is down`, `link` the app's `status_url` or else its `url`. A
retired app is not polled.

## Errors

Every `/v1` reply with a status of 400 or above has a JSON body of one member, `error`, an object. This is the
envelope [HTTP authentication](http_auth.md#failure-modes-at-the-service) gives as the target for every komira
service, so the 401, 400 and 503 replies its middleware writes before the call runs take the same shape.

| member | value |
|---|---|
| `code` | a stable lowercase code from the table below |
| `message` | English text for a person. Not stable, never parsed. It never holds a token, a submitted value or a secret |
| `field` | optional: the RFC 6901 JSON Pointer of the request member at fault (`/auth/redirect_uris/1`) |
| `param` | optional: the query parameter at fault (`version`) |
| `current_version` | with `version_conflict` only: the record's current version |

A 401 carries `WWW-Authenticate`: a bare `Bearer` challenge for `missing_token`, and
`Bearer error="invalid_token"` for `invalid_token`, with no detail of why (RFC 6750 section 3.1). A 503 carries
`Retry-After`, 1 to 300 seconds. A client that meets a code it does not know acts on the status alone, so a new code
is additive. The issuer's OAuth endpoints use RFC 6749's error shape instead ([The issuer](#the-issuer)).

| status | code | when |
|---|---|---|
| 400 | `invalid_request` | the `Authorization` header is malformed or there is more than one credential |
| 400 | `invalid_json` | the body is not one UTF-8 JSON object |
| 400 | `duplicate_key` | an object in the body has a key twice |
| 400 | `secret_field_refused` | an undefined member has a secret-looking name ([What the registry refuses](#what-the-registry-refuses-as-secret-looking)) |
| 400 | `setting_value_refused` | a setting declaration carries a value |
| 400 | `secret_value_refused` | a string looks like a credential |
| 400 | `unknown_field` | a member the call does not define |
| 400 | `missing_field` | a required member is absent |
| 400 | `invalid_value` | a member has the wrong type, breaks its grammar or limits, or breaks a cross-member rule |
| 400 | `duplicate_entry` | two grant types, redirect URIs, roles, kinds or settings are the same |
| 400 | `reserved_name` | the app name `environment` |
| 400 | `reserved_role` | a role named `publisher` |
| 400 | `reserved_kind` | a kind named `health` or `removal_failed`, declared, or published with an app token |
| 400 | `reserved_setting` | a setting named after a [library flag](#the-flags-the-library-owns) or an `http_auth` flag |
| 400 | `secret_setting_not_ref` | a secret-looking setting is not a `secret_ref`, or a `secret_ref` name does not end in `_ref` |
| 400 | `pointer_only_field` | a record without `auth` declares roles or notification kinds |
| 400 | `environment_mismatch` | `environment_id` is not the registry's |
| 400 | `name_mismatch` | the record's `name` is not the path's |
| 400 | `unknown_kind` | a Publish of a kind the record does not declare |
| 400 | `field_not_allowed` | a member this form of the call refuses (`title` with `resolve: true`, `app` with an app token) |
| 400 | `note_required` | an Acknowledge of an open `critical` notification without a note |
| 400 | `invalid_param` | a query parameter is unknown, repeated, empty, out of its range, or on a call that takes none |
| 400 | `invalid_cursor` | the cursor is expired or is not one this call with these filters issued |
| 401 | `missing_token` | no `Authorization: Bearer` header |
| 401 | `invalid_token` | the token failed any check (signature, `iss`, `aud`, `exp`, `typ`, algorithm) |
| 403 | `role_missing` | the token lacks the right the call needs; the message names it |
| 403 | `wrong_app` | an app's token acts for another app (`/v1/apps/{name}/health` of another name) |
| 404 | `route_not_found` | no such path |
| 404 | `app_not_found` | no record with that name, or a name that breaks the grammar |
| 404 | `version_not_found` | the record has no such version |
| 404 | `notification_not_found` | no notification with that id in this environment, or an id that breaks the grammar |
| 404 | `no_open_notification` | a resolve publish in a scope never used |
| 405 | `method_not_allowed` | the path exists and the method does not; `Allow` lists the methods |
| 409 | `version_conflict` | an Update's `base_version` is older and its record differs |
| 409 | `name_taken` | a Register of an active name with a different record |
| 409 | `name_retired` | a Register of a retired name |
| 409 | `app_retired` | an Update, Publish or Report health for a retired app |
| 409 | `notification_resolved` | an Acknowledge of a resolved notification |
| 413 | `body_too_large` | the body is over its limit |
| 415 | `unsupported_media_type` | a body with a content type other than JSON |
| 500 | `internal` | a fault in the service |
| 503 | `unavailable` | the service cannot serve now (its store is down, or the issuer's key set is past its stale bound) |

An example:

```json
{
  "error": {
    "code": "secret_value_refused",
    "message": "the member holds a value that looks like a credential; pass credentials as a secret_ref setting",
    "field": "/settings/1/description"
  }
}
```

### Errors from the schema

A schema failure maps to one code, with `field` the pointer of the member at fault:

| schema keyword | code | `field` points at |
|---|---|---|
| `additionalProperties` | `unknown_field` | the unknown member |
| `required`, and the `then` of a conditional that requires a member | `missing_field` | the absent member (`/auth/jwks_url`) |
| `uniqueItems` | `duplicate_entry` | the second of the two equal items |
| `type`, `enum`, `const`, `pattern`, `minLength`, `maxLength`, `minItems`, `maxItems`, `not` | `invalid_value` | the member |
| the other conditionals of `auth` | `invalid_value` | the member the rule names: `/auth/token_endpoint_auth_method` for `client_credentials` with `none`, `/auth/redirect_uris` for redirect URIs without `authorization_code`, `/auth/grant_types` for `refresh_token` without it, the refused member for `jwks_url` or the signing algorithm with `none` |

### Validation order

A request is checked in this order, and the reply names the first failure only, so the same bad request always
gets the same error:

1. the route and method (404 `route_not_found`, 405);
2. the token (400 `invalid_request`, 401);
3. for a call on a notification `{id}`: the lookup (404); for a call on `{name}` other than Register: the name
   grammar (404 `app_not_found`);
4. the right to make the call (403);
5. the query parameters (`invalid_param`, `invalid_cursor`);
6. the body: its content type (415), its size (413), then JSON and duplicate keys;
7. the secret checks: `secret_field_refused`, then `setting_value_refused`, then `secret_value_refused`, each over
   the body in document order;
8. the schema of the call, object by object from the root in document order: in each object, first its unknown
   members (in body order), then its missing required members (in the order of its table), then each present
   member in the order of its table (an object member or array item is checked fully before the next), then the
   object's conditionals in schema order;
9. the rules beyond the schema: the [Text](#text) rules, `duplicate_entry` for names, `reserved_name`,
   `reserved_role`, `reserved_kind`, `reserved_setting`, `secret_setting_not_ref`, `pointer_only_field`,
   `field_not_allowed`;
10. the match with the path and the environment (`name_mismatch`, `environment_mismatch`);
11. the stored state: `app_not_found`, then `app_retired` (Update, Publish, Report health), then `name_taken` or
    `name_retired` (Register), then the base_version rule, `unknown_kind`, `no_open_notification`, and the
    notification's state (`notification_resolved`, `note_required`).

The right to call comes before the body, so a caller without it learns nothing about what a body would have been
refused for.

## The framework library

The Mojo library an app links. Its operations, by what they do; the names are the ones the library uses. [proposal,
D12]

| operation | what it does |
|---|---|
| `AppFlags.parse(args, declaration)` | parses the command line against the library's flags and the app's declared settings ([Flags](#flags-never-environment-variables)); refuses as there; gives typed values (`get_string`, `get_integer`, `get_boolean`, `get_duration`, `get_url`, `get_secret_ref`), an absent optional one as no value |
| `token_verifier(flags, app_name)` | a `http_auth` verifier for the app's own API: issuer and JWKS from `issuer_url`, audience `app:{name}`, algorithm `RS256`, `typ` `at+jwt` (an `http_auth` target), maximum lifetime 900 s, leeway 30 s, `app_roles` copied into the principal |
| `ServiceTokens` | the app's own tokens by client credentials (`oauth` `ClientCredentialSource`), one per `resource`, signed with the key `--client-key-ref` names; a token is reused until 60 seconds before its `exp`, and concurrent callers share one fetch |
| `publish(notification)` | Publish with a service token for `notifications_url` |
| `report_health(state, detail)` | Report health with a service token for `registry_url` |
| `client_jwks()` | the public JWK Set of the app's signing key, for the app to serve at its `jwks_url` |
| `removal_notice(body)` | verifies a [removal notice](#removal-notice) and returns the person removed and the `jti`, or a typed refusal; the app keeps the `jti`s it has acted on |

What the library does on each reply of its own calls:

| reply | Publish with a `dedupe_key`, Report health | Publish without a `dedupe_key` |
|---|---|---|
| 2xx | done | done |
| 401 | drop the cached token, get a new one, send once more | same |
| 500, 503, a connection failure, no reply in 10 seconds | send again after 1 s, doubling to 60 s, or after `Retry-After` when it is longer; 5 attempts in all | not sent again (a second send could make a second notification) |
| any other 4xx, 409 | a typed error naming the `code`; not sent again | same |

## Service flags

The central services take their configuration as flags too. Each refuses at start, with exit status 2, what an
app's library refuses.

| service | flags |
|---|---|
| all three | `--environment-id=ID`, `--issuer-url=URL`, `--listen=ADDRESS`, `--store-url=URL` and `--store-password-ref=REF` for its own store |
| registry | `--registry-url=URL` (its own base URL, its `aud`), `--notifications-url=URL`, `--client-key-ref=REF` (its `central:registry` key) |
| notification service | `--notifications-url=URL` (its own base URL, its `aud`), `--registry-url=URL`, `--client-key-ref=REF` |
| issuer | `--signing-key-ref=REF` (repeated, one per key in the set; the first signs), `--registry-url=URL`, `--notifications-url=URL`, `--central-jwks-url=registry=URL` and `--central-jwks-url=notifications=URL`, `--session-max=DURATION`, `--bootstrap-registrar=SUB`; the identity provider's flags are out of scope |

## Compatibility

- The wire, the record and the notification object follow [Versioning the record](#versioning-the-record): additive
  only under `/v1`; readers ignore unknown reply members; error codes and enum values only grow.
- A shipped implementation names its cross-version test: the registry reads a corpus of every record shape any
  release wrote, and an earlier library reads the replies of the current services. This document ships no
  implementation, so it names no test; the first registry change adds the corpus, with the records here as its
  first entries.
- The `environment_id` on every record, reply and notification id lets a later system that spans environments tell
  them apart without a change to any app.

## Failure modes

| what fails | what the caller sees |
|---|---|
| the issuer's key set cannot be fetched past a verifier's stale bound | 503 `unavailable` from each service, as in [HTTP authentication](http_auth.md#failure-modes-at-the-service) |
| a token from another environment | 401 `invalid_token` (`iss` does not match) |
| a lost reply to Register or Update | the retry gets 200 with the current envelope |
| a lost reply to Publish | a second notification, unless the producer set a `dedupe_key` |
| the issuer cannot reach the registry | sign-ins and token requests for apps not in its 30-second cache fail (`temporarily_unavailable`, `invalid_client`) |
| the notification service is down at Retire | the app is retired; its notifications are resolved when Retire-resolve next succeeds |
| an app's health poll fails three times | a `health` notification to its owner |
| an app's removal endpoint fails for 7 days | a `removal_failed` notification to its owner |
| a retired app's token, still within its 15 minutes | 409 `app_retired` on Publish and Report health |

## Open decisions

The shapes here wait on these decisions of the project's maintainers. Each line is the recommendation this document
is written to, and the sections it governs.

| id | question | written here as | governs |
|---|---|---|---|
| D1 | our own small OIDC issuer, or an existing one | our own; the wire above does not depend on the choice | [The issuer](#the-issuer) |
| D2 | roles global, per app, or both | per app, plus the `environment` key for `registrar`, `viewer` and `admin` | [Tokens](#tokens) |
| D3 | who may register an app | the `registrar` role only, by hand; an app never registers itself | Register, Update, Retire |
| D4 | notification channels and subscriptions | inbox, mail and push, each a subscription per person and severity; not in v1, where the recipient is the owner | [Publish](#publish) recipients |
| D5 | how long notification history is kept | kept forever | [Query history](#query-history) |
| D6 | severity, states and acknowledgement rules | four severities, three states; the owner, a person with a role on the app, or a registrar may acknowledge; `critical` needs a note | [Acknowledge](#acknowledge), [Resolve](#resolve) |
| D7 | is the notification service part of the hub or a central service | a central service of the environment, so apps reach it when the hub is down | [The v1 wire](#the-v1-wire) |
| D10 | health by poll or by push | poll from inside the environment, with push as a normal path | [Health](#health) |
| D12 | the record, the wire, the environment model and the session length | as written here; the session length is the issuer's `--session-max`, with no default until D12 sets it | everything not tagged otherwise |

## What must always hold

- The registry never stores or returns a setting value or a secret.
- An app is registered in one environment and talks only to that environment's services; nothing in a record names
  a cloud provider or account.
- No app setting or service setting is read from an environment variable.
- A record version is never edited; a notification and its state changes are never edited.
- An app name is never reused in its environment.
- Every refusal is a named code; no call answers a bad request with a different success.
