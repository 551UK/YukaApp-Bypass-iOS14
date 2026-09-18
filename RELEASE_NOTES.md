Restores email account sign-up on Yuka 4.38.

Version 2.1.7 keeps the working 2.1.6 sign-in retry/fallback unchanged. It only re-enables the legacy FirebaseUI `allowNewEmailAccounts` path so an email with no existing account can continue into Yuka's already-bundled password sign-up controller.

The Firebase repair, app-identity spoof, scanning/history support and iOS 14 gRPC TLS compatibility fix are unchanged.
