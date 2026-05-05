//
//  PermissionsBanner.swift
//  Geo
//
//  Slim banner shown at the top of the tab view when the user has
//  denied a sensor permission Geo needs. Tapping the banner opens
//  iOS Settings so the user can fix it without hunting through menus.
//

import SwiftUI

struct PermissionsBanner: View {
    let monitor: PermissionsMonitor

    var body: some View {
        if monitor.hasAnyDenial {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text(deniedHeadline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(deniedDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text("Open Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.65))
            .contentShape(Rectangle())
            .onTapGesture {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    // `LocalizedStringKey` (rather than `String`) makes the values
    // flow through `Localizable.strings` lookup when fed to
    // `Text(_:LocalizedStringKey)`.
    private var deniedHeadline: LocalizedStringKey {
        switch (monitor.locationDenied, monitor.motionDenied) {
        case (true, true):  return "Location & motion access required"
        case (true, false): return "Location access required"
        case (false, true): return "Motion access required"
        default:            return ""
        }
    }

    private var deniedDetail: LocalizedStringKey {
        switch (monitor.locationDenied, monitor.motionDenied) {
        case (true, true):
            return "Tap to enable Location and Motion in Settings."
        case (true, false):
            return "Tap to enable Location in Settings — needed for nearby peaks and the map."
        case (false, true):
            return "Tap to enable Motion in Settings — needed for barometer altitude."
        default:
            return ""
        }
    }
}
