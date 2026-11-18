import Testing
import Foundation
import GarminCore
@testable import GarminTransport

private func bytes(_ range: Range<Int>) -> Data {
    Data(range.map { UInt8($0) })
}

@Test func packetHeaderPacksHandleAndSequenceBits() {
    // reqNum 5 = 0b000101: its high bits sit in byte 0, its low bits in the top of byte 1.
    let packet = MLRPacket(handle: 1, reqNum: 5, seqNum: 9, payload: Data([0xAA]))
    #expect(packet.encoded() == Data([0x91, 0x49, 0xAA]))
}

@Test func packetRoundTripsAndRejectsUnflaggedData() {
    let packet = MLRPacket(handle: 7, reqNum: 63, seqNum: 63, payload: Data([1, 2]))
    #expect(MLRPacket(decoding: packet.encoded()) == packet)
    #expect(MLRPacket(decoding: Data([0x10, 0x00, 0x01])) == nil)
    #expect(MLRPacket(decoding: Data([0x80])) == nil)
}

@Test func chunkingSplitsIntoFullPiecesAndARemainder() {
    #expect(chunked(bytes(0..<10), size: 4) == [bytes(0..<4), bytes(4..<8), bytes(8..<10)])
    #expect(chunked(Data(), size: 4) == [])
}

/// Feeds `packet` to `receiver` and every acknowledgement it would send, including a fired ack timer, to `sender`.
private func deliver(_ packet: Data, from sender: inout MLRChannel, to receiver: inout MLRChannel) -> [Data] {
    var received = receiver.receive(packet)
    if received.ack == .delayed { received.outgoing.append(receiver.ackTimedOut()) }
    for ack in received.outgoing { _ = sender.receive(ack) }
    return received.messages
}

@Test func receiverDelaysAcksUntilFivePacketsOrTheTimer() {
    var watch = MLRChannel(handle: 1, maxWrite: 20)
    // Packets 0 to 3 are delivered without an acknowledgement; the caller starts the 20 ms timer each time.
    for seq in 0..<4 {
        let received = watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: UInt8(seq), payload: Data([UInt8(seq)])).encoded())
        #expect(received.messages == [Data([UInt8(seq)])])
        #expect(received.outgoing.isEmpty)
        #expect(received.ack == .delayed)
    }
    // The fifth unacknowledged packet acknowledges at once: reqNum 5 = 0x90 | 5 >> 2, then (5 & 3) << 6.
    let fifth = watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 4, payload: Data([4])).encoded())
    #expect(fifth.outgoing == [Data([0x91, 0x40])])
    #expect(fifth.ack == .sent)
    // One more packet: below the threshold again, and the timer acknowledges it with reqNum 6.
    #expect(watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 5, payload: Data([5])).encoded()).ack == .delayed)
    #expect(watch.ackTimedOut() == Data([0x91, 0x80]))
}

@Test func receiverReacksGapsAtOnceAndIgnoresAcksAndOtherHandles() {
    var watch = MLRChannel(handle: 1, maxWrite: 20)
    _ = watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 0, payload: Data([0xAA])).encoded())

    // Sequence 5 while 1 is expected: dropped, and the expected number is acknowledged again immediately.
    let gap = watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 5, payload: Data([0xBB])).encoded())
    #expect(gap.messages.isEmpty)
    #expect(gap.outgoing == [Data([0x90, 0x40])])
    #expect(gap.ack == .sent)

    // An acknowledgement-only packet is not acknowledged.
    #expect(watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 0).encoded()).ack == .none)

    let otherHandle = MLRPacket(handle: 2, reqNum: 0, seqNum: 1, payload: Data([0xCC])).encoded()
    #expect(watch.receive(otherHandle) == MLRChannel.Received())
}

@Test func sendWindowHoldsThirtyTwoPacketsUntilAcknowledged() {
    var host = MLRChannel(handle: 1, maxWrite: 3) // one payload byte per packet
    let first = host.send(Data(repeating: 0x41, count: 50))
    #expect(first.count == 32)
    #expect(host.unacknowledgedCount == 32)

    // The watch acknowledges packets 0 to 9 with reqNum 10. Ten slots open, so ten more go out, numbered 32 to 41.
    let ack = MLRPacket(handle: 1, reqNum: 10, seqNum: 0).encoded()
    let received = host.receive(ack)
    #expect(received.acknowledgedNew)
    #expect(received.outgoing.map { $0[1] & 0x3F } == (32...41).map { UInt8($0) })
    #expect(host.unacknowledgedCount == 32)
}

@Test func retransmissionBacksOffHalvesTheWindowAndRecoversOnAck() {
    var host = MLRChannel(handle: 1, maxWrite: 3)
    _ = host.send(Data(repeating: 0x41, count: 40))
    #expect(host.unacknowledgedCount == 32)

    #expect(host.retransmissionTimedOut().count == 32)
    #expect(host.retransmissionTimeout == .seconds(2))
    #expect(host.window == 16)
    _ = host.retransmissionTimedOut()
    #expect(host.retransmissionTimeout == .seconds(4))
    #expect(host.window == 8)
    for _ in 0..<5 { _ = host.retransmissionTimedOut() }
    #expect(host.retransmissionTimeout == .seconds(20))
    #expect(host.window == 1)

    // Acknowledging 0 to 29 resets the timeout and grows the window by 30, capped at 32. Only two packets stay in
    // flight, so the eight queued ones fill the window up to ten, not to 32.
    let received = host.receive(MLRPacket(handle: 1, reqNum: 30, seqNum: 0).encoded())
    #expect(host.retransmissionTimeout == .seconds(1))
    #expect(host.window == 31)
    #expect(received.outgoing.count == 8)
    #expect(host.unacknowledgedCount == 10)
}

@Test func retransmissionRepeatsTheOriginalReqNum() {
    var host = MLRChannel(handle: 1, maxWrite: 3)
    let original = host.send(Data([0x41]))
    // The host then receives two packets from the watch, so its own reqNum moves to 2.
    _ = host.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 0, payload: Data([1])).encoded())
    _ = host.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 1, payload: Data([2])).encoded())
    #expect(host.retransmissionTimedOut() == original)
}

@Test func sequenceNumbersWrapAfterSixtyFourPackets() {
    var host = MLRChannel(handle: 1, maxWrite: 3)
    var watch = MLRChannel(handle: 1, maxWrite: 3)
    for i in 0..<70 {
        let packets = host.send(Data([UInt8(i)]))
        #expect(packets.count == 1)
        #expect(packets[0][1] & 0x3F == UInt8(i % 64))
        #expect(deliver(packets[0], from: &host, to: &watch) == [Data([UInt8(i)])])
    }
    #expect(host.unacknowledgedCount == 0)
}

@Test func lostPacketIsRecoveredByRetransmission() {
    let payload = bytes(0..<100)
    var host = MLRChannel(handle: 1, maxWrite: 12) // ten payload bytes per packet
    var watch = MLRChannel(handle: 1, maxWrite: 12)
    let packets = host.send(Cobs.encode(payload))
    #expect(packets.count > 3)

    var delivered: [Data] = []
    // Packet 2 is lost on the way to the watch; the watch re-acks 2 for every packet after it.
    for (index, packet) in packets.enumerated() where index != 2 {
        delivered += deliver(packet, from: &host, to: &watch)
    }
    #expect(host.unacknowledgedCount == packets.count - 2)

    for packet in host.retransmissionTimedOut() {
        delivered += deliver(packet, from: &host, to: &watch)
    }
    #expect(host.unacknowledgedCount == 0)

    var decoder = CobsDecoder()
    #expect(decoder.feed(delivered.reduce(Data(), +)) == [payload])
}
