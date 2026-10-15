# App Store Connect → App Privacy

**Data collection: "No, we do not collect data from this app."**

Rationale (keep for reference / review questions):

- Readlet has no server, account, analytics, crash reporting SDK or advertising.
- Documents, translations, notes and audio stay on the Mac (app data folder).
- When the user enables AI features, page text / images are sent **directly from the Mac to the AI service the user configured** (their own gateway, API account or local model). The developer does not receive or have access to this data; Apple's definition of "collect" covers data transmitted off device to the developer or its third-party partners, which does not apply to services chosen and configured by the user.
- The privacy policy (https://readlet.novarock.io/privacy.html) describes this flow; the app shows a consent notice before the first AI request.

Privacy manifest: `Resources/PrivacyInfo.xcprivacy` (no tracking, no collected data; required-reason APIs: UserDefaults CA92.1, file timestamps C617.1).
