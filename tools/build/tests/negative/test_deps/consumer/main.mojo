# A program depending on tdlib, which names tdhelper in `test_deps` only:
# tdhelper is not in tdlib's closure, so the import fails to compile.
from tdhelper import helper_answer


def main():
    print(helper_answer())
