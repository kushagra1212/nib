import ApplicationServices
import Foundation

/// The three text-marker functions that have no Swift declaration.
///
/// Chromium answers `AXBoundsForTextMarkerRange` with real geometry while
/// returning an empty rectangle for the documented `AXBoundsForRange`, so
/// markers are the only route to a rectangle in Slack, ChatGPT, Chrome and
/// every other Electron app. Markers themselves can only be obtained from the
/// app -- and Slack refuses `AXStartTextMarkerForBounds` and
/// `AXTextMarkerForPosition`, the two documented ways of asking.
///
/// What it does answer is `AXTextMarkerRangeForUIElement`, a range covering
/// the whole field. Splitting that range into its two markers, and building a
/// narrower range from a pair, are C functions that ship in
/// ApplicationServices but appear in no public header. They are looked up by
/// name rather than linked, so a macOS release that drops them leaves nib
/// falling back to the badge rather than failing to launch.
enum TextMarkerBridge {
    private typealias CopyMarker =
        @convention(c) (AnyObject) -> Unmanaged<AnyObject>?
    private typealias CreateRange =
        @convention(c) (CFAllocator?, AnyObject, AnyObject) -> Unmanaged<AnyObject>?

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let copyStart = symbol(
        "AXTextMarkerRangeCopyStartMarker", as: CopyMarker.self)
    private static let copyEnd = symbol(
        "AXTextMarkerRangeCopyEndMarker", as: CopyMarker.self)
    private static let createRange = symbol(
        "AXTextMarkerRangeCreate", as: CreateRange.self)

    /// Whether this system has the functions at all.
    static var isAvailable: Bool {
        copyStart != nil && copyEnd != nil && createRange != nil
    }

    /// Both are `Copy` functions, so the result arrives retained.
    static func startMarker(of range: AnyObject) -> AnyObject? {
        copyStart?(range)?.takeRetainedValue()
    }

    static func endMarker(of range: AnyObject) -> AnyObject? {
        copyEnd?(range)?.takeRetainedValue()
    }

    static func range(from start: AnyObject, to end: AnyObject) -> AnyObject? {
        createRange?(kCFAllocatorDefault, start, end)?.takeRetainedValue()
    }
}
