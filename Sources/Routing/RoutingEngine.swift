import Foundation

public actor RoutingEngine {
    private var routeTable: [PeerID: [RouteEntry]] = [:]

    public init() {}

    public func upsert(route: RouteEntry) {
        var routes = routeTable[route.destination, default: []]
        if let index = routes.firstIndex(where: { $0.nextHop == route.nextHop }) {
            routes[index] = route
        } else {
            routes.append(route)
        }
        routeTable[route.destination] = routes
    }

    public func nextHop(for destination: PeerID) -> RouteEntry? {
        routeTable[destination]?
            .sorted {
                if $0.cost == $1.cost {
                    return $0.latencyMs < $1.latencyMs
                }
                return $0.cost < $1.cost
            }
            .first
    }

    public func updateDistanceVector(_ routes: [RouteEntry], from neighbor: PeerID) {
        for route in routes {
            let relayed = RouteEntry(
                destination: route.destination,
                nextHop: neighbor,
                cost: route.cost + 1,
                latencyMs: route.latencyMs
            )
            upsert(route: relayed)
        }
    }

    public func allRoutes() -> [RouteEntry] {
        routeTable.values.flatMap { $0 }
    }

    public func knownRouteDestinations() -> [PeerID] {
        Array(routeTable.keys)
    }
}

