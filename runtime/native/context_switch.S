/*
 * Minimal stackful-context support used by System.Flyology.Contexts.
 *
 * The Ada side owns each stack and a zero-initialized Register_Array.  This
 * file supplies two C-callable leaf routines:
 *
 *   initialize_registers(image, stack_top, trampoline)
 *     Constructs the register image for a context that has never run.
 *
 *   swap_registers(from, to)
 *     Saves the current C ABI's nonvolatile machine state in `from`, restores
 *     it from `to`, and continues at the restored instruction address.
 *
 * This is deliberately a cooperative call boundary, not an interrupt frame.
 * Caller-saved registers need not survive: the compiler already assumes a
 * normal call may clobber them.  The offsets below are therefore a private ABI
 * shared with the Register_Array declared in s-flycon.ads.  Change the two
 * together, and keep the array large enough for the greatest offset used here.
 */

#if defined(__APPLE__) && defined(__aarch64__)

/*
 * Darwin AArch64 register image (byte offsets):
 *
 *    0..79   x19..x28       AAPCS64 callee-saved general registers
 *   80       x29            frame pointer
 *   88       x30            link register / resume address
 *   96       sp             stack pointer
 *  104..167  d8..d15        preserved low 64 bits of v8..v15
 *  168       fpcr (32 bits)  floating-point control
 *  172       fpsr (32 bits)  floating-point status
 *
 * Darwin prefixes externally visible C symbols with an underscore.  C
 * arguments arrive in x0=image, x1=stack_top, x2=trampoline.
 */
.text
.p2align 2
.globl _flyology_context_initialize_registers
_flyology_context_initialize_registers:
    /* A first restore executes `ret`, so seed LR with the trampoline. */
    str x2, [x0, #88]

    /* stack_top is already 16-byte aligned by the Ada stack allocator. */
    str x1, [x0, #96]

    /*
     * x29 and all other slots remain zero from Register_Array's default
     * initialization.  In particular, x29=0 terminates the initial backtrace.
     */
    ret

.globl _flyology_context_swap_registers
_flyology_context_swap_registers:
    /* Save every nonvolatile general register in `from` (x0). */
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]

    /* AArch64 cannot store SP directly, so use caller-saved x2 as scratch. */
    mov x2, sp
    str x2, [x0, #96]

    /* Preserve the AAPCS64 nonvolatile SIMD lanes and per-context FP modes. */
    stp d8, d9, [x0, #104]
    stp d10, d11, [x0, #120]
    stp d12, d13, [x0, #136]
    stp d14, d15, [x0, #152]
    mrs x2, fpcr
    str w2, [x0, #168]
    mrs x2, fpsr
    str w2, [x0, #172]

    /* Restore the destination image from `to` (x1). */
    ldp x19, x20, [x1, #0]
    ldp x21, x22, [x1, #16]
    ldp x23, x24, [x1, #32]
    ldp x25, x26, [x1, #48]
    ldp x27, x28, [x1, #64]
    ldp x29, x30, [x1, #80]
    ldr x2, [x1, #96]
    mov sp, x2
    ldp d8, d9, [x1, #104]
    ldp d10, d11, [x1, #120]
    ldp d12, d13, [x1, #136]
    ldp d14, d15, [x1, #152]
    ldr w2, [x1, #168]
    msr fpcr, x2
    ldr w2, [x1, #172]
    msr fpsr, x2

    /*
     * x30 now names either the suspended caller of swap_registers or, for a
     * fresh context, the Ada trampoline.  `ret` performs the actual transfer.
     */
    ret

#elif defined(__APPLE__) && defined(__x86_64__)

/*
 * Darwin x86-64 register image (byte offsets):
 *
 *    0  rbx       8  rbp      16  r12      24  r13
 *   32  r14      40  r15      48  rsp      56  resume RIP
 *   64  mxcsr (32 bits)        68  x87 control word (16 bits)
 *
 * SysV AMD64 has no nonvolatile XMM data registers.  MXCSR and the x87 control
 * word still carry rounding/masking state and are kept with the Ada task.
 * C arguments arrive in rdi=image, rsi=stack_top, rdx=trampoline.
 */
.text
.p2align 4
.globl _flyology_context_initialize_registers
_flyology_context_initialize_registers:
    /*
     * A normal call enters with rsp == 8 (mod 16), after its return address was
     * pushed.  A first context is reached by `jmp`, so manufacture that stack
     * shape and use address zero as a fail-fast return sentinel.
     */
    subq $8, %rsi
    movq $0, (%rsi)
    movq %rsi, 48(%rdi)
    movq %rdx, 56(%rdi)

    /* Architectural power-on/default C floating-point environment. */
    movl $0x1f80, 64(%rdi)
    movw $0x037f, 68(%rdi)
    ret

.globl _flyology_context_swap_registers
_flyology_context_swap_registers:
    /* Save the SysV nonvolatile general registers in `from` (rdi). */
    movq %rbx, 0(%rdi)
    movq %rbp, 8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    movq %rsp, 48(%rdi)

    /*
     * Store a local continuation rather than the caller's return address.
     * When this context is resumed, execution jumps to label 1 and the final
     * `ret` consumes the caller return address still on the saved stack.
     */
    leaq 1f(%rip), %rax
    movq %rax, 56(%rdi)
    stmxcsr 64(%rdi)
    fnstcw 68(%rdi)

    /* Restore the destination's nonvolatile state from `to` (rsi). */
    movq 0(%rsi), %rbx
    movq 8(%rsi), %rbp
    movq 16(%rsi), %r12
    movq 24(%rsi), %r13
    movq 32(%rsi), %r14
    movq 40(%rsi), %r15
    movq 48(%rsi), %rsp
    ldmxcsr 64(%rsi)
    fldcw 68(%rsi)

    /* `jmp` changes contexts without pushing onto the destination stack. */
    jmp *56(%rsi)
1:
    /* Resumed swap: return normally to System.Flyology.Contexts.Switch. */
    ret

#elif defined(__linux__) && defined(__aarch64__)

/*
 * Linux AArch64 uses the same AAPCS64 register image as Darwin:
 *
 *    0..79   x19..x28       callee-saved general registers
 *   80       x29            frame pointer
 *   88       x30            link register / resume address
 *   96       sp             stack pointer
 *  104..167  d8..d15        preserved low 64 bits of v8..v15
 *  168       fpcr (32 bits)  floating-point control
 *  172       fpsr (32 bits)  floating-point status
 *
 * ELF C symbols have no leading underscore.  Arguments arrive in
 * x0=image, x1=stack_top, x2=trampoline.
 */
.text
.p2align 2
.globl flyology_context_initialize_registers
.type flyology_context_initialize_registers, %function
flyology_context_initialize_registers:
    /* Seed LR for the first `ret`; SP is already 16-byte aligned. */
    str x2, [x0, #88]
    str x1, [x0, #96]

    /* Zero-initialized x29 terminates the fresh context's backtrace. */
    ret

.globl flyology_context_swap_registers
.type flyology_context_swap_registers, %function
flyology_context_swap_registers:
    /* Save all AAPCS64 nonvolatile state in `from` (x0). */
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]

    /* SP requires a general-register intermediary; x2 is caller-saved. */
    mov x2, sp
    str x2, [x0, #96]
    stp d8, d9, [x0, #104]
    stp d10, d11, [x0, #120]
    stp d12, d13, [x0, #136]
    stp d14, d15, [x0, #152]
    mrs x2, fpcr
    str w2, [x0, #168]
    mrs x2, fpsr
    str w2, [x0, #172]

    /* Restore all nonvolatile state from `to` (x1). */
    ldp x19, x20, [x1, #0]
    ldp x21, x22, [x1, #16]
    ldp x23, x24, [x1, #32]
    ldp x25, x26, [x1, #48]
    ldp x27, x28, [x1, #64]
    ldp x29, x30, [x1, #80]
    ldr x2, [x1, #96]
    mov sp, x2
    ldp d8, d9, [x1, #104]
    ldp d10, d11, [x1, #120]
    ldp d12, d13, [x1, #136]
    ldp d14, d15, [x1, #152]
    ldr w2, [x1, #168]
    msr fpcr, x2
    ldr w2, [x1, #172]
    msr fpsr, x2

    /* Resume the saved caller, or enter the trampoline for a fresh image. */
    ret

/* Mark stacks non-executable for ELF linkers. */
.section .note.GNU-stack,"",%progbits

#elif defined(__linux__) && defined(__x86_64__)

/*
 * Linux x86-64 uses the SysV AMD64 register image:
 *
 *    0  rbx       8  rbp      16  r12      24  r13
 *   32  r14      40  r15      48  rsp      56  resume RIP
 *   64  mxcsr (32 bits)        68  x87 control word (16 bits)
 *
 * Caller-saved registers, including all XMM data registers, intentionally do
 * not survive this ordinary C call boundary.  Arguments arrive in
 * rdi=image, rsi=stack_top, rdx=trampoline.
 */
.text
.p2align 4
.globl flyology_context_initialize_registers
.type flyology_context_initialize_registers, @function
flyology_context_initialize_registers:
    /*
     * Reproduce function-entry alignment without a call instruction.  The
     * zero word stands in for a return address and catches an impossible
     * return from the no-return trampoline.
     */
    subq $8, %rsi
    movq $0, (%rsi)
    movq %rsi, 48(%rdi)
    movq %rdx, 56(%rdi)

    /* Default MXCSR and x87 control values for a newly created task. */
    movl $0x1f80, 64(%rdi)
    movw $0x037f, 68(%rdi)
    ret

.globl flyology_context_swap_registers
.type flyology_context_swap_registers, @function
flyology_context_swap_registers:
    /* Save SysV nonvolatile general and floating-point control state. */
    movq %rbx, 0(%rdi)
    movq %rbp, 8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    movq %rsp, 48(%rdi)

    /* Resume here later, then return through the original caller's stack. */
    leaq 1f(%rip), %rax
    movq %rax, 56(%rdi)
    stmxcsr 64(%rdi)
    fnstcw 68(%rdi)

    /* Restore the destination image. */
    movq 0(%rsi), %rbx
    movq 8(%rsi), %rbp
    movq 16(%rsi), %r12
    movq 24(%rsi), %r13
    movq 32(%rsi), %r14
    movq 40(%rsi), %r15
    movq 48(%rsi), %rsp
    ldmxcsr 64(%rsi)
    fldcw 68(%rsi)

    /* Jumping avoids perturbing the destination's restored stack. */
    jmp *56(%rsi)
1:
    /* Resumed swap: return to the Ada Switch caller. */
    ret

/* Mark stacks non-executable for ELF linkers. */
.section .note.GNU-stack,"",@progbits

#else
#error Flyology needs a context switch for this ABI
#endif
