//
//  LoginView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import WebKit

/// YouTube ログイン用シート。WKWebView でGoogleログインを行い、
/// 成功後に YouTube セッションクッキーを抽出して AuthState に保存する。
struct LoginView: View {
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Coordinator 内で AuthState.shared.save(cookies:dataStore:) を呼ぶため
            // ここでは onComplete と dismiss のみ行う
            YouTubeLoginWebView {
                onComplete()
                dismiss()
            }
            .navigationTitle("YouTubeにログイン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}

// MARK: - WKWebView ラッパー

/// Google アカウントページを WKWebView で表示し、ログイン完了後にクッキーと DataStore を保存する。
struct YouTubeLoginWebView: UIViewRepresentable {
    /// ログイン完了通知（クッキー保存は Coordinator が直接 AuthState を更新）
    let onLoginComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginComplete: onLoginComplete)
    }

    func makeUIView(context: Context) -> WKWebView {
        // 非永続ストアを使って既存セッションと切り離しクリーンなログインを提供する。
        // このストアはログイン後に AuthState.shared.dataStore として保持される。
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&hl=ja")!
        webView.load(URLRequest(url: loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoginComplete: () -> Void
        /// クッキー抽出を一度だけ行うためのフラグ
        private var hasExtracted = false

        init(onLoginComplete: @escaping () -> Void) {
            self.onLoginComplete = onLoginComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasExtracted,
                  let host = webView.url?.host,
                  host.contains("youtube.com") else { return }

            hasExtracted = true

            // DataStore を保持（URLSession では機能しないため WKWebView で使い回す）
            let dataStore = webView.configuration.websiteDataStore

            // ページが完全ロードされた後にクッキーを取得する
            dataStore.httpCookieStore.getAllCookies { cookies in
                let relevant = cookies.filter {
                    $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
                }
                let cookieString = relevant
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                guard !cookieString.isEmpty else { return }
                DispatchQueue.main.async {
                    // クッキー文字列と DataStore の両方を AuthState に保存する
                    AuthState.shared.save(cookies: cookieString, dataStore: dataStore)
                    self.onLoginComplete()
                }
            }
        }
    }
}
