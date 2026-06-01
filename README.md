# Photo Cleaner

iOS app for triaging your local Photos library AND Google Photos via Tinder-style swipes. Built in SwiftUI; the Google Photos integration runs photos.google.com inside a `WKWebView` and drives Google's internal RPCs (`rJ0tlb` for library bounds + count, `EzkLib` for date-based photo search, `XwAOJf` for trash) so random batches sample uniformly across the user's entire library, not just what's currently rendered.

## Run locally

1. Open `PhotoCleaner.xcodeproj` in Xcode 16+
2. Select the **PhotoCleaner** scheme + an iOS 17+ simulator
3. ⌘R to build and run

To run on **your own device**:
1. Plug your iPhone in, trust the Mac
2. In Xcode: Signing & Capabilities → Team → your Apple Developer Team
3. Pick your iPhone as the run destination, ⌘R
4. On your phone: Settings → General → VPN & Device Management → trust the dev cert

## Deploy to TestFlight (GitHub Actions + Fastlane Match)

Mirrors the dennis3paul-org/Trio pattern: every push to `main` triggers a GitHub Actions run that builds the IPA and pushes it to TestFlight. Certificates and provisioning profiles live in the shared `dennis3paul-org/Match-Secrets` repo and are fetched at build time via `fastlane match`.

### One-time setup

1. **Push this repo to the `dennis3paul-org` GitHub organization**:
   ```bash
   git remote add origin https://github.com/dennis3paul-org/photo-cleaner.git
   git push -u origin main
   ```
   Org-level secrets (`TEAMID`, `GH_PAT`, `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY`, `MATCH_PASSWORD`) inherit automatically.

2. **Create the App Store Connect app record** (if you haven't already):
   - [App Store Connect](https://appstoreconnect.apple.com) → My Apps → ➕ New App
   - Bundle ID: `com.dennispaul.PhotoCleaner`
   - Name + primary language (default everything else)

3. **Run the "Provision Certificates" workflow once**:
   - GitHub → Actions tab → "Provision Certificates" → "Run workflow"
   - This registers the bundle ID + adds the App Store profile for `com.dennispaul.PhotoCleaner` into Match-Secrets

Once that workflow succeeds, the regular **Build PhotoCleaner** workflow takes over for every push.

### Ongoing builds

- **On push to `main`**: `Build PhotoCleaner` triggers automatically → builds the IPA → uploads to TestFlight (~10-15 min compile/sign/upload + another 10-20 min for Apple's processing)
- **Manual trigger**: Actions tab → "Build PhotoCleaner" → "Run workflow"

The workflow:
1. Pulls cert + profile from Match-Secrets via `fastlane match`
2. Bumps the build number to `latest_testflight + 1`
3. Builds for `app-store` export
4. Uploads via App Store Connect API key (no Apple ID password / 2FA dance)

### Lanes (for local invocation)

```bash
# Sanity-check that all env vars + match repo work end-to-end:
bundle exec fastlane validate_secrets

# Manually provision certs (CI does this automatically via the workflow):
bundle exec fastlane certs

# Build the IPA locally:
bundle exec fastlane build_app

# Push the last-built IPA to TestFlight:
bundle exec fastlane release
```

For local runs you'd need the same env vars set (TEAMID, GH_PAT, FASTLANE_KEY_ID, FASTLANE_ISSUER_ID, FASTLANE_KEY, MATCH_PASSWORD, GITHUB_REPOSITORY_OWNER=dennis3paul-org). Easier to let CI do it.

## Project structure

```
PhotoCleaner/                  # Swift sources
├── PhotoCleanerApp.swift       # @main + WindowGroup
├── AppModel.swift              # State machine: idle → pickBatch → triage → cleanup
├── IdleView.swift              # Library landing card
├── PickBatchView.swift         # Local gallery + Random + Videos-only
├── TriageView.swift            # Local swipe UI
├── LocalCleanupView.swift      # PHAssetChangeRequest.deleteAssets
├── GooglePhotosView.swift      # GP WebView container + Random pill
├── GooglePhotosWebView.swift   # WKWebView + JS bundle for GP RPCs
├── GPSwipeView.swift           # GP swipe UI
├── GPCleanupView.swift         # GP XwAOJf bulk delete
├── WebVideoPlayer.swift        # HTML5 <video> in WKWebView with cookie sharing
├── VideoFilePrefetcher.swift   # URLSession → tmp file for instant playback
├── PCVideoSchemeHandler.swift  # pcvideo:// scheme for local files
├── PHAssetImage.swift          # PhotoKit thumbnail loader
└── …

fastlane/
├── Fastfile                    # build_app, release, certs, identifiers, validate_secrets lanes
└── Matchfile                   # Points at dennis3paul-org/Match-Secrets

.github/workflows/
├── build.yml                   # Push to main → build + TestFlight
└── provision_certs.yml         # Manual: register bundle ID + populate Match-Secrets
```
