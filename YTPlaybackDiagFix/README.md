# YouTube Playback Diag Fix

Rootful iOS 12-14 tweak for `com.google.ios.youtube`.

It logs:
- YouTube / googlevideo / youtubei NSURLSession activity
- HTTP status codes and NSError failures
- AVPlayer stalls and failed-to-play events
- AVPlayer error/access-log details

It deliberately avoids cookies, Authorization headers, and most signed URL parameters.

It also performs one conservative AVPlayer `play` retry after an actual playback-stalled notification, with an 8-second cooldown. It does not attempt to bypass server-side 403/410 errors.

Log file:
`/var/mobile/Library/Logs/YTPlaybackDiag.log`

After installing, force-close YouTube, reopen it, reproduce one failing video, then collect the log.
