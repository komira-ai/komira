"""fx_dlopen_unmapped_user: depends on fx_dlopen_unmapped, a fixture of tests//negative/conda."""

from fx_dlopen_unmapped import fx_dlopen_unmapped_value


def fx_dlopen_unmapped_user_value() -> Int:
    return fx_dlopen_unmapped_value() + 1
