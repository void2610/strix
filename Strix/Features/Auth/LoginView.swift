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
            YouTubeLoginWebView { cookieString in
                AuthState.shared.save(cookies: cookieString)
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

/// Google アカウントページを WKWebView で表示し、ログイン完了後にクッキーを抽出する。
struct YouTubeLoginWebView: UIViewRepresentable {
    let onCookiesExtracted: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesExtracted: onCookiesExtracted)
    }

    func makeUIView(context: Context) -> WKWebView {
        // 非永続ストアを使って既存セッションと切り離しクリーンなログインを提供する
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
        let onCookiesExtracted: (String) -> Void
        /// クッキー抽出を一度だけ行うためのフラグ
        private var hasExtracted = false

        init(onCookiesExtracted: @escaping (String) -> Void) {
            self.onCookiesExtracted = onCookiesExtracted
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasExtracted,
                  let host = webView.url?.host,
                  host.contains("youtube.com") else { return }

            hasExtracted = true

            // ログイン後に youtube.com へ遷移した時点でクッキーを取得する
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let relevant = cookies.filter {
                    $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
                }
                let cookieString = relevant
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                guard !cookieString.isEmpty else { return }
                DispatchQueue.main.async {
                    self.onCookiesExtracted(cookieString)
                }
            }
        }
    }
}
