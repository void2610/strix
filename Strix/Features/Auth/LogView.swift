//
//  LogView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI

/// アプリ内デバッグログビューア。
/// AppLogger に記録されたメッセージを時系列で表示する。
struct LogView: View {
    private let logger = AppLogger.shared
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            Group {
                if logger.entries.isEmpty {
                    ContentUnavailableView(
                        "ログなし",
                        systemImage: "doc.text",
                        description: Text("操作するとここにログが表示されます")
                    )
                } else {
                    logList
                }
            }
            .navigationTitle("デバッグログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("クリア") { logger.clear() }
                        .foregroundStyle(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showCopied ? "コピー済み" : "全コピー") {
                        copyAll()
                    }
                }
            }
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(logger.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.timeString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: logger.entries.count) { _, _ in
                if let last = logger.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func copyAll() {
        let text = logger.entries
            .map { "[\($0.timeString)] \($0.message)" }
            .joined(separator: "\n")
        UIPasteboard.general.string = text
        showCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopied = false
        }
    }
}
