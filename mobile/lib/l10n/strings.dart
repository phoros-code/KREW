/// Track C3 i18n scaffold: the single string table for user-visible copy.
///
/// English only. Full ARB/arb flow is out of scope — this file IS the copy
/// source of truth: screens reference [AppStrings] constants instead of
/// inline literals for tab labels, error copy, and empty states (plus all
/// Track C3 surfaces). See DESIGN.md ("copy lives in lib/l10n/strings.dart").
///
/// Rule: values are plain `static const String` (no interpolation of server
/// payloads — curated copy only; raw codes live behind "Details" expanders).
/// [all] collects every value so tests can assert none is empty.
abstract final class AppStrings {
  // Tabs (NavigationBar labels + tooltips).
  static const String tabPair = 'Pair';
  static const String tabChat = 'Chat';
  static const String tabTasks = 'Tasks';
  static const String tabScreen = 'Screen';
  static const String tabSettings = 'Settings';

  // Pairing screen.
  static const String pairTitle = 'Pair with your laptop';
  static const String pairSubtitle =
      'This is the trust moment: pairing gives this phone full remote control '
      'of the laptop agent. Stay on the same Wi-Fi and confirm the laptop '
      'screen before you save.';
  static const String pairEmptyMessage =
      'No laptop yet. Run the pairing script on the laptop to get its IP '
      'and token, then enter them below.';
  static const String pairHostLabel = 'Laptop IP';
  static const String pairHostHint = '192.168.1.10';
  static const String pairTokenLabel = 'Pairing token';
  static const String pairTokenHint = 'paste the token from the laptop';
  static const String pairTokenNote =
      'Saved in secure storage (Keystore / Keychain), never in plain files. '
      'Port defaults to 8443 over HTTPS.';
  static const String pairFingerprintLabel =
      'Laptop cert fingerprint (SHA-256)';
  static const String pairFingerprintHint =
      '6c9caeac… (Cert SHA256 from pair_device.py)';
  static const String pairFingerprintNote =
      'The app trusts exactly this certificate and nothing else. Copy it '
      'from the laptop pairing script output — colons and spaces are fine.';
  static const String pairBtLabel = 'Laptop Bluetooth ID (optional)';
  static const String pairBtHint = 'AA:BB:CC:DD:EE:FF (Android) or UUID (iOS)';
  static const String pairBtNote =
      'Enables the near/far indicator from Bluetooth signal strength. Leave '
      'blank to skip it — proximity then follows server responses only. '
      'Find the ID in the laptop OS Bluetooth settings; the laptop must stay '
      'discoverable or paired.';
  static const String pairHostEmpty =
      'Enter the laptop IP shown by the pairing script.';
  static const String pairHostInvalid =
      'That host does not look valid — use an IP or hostname, with an '
      'optional :port.';
  static const String pairTokenEmpty = 'Enter the pairing token from the laptop.';
  static const String pairTokenShort = 'That token looks too short.';
  static const String pairFingerprintEmpty =
      'Paste the cert fingerprint from the laptop pairing script.';
  static const String pairFingerprintInvalid =
      'That does not look like a SHA-256 fingerprint (64 hex chars).';
  static const String pairFailedTitle = 'Pairing failed';
  static const String pairErrorUnauthorized =
      'Wrong token — check for a trailing space, or generate a fresh token '
      'on the laptop and try again.';
  static const String pairErrorTokenExpired =
      'That token reached its age limit — generate a fresh token on the '
      'laptop and pair again.';
  static const String pairErrorLockedOut =
      'Too many wrong attempts — the laptop is temporarily locked. Wait a '
      'few minutes, then try again.';
  static const String pairErrorForbidden =
      'The laptop only allows this from near proximity. Join the same Wi-Fi '
      'and try again.';
  static const String pairErrorGeneric =
      'Pairing failed — check the details and try again.';
  static const String pairDetailsLabel = 'Details';
  static const String pairSaveButton = 'Test connection and save';
  static const String pairTestingLabel = 'Testing connection, please wait';
  static const String pairShowToken = 'Show token';
  static const String pairHideToken = 'Hide token';

  // Chat screen.
  static const String chatTitle = 'Agent log';
  static const String chatSubtitleFar =
      'FAR mode — following task notifications. Commands unlock when you '
      'are near.';
  static const String chatSubtitleLive =
      'Live task activity from the laptop. Newest first.';
  static const String chatStreamErrorTitle = 'Live updates paused';
  static const String chatEmptyUnpairedTitle = 'No laptop paired yet';
  static const String chatEmptyUnpairedHint =
      'Pair from the Pair tab — then send your first command here.';
  static const String chatEmptyNoCommandsTitle = 'No commands yet';
  static const String chatEmptyNoCommandsHint =
      'Send a command below — results stream back here as the agent works.';
  static const String chatEmptyConnectingTitle = 'Connecting to the laptop…';
  static const String chatEmptyConnectingHint =
      'Opening the live event stream. This usually takes a second.';
  static const String chatSendUnauthorized =
      'The laptop rejected the token. Re-pair from the Pair tab.';
  static const String chatSendTokenExpired =
      'The pairing token reached its age limit. Re-pair from the Pair tab.';
  static const String chatSendForbidden =
      'Blocked: commands need near proximity. You are on notifications-only '
      'until you move closer.';
  static const String chatSendLockedOut =
      'The laptop locked out after too many attempts. Wait, then retry.';
  static const String chatBarUnpaired = 'Pair with the laptop first.';
  static const String chatBarOffline =
      'Laptop unreachable — commands are paused until the connection returns.';
  static const String chatBarFar =
      'FAR mode: notifications only. Move closer to the laptop to send commands.';
  static const String chatBarConnecting = 'Connecting to the laptop…';
  static const String chatEventStarted = 'Task started';
  static const String chatEventDone = 'Task done';
  static const String chatEventFailed = 'Task failed';

  // Track B4: phone-side voice input (mic → /voice/transcribe → review → send).
  static const String voiceMicLabel = 'Record voice command';
  static const String voiceRecordingLabel = 'Recording voice command';
  static const String voiceStop = 'Stop';
  static const String voiceTranscribing = 'Transcribing…';
  static const String voiceEmptyRetry = "Didn't catch that — try again";
  static const String voiceNotImplemented =
      "Voice transcription isn't set up on the laptop yet";
  static const String voicePermissionDenied =
      'Microphone permission denied — enable it in Settings to use voice commands.';
  static const String voiceTooLarge =
      'That recording is too large to send — try a shorter command.';
  static const String voiceStartFailed =
      'Could not start recording — try again.';

  // Task list screen.
  static const String tasksTitle = 'Tasks';
  static const String tasksSubtitle =
      'Every command queued from the Chat tab, with its live status.';
  static const String tasksErrorTitle = 'Task updates paused';
  static const String tasksEmptyUnpairedTitle = 'No laptop paired yet';
  static const String tasksEmptyUnpairedHint =
      'Pair from the Pair tab — tasks you send will appear here.';
  static const String tasksEmptyTitle = 'No tasks yet';
  static const String tasksEmptyHint =
      'Send a command from the Chat tab. It will show here as QUEUED, then '
      'RUNNING, then DONE or FAILED.';

  // Shared actions.
  static const String actionReconnect = 'Reconnect';
  static const String actionRetry = 'Retry';
  static const String actionCancel = 'Cancel';
  static const String actionClose = 'Close';
  static const String actionUnpair = 'Unpair';

  // App shell (stream + boot states).
  static const String streamAuthFailure =
      'The laptop rejected the token. Re-pair from the Pair tab.';
  static const String streamDropped =
      'The live stream dropped. Reconnect to resume updates.';
  static const String streamClosed = 'The live stream closed. Reconnect to resume.';
  static const String streamQuiet = 'The live stream went quiet — reconnecting…';
  static const String bootFailedTitle = 'Could not start';
  static const String bootFailedMessage =
      'Secure storage is unavailable — pairing details could not be read.';
  static const String unpairTitle = 'Unpair this laptop?';
  static const String unpairMessage =
      'The token is deleted from secure storage. You can re-pair at any '
      'time from the laptop.';

  // Track C3: notification history (section inside the Tasks tab).
  static const String historyTitle = 'Recent notifications';
  static const String historyClear = 'Clear history';
  static const String historyEmpty =
      'No notifications yet — task activity will appear here.';

  // Track C3: per-task log view.
  static const String taskDetailTitle = 'Task log';
  static const String taskDetailCopy = 'Copy result';
  static const String taskDetailCopied = 'Result copied.';
  static const String taskDetailEmpty = 'No events for this task yet.';
  static const String taskDetailEventsHeader = 'Events';

  // Track C3: settings tab.
  static const String settingsTitle = 'Settings';
  static const String settingsPairingSection = 'Pairing';
  static const String settingsNotPaired = 'Not paired';
  static const String settingsPairedOn = 'Paired on';
  static const String settingsPairedOnUnknown = 'date unknown';
  static const String settingsTestButton = 'Test connection';
  static const String settingsTesting = 'Testing…';
  static const String settingsTestOk = 'Connection OK — token accepted.';
  static const String settingsBtSection = 'Bluetooth device';
  static const String settingsBtNotSet = 'Not set';
  static const String settingsBtClear = 'Clear';
  static const String settingsBtCleared =
      'Bluetooth device cleared — proximity falls back to server responses.';
  static const String settingsThresholdSection = 'Proximity threshold';
  static const String settingsThresholdNote =
      'Threshold editing lives in the Screen tab below the preview.';
  static const String settingsNotificationsSection = 'Notifications';
  static const String settingsNotificationsToggle = 'Task notifications';
  static const String settingsNotificationsHint =
      'Show a SnackBar when tasks start, finish, or fail. History is kept '
      'in the Tasks tab either way.';
  static const String settingsAboutSection = 'About';
  static const String settingsAppVersion = 'App version';
  static const String settingsVersionUnknown = 'unknown';
  static const String settingsServer = 'Server';
  static const String settingsServerOk = 'reachable';
  static const String settingsServerUnreachable = 'unreachable';
  static const String settingsLicenses = 'Licenses';
  static const String settingsUnpairSection = 'Unpair';

  // Track C3: onboarding (shown once, after first pairing).
  static const String onboardingSkip = 'Skip';
  static const String onboardingNext = 'Next';
  static const String onboardingDone = 'Get started';
  static const String onboardingTrustTitle = 'This phone controls your laptop';
  static const String onboardingTrustBody =
      'Pairing gives this phone full remote control of the laptop agent. '
      'It only works on your local Wi-Fi, every connection needs the token, '
      'and the screen preview never starts without laptop approval.';
  static const String onboardingProximityTitle = 'Near means control';
  static const String onboardingProximityBody =
      'NEAR unlocks commands; FAR is notifications only. The header always '
      'shows which mode you are in — commands stay blocked until you are near.';
  static const String onboardingTabsTitle = 'Four tabs, one column';
  static const String onboardingTabsBody =
      'Pair, Chat, Tasks, Screen — plus Settings for pairing details and '
      'preferences. Every screen is the same console column: status on top, '
      'content in the middle.';

  /// Every user-visible string, for the no-empty-values test.
  static const List<String> all = <String>[
    tabPair,
    tabChat,
    tabTasks,
    tabScreen,
    tabSettings,
    pairTitle,
    pairSubtitle,
    pairEmptyMessage,
    pairHostLabel,
    pairHostHint,
    pairTokenLabel,
    pairTokenHint,
    pairTokenNote,
    pairFingerprintLabel,
    pairFingerprintHint,
    pairFingerprintNote,
    pairBtLabel,
    pairBtHint,
    pairBtNote,
    pairHostEmpty,
    pairHostInvalid,
    pairTokenEmpty,
    pairTokenShort,
    pairFingerprintEmpty,
    pairFingerprintInvalid,
    pairFailedTitle,
    pairErrorUnauthorized,
    pairErrorTokenExpired,
    pairErrorLockedOut,
    pairErrorForbidden,
    pairErrorGeneric,
    pairDetailsLabel,
    pairSaveButton,
    pairTestingLabel,
    pairShowToken,
    pairHideToken,
    chatTitle,
    chatSubtitleFar,
    chatSubtitleLive,
    chatStreamErrorTitle,
    chatEmptyUnpairedTitle,
    chatEmptyUnpairedHint,
    chatEmptyNoCommandsTitle,
    chatEmptyNoCommandsHint,
    chatEmptyConnectingTitle,
    chatEmptyConnectingHint,
    chatSendUnauthorized,
    chatSendTokenExpired,
    chatSendForbidden,
    chatSendLockedOut,
    chatBarUnpaired,
    chatBarOffline,
    chatBarFar,
    chatBarConnecting,
    chatEventStarted,
    chatEventDone,
    chatEventFailed,
    voiceMicLabel,
    voiceRecordingLabel,
    voiceStop,
    voiceTranscribing,
    voiceEmptyRetry,
    voiceNotImplemented,
    voicePermissionDenied,
    voiceTooLarge,
    voiceStartFailed,
    tasksTitle,
    tasksSubtitle,
    tasksErrorTitle,
    tasksEmptyUnpairedTitle,
    tasksEmptyUnpairedHint,
    tasksEmptyTitle,
    tasksEmptyHint,
    actionReconnect,
    actionRetry,
    actionCancel,
    actionClose,
    actionUnpair,
    streamAuthFailure,
    streamDropped,
    streamClosed,
    streamQuiet,
    bootFailedTitle,
    bootFailedMessage,
    unpairTitle,
    unpairMessage,
    historyTitle,
    historyClear,
    historyEmpty,
    taskDetailTitle,
    taskDetailCopy,
    taskDetailCopied,
    taskDetailEmpty,
    taskDetailEventsHeader,
    settingsTitle,
    settingsPairingSection,
    settingsNotPaired,
    settingsPairedOn,
    settingsPairedOnUnknown,
    settingsTestButton,
    settingsTesting,
    settingsTestOk,
    settingsBtSection,
    settingsBtNotSet,
    settingsBtClear,
    settingsBtCleared,
    settingsThresholdSection,
    settingsThresholdNote,
    settingsNotificationsSection,
    settingsNotificationsToggle,
    settingsNotificationsHint,
    settingsAboutSection,
    settingsAppVersion,
    settingsVersionUnknown,
    settingsServer,
    settingsServerOk,
    settingsServerUnreachable,
    settingsLicenses,
    settingsUnpairSection,
    onboardingSkip,
    onboardingNext,
    onboardingDone,
    onboardingTrustTitle,
    onboardingTrustBody,
    onboardingProximityTitle,
    onboardingProximityBody,
    onboardingTabsTitle,
    onboardingTabsBody,
  ];
}
