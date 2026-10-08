"""covlow_user: a library that depends on covlow, whose coverage gate is red
in enforce mode (test 46): it compiles against covlow's package all the same."""

from covlow import word


def shout(x: Int) -> String:
    return word(x) + "!"
