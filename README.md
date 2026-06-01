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

## Deploy to TestFlight via GitHub Actions

The repo includes `fastlane/Fastfile` + `.github/workflows/testflight.yml` for fully automated TestFlight builds on every push to `main`. One-time setup below.

### 1. App Store Connect app record

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com)
2. **My Apps → ➕ New App**
3. Bundle ID: `com.dennispaul.PhotoCleaner` (must match the Xcode project)
4. Pick a name + primary language. Default everything else.

### 2. App Store Connect API key

This is how the CI uploads builds without your Apple ID password / 2FA.

1. **Users and Access → Integrations → App Store Connect API**
2. **Generate API Key** with **App Manager** access
3. Copy the **Issuer ID** (top of the page)
4. Copy the **Key ID** (from the new key's row)
5. Download the `.p8` file — **you can only download it once**

### 3. Code signing certificate + provisioning profile

The easiest path: do one local archive in Xcode so it auto-creates these, then export them.

1. In Xcode: **Signing & Capabilities → Team → select yours**, Signing Style: **Manual**
2. **Product → Archive** (you can cancel the upload — we just want the cert + profile created)
3. **Distribution Certificate (.p12):**
   - Open Keychain Access (macOS app)
   - Login keychain → "My Certificates" → find **"Apple Distribution: Your Name (TEAMID)"**
   - Right-click → **Export** → choose `.p12` format → set a strong password (you'll need it later)
4. **Provisioning Profile (.mobileprovision):**
   - Open `~/Library/MobileDevice/Provisioning Profiles/` in Finder
   - Find the most recently-modified `.mobileprovision` for your app — it's named with a UUID
   - Note the **profile name** (you'll need it). To see the name, double-click the file → "Profile Name" in the dialog. Or run:
     ```bash
     security cms -D -i ~/Library/MobileDevice/Provisioning\ Profiles/<UUID>.mobileprovision | plutil -extract Name xml1 -o - -
     ```

### 4. GitHub repository + Secrets

Create the GitHub repo:
```bash
# From inside this directory, after `git init`:
gh repo create photo-cleaner --private --source=. --remote=origin
git push -u origin main
```
(Or create the repo via the web UI and `git remote add origin …`.)

Then **Settings → Secrets and variables → Actions → New repository secret**. Add each:

| Secret name | What it is | How to get it |
|---|---|---|
| `APP_STORE_CONNECT_KEY_ID` | The key's ID (~10 chars) | App Store Connect → API key row |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID (UUID format) | App Store Connect → API keys page header |
| `APP_STORE_CONNECT_KEY_CONTENT` | The `.p8` file contents (full text including `-----BEGIN PRIVATE KEY-----`) | `cat AuthKey_XXX.p8 \| pbcopy` |
| `DEVELOPER_TEAM_ID` | Your 10-char Team ID | App Store Connect → Membership |
| `BUILD_CERTIFICATE_BASE64` | The `.p12` file, base64-encoded | `base64 -i Certificates.p12 \| pbcopy` |
| `P12_PASSWORD` | Password you set when exporting the .p12 | (you chose this) |
| `BUILD_PROVISION_PROFILE_BASE64` | The `.mobileprovision`, base64-encoded | `base64 -i profile.mobileprovision \| pbcopy` |
| `PROVISIONING_PROFILE_NAME` | The profile's "Name" field | from step 3.4 above |
| `KEYCHAIN_PASSWORD` | Any string (ephemeral temp-keychain password) | e.g. `openssl rand -base64 24` |

### 5. First push

```bash
git add .
git commit -m "Initial commit"
git push -u origin main
```

The `TestFlight` workflow auto-triggers on push to `main`. Watch it run under the **Actions** tab. First build typically takes ~10-15 minutes; TestFlight processing on Apple's side another ~10-20 minutes after that.

### Build locally (without TestFlight upload)

```bash
bundle install
DEVELOPER_TEAM_ID=YOURTEAM PROVISIONING_PROFILE_NAME="Your Profile Name" \
  bundle exec fastlane gym \
    --project PhotoCleaner.xcodeproj --scheme PhotoCleaner \
    --export_method app-store --output_directory build
```

Or just keep using Xcode's `⌘B` / `⌘R`.

## Project structure

```
PhotoCleaner/                 # Swift sources
├── PhotoCleanerApp.swift      # @main + WindowGroup
├── AppModel.swift             # State machine: idle → pickBatch → triage → cleanup
├── IdleView.swift             # Library landing card
├── PickBatchView.swift        # Local gallery + Random + Videos-only
├── TriageView.swift           # Local swipe UI
├── LocalCleanupView.swift     # PHAssetChangeRequest.deleteAssets
├── GooglePhotosView.swift     # GP WebView container + Random pill
├── GooglePhotosWebView.swift  # WKWebView + JS bundle for GP RPCs
├── GPSwipeView.swift          # GP swipe UI
├── GPCleanupView.swift        # GP XwAOJf bulk delete
├── WebVideoPlayer.swift       # HTML5 <video> in WKWebView with cookie sharing
├── VideoFilePrefetcher.swift  # URLSession → tmp file for instant playback
├── PCVideoSchemeHandler.swift # pcvideo:// scheme for local files
├── PHAssetImage.swift         # PhotoKit thumbnail loader
└── …

fastlane/                      # Fastfile + Appfile (TestFlight build lane)
.github/workflows/             # CI: build + upload on push to main
```
