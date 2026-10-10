import CoreMIDI
import Foundation

/// The deck's own MIDI port, for when Studio One isn't running.
///
/// Logic ties a controller assignment to the port the message came from, so
/// this claims the same name *and* the same unique identity Studio One's port
/// uses. Learn a control once and it answers whichever of the two sent it.
///
/// Only one of them can hold that identity at a time, so this port is opened
/// only while Studio One is away and closed the moment it comes back —
/// otherwise Studio One would find its identity taken on launch, be handed a
/// random one instead, and every assignment already learned would go deaf.
final class MIDIOut {

    /// The same identity and name Studio One gives its port.
    private static let identity: Int32 = 0x53504F4B
    private static let portName = "Studio One"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private(set) var isOpen = false

    /// True if the port is ours to use. Fails while Studio One holds it.
    @discardableResult
    func open() -> Bool {
        guard !isOpen else { return true }
        guard MIDIClientCreate("Studio One Deck" as CFString, nil, nil, &client) == noErr,
              MIDISourceCreate(client, Self.portName as CFString, &source) == noErr else {
            return false
        }
        // Taken means Studio One is running and owns it; then this port would
        // be a second device Logic has never been taught, so it is no use.
        guard MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, Self.identity) == noErr else {
            MIDIEndpointDispose(source)
            MIDIClientDispose(client)
            source = MIDIEndpointRef()
            client = MIDIClientRef()
            return false
        }
        MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, Self.portName as CFString)
        MIDIObjectSetStringProperty(source, kMIDIPropertyModel, Self.portName as CFString)
        isOpen = true
        return true
    }

    func close() {
        guard isOpen else { return }
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
        source = MIDIEndpointRef()
        client = MIDIClientRef()
        isOpen = false
    }

    /// `channel` is 1–16 as people count them.
    func send(cc: Int, value: Int, channel: Int) {
        guard isOpen else { return }
        var bytes: [UInt8] = [0xB0 | UInt8((max(1, min(16, channel)) - 1) & 0x0F),
                              UInt8(max(0, min(127, cc))),
                              UInt8(max(0, min(127, value)))]
        var list = MIDIPacketList()
        withUnsafeMutablePointer(to: &list) { pointer in
            var packet = MIDIPacketListInit(pointer)
            packet = MIDIPacketListAdd(pointer, MemoryLayout<MIDIPacketList>.size,
                                       packet, 0, bytes.count, &bytes)
            _ = MIDIReceived(source, pointer)
        }
    }

    // MARK: - Step encoding

    /// The same two conventions Studio One offers, so a control learned in
    /// Logic behaves identically whoever sent the message.
    static func relativeValue(ticks: Int, step: String) -> Int {
        let size = min(63, max(1, abs(ticks)))
        if ticks >= 0 { return size }
        return step == "twosComplement" ? 128 - size : 64 + size
    }
}
