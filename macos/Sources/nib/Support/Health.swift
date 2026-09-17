import Foundation

/// What nib can and cannot do right now, and why.
///
/// nib fails in pieces. The model can be missing while dictation works, or
/// Accessibility can be revoked while everything else is loaded and ready --
/// and the menu bar shows one icon for all of it. Diagnosing that meant
/// pressing each feature in turn and reading the error it happened to give.
///
/// Every check here is passive: files on disk, permissions already granted,
/// processes already running. Nothing is started to find out. That is the point
/// -- waking llama-server costs 2.7GB, and a health check that allocates is one
/// that can cause the failure it was opened to explain. Proving a subsystem
/// really works is `Probe`, run per row, on request.
enum Feature: String, CaseIterable {
    case accessibility
    case grammar
    case rewrite
    case dictation
    case speech
    case hotkeys
    case liveChecking

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .grammar: return "Grammar checking"
        case .rewrite: return "AI rewrite"
        case .dictation: return "Dictation"
        case .speech: return "Speak selection"
        case .hotkeys: return "Keyboard shortcuts"
        case .liveChecking: return "Underline as I type"
        }
    }

    /// What stops working when this one does. The panel says it out loud
    /// because "harper-ls is not running" means nothing to someone who wanted
    /// to know why their typos stopped being underlined.
    var purpose: String {
        switch self {
        case .accessibility: return "Reading and editing text in other apps"
        case .grammar: return "Finding spelling and grammar mistakes"
        case .rewrite: return "Fix, Clearer, Shorter and Native"
        case .dictation: return "Typing by speaking"
        case .speech: return "Reading selected text aloud"
        case .hotkeys: return "Triggering nib without the menu"
        case .liveChecking: return "Underlining mistakes while you type"
        }
    }
}

enum HealthState {
    /// Everything this feature needs is present.
    case working
    /// Usable, but not as intended -- a fallback is in play, or part of it is off.
    case degraded
    /// Cannot run at all.
    case broken

    var symbol: String {
        switch self {
        case .working: return "●"
        case .degraded: return "●"
        case .broken: return "●"
        }
    }
}

/// The live facts a passive check cannot read off disk.
///
/// Injected rather than reached for, so the whole report can be built in a test
/// without an NSApplication, a menu bar, or a running llama-server.
struct HealthContext {
    var accessibilityTrusted: Bool
    var grammarRunning: Bool
    var rewriterLoaded: Bool
    var liveCheckingEnabled: Bool
    /// Name to key combination. A nil combination means something else on the
    /// system already holds it, which is the common cause and is invisible.
    var hotkeys: [(name: String, combo: String?)]
    /// The last failure each feature reported, if any. What actually went wrong
    /// beats what the file system implies.
    var lastFailures: [Feature: String]

    static func empty() -> HealthContext {
        HealthContext(accessibilityTrusted: false, grammarRunning: false,
                      rewriterLoaded: false, liveCheckingEnabled: false,
                      hotkeys: [], lastFailures: [:])
    }
}

/// One line of the report.
struct HealthRow: Identifiable {
    let feature: Feature
    let state: HealthState
    /// What is true right now, in one line.
    let detail: String
    /// Why it is not working. Nil when it is.
    let reason: String?
    /// What to do about it. Nil when there is nothing to do.
    let fix: String?
    /// Whether restarting this alone is worth offering. Restarting a feature
    /// that is broken for want of a file on disk only wastes the user's time.
    let restartable: Bool

    var id: String { feature.rawValue }
}

enum Health {
    /// The installed rewrite model, if any. Mirrors `SpeechModelCatalog.installed`.
    static func installedRewriteModel() -> URL? {
        let dir = ModelCatalog.installDirectory
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { $0.hasSuffix(".gguf") }
            .map { dir.appendingPathComponent($0) }
            .first
    }

    static func report(_ context: HealthContext) -> [HealthRow] {
        Feature.allCases.map { row(for: $0, context: context) }
    }

    /// True when nothing is broken. Degraded does not count as broken: a
    /// missing optional shortcut is not a reason to paint the menu bar red.
    static func allWorking(_ rows: [HealthRow]) -> Bool {
        !rows.contains { $0.state == .broken }
    }

    static func row(for feature: Feature, context: HealthContext) -> HealthRow {
        // A recorded failure outranks an inferred one. The file being on disk
        // says the feature could work; the error says it did not.
        let failure = context.lastFailures[feature]

        switch feature {
        case .accessibility:
            guard context.accessibilityTrusted else {
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "Permission not granted",
                    reason: "macOS will not let nib read or change text in other "
                        + "apps until it is trusted for Accessibility.",
                    fix: "Open System Settings, Privacy & Security, "
                        + "Accessibility, and switch nib on. If it is already "
                        + "on, switch it off and on again -- the permission "
                        + "goes stale after nib is rebuilt or updated.",
                    restartable: false)
            }
            return HealthRow(feature: feature, state: .working,
                             detail: "Granted", reason: nil, fix: nil,
                             restartable: false)

        case .grammar:
            if let failure {
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "Stopped", reason: failure,
                    fix: "Restart grammar checking. If it stops again, the "
                        + "bundled harper-ls may be missing from the app "
                        + "bundle, which means reinstalling nib.",
                    restartable: true)
            }
            guard context.grammarRunning else {
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "Not running",
                    reason: "harper-ls, which finds the spelling and grammar "
                        + "mistakes, is not running.",
                    fix: "Restart grammar checking.",
                    restartable: true)
            }
            return HealthRow(feature: feature, state: .working,
                             detail: "Running", reason: nil, fix: nil,
                             restartable: true)

        case .rewrite:
            guard let model = installedRewriteModel() else {
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "No model installed",
                    reason: "Fix, Clearer, Shorter and Native all need a local "
                        + "GGUF model, and there is none in "
                        + "\(ModelCatalog.installDirectory.path).",
                    fix: "Open the model setup window and download "
                        + "\(ModelCatalog.recommended.title).",
                    restartable: false)
            }
            if let failure {
                return HealthRow(
                    feature: feature, state: .degraded,
                    detail: "\(model.lastPathComponent), last attempt failed",
                    reason: failure,
                    fix: "Restart the rewrite server. If it fails for memory, "
                        + "close some apps or switch to a smaller model -- "
                        + "dictation holds GPU memory for 180 seconds after "
                        + "transcribing, so the two compete.",
                    restartable: true)
            }
            return HealthRow(
                feature: feature,
                state: .working,
                detail: context.rewriterLoaded
                    ? "\(model.lastPathComponent), loaded"
                    : "\(model.lastPathComponent), sleeping",
                reason: nil,
                // Sleeping is correct, not a fault: llama-server shuts down
                // after 120s idle to return 2.7GB. Someone reading this panel
                // should not go looking for a way to keep it awake.
                fix: nil,
                restartable: context.rewriterLoaded)

        case .dictation:
            guard let model = SpeechModelCatalog.installed() else {
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "No model installed",
                    reason: "Dictation needs a whisper model, and there is none "
                        + "in \(SpeechModelCatalog.installDirectory.path).",
                    fix: "Download \(SpeechModelCatalog.recommended.title) from "
                        + "the dictation setup.",
                    restartable: false)
            }
            if let failure {
                return HealthRow(feature: feature, state: .broken,
                                 detail: model.lastPathComponent, reason: failure,
                                 fix: "Check that macOS has granted nib access "
                                     + "to the microphone, in System Settings, "
                                     + "Privacy & Security, Microphone.",
                                 restartable: false)
            }
            return HealthRow(feature: feature, state: .working,
                             detail: model.lastPathComponent, reason: nil,
                             fix: nil, restartable: false)

        case .speech:
            let model = VoiceCatalog.installedModel
            let pack = VoiceCatalog.installedVoicePack
            guard model != nil, pack != nil else {
                let missing = [model == nil ? "the Kokoro model" : nil,
                               pack == nil ? "the voice pack" : nil]
                    .compactMap { $0 }.joined(separator: " and ")
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "Missing \(missing)",
                    reason: "Speaking needs both the model and the 54-voice "
                        + "pack; neither is any use without the other.",
                    fix: "Open the Voices window and download what is missing.",
                    restartable: false)
            }
            // espeak turns text into phonemes. Its absence is not visible from
            // the model files, and it fails at the moment of speaking.
            do {
                _ = try EspeakLibrary.installedDirectory()
            } catch {
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "espeak not found",
                    reason: "The espeak data that turns text into phonemes is "
                        + "missing from the app bundle.",
                    fix: "Reinstall nib -- this ships inside the app and "
                        + "cannot be downloaded separately.",
                    restartable: false)
            }
            if let failure {
                return HealthRow(feature: feature, state: .degraded,
                                 detail: "Last attempt failed", reason: failure,
                                 fix: "Try speaking again. If it keeps failing, "
                                     + "check the output device in Sound settings.",
                                 restartable: false)
            }
            return HealthRow(feature: feature, state: .working,
                             detail: "Ready", reason: nil, fix: nil,
                             restartable: false)

        case .hotkeys:
            let unbound = context.hotkeys.filter { $0.combo == nil }
            guard unbound.isEmpty else {
                let names = unbound.map(\.name).joined(separator: ", ")
                return HealthRow(
                    feature: feature, state: .degraded,
                    detail: "\(context.hotkeys.count - unbound.count) of "
                        + "\(context.hotkeys.count) registered",
                    reason: "Something else on this Mac already holds the "
                        + "shortcut for \(names). macOS gives a combination to "
                        + "one app only, and the loser is told nothing.",
                    fix: "Quit whatever else uses it, or change that app's "
                        + "shortcut, then restart the shortcuts here. Every "
                        + "feature is still reachable from this menu.",
                    restartable: true)
            }
            return HealthRow(
                feature: feature, state: .working,
                detail: context.hotkeys.compactMap(\.combo).joined(separator: "  "),
                reason: nil, fix: nil, restartable: true)

        case .liveChecking:
            guard context.accessibilityTrusted else {
                return HealthRow(
                    feature: feature, state: .broken,
                    detail: "Needs Accessibility",
                    reason: "Underlining draws over other apps' text, which "
                        + "needs the same permission as everything else here.",
                    fix: "Grant Accessibility, above.",
                    restartable: false)
            }
            guard context.liveCheckingEnabled else {
                // Off is a choice, not a fault. Saying "broken" about something
                // the user switched off is how a status panel loses its
                // credibility.
                return HealthRow(feature: feature, state: .degraded,
                                 detail: "Switched off", reason: nil,
                                 fix: "Turn on Underline As I Type in the menu.",
                                 restartable: false)
            }
            if let failure {
                return HealthRow(feature: feature, state: .degraded,
                                 detail: "On, last pass failed", reason: failure,
                                 fix: "Restart underlining. Some apps expose no "
                                     + "text position to draw against, in which "
                                     + "case Check Selection still works.",
                                 restartable: true)
            }
            return HealthRow(feature: feature, state: .working, detail: "On",
                             reason: nil, fix: nil, restartable: true)
        }
    }
}
