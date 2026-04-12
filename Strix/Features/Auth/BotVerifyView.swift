//
//  BotVerifyView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/12.
//

import SwiftUI
import WebKit

/// YouTube のボット検出 CAPTCHA を解くための WKWebView 画面。
/// ユーザーが YouTube ページで認証を完了し「完了」ボタンを押すと Cookie を更新してリトライする。
struct BotVerifyView: View {
    let onVerified: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BotVerifyWebView()
                .navigationTitle("YouTube 認証")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            // 閉じる前に最新の Cookie を保存
                            BotVerifyWebView.refreshCookies {
                                onVerified()
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - WKWebView ラッパー

private struct BotVerifyWebView: UIViewRepresentable {
    /// 共有の WKWebView 参照（Cookie 更新用）
    private static var currentWebView: WKWebView?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = AuthState.shared.dataStore ?? .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        Self.currentWebView = webView

        let url = URL(string: "https://www.youtube.com")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// 「完了」ボタンから呼ばれる。現在の WKWebView から Cookie を抽出して AuthState を更新する。
    static func refreshCookies(completion: @escaping () -> Void) {
        guard let webView = currentWebView else {
            completion()
            return
        }
        let dataStore = webView.configuration.websiteDataStore
        dataStore.httpCookieStore.getAllCookies { cookies in
            let relevant = cookies.filter {
                $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
            }
            let cookieString = relevant
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            DispatchQueue.main.async {
                if !cookieString.isEmpty {
                    AuthState.shared.save(cookies: cookieString, dataStore: dataStore)
                    strixLog("BotVerify: Cookie 更新完了")
                }
                completion()
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {}
}
