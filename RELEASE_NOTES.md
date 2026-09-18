Fixes fresh email login on Yuka 4.38.

The legacy FirebaseUI email screen could dismiss back to the "Let's go" screen when its sign-in-method lookup failed. This build adds retry/fallback handling so the user can continue to the password screen instead of being kicked back.

The working Firebase, scanning/history and iOS 14 gRPC TLS fixes are unchanged.
