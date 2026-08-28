import AppKit

/// Draws marks over the real text and shows the fix card on hover.
///
/// The overlay window sets ignoresMouseEvents, so it never receives mouse
/// events itself: hover arrives from a global monitor. Swallowing clicks across
/// a whole text field would make the app underneath unusable, which is a worse
/// failure than having no underlines.
@MainActor
final class InlineOverlay {
    var onAcceptFix: ((Suggestion, String) -> Void)?
    var onDismissFix: ((Suggestion) -> Void)?

    private let window: NSWindow
    private let marksView = SquiggleView()
    private let card = FixCard()
    private var hideCardWork: DispatchWorkItem?

    /// Text the marks refer to, so the card can show the edit in context.
    private var context = ""
    private var ordered: [Suggestion] = []
    private var shownIndex: Int?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = marksView

        card.onAccept = { [weak self] suggestion, replacement in
            self?.card.orderOut(nil)
            self?.onAcceptFix?(suggestion, replacement)
        }
        card.onDismiss = { [weak self] suggestion in
            self?.card.orderOut(nil)
            self?.onDismissFix?(suggestion)
        }
        card.onStep = { [weak self] delta in
            self?.step(by: delta)
        }
    }

    var isVisible: Bool { window.isVisible }

    func show(
        fieldFrame: CGRect,
        marks: [(Suggestion, [CGRect])],
        context: String
    ) {
        guard !marks.isEmpty, fieldFrame.width > 0, fieldFrame.height > 0 else {
            hide()
            return
        }
        self.context = context
        ordered = marks.map(\.0)

        window.setFrame(fieldFrame, display: false)
        // Rects arrive in screen coordinates; the view draws in window space.
        marksView.marks = marks.map { suggestion, rects in
            SquiggleView.Mark(
                suggestion: suggestion,
                rects: rects.map {
                    CGRect(x: $0.origin.x - fieldFrame.origin.x,
                           y: $0.origin.y - fieldFrame.origin.y,
                           width: $0.width, height: $0.height)
                }
            )
        }
        window.orderFront(nil)
    }

    func hide() {
        marksView.marks = []
        ordered = []
        shownIndex = nil
        card.reset()
        window.orderOut(nil)
        card.orderOut(nil)
    }

    /// Called from the app's global mouse monitor.
    func mouseMoved(to screenPoint: CGPoint) {
        guard window.isVisible else { return }

        // Keep the card up while the pointer is over it, so its buttons are
        // reachable without the card vanishing on the way there.
        if card.isVisible, card.frame.insetBy(dx: -6, dy: -6).contains(screenPoint) {
            hideCardWork?.cancel()
            return
        }

        let local = CGPoint(x: screenPoint.x - window.frame.origin.x,
                            y: screenPoint.y - window.frame.origin.y)

        guard let mark = marksView.suggestion(at: local) else {
            marksView.hovered = nil
            scheduleCardHide()
            return
        }

        hideCardWork?.cancel()
        marksView.hovered = mark.suggestion.id

        guard let index = ordered.firstIndex(where: { $0.id == mark.suggestion.id })
        else { return }
        present(index: index)
    }

    private func present(index: Int) {
        guard ordered.indices.contains(index) else { return }
        let suggestion = ordered[index]
        // Nothing to offer: an advisory lint with no replacement.
        guard !suggestion.replacements.isEmpty else {
            card.orderOut(nil)
            return
        }
        guard let rect = marksView.anchorRect(for: suggestion.id) else { return }

        shownIndex = index
        marksView.hovered = suggestion.id
        let anchor = CGPoint(x: window.frame.origin.x + rect.minX,
                             y: window.frame.origin.y + rect.minY)
        card.show(suggestion, context: context, index: index,
                  total: ordered.count, below: anchor)
    }

    /// Moves to the next or previous issue, wrapping around.
    private func step(by delta: Int) {
        guard let shownIndex, !ordered.isEmpty else { return }
        let count = ordered.count
        var next = shownIndex
        // Skip advisory lints with no fix; stepping onto one shows nothing.
        for _ in 0..<count {
            next = ((next + delta) % count + count) % count
            if !ordered[next].replacements.isEmpty { break }
        }
        card.reset()
        present(index: next)
    }

    private func scheduleCardHide() {
        hideCardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.card.isMouseInside else { return }
            self.card.dismiss()
            self.card.reset()
            self.shownIndex = nil
        }
        hideCardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
