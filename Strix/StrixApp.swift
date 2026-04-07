//
//  StrixApp.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import SwiftUI
import SwiftData

@main
struct StrixApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([WatchedVideo.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer の作成に失敗しました: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(sharedModelContainer)
    }
}
