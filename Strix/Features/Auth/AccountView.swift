//
//  AccountView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI

/// アカウントタブ。未ログイン時はログイン促進UI、ログイン済み時はアカウント情報を表示する。
struct AccountView: View {
    @State private var showLogin = false
    private let authState = AuthState.shared

    var body: some View {
        NavigationStack {
            if authState.isSignedIn {
                signedInView
            } else {
                signedOutView
            }
        }
    }

    // MARK: - ログイン済み画面

    private var signedInView: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YouTubeアカウント")
                            .font(.headline)
                        Text("ログイン済み")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                Button(role: .destructive) {
                    authState.signOut()
                } label: {
                    Label("ログアウト", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - 未ログイン画面

    private var signedOutView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("YouTubeにログイン")
                    .font(.title2.bold())
                Text("ログインするとあなたのおすすめ動画や\n視聴履歴に基づいたコンテンツが表示されます")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                showLogin = true
            } label: {
                Label("Googleでログイン", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)

            Spacer()
        }
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showLogin) {
            LoginView {}
        }
    }
}
