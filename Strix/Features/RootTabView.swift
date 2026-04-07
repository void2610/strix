//
//  RootTabView.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/08.
//

import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("ホーム", systemImage: "house.fill") {
                HomeView()
            }
            Tab("検索", systemImage: "magnifyingglass") {
                SearchView()
            }
        }
    }
}
