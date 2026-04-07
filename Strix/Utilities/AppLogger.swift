//
//  AppLogger.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation

/// アプリ内ログビューア用のシンプルなロガー。
/// AppLogger.log() で記録し、AppLogger.shared.entries で参照できる。
@Observable
final class AppLogger {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String

        var timeString: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: date)
        }
    }

    static let shared = AppLogger()
    private init() {}

    private(set) var entries: [Entry] = []

    /// ログを記録する。print() と同時に呼ぶ。
    func append(_ message: String) {
        let entry = Entry(date: Date(), message: message)
        entries.append(entry)
        // 最大 500 件を保持（古いものを捨てる）
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    func clear() {
        entries = []
    }
}

/// print の代わりに使うグローバル関数。print + AppLogger.shared に両方送る。
func strixLog(_ message: String) {
    print("[Strix] \(message)")
    Task { @MainActor in
        AppLogger.shared.append(message)
    }
}
