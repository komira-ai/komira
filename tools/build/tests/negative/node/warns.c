/* A source with one warning (an unused variable): c_shared_lib `warns` must
 * fail, because it compiles with -Wall -Werror. */
int komira_negative_warns(void) {
    int unused_on_purpose = 0;
    return 1;
}
