"""syslib_consumer: a library with no code of its own whose welded test calls syslib_codec, which opens SQLite by its bare name."""


def doubled(x: Int) -> Int:
    return x * 2
