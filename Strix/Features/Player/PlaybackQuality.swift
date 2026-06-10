//
//  PlaybackQuality.swift
//  Strix
//

import Foundation

/// 再生画質の上限設定。
/// AVPlayerItem.preferredPeakBitRate に変換して HLS のレンディション選択を制御する。
/// 通信量を抑えたい時にユーザーが上限を選べるようにする。
enum PlaybackQuality: String, CaseIterable, Identifiable {
    case auto
    case hd720
    case sd480
    case dataSaver

    var id: String { rawValue }

    /// メニュー表示名
    var displayName: String {
        switch self {
        case .auto:      return "自動"
        case .hd720:     return "720p"
        case .sd480:     return "480p"
        case .dataSaver: return "データセーバー"
        }
    }

    /// AVPlayerItem.preferredPeakBitRate に設定する値（0 は無制限 = 自動）
    var preferredPeakBitRate: Double {
        switch self {
        case .auto:      return 0
        case .hd720:     return 2_500_000
        case .sd480:     return 1_200_000
        case .dataSaver: return 300_000
        }
    }

    // MARK: - 永続化

    static let userDefaultsKey = "playbackQuality"

    /// UserDefaults に保存された画質設定を返す（未保存・不正値は .auto）
    static var saved: PlaybackQuality {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let quality = PlaybackQuality(rawValue: raw) else { return .auto }
        return quality
    }
}
