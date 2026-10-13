import SwiftUI

/// 動画の下（全画面時は右側）に重ねて開くパネルの外枠。つまみ・角丸・影を付け、外側へのスワイプで閉じる。
struct PlayerPanelContainer<Content: View>: View {
    let title: String
    /// 見出しの横に薄く出す補足（コメント数など）
    var subtitle: String?
    /// パネルが出入りする辺（縦画面は下、全画面は右）
    let edge: Edge
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    /// つまみ・見出しを引いている量
    @State private var dragOffset: CGFloat = 0
    /// 一覧の先頭から下へ引いている量（スクロールのはみ出し量）
    @State private var pullOffset: CGFloat = 0
    /// パネルを下げる量。閉じると決めた後は、一覧の跳ね返りでパネルが引き戻されないよう止める
    @State private var panelPullOffset: CGFloat = 0
    @State private var isClosing = false

    /// 閉じると判定する引き量と、指を離したときの勢いを含めた予測移動量
    private let closeDistance: CGFloat = 120
    private let closePredictedDistance: CGFloat = 260
    /// 一覧のはみ出しはゴムの抵抗で縮むため、見出しを引くときより短い量で閉じる
    private let pullCloseDistance: CGFloat = 70

    private var isBottom: Bool { edge == .bottom }

    var body: some View {
        VStack(spacing: 0) {
            header
                .gesture(dismissDrag)
                .zIndex(1)
            Divider()
                .zIndex(1)
            content()
                // 一覧のはみ出しでパネルごと下げる間、中身は一覧の中で下がった分を打ち消してパネルと一緒に動かす
                .offset(y: -pullOffset)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .environment(\.panelPullHandler, isBottom ? pullHandler : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        // 影は背景の形にだけ付ける（パネル全体に付けると中の文字ごとに影がにじむ）
        .background {
            background
                .clipShape(shape)
                .shadow(color: .black.opacity(0.18), radius: 10, x: isBottom ? 0 : -2, y: isBottom ? -3 : 0)
        }
        .offset(x: isBottom ? 0 : dragOffset, y: isBottom ? dragOffset + panelPullOffset : 0)
    }

    private var header: some View {
        VStack(spacing: 0) {
            if isBottom {
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
            }
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
        }
        .contentShape(Rectangle())
        .background { background }
    }

    @ViewBuilder
    private var background: some View {
        if isBottom {
            Color(.systemBackground)
        } else {
            // 全画面では動画の上に重なるため、背後が透ける素材にする
            Rectangle().fill(.regularMaterial)
        }
    }

    private var shape: UnevenRoundedRectangle {
        isBottom
            ? UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, style: .continuous)
    }

    private var dismissDrag: some Gesture {
        // 引いている見出し自身がパネルと一緒に動くため、動かない画面全体の座標で測る（自身の座標だと引くたびに基準がずれて振動する）
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let t = isBottom ? value.translation.height : value.translation.width
                // 閉じる向きは指に追従し、逆向きは抵抗を付けて少しだけ動かす
                dragOffset = t > 0 ? t : -sqrt(-t) * 2
            }
            .onEnded { value in
                let t = isBottom ? value.translation.height : value.translation.width
                let predicted = isBottom ? value.predictedEndTranslation.height : value.predictedEndTranslation.width
                if t > closeDistance || predicted > closePredictedDistance {
                    onClose()
                } else {
                    withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                }
            }
    }

    private var pullHandler: PanelPullHandler {
        PanelPullHandler(
            onPull: { pull in
                pullOffset = pull
                if !isClosing { panelPullOffset = pull }
            },
            onRelease: { pull in
                guard pull > pullCloseDistance else { return }
                isClosing = true
                onClose()
            }
        )
    }
}

/// パネル内の一覧から外枠へ、先頭より下に引いた量を伝える
struct PanelPullHandler {
    let onPull: (CGFloat) -> Void
    let onRelease: (CGFloat) -> Void
}

extension EnvironmentValues {
    @Entry var panelPullHandler: PanelPullHandler?
}

extension View {
    /// パネル内のスクロールする一覧に付け、先頭からさらに下へ引いたときにパネルを下げて閉じられるようにする
    func panelPullToDismiss() -> some View {
        modifier(PanelPullToDismissModifier())
    }
}

private struct PanelPullToDismissModifier: ViewModifier {
    @Environment(\.panelPullHandler) private var handler

    func body(content: Content) -> some View {
        content
            // 項目が少なく一覧が画面に収まるときも、先頭から引けるようにする
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, pull in
                handler?.onPull(pull)
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                guard oldPhase == .interacting, newPhase != .interacting else { return }
                let geometry = context.geometry
                handler?.onRelease(max(0, -(geometry.contentOffset.y + geometry.contentInsets.top)))
            }
    }
}
