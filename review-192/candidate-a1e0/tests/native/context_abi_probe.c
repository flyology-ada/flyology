#include <stdint.h>

/*
 * Test-only context-switch ABI probe.
 *
 * The assembly routine installs canaries in the host ABI's nonvolatile
 * registers, calls an Ada callback that suspends the current task, and checks
 * the canaries when that callback returns.  It restores the caller's original
 * machine state before returning a category bit mask:
 *
 *   bit 0  callback reported failure
 *   bit 1  stack entry or call alignment was wrong
 *   bit 2  a nonvolatile integer register changed
 *   bit 3  a nonvolatile floating-point register changed
 *   bit 4  floating-point control state changed
 *
 * Caller-saved registers are deliberately outside this probe's contract.
 */

#if defined(__APPLE__)
#define FLYOLOGY_ASM_SYMBOL(name) "_" #name
#define FLYOLOGY_GNU_STACK
#else
#define FLYOLOGY_ASM_SYMBOL(name) #name
#define FLYOLOGY_GNU_STACK \
    ".section .note.GNU-stack,\"\",%progbits\n"
#endif

#if defined(__aarch64__)

__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl " FLYOLOGY_ASM_SYMBOL(flyology_test_context_probe) "\n"
    FLYOLOGY_ASM_SYMBOL(flyology_test_context_probe) ":\n"
    /* Preserve the probe caller's complete nonvolatile state. */
    "sub sp, sp, #176\n"
    "stp x29, x30, [sp, #0]\n"
    "stp x19, x20, [sp, #16]\n"
    "stp x21, x22, [sp, #32]\n"
    "stp x23, x24, [sp, #48]\n"
    "stp x25, x26, [sp, #64]\n"
    "stp x27, x28, [sp, #80]\n"
    "stp d8, d9, [sp, #96]\n"
    "stp d10, d11, [sp, #112]\n"
    "stp d12, d13, [sp, #128]\n"
    "stp d14, d15, [sp, #144]\n"
    "mrs x9, fpcr\n"
    "str w9, [sp, #160]\n"
    "mrs x9, fpsr\n"
    "str w9, [sp, #164]\n"
    "str w0, [sp, #168]\n"
    "str wzr, [sp, #172]\n"

    /* AAPCS64 requires SP to remain 16-byte aligned at every public call. */
    "mov x9, sp\n"
    "tst x9, #15\n"
    "b.eq 1f\n"
    "mov w10, #2\n"
    "str w10, [sp, #172]\n"
    "1:\n"

    /* Distinct integer and low-64-bit SIMD canaries. */
    "mov x19, #0x191\n"
    "mov x20, #0x202\n"
    "mov x21, #0x213\n"
    "mov x22, #0x224\n"
    "mov x23, #0x235\n"
    "mov x24, #0x246\n"
    "mov x25, #0x257\n"
    "mov x26, #0x268\n"
    "mov x27, #0x279\n"
    "mov x28, #0x28a\n"
    "mov x9, #0xd08\n"
    "fmov d8, x9\n"
    "mov x9, #0xd09\n"
    "fmov d9, x9\n"
    "mov x9, #0xd10\n"
    "fmov d10, x9\n"
    "mov x9, #0xd11\n"
    "fmov d11, x9\n"
    "mov x9, #0xd12\n"
    "fmov d12, x9\n"
    "mov x9, #0xd13\n"
    "fmov d13, x9\n"
    "mov x9, #0xd14\n"
    "fmov d14, x9\n"
    "mov x9, #0xd15\n"
    "fmov d15, x9\n"

    /* Use valid, non-default mode/status images that a swap must retain. */
    "mov x9, #0x400000\n"
    "msr fpcr, x9\n"
    "mov x9, #0x8000000\n"
    "msr fpsr, x9\n"

    "ldr w0, [sp, #168]\n"
    "bl " FLYOLOGY_ASM_SYMBOL(flyology_test_context_callback) "\n"
    "ldr w10, [sp, #172]\n"
    "cbz w0, 2f\n"
    "orr w10, w10, #1\n"
    "2:\n"

    /* Any integer mismatch sets category bit 2. */
    "mov x9, #0x191\n"
    "cmp x19, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x202\n"
    "cmp x20, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x213\n"
    "cmp x21, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x224\n"
    "cmp x22, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x235\n"
    "cmp x23, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x246\n"
    "cmp x24, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x257\n"
    "cmp x25, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x268\n"
    "cmp x26, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x279\n"
    "cmp x27, x9\n"
    "b.ne 10f\n"
    "mov x9, #0x28a\n"
    "cmp x28, x9\n"
    "b.eq 11f\n"
    "10:\n"
    "orr w10, w10, #4\n"
    "11:\n"

    /* AAPCS64 preserves only the low 64 bits of v8 through v15. */
    "fmov x9, d8\n"
    "cmp x9, #0xd08\n"
    "b.ne 20f\n"
    "fmov x9, d9\n"
    "cmp x9, #0xd09\n"
    "b.ne 20f\n"
    "fmov x9, d10\n"
    "cmp x9, #0xd10\n"
    "b.ne 20f\n"
    "fmov x9, d11\n"
    "cmp x9, #0xd11\n"
    "b.ne 20f\n"
    "fmov x9, d12\n"
    "cmp x9, #0xd12\n"
    "b.ne 20f\n"
    "fmov x9, d13\n"
    "cmp x9, #0xd13\n"
    "b.ne 20f\n"
    "fmov x9, d14\n"
    "cmp x9, #0xd14\n"
    "b.ne 20f\n"
    "fmov x9, d15\n"
    "cmp x9, #0xd15\n"
    "b.eq 21f\n"
    "20:\n"
    "orr w10, w10, #8\n"
    "21:\n"

    "mrs x9, fpcr\n"
    "mov x11, #0x400000\n"
    "cmp w9, w11\n"
    "b.ne 30f\n"
    "mrs x9, fpsr\n"
    "mov x11, #0x8000000\n"
    "cmp w9, w11\n"
    "b.eq 31f\n"
    "30:\n"
    "orr w10, w10, #16\n"
    "31:\n"
    "str w10, [sp, #172]\n"

    /* Restore the probe caller exactly, including its FP environment. */
    "ldr w9, [sp, #160]\n"
    "msr fpcr, x9\n"
    "ldr w9, [sp, #164]\n"
    "msr fpsr, x9\n"
    "ldp d8, d9, [sp, #96]\n"
    "ldp d10, d11, [sp, #112]\n"
    "ldp d12, d13, [sp, #128]\n"
    "ldp d14, d15, [sp, #144]\n"
    "ldp x19, x20, [sp, #16]\n"
    "ldp x21, x22, [sp, #32]\n"
    "ldp x23, x24, [sp, #48]\n"
    "ldp x25, x26, [sp, #64]\n"
    "ldp x27, x28, [sp, #80]\n"
    "ldp x29, x30, [sp, #0]\n"
    "ldr w0, [sp, #172]\n"
    "add sp, sp, #176\n"
    "ret\n"
    FLYOLOGY_GNU_STACK);

#elif defined(__x86_64__)

__asm__(
    ".text\n"
    ".p2align 4\n"
    ".globl " FLYOLOGY_ASM_SYMBOL(flyology_test_context_probe) "\n"
    FLYOLOGY_ASM_SYMBOL(flyology_test_context_probe) ":\n"
    /* 104 bytes changes entry RSP==8 (mod 16) into call RSP==0 (mod 16). */
    "subq $104, %rsp\n"
    "movq %rbx, 0(%rsp)\n"
    "movq %rbp, 8(%rsp)\n"
    "movq %r12, 16(%rsp)\n"
    "movq %r13, 24(%rsp)\n"
    "movq %r14, 32(%rsp)\n"
    "movq %r15, 40(%rsp)\n"
    "stmxcsr 48(%rsp)\n"
    "fnstcw 52(%rsp)\n"
    "movl %edi, 56(%rsp)\n"
    "movl $0, 60(%rsp)\n"

    /* Check both the public entry convention and the outgoing call site. */
    "leaq 104(%rsp), %rax\n"
    "andl $15, %eax\n"
    "cmpl $8, %eax\n"
    "jne 1f\n"
    "movq %rsp, %rax\n"
    "andl $15, %eax\n"
    "jz 2f\n"
    "1:\n"
    "orl $2, 60(%rsp)\n"
    "2:\n"

    "movabsq $0x1919191919190191, %rbx\n"
    "movabsq $0x2020202020200202, %rbp\n"
    "movabsq $0x1212121212120121, %r12\n"
    "movabsq $0x1313131313130131, %r13\n"
    "movabsq $0x1414141414140141, %r14\n"
    "movabsq $0x1515151515150151, %r15\n"
    "movl $0x3f80, 64(%rsp)\n"
    "ldmxcsr 64(%rsp)\n"
    "movw $0x077f, 68(%rsp)\n"
    "fldcw 68(%rsp)\n"

    "movl 56(%rsp), %edi\n"
    "call " FLYOLOGY_ASM_SYMBOL(flyology_test_context_callback) "\n"
    "testl %eax, %eax\n"
    "jz 3f\n"
    "orl $1, 60(%rsp)\n"
    "3:\n"

    "movabsq $0x1919191919190191, %rax\n"
    "cmpq %rax, %rbx\n"
    "jne 10f\n"
    "movabsq $0x2020202020200202, %rax\n"
    "cmpq %rax, %rbp\n"
    "jne 10f\n"
    "movabsq $0x1212121212120121, %rax\n"
    "cmpq %rax, %r12\n"
    "jne 10f\n"
    "movabsq $0x1313131313130131, %rax\n"
    "cmpq %rax, %r13\n"
    "jne 10f\n"
    "movabsq $0x1414141414140141, %rax\n"
    "cmpq %rax, %r14\n"
    "jne 10f\n"
    "movabsq $0x1515151515150151, %rax\n"
    "cmpq %rax, %r15\n"
    "je 11f\n"
    "10:\n"
    "orl $4, 60(%rsp)\n"
    "11:\n"

    /* SysV AMD64 has no nonvolatile XMM data registers. */
    "stmxcsr 72(%rsp)\n"
    "cmpl $0x3f80, 72(%rsp)\n"
    "jne 20f\n"
    "fnstcw 76(%rsp)\n"
    "cmpw $0x077f, 76(%rsp)\n"
    "je 21f\n"
    "20:\n"
    "orl $16, 60(%rsp)\n"
    "21:\n"

    "ldmxcsr 48(%rsp)\n"
    "fldcw 52(%rsp)\n"
    "movq 0(%rsp), %rbx\n"
    "movq 8(%rsp), %rbp\n"
    "movq 16(%rsp), %r12\n"
    "movq 24(%rsp), %r13\n"
    "movq 32(%rsp), %r14\n"
    "movq 40(%rsp), %r15\n"
    "movl 60(%rsp), %eax\n"
    "addq $104, %rsp\n"
    "ret\n"
    FLYOLOGY_GNU_STACK);

#else
#error "context ABI probe requires a supported Flyology architecture"
#endif
