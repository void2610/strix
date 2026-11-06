import QuartzCore

/// 画面の更新ごとに値を進める。指で引くときと同じく状態を直接書き換えるので、SwiftUI のアニメーションに乗らない
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var duration: Double = 0
    private var update: ((Double) -> Void)?
    private var completion: (() -> Void)?

    var isRunning: Bool { link != nil }

    /// update には 0〜1 の進み具合（減速をかけたもの）が渡る
    func start(duration: Double, update: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        finish()
        self.duration = duration
        self.update = update
        self.completion = completion
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// 動いている途中なら最後の位置まで進めて終える
    func finish() {
        guard link != nil else { return }
        update?(1)
        let completion = completion
        stop()
        completion?()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        update = nil
        completion = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let progress = Self.easedProgress(elapsed: link.targetTimestamp - startTime, duration: duration)
        if progress >= 1 {
            finish()
        } else {
            update?(progress)
        }
    }

    /// 経過時間を、終わりに向けて減速する 0〜1 の進み具合にする
    nonisolated static func easedProgress(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(max(elapsed / duration, 0), 1)
        return 1 - pow(1 - t, 3)
    }
}
