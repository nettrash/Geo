//
//  GeoApp.swift
//  Geo Watch App
//
//  Created by Ivan Alekseev on 24/01/2025.
//

import SwiftUI
import Foundation
import CoreMotion

class BarometerInformation: ObservableObject {
    @Published var pressure: Double = 0
    @Published var delta: Double = 0
    @Published var height: Double = 0
    @Published var everest: Double = 0
}

@main
struct Geo_Watch_AppApp: App {
    let barometer = CMAltimeter()
    
    @State var barometerInformation: BarometerInformation = BarometerInformation()
    
    var body: some Scene {
        WindowGroup {
            ContentView(barometerInformation: barometerInformation)
        }
    }
    
    func main() {
        barometer.startRelativeAltitudeUpdates(to: .main) { data, error in
            if data != nil {
                self.barometerInformation.pressure = data!.pressure.doubleValue
                self.barometerInformation.delta = data!.relativeAltitude.doubleValue
                
                //Ph = P0 * exp(-0.00012 * h)
                //exp(-0.00012 * h) = Ph / P0
                //-0.00012 * h = ln( Ph / P0 )
                //ln( P0 / Ph ) = 0.00012 * h
                // h = ln ( P0 / Ph ) / 0.00012
                // P0 = 101.325
                
                let P0: Double = 101.325
                let Ph: Double = data!.pressure.doubleValue
                let h: Double = log(P0 / Ph) / 0.00012
                
                self.barometerInformation.height = h
                self.barometerInformation.everest = h / 8848
            }
        }
    }
}
