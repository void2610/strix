import CoreGraphics
import Foundation

/// シークバー用のサムネイルを格子状に並べた画像（/player の `playerStoryboardSpecRenderer.spec`）
struct Storyboard: Equatable {
    /// `$L`（レベル）と `$N`（画像名）を含む URL のひな形
    let baseURL: String
    let level: Int
    /// 1 コマの大きさ（px）
    let frameWidth: Int
    let frameHeight: Int
    /// コマの総数
    let frameCount: Int
    let columns: Int
    let rows: Int
    /// 1 コマが表す時間（ミリ秒）
    let intervalMilliseconds: Int
    /// 画像名のひな形（`$M` が画像の通し番号になる）
    let nameTemplate: String
    let signature: String

    /// spec は「URL|レベル0|レベル1|…」で、各レベルは「幅#高さ#コマ数#列#行#間隔ms#画像名#署名」。
    /// 一番大きいレベルを使う。レベル 0 は間隔が 0 の 1 枚絵なので除く。
    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        var best: (level: Int, fields: [String], width: Int)?
        for (index, levelSpec) in parts.dropFirst().enumerated() {
            let fields = levelSpec.components(separatedBy: "#")
            guard fields.count >= 8,
                  let width = Int(fields[0]),
                  let interval = Int(fields[5]), interval > 0 else { continue }
            if best == nil || width > best!.width {
                best = (index, fields, width)
            }
        }
        guard let best,
              let height = Int(best.fields[1]),
              let count = Int(best.fields[2]), count > 0,
              let columns = Int(best.fields[3]), columns > 0,
              let rows = Int(best.fields[4]), rows > 0,
              let interval = Int(best.fields[5]) else { return nil }
        baseURL = parts[0]
        level = best.level
        frameWidth = best.width
        frameHeight = height
        frameCount = count
        self.columns = columns
        self.rows = rows
        intervalMilliseconds = interval
        nameTemplate = best.fields[6]
        signature = best.fields[7]
    }

    /// 指定時刻のコマが載っている画像の URL と、画像内での位置（px）
    func frame(at seconds: Double) -> (sheetURL: URL, rect: CGRect)? {
        let raw = Int(max(0, seconds) * 1000) / intervalMilliseconds
        let index = min(raw, frameCount - 1)
        let perSheet = columns * rows
        let sheet = index / perSheet
        let position = index % perSheet
        let name = nameTemplate.replacingOccurrences(of: "$M", with: String(sheet))
        let urlString = baseURL
            .replacingOccurrences(of: "$L", with: String(level))
            .replacingOccurrences(of: "$N", with: name)
            + "&sigh=" + signature
        guard let url = URL(string: urlString) else { return nil }
        let rect = CGRect(
            x: (position % columns) * frameWidth,
            y: (position / columns) * frameHeight,
            width: frameWidth,
            height: frameHeight
        )
        return (url, rect)
    }
}
