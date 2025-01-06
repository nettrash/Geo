//
//  MountainDetailsView.swift
//  Geo
//
//  Created by Ivan Alekseev on 03/01/2025.
//

import SwiftUI

struct MountainDetailsView: View {
    @State var mountain: MountainInfo? = nil
    
    var body: some View {
        
        if mountain != nil {
            VStack {
                Text(mountain!.name!)
                    .font(.headline)
                    .padding()
                Text("\(mountain!.height!) m")
                    .font(.subheadline)
                    .padding()
                Image(mountain!.image!)
                    .resizable()
            }
        }
    }
}

#Preview {
    MountainDetailsView(mountain: nil)
}
