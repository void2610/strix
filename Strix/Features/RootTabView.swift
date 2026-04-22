//
//  RootTabView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI

struct RootTabView: View {
    @State private var playerCoordinator = PlayerCoordinator()
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("ホーム", systemImage: "house.fill", value: 0) {
                    HomeView()
                }
                Tab("検索", systemImage: "magnifyingglass", value: 1) {
                    SearchView()
                }
                Tab("アカウント", systemImage: "person.crop.circle", value: 2) {
                    AccountView()
                }
            }
            // フルスクリーン時はタブバーを隠して画面全体を黒背景にする
            .toolbarVisibility(playerCoordinator.isFullScreen ? .hidden : .visible, for: .tabBar)

            if playerCoordinator.mode != .hidden {
                PlayerContainerView()
            }
        }
        .environment(playerCoordinator)
        .statusBarHidden(playerCoordinator.isFullScreen)
        .onChange(of: selectedTab) { _, newTab in
            playerCoordinator.selectedTab = newTab
        }
    }
}
