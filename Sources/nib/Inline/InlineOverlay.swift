import AppKit

/// The Grammarly-style layer: squiggles over the real text, and a small card on
/// hover offering the fix.
///
/// The overlay window ignores mouse events everywhere except where a squiggle
/// actually is. Swallowing clicks across a whole text field would make the app
/// underneath unusable, which is worse than having no underlines.
@MainActor
final class InlineOverlay {
    /// Called when the user accepts a fix; the caller writes it into the app.
    var onAcceptFix: ((Suggestion, String) -> Void)?

    private let window: NSWindow
    private let squiggles = SquiggleView()
    private let card = FixCard()
    private var trackingArea: NSTrackingArea?
    private var hideCardWork: DispatchWorkItem?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Above normal windows but below menus and the panel itself.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = squiggles

        card.onAccept = { [weak self] suggestion, replacement in
            self?.onAcceptFix?(suggestion, replacement)
            self?.card.orderOut(nil)
        }
    }

    var isVisible: Bool { window.isVisible }

    /// Positions the overlay over a text field and draws the given marks.
    func show(fieldFrame: CGRect, marks: [(suggestion: Suggestion, rect: CGRect)]) {
        guard !marks.isEmpty, fieldFrame.width > 0, fieldFrame.height > 0 else {
            hide()
            return
        }

        window.setFrame(fieldFrame, display: false)
        // Rects arrive in screen coordinates; the view works in window space.
        squiggles.marks = marks.map {
            SquiggleView.Mark(
                suggestion: $0.suggestion,
                rect: CGRect(x: $0.rect.origin.x - fieldFrame.origin.x,
                             y: $0.rect.origin.y - fieldFrame.origin.y,
                             width: $0.rect.width,
                             height: $0.rect.height)
            )
        }
        refreshTracking()
        window.orderFront(nil)
    }

    func hide() {
        squiggles.marks = []
        window.orderOut(nil)
        card.orderOut(nil)
    }

    /// Mouse tracking is re-created on every move because the window frame,
    /// and therefore the tracking rect, changes as the field scrolls.
    private func refreshTracking() {
        if let trackingArea { squiggles.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: squiggles.bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: squiggles, userInfo: nil
        )
        squiggles.addTrackingArea(area)
        trackingArea = area
    }

    /// Called from the app's global mouse monitor.
    ///
    /// A global monitor is used rather than the window's own mouse events
    /// because the window ignores mouse events by design; it never receives
    /// them itself.
    func mouseMoved(to screenPoint: CGPoint) {
        guard window.isVisible else { return }
        let local = CGPoint(x: screenPoint.x - window.frame.origin.x,
                            y: screenPoint.y - window.frame.origin.y)

        guard let mark = squiggles.suggestion(at: local) else {
            scheduleCardHide()
            squiggles.hovered = nil
            return
        }

        hideCardWork?.cancel()
        squiggles.hovered = mark.suggestion.id

        guard !mark.suggestion.replacements.isEmpty else { return }
        let anchor = CGPoint(x: window.frame.origin.x + mark.rect.minX,
                             y: window.frame.origin.y + mark.rect.minY)
        card.show(mark.suggestion, below: anchor)
    }

    /// Small delay so moving the pointer from squiggle to card does not
    /// dismiss the card on the way.
    private func scheduleCardHide() {
        hideCardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.card.isMouseInside else { return }
            self.card.orderOut(nil)
        }
        hideCardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// The hover card: what is wrong, and buttons to fix it.
final class FixCard: NSPanel {
    var onAccept: ((Suggestion, String) -> Void)?
    private(set) var isMouseInside = false

    private let messageLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private var suggestion: Suggestion?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        contentView = background

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.preferredMaxLayoutWidth = 216

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 4

        let stack = NSStackView(views: [messageLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    override var canBecomeKey: Bool { false }

    func show(_ suggestion: Suggestion, below anchor: CGPoint) {
        // Rebuilding on every mouse move would flicker the buttons out from
        // under the pointer.
        if self.suggestion?.id != suggestion.id {
            self.suggestion = suggestion
            messageLabel.stringValue = suggestion.message
            buttonRow.arrangedSubviews.forEach {
                buttonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for fix in suggestion.replacements.prefix(3) {
                let button = NSButton(title: fix, target: self,
                                      action: #selector(accept(_:)))
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11)
                button.identifier = NSUserInterfaceItemIdentifier(fix)
                buttonRow.addArrangedSubview(button)
            }
            let fitting = contentView?.fittingSize ?? NSSize(width: 240, height: 60)
            setContentSize(NSSize(width: max(160, fitting.width), height: fitting.height))
        }

        var origin = CGPoint(x: anchor.x, y: anchor.y - frame.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
            // No room beneath the word: sit above it instead.
            if origin.y < visible.minY + 4 { origin.y = anchor.y + 18 }
        }
        setFrameOrigin(origin)
        orderFront(nil)
    }

    @objc private func accept(_ sender: NSButton) {
        guard let suggestion, let fix = sender.identifier?.rawValue else { return }
        onAccept?(suggestion, fix)
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true }
    override func mouseExited(with event: NSEvent) { isMouseInside = false }
}
