import AppKit

/// The seven feature cards, as a view rather than a window.
///
/// Lifted out of HealthWindow so the control panel and the old Status… window
/// render the same thing. Only the ownership changed: this builds a view and
/// reports what the user pressed, and knows nothing about where it is shown.
///
/// Rows are built passively, so showing this costs nothing and allocates
/// nothing. Restart is offered only where restarting could plausibly help; a
/// feature broken for want of a file on disk gets the download instead.
@MainActor
final class StatusSection: NSObject {
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

    private let body = NSStackView()
    private var note: String?
    private var built = false

    /// The view to place in a window. Built once; `refresh()` re-renders it.
    func makeView() -> NSView {
        if !built {
            body.orientation = .vertical
            body.alignment = .leading
            body.spacing = 12
            body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
            body.translatesAutoresizingMaskIntoConstraints = false
            built = true
        }
        render()
        return body
    }

    /// Re-reads everything. Called when the window is brought forward, because
    /// a panel showing the state from five minutes ago is worse than none.
    func refresh() {
        guard built else { return }
        render()
    }

    /// Clears the transient line under the heading, so a restart note from last
    /// time is not read as the result of this time.
    func clearNote() {
        note = nil
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
        body.addArrangedSubview(PillButton(
            title: "Restart nib", emphasis: .secondary,
            target: self, action: #selector(restartApp)))
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
}
