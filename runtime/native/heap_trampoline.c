/*  Copyright (c) 2026 Yurii Rashkovskii
 *  SPDX-License-Identifier: MIT OR Apache-2.0
 *
 *  Pooled heap trampolines for GNAT nested subprograms.
 *
 *  GCC gives a nested subprogram whose address escapes a small executable
 *  thunk that loads the enclosing frame's static chain before branching to the
 *  subprogram body. On targets without executable stacks the compiler asks its
 *  runtime for that storage, emitting calls to
 *
 *     __gcc_nested_func_ptr_created (chain, function, destination)
 *     __gcc_nested_func_ptr_deleted (void)
 *
 *  when the declaring subprogram is entered and when it returns.
 *
 *  libgcc's Darwin/AArch64 implementation keeps one allocation cursor in
 *  thread-local storage and reclaims slots by count: creation takes the next
 *  slot of the current page and deletion merely returns one slot to it. The
 *  deletion entry point receives no argument, so that allocator cannot release
 *  an arbitrary slot and is correct only while each pthread creates and
 *  releases trampolines in stack order.
 *
 *  Flyology multiplexes stackful fibers onto one event-loop pthread, so those
 *  lifetimes interleave: a fiber can suspend with a callback still live while
 *  another fiber on the same thread creates and releases its own. A cursor
 *  shared by the thread then hands a later fiber a slot that an earlier fiber
 *  still owns, silently rewriting a live thunk's target and static chain.
 *
 *  Deletions are stack-ordered within one fiber even though they are not
 *  within one thread, so this implementation keeps the stack per fiber and the
 *  storage shared. Each fiber owns only a pointer to its most recent
 *  trampoline; each trampoline records the fiber's previous one in a word
 *  placed after the two the compiler reads. Slots are therefore released
 *  individually and come from per-thread arenas rather than from a page
 *  reserved for one fiber, so committed memory tracks live callbacks instead
 *  of fiber count.
 *
 *  A fiber may migrate between event loops while holding a callback, so a slot
 *  can be released by a thread other than the one that allocated it. Each page
 *  names its owning arena, and a foreign release publishes the slot through
 *  that arena's lock-free inbox, which the owner drains when it next needs a
 *  slot. No lock is taken on either path.
 *
 *  Arenas and their pages are retained for the process lifetime and recycled
 *  through the free lists, so the footprint settles at the peak number of
 *  simultaneously live trampolines per thread.
 *
 *  Only slot management differs from the compiler's own implementation. The
 *  thunk encoding, the mapping flags, the W^X toggling, and the cache
 *  maintenance are fixed by the compiler ABI and by Darwin's rules for
 *  executable memory, and must match what generated code expects.
 */

#if defined(__APPLE__) && defined(__aarch64__)

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/*  Six instructions, then the two words the thunk loads, then our link. The
 *  literal loads reach offsets 24 and 32, so the trailing word is invisible to
 *  generated code.  */
struct flyology_slot {
    uint32_t instructions[6]; /*  0 */
    void *function;           /* 24 <- ldr x17, .+20 */
    void *static_chain;       /* 32 <- ldr x16, .+24 */
    void *link;               /* 40    owning fiber's previous slot, or the
                               *       next slot in an arena's remote inbox */
};

static const uint32_t flyology_trampoline_template[6] = {
    0xd503245fU, /* bti c          */
    0x580000b1U, /* ldr x17, .+20  */
    0x580000d0U, /* ldr x16, .+24  */
    0xd61f0220U, /* br  x17        */
    0xd5033f9fU, /* dsb sy         */
    0xd5033fdfU  /* isb            */
};

struct flyology_arena;

/*  The first slot-sized cell of a page names its arena so that any thread can
 *  route a release without consulting shared bookkeeping.  */
struct flyology_page {
    struct flyology_arena *owner;
    struct flyology_page *next_page;
};

struct flyology_arena {
    /*  Owner-only: the free list and its pages are touched exclusively by the
     *  thread this arena belongs to.  */
    struct flyology_slot **free_slots;
    size_t free_count;
    size_t free_capacity;
    struct flyology_page *pages;
    /*  Any thread may push; only the owner drains.  */
    _Atomic(struct flyology_slot *) remote_head;
    struct flyology_arena *next_arena;
};

/*  Address of the running fiber's cursor, or null outside a fiber.  */
extern void **flyology_runtime_current_trampoline_control_slot(void);

/*  Native tasks, the environment task, and scheduler code outside a fiber keep
 *  an ordinary per-thread cursor. The stack discipline holds there already.  */
/*  Held as void * so it has exactly the representation of the fiber slot the
 *  scheduler exports, and both cursors can be read through one pointer type.  */
static _Thread_local void *flyology_thread_top;
static _Thread_local struct flyology_arena *flyology_thread_arena;

/*  Retained only so a leak checker can see every mapping the process owns.  */
static _Atomic(struct flyology_arena *) flyology_arenas;

static size_t flyology_page_bytes(void) {
    return (size_t) getpagesize();
}

/*  One cell is spent on the page header.  */
static size_t flyology_slots_per_page(void) {
    return flyology_page_bytes() / sizeof(struct flyology_slot) - 1;
}

static struct flyology_arena *flyology_owner_of(struct flyology_slot *slot) {
    uintptr_t base = (uintptr_t) slot & ~((uintptr_t) flyology_page_bytes() - 1);

    return ((struct flyology_page *) base)->owner;
}

static struct flyology_arena *flyology_ensure_arena(void) {
    struct flyology_arena *arena = flyology_thread_arena;
    struct flyology_arena *head;

    if (arena != NULL) {
        return arena;
    }
    arena = calloc(1, sizeof(*arena));
    /*  The compiler's calling sequence cannot report a failure to its caller,
     *  so an exhausted host ends the process here, as libgcc's does.  */
    if (arena == NULL) {
        abort();
    }
    atomic_init(&arena->remote_head, NULL);
    head = atomic_load_explicit(&flyology_arenas, memory_order_relaxed);
    do {
        arena->next_arena = head;
    } while (!atomic_compare_exchange_weak_explicit(
        &flyology_arenas, &head, arena,
        memory_order_release, memory_order_relaxed));
    flyology_thread_arena = arena;
    return arena;
}

/*  Reclaim everything foreign threads have published. Called by the owner only,
 *  so the free list needs no synchronisation of its own.  */
static void flyology_drain_remote(struct flyology_arena *arena) {
    struct flyology_slot *slot =
        atomic_exchange_explicit(&arena->remote_head, NULL, memory_order_acquire);

    while (slot != NULL) {
        struct flyology_slot *next = slot->link;

        arena->free_slots[arena->free_count++] = slot;
        slot = next;
    }
}

static int flyology_add_page(struct flyology_arena *arena) {
    size_t per_page = flyology_slots_per_page();
    size_t capacity = arena->free_capacity + per_page;
    struct flyology_slot **slots =
        realloc(arena->free_slots, capacity * sizeof(*slots));
    struct flyology_page *page;
    unsigned char *base;
    size_t index;

    if (slots == NULL) {
        return 0;
    }
    arena->free_slots = slots;
    base = mmap(NULL, flyology_page_bytes(), PROT_READ | PROT_WRITE | PROT_EXEC,
                MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (base == MAP_FAILED) {
        return 0;
    }
    page = (struct flyology_page *) base;
    pthread_jit_write_protect_np(0);
    page->owner = arena;
    page->next_page = arena->pages;
    pthread_jit_write_protect_np(1);
    arena->pages = page;
    arena->free_capacity = capacity;
    for (index = 1; index <= per_page; index++) {
        arena->free_slots[arena->free_count++] =
            (struct flyology_slot *) (base + index * sizeof(struct flyology_slot));
    }
    return 1;
}

static struct flyology_slot *flyology_take_slot(struct flyology_arena *arena) {
    if (arena->free_count == 0) {
        flyology_drain_remote(arena);
    }
    if (arena->free_count == 0 && !flyology_add_page(arena)) {
        abort();
    }
    return arena->free_slots[--arena->free_count];
}

static void flyology_return_slot(struct flyology_slot *slot) {
    struct flyology_arena *owner = flyology_owner_of(slot);
    struct flyology_slot *head;

    if (owner == flyology_thread_arena) {
        /*  Every slot released here was carved from this arena, so the free
         *  list can always hold it.  */
        owner->free_slots[owner->free_count++] = slot;
        return;
    }
    /*  The fiber migrated after taking this slot. Publishing through the inbox
     *  writes the slot, so the JIT window opens for the push.  */
    pthread_jit_write_protect_np(0);
    head = atomic_load_explicit(&owner->remote_head, memory_order_relaxed);
    do {
        slot->link = head;
    } while (!atomic_compare_exchange_weak_explicit(
        &owner->remote_head, &head, slot,
        memory_order_release, memory_order_relaxed));
    pthread_jit_write_protect_np(1);
}

static void **flyology_current_top(void) {
    void **cursor = flyology_runtime_current_trampoline_control_slot();

    return (cursor != NULL) ? cursor : &flyology_thread_top;
}

void __gcc_nested_func_ptr_created(void *chain, void *function,
                                   void *destination) {
    void **top = flyology_current_top();
    struct flyology_arena *arena = flyology_ensure_arena();
    struct flyology_slot *slot = flyology_take_slot(arena);

    pthread_jit_write_protect_np(0);
    memcpy(slot->instructions, flyology_trampoline_template,
           sizeof(flyology_trampoline_template));
    slot->function = function;
    slot->static_chain = chain;
    slot->link = *top;
    pthread_jit_write_protect_np(1);
    /*  Only the instructions are executed; the trailing words are read as
     *  data.  */
    __builtin___clear_cache((char *) slot->instructions,
                            (char *) slot->instructions
                                + sizeof(slot->instructions));
    *top = slot;
    *(void **) destination = slot->instructions;
}

void __gcc_nested_func_ptr_deleted(void) {
    void **top = flyology_current_top();
    struct flyology_slot *slot = *top;

    /*  The compiler pairs every deletion with an earlier creation reached
     *  through the same cursor, so this is unreachable from generated code.  */
    if (slot == NULL) {
        abort();
    }
    *top = slot->link;
    flyology_return_slot(slot);
}

void flyology_heap_trampoline_release(void *control) {
    struct flyology_slot *slot = control;

    while (slot != NULL) {
        struct flyology_slot *next = slot->link;

        flyology_return_slot(slot);
        slot = next;
    }
}

#else

/*  Other hosts keep the compiler's own trampoline handling, so a reaped fiber
 *  owns nothing to release.  */
void flyology_heap_trampoline_release(void *control) {
    (void) control;
}

#endif
