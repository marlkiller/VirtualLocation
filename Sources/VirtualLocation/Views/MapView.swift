import SwiftUI
import MapKit

final class LocationPinAnnotation: MKPointAnnotation {
    let kind: Kind
    enum Kind: String { case active, selected }

    init(kind: Kind, coordinate: CLLocationCoordinate2D, title: String, subtitle: String = "") {
        self.kind = kind
        super.init()
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }
}

final class PresetAnnotation: MKPointAnnotation {
    let presetID: UUID
    let isCustom: Bool

    init(preset: LocationPreset, isCustom: Bool) {
        self.presetID = preset.id
        self.isCustom = isCustom
        super.init()
        title = preset.name
        subtitle = "\(preset.landmark) · \(preset.region)"
        coordinate = preset.coordinate
    }
}

struct MapView: NSViewRepresentable {
    @Binding var selectedCoordinate: CLLocationCoordinate2D?
    var presets: [LocationPreset]
    var activeCoordinate: CLLocationCoordinate2D?
    var centerCoordinate: CLLocationCoordinate2D?
    var mapType: MKMapType = .standard
    var showPresets: Bool = true
    var onDeletePreset: ((LocationPreset) -> Void)?
    var onCoordinateChanged: ((CLLocationCoordinate2D) -> Void)?
    var onCoordinateTapped: ((CLLocationCoordinate2D, CGPoint) -> Void)?
    @Binding var zoomInCounter: Int
    @Binding var zoomOutCounter: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = mapType
        map.showsZoomControls = false
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = false
        map.wantsLayer = true

        let tap = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        map.addGestureRecognizer(tap)

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.3974),
            span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 50)
        )
        map.setRegion(region, animated: false)

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        if zoomInCounter != context.coordinator.lastZoomInCounter {
            context.coordinator.lastZoomInCounter = zoomInCounter
            var r = map.region
            r.span.latitudeDelta *= 0.5
            r.span.longitudeDelta *= 0.5
            map.setRegion(r, animated: true)
        }
        if zoomOutCounter != context.coordinator.lastZoomOutCounter {
            context.coordinator.lastZoomOutCounter = zoomOutCounter
            var r = map.region
            r.span.latitudeDelta *= 2.0
            r.span.longitudeDelta *= 2.0
            map.setRegion(r, animated: true)
        }

        if map.mapType != mapType {
            map.mapType = mapType
        }

        if let center = centerCoordinate {
            let last = context.coordinator.lastCenter
            if last == nil ||
                abs(last!.latitude - center.latitude) > 0.000001 ||
                abs(last!.longitude - center.longitude) > 0.000001 {
                map.setCenter(center, animated: true)
                context.coordinator.lastCenter = center
            }
        }

        let existing = map.annotations
        var desired: [MKAnnotation] = []

        let customIDs = Set(presets.filter { p in
            !LocationPreset.builtin.contains(where: { $0.id == p.id })
        }.map(\.id))

        if showPresets {
            for p in presets {
                desired.append(PresetAnnotation(preset: p, isCustom: customIDs.contains(p.id)))
            }
        }

        if let active = activeCoordinate {
            desired.append(LocationPinAnnotation(
                kind: .active,
                coordinate: active,
                title: "模拟位置",
                subtitle: String(format: "%.6f, %.6f", active.latitude, active.longitude)
            ))
        }

        if let sel = selectedCoordinate {
            let exists = desired.contains { ann in
                abs(ann.coordinate.latitude - sel.latitude) < 0.000001 &&
                abs(ann.coordinate.longitude - sel.longitude) < 0.000001
            }
            if !exists {
                desired.append(LocationPinAnnotation(
                    kind: .selected,
                    coordinate: sel,
                    title: "选定位置",
                    subtitle: String(format: "%.6f, %.6f", sel.latitude, sel.longitude)
                ))
            }
        }

        let desiredKeys = Set(desired.map { annKey($0) })
        let toRemove = existing.filter { !desiredKeys.contains(annKey($0)) }
        let existingKeys = Set(existing.map { annKey($0) })
        let toAdd = desired.filter { !existingKeys.contains(annKey($0)) }

        if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
        if !toAdd.isEmpty { map.addAnnotations(toAdd) }
    }

    private func annKey(_ ann: MKAnnotation) -> String {
        let lat = String(format: "%.6f", ann.coordinate.latitude)
        let lng = String(format: "%.6f", ann.coordinate.longitude)
        let t: String = (ann.title ?? "") ?? ""
        return "\(lat),\(lng)|\(t)"
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapView
        var lastCenter: CLLocationCoordinate2D?
        var lastZoomInCounter = 0
        var lastZoomOutCounter = 0

        init(_ parent: MapView) { self.parent = parent }

        @objc func handleMapTap(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)

            var hit: NSView? = map.hitTest(point)
            while hit != nil {
                if hit is MKAnnotationView { return }
                hit = hit?.superview
            }

            let coord = map.convert(point, toCoordinateFrom: map)
            parent.selectedCoordinate = coord
            parent.onCoordinateChanged?(coord)
            parent.onCoordinateTapped?(coord, point)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation else { return }
            let pt = mapView.convert(ann.coordinate, toPointTo: mapView)
            parent.selectedCoordinate = ann.coordinate
            parent.onCoordinateChanged?(ann.coordinate)
            parent.onCoordinateTapped?(ann.coordinate, pt)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let la = annotation as? LocationPinAnnotation {
                let id = "LocationPin"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                if v == nil {
                    v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                } else {
                    v?.annotation = annotation
                }

                switch la.kind {
                case .active:
                    v?.markerTintColor = NSColor(.dsAccent)
                    v?.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
                    v?.glyphTintColor = .white
                    v?.animatesWhenAdded = true
                    v?.displayPriority = .required
                case .selected:
                    v?.markerTintColor = NSColor(.dsWarning)
                    v?.glyphImage = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: nil)
                    v?.glyphTintColor = .white
                    v?.displayPriority = .required
                }
                v?.canShowCallout = true
                return v
            }

            if let pa = annotation as? PresetAnnotation {
                let id = "PresetPin"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                if v == nil {
                    v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                } else {
                    v?.annotation = annotation
                }

                v?.markerTintColor = pa.isCustom
                    ? NSColor(.dsAccent).withAlphaComponent(0.6)
                    : NSColor(.dsAccent).withAlphaComponent(0.4)
                v?.glyphImage = NSImage(systemSymbolName: pa.isCustom ? "bookmark.fill" : "star", accessibilityDescription: nil)
                v?.glyphTintColor = .white
                v?.canShowCallout = true
                v?.displayPriority = .defaultLow

                if pa.isCustom, parent.onDeletePreset != nil {
                    let menu = NSMenu()
                    let item = NSMenuItem(title: "删除收藏", action: #selector(deletePreset(_:)), keyEquivalent: "")
                    item.representedObject = pa.presetID
                    item.target = self
                    menu.addItem(item)
                    v?.menu = menu
                }
                return v
            }

            return nil
        }

        @objc private func deletePreset(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID,
                  let preset = parent.presets.first(where: { $0.id == id }) else { return }
            parent.onDeletePreset?(preset)
        }
    }
}
