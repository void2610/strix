import SwiftUI
import UIKit

/// 決まった向きに引いたときだけ動くパン操作。
/// SwiftUI の DragGesture はボタンの上から引き始めると追従を受け取らないまま終了だけを受け取ることがあるため、UIKit のパン操作を使う。
struct DirectionalPanGesture: UIGestureRecognizerRepresentable {
    enum Direction {
        case down, right
    }

    let direction: Direction
    var isEnabled = true
    /// 引いた量と速さ（向きの軸に沿った値、画面全体の座標）
    var onChange: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> DirectionalPanRecognizer {
        let recognizer = DirectionalPanRecognizer()
        recognizer.direction = direction
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: DirectionalPanRecognizer, context: Context) {
        recognizer.direction = direction
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: DirectionalPanRecognizer, context: Context) {
        // 引いている部分自身が動くため、動かない画面全体の座標で測る
        let t = recognizer.translation(in: nil)
        let v = recognizer.velocity(in: nil)
        let translation = direction == .down ? t.y : t.x
        let velocity = direction == .down ? v.y : v.x
        switch recognizer.state {
        case .began, .changed:
            onChange(translation, velocity)
        case .ended, .cancelled:
            onEnd(translation, velocity)
        default:
            break
        }
    }
}

/// 引き始めの向きが指定と違えば失敗し、シークバーの横の操作などを奪わないパン操作
final class DirectionalPanRecognizer: UIPanGestureRecognizer {
    var direction: DirectionalPanGesture.Direction = .down
    private var startLocation: CGPoint?
    /// 向きを判定するまでの移動量
    private let decisionDistance: CGFloat = 8

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        startLocation = touches.first?.location(in: nil)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start = startLocation, let point = touches.first?.location(in: nil) {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if hypot(dx, dy) >= decisionDistance {
                let along = direction == .down ? dy : dx
                let across = direction == .down ? dx : dy
                if along <= abs(across) {
                    state = .failed
                    return
                }
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        startLocation = nil
    }
}
