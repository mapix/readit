# Mac App Store release checklist — Readlet 1.0

Everything in this folder is ready to paste into App Store Connect. Steps marked **(you)** need your Apple account; the rest is automated by `build_mas.sh` / `upload_mas.sh`.

## 0. Decisions already made

| Item | Value |
|---|---|
| App name (store) | `Readlet – AI Bilingual Reader` (en) · `Readlet – AI 双语阅读` (zh-Hans) · `Readlet – AI 対訳リーダー` (ja) — all ≤ 30 chars |
| Name check | No app named "Readlet" on the Mac or iOS App Store (checked 2026-10-16 via the iTunes Search API). "Readit" is taken, hence the rename. |
| Bundle ID | `io.novarock.readlet` (also used by the direct-download edition) |
| SKU | `readlet-mac` |
| Price | **Free** (no in-app purchases). Keeping it free and open source is what allows *Sign in with ChatGPT* without OpenAI approval — a paid price or IAP would require applying first. |
| Category | Primary: Education · Secondary: Productivity |
| Age rating | 4+ (no objectionable content; user-generated web content is the user's own import — answer "No" to all content questions; "Unrestricted web access": No — the app does not browse the web freely, it imports pages the user links) |
| Minimum macOS | 14.0, universal binary (Apple Silicon + Intel) |
| Encryption | Exempt (HTTPS only) — `ITSAppUsesNonExemptEncryption = false` in Info.plist |
| Privacy | "Data Not Collected" — see `app_privacy.md`; policy page `https://readit.novarock.io/privacy.html` |
| Support / marketing URL | `https://readit.novarock.io/support.html` · `https://readit.novarock.io` |

## 1. Apple Developer Program (you)

1. Enroll at <https://developer.apple.com/programs/> (USD 99/year). An organization account shows "Novarock" as the seller; an individual account shows your name.
2. App Store Connect → **Business**: the **Free Apps** agreement is accepted with the membership; no banking or tax forms are needed for a free app.

## 2. Identifiers, certificates, profile (you, ~15 min)

In <https://developer.apple.com/account/resources>:

1. **Identifiers → +** → App IDs → App → Bundle ID *explicit* `io.novarock.readlet`, description "Readlet". No extra capabilities are needed.
2. **Certificates → +**:
   - *Apple Distribution* (signs the app)
   - *Mac Installer Distribution* (signs the .pkg; shows as "3rd Party Mac Developer Installer")
   - (optional, for the website download) *Developer ID Application*
   Create the CSR with Keychain Access → Certificate Assistant → Request a Certificate…, download and double-click each certificate.
3. **Profiles → +** → *Mac App Store Connect* → App ID `io.novarock.readlet` → certificate *Apple Distribution* → download `Readlet_Mac_App_Store.provisionprofile`.
4. Find your Team ID (top right of the developer site, 10 characters).

Check the identities are installed: `security find-identity -v -p codesigning` and `security find-identity -v` (installer).

## 3. App Store Connect record (you)

App Store Connect → **Apps → + → New App**: platform macOS, name `Readlet – AI Bilingual Reader`, primary language English (U.S.), bundle ID `io.novarock.readlet`, SKU `readlet-mac`.

Then fill in, per language (en-US, zh-Hans, ja — add the localizations under *App Information*), from `metadata/<locale>/`:

| Field | File |
|---|---|
| Name | `name.txt` |
| Subtitle | `subtitle.txt` |
| Promotional text | `promotional_text.txt` |
| Description | `description.txt` |
| Keywords | `keywords.txt` |
| What's New | `release_notes.txt` |

Also: support URL, marketing URL, privacy policy URL (above), category, age rating, price (**Pricing and Availability → Free**), **App Privacy** (from `app_privacy.md`), copyright `© 2026 Novarock`, and App Icon (`AppStore/AppIcon-1024.png` — 1024×1024 RGB PNG without alpha).

Screenshots: ready-to-upload 2880×1800 PNGs for `en-US`, `zh-Hans`, and `ja` are generated in `AppStore/screenshots/<locale>/` (see `screenshots.md`).

## 4. Build and upload

```bash
# 1. a review gateway key: put a working, quota-limited key into review_notes.txt (see step 5)
# 2. build the signed App Store package (universal; needs Xcode, not only the Command Line Tools)
TEAM_ID=ABCDE12345 \
MAS_APP_IDENTITY="Apple Distribution: Your Name (ABCDE12345)" \
MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (ABCDE12345)" \
MAS_PROFILE=~/Downloads/Readlet_Mac_App_Store.provisionprofile \
./build_mas.sh
# → dist/Readlet-1.0.0-AppStore.pkg

# 3. upload (App Store Connect API key: Users and Access → Integrations → Keys; save the .p8 to ~/.appstoreconnect/private_keys/)
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ./upload_mas.sh dist/Readlet-1.0.0-AppStore.pkg
```

Or open the .pkg in Apple's **Transporter** app. Every upload needs a higher build number — it is the git commit count, so commit before rebuilding.

Before uploading, smoke-test the sandboxed build locally: `open build/mas/Readlet.app` (it runs only on Macs registered in the profile if you use a development profile; with the App Store profile use TestFlight instead — step 6).

## 5. Review notes (you)

App Review must be able to try AI features. Edit `review_notes.txt`: replace `<REVIEW_GATEWAY_URL>` / `<REVIEW_API_KEY>` with a working endpoint and a key limited to a small budget, and paste the text into **App Review Information → Notes**. No sign-in is required, so leave "Sign-in required" unchecked.

## 6. TestFlight, then submit

1. After processing (10–30 min) the build appears under **TestFlight**; install it via the TestFlight app on your Mac and check: import a PDF, bilingual view, AI narration with the system voice and an online voice, web import, EPUB import, export to Markdown, Settings → Storage.
2. On the version page select the build → **Add for Review** → **Submit**.
3. Typical review time is 1–3 days. Common rejections for this kind of app and how the build already addresses them:
   - *2.1 App completeness* → working review key in the notes.
   - *5.1.2 data sharing with AI* → consent notice before the first AI request, privacy policy.
   - *2.4.5 (self-updating)* → the App Store edition has no updater (compiled with `-DMAS`).
   - *ATS exceptions* → explained in the notes (user-chosen and local servers).
   - *4.8 Login services* → not applicable: there is no app account; ChatGPT sign-in is only an optional AI provider, like entering an API key.

## 7. Differences of the App Store edition

| | Direct download | Mac App Store |
|---|---|---|
| Sandbox | no | yes (data in `~/Library/Containers/io.novarock.readlet`) |
| Update check | built in | through the App Store |
| Sign in with ChatGPT | yes | yes (free + open source; a paid edition would need OpenAI approval: <https://openai.com/form/sign-in-with-chatgpt-interest/>) |
| `api_key_command` in config | yes | no (sandbox can't run shell commands) — keys go in the Keychain via Settings |
| Markdown images next to the file | yes | only if they are inside the imported file's folder permission (sandbox) |

## 8. Website

The landing page links both the App Store and the direct download. After approval set the App Store URL in `landing/index.html` (`APP_STORE_URL`), redeploy with `deploy/deploy.sh`.
