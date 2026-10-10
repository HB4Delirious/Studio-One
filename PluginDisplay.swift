import AppKit
import CoreMIDI
import Foundation

/// The controls picked from the plug-ins on Topline's channel, read live from
/// Logic, for the panel in the Controls window.
///
/// Logic tells a Mackie Control what the plug-in it's editing is set to: each
/// control's name and its value as the plug-in shows it, the moment it
/// changes, whether from the M-BRIO, the mouse, automation or a preset. So
/// Studio One presents itself as one — a Mackie Control and an extender, on
/// ports of their own called "Studio One Display", which Logic installs by
/// itself — and sees sixteen controls, one page, at a time.
///
/// Reading (Settings › Plug-ins) walks every page of every plug-in on the
/// channel Logic has locked, for the names to pick from. Showing keeps Logic
/// on the page holding the picked controls of the plug-in the panel shows;
/// picks on more than one page are taken in turn, a moment on each, so none
/// is more than a second or two old.
///
/// Studio One sends the plug-ins nothing. It presses only the surface's own
/// buttons: Plug-In, a knob on an insert that holds a plug-in (which opens
/// it), the cursor keys. It never presses a knob on an empty insert slot,
/// which starts Logic's chooser for adding a plug-in there, and moves the
/// cursor only while the display shows a plug-in it has read.
///
/// Measured in Logic 12.3.1: Plug-In lists the selected channel's inserts;
/// pressing a knob opens that insert; cursor Up and Down step through the
/// inserts, naming each in full (`Insert 3 "MetaTune (s/s)"`); Left and Right
/// turn the page and name it (`Page 1/2`) — Left on the first page stays
/// there and names it all the same. Logic follows the track selected in
/// Logic unless the surface's Track Lock is on.
@MainActor
final class PluginDisplay: ObservableObject {

    /// The panel in the Controls window: the plug-ins on Topline's channel.
    static let shared = PluginDisplay(.panel)
    /// The key check: MetaTune on Mic 1's channel, from a second surface in a
    /// control surface group of its own (see `KeyCheck`).
    static let check = PluginDisplay(.check)

    /// What an instance is for: its ports, its settings, its words.
    enum Role {
        case panel, check

        var portName: String { self == .panel ? "Studio One Display" : "Studio One Check" }
        var enabledKey: String { self == .panel ? "pluginDisplayEnabled" : "keyCheckEnabled" }
        /// The channel Logic should have locked for it.
        var channel: String { self == .panel ? "Topline's channel" : "Mic 1's channel" }
        /// Fixed IDs, so Logic knows the ports again from launch to launch.
        fileprivate var identities: (Int32, Int32) {
            self == .panel ? (0x53_4F_44_31, 0x53_4F_44_32)   // "SOD1", "SOD2"
                           : (0x53_4F_43_31, 0x53_4F_43_32)   // "SOC1", "SOC2"
        }
        /// The panel is on unless turned off; the check needs setting up in
        /// Logic first, so it waits to be turned on.
        fileprivate var onByDefault: Bool { self == .panel }
        fileprivate var defaultsPrefix: String { self == .panel ? "pluginDisplay" : "keyCheck" }
        fileprivate var logName: String { self == .panel ? "plugin display" : "key check" }
    }

    let role: Role
    var portName: String { role.portName }

    /// The panel's own fold: folded, Studio One leaves Logic's pages alone.
    static let panelOpenKey = "pluginDisplay.open"
    private var layoutsKey: String { role.defaultsPrefix + ".layouts" }
    private var picksKey: String { role.defaultsPrefix + ".picks" }
    private var labelsKey: String { role.defaultsPrefix + ".labels" }
    private var shownKey: String { role.defaultsPrefix + ".shown" }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: role.enabledKey) as? Bool ?? role.onByDefault }

    /// A plug-in on the channel, and its controls as Logic pages through them.
    struct Layout: Codable, Equatable, Identifiable {
        /// Its insert slot, from 1.
        var slot: Int
        /// In full, as Logic names it stepping through the inserts.
        let name: String
        /// As Plug-In's list of inserts shows it ("UADx To"), to find it by.
        let shortName: String
        /// Controls to a page: eight for each unit Logic showed them on.
        let pageSize: Int
        /// Every control's short name, in Logic's order.
        let controls: [String]

        var id: String { name }
        var pageCount: Int { max(1, (controls.count + pageSize - 1) / pageSize) }

        /// Logic fills the last page from the end: MetaTune's 21 controls
        /// show as 1–16, then 6–21.
        func start(of page: Int) -> Int {
            page < pageCount ? (page - 1) * pageSize : max(0, controls.count - pageSize)
        }

        /// The fewest pages that show all of `indices`: for each not yet
        /// shown, the page that shows it and reaches furthest on — the last,
        /// where two pages do.
        func pages(showing indices: [Int]) -> [Int] {
            var pages: [Int] = []
            var shown = 0..<0
            for index in indices.sorted() where index < controls.count && !shown.contains(index) {
                let page = index >= start(of: pageCount) ? pageCount : index / pageSize + 1
                pages.append(page)
                shown = start(of: page)..<(start(of: page) + pageSize)
            }
            return pages
        }
    }

    struct Reading: Equatable {
        let value: String
        /// 0…1 from the knob's LED ring, when it shows one.
        let position: Double?
    }

    /// A picked control, for the panel; no reading until Logic has shown it.
    struct Control: Identifiable, Equatable {
        let id: Int
        /// As named in Settings, else Logic's short name.
        let name: String
        let logicName: String
        let reading: Reading?
    }

    enum Phase: Equatable {
        case off
        case waitingForLogic
        case connected
        case reading(String)
        case showing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    /// The plug-ins on the channel, as last read.
    @Published private(set) var layouts: [Layout] = []
    /// What's picked from each plug-in, by name: positions in its `controls`,
    /// in the order the panel shows them.
    @Published private(set) var picks: [String: [Int]] = [:]
    /// Names given to controls in Settings, by plug-in name and position.
    @Published private(set) var labels: [String: [Int: String]] = [:]
    /// The latest of each control Logic has shown, by plug-in name and position.
    @Published private(set) var readings: [String: [Int: Reading]] = [:]
    /// The plug-in on the panel, by name.
    @Published private(set) var shownName: String?
    /// An alert Logic has open, as it shows on the surface. Logic ignores every
    /// controller while one is up — the key, the tempo, the M-BRIO — and
    /// Studio One presses nothing until it's gone.
    @Published private(set) var logicAlert: String?
    /// Logic's channel meters, 0–12, for the sixteen strips the two units
    /// show — refreshed ten times a second, falling back as a real meter
    /// would between Logic's updates (see `MicMeters`).
    @Published private(set) var meters = [Int](repeating: 0, count: 16)
    /// When each strip last showed a level above the floor.
    private(set) var meterHeard = [Date](repeating: .distantPast, count: 16)
    private var meterLevels = [Int](repeating: 0, count: 16)
    private var meterUpdated = [Date](repeating: .distantPast, count: 16)
    private var meterTimer: Timer?

    private init(_ role: Role) {
        self.role = role
        units = [
            Unit(model: 0x14, name: role.portName, identity: role.identities.0),
            Unit(model: 0x15, name: role.portName + " 2", identity: role.identities.1),
        ]
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: layoutsKey),
           let stored = try? JSONDecoder().decode([Layout].self, from: data) {
            layouts = stored
        }
        if let data = defaults.data(forKey: picksKey),
           let stored = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            picks = stored
        }
        if let data = defaults.data(forKey: labelsKey),
           let stored = try? JSONDecoder().decode([String: [Int: String]].self, from: data) {
            labels = stored
        }
        shownName = defaults.string(forKey: shownKey)
    }

    // MARK: - The surface

    /// One Mackie unit: the Mackie Control, then its extender, each with an
    /// output and an input of the same name. Fixed IDs, so Logic knows them
    /// again from launch to launch.
    private final class Unit {
        let model: UInt8
        let name: String
        let identity: Int32
        var source = MIDIEndpointRef()
        var destination = MIDIEndpointRef()
        /// Logic has drawn on it since connecting.
        var online = false
        /// The two display lines, 56 characters each, seven per strip:
        /// the top as shown, notices and all, and as the controls' names.
        var shown = [UInt8](repeating: 32, count: 56)
        var names = [UInt8](repeating: 32, count: 56)
        var values = [UInt8](repeating: 32, count: 56)
        var rings = [UInt8](repeating: 0, count: 8)

        init(model: UInt8, name: String, identity: Int32) {
            self.model = model
            self.name = name
            self.identity = identity
        }
    }

    private let units: [Unit]
    private var client = MIDIClientRef()
    private var started = false
    private var identityTimer: Timer?
    /// Reading or showing: one at a time, as both press the surface's buttons.
    private var work: Task<Void, Never>?
    private var autoStart: Task<Void, Never>?
    private var logicWatch: NSObjectProtocol?

    /// Bumped by every display update, so a step can wait for Logic's answer.
    private var updates = 0
    /// The insert and the page Logic last named, and how many times each was
    /// newly drawn — a repeat of the same notice counts.
    private var insert: (slot: Int, name: String)?
    private var page: (current: Int, count: Int)?
    private var insertNotices = 0
    private var pageNotices = 0
    /// The characters of the top line under a notice now.
    private var covered = IndexSet()

    /// Where the display is, by our own steps: a read plug-in's slot and page.
    private var location: (slot: Int, page: Int)?
    /// Since when what's shown hasn't been what `location` should show.
    private var mismatchSince: Date?
    /// When a picked control last changed while on show.
    private var lastChange = Date.distantPast

    private enum Button: UInt8 {
        case plugIn = 0x2B
        case up = 0x60, down = 0x61, left = 0x62, right = 0x63
    }

    // MARK: - Starting

    func start() {
        guard isEnabled, !started else { return }
        guard MIDIClientCreate(portName as CFString, nil, nil, &client) == noErr else {
            log("no MIDI client")
            return
        }
        for (index, unit) in units.enumerated() {
            MIDISourceCreate(client, unit.name as CFString, &unit.source)
            var assembly: [UInt8] = []   // Touched only on CoreMIDI's thread for this input.
            MIDIDestinationCreateWithBlock(client, unit.name as CFString, &unit.destination) { list, _ in
                for message in Self.messages(in: list, assembling: &assembly) {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.receive(message, unit: index) }
                    }
                }
            }
        }
        claimIdentities()
        if role == .panel { startMeters() }
        started = true
        phase = .waitingForLogic
        logicWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard LogicBackup.logicBundleIDs.contains(app?.bundleIdentifier ?? "") else { return }
            MainActor.assumeIsolated { self?.logicQuit() }
        }
        log("ports up, waiting for Logic")
    }

    /// Takes the ports' fixed unique IDs, and keeps trying for as long as
    /// something else holds one — another Studio One, or one still quitting.
    /// Logic finds its control surfaces by ID as it launches; giving up would
    /// leave the display unconnected until Studio One starts again.
    private func claimIdentities() {
        guard identityTimer == nil else { return }
        if tryClaimIdentities() { return }
        log("port identity held elsewhere — waiting for it")
        identityTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            Task { @MainActor in
                // A tick already queued when `stop()` ran finds another timer, or none.
                guard let self, self.identityTimer === timer else { return timer.invalidate() }
                if self.tryClaimIdentities() {
                    timer.invalidate()
                    self.identityTimer = nil
                }
            }
        }
    }

    /// Every port in turn, so those free are taken now and only the rest wait.
    private func tryClaimIdentities() -> Bool {
        var claimed = false
        var waiting = false
        for unit in units {
            for (endpoint, identity) in [(unit.source, unit.identity), (unit.destination, unit.identity + 0x10)] {
                var current: Int32 = 0
                MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &current)
                if current == identity { continue }
                if MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, identity) == noErr {
                    claimed = true
                } else {
                    waiting = true
                }
            }
        }
        if claimed, !waiting { log("port identity claimed") }
        return !waiting
    }

    /// A Mackie meter message's data byte: the strip (high nibble) on this
    /// unit, numbered across both, and its level, 0–12. Nil for 0xE and 0xF,
    /// which set and clear the overload light.
    nonisolated static func meter(_ value: UInt8, unit: Int) -> (strip: Int, level: Int)? {
        let level = Int(value & 0x0F)
        guard level <= 0x0C else { return nil }
        return (unit * 8 + (Int(value >> 4) & 0x07), level)
    }

    /// Ten times a second: levels Logic hasn't refreshed for a moment fall a
    /// step, as a Mackie's own meters do, and the panel's copy is updated.
    private func startMeters() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                for strip in self.meterLevels.indices
                where self.meterLevels[strip] > 0 && now.timeIntervalSince(self.meterUpdated[strip]) > 0.3 {
                    self.meterLevels[strip] -= 1
                    self.meterUpdated[strip] = now.addingTimeInterval(-0.2)
                }
                if self.meters != self.meterLevels { self.meters = self.meterLevels }
            }
        }
    }

    func stop() {
        guard started else { return }
        stopWork()
        identityTimer?.invalidate()
        identityTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        for unit in units {
            MIDIEndpointDispose(unit.source)
            MIDIEndpointDispose(unit.destination)
        }
        MIDIClientDispose(client)
        if let logicWatch { NSWorkspace.shared.notificationCenter.removeObserver(logicWatch) }
        started = false
        phase = .off
        clear()
    }

    private func logicQuit() {
        guard started else { return }
        stopWork()
        phase = .waitingForLogic
        clear()
    }

    private func stopWork() {
        work?.cancel()
        work = nil
        autoStart?.cancel()
        autoStart = nil
    }

    private func clear() {
        readings = [:]
        logicAlert = nil
        alertText = ""
        lastWholeLine = nil
        alertEnding?.cancel()
        insert = nil
        page = nil
        location = nil
        mismatchSince = nil
        covered = IndexSet()
        for unit in units { unit.online = false }
    }

    private var isConnected: Bool { started && phase != .off && phase != .waitingForLogic }

    // MARK: - What the panel shows

    /// The plug-ins with something picked, in insert order: the panel's pages.
    var shownPlugins: [Layout] {
        layouts.filter { !(picks[$0.name] ?? []).isEmpty }
    }

    var shownPlugin: Layout? {
        let shown = shownPlugins
        return shown.first { $0.name == shownName } ?? shown.first
    }

    func controls(of layout: Layout) -> [Control] {
        (picks[layout.name] ?? []).compactMap { index in
            guard index < layout.controls.count else { return nil }
            return Control(id: index, name: label(index, in: layout), logicName: layout.controls[index],
                           reading: readings[layout.name]?[index])
        }
    }

    /// The panel's next or previous plug-in.
    func showPlugin(forward: Bool) {
        let shown = shownPlugins
        guard shown.count > 1, let current = shownPlugin, let index = shown.firstIndex(of: current) else { return }
        choose(shown[(index + (forward ? 1 : shown.count - 1)) % shown.count].name)
    }

    private func choose(_ name: String) {
        shownName = name
        UserDefaults.standard.set(name, forKey: shownKey)
    }

    // MARK: - Picking

    func isPicked(_ index: Int, in layout: Layout) -> Bool {
        picks[layout.name]?.contains(index) ?? false
    }

    /// Ticking adds to the end of what's shown; unticking takes it out.
    func setPicked(_ on: Bool, _ index: Int, in layout: Layout) {
        var picked = picks[layout.name] ?? []
        picked.removeAll { $0 == index }
        if on { picked.append(index) }
        setPicks(picked, for: layout)
    }

    func pickAll(_ on: Bool, in layout: Layout) {
        var picked = on ? picks[layout.name] ?? [] : []
        if on {
            picked += layout.controls.indices.filter { !layout.controls[$0].isEmpty && !picked.contains($0) }
        }
        setPicks(picked, for: layout)
    }

    /// The shown controls in a new order, as dragged in Settings.
    func movePicks(in layout: Layout, from offsets: IndexSet, to destination: Int) {
        let picked = picks[layout.name] ?? []
        var rest = picked.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let moving = offsets.filter { $0 < picked.count }.map { picked[$0] }
        rest.insert(contentsOf: moving, at: min(rest.count, destination - offsets.filter { $0 < destination }.count))
        setPicks(rest, for: layout)
    }

    /// A control's name on the panel: the one given it, else Logic's.
    func label(_ index: Int, in layout: Layout) -> String {
        labels[layout.name]?[index] ?? (index < layout.controls.count ? layout.controls[index] : "")
    }

    /// Names a control for the panel; blank, or Logic's own name, undoes it.
    func setLabel(_ text: String, _ index: Int, in layout: Layout) {
        let name = text.trimmingCharacters(in: .whitespaces)
        var named = labels[layout.name] ?? [:]
        named[index] = name.isEmpty || name == layout.controls[index] ? nil : name
        labels[layout.name] = named.isEmpty ? nil : named
        save()
    }

    private func setPicks(_ picked: [Int], for layout: Layout) {
        // Ticking something brings its plug-in up on the panel.
        if picked.count > (picks[layout.name]?.count ?? 0) { choose(layout.name) }
        picks[layout.name] = picked
        save()
        // Something to show now, or nothing left to.
        if phase == .connected, !shownPlugins.isEmpty {
            show()
        } else if phase == .showing, shownPlugins.isEmpty {
            stopWork()
            phase = .connected
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(layouts), forKey: layoutsKey)
        defaults.set(try? JSONEncoder().encode(picks), forKey: picksKey)
        defaults.set(try? JSONEncoder().encode(labels), forKey: labelsKey)
    }

    /// Takes a fresh reading of the channel's plug-ins, keeping what was
    /// picked, in its order, and the names given: in place where the name
    /// there is unchanged, else wherever that name went.
    private func adopt(_ found: [Layout], readings fresh: [String: [Int: Reading]]) {
        for layout in found {
            guard let old = layouts.first(where: { $0.name == layout.name }) else { continue }
            var moved: [Int: Int] = [:]
            var taken = Set<Int>()
            let wanted = (picks[layout.name] ?? []) + (labels[layout.name] ?? [:]).keys.sorted()
            for index in wanted where moved[index] == nil && index < old.controls.count {
                let name = old.controls[index]
                let stayed = index < layout.controls.count && layout.controls[index] == name && !taken.contains(index)
                if let target = stayed ? index : layout.controls.indices.first(where: {
                    layout.controls[$0] == name && !taken.contains($0)
                }) {
                    moved[index] = target
                    taken.insert(target)
                }
            }
            if let picked = picks[layout.name] { picks[layout.name] = picked.compactMap { moved[$0] } }
            if let named = labels[layout.name] {
                labels[layout.name] = Dictionary(uniqueKeysWithValues: named.compactMap { index, text in
                    moved[index].map { ($0, text) }
                })
            }
        }
        layouts = found
        readings = fresh
        save()
    }

    // MARK: - Receiving

    /// Whole messages Studio One needs from a packet list: the Mackie SysEx
    /// (display, handshake) and the knobs' LED rings. Meters, faders and
    /// time code — most of what Logic sends — are dropped here, off the main
    /// thread. SysEx split across packets is put back together.
    nonisolated private static func messages(in list: UnsafePointer<MIDIPacketList>,
                                             assembling assembly: inout [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        for packet in list.unsafeSequence() {
            let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(Int(packet.pointee.length))) }
            if !assembly.isEmpty || bytes.first == 0xF0 {
                assembly += bytes
                if assembly.last == 0xF7 {
                    if assembly.starts(with: [0xF0, 0x00, 0x00, 0x66]) { result.append(assembly) }
                    assembly = []
                } else if assembly.count > 4_096 {
                    assembly = []
                }
                continue
            }
            // Controllers 0x30–0x37 on channel 1 are the V-Pot rings; channel
            // pressure is a strip's meter: the strip, then its level.
            var index = 0
            while index < bytes.count {
                let status = bytes[index]
                if status == 0xB0, index + 2 < bytes.count, (0x30...0x37).contains(bytes[index + 1]) {
                    result.append(Array(bytes[index...(index + 2)]))
                }
                if status == 0xD0, index + 1 < bytes.count {
                    result.append([0xD0, bytes[index + 1]])
                }
                switch status {
                case 0xC0...0xDF, 0xF1, 0xF3: index += 2
                case 0x80...0xEF, 0xF2: index += 3
                default: index += 1
                }
            }
        }
        return result
    }

    private func receive(_ message: [UInt8], unit index: Int) {
        guard started else { return }
        let unit = units[index]
        if message.first == 0xD0, message.count >= 2 {
            if let (strip, level) = Self.meter(message[1], unit: index), strip < meterLevels.count {
                meterLevels[strip] = level
                meterUpdated[strip] = Date()
                if level > 1 { meterHeard[strip] = Date() }
            }
            return
        }
        if message.first == 0xB0 {
            unit.rings[Int(message[1]) - 0x30] = message[2]
            checkLocation()
            return
        }
        guard message.count >= 7, message[4] == unit.model else { return }
        let serial = Array("STUDIO\(index)".utf8)
        switch message[5] {
        case 0x00:   // Device query: this is a Mackie, here's a serial and a challenge.
            send([0xF0, 0x00, 0x00, 0x66, unit.model, 0x01] + serial + [0x01, 0x02, 0x03, 0x04, 0xF7], unit)
        case 0x02:   // Host connection reply: confirmed.
            send([0xF0, 0x00, 0x00, 0x66, unit.model, 0x03] + serial + [0xF7], unit)
        case 0x13:   // Version request.
            send([0xF0, 0x00, 0x00, 0x66, unit.model, 0x14] + Array("V1.02".utf8) + [0xF7], unit)
        case 0x0F:   // Going offline.
            logicQuit()
        case 0x12 where message.count >= 8:   // Display: offset, characters, F7.
            display(message, unit: unit)
        default:
            break
        }
    }

    private func display(_ message: [UInt8], unit: Unit) {
        let offset = Int(message[6])
        let characters = Array(message[7..<(message.count - 1)])
        updates += 1
        unit.online = true
        if phase == .waitingForLogic {
            phase = .connected
            log("Logic connected")
            scheduleStart()
        }
        for (index, character) in characters.enumerated() {
            let position = offset + index
            if position < 56 { unit.shown[position] = character }
            else if position < 112 { unit.values[position - 56] = character }
        }
        // Logic writes notices over the main unit's names for a few seconds,
        // sometimes in pieces, and puts the names back after: read the notices
        // from the line as shown, and keep them out of the names. A new insert
        // or page has new names under its notice, not yet sent: blank the old.
        var hidden = IndexSet()
        if unit === units[0] {
            let before = (insert?.slot, page?.current)
            let written = offset..<max(offset, min(offset + characters.count, 56))
            let found = Self.notices(in: Self.text(unit.shown))
            if let notice = found.insert {
                insert = (notice.slot, notice.name)
                if notice.range.overlaps(written) { insertNotices += 1 }
            }
            if let notice = found.page {
                page = (notice.current, notice.count)
                if notice.range.overlaps(written) { pageNotices += 1 }
            }
            covered = found.covered
            hidden = found.covered
            if before.0 != insert?.slot || before.1 != page?.current {
                for position in hidden { unit.names[position] = 32 }
            }
        }
        for (index, character) in characters.enumerated() where offset + index < 56 {
            if !hidden.contains(offset + index) { unit.names[offset + index] = character }
        }
        // A frame drawn from a column or three in, whatever went unchanged
        // before it, is a whole line all the same.
        if unit === units[0], offset < 56 {
            watchForAlert(wholeLine: offset <= 3 && offset + characters.count >= 54)
        }
        checkLocation()
    }

    // MARK: - Logic's alerts

    /// The Mackie Control's last whole top line, to tell one that scrolls.
    private var lastWholeLine: String?
    /// The alert's text, put back together as it scrolls past.
    private var alertText = ""
    /// Still gathering its text: false once it starts over from the top.
    private var alertGrowing = true
    private var alertStep = Date.distantPast
    private var alertEnding: Task<Void, Never>?

    /// Logic puts an open alert on a Mackie Control: its text along the top
    /// line — scrolling a character at a time after three seconds when it's
    /// longer than the line — and its buttons at the right of the bottom
    /// one ("Save   Don'tS Cancel"). Controls' names never run across the
    /// blank between strips, nor scroll. Logic redraws the plug-in when the
    /// alert closes.
    private func watchForAlert(wholeLine: Bool) {
        let line = Self.text(units[0].shown)
        defer { if wholeLine { lastWholeLine = line } }
        let before = lastWholeLine
        let shift = wholeLine ? before.flatMap { Self.scroll(from: $0, to: line) } : nil
        // Scrolling, or a frame of an alert: its first, or its start again
        // once it has scrolled to the end.
        guard shift != nil || looksLikeAlert(line) else {
            if logicAlert != nil { endAlertSoon() }
            return
        }
        if logicAlert == nil {
            alertText = ""
            alertGrowing = true
            log("Logic has an alert open")
            logDisplay("alert")
        }
        if wholeLine, alertGrowing { gather(String(Array(line)[0..<Self.scrollWidth])) }
        alertStep = .now
        alertEnding?.cancel()
        let text = alertText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, logicAlert != text { logicAlert = text }
    }

    /// Lays a frame over the alert's text where its start is found, so a step
    /// missed, or a right-hand end that lagged, comes right with the next.
    /// The text is whole when the frame is its start again.
    private func gather(_ frame: String) {
        let key = String(frame.prefix(24))
        if alertText.isEmpty {
            alertText = frame
        } else if alertText.count > Self.scrollWidth, alertText.hasPrefix(key) {
            alertGrowing = false
        } else if let found = alertText.range(of: key, options: .backwards) {
            alertText = String((alertText[..<found.lowerBound] + frame).prefix(240))
        }
    }

    /// Something else drawn: the alert is closing — unless it scrolls on.
    private func endAlertSoon() {
        alertEnding?.cancel()
        alertEnding = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, Date().timeIntervalSince(alertStep) > 0.7 else { return }
            endAlert()
        }
    }

    /// An alert's first frame: words across the blanks between strips, which
    /// no control's name does, and buttons only at the right of the bottom.
    private func looksLikeAlert(_ line: String) -> Bool {
        let top = Array(line)
        let across = stride(from: 6, to: Self.scrollWidth, by: 7).filter { top[$0] != " " }.count
        guard across >= 4, Self.notices(in: line).covered.isEmpty else { return false }
        let values = Self.text(units[0].values)
        let left = (0..<4).allSatisfy { Self.cell(values, $0).isEmpty }
        let right = (4..<8).contains { !Self.cell(values, $0).isEmpty }
        return left && right
    }

    private func endAlert() {
        guard logicAlert != nil else { return }
        logicAlert = nil
        alertText = ""
        log("Logic's alert closed")
        // Logic redraws what was there; what Studio One stepped to holds.
        mismatchSince = nil
        checkLocation()
    }

    /// The columns an alert scrolls across; the last one stays blank.
    private static let scrollWidth = 55

    /// How far `after` has scrolled from `before`: one to three characters.
    /// Logic redraws only what changed, so the line's last few characters can
    /// lag a step; the first 48 settle it.
    private static func scroll(from before: String, to after: String) -> Int? {
        let old = Array(before), new = Array(after)
        let span = 48
        guard old.count == 56, new.count == 56 else { return nil }
        for shift in 1...3 where Array(old[shift..<(shift + span)]) == Array(new[..<span]) {
            return new[..<span].filter(\.isLetter).count >= 20 ? shift : nil
        }
        return nil
    }

    /// Logic's passing notices on a line — the insert the cursor is on, the
    /// page — and the characters they cover, with those of the ones Studio One
    /// never asks for (the chooser, a strip's Select).
    private struct Notices {
        var insert: (range: Range<Int>, slot: Int, name: String)?
        var page: (range: Range<Int>, current: Int, count: Int)?
        var covered = IndexSet()
    }

    private static func notices(in line: String) -> Notices {
        var found = Notices()
        if let (range, groups) = match(insertNotice, in: line), let slot = Int(groups[0]) {
            // "MetaTune (s/s)" — the channel format isn't part of the name; a
            // long name runs off the end of the line.
            let name = groups[1].replacingOccurrences(of: #"\s*\([^)]*\)?\s*$"#, with: "", options: .regularExpression)
            found.insert = (range, slot, name.trimmingCharacters(in: .whitespaces))
            found.covered.insert(integersIn: range)
        }
        if let (range, groups) = match(pageNotice, in: line), let current = Int(groups[0]), let count = Int(groups[1]) {
            found.page = (range, current, count)
            found.covered.insert(integersIn: range)
        }
        if let (range, _) = match(chooserNotice, in: line) {
            found.covered.insert(integersIn: range)
        }
        for strip in 0..<8 where cell(line, strip) == "Select" {
            found.covered.insert(integersIn: (strip * 7)..<(strip * 7 + 7))
        }
        return found
    }

    private static let insertNotice = try! NSRegularExpression(pattern: #"Insert (\d+) "([^"]*)"?"#)
    private static let pageNotice = try! NSRegularExpression(pattern: #"Page (\d+)/(\d+)"#)
    private static let chooserNotice = try! NSRegularExpression(pattern: #"Insert \d+ (Instantiate|Plug-in)"#)
    private static let insertLabel = try! NSRegularExpression(pattern: #"^Ins?(\d+)"#)

    /// The match's character range and its groups. The line is ASCII, so
    /// characters and UTF-16 offsets agree.
    private static func match(_ pattern: NSRegularExpression, in text: String) -> (Range<Int>, [String])? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        return (match.range.location..<(match.range.location + match.range.length), groups)
    }

    private static func text(_ line: [UInt8]) -> String {
        String(decoding: line.map { (32...126).contains($0) ? $0 : 32 }, as: UTF8.self)
    }

    private static func cell(_ line: [UInt8], _ strip: Int) -> String {
        cell(text(line), strip)
    }

    private static func cell(_ line: String, _ strip: Int) -> String {
        let characters = Array(line)
        guard characters.count >= strip * 7 + 7 else { return "" }
        return String(characters[(strip * 7)..<(strip * 7 + 7)]).trimmingCharacters(in: .whitespaces)
    }

    /// The ring's lit position, 1–11 of eleven LEDs; 0 is all off.
    private static func position(ofRing value: UInt8) -> Double? {
        let led = Int(value & 0x0F)
        return (1...11).contains(led) ? Double(led - 1) / 10 : nil
    }

    // MARK: - Where the display is

    /// Checks what's shown against the page Studio One stepped to, and keeps
    /// its values when they agree.
    private func checkLocation() {
        guard let here = location, let layout = layouts.first(where: { $0.slot == here.slot }) else { return }
        switch agreement(layout, page: here.page) {
        case true?:
            mismatchSince = nil
            capture(layout, page: here.page)
        case false?:
            if mismatchSince == nil { mismatchSince = .now }
        case nil:
            break
        }
    }

    /// Whether the names shown are the ones read for that page: no name
    /// disagrees, and at least one agrees. A notice and the blanks Logic
    /// pads it with prove nothing either way.
    private func agreement(_ layout: Layout, page: Int) -> Bool? {
        var agreed = false
        for (unitIndex, unit) in units.prefix(layout.pageSize / 8).enumerated() {
            for strip in 0..<8 {
                if unitIndex == 0, covered.intersects(integersIn: (strip * 7)..<(strip * 7 + 7)) { continue }
                let index = layout.start(of: page) + unitIndex * 8 + strip
                let shown = Self.cell(unit.shown, strip)
                guard index < layout.controls.count, !layout.controls[index].isEmpty, !shown.isEmpty else { continue }
                if shown != layout.controls[index] { return false }
                agreed = true
            }
        }
        return agreed ? true : nil
    }

    private func capture(_ layout: Layout, page: Int) {
        var latest = readings[layout.name] ?? [:]
        let picked = Set(picks[layout.name] ?? [])
        var changed = false
        for (unitIndex, unit) in units.prefix(layout.pageSize / 8).enumerated() {
            for strip in 0..<8 {
                let index = layout.start(of: page) + unitIndex * 8 + strip
                guard index < layout.controls.count, !layout.controls[index].isEmpty else { continue }
                let reading = Reading(value: Self.cell(unit.values, strip),
                                      position: Self.position(ofRing: unit.rings[strip]))
                guard latest[index] != reading else { continue }
                latest[index] = reading
                changed = true
                if picked.contains(index) { lastChange = .now }
            }
        }
        if changed { readings[layout.name] = latest }
    }

    /// The plug-in on show, while what's shown still agrees.
    private var verifiedSlot: Int? {
        mismatchSince == nil ? location?.slot : nil
    }

    // MARK: - Reading the plug-ins

    private func scheduleStart() {
        autoStart?.cancel()
        autoStart = Task {
            // Logic sends the whole surface state as it connects; let it land.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, phase == .connected else { return }
            if layouts.isEmpty { read() } else if !shownPlugins.isEmpty { show() }
        }
    }

    /// Reads the plug-ins on the channel Logic has locked (or selected):
    /// every control's name, page by page, to pick from.
    func read() {
        guard isConnected else { return }
        run { await self.runRead() }
    }

    /// Shows the picked controls, after a failure or a read.
    func retry() {
        layouts.isEmpty ? read() : show()
    }

    private func show() {
        guard isConnected, !shownPlugins.isEmpty else { return }
        run { await self.runShow() }
    }

    /// Starts `job` once the one before has stopped pressing buttons.
    private func run(_ job: @escaping @MainActor () async -> Void) {
        let previous = work
        previous?.cancel()
        autoStart?.cancel()
        work = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await job()
        }
    }

    /// Into Plug-In's list of the channel's inserts, into the first plug-in,
    /// then down through the inserts — each named in full as the cursor
    /// arrives — reading every page of each.
    private func runRead() async {
        phase = .reading("Opening the channel's plug-ins…")
        location = nil
        guard await openInsertList() else {
            return fail("Logic didn't list the channel's plug-ins. Lock \(role.channel) in Logic, then read again.")
        }
        let listed = insertList()
        guard let first = listed.first, let last = listed.last else {
            return fail("The channel Logic has locked has no plug-ins. Lock \(role.channel), then read again.")
        }
        // Logic names an insert only as the cursor arrives on it, so step off
        // the first and back to hear its name.
        press(knob: first.strip, unit: first.unit)
        await settle()
        press(.down)
        await settle()
        press(.up)
        await settle()

        var found: [Layout] = []
        var values: [String: [Int: Reading]] = [:]
        var visited: Set<Int> = []
        while let current = insert, visited.insert(current.slot).inserted, !Task.isCancelled {
            if let entry = listed.first(where: { $0.slot == current.slot }) {
                // Two of one plug-in are told apart by number.
                let base = current.name.isEmpty ? entry.shortName : current.name
                var name = base
                var copy = 2
                while found.contains(where: { $0.name == name }) {
                    name = "\(base) \(copy)"
                    copy += 1
                }
                guard let controls = await readControls(of: name, number: found.count + 1, of: listed.count) else {
                    if Task.isCancelled { return }
                    return fail("Logic stopped answering while reading \(name). Read again.")
                }
                let layout = Layout(slot: current.slot, name: name, shortName: entry.shortName,
                                    pageSize: onlineUnits * 8, controls: controls.names)
                found.append(layout)
                values[name] = controls.readings
            }
            guard current.slot < last.slot else { break }
            let before = insertNotices
            press(.down)
            await settle()
            guard insertNotices != before else { break }
        }
        guard !Task.isCancelled else { return }
        guard !found.isEmpty else {
            return fail("Logic didn't name the channel's plug-ins. Read again.")
        }
        adopt(found, readings: values)
        if role == .check, !pickTuner() {
            return fail("No MetaTune on the channel Logic has locked for the key check. Lock \(role.channel), then read again.")
        }
        // Still on the last one read, on its last page.
        if let last = found.last, insert?.slot == last.slot {
            location = (last.slot, last.pageCount)
            checkLocation()
        }
        log("read " + found.map { "\($0.name) (insert \($0.slot), \($0.controls.count) controls)" }
            .joined(separator: ", "))
        if found.count < listed.count {
            log("Logic listed \(listed.count) plug-ins; \(found.count) read")
        }
        if shownPlugins.isEmpty {
            phase = .connected
        } else {
            await runShow()
        }
    }

    /// The key check's picks: MetaTune's Bypass and its twelve note switches.
    private func pickTuner() -> Bool {
        guard let tuner = layouts.first(where: { $0.name.localizedCaseInsensitiveContains("MetaTune") }) else {
            return false
        }
        picks = [tuner.name: tuner.controls.indices.filter {
            tuner.controls[$0] == "Bypass" || KeyCheck.pitchClass(of: tuner.controls[$0]) != nil
        }]
        choose(tuner.name)
        save()
        return true
    }

    /// Every control's name on the plug-in being shown, page by page, with
    /// what each is set to.
    private func readControls(of name: String, number: Int, of total: Int) async
        -> (names: [String], readings: [Int: Reading])? {
        // To the first page: Left goes back one and names where it lands.
        var landed: (current: Int, count: Int)?
        for _ in 0..<40 where !Task.isCancelled {
            guard let page = await pageAfter(.left) else { return nil }
            landed = page
            if page.current == 1 { break }
        }
        guard let count = landed?.count, landed?.current == 1 else { return nil }

        let lead = total > 1 ? "Reading \(name) (\(number) of \(total))" : "Reading \(name)"
        var pages: [(names: [String], readings: [Reading])] = []
        for pageNumber in 1...count {
            guard !Task.isCancelled else { return nil }
            phase = .reading(count > 1 ? "\(lead), page \(pageNumber) of \(count)…" : "\(lead)…")
            if pageNumber > 1 {
                guard let page = await pageAfter(.right), page.current == pageNumber else { return nil }
            }
            // The page's notice hides some names for two or three seconds.
            guard await noticeCleared() else { return nil }
            let strips = units.prefix(onlineUnits).flatMap { unit in (0..<8).map { (unit, $0) } }
            pages.append((strips.map { Self.cell($0.0.names, $0.1) },
                          strips.map { Reading(value: Self.cell($0.0.values, $0.1),
                                               position: Self.position(ofRing: $0.0.rings[$0.1])) }))
        }
        // The last page, filled from the end, repeats the end of the one
        // before: the longest run of the same names with the same values.
        var names = pages.dropLast().flatMap(\.names)
        var values = pages.dropLast().flatMap(\.readings)
        let last = pages[pages.count - 1]
        let repeated = stride(from: min(last.names.count - 1, names.count), through: 1, by: -1).first { length in
            Array(last.names.prefix(length)) == Array(names.suffix(length))
                && last.readings.prefix(length).map(\.value) == values.suffix(length).map(\.value)
        } ?? 0
        names += last.names.dropFirst(repeated)
        values += last.readings.dropFirst(repeated)
        // A short last page's spare strips read "-".
        while let final = names.last, final.isEmpty || final == "-" {
            names.removeLast()
            values.removeLast()
        }
        names = names.map { $0 == "-" ? "" : $0 }
        let readings = Dictionary(uniqueKeysWithValues: names.indices.filter { !names[$0].isEmpty }.map { ($0, values[$0]) })
        return (names, readings)
    }

    /// The units Logic is drawing on: the Mackie Control, and the extender
    /// unless Logic left it out.
    private var onlineUnits: Int {
        max(1, units.prefix { $0.online }.count)
    }

    /// Waits for Logic to put the names back over its notice — all of it:
    /// a notice can go in pieces, leaving a stray `"` or "Page".
    private func noticeCleared() async -> Bool {
        for _ in 0..<60 where !Task.isCancelled {
            let line = Self.text(units[0].shown)
            if Self.notices(in: line).covered.isEmpty, !line.contains("\""), !line.contains("Page ") {
                // The rest of the redraw.
                try? await Task.sleep(for: .milliseconds(150))
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: - Showing the picks

    /// Keeps Logic on the panel's plug-in, on the pages with something
    /// picked, taking them in turn: 0.6 s on each, or 2 s while something on
    /// it is moving.
    private func runShow() async {
        phase = .showing
        log("showing " + shownPlugins.map(\.name).joined(separator: ", "))
        var failures = 0
        var arrived = Date.distantPast
        while !Task.isCancelled {
            guard logicAlert == nil,
                  role == .check || UserDefaults.standard.object(forKey: Self.panelOpenKey) as? Bool ?? true,
                  let plugin = shownPlugin else {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            if let since = mismatchSince, Date().timeIntervalSince(since) > 1.5 {
                log("Logic moved off \(plugin.name)")
                logDisplay("then")
                location = nil
                mismatchSince = nil
            }
            var stepped = true
            if location?.slot != plugin.slot {
                stepped = await open(plugin)
            } else if let here = location {
                let pages = plugin.pages(showing: picks[plugin.name] ?? [])
                let moving = lastChange > arrived.addingTimeInterval(0.2)
                let due = !pages.contains(here.page) || Date().timeIntervalSince(arrived) > (moving ? 2 : 0.6)
                if due, let next = pages.first(where: { $0 > here.page }) ?? pages.first, next != here.page {
                    stepped = await turn(to: next)
                } else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
            }
            if Task.isCancelled { return }
            if stepped {
                failures = 0
                arrived = .now
            } else {
                // Three tries, a pause between: no stream of presses into a
                // Logic that's showing something else.
                failures += 1
                if failures >= 3 {
                    return fail("Logic isn't showing \(plugin.name). If it moved, or the channel changed, read the plug-ins again in Settings › Plug-ins.")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Brings up `plugin`: by the cursor from a plug-in beside it, else from
    /// Plug-In's list of inserts; then Left, to learn the page.
    private func open(_ plugin: Layout) async -> Bool {
        let from = verifiedSlot
        location = nil
        var slot = plugin.slot
        if let from {
            if from != slot {
                let before = insertNotices
                for _ in 0..<abs(slot - from) {
                    press(slot > from ? .down : .up)
                    await settle()
                }
                guard insertNotices != before, insert?.slot == slot else { return false }
            }
        } else {
            guard await openInsertList() else { return false }
            let listed = insertList()
            guard let entry = listed.first(where: { $0.slot == slot && Self.same($0.shortName, plugin.shortName) })
                    ?? listed.first(where: { Self.same($0.shortName, plugin.shortName) }) else { return false }
            if entry.slot != slot, let index = layouts.firstIndex(of: plugin) {
                // Moved to another insert since it was read.
                slot = entry.slot
                layouts[index].slot = slot
                save()
            }
            press(knob: entry.strip, unit: entry.unit)
            await settle()
        }
        guard let page = await pageAfter(.left) else { return false }
        location = (slot, page.current)
        for _ in 0..<6 where !Task.isCancelled {
            if agreement(plugin, page: page.current) == true {
                mismatchSince = nil
                checkLocation()
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        location = nil
        mismatchSince = nil
        return false
    }

    /// Left or Right to `target`, a page at a time, each named by Logic.
    private func turn(to target: Int) async -> Bool {
        guard let here = location else { return false }
        location = nil
        var current = here.page
        while current != target {
            guard !Task.isCancelled,
                  let page = await pageAfter(target > current ? .right : .left),
                  page.current != current else { return false }
            current = page.current
        }
        location = (here.slot, current)
        mismatchSince = nil
        checkLocation()
        return true
    }

    /// Presses Left or Right and waits for Logic to name the page. Logic
    /// draws only what changed, so a notice already showing that page draws
    /// nothing new — and is the answer.
    private func pageAfter(_ button: Button) async -> (current: Int, count: Int)? {
        let before = pageNotices
        press(button)
        for _ in 0..<20 where pageNotices == before && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(60))
        }
        if pageNotices == before {
            return Self.notices(in: Self.text(units[0].shown)).page.map { ($0.current, $0.count) }
        }
        // The rings follow the notice.
        try? await Task.sleep(for: .milliseconds(120))
        return page
    }

    private func fail(_ reason: String) {
        // Stopped, not failed: whatever stopped it has said what's next.
        guard !Task.isCancelled else { return }
        phase = .failed(reason)
        location = nil
        log(reason)
        logDisplay("then")
    }

    /// What the surface shows, for the log: finding goes by it.
    private func logDisplay(_ when: String) {
        for (index, unit) in units.enumerated() {
            Diagnostics.log("  \(role.logName) \(index + 1), \(when): |\(Self.text(unit.shown))| |\(Self.text(unit.values))|")
        }
    }

    private func log(_ text: String) {
        Diagnostics.log("\(role.logName): " + text)
    }

    // MARK: - Plug-In's list of inserts

    /// Plug-In, until Logic lists the channel's inserts: "Ins1Pl", "Ins2Pl" … .
    private func openInsertList() async -> Bool {
        for _ in 0..<3 where !showsInsertList {
            press(.plugIn)
            await settle()
        }
        return showsInsertList
    }

    private var showsInsertList: Bool {
        Self.insertSlot(Self.cell(units[0].names, 0)) == 1
    }

    /// The listed inserts that hold a plug-in. The extender can repeat the
    /// Mackie Control's list; the Mackie Control's is the one to press.
    private func insertList() -> [(slot: Int, shortName: String, unit: Int, strip: Int)] {
        var listed: [(slot: Int, shortName: String, unit: Int, strip: Int)] = []
        for (unitIndex, unit) in units.enumerated() {
            for strip in 0..<8 {
                guard let slot = Self.insertSlot(Self.cell(unit.names, strip)),
                      !listed.contains(where: { $0.slot == slot }) else { continue }
                let name = Self.cell(unit.values, strip)
                if Self.holdsPlugin(name) { listed.append((slot, name, unitIndex, strip)) }
            }
        }
        return listed.sorted { $0.slot < $1.slot }
    }

    private static func insertSlot(_ label: String) -> Int? {
        match(insertLabel, in: label).flatMap { Int($0.1[0]) }
    }

    /// An insert that holds a plug-in: not "--", bypassed or not.
    private static func holdsPlugin(_ name: String) -> Bool {
        let bare = name.replacingOccurrences(of: "*", with: "")
        return !bare.isEmpty && bare.contains(where: \.isLetter)
    }

    /// Two short names for one plug-in, bypassed ("*") or not.
    private static func same(_ a: String, _ b: String) -> Bool {
        let bare = { (name: String) in name.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
        return bare(a).caseInsensitiveCompare(bare(b)) == .orderedSame
    }

    /// Waits for Logic to redraw after a press, then for the redraw to finish.
    private func settle() async {
        let before = updates
        for _ in 0..<12 where updates == before {
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - Sending

    private func press(_ button: Button) {
        press(note: button.rawValue, unit: 0)
    }

    /// A knob's push: V-Select 1–8 on the Mackie Control or its extender.
    private func press(knob strip: Int, unit: Int) {
        press(note: 0x20 + UInt8(strip), unit: unit)
    }

    private func press(note: UInt8, unit index: Int) {
        // A job stopped mid-way presses nothing more; nor does anything while
        // Logic has an alert up, where the surface's buttons answer the alert.
        guard !Task.isCancelled, logicAlert == nil else { return }
        let unit = units[index]
        send([0x90, note, 0x7F], unit)
        let source = unit.source
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            MIDIBridge.transmit([0x90, note, 0x00], from: source)
        }
    }

    private func send(_ bytes: [UInt8], _ unit: Unit) {
        MIDIBridge.transmit(bytes, from: unit.source)
    }
}
