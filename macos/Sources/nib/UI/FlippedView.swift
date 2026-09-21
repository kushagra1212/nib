import AppKit

/// Text lays out from the top in a scroll view only if the document view says
/// its origin is up there.
///
/// Shared rather than file-private: the status cards and the control panel both
/// scroll, and a second copy of a four-line class is how two scroll views start
/// behaving differently.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
