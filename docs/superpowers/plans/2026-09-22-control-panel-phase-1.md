# nib control panel, phase 1 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** make nib openable — one window holding everything it knows, reachable by clicking nib
in Finder, with the menu bar reduced to quick actions.

**Architecture:** a new `ControlPanelWindow` hosts section views in a sidebar. `HealthWindow`'s
rendering becomes `StatusSection`, an `NSView` factory rather than a window, so the existing
cards, Restart and Open setup keep working unchanged. nib switches from `.accessory` to
`.regular` while the window is open so it gets a Dock icon, ⌘-Tab and real focus.

**Tech Stack:** Swift 6.2, AppKit, XCTest. Existing helpers: `Theme.makeAurora()`, `PillButton`,
`FlippedView`, `Health.report(_:)`.

**Prerequisite:** the core must be built before any `swift build` — `cmake --build core/build`.

---

## File structure

| Path | Responsibility |
|---|---|
| `macos/Sources/nib/Support/ActivationPolicy.swift` | when nib should show a Dock icon |
| `macos/Sources/nib/UI/ControlPanel/ControlPanelSection.swift` | the sidebar's sections, as data |
| `macos/Sources/nib/UI/ControlPanel/ControlPanelWindow.swift` | window, sidebar, section hosting |
| `macos/Sources/nib/UI/ControlPanel/StatusSection.swift` | feature cards, extracted from HealthWindow |
| `macos/Tests/nibTests/ActivationPolicyTests.swift` | Dock policy decisions |
| `macos/Tests/nibTests/ControlPanelSectionTests.swift` | section list and titles |

Modified: `macos/Sources/nib/UI/HealthWindow.swift` (delegates rendering to `StatusSection`),
`macos/Sources/nib/UI/AppDelegate.swift` (menu reduction, open, reopen),
`macos/Sources/nib/main.swift:428` (policy set through `ActivationPolicy`).

Phase 1 does **not** touch the probes, models, or the log. Those are phases 2 and 3.

---

## Task 1: Decide when nib shows a Dock icon

nib is `.accessory`: no Dock icon, no ⌘-Tab. That is right for a menu-bar tool and wrong for a
window, whose focus behaviour is broken without it. The decision is pure and therefore tested;
applying it touches `NSApp` and is not.

**Files:**
- Create: `macos/Sources/nib/Support/ActivationPolicy.swift`
- Test: `macos/Tests/nibTests/ActivationPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import AppKit
import XCTest
@testable import nib

/// A Dock icon that appears and never leaves is worse than none, so the rule
/// is asserted rather than left to whoever calls it last.
final class ActivationPolicyTests: XCTestCase {
    func testNoWindowsMeansMenuBarOnly() {
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 0), .accessory)
    }

    func testAnyOpenWindowMeansRegular() {
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 1), .regular)
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 4), .regular)
    }

    // Closing one of two windows must not drop the Dock icon while the other
    // is still on screen.
    func testCountIsWhatMattersNotAFlag() {
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 2), .regular)
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 1), .regular)
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 0), .accessory)
    }

    func testNegativeCountIsTreatedAsNone() {
        // Defensive: an unbalanced close should not leave a Dock icon behind.
        XCTAssertEqual(ActivationPolicy.desired(openWindows: -1), .accessory)
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
cmake --build core/build
swift test --package-path macos --filter ActivationPolicyTests 2>&1 | tail -5
```

Expected: a compile error naming `ActivationPolicy` as unresolved.

- [ ] **Step 3: Write the implementation**

`macos/Sources/nib/Support/ActivationPolicy.swift`:

```swift
import AppKit

/// Whether nib appears in the Dock.
///
/// nib is a menu-bar tool and spends almost all its life as `.accessory`: no
/// Dock icon, no ⌘-Tab, no app menu. That stops being right the moment it owns
/// a window. An accessory app's windows cannot be reached with ⌘-Tab, so one
/// that slips behind Safari can only be recovered through the menu bar -- and
/// someone who has just been told "open nib to see what is broken" is not in a
/// mood to hunt.
///
/// So the policy follows the windows: regular while any is open, accessory
/// again when the last one closes.
@MainActor
enum ActivationPolicy {
    /// The decision, separated from applying it so it can be tested.
    nonisolated static func desired(openWindows: Int) -> NSApplication.ActivationPolicy {
        openWindows > 0 ? .regular : .accessory
    }

    /// How many nib windows are currently on screen.
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        apply()
    }

    static func windowClosed() {
        // Clamped rather than allowed to go negative: an unbalanced close would
        // otherwise leave nib one window away from never showing a Dock icon
        // again, which is a bug nobody would connect to this.
        openWindows = max(0, openWindows - 1)
        apply()
    }

    private static func apply() {
        let policy = desired(openWindows: openWindows)
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        Log.write("activation policy now \(policy == .regular ? "regular" : "accessory")")
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
swift test --package-path macos --filter ActivationPolicyTests 2>&1 | tail -5
```

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/nib/Support/ActivationPolicy.swift \
        macos/Tests/nibTests/ActivationPolicyTests.swift
git commit -m "Show a Dock icon only while a nib window is open"
```

---

## Task 2: Describe the sidebar as data

The sidebar is a list of sections. Keeping that list as a value rather than as view code means
the order and titles can be asserted, and phases 2 and 3 add a case without touching layout.

**Files:**
- Create: `macos/Sources/nib/UI/ControlPanel/ControlPanelSection.swift`
- Test: `macos/Tests/nibTests/ControlPanelSectionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import nib

final class ControlPanelSectionTests: XCTestCase {
    // Status is first because the window exists to answer "what is broken".
    func testStatusComesFirst() {
        XCTAssertEqual(ControlPanelSection.allCases.first, .status)
    }

    func testEverySectionHasATitleAndSymbol() {
        for section in ControlPanelSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) has no title")
            XCTAssertFalse(section.symbol.isEmpty, "\(section) has no symbol")
        }
    }

    // Phase 1 ships one section. The others arrive with the work that fills
    // them, rather than as empty panes that look broken.
    func testPhaseOneShipsStatusOnly() {
        XCTAssertEqual(ControlPanelSection.allCases, [.status])
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
swift test --package-path macos --filter ControlPanelSectionTests 2>&1 | tail -5
```

Expected: a compile error naming `ControlPanelSection` as unresolved.

- [ ] **Step 3: Write the implementation**

`macos/Sources/nib/UI/ControlPanel/ControlPanelSection.swift`:

```swift
import Foundation

/// The sidebar, as data.
///
/// One case per pane. Phase 1 ships only Status: an empty Models pane reads as
/// a broken app rather than an unfinished one, so sections appear when the work
/// that fills them does.
enum ControlPanelSection: String, CaseIterable {
    case status

    var title: String {
        switch self {
        case .status: return "Status"
        }
    }

    /// SF Symbol shown beside the title.
    var symbol: String {
        switch self {
        case .status: return "waveform.path.ecg"
        }
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
swift test --package-path macos --filter ControlPanelSectionTests 2>&1 | tail -5
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/nib/UI/ControlPanel/ControlPanelSection.swift \
        macos/Tests/nibTests/ControlPanelSectionTests.swift
git commit -m "Describe the control panel's sections as data"
```

---

## Task 3: Extract the status cards from HealthWindow

`HealthWindow` currently owns both a window and the rendering of seven feature cards. The cards
are what the control panel needs; the window is what it replaces. Splitting them lets both use
the same code during the transition, so nothing regresses while the menu still points at
*Status…*.

**Files:**
- Create: `macos/Sources/nib/UI/ControlPanel/StatusSection.swift`
- Modify: `macos/Sources/nib/UI/HealthWindow.swift`

- [ ] **Step 1: Read the current rendering before moving it**

```bash
sed -n '93,215p' macos/Sources/nib/UI/HealthWindow.swift
```

Note every private helper it uses: `card(for:)`, `label(_:size:weight:colour:)`, `spacer(_:)`,
`indented(_:)`, `colour(for:)`, `needsDownload(_:)`, and the `@objc` actions `restartOne(_:)`,
`fixOne(_:)`, `restartApp`. All of them move.

- [ ] **Step 2: Create StatusSection with the moved rendering**

`macos/Sources/nib/UI/ControlPanel/StatusSection.swift`:

```swift
import AppKit

/// The seven feature cards, as a view rather than a window.
///
/// Lifted wholesale out of HealthWindow so the control panel and the old
/// Status… window render the same thing during the transition. Only the
/// ownership changed: this builds a view and reports what the user pressed,
/// and knows nothing about where it is shown.
@MainActor
final class StatusSection: NSObject {
    /// Supplied by AppDelegate, which owns the engines this reads the state of.
    var context: @MainActor () -> HealthContext = { .empty() }
    /// Restart one feature. Returns a line to show, or nil to stay quiet.
    var onRestart: (@MainActor (Feature) -> String?)?
    /// Restart the whole app.
    var onRestartApp: (@MainActor () -> Void)?
    /// Open the window that fixes a missing download.
    var onFix: (@MainActor (Feature) -> Void)?

    private let body = NSStackView()
    private var note: String?

    /// The view to place in a window. Built once; `refresh()` re-renders it.
    func makeView() -> NSView {
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        body.translatesAutoresizingMaskIntoConstraints = false
        render()
        return body
    }

    func refresh() {
        render()
    }

    /// Clears the transient line under the heading, so a restart note from last
    /// time is not read as the result of this time.
    func clearNote() {
        note = nil
    }

    // MARK: - Rendering
    //
    // Moved verbatim from HealthWindow. Every private helper it used moved with
    // it; see that file's history for why each reads the way it does.

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

    @objc private func restartApp() {
        onRestartApp?()
    }

    @objc private func restartOne(_ sender: NSButton) {
        let feature = Feature.allCases[sender.tag]
        note = onRestart?(feature) ?? "Restarted \(feature.title.lowercased())."
        render()
    }

    @objc private func fixOne(_ sender: NSButton) {
        onFix?(Feature.allCases[sender.tag])
    }
}
```

Then move `card(for:)`, `label(_:size:weight:colour:)`, `spacer(_:)`, `indented(_:)`,
`colour(for:)` and `needsDownload(_:)` from `HealthWindow.swift` into this file **unchanged**,
as `private` members of `StatusSection`.

- [ ] **Step 3: Make HealthWindow use it**

In `HealthWindow.swift`, delete the moved members and the `body` stack view, and hold a
`StatusSection` instead. Its `show()` keeps building the window and scroll view, but places
`section.makeView()` inside `FlippedView` where `body` used to go, and forwards its four
callbacks:

```swift
private let section = StatusSection()

// In show(), before building the scroll view:
section.context = context
section.onRestart = onRestart
section.onRestartApp = onRestartApp
section.onFix = onFix
let sectionView = section.makeView()
```

Replace the three uses of `body` in the constraint block with `sectionView`, and replace the
`render()` calls in `show()` and `refresh()` with `section.refresh()`. In
`windowShouldClose(_:)`, replace `note = nil` with `section.clearNote()`.

- [ ] **Step 4: Build and run the whole suite**

```bash
cmake --build core/build
swift test --package-path macos 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1
```

Expected: `Executed 712 tests, with 0 failures` — the 705 that existed plus the 7 added in
tasks 1 and 2. A different total means something moved that should not have.

- [ ] **Step 5: Confirm the old window still works**

```bash
swift build -c release --package-path macos && Scripts/bundle.sh && Scripts/install.sh
open -a nib
```

Open **Status…** from the menu bar. Expected: the same seven cards as before, with Restart and
Open setup behaving as they did. This is a refactor; it should be invisible.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/nib/UI/ControlPanel/StatusSection.swift \
        macos/Sources/nib/UI/HealthWindow.swift
git commit -m "Make the status cards a view rather than a window"
```

---

## Task 4: Build the control panel window

**Files:**
- Create: `macos/Sources/nib/UI/ControlPanel/ControlPanelWindow.swift`

- [ ] **Step 1: Write the window**

`macos/Sources/nib/UI/ControlPanel/ControlPanelWindow.swift`:

```swift
import AppKit

/// nib's one window.
///
/// Everything nib knows used to be spread across twenty menu items, and the
/// window that already held most of it was behind an item called "Status…"
/// that a daily user had not found. A menu is a fine place for five verbs and
/// a poor place for a control panel.
///
/// The sidebar is a plain table rather than NSSplitViewController: there are
/// few sections, none of them collapse, and the list is data
/// (`ControlPanelSection`) so adding one is a case rather than a layout change.
@MainActor
final class ControlPanelWindow: NSObject, NSWindowDelegate, NSTableViewDataSource,
                                NSTableViewDelegate {
    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let container = NSView()
    private var selected: ControlPanelSection = .status

    /// The Status pane. Owned here, configured by AppDelegate.
    let status = StatusSection()

    private var sectionViews: [ControlPanelSection: NSView] = [:]

    func show() {
        if let window {
            status.refresh()
            raise(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "nib"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 460)

        window.contentView = makeContent()
        window.center()
        self.window = window

        ActivationPolicy.windowOpened()
        raise(window)
        Log.write("control panel opened")
    }

    private func raise(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        status.clearNote()
        ActivationPolicy.windowClosed()
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let content = Theme.makeAurora()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.width = 180
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.backgroundColor = .clear
        sidebar.selectionHighlightStyle = .regular
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.rowHeight = 30
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = sidebar
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebarScroll)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 180),

            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        present(.status)
        return content
    }

    /// Section views are built once and kept. Rebuilding on every click would
    /// discard scroll position and any text mid-edit.
    private func present(_ section: ControlPanelSection) {
        selected = section
        container.subviews.forEach { $0.removeFromSuperview() }

        let view: NSView
        if let existing = sectionViews[section] {
            view = existing
        } else {
            view = makeSectionView(section)
            sectionViews[section] = view
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: flipped.topAnchor),
            view.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        scroll.documentView = flipped

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    private func makeSectionView(_ section: ControlPanelSection) -> NSView {
        switch section {
        case .status: return status.makeView()
        }
    }

    // MARK: - Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int {
        ControlPanelSection.allCases.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = ControlPanelSection.allCases[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: section.title)
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = Theme.Colour.ink
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < ControlPanelSection.allCases.count else { return }
        present(ControlPanelSection.allCases[row])
    }
}
```

- [ ] **Step 2: Build**

```bash
cmake --build core/build && swift build --package-path macos 2>&1 | tail -3
```

Expected: `Build complete!`. Nothing opens it yet — that is task 5.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/nib/UI/ControlPanel/ControlPanelWindow.swift
git commit -m "Add the control panel window"
```

---

## Task 5: Open it, and cut the menu down

**Files:**
- Modify: `macos/Sources/nib/UI/AppDelegate.swift`
- Modify: `macos/Sources/nib/main.swift:428`

- [ ] **Step 1: Route the activation policy through ActivationPolicy**

In `macos/Sources/nib/main.swift`, replace:

```swift
app.setActivationPolicy(.accessory)
```

with:

```swift
// Accessory until a window opens; ActivationPolicy owns the switching.
app.setActivationPolicy(ActivationPolicy.desired(openWindows: 0))
```

- [ ] **Step 2: Own the panel in AppDelegate**

Add beside the other lazy windows:

```swift
@MainActor private lazy var controlPanel = makeControlPanel()

@MainActor
private func makeControlPanel() -> ControlPanelWindow {
    let panel = ControlPanelWindow()
    panel.status.context = { [weak self] in self?.healthContext() ?? .empty() }
    panel.status.onRestart = { [weak self] feature in self?.restart(feature) }
    panel.status.onRestartApp = { [weak self] in self?.restartApp() }
    panel.status.onFix = { [weak self] feature in self?.fix(feature) }
    return panel
}

@MainActor
@objc private func showControlPanel() {
    controlPanel.show()
}
```

Reuse whatever the existing `showHealth` path already passes to `HealthWindow` for
`healthContext()`, `restart(_:)`, `restartApp()` and `fix(_:)` — those closures exist; only
their destination changes.

- [ ] **Step 3: Make clicking nib in Finder open the window**

Add to `AppDelegate`:

```swift
/// Clicking nib in Finder or the Dock while it is already running.
///
/// An accessory app receives this and, having no windows, does nothing
/// visible -- which is what made nib look broken: it was running the whole
/// time, in the menu bar, with no way to say so.
func applicationShouldHandleReopen(_ sender: NSApplication,
                                   hasVisibleWindows: Bool) -> Bool {
    showControlPanel()
    return true
}
```

- [ ] **Step 4: Replace the Status… item and add ⌘,**

At `macos/Sources/nib/UI/AppDelegate.swift:802`, replace the `statusEntry` item with:

```swift
let openEntry = NSMenuItem(title: "Open nib…", action: #selector(showControlPanel),
                           keyEquivalent: ",")
openEntry.keyEquivalentModifierMask = [.command]
openEntry.target = self
menu.addItem(openEntry)
```

Then remove these items from the menu, since the window now holds them — leave their actions in
place, because the window calls them:

- `Accessibility Settings…`
- `Diagnose Frontmost App…`
- `Diagnose Live Checking…`
- `Licences…`
- the `Memory: …` line

Leave `Voices…`, `Dictation Words…` and `Practice Takes…` where they are for now; they move in
phase 3 with their sections.

- [ ] **Step 5: Build, test, and check the count**

```bash
cmake --build core/build
swift test --package-path macos 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1
swift build -c release --package-path macos 2>&1 | tail -1
```

Expected: `Executed 712 tests, with 0 failures` and `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/nib/UI/AppDelegate.swift macos/Sources/nib/main.swift
git commit -m "Open the control panel from the menu and from Finder"
```

---

## Task 6: Check it by hand

Phase 1 is UI, and the suite cannot see any of it. These are the things that would be embarrassing to ship broken.

**Files:** none.

- [ ] **Step 1: Install the build**

```bash
cmake --build core/build
swift build -c release --package-path macos
Scripts/bundle.sh
Scripts/install.sh
```

`install.sh` clears Accessibility and Microphone because the ad-hoc signature changed. Re-approve
nib in System Settings → Privacy & Security → Accessibility before checking anything that reads
text.

- [ ] **Step 2: Walk the checks**

| Do this | Expect |
|---|---|
| Click nib in Finder | The window opens |
| Look at the Dock | A nib icon is present while the window is open |
| ⌘-Tab | nib is in the switcher |
| Close the window | The Dock icon disappears; the menu bar icon stays |
| Click nib in Finder again | The window comes back |
| Menu bar → **Open nib…** | The window opens; ⌘, does the same |
| Sidebar | Status is selected, showing seven cards |
| Press **Restart** on grammar checking | A line appears under the heading saying what happened |
| Press **Restart nib** | nib relaunches and the window is gone |
| Open the window, click another app, then ⌘-Tab back | The window is reachable |

- [ ] **Step 3: Confirm the window is not leaking policy**

```bash
# With the window closed, nib must not be in the Dock.
osascript -e 'tell application "System Events" to get name of every process whose background only is false' \
  | tr ',' '\n' | grep -i nib || echo "nib is not a foreground app -- correct with the window closed"
```

Expected: the `correct with the window closed` line.

- [ ] **Step 4: Commit nothing**

No code changes here. If any check failed, fix it and re-run the whole table rather than the one
row — the activation policy in particular fails in combinations, not singly.

---

## Phase 1 exit criteria

- [ ] `swift test --package-path macos` reports 712 tests, 0 failures
- [ ] Clicking nib in Finder opens the window
- [ ] The Dock icon appears with the window and leaves with it
- [ ] The Status section shows the same seven cards as the old Status… window
- [ ] Restart and Restart nib behave as they did before
- [ ] The menu bar is down to fifteen items, with **Open nib… ⌘,** among them

---

## Self-review notes

Checked against `docs/superpowers/specs/2026-09-22-nib-control-panel-design.md`:

- Spec items covered here: window shell (task 4), sidebar as data (task 2), activation policy
  (tasks 1 and 5), Status section (task 3), launch and reopen (task 5), menu reduction (task 5).
- Spec items deliberately **not** here, and where they go: Test and Fix plus the probe refactor
  (phase 2); Models, Voices, Dictation Words, Diagnostics, the log buffer and the report
  (phase 3). The spec's scope section was corrected to three phases to match.
- No placeholders: every code step carries the full file or the exact edit.
- Type consistency: `ControlPanelSection.allCases`, `StatusSection.makeView()`, `refresh()`,
  `clearNote()`, and `ActivationPolicy.desired(openWindows:)` / `windowOpened()` /
  `windowClosed()` are used with those exact names throughout.
- Known soft spot: task 3 step 3 describes moving private helpers rather than reproducing them,
  because they are being moved unchanged and reproducing 120 lines here would invite editing
  them in transit. The step names every one of them so nothing is missed.
