//
//  MainView.swift
//  Geo
//
//  Created by nettrash on 08/09/2023.
//

import SwiftUI
import CoreData

struct MainView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State var app: GeoAppDelegate?
    
    var body: some View {
        ZStack(content: {
            /*Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.01)*/
            
            TabView {
                GeoInfoView(app: app)
                    .tabItem {
                        Image(systemName: "ruler")
                        Text("Info")
                    }
                GeoStatView()
                    .tabItem {
                        Image(systemName: "chart.xyaxis.line")
                        Text("Stat")
                    }
                GeoMapView()
                    .tabItem {
                        Image(systemName: "map")
                        Text("Map")
                    }
                GeoNatureView()
                    .tabItem {
                        Image(systemName: "mountain.2")
                        Text("Nature")
                    }
            }
        })
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView(app: nil).environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
