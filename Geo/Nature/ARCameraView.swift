//
//  ARCameraView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI
import ARKit
import CoreLocation

/// UIViewRepresentable wrapper for ARSCNView to show the camera feed
struct ARCameraView: UIViewRepresentable {
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session.delegate = context.coordinator
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true
        
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        arView.session.run(config)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }
    
    class Coordinator: NSObject, ARSessionDelegate {
    }
}
