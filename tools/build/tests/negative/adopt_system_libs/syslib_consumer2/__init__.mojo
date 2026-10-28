"""syslib_consumer2: two levels below the adopted package (it depends on syslib_consumer, which depends on the adopted syslib_codec)."""


def tripled(x: Int) -> Int:
    return x * 3
