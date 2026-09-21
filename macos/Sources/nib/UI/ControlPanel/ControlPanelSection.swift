import Foundation

/// The sidebar, as data.
///
/// One case per pane. Phase 1 ships only Status: an empty Models pane reads as
/// a broken app rather than an unfinished one, so sections appear when the work
/// that fills them does.
enum ControlPanelSection: String, CaseIterable {
    case status

    var title: String {
        switch self {
        case .status: return "Status"
        }
    }

    /// SF Symbol shown beside the title.
    var symbol: String {
        switch self {
        case .status: return "waveform.path.ecg"
        }
    }
}
