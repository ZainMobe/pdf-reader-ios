import Foundation

enum AnalyticsEvent: String {
    case featureUsed = "feature_used"
    case appEntry = "app_entry"
    case tabSelected = "tab_selected"
    case screenTime = "screen_time"
    case sessionEnded = "session_ended"

    case onboardingStarted = "onboarding_started"
    case onboardingPageViewed = "onboarding_page_viewed"
    case onboardingCompleted = "onboarding_completed"

    case documentImported = "document_imported"
    case importFailed = "import_failed"
    case documentOpened = "document_opened"
    case documentOpenFailed = "document_open_failed"
    case scanCompleted = "scan_completed"
    case scanFailed = "scan_failed"
    case libraryAction = "library_action"
    case librarySearch = "library_search"
    case libraryFilter = "library_filter"
    case documentShared = "document_shared"

    case readerAction = "reader_action"
    case readingSession = "reading_session"
    case annotationAdded = "annotation_added"
    case annotationUndone = "annotation_undone"
    case redactionMarked = "redaction_marked"
    case redactionApplied = "redaction_applied"
    case signatureCreated = "signature_created"
    case signaturePlaced = "signature_placed"
    case pagesEdited = "pages_edited"
    case saveFailed = "save_failed"

    case toolOpened = "tool_opened"
    case toolCompleted = "tool_completed"
    case toolFailed = "tool_failed"
    case toolBlocked = "tool_blocked"
    case exportShared = "export_shared"

    case aiActionTapped = "ai_action_tapped"
    case aiStarted = "ai_started"
    case aiCompleted = "ai_completed"
    case aiFailed = "ai_failed"
    case aiCancelled = "ai_cancelled"
    case aiUnavailable = "ai_unavailable"
    case aiChatMessage = "ai_chat_message"
    case aiResultAction = "ai_result_action"
    case cloudAIConsent = "cloud_ai_consent"

    case paywallViewed = "paywall_viewed"
    case paywallClosed = "paywall_closed"
    case paywallLoadFailed = "paywall_load_failed"
    case paywallPlanSelected = "paywall_plan_selected"
    case purchaseStarted = "purchase_started"
    case purchaseCompleted = "purchase_completed"
    case purchaseCancelled = "purchase_cancelled"
    case purchaseFailed = "purchase_failed"
    case restoreCompleted = "restore_completed"
    case freeLimitReached = "free_limit_reached"
    case freeUseConsumed = "free_use_consumed"
    case upgradeBannerTapped = "upgrade_banner_tapped"
    case upgradeBannerDismissed = "upgrade_banner_dismissed"

    case subscriptionCancelled = "subscription_cancelled"
    case subscriptionReactivated = "subscription_reactivated"
    case subscriptionExpired = "subscription_expired"
    case subscriptionBillingIssue = "subscription_billing_issue"
    case trialConverted = "trial_converted"

    case settingChanged = "setting_changed"
    case reviewPromptRequested = "review_prompt_requested"
    case cloudServiceConnected = "cloud_service_connected"
    case cloudServiceDisconnected = "cloud_service_disconnected"
    case cloudSyncFailed = "cloud_sync_failed"
    case inviteShared = "invite_shared"

    var isFailure: Bool {
        rawValue.hasSuffix("_failed") || self == .subscriptionBillingIssue
    }
}

enum AnalyticsParam: String {
    case feature
    case category
    case source
    case action
    case tool
    case tab
    case screenName = "screen_name"
    case lastScreen = "last_screen"
    case screensViewed = "screens_viewed"
    case seconds
    case pageBucket = "page_bucket"
    case pagesViewed = "pages_viewed"
    case percentRead = "percent_read"
    case savedPercent = "saved_percent"
    case fileCount = "file_count"
    case count
    case failedCount = "failed_count"
    case duplicate
    case kind
    case durationMs = "duration_ms"
    case errorType = "error_type"
    case annotationType = "annotation_type"
    case aiAction = "ai_action"
    case aiBackend = "ai_backend"
    case outputSize = "output_size"
    case messageIndex = "message_index"
    case suggested
    case granted
    case language
    case setting
    case value = "new_value"
    case revenue = "value"
    case currency
    case plan
    case periodType = "period_type"
    case hasTrial = "has_trial"
    case trigger
    case proFeature = "pro_feature"
    case remaining
    case pageIndex = "page_index"
    case pageName = "page_name"
    case pagesSeen = "pages_seen"
    case skipped
    case theme
    case displayMode = "display_mode"
    case format
    case destination
    case success
    case isPro = "is_pro"
    case sizeBucket = "size_bucket"
    case encrypted
    case option
    case service
    case hasResults = "has_results"
    case queryLength = "query_length"
    case filter
    case marks
    case pages
    case purchased
}

enum AnalyticsUserProperty: String {
    case isPro = "is_pro"
    case plan
    case librarySize = "library_size"
    case aiAvailability = "ai_availability"
    case aiMode = "ai_mode"
    case readerTheme = "reader_theme"
    case libraryViewMode = "library_view_mode"
    case hasSignature = "has_signature"
    case iCloudEnabled = "icloud_enabled"
    case dropboxLinked = "dropbox_linked"
    case onboardingDone = "onboarding_done"
    case subscriptionState = "subscription_state"
}

enum AnalyticsSource: String {
    case library
    case libraryEmptyState = "library_empty_state"
    case libraryMenu = "library_menu"
    case addTab = "add_tab"
    case toolsTab = "tools_tab"
    case aiTab = "ai_tab"
    case reader
    case readerPencil = "reader_pencil"
    case settings
    case paywall
    case onboarding
    case upgradeBanner = "upgrade_banner"
    case filesPicker = "files_picker"
    case dragDrop = "drag_drop"
    case openIn = "open_in"
    case shareExtension = "share_extension"
    case shortcut
    case widget
    case quickAction = "quick_action"
    case deepLink = "deep_link"
    case banner
    case search
    case aiCitation = "ai_citation"
    case newWindow = "new_window"
    case dropbox
    case unknown
}

enum AnalyticsCategory: String {
    case library
    case create
    case reader
    case annotate
    case edit
    case sign
    case ai
    case convert
    case organize
    case security
    case optimize
    case review
    case share
    case settings
    case sync
    case growth
}

enum AnalyticsFeature: String {
    case importFiles = "import_files"
    case scan
    case newBlank = "new_blank"
    case dragDrop = "drag_drop"
    case openIn = "open_in"
    case shareExtension = "share_extension"
    case shortcutImport = "shortcut_import"
    case librarySearch = "library_search"
    case libraryFilter = "library_filter"
    case folders
    case moveToFolder = "move_to_folder"
    case tags
    case favorite
    case rename
    case deleteDocument = "delete_document"
    case shareDocument = "share_document"
    case openNewWindow = "open_new_window"
    case libraryViewMode = "library_view_mode"

    case readDocument = "read_document"
    case findInDocument = "find_in_document"
    case browseSidebar = "browse_sidebar"
    case thumbnails
    case outline
    case bookmarks
    case annotationsList = "annotations_list"
    case addBookmark = "add_bookmark"
    case readAloud = "read_aloud"
    case textView = "text_view"
    case readerTheme = "reader_theme"
    case displayMode = "display_mode"
    case exportAnnotations = "export_annotations"
    case documentInfo = "document_info"
    case unlockPassword = "unlock_password"

    case highlight
    case stickyNote = "sticky_note"
    case ink
    case addText = "add_text"
    case undo
    case redact
    case editPages = "edit_pages"
    case signature

    case aiSummarize = "ai_summarize"
    case aiChat = "ai_chat"
    case aiTranslate = "ai_translate"
    case aiExtract = "ai_extract"
    case aiFormFill = "ai_form_fill"
    case aiAskLibrary = "ai_ask_library"

    case toolNewBlank = "tool_new_blank"
    case toolMerge = "tool_merge"
    case toolSplit = "tool_split"
    case toolWatermark = "tool_watermark"
    case toolPageNumbers = "tool_page_numbers"
    case toolCompress = "tool_compress"
    case toolRemovePassword = "tool_remove_password"
    case toolProtect = "tool_protect"
    case toolFlatten = "tool_flatten"
    case toolCompare = "tool_compare"
    case toolImagesToPDF = "tool_images_to_pdf"
    case toolFileToPDF = "tool_file_to_pdf"
    case toolPDFToImages = "tool_pdf_to_images"
    case toolPDFToWord = "tool_pdf_to_word"
    case toolScan = "tool_scan"

    case signatureManager = "signature_manager"
    case dropboxBackup = "dropbox_backup"
    case dropboxBrowse = "dropbox_browse"
    case profile
    case invite

    var category: AnalyticsCategory {
        switch self {
        case .importFiles, .scan, .newBlank, .dragDrop, .openIn, .shareExtension, .shortcutImport:
            return .create
        case .librarySearch, .libraryFilter, .folders, .moveToFolder, .tags, .favorite, .rename,
             .deleteDocument, .openNewWindow, .libraryViewMode:
            return .library
        case .shareDocument:
            return .share
        case .readDocument, .findInDocument, .browseSidebar, .thumbnails, .outline, .bookmarks,
             .annotationsList, .addBookmark, .readAloud, .textView, .readerTheme, .displayMode,
             .exportAnnotations, .documentInfo, .unlockPassword:
            return .reader
        case .highlight, .stickyNote, .ink, .undo:
            return .annotate
        case .addText, .redact, .editPages:
            return .edit
        case .signature, .signatureManager:
            return .sign
        case .aiSummarize, .aiChat, .aiTranslate, .aiExtract, .aiFormFill, .aiAskLibrary:
            return .ai
        case .toolNewBlank, .toolScan:
            return .create
        case .toolImagesToPDF, .toolFileToPDF, .toolPDFToImages, .toolPDFToWord:
            return .convert
        case .toolMerge, .toolSplit:
            return .organize
        case .toolCompare, .toolFlatten:
            return .review
        case .toolWatermark, .toolPageNumbers:
            return .edit
        case .toolProtect, .toolRemovePassword:
            return .security
        case .toolCompress:
            return .optimize
        case .dropboxBackup, .dropboxBrowse:
            return .sync
        case .profile:
            return .settings
        case .invite:
            return .growth
        }
    }
}

enum AnalyticsTool: String {
    case newBlank = "new_blank"
    case merge
    case split
    case watermark
    case pageNumbers = "page_numbers"
    case compress
    case removePassword = "remove_password"
    case protect
    case flatten
    case compare
    case imagesToPDF = "images_to_pdf"
    case fileToPDF = "file_to_pdf"
    case pdfToImages = "pdf_to_images"
    case pdfToWord = "pdf_to_word"
    case scan

    var feature: AnalyticsFeature {
        switch self {
        case .newBlank: .toolNewBlank
        case .merge: .toolMerge
        case .split: .toolSplit
        case .watermark: .toolWatermark
        case .pageNumbers: .toolPageNumbers
        case .compress: .toolCompress
        case .removePassword: .toolRemovePassword
        case .protect: .toolProtect
        case .flatten: .toolFlatten
        case .compare: .toolCompare
        case .imagesToPDF: .toolImagesToPDF
        case .fileToPDF: .toolFileToPDF
        case .pdfToImages: .toolPDFToImages
        case .pdfToWord: .toolPDFToWord
        case .scan: .toolScan
        }
    }

    var screen: AnalyticsScreen {
        switch self {
        case .newBlank: .toolNewBlank
        case .merge: .toolMerge
        case .split: .toolSplit
        case .watermark: .toolWatermark
        case .pageNumbers: .toolPageNumbers
        case .compress: .toolCompress
        case .removePassword: .toolRemovePassword
        case .protect: .toolProtect
        case .flatten: .toolFlatten
        case .compare: .toolCompare
        case .imagesToPDF: .toolImagesToPDF
        case .fileToPDF: .toolFileToPDF
        case .pdfToImages: .toolPDFToImages
        case .pdfToWord: .toolPDFToWord
        case .scan: .scanner
        }
    }
}

enum AnalyticsAIAction: String {
    case summarize
    case chat
    case translate
    case extract
    case formFill = "form_fill"
    case askLibrary = "ask_library"

    var feature: AnalyticsFeature {
        switch self {
        case .summarize: .aiSummarize
        case .chat: .aiChat
        case .translate: .aiTranslate
        case .extract: .aiExtract
        case .formFill: .aiFormFill
        case .askLibrary: .aiAskLibrary
        }
    }
}

enum AnalyticsAnnotation: String {
    case highlight
    case stickyNote = "sticky_note"
    case ink
    case text
    case signature

    var feature: AnalyticsFeature {
        switch self {
        case .highlight: .highlight
        case .stickyNote: .stickyNote
        case .ink: .ink
        case .text: .addText
        case .signature: .signature
        }
    }
}

enum AnalyticsScreen: String {
    case library
    case aiAssistant = "ai_assistant"
    case add
    case tools
    case settings
    case onboarding
    case reader
    case documentWindow = "document_window"
    case reflowReader = "reflow_reader"
    case readerSidebar = "reader_sidebar"
    case searchInDocument = "search_in_document"
    case documentInfo = "document_info"
    case passwordPrompt = "password_prompt"
    case aiSummary = "ai_summary"
    case aiChat = "ai_chat"
    case aiTranslate = "ai_translate"
    case aiExtract = "ai_extract"
    case aiFormFill = "ai_form_fill"
    case aiLibraryAsk = "ai_library_ask"
    case aiDocumentPicker = "ai_document_picker"
    case aiActionPicker = "ai_action_picker"
    case cloudAIConsent = "cloud_ai_consent"
    case signaturePicker = "signature_picker"
    case signaturePlacement = "signature_placement"
    case signatureManager = "signature_manager"
    case ink
    case pageEditor = "page_editor"
    case paywall
    case celebration
    case folderManager = "folder_manager"
    case profileEditor = "profile_editor"
    case syncStatus = "sync_status"
    case dropboxBrowser = "dropbox_browser"
    case scanner
    case toolNewBlank = "tool_new_blank"
    case toolMerge = "tool_merge"
    case toolSplit = "tool_split"
    case toolWatermark = "tool_watermark"
    case toolPageNumbers = "tool_page_numbers"
    case toolCompress = "tool_compress"
    case toolRemovePassword = "tool_remove_password"
    case toolProtect = "tool_protect"
    case toolFlatten = "tool_flatten"
    case toolCompare = "tool_compare"
    case toolCompareResults = "tool_compare_results"
    case toolImagesToPDF = "tool_images_to_pdf"
    case toolFileToPDF = "tool_file_to_pdf"
    case toolPDFToImages = "tool_pdf_to_images"
    case toolPDFToWord = "tool_pdf_to_word"
    case toolSuccess = "tool_success"
    case exportResult = "export_result"

    var screenClass: String {
        switch self {
        case .library: "LibraryHomeView"
        case .aiAssistant: "AIAssistantView"
        case .add: "AddHomeView"
        case .tools: "ToolsHomeView"
        case .settings: "SettingsHomeView"
        case .onboarding: "OnboardingView"
        case .reader: "ReaderView"
        case .documentWindow: "DocumentWindowView"
        case .reflowReader: "ReflowReaderView"
        case .readerSidebar: "ReaderSidebarView"
        case .searchInDocument: "SearchSheet"
        case .documentInfo: "DocumentInfoSheet"
        case .passwordPrompt: "PasswordPromptSheet"
        case .aiSummary: "SummarySheet"
        case .aiChat: "ChatSheet"
        case .aiTranslate: "TranslateSheet"
        case .aiExtract: "ExtractSheet"
        case .aiFormFill: "FormFillSheet"
        case .aiLibraryAsk: "LibrarySearchView"
        case .aiDocumentPicker: "DocumentPickerSheet"
        case .aiActionPicker: "ActionPickerSheet"
        case .cloudAIConsent: "CloudAIConsentView"
        case .signaturePicker: "SignatureSheet"
        case .signaturePlacement: "SignaturePlacementSheet"
        case .signatureManager: "SignatureManagerView"
        case .ink: "InkSheet"
        case .pageEditor: "PageEditorView"
        case .paywall: "PaywallView"
        case .celebration: "CelebrationView"
        case .folderManager: "FolderManagerView"
        case .profileEditor: "ProfileEditorView"
        case .syncStatus: "SyncStatusView"
        case .dropboxBrowser: "DropboxBrowserView"
        case .scanner: "ScannerLauncher"
        case .toolNewBlank: "NewBlankPDFView"
        case .toolMerge: "MergePDFsView"
        case .toolSplit: "SplitPDFView"
        case .toolWatermark: "WatermarkView"
        case .toolPageNumbers: "PageNumbersView"
        case .toolCompress: "CompressView"
        case .toolRemovePassword: "RemovePasswordView"
        case .toolProtect: "ProtectPDFView"
        case .toolFlatten: "FlattenPDFView"
        case .toolCompare: "ComparePDFsView"
        case .toolCompareResults: "CompareResultsView"
        case .toolImagesToPDF: "ImagesToPDFView"
        case .toolFileToPDF: "FileToPDFView"
        case .toolPDFToImages: "PDFToImagesView"
        case .toolPDFToWord: "PDFToWordView"
        case .toolSuccess: "ToolSuccessView"
        case .exportResult: "ExportResultView"
        }
    }
}
