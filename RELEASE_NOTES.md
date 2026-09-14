Targets the confirmed `grpcpp+0x4984` iOS 14 crash from Yuka 4.38.

2.1.3 replaces the three gRPC thread-local lazy imports with register-preserving wrappers, including the first-call dyld bind path that 2.1.2 did not cover. Firebase repair remains included.

Install, respring, then open Yuka online. If it still closes, send `YukaGRPCCompat.txt`, `YukaCrash.txt`, and `YukaRepair.txt` from Yuka's Documents folder.
