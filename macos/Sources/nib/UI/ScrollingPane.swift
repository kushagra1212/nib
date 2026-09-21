import AppKit

/// A scrolling pane whose width the window controls, not the other way round.
///
/// This exists because the obvious layout does not survive the app becoming a
/// regular one.
///
/// Pinning a scroll view to its content view with constraints hands Auto
/// Layout the job of sizing the window. That is fine until
/// `setActivationPolicy` switches nib from accessory to regular, which makes
/// AppKit recompute window frames -- and a constraint-driven window with an
/// NSScrollView in it, whose document tracks the scroll view's width, has no
/// width of its own to recompute back to. The control panel opened at
/// `size = (0, 648)` on the display the pointer was on: invisible, while the
/// log cheerfully recorded that the panel had opened.
///
/// Frames and autoresizing masks above the document, Auto Layout strictly
/// inside it. The window stays authoritative about its own size and the policy
/// switch has nothing to take away.
///
/// Note what is *not* claimed: that the old arrangement is broken on its own.
/// It is not. `ScrollingPaneTests` builds one in a plain window and it holds
/// its width exactly. The policy switch is the other half, and an earlier
/// version of this comment blamed the layout alone -- wrongly, and confidently.
///
enum ScrollingPane {
    /// Wraps `content` in a scroll view on nib's aurora backdrop, sized to
    /// `size` and resizing with its window.
    static func make(content: NSView, size: NSSize) -> NSView {
        let bounds = NSRect(origin: .zero, size: size)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let scroll = NSScrollView(frame: bounds)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = document

        // Against the clip view, not the scroll view. The document tracks the
        // visible area so text wraps to it instead of scrolling sideways, and
        // because this constrains the document it cannot reach the window.
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])

        let aurora = Theme.makeAurora()
        aurora.frame = bounds
        aurora.autoresizingMask = [.width, .height]
        aurora.addSubview(scroll)

        let root = NSView(frame: bounds)
        root.autoresizingMask = [.width, .height]
        root.addSubview(aurora)
        return root
    }
}
