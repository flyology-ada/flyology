#include <stdlib.h>

extern unsigned flyology_test_fault_calls(int point);

static unsigned minimum_releases;

static void verify_poller_finalization(void)
{
    /* The binder finalizes the Flyology runtime before C atexit handlers run. */
    if (flyology_test_fault_calls(48) < minimum_releases) {
        _Exit(86);
    }
}

int flyology_test_expect_poller_finalize_releases(unsigned minimum)
{
    minimum_releases = minimum;
    return atexit(verify_poller_finalization);
}
