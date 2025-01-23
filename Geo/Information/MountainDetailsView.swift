//
//  MountainDetailsView.swift
//  Geo
//
//  Created by Ivan Alekseev on 03/01/2025.
//

import SwiftUI

struct MountainDetailsView: View {
    @State var mountain: MountainInfo
    
    var body: some View {
        
        VStack {
            
            VStack {
                Text(mountain.name ?? "")
                    .font(.headline)
                
                Text("\(mountain.height ?? 0) m")
                    .font(.system(size: 10))
            }
            .padding()
            
            if mountain.image != nil && mountain.image != "" {
                Image(mountain.image ?? "")
                    .resizable(resizingMode: .stretch)
                    .frame(height: 200)
                    .padding()
            }
            
            HStack(alignment: .top) {
                Text("Geography")
                    .font(.subheadline)
                    .padding()
                Spacer()
                VStack(alignment: .trailing) {
                    Text(mountain.partOfTheWorld ?? "")
                        .font(.system(size: 10))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(mountain.country ?? "")
                        .font(.system(size: 10))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(mountain.location ?? "")
                        .font(.system(size: 10))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding()
            }
            
            if (mountain.firstAscent ?? "") != "" {
                
                HStack(alignment: .top) {
                    Text("Mountain")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack(alignment: .trailing) {
                        if (mountain.firstAscent ?? "") == "" {
                            Text("first ascent is unknown")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .font(.system(size: 10))
                        } else {
                            Text("first ascent was in \(mountain.firstAscent ?? "")")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .font(.system(size: 10))
                        }
                    }
                    .padding()
                }
                
            }

        }
        Spacer()
        
    }
}

#Preview {
    MountainDetailsView(mountain: emptyMountainInfo)
}
