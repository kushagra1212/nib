import AppKit

/// Three dots that rise and fade in sequence while the model works.
///
/// A spinner reads as "the app is busy". Local generation takes a second or
/// two, and something with a rhythm to it makes that wait feel intentional
/// rather than stuck.
final class LoadingDots: NSView {
    private var dots: [CALayer] = []
    private let count = 3
    private let radius: CGFloat = 3
    private let gap: CGFloat = 5

    var tint: NSColor = .secondaryLabelColor {
        didSet { dots.forEach { $0.backgroundColor = tint.cgColor } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<count {
            let dot = CALayer()
            dot.cornerRadius = radius
            dot.backgroundColor = tint.cgColor
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(count) * radius * 2 + CGFloat(count - 1) * gap,
               height: radius * 2 + 6)
    }

    override func layout() {
        super.layout()
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (radius * 2 + gap),
                               y: bounds.midY - radius,
                               width: radius * 2, height: radius * 2)
        }
    }

    func start() {
        isHidden = false
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()

            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0
            rise.toValue = 4

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.35
            fade.toValue = 1

            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 0.45
            group.autoreverses = true
            group.repeatCount = .infinity
            // Offset per dot so the motion travels along the row.
            group.timeOffset = Double(index) * 0.15
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(group, forKey: "pulse")
        }
    }

    func stop() {
        dots.forEach { $0.removeAllAnimations() }
        isHidden = true
    }
}
