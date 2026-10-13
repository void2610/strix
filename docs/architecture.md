# アーキテクチャ

## 認証フロー

1. `LoginView` の WKWebView（`.default()` 永続ストア）で Google ログイン
2. YouTube セッション Cookie 取得
3. 必須 Cookie（SID/HSID/SSID）を `AuthClient` で検証後 Keychain 保存
4. デバイス信頼情報は `.default()` ストアで永続保持（再ログイン時 2FA 不要）
5. 起動時に `AuthState.shared.loadFromKeychain()` で復元

`AuthState`（`AuthClient.swift`）はアプリ全体で共有される `@Observable` シングルトン。

## API クライアント戦略

### コンテンツ取得（ContentClient）

Innertube WEB クライアント + Cookie + SAPISIDHASH 認証。

- **ホームフィード**: `/browse`（WEB client）を URLSession で直接呼ぶ
  - `httpShouldSetCookies = false` の ephemeral session でシステム Cookie 上書きを防止
- **検索**: `/search`（WEB client）を直接呼び、ホームと同じパーサーで動画を取り出す（メンバー限定・広告の除外も効く）
  - 続きのトークンは結果末尾の `continuationItemRenderer` から取る。絞り込みチップも `continuationCommand` を持つため、汎用の `extractContinuationToken` では別の絞り込みのページを拾うことがある
  - 続きのページはショートだけで通常の動画が 0 件のことがあるので、1 回の追加読み込みで数ページまで先を試す
  - 再生リスト・コースの lockup は動画として再生できないので検索結果から除く
- **関連動画**: `/next` API から lockupViewModel をパース。同じ応答から説明欄・チャプター・評価の状態・コメント数も取り出し、`WatchNextInfo` にまとめて返す
  - **チャプター**: シークバーのマーカー（`markersMap`）の `DESCRIPTION_CHAPTERS` を、無ければ `AUTO_CHAPTERS` を使う
  - **高評価**: `segmentedLikeDislikeButtonViewModel` の `likeStatusEntity.likeStatus` が状態。件数は未評価時（`defaultButtonViewModel`）と評価時（`toggledButtonViewModel`）の表示が両方入っている。未ログインの応答はボタンに `signInEndpoint` が付くので、そのときはボタンを出さない（`AuthState` を見ないのは、テストで共有のログイン状態を書き換えずに済ませるため）
  - 評価の送信は `/like/like`・`/like/dislike`・`/like/removelike` に `target.videoId` だけを送る
  - **コメント数**: `engagementPanels` のうち `panelIdentifier == "engagement-panel-comments-section"` の見出しの `contextualInfo`
- **チャンネル**: `/browse` でチャンネルページ取得

認証ヘッダー: `Cookie` + `SAPISIDHASH`（`Authorization`）+ `X-Goog-AuthUser: 0`

### ストリーム取得（YouTubeClient）

4段フォールバック:
1. **VISIONOS クライアント**（HLS） — 認証なし・`visitorData` 必須（無いと `LOGIN_REQUIRED`）。PO Token 不要で、SABR 移行済み動画にも `hlsManifestUrl` を返す。「子ども向け」動画は再生不可
2. **IOS クライアント**（HLS） — Cookie + SAPISIDHASH 認証。`hlsManifestUrl` を取得（SABR 移行済み動画では返らない）
3. **WEB クライアント**（combined formats） — Cookie + SAPISIDHASH 認証。`formats` / `hlsManifestUrl` を取得
4. **WebPage**（WKWebView + fetch/XHR インターセプト） — モバイル版 YouTube を読み込み、再生を開始させた後、`googlevideo.com/videoplayback` への fetch/XHR リクエストをフックして署名デコード済み URL を取得。combined format（itag 18/22）を優先

ANDROID_VR（1.65.10）は 2026-08-17 以降、itag18 を含む全フォーマットが 403 になったため再生経路から外した。それ以前から PO Token 未提示のストリームは「先頭約 1 分（2.5MB 前後）だけ取得でき、それより先の Range は 403」になっており、`/player` が URL を返しても再生が途中で止まる。ストリームの可否は URL の有無ではなく末尾まで取得できるかで判定する（`YouTubeClientTests` の結合テスト）。

### コメント・チャプターのパネル（PlayerPanelContainer）

公式クライアントと同じく、動画の下の領域に重ねて開く。`.sheet` を使わないのは、開いている間に背面（動画）を操作できなくなるため。全画面時のチャプター一覧は動画の右側に重ねる。

- 下からの出入りは `.transition(.move(edge:))`。下の領域を `.clipped()` して、パネルが動画の上にはみ出さないようにする
- つまみ・見出しを引いて閉じるほか、一覧に `panelPullToDismiss()` を付けると、一覧の先頭からさらに下へ引いても閉じる。スクロールのはみ出し量（`onScrollGeometryChange`）だけパネルを下げ、一覧の中身は同じ量を打ち消してパネルと一緒に動かす。指を離したとき（`onScrollPhaseChange`）に一定以上はみ出していれば閉じる
- 閉じると決めた後は、一覧の跳ね返りでパネルが引き戻されないよう、パネルの位置だけ止める

### シークサムネイル（Storyboard）

VISIONOS と IOS の `/player` は `storyboards.playerStoryboardSpecRenderer.spec` を返す（WEB / WebPage は返さないので、そのときはサムネイルを出さない）。spec は「URL のひな形|レベル0|レベル1|…」で、各レベルは「幅#高さ#コマ数#列#行#間隔ms#画像名#署名」。

- 一番大きいレベル（多くは 160×90）を使う。レベル 0 は間隔 0 の 1 枚絵なので使わない
- 画像は列×行の格子にコマを並べたもの。コマ番号 = 時刻 ÷ 間隔、画像番号 = コマ番号 ÷（列×行）で、URL の `$L` をレベル、`$N` の `$M` を画像番号に置き換え、`&sigh=署名` を付ける
- 取得した画像は `StoryboardSheetCache` に持ち、同じ画像への同時要求は 1 回の通信にまとめる

### 視聴履歴のアカウント記録（PlaybackTracker）

再生とは別に、`/player` の `playbackTracking` にある URL へ送信して、YouTube アカウントの再生履歴に記録する。

- **履歴に載るのは再生開始の送信**: `videostatsPlaybackUrl` への 1 回の送信で履歴に載る。`videostatsWatchtimeUrl` はどこまで見たかの更新で、これだけでは載らない。そのため再生開始の送信は、失敗したら間隔を空けて送り直し、すぐに別の動画へ移っても取り消さない
- **送信先はログインアカウントに紐づく URL に限る**: VISIONOS / IOS など認証なしのクライアントが返す URL は、Cookie を付けて送っても履歴に残らない。ログイン中は認証付き WEB の `/player` から取得する（`YouTubeClient.resolvePlaybackTracking`）。アカウントに紐づく URL には `uga` パラメータが付く
- **再生開始から切り離す**: 認証付き WEB の `/player` の応答は 200KB を超えるため、`X-Goog-FieldMask: playabilityStatus.status,playbackTracking` で約 3KB に絞り、再生を待たせずに非同期で取得する。以前は VISIONOS の応答から 2 秒で打ち切って認証なしの URL に切り替えていたため、弱い電波では履歴に残らなかった
- **オフライン再生も記録**: 保存済み動画を再生したときも、通信できればアカウント用の URL を取得して送る
- **確認するときの注意**: `FEhistory` の「今日」の区切りは先頭がショートの棚（数百本になることがある）で、通常の動画はその後ろに並ぶ。先頭だけを見ると記録されていないように見える

### 音声のみモード（StreamResourceLoader）

音声のみモードは adaptive の AAC 音声（DASH の断片化 MP4）を `StreamResourceLoader` 経由で再生する。YouTube の DASH ファイルはサンプルを持たない moov の `mvhd` / `tkhd` / `mdhd` にも全体の長さを書いており、AVFoundation はそれを断片の合計に足して尺を約 2 倍（例: 634 秒 → 1269 秒）と解釈する。シークバーが倍の長さになり、実際の終端を過ぎても再生位置が進み続けて自動再生が遅れるため、ローダーが返すバイト列の moov の duration を 0 にして断片の合計だけで尺を数えさせている（`FragmentedMP4`）。moov に `mvex` が無い通常の MP4 は duration が尺そのものなので書き換えない。

### プレイリスト編集（ContentClient）

Innertube `/browse/edit_playlist` エンドポイントで以下の操作を実行：
- `addToPlaylist(playlistId:videoId:)` — 任意プレイリストへの動画追加（`ACTION_ADD_VIDEO`）
- `removeFromPlaylist(playlistId:videoId:setVideoId:)` — プレイリストからの動画削除（`ACTION_REMOVE_VIDEO`、`setVideoId` 必須）

### ミニプレイヤー（PlayerCoordinator + PlayerContainerView）

`PlayerCoordinator`（`@Observable`）がアプリ全体のプレイヤー状態（`.hidden` / `.fullScreen` / `.miniPlayer`）を管理。`RootTabView` で `.environment()` 注入し、どのタブからでも `coordinator.play(videoID:)` で再生開始。

- `PlayerContainerView`: RootTabView のオーバーレイ。フルスクリーンとミニプレイヤーの切替を管理
- ミニプレイヤー: `AVPlayerLayer` ベースの小窓（200×112pt）で映像をリアルタイム表示。最初のフレームが描かれるまで `AVPlayerLayer` は透明なので、下地を黒にしている
- 映像エリアの下スワイプでミニプレイヤーに遷移、タップでフルスクリーン復帰

### アカウント情報（AccountClient）

Innertube WEB client でライブラリ・プレイリスト一覧を取得。

### ダウンロード & オフライン再生（DownloadManager）

`DownloadManager`（`Utilities/`、`@MainActor @Observable` シングルトン）が動画のオフライン保存を管理する。

- **ストリーム選定**: `YouTubeClient.fetchDownloadStream` が VISIONOS（PO Token 不要）の adaptive formats から、H.264 映像（短辺 720 以下で最高画質）と AAC 音声を選ぶ。失敗時は WEB の adaptive formats へフォールバック。音声込みの単一ファイル（itag18/22）は PO Token なしでは取得できなくなったため使わない。HLS はセグメント分割でファイル保存に不向きなため使わない
- **ダウンロード**: googlevideo の open-ended GET はスロットリングされるため、映像と音声をそれぞれ Range リクエストで 5MB チャンクに分割して一時ファイルへ書き出す。YouTube の DASH は moov の長さを補正しないと尺が約 2 倍に解釈されるため（音声のみモードの節を参照）、`FragmentedMP4.correctDurations` で補正してから `AVAssetExportSession`（passthrough、再エンコードなし）で 1 つの mp4 に結合し、`Application Support/StrixDownloads` へ移動。サムネイルもオフライン用に保存する
- **永続化**: `DownloadedVideo`（SwiftData）が状態（`downloading`/`completed`/`failed`）・進捗・相対ファイル名を保持。絶対パスはアプリ再インストールで無効化するため保存しない
- **DI**: `init(baseDirectory:fetchStream:downloadFile:)` でストリーム取得・実ファイル取得・保存先を注入可能にし、テスト時はネットワーク不要のフェイクへ差し替える
- **オフライン再生**: `PlayerViewModel.loadStream` が再生前に完了済みの `DownloadedVideo` を照会し、ローカルファイルが存在すればネットワークを介さずそのまま再生する（`makePlayerItem` は file URL をカスタムスキームで包まずそのまま使う）

## パーサー

| パーサー | 対象 | 関数 |
|---|---|---|
| lockupViewModel（WEB 新形式） | ホーム・関連動画 | `parseLockupViewModel` — チャンネル名/ID は `extractChannelInfo` で再帰探索 |
| videoRenderer（WEB 旧形式） | 検索結果等 | `parseVideoRenderer` |
| videoWithContextModel（IOS 形式） | IOS レスポンス | `parseVideoWithContextData` |
| プレイリスト | LOCKUP_CONTENT_TYPE_PLAYLIST/ALBUM | `parsePlaylistLockups` |
| ミックスリスト | `/next` の playlistPanelVideoRenderer | 専用パーサー |
| 画像 URL | プロトコル相対 URL 補正 | `imageURL(from:)` で `//` → `https:` |

### 一覧から除外する動画

未加入では再生できないメンバー限定動画は、`containsMembersOnlyBadge` で一覧から外す。ログイン中のホーム・関連動画には、次の 2 つの形で現れる。

- **メンバー限定バッジ付き**: `badgeStyle == "BADGE_MEMBERS_ONLY"`（旧形式は `style == "BADGE_STYLE_TYPE_MEMBERS_ONLY"`）。
- **メンバーシップの勧誘枠**: 「YouTube より」(`BADGE_PROMOTED`) と「￥0 で試す」(`BADGE_COMMERCE`) が付き、メンバー限定バッジは付かない。それでも `/player` は UNPLAYABLE（メンバー限定）を返す。そのため `BADGE_PROMOTED` で外す。勧誘枠は取得のたびに入れ替わるので、1 回の取得で出なくても再現しないとは言えない。

`BADGE_COMMERCE` 単独では外さない。映画の「無料、広告あり」にも付き、こちらは再生できるため。

## チャンネルアバター取得

取得元の優先順:
1. `/next` の `videoOwnerRenderer`
2. `/player` の endscreen
3. 関連動画の同一チャンネルから取得

## ボット検出対策

- WebPage フォールバック（WKWebView で YouTube ページを読み込み）
- `BotVerifyView` で手動 CAPTCHA 解決

## 永続化

| データ | 保存先 |
|---|---|
| 視聴履歴（`WatchedVideo`） | SwiftData |
| ダウンロード動画（`DownloadedVideo`） | SwiftData（メタ）+ Application Support/StrixDownloads（実ファイル） |
| ホーム表示プレイリスト（`PinnedPlaylist`） | SwiftData |
| 認証 Cookie | Keychain |
| 再生速度設定 | UserDefaults |
| デバイス信頼情報 | WKWebsiteDataStore `.default()` |

## Live Activity / ダイナミックアイランド

- `StrixActivityAttributes`（`Utilities/`）: メインアプリと Widget Extension で共有される属性定義
- `LiveActivityManager`（`Utilities/`）: Activity の開始・更新・終了を制御
- `StrixWidgetExtension/`: ダイナミックアイランド・ロック画面の UI を実装
