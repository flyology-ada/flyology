#if defined(__APPLE__) && defined(__aarch64__)

.text
.p2align 2
.globl _gnatevl_context_initialize_registers
_gnatevl_context_initialize_registers:
    str x2, [x0, #88]
    str x1, [x0, #96]
    ret

.globl _gnatevl_context_swap_registers
_gnatevl_context_swap_registers:
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
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
    ret

#elif defined(__APPLE__) && defined(__x86_64__)

.text
.p2align 4
.globl _gnatevl_context_initialize_registers
_gnatevl_context_initialize_registers:
    subq $8, %rsi
    movq $0, (%rsi)
    movq %rsi, 48(%rdi)
    movq %rdx, 56(%rdi)
    movl $0x1f80, 64(%rdi)
    movw $0x037f, 68(%rdi)
    ret

.globl _gnatevl_context_swap_registers
_gnatevl_context_swap_registers:
    movq %rbx, 0(%rdi)
    movq %rbp, 8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    movq %rsp, 48(%rdi)
    leaq 1f(%rip), %rax
    movq %rax, 56(%rdi)
    stmxcsr 64(%rdi)
    fnstcw 68(%rdi)
    movq 0(%rsi), %rbx
    movq 8(%rsi), %rbp
    movq 16(%rsi), %r12
    movq 24(%rsi), %r13
    movq 32(%rsi), %r14
    movq 40(%rsi), %r15
    movq 48(%rsi), %rsp
    ldmxcsr 64(%rsi)
    fldcw 68(%rsi)
    jmp *56(%rsi)
1:
    ret

#elif defined(__linux__) && defined(__aarch64__)

.text
.p2align 2
.globl gnatevl_context_initialize_registers
.type gnatevl_context_initialize_registers, %function
gnatevl_context_initialize_registers:
    str x2, [x0, #88]
    str x1, [x0, #96]
    ret

.globl gnatevl_context_swap_registers
.type gnatevl_context_swap_registers, %function
gnatevl_context_swap_registers:
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
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
    ret

.section .note.GNU-stack,"",%progbits

#elif defined(__linux__) && defined(__x86_64__)

.text
.p2align 4
.globl gnatevl_context_initialize_registers
.type gnatevl_context_initialize_registers, @function
gnatevl_context_initialize_registers:
    subq $8, %rsi
    movq $0, (%rsi)
    movq %rsi, 48(%rdi)
    movq %rdx, 56(%rdi)
    movl $0x1f80, 64(%rdi)
    movw $0x037f, 68(%rdi)
    ret

.globl gnatevl_context_swap_registers
.type gnatevl_context_swap_registers, @function
gnatevl_context_swap_registers:
    movq %rbx, 0(%rdi)
    movq %rbp, 8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    movq %rsp, 48(%rdi)
    leaq 1f(%rip), %rax
    movq %rax, 56(%rdi)
    stmxcsr 64(%rdi)
    fnstcw 68(%rdi)
    movq 0(%rsi), %rbx
    movq 8(%rsi), %rbp
    movq 16(%rsi), %r12
    movq 24(%rsi), %r13
    movq 32(%rsi), %r14
    movq 40(%rsi), %r15
    movq 48(%rsi), %rsp
    ldmxcsr 64(%rsi)
    fldcw 68(%rsi)
    jmp *56(%rsi)
1:
    ret

.section .note.GNU-stack,"",@progbits

#else
#error GNATEVL needs a context switch for this ABI
#endif
