"""fx_native_owner_user: reaches C only through fx_native_owner, a fixture of tools/build/native/fixtures."""

from fx_native_owner import fx_native_add


def fx_native_five() -> Int32:
    return fx_native_add(2, 3)
