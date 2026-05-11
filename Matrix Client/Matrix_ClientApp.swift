//
//  Matrix_ClientApp.swift
//  Matrix Client
//
//  Created by Tejas Patel on 5/10/26.
//

import SwiftUI
import CoreData

@main
struct Matrix_ClientApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
