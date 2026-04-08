//
//  StrixWidgetExtensionBundle.swift
//  StrixWidgetExtension
//
//  Created by Shuya Izumi on 2026/04/08.
//

import WidgetKit
import SwiftUI

/// Widget Extension のエントリーポイント。
/// Live Activity（ダイナミックアイランド・ロック画面）のみを含む。
@main
struct StrixWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        StrixLiveActivityWidget()
    }
}
