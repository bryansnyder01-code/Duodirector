# DuoDirector: App Store submission checklist

Work top to bottom. Items marked **(Mac)** need Xcode on a Mac. Everything else happens in a browser, in the Apple Developer portal or App Store Connect.

## 0. First build (blocking everything else)
- [ ] **(Mac)** `brew install xcodegen && xcodegen generate`, then open `DuoDirector.xcodeproj`.
- [ ] **(Mac)** Set `DEVELOPMENT_TEAM` in `project.yml` (or Signing & Capabilities) to your team ID.
- [ ] **(Mac)** Build for the iPhone Duo simulator. Fix compile errors, starting with the API signatures in `Platform/DuoPlatformAPIs.swift`, since that's where unconfirmed iOS 27 APIs live.
- [ ] **(Mac)** Run ⌘U: unit tests (`DuoDirectorTests`) and UI tests (`DuoDirectorUITests`).
- [ ] **(Mac)** Install on a real iPhone Duo and go through every "verify on hardware" list in the README (Phases 1–8), including the HaishinKit `VERIFY` items.
- [ ] **(Mac)** Clear the strict-concurrency warnings, then set `SWIFT_VERSION: "6.0"` (optional for 1.0).

## 1. Identifiers & capabilities (developer.apple.com › Certificates, Identifiers & Profiles)
- [ ] App ID `com.duodirector.app` (or yours; then update `project.yml`, `DuoDirector.entitlements`, `CloudSyncController.containerIdentifier`).
- [ ] iCloud capability with **iCloud Documents**, plus the container `iCloud.com.duodirector.app`.
- [ ] No other entitlements are needed. Camera, mic, Photos add-only and local network are covered by Info.plist usage strings.

## 2. App Store Connect record
- [ ] New app: platform iOS, name, primary language English (U.S.), bundle ID above, SKU.
- [ ] Category: **Photo & Video** (secondary: Productivity).
- [ ] Price and availability.
- [ ] Localizations: English + Spanish (the app ships `es` via String Catalogs). Add Spanish metadata, or remove `es` from `CFBundleLocalizations`.

## 3. Privacy
- [ ] **App Privacy (nutrition label): "Data Not Collected."** Everything stays on device or in the user's own iCloud. Nothing is sent to us, and there are no analytics or ads.
- [ ] Privacy policy URL (required even for "Data Not Collected"). Draft: `docs/PRIVACY_POLICY.md`. Host it, then set `AboutView.privacyPolicyURL`. It should say: camera, microphone and Photos are used only to record and save the user's videos; optional iCloud sync goes to the user's own iCloud; Remote Producer connects only to nearby devices the user approves.
- [ ] `PrivacyInfo.xcprivacy` is already in the bundle (DiskSpace E174.1, UserDefaults CA92.1). Re-check it after the first build with Xcode's *Generate Privacy Report* (Product › Archive › right-click).
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption = NO` is set (only OS-provided encryption); RTMPS uses the OS TLS stack and SRT isn't linked).
- [ ] Go Live (Phase 8) still fits "Data Not Collected": video goes only to the server the user enters, with their own stream key, and nothing reaches us. Mention it in the privacy policy ("if you use Go Live, your video is sent to the streaming service you choose").
- [ ] **Decided 2026-11-24: 1.0 ships WITHOUT remote guests.** Build 1.0 from `project.yml`, and leave Remote guest out of the App Review notes. Guests come in 1.1 from `project-guests.yml`.
- [ ] **Remote guests (Phase 9) decide the encryption answer.** Built from `project.yml` (no LiveKit), keep `ITSAppUsesNonExemptEncryption = NO`. Built from `project-guests.yml`, it's YES, because WebRTC adds DTLS-SRTP. App Store Connect then asks whether the app qualifies for an exemption. Standard protocols in a mass-market app usually do, but check Apple's export-compliance guidance (or ask counsel) before answering. This is not legal advice.
- [ ] Guests still fit "Data Not Collected" as long as the LiveKit project and token endpoint belong to the user, not to you. If you host a shared LiveKit project for users, the answer changes (audio and video pass through your servers).
- [ ] Third-party SDK: LiveKit client-sdk-swift (Apache-2.0) in the guests build.
- [x] Third-party SDK: HaishinKit (BSD-3-Clause). Its license is shown in Diagnostics › About & acknowledgements (check the text against the resolved version).

## 4. Accessibility Nutrition Labels (App Store Connect › Accessibility)
Claim only what you've tested on device:
- [ ] VoiceOver: controls have labels, and banners plus record start/stop are announced. Test the full record → marker → stop flow with VoiceOver on.
- [ ] Larger Text: test at AX sizes. Some HUD text uses fixed sizes (meters, cover monitor), so don't claim this until checked.
- [ ] Dark Interface: yes (the app is dark-only).
- [ ] Captions / Audio Descriptions: not applicable (it's a recording app).

## 5. Screenshots & previews
- [ ] **(Mac)** `scripts/capture-screenshots.sh "iPhone Duo" Screenshots/` captures five PNGs (cover, flat dual-cam, tabletop, takes, diagnostics).
- [ ] Check which display sizes App Store Connect asks for iPhone Duo. If it wants the 5.4" cover set separately, use `01-cover-5.4in-monitor`.
- [ ] Optional App Preview video: record the Simulator in Demo Mode, rolling a take in tabletop.
- [ ] Screenshots must not show "SIMULATED" captions (Demo Mode hides them) or a non-9:41 status bar (the script overrides it).

## 6. App Review notes (paste into "Notes")
> DuoDirector is a video production app for iPhone Duo.
> • Cover display: with the device open, the 5.4" outer display shows a live monitor and teleprompter (CameraCaptureAccessory). It appears automatically when recording with the device open.
> • Dual-Cam Podcast: the rail's "Solo 4K / Dual-Cam" button records the rear and inner cameras at once (AVCaptureMultiCamSession).
> • Demo Mode: overflow menu (•••) › Launch & Diagnostics › Demo Mode loads sample content so every feature can be reviewed without setup.
> • Remote Producer needs a second iPhone or iPad running DuoDirector on the same network. It's optional and peer-to-peer only.
> • iCloud sync is optional and off by default.
> • Go Live: overflow menu › Go Live streams to YouTube, Twitch or any RTMPS server with the user's own stream key. In Demo Mode it's simulated, so it can be reviewed without an account. To test a real stream, use any RTMP test server.
> • Remote guest: overflow menu › Remote guest. In Demo Mode a simulated guest joins, so it can be reviewed without a LiveKit account.
> No account or sign-in is required.

- [ ] Age rating questionnaire: no objectionable content, which gives **4+**.

## 6b. Metadata
- [ ] Paste name, subtitle, promo text, description and keywords from `docs/APP_STORE_METADATA.md` (English + Spanish).

## 7. Build upload
- [ ] **No Mac needed:** push to GitHub with the four secrets in `.github/workflows/ios.yml`, then Actions › iOS › Run workflow › upload. The build number comes from the run number automatically.
- [ ] **(Mac)** Product › Archive (Release, generic iOS device) › Distribute App › App Store Connect › Upload.
  Or set up CI: a GitHub Actions macOS runner with `xcodebuild archive` + `xcrun altool`/`notarytool` and an App Store Connect API key stored as a secret.
- [ ] Bump `CFBundleVersion` in `project.yml` for every upload. `CFBundleShortVersionString` stays `1.0` for the first release.
- [ ] TestFlight: internal testers first. Check the cover display, dual-cam, thermal behaviour on a long take, iCloud on two devices, and a 30-minute live stream.
- [ ] Submit for review.

## 8. After approval
- [ ] Watch crash reports (Xcode Organizer) for the first week, especially MultiCam configuration on devices that don't fully support it.
- [ ] Next roadmap items are in the README.
