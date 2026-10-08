import Foundation

/// YouTube の DASH（断片化 MP4）は空の moov にも全体の長さを書き、AVFoundation が断片の合計と足して約 2 倍の尺にするため、moov 側の長さを 0 にして断片だけで数えさせる
enum FragmentedMP4 {

    /// ファイル先頭からの応答で対象範囲を一度だけ特定し、Range ごとに分かれて届く以降の応答にも同じ補正を掛ける
    struct DurationCorrector {
        private var ranges: [Range<Int64>]?

        mutating func correct(_ data: Data, at offset: Int64) -> Data {
            if ranges == nil, offset == 0 {
                ranges = FragmentedMP4.durationFieldRanges(inHeader: data)
            }
            guard let ranges, !ranges.isEmpty else { return data }
            return FragmentedMP4.zeroing(ranges, in: data, at: offset)
        }
    }

    /// 断片化 MP4 でなければ空配列、header が moov 全体を含まず判定できなければ nil を返す
    static func durationFieldRanges(inHeader header: Data) -> [Range<Int64>]? {
        let bytes = [UInt8](header)
        guard let moov = boxes(in: bytes, from: 0, to: bytes.count).first(where: { $0.type == "moov" }) else { return nil }
        guard moov.end <= bytes.count else { return nil }
        let children = boxes(in: bytes, from: moov.bodyStart, to: moov.end)
        // 通常の MP4 は moov の duration が尺そのものなので、0 にすると再生が壊れる
        guard children.contains(where: { $0.type == "mvex" }) else { return [] }

        var ranges: [Range<Int64>] = []
        for child in children {
            switch child.type {
            case "mvhd":
                ranges.append(contentsOf: durationField(of: child, in: bytes, v0Offset: 16, v1Offset: 24))
            case "trak":
                for trakChild in boxes(in: bytes, from: child.bodyStart, to: child.end) {
                    if trakChild.type == "tkhd" {
                        ranges.append(contentsOf: durationField(of: trakChild, in: bytes, v0Offset: 20, v1Offset: 28))
                    } else if trakChild.type == "mdia" {
                        for mdiaChild in boxes(in: bytes, from: trakChild.bodyStart, to: trakChild.end) where mdiaChild.type == "mdhd" {
                            ranges.append(contentsOf: durationField(of: mdiaChild, in: bytes, v0Offset: 16, v1Offset: 24))
                        }
                    }
                }
            default:
                break
            }
        }
        return ranges
    }

    static func zeroing(_ ranges: [Range<Int64>], in data: Data, at offset: Int64) -> Data {
        let dataRange = offset..<(offset + Int64(data.count))
        var result = data
        for range in ranges where range.overlaps(dataRange) {
            let lower = Int(max(range.lowerBound, dataRange.lowerBound) - offset)
            let upper = Int(min(range.upperBound, dataRange.upperBound) - offset)
            result.replaceSubrange((result.startIndex + lower)..<(result.startIndex + upper), with: repeatElement(0, count: upper - lower))
        }
        return result
    }

    // MARK: - box 解析

    private struct Box {
        let type: String
        let bodyStart: Int
        let end: Int
    }

    /// to を超えて宣言された末尾の box もそのまま返す（moov が途中で切れているかの判定に使う）
    private static func boxes(in bytes: [UInt8], from: Int, to: Int) -> [Box] {
        var result: [Box] = []
        var offset = from
        let limit = min(to, bytes.count)
        while offset + 8 <= limit {
            var size = Int(readUInt(bytes, at: offset, length: 4))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var headerSize = 8
            if size == 1 {
                guard offset + 16 <= limit else { break }
                size = Int(readUInt(bytes, at: offset + 8, length: 8))
                headerSize = 16
            } else if size == 0 {
                size = to - offset
            }
            guard size >= headerSize else { break }
            result.append(Box(type: type, bodyStart: offset + headerSize, end: offset + size))
            offset += size
        }
        return result
    }

    /// FullBox の version に応じた duration フィールドの範囲（v0 は 4 バイト、v1 は 8 バイト）
    private static func durationField(of box: Box, in bytes: [UInt8], v0Offset: Int, v1Offset: Int) -> [Range<Int64>] {
        guard box.bodyStart < box.end, box.bodyStart < bytes.count else { return [] }
        let isVersion1 = bytes[box.bodyStart] == 1
        let start = box.bodyStart + (isVersion1 ? v1Offset : v0Offset)
        let end = start + (isVersion1 ? 8 : 4)
        guard end <= box.end, end <= bytes.count else { return [] }
        return [Int64(start)..<Int64(end)]
    }

    private static func readUInt(_ bytes: [UInt8], at offset: Int, length: Int) -> UInt64 {
        bytes[offset..<(offset + length)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
