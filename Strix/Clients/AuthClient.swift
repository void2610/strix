//
//  AuthClient.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import Foundation
import Security
import WebKit

/// YouTube ログイン状態を保持する Observable オブジェクト。
/// アプリ全体で AuthState.shared を共有する。
@Observable
final class AuthState {
    /// YouTube セッションクッキー文字列（nil = 未ログイン）
    var cookieString: String?
    var isSignedIn: Bool { cookieString != nil }

    /// ログイン時に使った WKWebsiteDataStore（同一アプリセッション内でのみ有効）。
    /// アプリ再起動後は nil になるため、クッキーインジェクションにフォールバックする。
    var dataStore: WKWebsiteDataStore?

    static let shared = AuthState()
    private init() {}

    /// Keychain から保存済みクッキーを読み込む（起動時に呼ぶ）
    func loadFromKeychain() {
        cookieString = KeychainHelper.load(key: "yt_cookies")
    }

    /// ログイン完了後にクッキーと DataStore を保存する
    func save(cookies: String, dataStore: WKWebsiteDataStore) {
        cookieString = cookies
        self.dataStore = dataStore
        KeychainHelper.save(key: "yt_cookies", value: cookies)
    }

    /// ログアウト：Keychain とブラウザキャッシュを両方クリアする
    func signOut() {
        cookieString = nil
        dataStore = nil
        KeychainHelper.delete(key: "yt_cookies")
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }
}

// MARK: - Keychain ヘルパー

enum KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        // 既存エントリを削除してから追加
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
