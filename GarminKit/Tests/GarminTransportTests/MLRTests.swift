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

@Test func receiverDeliversInOrderReacksGapsAndIgnoresOtherHandles() {
    var watch = MLRChannel(handle: 1, maxWrite: 20)

    let first = watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 0, payload: Data([0xAA])).encoded())
    #expect(first.messages == [Data([0xAA])])
    // Acknowledgement for handle 1 with reqNum 1: 0x80 | 1 << 4 | 0, then 1 << 6.
    #expect(first.outgoing == [Data([0x90, 0x40])])

    // Sequence 5 while 1 is expected: dropped, and the expected number is acknowledged again.
    let gap = watch.receive(MLRPacket(handle: 1, reqNum: 0, seqNum: 5, payload: Data([0xBB])).encoded())
    #expect(gap.messages.isEmpty)
    #expect(gap.outgoing == [Data([0x90, 0x40])])

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
    let sent = host.receive(ack).outgoing
    #expect(sent.map { $0[1] & 0x3F } == (32...41).map { UInt8($0) })
    #expect(host.unacknowledgedCount == 32)
}

@Test func sequenceNumbersWrapAfterSixtyFourPackets() {
    var host = MLRChannel(handle: 1, maxWrite: 3)
    var watch = MLRChannel(handle: 1, maxWrite: 3)
    for i in 0..<70 {
        let packets = host.send(Data([UInt8(i)]))
        #expect(packets.count == 1)
        #expect(packets[0][1] & 0x3F == UInt8(i % 64))
        let received = watch.receive(packets[0])
        #expect(received.messages == [Data([UInt8(i)])])
        for ack in received.outgoing { _ = host.receive(ack) }
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
        let received = watch.receive(packet)
        delivered += received.messages
        for ack in received.outgoing { _ = host.receive(ack) }
    }
    #expect(host.unacknowledgedCount == packets.count - 2)

    for packet in host.retransmit() {
        let received = watch.receive(packet)
        delivered += received.messages
        for ack in received.outgoing { _ = host.receive(ack) }
    }
    #expect(host.unacknowledgedCount == 0)

    var decoder = CobsDecoder()
    #expect(decoder.feed(delivered.reduce(Data(), +)) == [payload])
}
