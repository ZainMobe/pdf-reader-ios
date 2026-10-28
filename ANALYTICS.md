# Firebase Analytics

The iOS app logs product analytics to Firebase (GA4) so we can see which screens and features people use, where they drop off, and what drives upgrades.

All logging goes through `PDF Reader/Analytics/`. Nothing else in the app imports Firebase.

The Android app (`PDFReaderAndroid`) logs the same events, parameters and user properties with identical names from `app/src/main/java/com/wapp/pdfreader/analytics/`, so every report below covers both platforms. Split by platform with the built-in `platform` dimension.

| File | What it does |
| --- | --- |
| `AppAnalytics.swift` | Configures Firebase, logs events, buckets numbers, tracks AI runs (`AIAnalyticsRun`) |
| `AnalyticsCatalog.swift` | Every event name, parameter, feature, screen, tool and source as enums |
| `ScreenTracking.swift` | `.trackScreen(.name)` modifier: logs `screen_view` and `screen_time` |
| `AnalyticsUserProperties.swift` | User properties (Pro, plan, library size, AI availability, theme) |
| `ReadingSessionTracker.swift` | Time and pages read per Reader session |
| `ScanAnalytics.swift` | Scan success and failure |
| `SubscriptionAnalytics.swift` | Detects cancellations, expiries, billing issues and trial conversions from RevenueCat |

Every analytics event is also written to the Crashlytics log, so a crash report shows the last things the user did. Every `*_failed` event (and `subscription_billing_issue`) is also recorded as a Crashlytics non-fatal, grouped by event and `error_type`; expected noise (cancellations, offline) is skipped. Crashlytics custom keys carry `last_screen` and every user property.

## Setup (one time)

1. In the Firebase console, create a project (or open the existing one) and add an iOS app with bundle ID `com.wappltd.PDF-Reader`.
2. Download `GoogleService-Info.plist` and drop it into the `PDF Reader/` folder in Xcode. The folder is a synchronized group, so it is added to the app target automatically. Do not add it to the Share Extension.
3. Open the project. Xcode resolves the new `firebase-ios-sdk` package (13.x, products `FirebaseCore` and `FirebaseAnalytics`).
4. To watch events live while testing: Product > Scheme > Edit Scheme > Run > Arguments, add `-FIRDebugEnabled`, then open Firebase console > Analytics > DebugView. In Debug builds every event is also printed to the Xcode console with the `[Analytics]` prefix.
5. Register the custom dimensions and metrics below (Firebase console > Analytics > Custom definitions). GA4 only shows a parameter in reports after it is registered; events are still collected before that.
6. Update the App Store privacy label: Data Used to Track You = none; Data Linked to You = none; Data Not Linked to You = Usage Data (Product Interaction) and Diagnostics. Mention Google Analytics for Firebase in the privacy policy on propdfeditor.online.

Without `GoogleService-Info.plist` the app runs normally and analytics is a silent no-op.

## Privacy

- No document titles, file names, search text, chat messages, extracted values or form values are ever logged. Only categories, counts and buckets.
- Ad storage, ad user data and ad personalisation consent are denied. No IDFA, no App Tracking Transparency prompt needed.
- Settings > Privacy > Share Usage Analytics lets people turn collection off.

## The report that answers "what do people use most"

Every meaningful action logs **`feature_used`** with `feature` and `category`. In GA4: Explore > Free form, rows = `feature`, values = Event count and Total users, filter Event name = `feature_used`. Swap rows to `category` for the high-level split (reader, annotate, edit, sign, ai, convert, organize, security, ...).

Other useful explorations:

- **Screens**: Engagement > Pages and screens (uses `screen_view`). For time spent per screen, explore `screen_time` with rows = `screen_name`, values = sum of `seconds`.
- **Tool funnel**: `tool_opened` > `tool_completed` broken down by `tool`. `tool_blocked` shows which tools free users wanted but hit the daily limit on.
- **AI funnel**: `ai_action_tapped` > `ai_started` > `ai_completed`, by `ai_action` and `ai_backend` (on_device vs cloud). `ai_failed` by `error_type` shows reliability problems.
- **Paywall**: `paywall_viewed` (by `source` and `trigger`) > `purchase_started` > `purchase_completed`. `free_limit_reached` by `pro_feature` shows which limit converts.
- **Acquisition of documents**: `document_imported` by `source` (files_picker, open_in, share_extension, drag_drop, shortcut, dropbox) plus `scan_completed`.
- **Reading depth**: `reading_session` with `seconds`, `pages_viewed`, `percent_read`, `theme`.
- **Onboarding**: `onboarding_page_viewed` by `page_name`, and `onboarding_completed` with `skipped`.
- **Entry points**: `app_entry` by `source` (widget, quick_action, shortcut, deep_link) and `action`.

## The report that answers "why are people leaving"

- **Where sessions end**: `session_ended` with rows = `last_screen`, values = Event count. A screen that ends far more sessions than it gets views is where people give up. Add `is_pro` to compare free vs paid.
- **Paywall dismissals**: `paywall_closed` with `purchased` = 0, broken down by `source`, `trigger` and `plan` (the plan selected when they left). `seconds` shows whether they read it or bounced. `paywall_load_failed` shows when no prices could be shown at all.
- **Purchase errors**: `purchase_failed` by `error_type` (`billing.*` on Android, `RevenueCat.ErrorCode.*` on iOS, `entitlement_inactive` when the store charged but Pro didn't unlock). `purchase_cancelled` is the user backing out of the store sheet.
- **Subscription churn**: `subscription_cancelled` (auto-renew turned off), `subscription_expired` (`kind` = not_renewed or billing_issue), `subscription_billing_issue`, `subscription_reactivated`, `trial_converted`. Detected when the app next talks to RevenueCat, so they appear on the user's next launch. The `subscription_state` user property (never, trial, trial_cancelled, active, cancelled, billing_issue, lifetime, lapsed) splits any report by where users are in that lifecycle.
- **Failures**: every `*_failed` event by `error_type` — `tool_failed`, `ai_failed`, `import_failed`, `document_open_failed`, `scan_failed`, `save_failed` (autosave couldn't write), `cloud_sync_failed`. The same failures appear in Crashlytics as non-fatals with full context.
- **Retention**: Firebase Analytics > Retention, and Audiences built on `subscription_state` or on users with `ai_failed` / `save_failed`.

## Events

| Event | When | Key parameters |
| --- | --- | --- |
| `feature_used` | Any feature actually used | `feature`, `category`, `source` |
| `screen_view` | Any screen or sheet appears | `screen_name`, `screen_class` |
| `screen_time` | Screen goes away or app backgrounds (1s or more) | `screen_name`, `seconds` |
| `tab_selected` | Tab bar change | `tab` |
| `app_entry` | Widget, Quick Action, Shortcut or `pdfeditor://` link | `action`, `source` |
| `onboarding_started` / `onboarding_page_viewed` / `onboarding_completed` | Onboarding | `page_index`, `page_name`, `skipped`, `pages_seen`, `seconds` |
| `document_imported` / `import_failed` | Files picker, drop, Open in, Share Extension, Shortcuts, Dropbox | `source`, `kind`, `file_count`, `count`, `duplicate`, `failed_count`, `error_type` |
| `scan_completed` / `scan_failed` | Document scanner | `source`, `count`, `page_bucket`, `duration_ms`, `error_type` (`cancelled` when dismissed) |
| `document_opened` / `document_open_failed` | Reader opens a file | `source`, `page_bucket`, `size_bucket`, `encrypted`, `theme` |
| `reading_session` | Reader closes | `seconds`, `pages_viewed`, `percent_read`, `page_bucket`, `theme`, `display_mode` |
| `reader_action` | Find, browse, bookmarks, read aloud, text view, theme, page mode, info, unlock | `action`, `option` |
| `annotation_added` / `annotation_undone` | Highlight, sticky note, ink, text | `annotation_type`, `source`, `option` (highlight colour) |
| `redaction_marked` / `redaction_applied` | Redaction | `option`, `marks`, `pages` |
| `signature_created` / `signature_placed` | Signing | `option` (draw, type, importPhoto, reuse_saved) |
| `pages_edited` | Page editor saved | `count`, `page_bucket` |
| `library_action` | Favorite, rename, delete, tags, folders, view mode, new window | `action`, `option` |
| `library_search` / `library_filter` | Library search (after typing settles) and smart filters | `query_length`, `has_results`, `count`, `filter` |
| `document_shared` | Share from Library or Reader | `source` |
| `tool_opened` / `tool_completed` / `tool_failed` / `tool_blocked` | Every tool in the Tools tab, plus Shortcuts tools | `tool`, `source`, `page_bucket`, `file_count`, `duration_ms`, `error_type`, `option`, `format` |
| `export_shared` | Result screens: share sheet, Files, Photos, open result | `destination`, `file_count` |
| `ai_action_tapped` | AI action chosen in the AI tab or Reader | `ai_action`, `source` |
| `ai_started` / `ai_completed` / `ai_failed` / `ai_cancelled` / `ai_unavailable` | Every AI run | `ai_action`, `ai_backend`, `duration_ms`, `output_size`, `error_type`, `language`, `message_index` |
| `ai_result_action` | Copy, save translation, apply form fill, open citation | `ai_action`, `action` |
| `cloud_ai_consent` | Cloud AI consent sheet answered | `granted` |
| `paywall_viewed` / `paywall_closed` | Paywall | `source`, `trigger`, `seconds`, `purchased` |
| `paywall_plan_selected` | Plan tapped | `plan` |
| `purchase_started` / `purchase_completed` / `purchase_cancelled` / `purchase_failed` | Purchase flow | `plan`, `has_trial`, `source`, `trigger`, `value`, `currency`, `error_type` |
| `restore_completed` | Restore Purchases | `success` |
| `free_limit_reached` / `free_use_consumed` | Free tier metering | `pro_feature`, `remaining` |
| `upgrade_banner_tapped` / `upgrade_banner_dismissed` | Library upsell banner | |
| `setting_changed` | Any setting | `setting`, `new_value` |
| `cloud_service_connected` / `cloud_service_disconnected` | Dropbox | `service`, `success` |
| `invite_shared` / `review_prompt_requested` | Growth | `source` |
| `session_ended` | App goes to the background | `seconds`, `last_screen`, `screens_viewed`, `is_pro` |
| `paywall_load_failed` | Paywall couldn't load prices | `source`, `error_type` |
| `subscription_cancelled` / `subscription_reactivated` | Auto-renew turned off / back on | `plan`, `period_type` |
| `subscription_expired` | Pro ended | `plan`, `period_type`, `kind` |
| `subscription_billing_issue` | Store reports a billing problem | `plan`, `period_type` |
| `trial_converted` | Trial became a paid period | `plan` |
| `save_failed` | Reader autosave couldn't write the PDF | `source`, `error_type`, `encrypted` |
| `cloud_sync_failed` | Dropbox / Google Drive operation failed | `service`, `action`, `error_type` |

## User properties

`is_pro`, `plan` (free, monthly, annual, lifetime), `subscription_state`, `library_size` (bucket), `ai_availability` (on_device, cloud, needs_consent, unavailable), `ai_mode`, `reader_theme`, `library_view_mode`, `has_signature`, `icloud_enabled`, `dropbox_linked` (iOS), `drive_linked` (Android), `onboarding_done`.

Register each as a user-scoped custom dimension so every report can be split by free vs Pro, on-device vs cloud AI, and so on.

## Custom definitions to register

Event-scoped dimensions: `feature`, `category`, `source`, `action`, `tool`, `tab`, `screen_name`, `page_bucket`, `size_bucket`, `kind`, `error_type`, `annotation_type`, `ai_action`, `ai_backend`, `output_size`, `option`, `format`, `destination`, `plan`, `trigger`, `pro_feature`, `page_name`, `theme`, `display_mode`, `setting`, `new_value`, `language`, `filter`, `query_length`, `service`, `last_screen`, `period_type`.

Metrics: `seconds`, `duration_ms`, `pages_viewed`, `percent_read`, `count`, `file_count`, `failed_count`, `message_index`, `remaining`, `marks`, `pages`, `saved_percent`, `pages_seen`, `screens_viewed`.

GA4 allows 50 event-scoped dimensions and 50 metrics per property, so this fits with room to spare.

## Adding a new event

1. Add the case to `AnalyticsEvent` (and any new parameter to `AnalyticsParam`) in `AnalyticsCatalog.swift`. Names: snake_case, 40 characters max.
2. If it is a user-facing feature, add it to `AnalyticsFeature` with a category and call `AppAnalytics.feature(...)` so it shows in the main report.
3. New screens: add to `AnalyticsScreen` and put `.trackScreen(.yourScreen)` on the view.
4. Never pass user content. Use `AppAnalytics.countBucket`, `pageBucket` or `sizeBucket` for numbers that could identify a document.
