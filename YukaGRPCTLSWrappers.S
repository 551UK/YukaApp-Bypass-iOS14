.text
.p2align 2

// gRPC's generated thread-local accessors in the supplied Yuka 4.38 build are
// treated by grpcpp as compiler TLS intrinsics: callers keep volatile registers
// live across them. iOS 14's Darwin TLV resolver is free to clobber those registers.
// These wrappers preserve every volatile GPR except x0 (the accessor return value)
// plus every vector register while the real accessor runs.

.macro YUKA_TLS_WRAPPER name, target
.globl _\name
.private_extern _\name
_\name:
    sub sp, sp, #0x2c0

    stp x1,  x2,  [sp, #0x000]
    stp x3,  x4,  [sp, #0x010]
    stp x5,  x6,  [sp, #0x020]
    stp x7,  x8,  [sp, #0x030]
    stp x9,  x10, [sp, #0x040]
    stp x11, x12, [sp, #0x050]
    stp x13, x14, [sp, #0x060]
    stp x15, x16, [sp, #0x070]
    str x17,       [sp, #0x080]
    str x30,       [sp, #0x088]

    stp q0,  q1,  [sp, #0x0a0]
    stp q2,  q3,  [sp, #0x0c0]
    stp q4,  q5,  [sp, #0x0e0]
    stp q6,  q7,  [sp, #0x100]
    stp q8,  q9,  [sp, #0x120]
    stp q10, q11, [sp, #0x140]
    stp q12, q13, [sp, #0x160]
    stp q14, q15, [sp, #0x180]
    stp q16, q17, [sp, #0x1a0]
    stp q18, q19, [sp, #0x1c0]
    stp q20, q21, [sp, #0x1e0]
    stp q22, q23, [sp, #0x200]
    stp q24, q25, [sp, #0x220]
    stp q26, q27, [sp, #0x240]
    stp q28, q29, [sp, #0x260]
    stp q30, q31, [sp, #0x280]

    adrp x16, _\target@PAGE
    ldr  x16, [x16, _\target@PAGEOFF]
    blr  x16

    ldp q30, q31, [sp, #0x280]
    ldp q28, q29, [sp, #0x260]
    ldp q26, q27, [sp, #0x240]
    ldp q24, q25, [sp, #0x220]
    ldp q22, q23, [sp, #0x200]
    ldp q20, q21, [sp, #0x1e0]
    ldp q18, q19, [sp, #0x1c0]
    ldp q16, q17, [sp, #0x1a0]
    ldp q14, q15, [sp, #0x180]
    ldp q12, q13, [sp, #0x160]
    ldp q10, q11, [sp, #0x140]
    ldp q8,  q9,  [sp, #0x120]
    ldp q6,  q7,  [sp, #0x100]
    ldp q4,  q5,  [sp, #0x0e0]
    ldp q2,  q3,  [sp, #0x0c0]
    ldp q0,  q1,  [sp, #0x0a0]

    ldr x30,       [sp, #0x088]
    ldr x17,       [sp, #0x080]
    ldp x15, x16, [sp, #0x070]
    ldp x13, x14, [sp, #0x060]
    ldp x11, x12, [sp, #0x050]
    ldp x9,  x10, [sp, #0x040]
    ldp x7,  x8,  [sp, #0x030]
    ldp x5,  x6,  [sp, #0x020]
    ldp x3,  x4,  [sp, #0x010]
    ldp x1,  x2,  [sp, #0x000]

    add sp, sp, #0x2c0
    ret
.endm

YUKA_TLS_WRAPPER YukaTimestampAccessorCompat, YukaTimestampAccessorTarget
YUKA_TLS_WRAPPER YukaExecCtxAccessorCompat, YukaExecCtxAccessorTarget
YUKA_TLS_WRAPPER YukaCallbackExecCtxAccessorCompat, YukaCallbackExecCtxAccessorTarget
