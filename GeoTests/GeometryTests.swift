//
//  GeometryTests.swift
//  GeoTests
//
//  Pure-function tests for the geometry primitives that drive the AR
//  overlay (horizon line, peak markers, history points). These are
//  deliberately isolated from ARKit / SwiftUI so they run anywhere.
//

import XCTest
import CoreLocation
@testable import Geo

final class GeometryTests: XCTestCase {

    // MARK: - Horizon distance

    func testHorizonDistanceAtSeaLevel() {
        // Right at sea level the horizon is "at the observer" — sqrt(0).
        XCTAssertEqual(Geometry.horizonDistance(observerAltitude: 0), 0,
                       accuracy: 0.001)
    }

    func testHorizonDistanceAtTwoMetres() {
        // Classic textbook value: ~5 km horizon at average eye height.
        let d = Geometry.horizonDistance(observerAltitude: 2)
        XCTAssertEqual(d, 5_048, accuracy: 50)
    }

    func testHorizonDistanceOnEverest() {
        // Standing on Everest (~8848 m), the horizon should be ~336 km.
        let d = Geometry.horizonDistance(observerAltitude: 8_848)
        XCTAssertEqual(d, 336_000, accuracy: 1_000)
    }

    func testHorizonDistanceClampsNegativeAltitudes() {
        // GPS sometimes reports negative altitudes near sea level.
        // The function should treat them as zero, never NaN.
        let d = Geometry.horizonDistance(observerAltitude: -3)
        XCTAssertEqual(d, 0, accuracy: 0.001)
    }

    // MARK: - GPS → ENU

    func testGpsToENUSamePointIsZero() {
        let p = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
        let enu = Geometry.gpsToENU(from: p, originAltitude: 100,
                                    to: p, targetAltitude: 100)
        XCTAssertEqual(enu.east, 0, accuracy: 0.001)
        XCTAssertEqual(enu.north, 0, accuracy: 0.001)
        XCTAssertEqual(enu.up, 0, accuracy: 0.001)
    }

    func testGpsToENUNorthOffsetMatchesLatitudeArc() {
        // Move 0.01° north from the equator: north should be ~1113 m
        // (0.01 × 111_320), east ~ 0, up reflects altitude diff.
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let target = CLLocationCoordinate2D(latitude: 0.01, longitude: 0)
        let enu = Geometry.gpsToENU(from: origin, originAltitude: 0,
                                    to: target, targetAltitude: 0)
        XCTAssertEqual(enu.east, 0, accuracy: 0.001)
        XCTAssertEqual(enu.north, 1_113.2, accuracy: 1)
        XCTAssertEqual(enu.up, 0, accuracy: 0.001)
    }

    func testGpsToENUEastOffsetShrinksWithLatitude() {
        // 0.01° east at the equator vs at 60°N: the metres-per-degree-
        // longitude figure is halved at 60° (cos(60°)=0.5).
        let eq = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let eqEast = CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
        let north = CLLocationCoordinate2D(latitude: 60, longitude: 0)
        let northEast = CLLocationCoordinate2D(latitude: 60, longitude: 0.01)

        let eqENU = Geometry.gpsToENU(from: eq, originAltitude: 0,
                                      to: eqEast, targetAltitude: 0)
        let nENU = Geometry.gpsToENU(from: north, originAltitude: 0,
                                     to: northEast, targetAltitude: 0)
        XCTAssertEqual(eqENU.east / nENU.east, 2.0, accuracy: 0.01)
    }

    func testGpsToENUAppliesCurvatureDropForDistantPoints() {
        // 50 km away at the same altitude: the up component should be
        // strongly negative due to Earth-curvature drop (~196 m).
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        // ~50 km east: ~0.449° at the equator
        let target = CLLocationCoordinate2D(latitude: 0, longitude: 0.449)
        let enu = Geometry.gpsToENU(from: origin, originAltitude: 0,
                                    to: target, targetAltitude: 0)
        XCTAssertLessThan(enu.up, -150)
    }

    // MARK: - Manual compass alignment (ENU rotation + pan conversion)

    func testRotateENUZeroDegreesIsIdentity() {
        let r = Geometry.rotateENU(east: 123.4, north: -56.7, clockwiseDegrees: 0)
        XCTAssertEqual(r.east, 123.4, accuracy: 1e-9)
        XCTAssertEqual(r.north, -56.7, accuracy: 1e-9)
    }

    func testRotateENUPlus90MapsNorthToEast() {
        // Compass-sense rotation: +90° takes a due-North point (bearing 0)
        // to due East (bearing 90) — the overlay shifts clockwise/right.
        let r = Geometry.rotateENU(east: 0, north: 100, clockwiseDegrees: 90)
        XCTAssertEqual(r.east, 100, accuracy: 1e-9)
        XCTAssertEqual(r.north, 0, accuracy: 1e-9)
    }

    func testRotateENUMinus90MapsNorthToWest() {
        // −90° takes due North (bearing 0) to due West (bearing 270).
        let r = Geometry.rotateENU(east: 0, north: 100, clockwiseDegrees: -90)
        XCTAssertEqual(r.east, -100, accuracy: 1e-9)
        XCTAssertEqual(r.north, 0, accuracy: 1e-9)
    }

    func testAlignmentPanConversionSignAndScale() {
        // 8 pt of rightward pan = +1° of alignment; sign follows the finger.
        XCTAssertEqual(alignmentOffsetDegrees(base: 0, panTranslationX: 8), 1, accuracy: 1e-9)
        XCTAssertEqual(alignmentOffsetDegrees(base: 0, panTranslationX: -16), -2, accuracy: 1e-9)
        // Pan continues from the latched base, it doesn't restart at zero.
        XCTAssertEqual(alignmentOffsetDegrees(base: 5, panTranslationX: 24), 8, accuracy: 1e-9)
    }

    func testAlignmentPanConversionClampsToPlusMinus30() {
        // A screen-crossing fling can't exceed the ±30° clamp in either
        // direction, whatever the starting base.
        XCTAssertEqual(alignmentOffsetDegrees(base: 0, panTranslationX: 10_000), 30, accuracy: 1e-9)
        XCTAssertEqual(alignmentOffsetDegrees(base: 0, panTranslationX: -10_000), -30, accuracy: 1e-9)
        XCTAssertEqual(alignmentOffsetDegrees(base: 29, panTranslationX: 80), 30, accuracy: 1e-9)
        XCTAssertEqual(alignmentOffsetDegrees(base: -29, panTranslationX: -80), -30, accuracy: 1e-9)
    }

    // MARK: - Bearing

    func testBearingDueNorth() {
        let from = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let to = CLLocationCoordinate2D(latitude: 1, longitude: 0)
        XCTAssertEqual(Geometry.bearing(from: from, to: to), 0, accuracy: 0.5)
    }

    func testBearingDueEast() {
        let from = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let to = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        XCTAssertEqual(Geometry.bearing(from: from, to: to), 90, accuracy: 0.5)
    }

    func testBearingDueWestIs270NotNegative() {
        let from = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let to = CLLocationCoordinate2D(latitude: 0, longitude: -1)
        // Should wrap into [0, 360) — i.e. 270, never -90.
        XCTAssertEqual(Geometry.bearing(from: from, to: to), 270, accuracy: 0.5)
    }

    // MARK: - Cardinal direction (8-point compass)

    func testCardinalDirectionBoundaries() {
        XCTAssertEqual(Geometry.cardinalDirection(0), "N")
        XCTAssertEqual(Geometry.cardinalDirection(45), "NE")
        XCTAssertEqual(Geometry.cardinalDirection(90), "E")
        XCTAssertEqual(Geometry.cardinalDirection(117), "SE")   // matches the spec example
        XCTAssertEqual(Geometry.cardinalDirection(135), "SE")
        XCTAssertEqual(Geometry.cardinalDirection(180), "S")
        XCTAssertEqual(Geometry.cardinalDirection(225), "SW")
        XCTAssertEqual(Geometry.cardinalDirection(270), "W")
        XCTAssertEqual(Geometry.cardinalDirection(315), "NW")
    }

    func testCardinalDirectionWrapsAndSnaps() {
        XCTAssertEqual(Geometry.cardinalDirection(360), "N")
        XCTAssertEqual(Geometry.cardinalDirection(350), "N")   // 337.5–360 snaps to N
        XCTAssertEqual(Geometry.cardinalDirection(-45), "NW")  // negative normalises
        XCTAssertEqual(Geometry.cardinalDirection(405), "NE")  // >360 normalises (45°)
    }

    func testCardinalDirectionSectorBoundaries() {
        // Each lower sector edge is inclusive; just below snaps to the
        // previous sector. Locked in lockstep with Android `SolarTest`/
        // `GeoCalculationsTest` so a half-sector drift fails on both.
        XCTAssertEqual(Geometry.cardinalDirection(22.5), "NE")
        XCTAssertEqual(Geometry.cardinalDirection(67.5), "E")
        XCTAssertEqual(Geometry.cardinalDirection(112.5), "SE")
        XCTAssertEqual(Geometry.cardinalDirection(157.5), "S")
        XCTAssertEqual(Geometry.cardinalDirection(202.5), "SW")
        XCTAssertEqual(Geometry.cardinalDirection(247.5), "W")
        XCTAssertEqual(Geometry.cardinalDirection(292.5), "NW")
        XCTAssertEqual(Geometry.cardinalDirection(337.5), "N")
        XCTAssertEqual(Geometry.cardinalDirection(22.4999), "N")
        XCTAssertEqual(Geometry.cardinalDirection(337.4999), "NW")
    }

    func testCardinalDirectionNonFiniteIsN() {
        XCTAssertEqual(Geometry.cardinalDirection(.nan), "N")
        XCTAssertEqual(Geometry.cardinalDirection(.infinity), "N")
        XCTAssertEqual(Geometry.cardinalDirection(-.infinity), "N")
    }
}
