# Yuka App Bypass iOS 14

Rootful tweak for **Yuka 4.38** on **iOS 14**.

It restores Yuka's online functionality, including startup, history, product lookup and barcode scanning.

## What was actually broken

Yuka 4.38 still contains an older Firebase / Firestore stack and an older gRPC build. Two separate compatibility problems appeared when the app contacted the current backend from iOS 14.

First, Yuka's bundled Firebase configuration had become stale. The app was still using an old Firebase API key and the old storage bucket value. The tweak repairs those values before Firebase finishes configuring, while keeping the rest of Yuka's original configuration intact. It also presents the current Yuka app version/build identity to the app and network requests where the backend expects it.

The harder crash was lower-level and was not a normal version check. Once Firestore started networking, Yuka crashed inside its bundled `grpcpp` framework at `grpcpp + 0x4984` in the `grpc_core::ExecCtx` path. The instruction was writing through a pointer held in ARM64 register `x10`.

The old gRPC code assumes several volatile ARM64 registers survive its thread-local-storage accessors. On iOS 14, the Darwin TLS / lazy-binding path is allowed to clobber those volatile registers. On the first TLS access, the call can also pass through dyld's lazy symbol binder before reaching the real TLS resolver. That meant the pointer in `x10` could already be destroyed by the time gRPC returned to the instruction that uses it, causing a repeatable `SIGSEGV` at the same `grpcpp + 0x4984` address.

The first compatibility attempt only wrapped the inner TLS resolver. That was not enough because the register could be clobbered earlier by the lazy-binding path.

## The final fix

The working fix targets the exact `grpc` and `grpcpp` builds shipped inside the supplied Yuka 4.38 IPA.

Before patching anything, the tweak verifies the framework UUIDs and the expected ARM64 instruction bytes. If they do not match the known Yuka 4.38 build, it refuses to patch unknown code.

For the matching build, the tweak replaces the affected gRPC thread-local lazy-import slots with small ARM64 assembly wrappers. These wrappers preserve the volatile register state across the complete TLS accessor path, including the first-call dyld lazy bind, then call the original target and restore the saved registers before returning to gRPC.

That prevents `x10` and the other live volatile registers from being destroyed while old gRPC expects them to remain valid. With that compatibility shim in place, Firestore can initialise normally on iOS 14 and Yuka stays open, loads history and scans products again.

## Target

- Yuka: **4.38**
- Bundle ID: `yuca.scanner`
- iOS: **14.x**
- Jailbreak packaging: **rootful**
- Architecture: **arm64 / arm64e**

## Notes

This is intentionally build-specific. The gRPC compatibility patch only activates for the exact framework build it was made for rather than blindly modifying other versions of Yuka.
