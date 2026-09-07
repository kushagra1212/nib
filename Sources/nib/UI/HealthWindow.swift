import AppKit

/// Which parts of nib are working, which are not, and what to do about each.
///
/// nib fails in pieces, and until now the menu bar showed one icon for all of
/// it. Finding out which piece meant pressing each feature and reading whatever
/// error it happened to give -- and one of those errors, "model unavailable",
/// was wrong often enough to send someone looking for a missing model that was
/// sitting on disk.
///
/// Rows are built passively, so opening this costs nothing and allocates
/// nothing. Restart is offered only where restarting could plausibly help;
/// a feature broken for want of a file on disk gets the download instead.
@MainActor
final class HealthWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let body = NSStackView()

    /// Supplied by AppDelegate, which owns the engines this reads the state of.
    /// Main-actor isolated because what it reads -- a running LiveChecker, a
    /// registered hotkey -- is.
    var context: @MainActor () -> HealthContext = { .empty() }
    /// Restart one feature. Returns a line to show, or nil to stay quiet.
    var onRestart: (@MainActor (Feature) -> String?)?
    /// Restart the whole app.
    var onRestartApp: (@MainActor () -> Void)?
    /// Open the window that fixes a missing download.
    var onFix: (@MainActor (Feature) -> Void)?

    private var note: String?

    func show() {
        if let window {
            render()
            place(window)
            raise(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "nib Status"
        window.delegate = self
        window.isReleasedWhenClosed = false

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        body.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: flipped.topAnchor),
            body.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        scroll.documentView = flipped

        let content = Theme.makeAurora()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        window.contentView = content
        self.window = window

        render()
        place(window)
        raise(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        note = nil
        return true
    }

    // MARK: - Rendering

    private func render() {
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let rows = Health.report(context())
        let broken = rows.filter { $0.state == .broken }.count

        body.addArrangedSubview(label(
            broken == 0
                ? "Everything is working."
                : "\(broken) of \(rows.count) not working.",
            size: 15, weight: .semibold,
            colour: broken == 0 ? Theme.Colour.accept : Theme.Colour.correction))

        if let note {
            body.addArrangedSubview(label(note, size: 11,
                                          colour: Theme.Colour.inkMuted))
        }

        for row in rows { body.addArrangedSubview(card(for: row)) }

        body.addArrangedSubview(spacer(4))
        let restartAll = PillButton(
            title: "Restart nib", emphasis: .secondary,
            target: self, action: #selector(restartApp))
        body.addArrangedSubview(restartAll)
        body.addArrangedSubview(label(
            "Restarting nib reloads every part of it. Anything downloaded stays "
            + "downloaded; only what is running is replaced.",
            size: 11, colour: Theme.Colour.inkMuted))
    }

    private func card(for row: HealthRow) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3

        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.spacing = 7
        heading.addArrangedSubview(label(row.state.symbol, size: 12,
                                         colour: colour(for: row.state)))
        heading.addArrangedSubview(label(row.feature.title, size: 13,
                                         weight: .semibold))
        heading.addArrangedSubview(label(row.detail, size: 12,
                                         colour: Theme.Colour.inkMuted))
        stack.addArrangedSubview(heading)

        // Said on every row, working or not. Someone opening this panel is
        // usually looking for the feature by what it does, not by its name.
        stack.addArrangedSubview(indented(label(row.feature.purpose, size: 11,
                                                colour: Theme.Colour.inkMuted)))

        if let reason = row.reason {
            stack.addArrangedSubview(indented(
                label(reason, size: 11, colour: Theme.Colour.correction)))
        }
        if let fix = row.fix {
            stack.addArrangedSubview(indented(
                label("Fix: " + fix, size: 11, colour: Theme.Colour.ink)))
        }

        var buttons: [NSView] = []
        if row.restartable {
            let button = PillButton(title: "Restart", emphasis: .secondary,
                                    target: self, action: #selector(restartOne(_:)))
            button.tag = index(of: row.feature)
            buttons.append(button)
        }
        // Offered only where a download is the actual fix, so the button is
        // never a dead end.
        if row.state == .broken, needsDownload(row.feature) {
            let button = PillButton(title: "Open setup", emphasis: .primary,
                                    target: self, action: #selector(fixOne(_:)))
            button.tag = index(of: row.feature)
            buttons.append(button)
        }
        if !buttons.isEmpty {
            let bar = NSStackView(views: buttons)
            bar.orientation = .horizontal
            bar.spacing = 8
            stack.addArrangedSubview(indented(bar))
        }

        stack.addArrangedSubview(spacer(2))
        return stack
    }

    private func needsDownload(_ feature: Feature) -> Bool {
        switch feature {
        case .rewrite, .dictation, .speech: return true
        default: return false
        }
    }

    // MARK: - Actions

    @objc private func restartOne(_ sender: NSButton) {
        guard let feature = Feature.allCases[safe: sender.tag] else { return }
        note = onRestart?(feature) ?? "Restarted \(feature.title.lowercased())."
        render()
    }

    @objc private func fixOne(_ sender: NSButton) {
        guard let feature = Feature.allCases[safe: sender.tag] else { return }
        onFix?(feature)
    }

    @objc private func restartApp() {
        onRestartApp?()
    }

    /// Re-reads everything. Called when the window is brought forward, because
    /// a panel that shows the state from five minutes ago is worse than none.
    func refresh() {
        guard window != nil else { return }
        render()
    }

    // MARK: - Building blocks

    private func index(of feature: Feature) -> Int {
        Feature.allCases.firstIndex(of: feature) ?? 0
    }

    private func colour(for state: HealthState) -> NSColor {
        switch state {
        case .working: return Theme.Colour.accept
        case .degraded: return Theme.Colour.inkMuted
        case .broken: return Theme.Colour.correction
        }
    }

    private func label(_ text: String, size: CGFloat,
                       weight: NSFont.Weight = .regular,
                       colour: NSColor = Theme.Colour.ink) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        field.isSelectable = true
        field.drawsBackground = false
        field.isBordered = false
        field.preferredMaxLayoutWidth = 460
        return field
    }

    private func indented(_ view: NSView) -> NSView {
        let holder = NSStackView(views: [view])
        holder.orientation = .horizontal
        holder.edgeInsets = NSEdgeInsets(top: 0, left: 19, bottom: 0, right: 0)
        return holder
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func place(_ window: NSWindow) {
        if window.frame.origin == .zero { window.center() }
    }

    private func raise(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Text lays out from the top in a scroll view only if the document view says
/// its origin is up there.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
