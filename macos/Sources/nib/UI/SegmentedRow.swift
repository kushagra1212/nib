import AppKit

/// A row of mutually exclusive choices, built from the same control as
/// everything else.
///
/// AppKit's NSSegmentedControl was the one thing in the rewrite bar that could
/// not be made to match its neighbours: its height, corner radius, font
/// rendering and selection colour come from the system, and none of them can be
/// set to agree with a custom button standing next to it. The result was a row
/// where four controls looked like nib and the fifth looked like System
/// Settings.
///
/// This is the same PillButton, three times, sharing one selection. Identical
/// height, radius, hairline, face and pigment, because it is literally the same
/// object.
final class SegmentedRow: NSView {
    /// Called with the index chosen.
    var onSelect: ((Int) -> Void)?

    private(set) var selectedIndex = 0
    private var buttons: [PillButton] = []
    private let row = NSStackView()

    init(titles: [String], selected: Int = 0) {
        super.init(frame: .zero)
        selectedIndex = selected

        // Hairline gaps rather than spacing: the segments read as one object
        // divided, which is what a choice between three settings is, instead of
        // three separate buttons that happen to be adjacent.
        row.orientation = .horizontal
        row.spacing = Theme.Metric.hairline
        row.translatesAutoresizingMaskIntoConstraints = false

        for (index, title) in titles.enumerated() {
            let button = PillButton(title: title, emphasis: .plain,
                                    target: self, action: #selector(tapped(_:)))
            button.tag = index
            buttons.append(button)
            row.addArrangedSubview(button)
        }

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    /// Moves the selection without telling anyone, for restoring saved state.
    func select(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        selectedIndex = index
        refresh()
    }

    @objc private func tapped(_ sender: NSButton) {
        guard buttons.indices.contains(sender.tag) else { return }
        selectedIndex = sender.tag
        refresh()
        onSelect?(sender.tag)
    }

    /// Brass marks the choice.
    ///
    /// Gilding is a line in this style, not a slab, so the selected segment is
    /// filled at low opacity and edged rather than flooded -- which also keeps
    /// the label readable, where a solid accent behind small serif text does
    /// not.
    private func refresh() {
        for (index, button) in buttons.enumerated() {
            button.setSelected(index == selectedIndex, tint: Theme.Colour.brass)
        }
    }
}
