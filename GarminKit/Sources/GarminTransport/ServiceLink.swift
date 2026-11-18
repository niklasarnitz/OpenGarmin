import Foundation

/// A link that can also open a file transfer service on the same watch connection. The new sync protocol lists files
/// over the GFDI channel, but each file's bytes come over one of these services.
public protocol GarminServiceLink: GarminLink {
    /// Opens a reliable service the watch can send a file on, on a service handle that is not in use. The channel is
    /// returned once the watch has accepted the registration.
    func openFileTransfer() async throws -> any GarminServiceChannel
}

/// A link that can open realtime services: the watch streams health readings on them, as Gadgetbridge's realtime
/// services do. They are unreliable, so readings arrive unframed and nothing is acknowledged.
public protocol GarminRealtimeLink: GarminLink {
    /// Opens a realtime service by its code, or returns the channel already open for it on this connection. The
    /// channel is returned once the watch has accepted the registration. Sending `[1]` on it starts the stream and
    /// `[0]` stops it.
    func openRealtimeService(_ service: UInt16) async throws -> any GarminServiceChannel
}

/// One file transfer service the watch opened. `incoming` finishes when the watch closes the service or the link
/// drops, so a finished stream does not by itself mean the transfer was complete.
public protocol GarminServiceChannel: AnyObject, Sendable {
    var incoming: AsyncStream<Data> { get }
    /// Sends one payload. The link splits it into as many packets as it needs.
    func send(_ payload: Data) async throws
}
