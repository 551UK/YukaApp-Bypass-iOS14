# Yuka 4.38 and 5.3 compatibility findings

Compared the two supplied decrypted IPAs. Findings are specific to these files.

| Area | Yuka 4.38 | Yuka 5.3 | Action |
| --- | --- | --- | --- |
| Firebase client key | Old key | Different key | Replace before Firebase initialization |
| Firebase storage bucket | project-6706240203345572135.appspot.com | yuka-app | Match new configuration |
| Firebase project and Google app ID | Same | Same | Preserve |
| Backend base | https://goodtoucan.com/ALJPAW5/api embedded in endpoint strings | Same base in Config.plist | No host substitution needed |
| Vapor backend | https://vapor.goodtoucan.com | Same, in Config.plist | Preserve |
| App identity | 4.38 | 5.3 / build 2654 | Report new app version/build |
| Firebase SDK packaging | Separate frameworks, version 10.10.0 | Firebase code embedded in executable | Cannot replace compiled SDK by changing a version string |
| Remote Config defaults | Includes available_signup_methods=email | Key absent; additional defaults added | Do not blindly substitute newer defaults |

## Confirmed live result

On 14 September 2026, requested the same read-only Firebase project configuration endpoint with each IPA's client key and the same bundle identifier. No user credentials or tokens were used.

- 4.38 key: HTTP 400, `INVALID_ARGUMENT`, `API_KEY_INVALID`, “API key expired. Please renew the API key.”
- 5.3 key: HTTP 200.

This proves the old client configuration is rejected by that Firebase service. It does not independently prove the cause of the startup termination or that Firestore reads will succeed after replacement.

## Why previous request-only replacement was incomplete

Firebase 10.10.0 constructs default options through `+[FIROptions defaultOptionsDictionary]` and `initInternalWithOptionsDictionary:`. Its Firestore SDK is a separate client, not just ordinary NSURLSession product requests. Version 2.1.0 updates default options before construction and handles explicit configuration through `+[FIRApp configureWithName:options:]` with a fresh options object. It never changes an existing locked options instance.

The supplied FirebaseCore binary contains these selectors. The upstream source for tag 10.10.0 confirms the default-options path and that setters throw when editingLocked is set:

- https://github.com/firebase/firebase-ios-sdk/blob/10.10.0/FirebaseCore/Sources/FIROptions.m
- https://github.com/firebase/firebase-ios-sdk/blob/10.10.0/FirebaseCore/Sources/FIRApp.m

The old executable also contains calls to `swift_unexpectedError` from FirestoreBridge.swift paths (including source lines 51, 100, 176 and 229). These are possible trap sites, not a diagnosis: no matching crash program counter has been collected.

## Scope and remaining verification

The repair preserves authentication, backend permissions, response bodies and existing API schema headers. Newer response schemas cannot safely be assumed compatible with old model parsers. It reports iOS 16.2 in an existing X-osv network header, but leaves local OS availability checks accurate to avoid calling unavailable iOS APIs.

Install on the device, enable injection for Yuka, respring, and test an online launch and food scan. `Documents/YukaRepair.txt` records whether the current Firebase key was used, HTTP status/reason codes and document-read errors without logging credentials, full request URLs or product data.
