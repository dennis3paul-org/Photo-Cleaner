# Photo Cleaner

A SwiftUI iOS app for triaging your photo library — Tinder-style swipes to mark photos for deletion across both your **local iOS Photos library** AND **Google Photos**.

Right-swipe to keep, left-swipe to delete. Confirm a batch and the actual deletion runs as one bulk operation.

## Features

- **Local library** (PhotoKit): triage on-device or iCloud photos. Browse the gallery, optionally filter to videos only, or grab a random batch of 10/25/50/100/200. Cleanup uses one `PHAssetChangeRequest.deleteAssets` call so iOS's system "Move N photos to Recently Deleted?" dialog covers the whole batch.
- **Google Photos**: signs in via an embedded `WKWebView` and drives Google's internal RPCs directly:
  - `rJ0tlb` sniffed at page bootstrap → library total count + date histogram
  - `EzkLib` per-date search → fast lookup of photos by creation date
  - `XwAOJf` multi-token trash RPC → one HTTP call deletes the whole queue
  - Random batches sample uniformly across the user's entire library lifespan (via the rJ0tlb date bounds), not just what's currently rendered in the grid.
- **Instant-feel video playback** in the swipe deck: `WebVideoPlayer` mounts an HTML5 `<video>` element inside a `WKWebView` that shares cookies with the main GP session, so authenticated `=dv` URLs play natively. `URLSession` pre-downloads upcoming videos to a local tmp file served via a custom `pcvideo://` URL scheme, so playback starts in ~50-100ms instead of waiting for a fresh network roundtrip.
- **File sizes** shown on every card and summed in the cleanup summary ("Will free 124 MB" / "Freed X MB").
- **Undo** via header button or iOS shake gesture.

## Build locally

1. Open `PhotoCleaner.xcodeproj` in Xcode 16+
2. Select the **PhotoCleaner** scheme + an iOS 17+ simulator
3. ⌘R to build and run

To run on a physical device:
1. Plug your iPhone in
2. Signing & Capabilities → Team → your Apple Developer Team
3. Pick the device as the run destination, ⌘R
4. On the phone: Settings → General → VPN & Device Management → trust the dev cert

## TestFlight via GitHub Actions

`.github/workflows/build.yml` builds and uploads to TestFlight on every push to `main`. `provision_certs.yml` is a one-time manual workflow that registers the bundle ID and provisions the App Store distribution profile via [`fastlane match`](https://docs.fastlane.tools/actions/match/).

### Required secrets

Both workflows expect these to be available (either as org-level secrets or as repo-level secrets):

| Secret | What it is |
|---|---|
| `TEAMID` | Apple Developer Team ID |
| `GH_PAT` | GitHub Personal Access Token (repo + workflow scope) — for accessing the private Match-Secrets repo |
| `FASTLANE_KEY_ID` | App Store Connect API Key ID |
| `FASTLANE_ISSUER_ID` | App Store Connect API Key Issuer ID |
| `FASTLANE_KEY` | The `.p8` API key contents (raw PEM OR base64-encoded — the Fastfile auto-detects) |
| `MATCH_PASSWORD` | Passphrase encrypting the match certs repo |

The Matchfile expects a private repo at `https://github.com/<GITHUB_REPOSITORY_OWNER>/Match-Secrets.git` (auto-resolved from the runner's env, so it works for forks).

### First-time setup

1. Push to GitHub
2. Run **Actions → Provision Certificates → Run workflow** once — registers the bundle ID on App Store Connect and adds the distribution profile to Match-Secrets
3. Subsequent pushes to `main` auto-trigger **Build PhotoCleaner** which uploads to TestFlight

### Fastlane lanes

```bash
bundle exec fastlane validate_secrets      # sanity-check env vars + match repo access
bundle exec fastlane certs                 # provision App Store profile via match
bundle exec fastlane build_photo_cleaner   # build the IPA
bundle exec fastlane release               # upload to TestFlight
```

## Project structure

```
PhotoCleaner/                   # Swift sources
├── PhotoCleanerApp.swift        # @main + WindowGroup
├── AppModel.swift               # State machine: idle → pickBatch → triage → cleanup
├── IdleView.swift               # Two-card landing screen (Local + Google Photos)
├── PickBatchView.swift          # Local gallery grid + Random + Videos-only filter
├── TriageView.swift             # Local PhotoKit swipe UI
├── LocalCleanupView.swift       # PHAssetChangeRequest.deleteAssets
├── GooglePhotosView.swift       # GP WebView container + bottom-bar Random pill
├── GooglePhotosWebView.swift    # WKWebView + injected JS for GP RPC sniffing/calls
├── GPSwipeView.swift            # GP swipe UI with pre-mounted next-card players
├── GPCleanupView.swift          # GP XwAOJf bulk delete + native UI fallback
├── WebVideoPlayer.swift         # HTML5 <video> in WKWebView (cookie sharing)
├── VideoFilePrefetcher.swift    # URLSession → tmp file for instant playback
├── PCVideoSchemeHandler.swift   # pcvideo:// scheme for local-file playback
├── PHAssetImage.swift           # PhotoKit thumbnail loader + ByteFormatter
├── SwipeCard.swift              # Generic swipe-card chrome
├── ShakeGesture.swift           # iOS shake-to-undo wrapper
├── GooglePhotosLogo.swift       # Pinwheel Canvas drawing
└── BatchScope.swift             # Local scope filter enum

fastlane/
├── Fastfile                     # build/release/certs/identifiers lanes
└── Matchfile                    # Match repo URL (env-templated)

.github/workflows/
├── build.yml                    # Push to main → TestFlight
└── provision_certs.yml          # Manual: register bundle ID + populate match
```

## How the Google Photos integration works

Google doesn't publish a Photos API that supports deletion. The official Photos Library API gives read access to a "Photos" partition but can't delete. The Picker API gives access via user-selected media but also can't delete.

Photo Cleaner gets around this the same way the open-source Chrome extension does: signs the user into photos.google.com in a `WKWebView` and calls Google's own internal RPCs the same way the JS in their web app does. The relevant endpoints are all under `https://photos.google.com/_/PhotosUi/data/batchexecute`:

- **`rJ0tlb`** is called on every page bootstrap to populate the date sidebar. Its response contains the user's total media count and a histogram bucketing all photos by date. A document-start fetch+XHR sniffer captures the response and parses out `[oldestMs, newestMs, totalCount]`.
- **`EzkLib`** searches the library by date string. Given "May 23, 2026" it returns every photo on that day with its action token. The random batch builder picks N random ms positions across `[oldestMs, newestMs]`, formats each as a date, calls EzkLib in parallel, dedups by photo id.
- **`XwAOJf`** is the trash RPC. It takes a variadic array of action tokens in one request — up to ~100 photos trashed in a single HTTP call. Defensive halving handles partial failures.

WIZ tokens (`SNlM0e` / `cfb2h` / `FdrFJe`) for these requests come straight from `window.WIZ_global_data` injected into the page by Google.

All this is purely client-side — the user's session, the user's cookies, the user's tokens. No proxying through any third-party server.

## License

MIT — see [LICENSE](LICENSE) if present.
