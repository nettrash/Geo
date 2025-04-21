//
//  LegendView.swift
//  Geo
//
//  Created by Ivan Alekseev on 21/04/2025.
//

import SwiftUI

struct LegendView: View {
    
    @State var Legend: [String] = []
    @State var Colors: [Color] = []

    var body: some View {
        VStack {
            ForEach(self.Legend, id: \.self) { legend in
                HStack {
                    Text("- \(legend)")
                        .font(.system(size: 6))
                        .bold()
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(getColor(legend))
                    Spacer()
                }
            }
        }
    }
    
    func getColor(_ index: Int) -> Color {
        if index >= 0 && index < self.Colors.count {
            self.Colors[index]
        } else {
            .gray
        }
    }
    
    func getColor(_ legend: String) -> Color {
        getColor(self.Legend.firstIndex(of: legend) ?? -1)
    }

}

#Preview {
    LegendView(Legend: ["Legen0", "Legend1", "Legend2"], Colors: [.blue, .red])
}
