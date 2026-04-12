//
//  LoginView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI
import WebKit

/// YouTube ログイン用シート。WKWebView で Google ログインを行い、
/// 成功後に YouTube セッションクッキーを抽出して AuthState に保存する。
struct LoginView: View {
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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

/// YouTube 認証に必須の Cookie 名
private let requiredCookieNames: Set<String> = ["SID", "HSID", "SSID"]

/// Google アカウントページを WKWebView で表示し、ログイン完了後にクッキーと DataStore を保存する。
/// .default() ストアを使用することでデバイス信頼情報・ログインセッションがアプリ再起動後も保持される。
struct YouTubeLoginWebView: UIViewRepresentable {
    let onLoginComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginComplete: onLoginComplete)
    }

    func makeUIView(context: Context) -> WKWebView {
        // .default() 永続ストアを使用（デバイス信頼・2FA 記憶が保持される）
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&hl=ja&continue=https://www.youtube.com/")!
        webView.load(URLRequest(url: loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onLoginComplete: () -> Void
        private var hasExtracted = false

        init(onLoginComplete: @escaping () -> Void) {
            self.onLoginComplete = onLoginComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let host = webView.url?.host,
                  host.contains("youtube.com") else { return }

            // YouTube に到達するたびに Cookie を確認（ログイン完了を検出）
            let dataStore = webView.configuration.websiteDataStore
            dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.hasExtracted else { return }
                let cookieNames = Set(cookies.map(\.name))
                // 必須 Cookie が揃っていなければまだログイン中
                guard requiredCookieNames.isSubset(of: cookieNames) else { return }
                self.hasExtracted = true

                let relevant = cookies.filter {
                    $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
                }
                let cookieString = relevant
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                guard !cookieString.isEmpty else { return }
                DispatchQueue.main.async {
                    AuthState.shared.save(cookies: cookieString, dataStore: dataStore)
                    strixLog("ログイン Cookie 保存完了（\(relevant.count)件）")
                    self.onLoginComplete()
                }
            }
        }

        /// ポップアップを現在の WKWebView にリダイレクト
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
