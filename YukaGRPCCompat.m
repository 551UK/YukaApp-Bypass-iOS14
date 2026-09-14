#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

typedef void *(*YukaTLVThunk)(void *);
typedef struct {
    YukaTLVThunk thunk;
    uintptr_t key;
    uintptr_t offset;
} YukaTLVDescriptor;

static NSString *CompatLogPath;
static YukaTLVDescriptor *TimeSourceDescriptor;
static YukaTLVDescriptor *GuardDescriptor;
static YukaTLVThunk OriginalTimeSourceThunk;
static YukaTLVThunk OriginalGuardThunk;
static BOOL Installed;

static void CompatLog(NSString *line) {
    if (!CompatLogPath || !line) return;
    NSData *data = [[NSString stringWithFormat:@"%@ %@\n", NSDate.date, line] dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(CompatLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) { (void)write(fd, data.bytes, data.length); close(fd); }
}

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

// The iOS 14 crash occurs because grpcpp keeps its ScopedTimeCache pointer in x10
// across the Timestamp TLS accessor. The accessor itself calls the Darwin TLV
// resolver, which is allowed to clobber volatile x10 on this OS. preserve_all makes
// this tiny shim save x10 (and the other volatile registers) around that resolver.
__attribute__((preserve_all, noinline))
static void *PreserveTLVRegisters(void *descriptor) {
    YukaTLVThunk thunk = NULL;
    if (descriptor == TimeSourceDescriptor) thunk = OriginalTimeSourceThunk;
    else if (descriptor == GuardDescriptor) thunk = OriginalGuardThunk;
    if (!thunk) return NULL;
    return thunk(descriptor);
}

static void InstallCompatibility(void) {
    if (Installed) return;

    const struct mach_header_64 *grpc = FindImage("/grpc.framework/grpc");
    const struct mach_header_64 *grpcpp = FindImage("/grpcpp.framework/grpcpp");
    if (!grpc || !grpcpp) {
        CompatLog(@"gRPC images not loaded; compatibility shim not installed");
        return;
    }

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
        Instruction(grpcpp, 0x495c) == 0xaa0003ea && // mov x10, x0
        Instruction(grpcpp, 0x4960) == 0xf8038d48 && // str x8, [x10,#0x38]!
        Instruction(grpcpp, 0x4974) == 0xf900000a && // str x10, [x0]
        Instruction(grpcpp, 0x4984) == 0xf9000148 && // str x8, [x10] (faulting instruction)
        Instruction(grpc, 0x1d5078) == 0xd63f01e0 && // blr x15 (TLS guard resolver)
        Instruction(grpc, 0x1d5090) == 0xd63f0120;   // blr x9  (TLS value resolver)

    CompatLog([NSString stringWithFormat:@"target check: build-id=%@ instructions=%@", ids ? @"match" : @"mismatch", bytes ? @"match" : @"mismatch"]);
    if (!ids || !bytes) {
        CompatLog(@"Exact supplied Yuka 4.38 gRPC build not detected; refusing to patch");
        return;
    }

    // Verified from the supplied grpc.framework UUID above. These are the two
    // consecutive __thread_vars descriptors used by Timestamp's TLS wrapper:
    // thread_local_time_source_E at 0x37b4c8 and its ___tls_guard at 0x37b4e0.
    TimeSourceDescriptor = (YukaTLVDescriptor *)((uint8_t *)grpc + 0x37b4c8);
    GuardDescriptor = (YukaTLVDescriptor *)((uint8_t *)grpc + 0x37b4e0);
    OriginalTimeSourceThunk = TimeSourceDescriptor->thunk;
    OriginalGuardThunk = GuardDescriptor->thunk;

    if (!OriginalTimeSourceThunk || !OriginalGuardThunk ||
        OriginalTimeSourceThunk == PreserveTLVRegisters || OriginalGuardThunk == PreserveTLVRegisters) {
        CompatLog(@"TLS descriptors were not in the expected unpatched state");
        return;
    }

    TimeSourceDescriptor->thunk = PreserveTLVRegisters;
    GuardDescriptor->thunk = PreserveTLVRegisters;
    Installed = YES;
    CompatLog(@"Installed register-preserving wrappers for Timestamp TLS accessors");
}

__attribute__((constructor)) static void InitializeGRPCCompatibility(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"yuca.scanner"]) return;
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        CompatLogPath = [docs stringByAppendingPathComponent:@"YukaGRPCCompat.txt"];
        NSString *previous = [docs stringByAppendingPathComponent:@"YukaGRPCCompat-previous.txt"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:previous error:NULL];
        if ([fm fileExistsAtPath:CompatLogPath]) [fm moveItemAtPath:CompatLogPath toPath:previous error:NULL];
        CompatLog(@"Yuka gRPC compatibility 2.1.2 loaded");
        InstallCompatibility();
    }
}
