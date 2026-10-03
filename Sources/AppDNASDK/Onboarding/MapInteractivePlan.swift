import Foundation

/// Decoder for Google's encoded polyline format, precision 5.
///
/// Pure Swift on purpose: it does not use `GMSPath(fromEncodedPath:)`, so the plan (and the shared
/// fixtures that pin it) run without the GoogleMaps bundle. It is the inverse of `encodePolyline`,
/// which the static builders use; a round trip is pinned by fixture.
enum MapPolyline {
    /// Decodes `encoded` into `(lat, lng)` pairs.
    ///
    /// - Returns: `[]` for an empty string; `nil` for malformed input — a chunk that never
    ///   terminates, a latitude with no longitude, a character outside `?`…`~`, or a decoded
    ///   coordinate outside ±90 / ±180 (which is also how a precision-6 polyline shows up).
    static func decode(_ encoded: String) -> [(lat: Double, lng: Double)]? {
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0, lng = 0
        var points: [(lat: Double, lng: Double)] = []

        /// One zig-zag varint chunk, or nil when it is truncated or holds an invalid character.
        func nextValue() -> Int? {
            var result = 0
            var shift = 0
            while true {
                guard index < bytes.count else { return nil }
                let c = Int(bytes[index])
                index += 1
                guard c >= 63, c <= 126 else { return nil }
                let b = c - 63
                // 64-bit Int: a legitimate coordinate needs at most 6 chunks; refuse absurd lengths
                // rather than overflow.
                guard shift <= 55 else { return nil }
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { break }
            }
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLng = nextValue() else { return nil }
            lat += dLat
            lng += dLng
            let la = Double(lat) / 1e5, ln = Double(lng) / 1e5
            guard abs(la) <= 90, abs(ln) <= 180 else { return nil }
            points.append((la, ln))
        }
        return points
    }
}

/// What the interactive map draws and where its camera goes, decided in one pure
/// function that `GoogleInteractiveMap` and the shared-fixture runner both call.
struct MapInteractivePlan: Equatable {
    struct LatLng: Equatable {
        let lat: Double
        let lng: Double
    }

    enum RouteSource: String {
        case polyline, stops, none
    }

    enum Camera: Equatable {
        /// Frame the bounding box of `points` with `MapInteractivePlan.fitPadding`.
        case fit(points: [LatLng])
        case center(lat: Double, lng: Double, zoom: Double)
    }

    let routeSource: RouteSource
    let routePoints: [LatLng]
    let markers: [LatLng]
    let camera: Camera

    /// Fixed padding for a fit (points). An authored fit padding is not honoured: it has no console control
    /// (Rule 8).
    static let fitPadding: Double = 48
    /// A fit that collapses to one point centres on it at this zoom — not `map_zoom`, because the
    /// console disables the zoom slider while fit is on.
    static let singlePointZoom: Double = 15
    static let defaultCenter = LatLng(lat: 47.6205, lng: -122.3493)
    static let defaultZoom: Double = 12

    /// - Parameters:
    ///   - block: the (already merged) map block — the route precedence and mode are read off it.
    ///   - rawResolved: whether the block came through the raw host-data pass, exactly as the static
    ///     tier's `mapStaticURL(…, rawResolved:)` takes it (a raw host polyline may contain `{{`).
    static func compute(block: ContentBlock, rawResolved: Bool = false) -> MapInteractivePlan {
        let isPlace = (mapCfg(block, "map_mode") as? String) == "place"
        let markers = mapStops(block).map { LatLng(lat: $0.lat, lng: $0.lng) }

        // 1. Route line.
        var source = RouteSource.none
        var route: [LatLng] = []
        if !isPlace, (mapCfg(block, "route_show") as? Bool) != false {
            let encoded = mapRoutePolyline(block, rawResolved: rawResolved)
            var decoded: [(lat: Double, lng: Double)]? = nil
            if let encoded, !encoded.isEmpty {
                decoded = MapPolyline.decode(encoded)
                if decoded == nil { Log.debug("map: polyline malformed, using stops") }
            }
            if let decoded, decoded.count >= 2 {
                source = .polyline
                route = decoded.map { LatLng(lat: $0.lat, lng: $0.lng) }
            } else if markers.count >= 2 {
                source = .stops
                route = markers
            }
        }

        // 3. Camera.
        let camera: Camera
        if isPlace {
            camera = .center(
                lat: mapDouble(block, "place_lat") ?? defaultCenter.lat,
                lng: mapDouble(block, "place_lng") ?? defaultCenter.lng,
                zoom: mapDouble(block, "map_zoom") ?? defaultZoom
            )
        } else {
            // F = route points ∪ markers, route first, each point once.
            var fitPoints: [LatLng] = []
            for p in route + markers where !fitPoints.contains(p) { fitPoints.append(p) }
            let fitOn = (mapCfg(block, "map_fit_to_stops") as? Bool) != false
            if fitOn, fitPoints.count >= 2 {
                camera = .fit(points: fitPoints)
            } else if fitOn, let only = fitPoints.first {
                camera = .center(lat: only.lat, lng: only.lng, zoom: singlePointZoom)
            } else {
                camera = .center(
                    lat: mapDouble(block, "map_center_lat") ?? defaultCenter.lat,
                    lng: mapDouble(block, "map_center_lng") ?? defaultCenter.lng,
                    zoom: mapDouble(block, "map_zoom") ?? defaultZoom
                )
            }
        }
        return MapInteractivePlan(routeSource: source, routePoints: route, markers: markers, camera: camera)
    }

    /// The camera's bounding box for a fit: naive min/max (routes crossing ±180° are out of scope).
    static func bounds(of points: [LatLng]) -> (south: Double, west: Double, north: Double, east: Double)? {
        guard let first = points.first else { return nil }
        var s = first.lat, n = first.lat, w = first.lng, e = first.lng
        for p in points.dropFirst() {
            s = min(s, p.lat); n = max(n, p.lat); w = min(w, p.lng); e = max(e, p.lng)
        }
        return (s, w, n, e)
    }
}
