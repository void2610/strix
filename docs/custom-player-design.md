# カスタムプレイヤー 詳細設計

**目標:** 現状の `AVPlayerViewController` ベース実装を、YouTube iOS 純正風の自作プレイヤーに置き換える。PiP は後工程。

---

## 1. スコープ

### 含める（MVP）
- `AVPlayerLayer` ベースの映像表示
- タップでオーバーレイ表示 / 3 秒で自動フェード
- 中央: 再生/停止、10 秒スキップ ×2
- 下部: シークバー（つまみ）、現在時刻 / 総時間
- 右上: `⋯` メニュー（倍速・ループ・自動再生・音声のみ）
- 右上: フルスクリーン切替（横回転）
- プレイリスト再生時の前/次ボタン（中央）
- ダブルタップで左右 10 秒スキップ（YouTube 風波紋エフェクト）
- バックグラウンド再生継続

### 含めない
- PiP（後工程・Phase 5）
- AirPlay / 字幕 / 画質切替
- 輝度・音量スワイプ

---

## 2. ファイル構成

```
Strix/Features/Player/
├─ PlayerView.swift                    既存（外側メニュー削除、playerSection 差し替え）
├─ PlayerViewModel                     既存（変更なし）
├─ PlayerContainerView.swift           既存（変更なし）
├─ PlayerCoordinator.swift             既存（変更なし）
│
├─ CustomPlayer/                       新規ディレクトリ
│   ├─ CustomPlayerView.swift          プレイヤー本体（映像 + オーバーレイ統合）
│   ├─ PlayerLayerView.swift           AVPlayerLayer の UIViewRepresentable
│   ├─ PlayerOverlayView.swift         全オーバーレイの配置
│   ├─ PlayerTopBar.swift              上部（戻る / タイトル / ⋯ / フルスクリーン）
│   ├─ PlayerCenterControls.swift      中央（再生/停止・10秒スキップ・前/次）
│   ├─ PlayerBottomBar.swift           下部（シークバー・時刻）
│   ├─ PlayerSeekBar.swift             シークバー単体（DragGesture）
│   ├─ PlayerSettingsMenu.swift        ⋯ メニュー（倍速選択・トグル群）
│   ├─ PlayerDoubleTapSkipOverlay.swift ダブルタップ波紋
│   ├─ PlayerOverlayController.swift   表示制御（@Observable）
│   └─ PlayerBackgroundObserver.swift  バックグラウンド処理（旧 _PlayerViewController 相当）
```

- **分割の理由:** 各領域を独立させておくと、後で PiP ボタン追加・AirPlay 追加の際に該当ファイルだけ触れば済む
- **ディレクトリで隔離:** 既存 PlayerView と混ざらないようにする

---

## 3. 状態モデル

### 3-1. `PlayerOverlayController`（新規 `@Observable`）

オーバーレイの表示/非表示と自動フェードタイマーを一元管理する。`CustomPlayerView` から見ると「このフラグを見てオーバーレイを出す」だけで済むように。

```swift
@MainActor
@Observable
final class PlayerOverlayController {
    var isVisible: Bool = true
    var isScrubbing: Bool = false          // シークバー操作中
    var isSettingsOpen: Bool = false       // ⋯ メニュー展開中
    var skipRipple: SkipRipple? = nil      // 左右ダブルタップの波紋状態

    struct SkipRipple: Identifiable {
        let id = UUID()
        let side: Side                     // .left / .right
        let amount: Int                    // 累積秒（連続ダブルタップで加算）
    }

    private var fadeTask: Task<Void, Never>?

    func tapped() { isVisible ? hide() : show() }
    func show() { /* isVisible = true, scheduleFade() */ }
    func hide() { /* isVisible = false, fadeTask?.cancel() */ }

    /// シーク中・設定展開中はフェードさせない
    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled,
                  !self.isScrubbing, !self.isSettingsOpen else { return }
            self.hide()
        }
    }
}
```

### 3-2. `CustomPlayerView` の `@State`

```swift
@State private var controller = PlayerOverlayController()
@State private var currentTime: Double = 0    // 再生位置（秒）
@State private var duration: Double = 0       // 総時間（秒）
@State private var isPlaying: Bool = false    // rate > 0 を反映
@State private var isBuffering: Bool = false  // isPlaybackLikelyToKeepUp の反転
@State private var isLandscape: Bool = false  // フルスクリーン状態
```

- `currentTime` / `duration` は `AVPlayer.addPeriodicTimeObserver` で 0.25 秒間隔に更新
- `isPlaying` / `isBuffering` は KVO で `player.rate` / `currentItem.isPlaybackLikelyToKeepUp` を監視

---

## 4. View 階層

```
CustomPlayerView (ZStack)
├─ PlayerLayerView                        ← AVPlayerLayer（映像）
│
├─ Color.black.opacity(controls ? 0.35 : 0)  ← オーバーレイ背景（フェード）
│
├─ PlayerOverlayView (isVisible 判定で opacity 制御)
│   ├─ PlayerTopBar        (.top leading/trailing)
│   ├─ PlayerCenterControls (.center)
│   └─ PlayerBottomBar     (.bottom)
│
├─ PlayerDoubleTapSkipOverlay (ダブルタップ波紋)
│
└─ BufferingIndicator (isBuffering 時のみ中央)
```

**透過制御:** `controller.isVisible` を `.opacity(controller.isVisible ? 1 : 0)` + `.animation(.easeInOut(duration: 0.2))` で束ねる。

---

## 5. 各領域の仕様

### 5-1. 上部バー `PlayerTopBar`

```
┌──────────────────────────────────────────┐
│ ⌄  [タイトル (1 行省略)]          ⋯  ⛶  │
└──────────────────────────────────────────┘
```

- 左: 下矢印（ミニプレイヤー化）→ 既存の `coordinator.minimize()`
- 中央: タイトル（`vm.videoInfo?.title`）
- 右: `⋯` ボタン（設定メニュー）、`⛶` フルスクリーン切替
- 背景: `LinearGradient(.black.opacity(0.6) → .clear)`

### 5-2. 中央コントロール `PlayerCenterControls`

```
                  ⏮    ⏯    ⏭                   (プレイリスト時のみ ⏮ ⏭ を表示)
                 (前)  再生  (次)

              ↺10    ▶    10↻                   (通常再生時)
```

- **プレイリスト再生時:** `vm.playlistQueue.isEmpty == false` → 前/再生/次の 3 ボタン
- **通常再生時:** 10 秒戻る / 再生 / 10 秒進む
- 中央ボタン: 60pt、左右: 44pt
- タップ領域: 最小 44pt 確保

### 5-3. 下部バー `PlayerBottomBar`

```
 0:12                                        3:45
 ━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━━━
```

- 左端: 現在時刻（`mm:ss` or `h:mm:ss`）
- 右端: 残り時刻 / 総時間（タップで切替、永続化は不要）
- 中央: `PlayerSeekBar`（詳細は 5-4）
- 背景: `LinearGradient(.clear → .black.opacity(0.6))`

### 5-4. シークバー `PlayerSeekBar`

```swift
// 簡略化
GeometryReader { geo in
    ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.3)).frame(height: 3)
        Capsule().fill(.white).frame(width: geo.size.width * progress, height: 3)
        Circle().fill(.white).frame(width: 14)
            .offset(x: ...)
            .opacity(isScrubbing ? 1 : (isVisible ? 0.8 : 0))
    }
    .gesture(
        DragGesture(minimumDistance: 0)
            .onChanged { controller.isScrubbing = true; pendingTime = ... }
            .onEnded { player.seek(to: pendingTime); controller.isScrubbing = false }
    )
}
```

- **スクラブ中は currentTime 更新を停止**（= `PeriodicTimeObserver` からの更新を無視するフラグ）
- スクラブ中のみ `.frame(height: 5)` に太くする（フィードバック）
- YouTube 風のサムネプレビューは MVP 外

### 5-5. `⋯` メニュー `PlayerSettingsMenu`

`Menu` で実装（標準の iOS メニュー UI が使える）。

```swift
Menu {
    // 倍速（入れ子メニュー）
    Menu("再生速度") {
        Picker("倍速", selection: binding) {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                Text("\(r)×").tag(r)
            }
        }
    }
    // トグル群
    Toggle("ループ再生", isOn: isLoopingBinding)
    Toggle("自動再生", isOn: autoPlayNextBinding)
    Toggle("音声のみ", isOn: isAudioOnlyBinding)
    Divider()
    Button("共有", systemImage: "square.and.arrow.up") { ... }
} label: {
    Image(systemName: "ellipsis")
}
```

- `Menu` 展開中は `controller.isSettingsOpen = true` をセットしてフェードを抑止
- Picker の選択値が変わったら `vm.playbackRate` に反映

### 5-6. ダブルタップ左右スキップ `PlayerDoubleTapSkipOverlay`

YouTube 風の丸い波紋エフェクト。

```
左半分ダブルタップ → -10 秒
右半分ダブルタップ → +10 秒
連続タップで累積（-10, -20, -30 ...）
```

- 左右半分にそれぞれ透明 `Color.clear.contentShape(Rectangle())` を置き、`onTapGesture(count: 2)` を付ける
- タップ位置から半円状のアニメーションを描画（`.mask(Circle().scale(progress))`）
- **シングルタップとの衝突回避:** `.highPriorityGesture(TapGesture(count: 2))` + `TapGesture(count: 1)` の順で定義

---

## 6. ジェスチャー衝突の整理

既存の下方向ドラッグ（ミニプレイヤー化）と新規ジェスチャーの共存。

| レイヤー | ジェスチャー | 効果 |
|---|---|---|
| 最前面 | ダブルタップ左右 | ±10 秒スキップ |
| 次 | シングルタップ（プレイヤー背景） | オーバーレイ表示/非表示 |
| 次 | 下方向 DragGesture（既存） | ミニプレイヤー化 |
| 最奥 | 映像本体 | タップ透過 |

**優先度の確定方法:**
- ダブルタップを `highPriorityGesture` で
- シングルタップは `simultaneousGesture` にせず、`onTapGesture(count: 1)` を使う（SwiftUI が自動で遅延判定する）
- 下方向ドラッグは `DragGesture(minimumDistance: 20)` + `y > x` 判定。**左右方向の動きは吸収しない**よう既存のまま維持
- シークバーの DragGesture は別領域（下部のみ）なので衝突しない

---

## 7. 既存コンポーネントとの結線

### 7-1. `PlayerViewModel` への変更

**最小限に留める。** 以下のメソッドを追加のみ:

```swift
// 任意の速度をセット（既存 togglePlaybackRate は残す）
func setPlaybackRate(_ rate: Float) {
    playbackRate = rate
    player?.rate = rate
}

// 任意秒にシーク
func seek(to seconds: Double) {
    let t = CMTime(seconds: seconds, preferredTimescale: 600)
    player?.seek(to: t)
}

// ±10 秒
func skipForward(_ seconds: Double = 10) { ... }
func skipBackward(_ seconds: Double = 10) { ... }
```

### 7-2. `PlayerView.swift` の変更

- **削除:** 外側のコントロールボタン群（`playerControlButton`、ループ・自動再生・音声のみ・倍速・共有）
- **差し替え:** `playerSection` の中で `AVPlayerLayerView` → `CustomPlayerView(vm: vm, videoID: videoID)` に
- **残す:** 下方向スワイプジェスチャー（`playerSection` に付いている）、ScrollView 内のタイトル・コメント・関連動画

### 7-3. `AVPlayerLayer` + バックグラウンド再生

現状の `_PlayerViewController.didEnterBackground` の仕組みを `PlayerBackgroundObserver` に移植:

```swift
@MainActor
final class PlayerBackgroundObserver: ObservableObject {
    weak var playerLayerView: PlayerLayerUIView?
    private let player: AVPlayer
    private var wasPlaying = false

    init(player: AVPlayer) {
        self.player = player
        NotificationCenter.default.addObserver(...)
    }

    @objc func didEnterBackground() {
        wasPlaying = player.rate > 0
        playerLayerView?.detachPlayer()   // AVPlayerLayer.player = nil
        if wasPlaying { player.play() }
    }
    @objc func willEnterForeground() {
        playerLayerView?.attachPlayer(player)
        if wasPlaying { player.play() }
    }
}
```

**`AVPlayerLayer.player = nil` でも同じ効果が得られるか？** → `AVPlayerLayer` と `AVPlayerViewController` は内部実装が異なる可能性があるため、**初回実装時に実機検証**。効かない場合の代替策: `AVPlayer.automaticallyWaitsToMinimizeStalling = false` + `AVAudioSession.setCategory(.playback)` の組み合わせで対応する。

### 7-4. `NowPlayingManager` / `LiveActivityManager` / `PlaybackTracker`

**完全に既存のまま。** ViewModel が保持する `AVPlayer` は同じオブジェクト。

---

## 8. フルスクリーン切替

```swift
@State private var isLandscape = false

// 右上ボタン
Button {
    isLandscape.toggle()
    // AppDelegate or Window で向きを強制
} label: {
    Image(systemName: isLandscape
        ? "arrow.down.right.and.arrow.up.left"
        : "arrow.up.left.and.arrow.down.right")
}
```

**実装方式:**
- iOS 16+ の `UIWindowScene.requestGeometryUpdate` を使う
- フルスクリーン時は `PlayerContainerView` 側で `dragOffset` を無効化、ScrollView のコンテンツを非表示、プレイヤーを画面全体にアスペクト比無視で拡大
- ステータスバー非表示（`.statusBarHidden(isLandscape)`）
- `PlayerCoordinator` に `isFullScreen: Bool` を追加し、`RootTabView` 側で `TabView` を裏に隠すかを判定

**注意:** `PlayerContainerView` が持つ `NavigationStack` / タブバー表示との整合性確認が必要。フルスクリーン中にチャンネルページに遷移しないようにする（フルスクリーン中は遷移系 UI を隠す）。

---

## 9. 段階的移行ステップ

壊さずに進めるためのロードマップ。

### Phase 1: 最小のカスタムプレイヤーを並走可能に
1. `PlayerLayerView`（`AVPlayerLayer` ラッパー）作成
2. `CustomPlayerView` 作成（映像表示のみ、コントロールなし）
3. `PlayerView.playerSection` に feature flag で切替
4. シミュレータでバックグラウンド再生維持を確認

### Phase 2: コントロール実装
5. `PlayerOverlayController` + `PlayerOverlayView` 空実装
6. タップで表示/非表示
7. 中央の再生/停止ボタン
8. 下部シークバー（時刻表示 + DragGesture）

### Phase 3: 完成度を上げる
9. 10 秒スキップ（ボタン + ダブルタップ波紋）
10. 上部バー（戻る・タイトル・`⋯`）
11. `⋯` メニュー（倍速 / ループ / 自動再生 / 音声のみ）
12. フルスクリーン切替
13. プレイリスト前/次ボタン
14. バッファリング表示

### Phase 4: 置き換え
15. 既存 `AVPlayerLayerView` と `_PlayerViewController` を削除
16. 既存の外側コントロールボタン群を削除
17. 実機検証

### Phase 5（将来）
- PiP
- AirPlay
- 字幕
- 画質切替

---

## 10. リスクと検証項目

| リスク | 検証方法 | 対策 |
|---|---|---|
| `AVPlayerLayer.player = nil` のバックグラウンド自動停止回避が効かない | Phase 1 で実機検証 | `AVAudioSession` 設定の強化 + `play()` の明示呼び出し |
| ダブルタップとシングルタップの衝突で反応が遅い | Phase 3 で体感確認 | `highPriorityGesture` で順序固定、タップ判定遅延は許容 |
| スクラブ中の時刻表示ちらつき | Phase 2 で確認 | `isScrubbing` フラグで `PeriodicTimeObserver` からの更新を無視 |
| フルスクリーン時の NavigationStack 衝突 | Phase 3 で確認 | `isFullScreen` 中は他の UI を `.zIndex(-1)` + 無効化 |
| KVO 解放忘れによるメモリリーク | deinit でログ出力しつつ手動検証 | `CustomPlayerView` に `.onDisappear` 明示記述 |
| 既存 PlayerCoordinator のドラッグ offset と干渉 | Phase 1 時点で確認 | ドラッグ衝突が出たら領域分離 |

---

## 11. テスト方針

### 新規ユニットテスト対象
- `PlayerOverlayController` のフェードタイマー挙動（スクラブ中は抑止される等）
- `PlayerViewModel.setPlaybackRate` / `skipForward` / `skipBackward`

### 既存テストへの影響
- `PlayerViewModel` のインターフェース変更は追加のみ → 既存テストはそのまま通る想定
