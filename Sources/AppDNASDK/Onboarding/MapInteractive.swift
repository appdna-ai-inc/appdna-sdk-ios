import SwiftUI
import GoogleMaps

/**
 SPEC-495 §A tier 2 — a REAL, pannable, zoomable map, drawn by the bundled Google Maps SDK.

 This is the tier #671 asked for. Before it, `map_interactive: true` on a Flutter or React Native
 host silently produced a still image, because the only interactive path went through
 `AppDNA.registerMapView` — an API neither wrapper exposes.

 🟢 AND ON iOS IT NEEDS NOTHING FROM THE HOST, WHICH IS NOT TRUE OF ANDROID.

 Worth stating plainly, because the two platforms differ and the Android file carries the opposite
 warning. The Maps SDK for Android reads `com.google.android.geo.API_KEY` from the MERGED MANIFEST
 at build time, so a server-delivered key cannot reach it and a host must add a `<meta-data>` line.
 iOS has `GMSServices.provideAPIKey(_:)` — a RUNTIME setter — so the key that arrives in the
 bootstrap payload is enough, and a Flutter host gets a pannable map with no wiring at all. That is
 the promise SPEC-495 §D4 made; it holds here and is corrected there for Android.
 */
enum GoogleMapsBootstrap {
    private static var provided = false
    /// Tried once and only once — a raising `provideAPIKey` must not be re-entered on every render.
    private static var attempted = false
    private static let lock = NSLock()

    /// Hands the customer's key to the Maps SDK exactly once, and reports whether a map can be drawn.
    ///
    /// Checked BEFORE a `GMSMapView` is ever constructed, because `GMSMapView.init` on an
    /// unconfigured `GMSServices` does not render a grey rectangle the way Android does — it raises
    /// an exception and takes the host app down. An onboarding step must never be able to do that,
    /// so no key means fall back to the static tier, which needs no key of its own to be *called*
    /// and simply renders its own fallback if it has none either.
    static func ready() -> Bool {
        guard let key = AppDNA.googleMapsApiKey, !key.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        if attempted { return provided }
        attempted = true

        // 🔴 When GoogleMaps.bundle is not where the Maps SDK looks for it, `GMSMapView` init RAISES an
        // Objective-C exception (measured on 9.4.0: `provideAPIKey` itself still returns true; the
        // raise comes at the first map view):
        //
        //     Google Maps SDK for iOS requires GoogleMaps.bundle to be part of your target
        //     under 'Copy Bundle Resources' (GMSServicesException)
        //
        // Swift cannot catch an NSException, so this must be PREVENTED, not handled. Checking first
        // is the whole reason this function exists: an onboarding step that takes the host app down
        // because a resource did not get copied is the worst possible failure for an SDK whose job
        // is the user's first thirty seconds. Without the guard the app dies; with it the map
        // quietly falls back to the static tier, which needs no bundle at all.
        guard mapsBundleIsPresent() else {
            Log.warning("""
            AppDNA map: GoogleMaps.bundle is not in the app bundle (neither at its top level nor             inside one of its top-level .bundle resources), so the Maps SDK cannot start. Falling             back to the static map. Make sure the GoogleMaps resources are copied into the APP             target — not only into a framework or extension.
            """)
            return false
        }

        provided = GMSServices.provideAPIKey(key)
        if !provided {
            Log.warning("AppDNA map: Google Maps rejected the delivered key — falling back to the static map")
        }
        return provided
    }

    /**
     Whether `GoogleMaps.bundle` is somewhere the Maps SDK will find it.

     🔴 MEASURED, not assumed (GoogleMaps 9.4.0, simulator, a minimal app with each layout; the
     exception is raised at `GMSMapView` init). The Maps SDK finds `GoogleMaps.bundle`:
       - at the top level of the MAIN bundle (`App.app/GoogleMaps.bundle`) — found;
       - ONE level inside any top-level `.bundle` of the main bundle — found. That covers CocoaPods
         9.x (`resource_bundles` → `App.app/GoogleMapsResources.bundle/GoogleMaps.bundle`, which is
         what every Flutter / React Native / CocoaPods host gets) and SwiftPM
         (`App.app/GoogleMaps_GoogleMapsTarget.bundle/GoogleMaps.bundle`); the wrapper name does not
         matter (`Foo.bundle/GoogleMaps.bundle` was found too);
       - TWO levels deep (`Outer.bundle/Inner.bundle/GoogleMaps.bundle`) — NOT found → the raise;
       - absent — NOT found → the raise.
     The old check accepted only the first, so on every CocoaPods host the interactive tier was
     refused before the key was ever provided and the map always fell back to the static image.
     */
    private static func mapsBundleIsPresent() -> Bool {
        mapsBundleIsPresent(inAppBundleAt: Bundle.main.bundleURL)
    }

    /// The layout rule above, against any app-bundle directory (injectable for tests).
    static func mapsBundleIsPresent(inAppBundleAt root: URL, fileManager fm: FileManager = .default) -> Bool {
        func isDir(_ u: URL) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
        }
        if isDir(root.appendingPathComponent("GoogleMaps.bundle")) { return true }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.contains { child in
            child.pathExtension == "bundle" && isDir(child.appendingPathComponent("GoogleMaps.bundle"))
        }
    }
}

/// The interactive Google map, wrapped for SwiftUI.
///
/// Every camera, styling and overlay decision below mirrors `MapInteractive.kt` field for field, so
/// switching platform does not change what the author authored. The shared fixtures assert that.
struct GoogleInteractiveMap: UIViewRepresentable {
    let block: ContentBlock

    func makeUIView(context: Context) -> GMSMapView { buildMapView() }

    /**
     The whole construction, with no SwiftUI `Context` in it.

     Split out so the interactive-tier tests can hold the REAL `GMSMapView` this renderer produces.
     `makeUIView` cannot be called outside a render pass (there is no way to fabricate a `Context`),
     and a test that rebuilt the same map itself would be a copy agreeing with a copy — which is how
     #671 stayed invisible: everything we measured was measuring something other than the map.
     */
    internal func buildMapView() -> GMSMapView {
        let camera = GMSCameraPosition.camera(
            withLatitude: centre.lat,
            longitude: centre.lng,
            zoom: Float(mapDouble(block, "map_zoom") ?? 12)
        )

        // `GMSMapViewOptions`, not the `init(frame:camera:)` pair — that initialiser is gone in the
        // Maps SDK 11.x this package pins, and the options object is how a Cloud map ID is supplied
        // at all.
        let options = GMSMapViewOptions()
        options.camera = camera
        options.frame = .zero

        // A Cloud-based map ID, when the author set one. It carries its own styling, so a JSON style
        // is not applied on top of it — that is Google's own precedence, not a choice made here.
        let cloudId = (mapCfg(block, "map_cloud_map_id") as? String) ?? ""
        if !cloudId.isEmpty {
            options.mapID = GMSMapID(identifier: cloudId)
        }

        let mapView = GMSMapView(options: options)
        if cloudId.isEmpty, let json = googleStyleJsonOf(block), !json.isEmpty {
            // A malformed style must not take the map down with it — the two static builders make
            // the same call (no style params rather than a broken request).
            mapView.mapStyle = try? GMSMapStyle(jsonString: json)
        }

        mapView.mapType = switch googleMapType(mapCfg(block, "map_style") as? String) {
        case "satellite": .satellite
        case "hybrid": .hybrid
        case "terrain": .terrain
        default: .normal
        }

        // 🔴 NEVER true. `isMyLocationEnabled` makes the Maps SDK request a location fix, and on a
        // host that already holds the permission it starts one silently. An onboarding map must not
        // turn the user's first run into a location prompt they did not ask for (SPEC-495 §D3).
        mapView.isMyLocationEnabled = false

        // The authored gate. `map_interactive` is what the console's "Pan & zoom" switch sets, and
        // an author who turned it off wants a picture of a place, not a map the user can drag away
        // from the place the step is about.
        let interactive = (mapCfg(block, "map_interactive") as? Bool) != false
        mapView.settings.scrollGestures = interactive
        mapView.settings.zoomGestures = interactive
        mapView.settings.rotateGestures = interactive
        mapView.settings.tiltGestures = false
        // `map_show_controls` means the compass on iOS and the zoom buttons + compass on Android.
        // Google's iOS SDK has no zoom buttons to show — the platforms differ, so the setting is
        // honoured with what each one actually has rather than being ignored on one of them.
        mapView.settings.compassButton = (mapCfg(block, "map_show_controls") as? Bool) == true
        mapView.settings.myLocationButton = false
        mapView.settings.indoorPicker = false

        draw(on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        // Re-drawing on update rather than diffing: a step's map config is authored, not animated,
        // so an update here means the author changed something and the cheap correct answer is to
        // lay the overlays out again.
        mapView.clear()
        draw(on: mapView)
    }

    // MARK: - camera + overlays

    private var isPlace: Bool { (mapCfg(block, "map_mode") as? String) == "place" }

    private var centre: (lat: Double, lng: Double) {
        let stops = mapStops(block)
        if isPlace {
            return (mapDouble(block, "place_lat") ?? 47.6205, mapDouble(block, "place_lng") ?? -122.3493)
        }
        if let first = stops.first { return (first.lat, first.lng) }
        return (mapDouble(block, "map_center_lat") ?? 47.6205, mapDouble(block, "map_center_lng") ?? -122.3493)
    }

    private func draw(on mapView: GMSMapView) {
        let stops = mapStops(block)

        // Route BEFORE markers, so pins draw over the line — the same ordering both static builders
        // use, so changing tier does not reorder the map.
        if !isPlace, (mapCfg(block, "route_show") as? Bool) != false, stops.count >= 2 {
            let path = GMSMutablePath()
            for s in stops { path.add(CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng)) }
            let width = mapDouble(block, "route_width") ?? 4
            let casing = mapDouble(block, "route_casing_width") ?? 2
            if casing > 0 {
                let under = GMSPolyline(path: path)
                under.strokeWidth = CGFloat(width + casing * 2)
                under.strokeColor = UIColor(Color(hex: (mapCfg(block, "route_casing_color") as? String) ?? "#FFFFFF"))
                under.map = mapView
            }
            let line = GMSPolyline(path: path)
            line.strokeWidth = CGFloat(width)
            line.strokeColor = UIColor(Color(hex: (mapCfg(block, "route_color") as? String) ?? "#6366F1"))
            line.map = mapView
        }

        for (i, s) in stops.enumerated() {
            let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng))
            marker.title = i == 0 ? (mapCfg(block, "place_title") as? String) : nil
            marker.map = mapView
        }
    }
}
