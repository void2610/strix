//
//  SearchHistory.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/14.
//

import Foundation
import SwiftData

/// 検索履歴を保存するモデル
@Model
final class SearchHistory {
    @Attribute(.unique) var query: String
    var searchedAt: Date

    init(query: String, searchedAt: Date = .now) {
        self.query = query
        self.searchedAt = searchedAt
    }
}
