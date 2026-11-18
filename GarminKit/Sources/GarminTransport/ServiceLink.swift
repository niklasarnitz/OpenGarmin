import Foundation

/// A link that can also open a file transfer service on the same watch connection. The new sync protocol lists files
/// over the GFDI channel, but each file's bytes come over one of these services.
public protocol GarminServiceLink: GarminLink {
    /// Opens a reliable service the watch can send a file on, on a service handle that is not in use. The channel is
    /// returned once the watch has accepted the registration.
    func openFileTransfer() async throws -> any GarminServiceChannel
}

/// One file transfer service the watch opened. `incoming` finishes when the watch closes the service or the link
/// drops, so a finished stream does not by itself mean the transfer was complete.
public protocol GarminServiceChannel: AnyObject, Sendable {
    var incoming: AsyncStream<Data> { get }
    /// Sends one payload. The link splits it into as many packets as it needs.
    func send(_ payload: Data) async throws
}
