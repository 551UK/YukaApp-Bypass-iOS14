#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>

extern void *YukaGRPCWrapTimeSource(void *descriptor);
extern void *YukaGRPCWrapGuard(void *descriptor);
extern void *YukaGRPCWrapExecCtx(void *descriptor);

void *YukaGRPCOriginalTimeSource = NULL;
void *YukaGRPCOriginalGuard = NULL;
void *YukaGRPCOriginalExecCtx = NULL;

typedef struct {
    void *thunk;
    uintptr_t key;
    uintptr_t offset;
} YukaTLVDescriptor;

static BOOL PathHasSuffix(const char *path, const char *suffix) {
    if (!path || !suffix) return NO;
    size_t a = strlen(path), b = strlen(suffix);
    return a >= b && memcmp(path + a - b, suffix, b) == 0;
}

static const struct mach_header_64 *FindImage(const char *suffix) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (PathHasSuffix(path, suffix))
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

static BOOL UUIDMatches(const struct mach_header_64 *header, const uint8_t expected[16]) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc)) return NO;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uc = (const struct uuid_command *)lc;
            return memcmp(uc->uuid, expected, 16) == 0;
        }
        cursor += lc->cmdsize;
    }
    return NO;
}

static uint32_t Instruction(const struct mach_header_64 *header, uintptr_t offset) {
    uint32_t value = 0;
    memcpy(&value, (const uint8_t *)header + offset, sizeof(value));
    return value;
}

static void InstallCompatibility(void) {
    const struct mach_header_64 *grpc = FindImage("/grpc.framework/grpc");
    const struct mach_header_64 *grpcpp = FindImage("/grpcpp.framework/grpcpp");
    if (!grpc || !grpcpp) return;

    static const uint8_t grpcUUID[16] = {
        0xfc, 0xcf, 0xd2, 0xbd, 0x9a, 0x6e, 0x33, 0xa2,
        0xa3, 0x2e, 0x2d, 0xf1, 0x80, 0xce, 0xf5, 0x8b
    };
    static const uint8_t grpcppUUID[16] = {
        0x0a, 0x58, 0xee, 0x4a, 0x18, 0xc1, 0x36, 0xb1,
        0xbd, 0xd2, 0xaf, 0x7a, 0x41, 0xa4, 0xbb, 0xd1
    };

    BOOL ids = UUIDMatches(grpc, grpcUUID) && UUIDMatches(grpcpp, grpcppUUID);
    BOOL bytes =
        Instruction(grpcpp, 0x495c) == 0xaa0003ea &&
        Instruction(grpcpp, 0x4960) == 0xf8038d48 &&
        Instruction(grpcpp, 0x4974) == 0xf900000a &&
        Instruction(grpcpp, 0x4984) == 0xf9000148 &&
        Instruction(grpc, 0x1d5078) == 0xd63f01e0 &&
        Instruction(grpc, 0x1d5090) == 0xd63f0120;

    if (!ids || !bytes) return;

    YukaTLVDescriptor *timeSource = (YukaTLVDescriptor *)((uint8_t *)grpc + 0x37b4c8);
    YukaTLVDescriptor *guard = (YukaTLVDescriptor *)((uint8_t *)grpc + 0x37b4e0);

    if (!timeSource->thunk || !guard->thunk) return;

    YukaGRPCOriginalTimeSource = timeSource->thunk;
    YukaGRPCOriginalGuard = guard->thunk;
    YukaGRPCOriginalExecCtx = guard->thunk;

    timeSource->thunk = (void *)YukaGRPCWrapTimeSource;
    guard->thunk = (void *)YukaGRPCWrapGuard;
}

__attribute__((constructor)) static void InitializeGRPCCompatibility(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"yuca.scanner"]) return;
        InstallCompatibility();
    }
}
