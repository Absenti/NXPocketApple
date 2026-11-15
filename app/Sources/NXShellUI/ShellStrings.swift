import Foundation

/// Every string the shell shows, keyed by name rather than written inline. The app is in English only.
public enum ShellStrings {
    public enum Key: String, CaseIterable, Sendable {
        case library, libraryEmptyTitle, libraryEmptyBody
        case settings, certificate, memory, transfers, about
        case importGame, importing, imported, importFailed, cancel
        case certificateNone, certificateImport, certificateReplace, certificateRemove
        case certificateBody, certificateTeam, certificateExpires, certificateSubject
        case certificatePassphrase, certificateWrongTeam
        case certificateInProfile, certificateNotInProfile, yes, no
        case memoryActive, memoryInactive, memoryBody
        case resignAll, resigning, resignDone, resignNeeded
        case play, quit, lastLaunchFailed, broken, remove
        case testLoad, testLoadRunning, testLoadBody, testLoadPassed, testLoadFailed
        case removeGameBody, storage
        case log, importLog, copy, done, close
        case gameSettings, handheldMode, handheldModeNote, fpsCounter, settingsAtPlay, noSettings, resetSettings
        case setAtLaunch, setIn
        case touchControls, touchControlsBody, touchSize, touchSmall, touchMedium, touchLarge
        case touchStick, stickCorner, stickHigher, stickInward, arrangeControls, controlsMoved, allGames
        case editorHint, layout2D, layout3D, keysApart, resetLayout, noRoomThere, keptInPlace, movePanel
        case turnSideways, touchHint, save
        case free, receiving, aGame, sizeOf, received, tryAgainImport
        case certificateNeededTitle, certificateNeededBody, gameWaitsForCertificate, toSignAgain, signAgainBody, sign
        case rename, renameBody, originalName, resignGame, copyIdentifier, gameSize, freeSpace, moreActions
        case removeKeepSaves, removeEverything, gameDidNotStart, starting
        case saves, exportSaves, importSaves, deleteSaves, deleteSavesBody, noSavesYet
        case savesImported, previousSavesKept, savesNotImported
        case saveOfOtherGame, notASaveCopy, saveIncomplete, saveCopyEmpty, saveUnreadable
        case logs, logsBody, appLog, noLogs, share, erase, eraseLogBody, logShownTail, emptyLog
        case addToHomeScreen, shortcutStep1, shortcutStep2, shortcutStep3, shortcutRemove, shortcutDescription
        case openInFiles, shareFile, shortcutFailed
        case certificateUnreadable, certificateNeededToPlay, certificateExpiredBody, importRefused, noManifest, busyImporting
        case availableNow, deviceMemory, gamesOnDisk, waiting, daysLeft, signingIdentifier, appLabel, signatureLabel
        case installedBy, unknownTeam, engineHost, engineInEachGame, noEngineInBuild, folderLabel, folderInFiles
        case noKeysNotice, p12PasswordHint, identifierLabel
        case keychainRefused, keychainMissingEntitlement, copyReport, reportCopied
        case playTime, lastPlayed, neverPlayed, underAMinute
        case updates, installedVersion, appIdentifierLabel, addToSideStore, sideStoreDidNotOpen, copyAddress
        case checkUpdates, checking, noPublicChannel, checkFailed, openSideStore, checkDaily, lastCheck, later
        case updateWarning, updateSavesHint, updateThroughSideStore, networkNotice
        case details, showGrid, showCovers, transfersEmpty, signIn
        case loadRefusedCertificate, loadRefusedEntitlements, loadRefusedUnknown
        case loadRefusedDistribution, distributionInstallWarning, loadRefusedSandbox
        case activity, activityInProgress, activityToHandle, filterAll, filterOnPhone, filterCloud, filterUpdates, sourceSectionEmpty
        case importInterrupted, deleteTransfer
        case sourcesTab, sourcesOffTitle, sourcesOffBody, sourcesTurnOn
        case addSource, findMyMac, addMacByAddress, addSFTPServer, sourceKindMac, sourceKindSFTP, forgetSource, sourceNameLabel
        case searchingMacs, noMacFound, localNetworkDenied, openSettings, macAddressLabel
        case pairingCodeLabel, pairingCodeHint, pairAction, keyLabel, compareKeyHint, deviceNameLabel
        case pairingRefused, pairingRateLimited, pairingWrongMac, pairingBadCode
        case pairByNumber, typeCodeInstead, sameNumberQuestion, numberSame, numberDifferent, waitingForMac, numberHint
        case pairLinkTitle, pairLinkBody, pairLinkTurnOn, pairingDifferent, pairingBusy
        case sourceSecretNotSaved, sourceSignedOut, sourceUnreachable, sourceKeyChanged, noGamesOnSource
        case updateAll, selectAction, doneAction, downloadAll, queuedPosition
        case autoUpdateTitle, autoUpdateBody, notifyTitle, notifyBody
        case notificationDownloaded, notificationResume, notificationFailed
        case cheats, cheatsBody, cheatsImport, cheatsReplace, cheatsRemove, cheatsOn, cheatsSearch, cheatsMasterCode, cheatsNextStart
        case cheatsNoBuild, cheatsRefused, cheatsSafeMode, cheatsEngineSaid
        case archiveResumeHint
        case buildsOnMac, buildFailedOnMac, buildsOffTitle, buildsOffBody, receivingStopped, receivingStoppedBody
        case addGames, importArchiveItem, importFolderItem, importLinkItem, importSection, sourcesSection
        case archiveHashPlaceholder, archiveHashHint, archiveHashing
        case addWebLibrary, sourceKindWeb, webLibraryBody, webTokenLabel, webLibraryCheck, webLibraryFound, sourceSave
        case archiveLinkTitle, archiveLinkHint, archiveUnpacking, archiveChecking
        case archiveDownloading, archiveBadLink, archiveWarningTitle, archiveWarning, archiveImportAction
        case autoBackupTitle, autoBackupBody, syncTitle, syncBody, syncFoundTitle, syncFoundBody, syncUse, syncKeep
        case timeMachineRemote, timeMachineRemoteLoading, restoreRemoteBody
        case lastSession, thermalNominal, thermalFair, thermalSerious, thermalCritical, sessionHeat, sessionBattery
        case repairTitle, repairBody, repairScanning, repairClean, repairFound, repairFrom, repairNoSource, repairDone, repairNoList, repairRepairing
        case toBuild, buildQueued, buildBuilding, buildAsk, buildAskBody, buildAction, buildsRefused, buildBusy, buildGone
        case timeMachine, timeMachineBody, timeMachineEmpty, timeMachineRestore, timeMachineRestoreBody, timeMachineDone
        case averageFPS, sessions, fpsNotEnough
        case offload, offloadBody, offloadNoSource, offloadedPill, offloadedNoSource, forgetOffloaded
        case certReminderToggle, certReminderHint, certReminderTitle, certReminderDay, certReminderHours
        case backUpSaves, backUpAllSaves, backupRunning, backupDone, backupNothing, backupFailed, savesRefused, sourceNoRoom, backupWhere
        case stateUpToDate, stateRebuilding
        case downloadSelected, pauseAction, resumeAction, downloadingNow, pausedState
        case sftpServerLabel, sftpPortLabel, sftpUserLabel, sftpPasswordLabel, sftpAuthLabel, sftpAuthPassword, sftpAuthKey
        case sftpPrivateKeyLabel, sftpPassphraseLabel, sftpKeyHint, sftpConnect, sftpTrustTitle, sftpTrustBody, sftpTrust
        case sftpChooseFolder, sftpUseFolder, sftpNoFolders, sftpWrongLogin, sftpBack, sftpFolderUp, sftpBadKey, sftpNoCommonAlgorithms
    }

    /// "Version 0.3.0 is available".
    public static func updateAvailable(_ version: String) -> String { "Version \(version) is available" }

    /// "NXPocketApple is up to date (0.2.0)".
    public static func upToDate(_ version: String) -> String { "NXPocketApple is up to date (\(version))" }

    /// The question asked when a game's icon is touched while another game runs: the engine starts once per process,
    /// so the running game has to close. `running` and `next` are the games' names.
    public static func closeGameQuestion(running: String, next: String) -> (title: String, message: String, confirm: String) {
        ("Close \(running)?",
         "\(next) opens when you touch its icon again. Whatever \(running) has not saved will be lost.",
         "Close \(running)")
    }

    /// "1 game", "3 games".
    public static func gameCount(_ count: Int) -> String { count == 1 ? "1 game" : "\(count) games" }

    public static func text(_ key: Key) -> String { english[key] ?? key.rawValue }

    static let english: [Key: String] = [
        .library: "Library",
        .details: "Details",
        .signIn: "Sign in",
        .showGrid: "Show all the games",
        .showCovers: "Show the covers one by one",
        .transfersEmpty: "Games arrive from the Mac over USB or Wi-Fi and are imported as they land.",
        .libraryEmptyTitle: "No games yet",
        .libraryEmptyBody: "Build a game on your Mac with NXPocketApple and send it over the cable or Wi-Fi. It shows up here on its own, without reinstalling this app.",
        .settings: "Settings",
        .certificate: "Certificate",
        .memory: "Memory",
        .transfers: "Transfers",
        .about: "About",
        .importGame: "Import a game",
        .importing: "Importing",
        .imported: "Imported",
        .importFailed: "Import failed",
        .cancel: "Cancel",
        .certificateNone: "No certificate",
        .certificateImport: "Import a .p12",
        .certificateReplace: "Replace",
        .certificateRemove: "Remove",
        .certificateBody: "Import the .p12 of the certificate that signed this app: exported from SideStore, or the one your store gave you. It stays in this app's keychain, never in a file and never on the network.",
        .certificateTeam: "Team",
        .certificateExpires: "Expires",
        .certificateSubject: "Certificate",
        .certificatePassphrase: "Password for the .p12",
        .certificateWrongTeam: "This certificate belongs to another team. Export the one that installed this app.",
        .certificateInProfile: "In the app's current profile",
        .certificateNotInProfile: "This app is now signed with another certificate than the one imported here. Get the new .p12 (in SideStore, export it) and import it here, or the games may stop loading.",
        .yes: "Yes",
        .no: "No",
        .memoryActive: "Increased memory limit is active",
        .memoryInactive: "Standard memory limit",
        .memoryBody: "A game's framework inherits this app's entitlements, so the budget below is what a game gets.",
        .resignAll: "Sign the games again",
        .resigning: "Signing",
        .resignDone: "Signed",
        .resignNeeded: "Needs signing again",
        .play: "Play",
        .quit: "Quit",
        .lastLaunchFailed: "The last launch failed",
        .broken: "Broken",
        .remove: "Remove",
        .testLoad: "Test loading",
        .testLoadRunning: "Loading the game's code",
        .testLoadBody: "Signs the game if needed and loads its code from this phone, without starting it. Once loaded it stays loaded: close the app to test again.",
        .testLoadPassed: "The game loads",
        .testLoadFailed: "The game did not load",
        .removeGameBody: "Kept saves come back by themselves when the game is sent again.",
        .storage: "Storage",
        .log: "Log",
        .importLog: "Import log",
        .copy: "Copy",
        .done: "Done",
        .close: "Close",
        .gameSettings: "Game settings",
        .handheldMode: "Handheld mode",
        .handheldModeNote: "Off, the game runs as if docked to a TV.",
        .fpsCounter: "Frame-rate counter",
        .settingsAtPlay: "Applied when the game starts.",
        .noSettings: "This game has no settings list: it starts with the engine's defaults.",
        .resetSettings: "Reset to tested defaults",
        .setAtLaunch: "Set at launch",
        .setIn: "Set in",
        .touchControls: "Touch controls",
        .touchControlsBody: "One set for every game, applied at the next start of a game.",
        .touchSize: "Size",
        .touchSmall: "Small",
        .touchMedium: "Medium",
        .touchLarge: "Large",
        .touchStick: "Left stick",
        .stickCorner: "Corner",
        .stickHigher: "Higher",
        .stickInward: "Inward",
        .arrangeControls: "Arrange the controls",
        .controlsMoved: "Controls moved",
        .allGames: "All games",
        .editorHint: "Drag a control. It only goes where the game can draw it.",
        .layout2D: "2D",
        .layout3D: "3D",
        .keysApart: "A B X Y one by one",
        .resetLayout: "Reset this layout",
        .noRoomThere: "No room there",
        .keptInPlace: "Kept in place on this phone:",
        .movePanel: "Move this panel",
        .turnSideways: "Turn the phone sideways to place the controls at their real size.",
        .touchHint: "Right stick: drag here",
        .save: "Save",
        .free: "free",
        .receiving: "Receiving",
        .aGame: "a game",
        .sizeOf: "of",
        .received: "received",
        .tryAgainImport: "Try again",
        .certificateNeededTitle: "Import your certificate",
        .certificateNeededBody: "The games are signed on this phone with the .p12 of the certificate that signed this app.",
        .gameWaitsForCertificate: "A game has arrived. Import this app's certificate (.p12) and it is installed at once.",
        .toSignAgain: "to sign again",
        .signAgainBody: "The certificate changed or is about to run out. Signing takes a moment per game.",
        .sign: "Sign",
        .rename: "Rename",
        .renameBody: "Only the name shown in NXPocketApple changes. The game's files stay as they are, and an update keeps the name.",
        .originalName: "Original name",
        .resignGame: "Sign again",
        .copyIdentifier: "Copy the identifier",
        .gameSize: "Game",
        .freeSpace: "Free space",
        .moreActions: "More",
        .removeKeepSaves: "Delete the game, keep the saves",
        .removeEverything: "Delete everything",
        .gameDidNotStart: "The game did not start",
        .starting: "Starting",
        .saves: "Saves",
        .exportSaves: "Export the saves",
        .importSaves: "Import a save",
        .deleteSaves: "Delete the saves",
        .deleteSavesBody: "They cannot be brought back, unless you have a copy on the Mac or in Files.",
        .noSavesYet: "No save yet",
        .savesImported: "Save imported",
        .previousSavesKept: "The saves it replaced are kept in Files › On My iPhone › NXPocketApple › Saves.",
        .savesNotImported: "Save not imported",
        .saveOfOtherGame: "This save belongs to another game:",
        .notASaveCopy: "Pick a save copy: a folder the Mac app copied (it holds backup.json) or a .zip exported here.",
        .saveIncomplete: "This copy is incomplete: some of its files are missing.",
        .saveCopyEmpty: "This copy holds no save.",
        .saveUnreadable: "The copy could not be read:",
        .logs: "Logs",
        .logsBody: "The app's log, and one log per game start, newest first.",
        .appLog: "App log",
        .noLogs: "No log yet. A game writes one each time it starts.",
        .share: "Share",
        .erase: "Delete",
        .eraseLogBody: "This log is deleted for good.",
        .logShownTail: "Only the end is shown. Share the log for the whole file.",
        .emptyLog: "This log is empty.",
        .addToHomeScreen: "Add to Home Screen",
        .shortcutStep1: "In Files, touch this game's file. iOS takes it as a profile to install.",
        .shortcutStep2: "Open Settings › Profile Downloaded › Install, then enter the iPhone's passcode.",
        .shortcutStep3: "The game's icon appears on the Home Screen. Touching it opens the game.",
        .shortcutRemove: "To remove it: Settings › General › VPN & Device Management.",
        .shortcutDescription: "Puts this game's icon on the Home Screen. Touching it opens the game in NXPocketApple.",
        .openInFiles: "Open in Files",
        .shareFile: "Share the file",
        .shortcutFailed: "The shortcut could not be made",
        .certificateUnreadable: "The certificate kept by this app could not be read:",
        .certificateNeededToPlay: "Import this app's certificate (.p12) first, in Settings.",
        .loadRefusedCertificate: "iOS refused this game's code: the certificate imported here is not the one that signed this app. Import the .p12 of the certificate your store installed NXPocketApple with (same team, same certificate), then try again.",
        .loadRefusedEntitlements: "iOS refused this game's code: its signature claims rights that this app's own signature does not carry. This app was installed by a store that signs in a way games cannot follow. Copy the report below and send it.",
        .loadRefusedUnknown: "iOS refused this game's code, and everything this app can check agrees (certificate, team, identifier, entitlements). Copy the report below and send it: it says what was compared.",
        .loadRefusedDistribution: "iOS's sandbox refused to let this app run the game's code: dyld names the file system sandbox, not code signing, so the game's signature is not what refused it. Everything this app can compare agrees (certificate, team, identifier, entitlements). The one difference from the setup known to work (SideStore) is that this app is signed for distribution (an ad hoc, enterprise or App Store profile, with no get-task-allow): iOS most likely only lets a development-signed app run code from outside its bundle. Install the app with SideStore, or with a store that gives it a development profile.",
        .loadRefusedSandbox: "iOS's sandbox refused to let this app run the game's code: dyld names the file system sandbox, not code signing, so how the game is signed is not the cause. The app is signed for development and everything it can compare agrees, so the cause is in what this app's own process is allowed, which it cannot read. Copy the report below and send it.",
        .distributionInstallWarning: "This app is signed for distribution, not for development (no get-task-allow). iOS may refuse to run games from it. SideStore installs it the way that is known to work.",
        .certificateExpiredBody: "The certificate has expired. Get a new .p12 (in SideStore, export it) and import it in Settings.",
        .importRefused: "Refused",
        .noManifest: "This game has no manifest to start from. Send it again from the Mac.",
        .busyImporting: "An import or a signature is running. Start the game again once it is done.",
        .availableNow: "Available now",
        .deviceMemory: "Device memory",
        .gamesOnDisk: "Games on disk",
        .waiting: "Waiting",
        .daysLeft: "Days left",
        .signingIdentifier: "Signing identifier",
        .appLabel: "App",
        .signatureLabel: "Signature",
        .installedBy: "Installed by",
        .unknownTeam: "unknown team",
        .engineHost: "Engine host",
        .engineInEachGame: "in each game's framework",
        .noEngineInBuild: "none in this build",
        .folderLabel: "Folder",
        .folderInFiles: "Files › On My iPhone › NXPocketApple",
        .noKeysNotice: "NXPocketApple ships no key, no firmware and no game. The games it runs come from your own dumps, built on your own Mac.",
        .p12PasswordHint: "The .p12's password: the one set when it was exported, or your store's.",
        .identifierLabel: "Identifier",
        .keychainRefused: "The keychain refused the certificate",
        .keychainMissingEntitlement: "The keychain refused the certificate: the signature the installer gave this app opens it no keychain group",
        .copyReport: "Copy the report",
        .reportCopied: "Report copied",
        .playTime: "Play time",
        .lastPlayed: "Last played",
        .neverPlayed: "Not played yet",
        .underAMinute: "under a minute",
        .updates: "Updates",
        .installedVersion: "Installed version",
        .appIdentifierLabel: "App identifier",
        .addToSideStore: "Add NXPocketApple to SideStore",
        .sideStoreDidNotOpen: "The address is copied. If SideStore did not add the source by itself: in SideStore, Browse → Sources → +, then paste this address:",
        .copyAddress: "Copy the address",
        .checkUpdates: "Check",
        .checking: "Checking",
        .noPublicChannel: "No public channel yet",
        .checkFailed: "The check did not go through",
        .openSideStore: "Open SideStore",
        .checkDaily: "Check once a day",
        .lastCheck: "Last check",
        .later: "Later",
        .updateWarning: "Update NXPocketApple through SideStore only, never by touching an IPA in Files. SideStore must keep the app identifier above: under another identifier the app starts from nothing, and the games and saves of the previous install are gone.",
        .updateSavesHint: "The Mac app copies the games' saves every day and before each send. Make a copy from the Mac before an update.",
        .updateThroughSideStore: "Install it from SideStore, which keeps the games and saves.",
        .networkNotice: "The update check reads source.json on GitHub: one request, no personal data. Network sources, when you turn them on, connect only to your own Mac or SFTP server.",
        .activity: "Activity",
        .activityInProgress: "In progress",
        .activityToHandle: "To handle",
        .filterAll: "All",
        .filterOnPhone: "On iPhone",
        .filterCloud: "Cloud",
        .filterUpdates: "Updates",
        .sourceSectionEmpty: "No source yet",
        .importInterrupted: "The app stopped while importing this game, so it is not imported again by itself. Try again, or delete it.",
        .deleteTransfer: "Delete",
        .sourcesTab: "Sources",
        .sourcesOffTitle: "Games from your network",
        .sourcesOffBody: "Looks for your Mac on this network, or an SFTP server you add, and downloads the games you pick. Sends only this iPhone's name and a pairing token or password. Off until you turn it on.",
        .sourcesTurnOn: "Turn on",
        .addSource: "Add a source",
        .findMyMac: "Find my Mac",
        .addMacByAddress: "Add by address",
        .sourceKindMac: "Mac",
        .forgetSource: "Forget this source",
        .sourceNameLabel: "Name",
        .searchingMacs: "Looking for Macs on this network…",
        .noMacFound: "No Mac found. Turn on sharing in the launcher on the Mac (Settings → Sharing), or type its address.",
        .localNetworkDenied: "iOS blocked the local network for NXPocketApple. Allow it in Settings → Privacy & Security → Local Network, or type the Mac's address.",
        .openSettings: "Open Settings",
        .macAddressLabel: "Address, as the launcher shows it",
        .pairingCodeLabel: "Code",
        .pairingCodeHint: "Type the code under \"Cannot scan?\" in the launcher (Settings → Sharing → Pair an iPhone). It works once, for two minutes.",
        .pairAction: "Pair",
        .keyLabel: "Key",
        .compareKeyHint: "The launcher shows the same key under its address. If they differ, do not pair.",
        .deviceNameLabel: "Name of this iPhone",
        .pairingRefused: "The Mac did not accept this code. It may have run out, been used already, or be mistyped.",
        .pairingRateLimited: "Too many attempts. Wait a minute and ask the Mac for a new code.",
        .pairingWrongMac: "The answer did not come from the Mac that showed the code. Nothing was saved.",
        .pairingBadCode: "A code is six digits.",
        .pairByNumber: "Compare a number",
        .typeCodeInstead: "Type a code instead",
        .sameNumberQuestion: "Same number on the Mac?",
        .numberSame: "Same",
        .numberDifferent: "Different",
        .waitingForMac: "Waiting for you to allow it on the Mac…",
        .numberHint: "Allow it on the Mac only if it shows this number.",
        .pairLinkTitle: "Pair with this Mac",
        .pairLinkBody: "You scanned the code on the Mac's screen. Pairing sends this iPhone's name and nothing else.",
        .pairLinkTurnOn: "Turn on network sources and pair",
        .pairingDifferent: "The numbers differ, so nothing was paired. If this happens again, someone else may be on this network.",
        .pairingBusy: "Another iPhone is pairing with this Mac right now.",
        .sourceSecretNotSaved: "The keychain refused to keep this source's secret: it is kept until the app quits, and you will have to enter it again.",
        .sourceSignedOut: "The source no longer recognises this iPhone. Pair or sign in again.",
        .sourceUnreachable: "The source could not be reached.",
        .sourceKeyChanged: "The source's key is not the one this iPhone accepted. Nothing was downloaded.",
        .noGamesOnSource: "No built game here.",
        .sftpServerLabel: "Server",
        .sftpPortLabel: "Port",
        .sftpUserLabel: "User",
        .sftpPasswordLabel: "Password",
        .sftpAuthLabel: "Sign in with",
        .sftpAuthPassword: "A password",
        .sftpAuthKey: "A private key",
        .sftpPrivateKeyLabel: "Private key (ed25519, OpenSSH format)",
        .sftpPassphraseLabel: "Passphrase of the key, if it has one",
        .sftpKeyHint: "The server's own tools show the same fingerprint (ssh-keygen -lf on the server, or its SSH settings). If they differ, do not trust it.",
        .sftpConnect: "Connect",
        .sftpTrustTitle: "Trust this server's key?",
        .sftpTrustBody: "Nothing has been sent to it yet: no password, no key. From now on this iPhone talks to this server only if it presents this same key.",
        .sftpTrust: "Trust it",
        .sftpChooseFolder: "Choose the folder that holds the built games",
        .sftpUseFolder: "Use folder",
        .sftpNoFolders: "No folder here.",
        .sftpWrongLogin: "The server refused this user name, password or key.",
        .sftpBack: "Back",
        .sftpFolderUp: "Parent folder",
        .sftpBadKey: "This key cannot be read. Only ed25519 keys in OpenSSH format are supported.",
        .sftpNoCommonAlgorithms: "This server offers no cipher or key this app supports (it needs aes-gcm, curve25519 and an ed25519 or ECDSA host key).",
        .addSFTPServer: "SFTP server",
        .sourceKindSFTP: "SFTP server",
        .stateUpToDate: "Up to date",
        .stateRebuilding: "Being rebuilt",
        .updateAll: "Update all",
        .selectAction: "Select",
        .doneAction: "Done",
        .downloadAll: "Download all",
        .queuedPosition: "Waiting",
        .autoUpdateTitle: "Update games by themselves",
        .autoUpdateBody: "When a source has a newer build of a game you have, it is downloaded and installed while the app is open.",
        .notifyTitle: "Tell me when downloads finish",
        .notifyBody: "A notification when the app is in the background. iOS stops a download a few seconds after you leave the app, so it is also the way to know one is waiting.",
        .notificationDownloaded: "Download finished",
        .notificationResume: "Open the app to continue the others.",
        .notificationFailed: "A download failed",
        .backUpSaves: "Back up the saves to…",
        .backUpAllSaves: "Back up all my saves",
        .backupRunning: "Backing up the saves…",
        .backupDone: "Saves backed up",
        .backupNothing: "There are no saves to back up yet.",
        .backupFailed: "The backup did not work",
        .savesRefused: "This Mac does not accept saves. Turn on “Accept copies of saves from iPhones” in the launcher's Sharing settings.",
        .sourceNoRoom: "There is not enough room for the saves there.",
        .backupWhere: "Where do you want the copy?",
        .certReminderToggle: "Remind me before it expires",
        .certReminderHint: "A notification a day and two hours before the certificate or the profile ends. It moves by itself when SideStore renews the app.",
        .certReminderTitle: "NXPocketApple expires soon",
        .certReminderDay: "Open SideStore by tomorrow to refresh the app, or your games will stop opening.",
        .certReminderHours: "Less than two hours left. Refresh the app in SideStore now.",
        .offload: "Offload the game",
        .offloadBody: "Frees %@. The saves and settings stay, and the tile stays in the library: a touch downloads the game again.",
        .offloadNoSource: "No source has this game right now: to get it back you would have to send it from the Mac again.",
        .offloadedPill: "Offloaded",
        .offloadedNoSource: "Offloaded · no source has it",
        .forgetOffloaded: "Forget this tile",
        .averageFPS: "Average FPS",
        .sessions: "Sessions",
        .fpsNotEnough: "Play a little longer",
        .timeMachine: "Time Machine of the saves",
        .timeMachineBody: "A copy of the saves is taken before each session, when they changed. Touch one to put those saves back.",
        .timeMachineEmpty: "No copy yet: the first is taken the next time you start the game.",
        .timeMachineRestore: "Put these saves back",
        .timeMachineRestoreBody: "The saves you have now are kept as a copy in Files, under Saves.",
        .timeMachineDone: "The saves are back. The ones you had are kept in Files, under Saves.",
        .toBuild: "To build on the Mac",
        .buildQueued: "Waiting on the Mac",
        .buildBuilding: "Building on the Mac",
        .buildAsk: "Build this game on your Mac?",
        .buildAskBody: "The Mac builds it from your own files, which can take up to an hour. The game downloads here by itself when it is ready.",
        .buildAction: "Build it",
        .buildsRefused: "This Mac does not let iPhones start builds. Turn on “Let paired iPhones start builds of my games” in the launcher's Sharing settings.",
        .buildBusy: "The Mac is already building as much as it takes for iPhones. Try again later.",
        .buildGone: "The Mac no longer has this game to build.",
        .repairTitle: "Check and repair the game",
        .repairBody: "Reads the whole game data and compares it with the list the game came with. Damaged parts are fetched again from a source, and only those.",
        .repairScanning: "Checking the game data…",
        .repairClean: "The game data is intact.",
        .repairFound: "%d of %d parts are damaged.",
        .repairFrom: "Repair from %@",
        .repairNoSource: "No source has this game right now. Turn network sources on, or send the game again from the Mac.",
        .repairDone: "%d parts repaired.",
        .repairNoList: "This game was installed before this check existed. Updating it from a source adds what the check needs.",
        .repairRepairing: "Repairing…",
        .lastSession: "Last session",
        .thermalNominal: "Cool",
        .thermalFair: "Warm",
        .thermalSerious: "Hot",
        .thermalCritical: "Too hot",
        .sessionHeat: "Heat",
        .sessionBattery: "Battery used",
        .autoBackupTitle: "Back up my saves by themselves",
        .autoBackupBody: "After you played a game, its saves are sent to your Mac and servers that keep them, the next time you open the app. Needs a Mac that accepts copies, or an SFTP server.",
        .syncTitle: "Offer newer saves from my other devices",
        .syncBody: "When you start a game, the Mac and servers are asked for saves from another of your devices that are newer than these. You decide before the game starts.",
        .syncFoundTitle: "Newer saves found",
        .syncFoundBody: "%@ holds saves from %@, newer than the ones on this iPhone. Use them? The saves you have now are kept as a copy.",
        .syncUse: "Use them",
        .syncKeep: "Keep mine",
        .timeMachineRemote: "On your Mac and servers",
        .timeMachineRemoteLoading: "Looking for copies…",
        .restoreRemoteBody: "The saves you have now are kept as a copy in Files, under Saves.",
        .archiveLinkTitle: "Link to the archive",
        .archiveLinkHint: "An https link. It is used once and not kept. The archive needs room on this iPhone for itself and for what it holds.",
        .archiveUnpacking: "Unpacking",
        .archiveChecking: "Checking the build",
        .archiveDownloading: "Downloading the archive",
        .archiveBadLink: "That is not an https link.",
        .archiveWarningTitle: "Before you import",
        .archiveWarning: "A build holds the game's own data and code that this app signs and runs. Only import a build you made yourself, from your own game files, and from a place you trust. A build from anywhere else may be an illegal copy of a game, or may hold harmful code.",
        .archiveImportAction: "Import",
        .addWebLibrary: "Add a web library",
        .sourceKindWeb: "Web library",
        .webLibraryBody: "The address of a folder the launcher exported for the web (Settings → My server → A web copy of my built games), put behind https on a server of yours. The address can be the secret; an access token is optional. Nothing runs on the server: it only has to serve files.",
        .webTokenLabel: "Access token (optional)",
        .webLibraryCheck: "Check the address",
        .webLibraryFound: "%d game(s) found.",
        .sourceSave: "Add this source",
        .addGames: "Add games",
        .receivingStopped: "Stopped",
        .receivingStoppedBody: "Nothing has arrived for a while: the Mac stopped sending, or was cancelled. Delete what arrived.",
        .buildsOnMac: "Builds on your Mac",
        .buildFailedOnMac: "The build failed on the Mac",
        .buildsOffTitle: "Games your Mac could build",
        .buildsOffBody: "%@ does not let this iPhone ask for builds. To see the games it can build and start one from here, turn on \"Let paired iPhones start builds of my games\" in the Mac app's Settings → Sharing.",
        .importArchiveItem: "Import an archive",
        .importFolderItem: "Import a folder",
        .importLinkItem: "Download from a link",
        .importSection: "A build you already have",
        .sourcesSection: "From your Mac or a server",
        .archiveHashPlaceholder: "SHA-256 of the archive (optional)",
        .archiveHashHint: "If you give the hash the launcher showed when it made the archive, it is checked before anything is unpacked.",
        .archiveHashing: "Checking the archive's hash",
        .cheats: "Cheats",
        .cheatsBody: "Import a cheat file in the Atmosphère format (the .txt that cheat sites share for your game's version). Cheats that change values in memory work on the iPhone; a cheat that writes into the game's code does not, and the engine says so below.",
        .cheatsImport: "Import a cheat file",
        .cheatsReplace: "Replace the file",
        .cheatsRemove: "Remove the file",
        .cheatsOn: "Cheats on",
        .cheatsSearch: "Search",
        .cheatsMasterCode: "Master code: always on",
        .cheatsNextStart: "What is on is applied the next time the game starts.",
        .cheatsNoBuild: "This game was built before its version could be read, so a cheat file cannot be matched to it. Build it again on the Mac to use cheats.",
        .cheatsRefused: "This file is not a cheat file the engine would read:",
        .cheatsSafeMode: "The last start with cheats on did not come back, so cheats were turned off for this game. Turn them back on when you want.",
        .cheatsEngineSaid: "THE ENGINE SAID, AT THE LAST START",
        .archiveResumeHint: "What arrived is kept: give the same link again to go on from there.",
        .downloadSelected: "Download",
        .pauseAction: "Pause",
        .resumeAction: "Resume",
        .downloadingNow: "Downloading",
        .pausedState: "Paused",
    ]
}
