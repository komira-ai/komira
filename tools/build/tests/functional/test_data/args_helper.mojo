# The program a mojo_test is handed through `$(exe_target ...)` in `args`
# (mojo_test_args): only its presence, beside its runtime libraries, is
# checked.
def main():
    print("args_helper")
