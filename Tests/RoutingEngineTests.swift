import Foundation
import XCTest
@testable import MeshMessenger

final class RoutingEngineTests: XCTestCase {
    func testNextHopChoosesLowestCostThenLatency() async {
        let routing = RoutingEngine()
        let destination = PeerID("dest")

        await routing.upsert(route: RouteEntry(destination: destination, nextHop: PeerID("slow"), cost: 2, latencyMs: 120))
        await routing.upsert(route: RouteEntry(destination: destination, nextHop: PeerID("fast"), cost: 2, latencyMs: 40))
        await routing.upsert(route: RouteEntry(destination: destination, nextHop: PeerID("cheap"), cost: 1, latencyMs: 200))

        let best = await routing.nextHop(for: destination)
        XCTAssertEqual(best?.nextHop, PeerID("cheap"))
    }
}

