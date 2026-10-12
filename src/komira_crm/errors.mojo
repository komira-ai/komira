# =============================================================================
# komira_crm/errors.mojo -- the texts the store raises.
# =============================================================================
#
# Every refusal of the store is an `Error` whose text starts with one of the
# constants below, so a caller maps it to an HTTP status by prefix. The
# not-found text names no id.
# =============================================================================

comptime ERR_NOT_FOUND: StaticString = "crm: not found"
comptime ERR_VERSION_CONFLICT: StaticString = "crm: version conflict"
comptime ERR_EXTERNAL_ID_TAKEN: StaticString = "crm: external_id is already used by another row of this kind"
comptime ERR_FIELD_KEY_TAKEN: StaticString = "crm: a custom field with this key already exists for this kind"
comptime ERR_SYSTEM_ACTIVITY: StaticString = "crm: a system activity cannot be changed"
comptime ERR_NOT_INITIALIZED: StaticString = "crm: the dataset is not initialized"
comptime ERR_INVALID: StaticString = "crm: invalid "
comptime ERR_FRACTIONAL_AMOUNT: StaticString = "crm: invalid amount: not a whole number of minor units of the currency"
comptime ERR_UNKNOWN_CURRENCY: StaticString = "crm: invalid currency: not an ISO 4217 code with a minor unit"


def invalid(field: StaticString, why: StaticString) -> Error:
    """`crm: invalid <field>: <why>`."""
    return Error(String(ERR_INVALID) + String(field) + String(": ") + String(why))


def not_found() -> Error:
    return Error(String(ERR_NOT_FOUND))


def version_conflict() -> Error:
    return Error(String(ERR_VERSION_CONFLICT))
