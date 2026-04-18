//
//  RootTabView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI

struct RootTabView: View {
    @State private var playerCoordinator = PlayerCoordinator()

    var body: some View {
        ZStack {
            TabView {
                Tab("ホーム", systemImage: "house.fill") {
                    HomeView()
                }
                Tab("検索", systemImage: "magnifyingglass") {
                    SearchView()
                }
                Tab("アカウント", systemImage: "person.crop.circle") {
                    AccountView()
                }
            }

            if playerCoordinator.mode != .hidden {
                PlayerContainerView()
            }
        }
        .environment(playerCoordinator)
    }
}
