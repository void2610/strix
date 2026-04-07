//
//  VideoID.swift
//  Strix
//
//  Created by Shuya Izumi on 2026/04/07.
//

import Foundation

/// YouTube の URL または動画 ID 文字列から動画 ID を抽出する
func extractVideoID(from input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)

    // 動画 ID 直接入力（11文字の英数字・ハイフン・アンダースコア）
    let idPattern = /^[a-zA-Z0-9_-]{11}$/
    if trimmed.wholeMatch(of: idPattern) != nil { return trimmed }

    guard let url = URL(string: trimmed),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }

    // https://www.youtube.com/watch?v=XXXXXXXXXXX
    if let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
        return v
    }

    // https://youtu.be/XXXXXXXXXXX
    if url.host == "youtu.be" {
        return url.pathComponents.dropFirst().first.map(String.init)
    }

    // https://www.youtube.com/shorts/XXXXXXXXXXX
    if url.pathComponents.contains("shorts"), let id = url.pathComponents.last {
        return id
    }

    return nil
}
