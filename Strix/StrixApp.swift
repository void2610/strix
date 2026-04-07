//
//  StrixApp.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import SwiftUI
import SwiftData
import AVFoundation

@main
struct StrixApp: App {
    init() {
        // 消音モードでも音声を再生する（音楽・動画アプリ標準の設定）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        // Keychain に保存済みのログインクッキーを復元する
        AuthState.shared.loadFromKeychain()
    }

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
