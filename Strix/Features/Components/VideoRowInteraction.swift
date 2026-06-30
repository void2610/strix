//
//  VideoRowInteraction.swift
//  Strix
//

import SwiftUI

extension View {
    /// 動画行に「タップ=再生・長押し=コンテキストメニュー」を統一して付与する。
    /// List 内では Button + .contextMenu だと長押しが Button に吸われて効かないため、
    /// 全コンテナで contentShape + onTapGesture に揃える。
    func videoRowInteraction(
        video: VideoItem,
        onDismiss: (() -> Void)? = nil,
        onRemoveFromPlaylist: (() -> Void)? = nil,
        onTap: @escaping () -> Void
    ) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .contextMenu {
                VideoContextMenu(
                    video: video,
                    onDismiss: onDismiss,
                    onRemoveFromPlaylist: onRemoveFromPlaylist
                )
            }
    }
}
