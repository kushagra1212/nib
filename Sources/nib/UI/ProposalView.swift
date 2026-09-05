import AppKit

/// The model's proposal, shown as something you click to accept.
///
/// A separate Replace button asks the reader to look at the text, decide, then
/// travel to a different control. Making the text itself the target removes
/// that step: what you are agreeing to and what you click are the same thing.
final class ProposalView: NSView {
    var onAccept: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let hint = NSImageView()
    private let expander = NSButton()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refresh() } }

    /// Called when the reader expands or collapses, so the bar can resize.
    var onToggleExpanded: (() -> Void)?

    /// Whether the whole proposal is shown.
    ///
    /// Four lines by default, because the bar floats over the text being
    /// rewritten and a tall one covers the thing it is about. But a proposal
    /// cut off mid-sentence cannot be judged, and accepting text you have not
    /// read is the one thing this view exists to prevent.
    private(set) var isExpanded = false {
        didSet {
            label.maximumNumberOfLines = isExpanded ? 0 : 4
            expander.image = NSImage(
                systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
                accessibilityDescription: isExpanded ? "Show less" : "Show all")
            invalidateIntrinsicContentSize()
            onToggleExpanded?()
        }
    }

    /// Which rewrite wrote this. Set before `text`, and kept through a diff.
    ///
    /// Not `tag`: NSView already has one, and it is an Int.
    ///
    /// The bar runs Fix, then Clearer, then Native, and shows the first one
    /// that changes anything -- so the suggestion on screen is usually Fix's,
    /// and a generic "AI" tag gives the reader no way to know that.
    var writtenBy: String = "AI" {
        didSet { describeForAccessibility() }
    }

    /// Shows something already styled -- the diff -- instead of plain text.
    func show(_ body: NSAttributedString) {
        let out = NSMutableAttributedString(attributedString: Theme.aiTag(writtenBy))
        out.append(body)
        label.attributedStringValue = out
        describeForAccessibility()
        invalidateIntrinsicContentSize()
    }

    /// What VoiceOver is told this is.
    ///
    /// The view is an `NSView` that accepts a rewrite when clicked, which to
    /// the accessibility tree is a rectangle that does nothing -- the same
    /// mistake as a `div` with an onclick. It carries the whole result of the
    /// feature and it is the only way to accept one, so it says what it is,
    /// reads out the rewrite it is offering, and can be pressed without a
    /// mouse.
    private func describeForAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // Which rewrite, so the announcement distinguishes Fix from Native the
        // same way the visible tag does.
        setAccessibilityLabel(writtenBy == "AI"
            ? "Accept suggestion"
            : "Accept \(writtenBy) rewrite")
        setAccessibilityValue(text)
        setAccessibilityHelp("Replaces the selected text with this rewrite.")
    }

    override func accessibilityPerformPress() -> Bool {
        onAccept?()
        return true
    }

    var text: String = "" {
        didSet {
            // Everything shown here was written by the model, so it is tagged
            // like the model's inline suggestions are. Accepting a rewrite
            // replaces a whole sentence, which is a bigger thing to agree to
            // than a spelling fix, and the reader should know what wrote it.
            let out = NSMutableAttributedString(attributedString: Theme.aiTag(writtenBy))
            out.append(NSAttributedString(string: text, attributes: [
                .foregroundColor: Theme.Colour.ink,
                .font: Theme.Font.body,
            ]))
            label.attributedStringValue = out
            describeForAccessibility()
            invalidateIntrinsicContentSize()
        }
    }

    /// Width the text wraps at, set by the owner to match the bar.
    var wrapWidth: CGFloat = 300 {
        didSet { label.preferredMaxLayoutWidth = wrapWidth }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        label.font = Theme.Font.body
        label.textColor = Theme.Colour.ink
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        expander.isBordered = false
        expander.bezelStyle = .inline
        expander.imagePosition = .imageOnly
        // The button grew to 24 for the hit area; the glyph must not grow
        // with it, or the chevron starts competing with the text beside it.
        expander.imageScaling = .scaleNone
        expander.image = NSImage(systemSymbolName: "chevron.down",
                                 accessibilityDescription: "Show all")
        expander.contentTintColor = Theme.Colour.inkMuted
        expander.target = self
        expander.action = #selector(toggleExpanded)
        expander.toolTip = "Show the whole suggestion"
        expander.translatesAutoresizingMaskIntoConstraints = false
        addSubview(expander)

        // A tick, not a return arrow.
        //
        // It was `return`, which reads as "press Return to accept" -- and
        // Return does nothing. The only key nib watches is Esc, and it cannot
        // watch Return either: a global monitor observes without consuming, so
        // the keystroke would accept the rewrite *and* insert a newline into
        // the sentence it just replaced. Since the bar deliberately never takes
        // key focus, there is no plain keystroke it can honestly claim.
        //
        // So the glyph now says what is true: this is the thing you click to
        // accept.
        hint.image = NSImage(systemSymbolName: "checkmark",
                             accessibilityDescription: "Accept")
        hint.contentTintColor = Theme.Colour.inkMuted
        // Decoration. The view around it is the button and carries the name;
        // announcing "Accept" twice is noise, not help.
        hint.setAccessibilityElement(false)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            expander.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            expander.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 24, not 16. The chevron is still drawn at 16 -- `scaleNone`
            // keeps the glyph where it was -- but the thing you have to hit
            // was a 16pt square, under the 24pt floor for a pointer target,
            // and it sits directly beside the much larger area that accepts
            // the rewrite. Missing it by two points does not do nothing; it
            // replaces the sentence.
            expander.widthAnchor.constraint(equalToConstant: Theme.Metric.target),
            expander.heightAnchor.constraint(equalToConstant: Theme.Metric.target),
            hint.leadingAnchor.constraint(equalTo: expander.trailingAnchor, constant: 4),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.widthAnchor.constraint(equalToConstant: 12),
            hint.heightAnchor.constraint(equalToConstant: 12),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
    }

    /// Hides the chevron when everything already fits.
    func updateExpander(fits: Bool) {
        expander.isHidden = fits && !isExpanded
    }

    override func mouseDown(with event: NSEvent) {
        // The chevron is a button in its own right; clicking it must not be
        // read as accepting the text behind it.
        let local = convert(event.locationInWindow, from: nil)
        guard !expander.frame.insetBy(dx: -4, dy: -4).contains(local) else { return }
        onAccept?()
    }

    private func refresh() {
        let tint = Theme.Colour.accept
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.hover
            layer?.backgroundColor = (hovering
                ? tint.withAlphaComponent(0.16)
                : Theme.Colour.controlFill(0.10)).cgColor
            layer?.borderColor = (hovering
                ? tint.withAlphaComponent(0.55)
                : NSColor.clear).cgColor
        }
        hint.contentTintColor = hovering ? tint : Theme.Colour.inkMuted
    }
}
