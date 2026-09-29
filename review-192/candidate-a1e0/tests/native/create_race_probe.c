/*  Foreign-thread driver and process-exit assertion for the Create/Finalize
    race regression test.

    The scheduler's create path must stay safe when a thread the Ada runtime
    never waits for calls it while the environment task finalizes.  GNAT
    supports exactly that through foreign-thread registration, so the racing
    creator here is a detached pthread rather than an Ada task: an Ada task
    would be awaited by its master and could never reach the window.

    The outcome can only be inspected after the main subprogram has returned,
    so the assertion runs from atexit, like the other lifecycle probes.  */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>

extern int flyology_runtime_observe_lifecycle(void);

typedef void (*flyology_create_race_entry)(void);
typedef int (*flyology_create_race_query)(void);

static flyology_create_race_query flyology_create_race_result;

static void *flyology_create_race_thread(void *argument) {
    flyology_create_race_entry entry = (flyology_create_race_entry)argument;

    entry();
    return NULL;
}

int flyology_test_start_create_racer(flyology_create_race_entry entry) {
    pthread_attr_t attributes;
    pthread_t thread;
    int result;

    if (entry == NULL) {
        return -1;
    }
    if (pthread_attr_init(&attributes) != 0) {
        return -1;
    }
    /*  Detached: the environment task must be able to finalize without
        joining this thread, which is the whole point of the race.  */
    if (pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED)
        != 0) {
        (void)pthread_attr_destroy(&attributes);
        return -1;
    }
    result = pthread_create(&thread, &attributes,
                            flyology_create_race_thread, (void *)entry);
    (void)pthread_attr_destroy(&attributes);
    return result == 0 ? 0 : -1;
}

static void check_create_race_at_exit(void) {
    int outcome = 1;
    int lifecycle;

    /*  The released creator finishes a few instructions after finalization
        resumes, so wait for its result rather than sampling it.  */
    for (int attempt = 0; attempt < 5000; ++attempt) {
        outcome = flyology_create_race_result();
        if (outcome != 1) {
            break;
        }
        usleep(1000);
    }
    lifecycle = flyology_runtime_observe_lifecycle();
    if (outcome != -1 || lifecycle != 3) {
        char message[160];
        int length = snprintf(message, sizeof(message),
            "Flyology create/finalize race check failed: "
            "create_result=%d lifecycle=%d (expected -1 and 3)\n",
            outcome, lifecycle);
        if (length > 0) {
            (void)write(STDERR_FILENO, message, (size_t)length);
        }
        _Exit(96);
    }
}

int flyology_test_arm_create_race_exit_check(
    flyology_create_race_query query) {
    if (query == NULL) {
        return -1;
    }
    flyology_create_race_result = query;
    return atexit(check_create_race_at_exit);
}
