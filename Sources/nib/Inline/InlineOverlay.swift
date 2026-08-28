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

    /// Where to put the card when there is no mark to hang it off.
    ///
    /// Apps that report no drawable bounds -- Slack and most other Chromium
    /// text boxes -- get the badge instead of underlines, and the badge is what
    /// the card hangs off there. Same card, same buttons, same stepping; only
    /// the anchor differs.
    private var detachedAnchor: CGPoint?
    /// Region that keeps the detached card alive, i.e. the badge itself.
    private var detachedKeepAlive: CGRect = .zero

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
    /// The fix card, which outlives the overlay window in detached mode.
    var isCardVisible: Bool { card.isVisible }

    func show(
        fieldFrame: CGRect,
        marks: [(Suggestion, [CGRect])],
        context: String
    ) {
        guard !marks.isEmpty, fieldFrame.width > 0, fieldFrame.height > 0 else {
            hide()
            return
        }
        // Marks exist again, so the card goes back to hanging off the text.
        detachedAnchor = nil
        self.context = context

        // The card is anchored to a rect that may have just moved. Rather than
        // chase it mid-scroll, drop it; the pointer is over the text, so it
        // comes straight back on the next mouse move.
        if card.isVisible, marksMoved(marks) {
            card.dismiss()
            card.reset()
            shownIndex = nil
        }
        ordered = marks.map(\.0)

        window.setFrame(fieldFrame, display: false)
        // Rects arrive already converted to window space by MarkPlacement.
        marksView.marks = marks.map { SquiggleView.Mark(suggestion: $0.0, rects: $0.1) }
        window.orderFront(nil)
    }

    func hide() {
        marksView.marks = []
        ordered = []
        shownIndex = nil
        detachedAnchor = nil
        card.reset()
        window.orderOut(nil)
        card.orderOut(nil)
    }

    // MARK: - No marks to hover

    /// Shows the card for a field that cannot be underlined, hung off the badge.
    ///
    /// Everything the hover path offers -- the fix, Accept, Dismiss, stepping
    /// through issues -- works the same here. Only the anchor is different,
    /// because there is no rectangle in the text to point at.
    func showDetached(
        _ suggestions: [Suggestion],
        context: String,
        below anchor: CGPoint,
        keepAlive: CGRect
    ) {
        guard !suggestions.isEmpty else {
            hideDetached()
            return
        }
        self.context = context
        detachedAnchor = anchor
        detachedKeepAlive = keepAlive
        hideCardWork?.cancel()

        // Rebuilding on every mouse move would reset the card to the first
        // issue while the user is stepping through them.
        if ordered.map(\.id) != suggestions.map(\.id) {
            ordered = suggestions
            card.reset()
            shownIndex = nil
        }
        present(index: shownIndex ?? 0)
    }

    func hideDetached() {
        guard detachedAnchor != nil else { return }
        detachedAnchor = nil
        card.dismiss()
        card.reset()
        shownIndex = nil
    }

    /// Starts the grace period after the pointer leaves the badge, so the card
    /// survives the trip from badge to buttons.
    func scheduleDetachedHide() {
        guard detachedAnchor != nil else { return }
        scheduleCardHide()
    }

    /// Set while the selection bar is up.
    ///
    /// A clarity mark usually sits inside whatever the user just selected, so
    /// hovering it would open the fix card on top of the bar: two panels
    /// offering different answers about the same words. The selection is the
    /// more explicit request, so it wins.
    var isSuppressed = false {
        didSet {
            guard isSuppressed, card.isVisible else { return }
            card.dismiss()
            card.reset()
            shownIndex = nil
            marksView.hovered = nil
        }
    }

    /// Called from the app's global mouse monitor.
    func mouseMoved(to screenPoint: CGPoint) {
        // Detached: the overlay window is not up at all, so the usual
        // marks-under-pointer logic has nothing to work with. The card stays
        // while the pointer is on it or on the badge that opened it.
        if detachedAnchor != nil {
            guard card.isVisible else { return }
            let overCard = card.frame.insetBy(dx: -6, dy: -6).contains(screenPoint)
            let overBadge = detachedKeepAlive.insetBy(dx: -6, dy: -6).contains(screenPoint)
            if overCard || overBadge {
                hideCardWork?.cancel()
            } else {
                scheduleCardHide()
            }
            return
        }
        guard window.isVisible, !isSuppressed else { return }

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

        let anchor: CGPoint
        if let detachedAnchor {
            anchor = detachedAnchor
        } else {
            // A suggestion with no automatic fix still has something to say.
            // This used to return early, leaving those marks hoverable but
            // silent, which reads as the app being broken rather than as advice.
            guard let rect = marksView.anchorRect(for: suggestion.id) else { return }
            marksView.hovered = suggestion.id
            anchor = CGPoint(x: window.frame.origin.x + rect.minX,
                             y: window.frame.origin.y + rect.minY)
        }

        shownIndex = index
        card.show(suggestion, context: context, index: index,
                  total: ordered.count, below: anchor)
    }

    /// Moves to the next or previous issue, wrapping around.
    private func step(by delta: Int) {
        guard let shownIndex, !ordered.isEmpty else { return }
        let count = ordered.count
        // Every suggestion is now presentable, so stepping just moves.
        let next = ((shownIndex + delta) % count + count) % count
        card.reset()
        present(index: next)
    }

    /// Whether the currently shown suggestion sits somewhere new.
    private func marksMoved(_ marks: [(Suggestion, [CGRect])]) -> Bool {
        guard let shownIndex, ordered.indices.contains(shownIndex) else { return false }
        let id = ordered[shownIndex].id
        guard let old = marksView.anchorRect(for: id) else { return true }
        guard let new = marks.first(where: { $0.0.id == id })?.1.first else { return true }
        return abs(new.origin.y - old.origin.y) > 1 || abs(new.origin.x - old.origin.x) > 1
    }

    private func scheduleCardHide() {
        hideCardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.card.isMouseInside else { return }
            self.card.dismiss()
            self.card.reset()
            self.shownIndex = nil
            self.detachedAnchor = nil
        }
        hideCardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
