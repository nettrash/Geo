//
//  PeakFinder.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import Foundation
import CoreLocation
import MapKit

/// Searches for nearby peaks using Apple Maps + OpenStreetMap Overpass API
/// and merges with known mountains from the app's MountainData
@MainActor
class PeakFinder: ObservableObject {
    
    @Published var peaks: [NearbyPeak] = []

    private let searchRadius: CLLocationDistance = 5000 // 5 km
    private var lastSearchLocation: CLLocation?
    private let minimumSearchDistance: CLLocationDistance = 500 // re-search after moving 500m

    /// Maximum number of peaks we keep in the merged set. Older / further
    /// entries are evicted first when this is exceeded.
    private let maxRetainedPeaks: Int = 200

    /// Time after which a peak that has not been re-confirmed by a search
    /// gets dropped, even if the user hasn't moved. Stops stale results
    /// from accumulating if the user sits in one place for hours.
    private let peakTTL: TimeInterval = 60 * 60
    
    /// Search for peaks near the given location using all sources in parallel
    func searchPeaks(near location: CLLocation, mountainsData: MountainData?) async {
        // Don't re-search if we haven't moved much
        if let last = lastSearchLocation,
           last.distance(from: location) < minimumSearchDistance,
           !peaks.isEmpty {
            return
        }

        lastSearchLocation = location

        // Run Apple Maps and OpenStreetMap searches in parallel
        async let applePeaks = searchAppleMaps(near: location)
        async let osmPeaks = searchOpenStreetMap(near: location)

        let knownPeaks = findKnownMountains(near: location, mountainsData: mountainsData)

        var foundPeaks: [NearbyPeak] = []

        // 1. Start with Apple Maps results
        let appleResults = await applePeaks
        foundPeaks.append(contentsOf: appleResults)

        // 2. Merge OpenStreetMap results (de-duplicate)
        let osmResults = await osmPeaks
        for osmPeak in osmResults {
            if !isDuplicate(osmPeak, in: foundPeaks) {
                foundPeaks.append(osmPeak)
            }
        }

        // 3. Merge known mountains from app data
        for knownPeak in knownPeaks {
            if !isDuplicate(knownPeak, in: foundPeaks) {
                foundPeaks.append(knownPeak)
            }
        }

        // Merge with the previous result set so a transient empty / partial
        // response from MapKit or Overpass doesn't wipe peaks that are still
        // valid.
        var byID: [UUID: NearbyPeak] = [:]
        for p in peaks { byID[p.id] = p }
        for p in foundPeaks { byID[p.id] = p } // fresh data wins on duplicates

        let dropRadius = searchRadius * 2 // hysteresis to avoid flicker at the edge
        let now = Date()
        let ttl = peakTTL

        // Recompute distance/bearing for *every* surviving peak against
        // the current user location so visual fades stay accurate.
        var recomputed: [NearbyPeak] = []
        recomputed.reserveCapacity(byID.count)
        for var peak in byID.values {
            let pl = CLLocation(latitude: peak.coordinate.latitude,
                                longitude: peak.coordinate.longitude)
            let d = location.distance(from: pl)
            // Drop entries we've moved well past, or that haven't been
            // re-confirmed by a search within the TTL window.
            guard d <= dropRadius else { continue }
            guard now.timeIntervalSince(peak.lastSeenAt) <= ttl else { continue }

            peak.distance = d
            peak.bearing = Geometry.bearing(from: location.coordinate, to: peak.coordinate)
            recomputed.append(peak)
        }

        // Cap the total — keep the closest ones first.
        recomputed.sort { $0.distance < $1.distance }
        if recomputed.count > maxRetainedPeaks {
            recomputed = Array(recomputed.prefix(maxRetainedPeaks))
        }

        peaks = recomputed
    }
    
    /// Check if a peak is a duplicate of any existing peak (within 200m)
    private func isDuplicate(_ peak: NearbyPeak, in existing: [NearbyPeak]) -> Bool {
        existing.contains { other in
            let otherLoc = CLLocation(latitude: other.coordinate.latitude,
                                      longitude: other.coordinate.longitude)
            let peakLoc = CLLocation(latitude: peak.coordinate.latitude,
                                     longitude: peak.coordinate.longitude)
            return otherLoc.distance(from: peakLoc) < 200
        }
    }
    
    /// Search Apple Maps for peaks/mountains using MKLocalSearch
    private func searchAppleMaps(near location: CLLocation) async -> [NearbyPeak] {
        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: searchRadius * 2,
            longitudinalMeters: searchRadius * 2
        )
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "mountain peak"
        request.region = region
        request.resultTypes = .pointOfInterest
        
        let search = MKLocalSearch(request: request)
        
        do {
            let response = try await search.start()
            return response.mapItems.compactMap { item -> NearbyPeak? in
                let peakLocation = item.location
                let coordinate = peakLocation.coordinate
                let distance = location.distance(from: peakLocation)
                
                guard distance <= searchRadius else { return nil }
                guard let name = item.name, !name.isEmpty else { return nil }
                
                let bearing = Geometry.bearing(
                    from: location.coordinate,
                    to: coordinate
                )
                
                // Apple Maps often doesn't provide altitude for POIs.
                // Fall back to the user's own altitude so the marker sits at the
                // horizon rather than at an arbitrary fixed offset.
                let altitude = peakLocation.altitude > 10 ? peakLocation.altitude : location.altitude
                
                return NearbyPeak(
                    name: name,
                    coordinate: coordinate,
                    altitude: altitude,
                    distance: distance,
                    bearing: bearing
                )
            }
        } catch {
            AppLog.ar.error("Apple Maps peak search error: \(String(describing: error))")
            return []
        }
    }
    
    /// Search OpenStreetMap via Overpass API for peaks (natural=peak)
    /// Free, no API key required, excellent worldwide peak coverage.
    /// Privacy: lat/lon are rounded to ~3 decimals (~110 m at the equator)
    /// before being sent so the precise location of the device isn't
    /// disclosed to a third-party API; the search radius (5 km) is far
    /// larger than that quantisation error.
    private func searchOpenStreetMap(near location: CLLocation) async -> [NearbyPeak] {
        let qLat = (location.coordinate.latitude * 1000).rounded() / 1000
        let qLon = (location.coordinate.longitude * 1000).rounded() / 1000
        let radiusMeters = Int(searchRadius)

        // Overpass QL query: find all nodes tagged as natural=peak within radius
        let query = """
        [out:json][timeout:10];
        node["natural"="peak"](around:\(radiusMeters),\(qLat),\(qLon));
        out body;
        """

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(encodedQuery)") else {
            return []
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }

            let result = try JSONDecoder().decode(OverpassResponse.self, from: data)

            return result.elements.compactMap { element -> NearbyPeak? in
                guard let name = element.tags?.name, !name.isEmpty else { return nil }

                let peakLocation = CLLocation(latitude: element.lat, longitude: element.lon)
                let distance = location.distance(from: peakLocation)

                guard distance <= searchRadius else { return nil }

                let peakBearing = Geometry.bearing(
                    from: location.coordinate,
                    to: CLLocationCoordinate2D(latitude: element.lat, longitude: element.lon)
                )

                // OSM peaks often have elevation in tags
                let altitude: Double
                if let eleString = element.tags?.ele, let ele = Double(eleString) {
                    altitude = ele
                } else {
                    altitude = location.altitude + 100
                }

                return NearbyPeak(
                    name: name,
                    coordinate: CLLocationCoordinate2D(latitude: element.lat, longitude: element.lon),
                    altitude: altitude,
                    distance: distance,
                    bearing: peakBearing
                )
            }
        } catch {
            AppLog.ar.error("OpenStreetMap peak search error: \(String(describing: error))")
            return []
        }
    }
    
    /// Find known mountains from app data that are within range
    private func findKnownMountains(near location: CLLocation, mountainsData: MountainData?) -> [NearbyPeak] {
        guard let data = mountainsData else { return [] }
        
        var results: [NearbyPeak] = []
        
        let allLists = [data.highest, data.sevenPeaks, data.snowLeopardOfRussia].compactMap { $0 }
        
        for list in allLists {
            guard let mountains = list.mountains else { continue }
            for mountain in mountains {
                guard let lat = mountain.coordinates?.latitude,
                      let lon = mountain.coordinates?.longitude,
                      let name = mountain.name else { continue }
                
                let mountainLocation = CLLocation(latitude: lat, longitude: lon)
                let distance = location.distance(from: mountainLocation)
                
                guard distance <= searchRadius else { continue }
                
                let mountainBearing = Geometry.bearing(from: location.coordinate,
                                                       to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                
                results.append(NearbyPeak(
                    name: name,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: Double(mountain.height ?? 0),
                    distance: distance,
                    bearing: mountainBearing
                ))
            }
        }
        
        return results
    }
    

}

// MARK: - OpenStreetMap Overpass API Response Models

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
}

private struct OverpassElement: Decodable {
    let lat: Double
    let lon: Double
    let tags: OverpassTags?
}

private struct OverpassTags: Decodable {
    let name: String?
    let ele: String?  // elevation in meters (stored as string in OSM)
}
