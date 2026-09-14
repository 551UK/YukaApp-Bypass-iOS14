# Yuka App Bypass iOS 14

Rootful tweak for **Yuka 4.38 on iOS 14**. It restores the app's online functions, including startup, history, product lookup and barcode scanning.

## What was broken

There were two separate problems.

### 1. Old Firebase / app identity

Yuka 4.38 ships with older Firebase configuration and identifies itself as an outdated app build. The current backend no longer accepts all of that old information.

The tweak repairs Yuka's Firebase configuration before Firebase finishes starting, replaces the outdated Firebase API key and storage bucket with the values used by the newer app, and presents the current Yuka app identity where the backend expects it.

Only network/app metadata is spoofed. iOS itself is still reported truthfully to runtime availability checks so Yuka does not try to call newer iOS APIs that do not exist on iOS 14.

### 2. Old gRPC crashes on iOS 14

This was the main problem.

Once Firestore started networking, Yuka repeatedly crashed inside its bundled `grpcpp` framework at:

`grpcpp + 0x4984`

The crashing code was using a pointer kept in ARM64 register `x10` across one of gRPC's thread-local-storage (TLS) accessors.

The old gRPC build bundled with Yuka assumes several volatile ARM64 registers stay intact across these TLS calls. On iOS 14 that assumption is unsafe: Darwin's TLS resolver, and especially the first-call dyld lazy-binding path, are allowed to overwrite those volatile registers.

So `x10` could contain a valid pointer before the TLS call, be clobbered during lazy binding/TLS resolution, then be used immediately afterwards. That produced the repeatable `SIGSEGV` at `grpcpp + 0x4984`.

An earlier attempt protected only the inner TLS resolver. It still crashed because the register could already be destroyed by dyld's lazy binder before that wrapper was reached.

## The working fix

The final fix intercepts the problem one level earlier.

The tweak first verifies that the loaded `grpc` and `grpcpp` frameworks are the exact builds from Yuka 4.38 by checking their UUIDs and known ARM64 instruction bytes. If they do not match, the gRPC patch is not applied.

For the matching build, it replaces the three affected gRPC TLS lazy-import slots:

- Timestamp TLS accessor
- ExecCtx TLS accessor
- Callback ExecCtx TLS accessor

Those imports are redirected to small ARM64 assembly wrappers before their first normal call. The wrappers save the volatile register state, call the real gRPC TLS accessor, then restore the saved state before returning to `grpcpp`.

The wrappers preserve `x1-x17`, `x30` and `q0-q31`; `x0` is left as the accessor return value.

That also covers the first dyld lazy-bind path, which was the part the earlier fix missed. The pointer in `x10` and the other live volatile values therefore survive exactly as the old gRPC code expects.

With that fixed, Firestore can initialise normally on iOS 14. Combined with the Firebase/app-identity repair, Yuka 4.38 can once again open online, load history and scan products.

## Notes

The gRPC compatibility patch is intentionally build-specific and only activates for the verified Yuka 4.38 framework build.

