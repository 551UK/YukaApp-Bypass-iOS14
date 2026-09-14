Updates the expired Firebase key before Firebase starts, matches the newer storage configuration, and reports Yuka 5.3. Includes a diagnostic log in Yuka’s Documents folder: YukaRepair.txt.

The old key returned HTTP 400/API_KEY_INVALID in a configuration check; the 5.3 key returned HTTP 200. This fixes that confirmed configuration difference, but launch and scanning still need testing on the phone.

Install, enable Yuka tweak injection in Choicy, and respring.
