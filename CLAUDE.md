# Sofvo プロジェクト設定メモ

## 再利用メモ・実装ドキュメント
- **浮島型すりガラス・ボトムナビ**（Instagram風／スクロールで縮む／後ろが透ける）の再利用ドキュメント: **`docs/floating_glass_bottom_nav.md`**
  - 実体: `lib/screens/home/main_tab_screen.dart`
  - 別アプリへ流用する場合はこのドキュメント内の「汎用版コード」「別アプリに渡すプロンプト」を使う
  - ハマりどころ: `Scaffold(extendBody:true)` ／ 各画面 `SafeArea(bottom:false)` ／ リスト下パディング ／ FAB持ち上げ ／ ページ背景白（詳細はドキュメント参照）
  - **本物の Liquid Glass の泡（2026-09-25・iPhone実機確認済み）**: 移動中の泡だけ `liquid_glass_widgets` の `AdaptiveGlass` で描く方式。手順・遠回りの記録・コピペ用プロンプトはドキュメントの「★ 本物の Liquid Glass の泡にする」節
  - **別プロジェクトへの共有メモ（2026-06-21）**: 浮島型ボトムナビを他プロジェクトへ流用する際は、この `docs/floating_glass_bottom_nav.md` を**そのまま1ファイル渡せばOK**（汎用版コード＋移植用プロンプト同梱）。実体ファイルやハマりどころの全文も含まれている。

## 開発ルール

### 修正完了時のデプロイ判定ルール
- **修正が完了したら、変更ファイルを「審査必要（ストア再提出）」と「審査不要（即反映）」に分類して報告すること**
- 判定基準:
  - **審査必要**: `lib/**`, `pubspec.yaml`, `android/**`, `ios/**`（Dartコード・ネイティブ設定 → ストア再提出が必要）
  - **審査不要**: `functions/**`, `firestore.rules`, `storage.rules`, `website/**`, `.github/**`（サーバー側・ルール・CI → mainマージで即反映）
- 報告フォーマット例:
  ```
  ✅ 審査不要（即反映）: storage.rules, functions/index.js
  📱 審査必要（ストア再提出）: lib/screens/auth/login_screen.dart
  ```
- **ストア提出手順・AABビルドの案内はユーザーから求められたときのみ行う（毎回自動で案内しない）**

### 審査提出リクエスト時の対応ルール
- **基本の流れ（2026-09-25 決定）: 「テスト版（TestFlight）で確認 → 問題なければ審査に出す」の2段階にする。**
  1. ユーザーが「審査に出したい」と言ったら、**まず TestFlight に上げる**（下記「TestFlight で実機確認」の手順・`ci_beta`）
     - このとき**バージョンは次のリリース番号にしておく**（例: 配信中 `1.0.48+63` → テスト版 `1.0.49+64`）。同じバージョンのまま審査に出せるようにするため
  2. 届いたらユーザーに**確認ポイント**（今回の変更で何を触ってみればよいか）を具体的に伝え、実機で見てもらう
  3. ユーザーから「OK」「問題ない」等の返事が来てから、**ビルド番号だけ +1**（例: `1.0.49+65`）して `ci_release` で審査に出す（リリースノートは実行前に提示して確認を取る）
  4. 問題があれば直して、ビルド番号を +1 してもう一度テスト版を上げる（審査には出さない）
  - **ユーザーが「テスト版は飛ばして」と明示したときだけ**、直接 `ci_release` で審査に出してよい
  - Android はテスト版の仕組みを使っていないので、iOS のテスト版で OK が出たら iOS と同じタイミングで「Build Android AAB」（製品版アップロード）を実行する
- 審査に出す段階では、以下を即座に用意すること：
  1. **`pubspec.yaml`** のバージョンを+1（例: `1.0.5+18` → `1.0.6+19`）
  2. **`ios/fastlane/metadata/ja/`** の説明文・キーワード等も必要に応じて更新（fastlane が自動反映する）
  3. コミット＆プッシュ（mainにマージ）
  4. **CLAUDE.md のバージョン履歴表**に新しい行を追加
- そのうえで、**アシスタント自身がワークフローを実行して提出まで完了させる**（ユーザーに操作を任せる必要はない）:
  - main にマージされたことを確認 → GitHub MCP の `actions_run_trigger`（`run_workflow`）で
    `ios-release.yml` を `ref: main`、`inputs: {lane: "ci_release", release_notes: "..."}` で実行
  - 完了まで見届ける（約40分）。失敗したら Actions のログと成果物 `gym-log` を読んで直し、再実行する
  - ユーザー自身でやりたい場合は下記「iOS 審査提出（GitHub Actions・推奨）」の3クリック手順を案内する
- **審査提出は取り消しが面倒な外向きの操作。ユーザーの明示的な依頼があってから実行すること**（勝手に出さない）
- リリースノートは Fastfile ではなく **ワークフロー実行時の入力（`release_notes`）** に渡す。文面はアシスタントが用意し、実行前にユーザーへ提示して確認を取る
- **ビルド番号（`+` 以降）は一度使うと二度と使えない**（TestFlight に上げただけでも消費される）。提出前に必ず現状より大きい番号にする

### 審査通過時の対応ルール
- 背景: `syncStoreVersions`（Cloud Function・**6時間ごとに自動実行**）が iTunes Lookup API / Google Play ページから
  latestVersionIos・latestVersionAndroid を自動取得して Firestore `config/app` に書き込んでいる。
  つまり**放っておいても最終的には自動反映される**。ただし **Apple 側 iTunes API の CDN キャッシュには
  最大24〜48時間の遅延がある**（Androidの Play 側にはこの遅延はほぼ無い）ため、「審査通過をすぐアプリに反映したい」
  ときだけ、以下の手動オーバーライドで遅延を回避する。
- ユーザーが「審査通過」「審査通った」等のメッセージを送ったら、**今回どちらのOSが通ったかを確認した上で**、以下を即座に実行すること：
  1. **バージョン履歴表**（CLAUDE.md 下部）と **リリース状況**（アプリ化 進捗セクション）を「リリース済み」に更新
  2. **`syncStoreVersionsNow` にバージョン番号を指定して直接 Firestore を更新するURLをユーザーに提示し、ブラウザで開いてもらう**：
     - **iOS/Android を同じバージョンで同時に提出・リリースした場合は、両方のパラメータを必ず一緒に指定すること**
       （片方だけ指定すると、指定しなかった側は最大48時間古い表示のままになる。今回まさにこれで一往復手戻りが発生した）：
       ```
       https://us-central1-sofvo-19d84.cloudfunctions.net/syncStoreVersionsNow?iosVersion=X.Y.Z&androidVersion=X.Y.Z
       ```
     - iOSのみ提出した場合: `?iosVersion=X.Y.Z` のみでよい（Androidは元の値のまま変わらない）
     - この環境（Claude Code on the web）からは egress プロキシの制限で直接 curl できないため、
       **URLをユーザーに提示してブラウザで開いてもらう**運用でよい（無理に自分で叩こうとしない）
     - 返ってきた JSON に `latestVersionIos` / `latestVersionAndroid` の両方が期待通りの値になっているか確認する
  3. コミット＆プッシュ

### fastlane メタデータ自動反映（v1.0.9で導入）
- `ios/fastlane/metadata/ja/` に以下のファイルを配置済み:
  - `description.txt` — App Store 説明文
  - `keywords.txt` — 検索キーワード
  - `promotional_text.txt` — プロモーションテキスト
  - `name.txt` — アプリ名
  - `subtitle.txt` — サブタイトル
  - `support_url.txt` — サポートURL
  - `privacy_url.txt` — プライバシーポリシーURL
- `fastlane release` 実行時に `skip_metadata: false` で自動的にApp Store Connectに反映される
- 説明文やキーワードを変更したい場合は、これらのファイルを編集してコミットするだけでOK
- **`Fastfile` 内でも `git pull` / `flutter clean` / `pod install` 等が実行されるため、手順と一部重複するが問題ない**

### iOS 審査提出（GitHub Actions・推奨）
**2026-08-30 に稼働確認済み。Mac は不要。** アシスタントが iOS 提出を案内するときは必ずこの手順を提示する。

1. **先に `pubspec.yaml` のバージョンを上げて main にマージしておく**（同じビルド番号は再アップロード不可）
2. GitHub → **Actions** タブ → 「**Build iOS & Submit to App Store**」
3. **Run workflow** をクリック
4. 提出先を選ぶ
   - `ci_beta` … TestFlight にアップロードのみ（審査に出さない。動作確認用）
   - `ci_release` … アップロード＋**審査提出まで**
5. `ci_release` のときは「このバージョンの最新情報」欄にリリースノートを入力
6. 完了まで約40分（Flutter ビルド18分＋アーカイブ14分＋アップロード3分）

- 仕組みの詳細・Secrets の一覧: `docs/ios_ci_release.md`
- 失敗時は Actions のログと、成果物 `gym-log`（xcodebuild の生ログ）を見る
- **`ci_release` はアップロード後に Apple のビルド処理待ち（`Waiting for the build to show up in the build list`）が入る。混雑時は1時間近くかかる**（2026-09-25 に48分待って当時の上限90分で打ち切られた→上限を180分に延長）。打ち切られてもビルドは Apple に届いているので、**`ci_submit`（ビルドせず、pubspec のバージョン/ビルド番号の既存ビルドを審査提出だけする。数分で終わる）**を `release_notes` 付きで実行すれば再ビルド不要（App Store Connect のバージョンページでビルドを選んで「審査に提出」しても同じ）
- **Apple は iOS 26 SDK（Xcode 26 以降）でビルドしたバイナリしか受け付けない。** ワークフローはランナー上の最新 Xcode を自動選択するので対応済み
- ランナーは `macos-26`。public リポジトリなので **macOS ランナーは無料**
- 必要な Secrets（登録済み・GitHub に保存されているので再設定不要）:
  `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8_BASE64` / `IOS_DIST_CERT_P12_BASE64` / `IOS_DIST_CERT_PASSWORD`
- **配布用証明書は1年で失効する（今回作成分は 2027-08 頃まで）。** 失効すると CI が署名で失敗するので、
  Xcode → Settings → Accounts → Manage Certificates で作り直し、`.p12` を書き出して
  `IOS_DIST_CERT_P12_BASE64` を更新する（手順は `docs/ios_ci_release.md`）
- 署名の構成: アーカイブは自動署名（`-allowProvisioningUpdates` ＋ APIキー）、
  書き出しのみ `sigh` が取得したプロファイルを明示した手動署名。**この組み合わせでないと通らない**（経緯は `docs/ios_ci_release.md` の表を参照）

### TestFlight で実機確認（テスト版・審査に出さない）
**2026-09-25 に稼働確認済み**（build 64 で泡の Liquid Glass を iPhone 実機確認）。見た目・動きを審査前に自分の iPhone で確かめたいときに使う。
- **Web プレビューやシミュレーターでは判断できないもの**（シェーダー描画・ネイティブ挙動など）は、これで実機確認してから審査に出す
- 手順:
  1. `pubspec.yaml` のビルド番号（`+` 以降）だけ +1 して main にマージ（**TestFlight に上げただけでもその番号は消費される**。審査提出時はさらに +1 する）
  2. `ios-release.yml` を `ref: main`、`inputs: {lane: "ci_beta", release_notes: ""}` で実行（約40分。アシスタントが `actions_run_trigger` で実行・見届けてよい）
  3. 完了後 5〜30分で iPhone の **TestFlight アプリ**に届く → 「アップデート」→「開く」
- **テスター登録済み**: App Store Connect → Sofvo → TestFlight → 内部テスト に info@sofvo.com を登録済み（招待コードは不要。TestFlight アプリの「コードを使う」画面は外部テスター用なので使わない）
- 見分け方: TestFlight アプリの Sofvo 画面の「ビルド NN」表示。**App Store 配信中と同じビルド番号なら中身は旧版**
- テスト版はストアのお客さんには見えない。OK なら同じ内容で**ビルド番号だけ +1** して `ci_release` で審査に出す（流れの全体は「審査提出リクエスト時の対応ルール」を参照）

### iOS（fastlane）審査提出・ローカル手順（Mac・非推奨）
GitHub Actions が使えないときの予備手段。**Mac の Xcode が 26 未満だと Apple に拒否される**ので注意。

```bash
cd ~/Desktop/sofvo
./scripts/app-store-release.sh
```

中身: ① Xcode の古い Archive / DerivedData 削除 → ② `main` を `git pull` → ③ `fastlane release`（`flutter clean`・`pod install`・IPA ビルド・App Store 審査提出まで）

#### 審査提出前ディスク整理（取り入れ済み）
- **まとめて実行**: `./scripts/app-store-release.sh`（上記。通常はこれだけでよい）
- **整理だけしたいとき**: `./scripts/pre-app-store-disk-cleanup.sh`（Archives + DerivedData のみ）
- **手動でさらに空けたいときだけ**: `~/Library/Developer/Xcode/iOS DeviceSupport/` の古い iOS バージョン、Xcode → Settings → Platforms の未使用ランタイム
- **細かく手動でやる場合**（`fastlane` 単体と重複するが可）:
  ```bash
  cd ~/Desktop/sofvo && git checkout main && git pull origin main --rebase
  flutter clean && flutter pub get
  cd ios && rm -rf Pods Podfile.lock && pod install --repo-update && fastlane release
  ```

### ストア提出手順（審査必要な変更がある場合に案内）

#### Android（全自動）
1. GitHub → **Actions** タブ
2. 「**Build Android AAB**」を選択
3. 右側の「**Run workflow**」をクリック
4. 「**Google Play 製品版にアップロード**」に**チェック**を入れる
5. 「**Run workflow**」で実行
- ビルド → Google Play 製品版アップロードまで全自動
- **⚠️ ただし公開は自動ではない（2026-09-26 判明）**: Play Console で「公開の管理」がオンだったため、審査通過後も「**変更を公開**」を押すまで配信されない。1.0.34〜1.0.48 は一度も公開されず、**Android ユーザーは全員 1.0.31 のままだった**（エントリー招待が Android の人に届かない原因にもなっていた）。9/26 に 1.0.49 を手動公開して解消。**同日「管理対象の公開」をオフに変更済み**（以後は審査通過で自動公開）
  - アップロード後は Play Console → リリース（製品版）で状態を確認し、「承認済み」で止まっていたら「公開の概要」→「**変更を公開**」を押す（「公開の管理」をオフにしてあれば自動公開）
  - 「非公開」＝一度も配信されずに次のリリースに置き換わったもの。「100%」の行が実際に配信中のバージョン
  - `syncStoreVersionsNow` に `androidVersion` を手入力するのは、**Play Console で公開（100%）を確認してから**にする（未公開のまま入力すると、更新できないのにアップデート案内が出続ける）

#### iOS（GitHub Actions・全自動）
**案内は「iOS 審査提出（GitHub Actions・推奨）」セクションの手順をそのまま使うこと。**

- 未コミットの変更がある場合は先に `git stash`（未追跡も含めるなら `git stash push -u -m wip`）してから実行し、完了後 `git stash pop`
- **App用パスワード（App-Specific Password）が必要**: `~/.zshrc` に以下を設定済み
  ```bash
  export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD="wilr-bfjb-mhlo-aulp"
  ```
  - Apple Account（info@sofvo.com）→ サインインとセキュリティ → アプリ用パスワード で生成
  - パスワードが無効になった場合は再生成して `~/.zshrc` を更新する

#### 注意事項
- **バージョンコード（pubspec.yaml の `+` 以降の数字）を上げてからmainにマージすること**
- 細かい修正はまとめて1回で提出するのが効率的（審査は数時間〜数日かかるため）

### Cloud Functions を新規追加したときの必須作業（UNAUTHENTICATED 対策）
- **アプリ／Webから呼ぶ関数を新規追加したら、GitHub Actions の「Fix Cloud Functions invoker permissions」を実行し、ワークフロー内の関数リストに新しい関数名を追加すること**
  - Actions タブ → 「Fix Cloud Functions invoker permissions」→ Run workflow
  - ローカルで gcloud を使う場合は `./scripts/fix-function-invokers.sh --fix` でも同じことができる
- 理由: Cloud Functions は**新規作成時はデフォルト非公開**で、`firebase deploy` の権限付与が失敗しても警告だけでデプロイは成功扱いになる（CI のサービスアカウント自体には IAM 設定権限がある。2026-08-29 に上記ワークフローで付与できることを実測確認済み）
- 症状: 関数は存在するのに Google の入口で **403** → アプリ側は赤いスナックバーに **`UNAUTHENTICATED`** と表示される（関数の中の「ログインが必要です」は出ない＝関数に到達していない）
- 既存の関数は一度公開されると更新時に権限が引き継がれるため、**新機能だけが壊れる**という出方をする
- **管理用エンドポイントは公開リストに入れないこと**（誰でも叩けるようになる）
- 確認方法: `curl -s -o /dev/null -w "%{http_code}" -X POST https://us-central1-sofvo-19d84.cloudfunctions.net/<関数名> -H "Content-Type: application/json" -d '{"data":{}}'` → **401 なら正常**（認証チェックまで到達）、**403 なら権限なし**、404 は未デプロイ
- 2026-08-29 に修復済みの関数: createEntryDraft / redeemInvite / respondTeamJoinRequest / distributePoints / broadcastChatMessage / sendOfficialNotification / getPublicProfile / recomputeTournamentPointsNow / recomputeTournamentPointsV2

### 管理エンドポイントは管理者トークン必須（2026-08-29〜）
- `onRequest` の管理用エンドポイントは `assertAdminRequest(req, res)` で **Firebase ID トークン＋`users/{uid}.isAdmin`** を必須にしてある。ブラウザでURLを開くだけでは実行できない
- 対象: updateUserAuth / updateAppConfig / clearVenues / seedVenues / seedNotices / repairCurrentTeams / backfillSearchNorm / recalcFollowCounts / resetDrivePosts / import*FromSheet / sync*ToSheet / getAnalytics / getUserSegments / testWelcomeEmail / runDrivePostNow / syncInstagramNow / driveVideoDebug
- **新しい管理用エンドポイントを追加するときも必ず `assertAdminRequest` を入れること**（入れ忘れると誰でも叩ける）
- 認証なしのままにしてよいのは、アプリ/Webから未ログインでも呼ぶ必要があるものだけ（getPublicProfile / amazonSearch / amazonProduct / syncStoreVersionsNow など）

### 公式アカウント自動投稿の状況（2026-08-29）
- 作業中の事故で `resetDrivePosts` が実行され、Googleドライブ連携の自動投稿 **17件が削除**、`config/driveInstagramSyncState.postIndex` が **0にリセット**された
- 元画像はドライブに残っているため、**通常スケジュール（月・木 20:00 JST に1件ずつ）で最初から再投稿される**（全17件戻るまで約2ヶ月）
- 削除された投稿への いいね／コメントは戻らない

### クロスプラットフォーム統一ルール
- **修正・実装は必ず Android / iPhone / iPad / Web の全プラットフォームで同じ動作になるようにすること**
- プラットフォーム分岐は「Web vs ネイティブ」の2分岐に留める。Android / iOS / iPad で別々のコードパスを作らない
- 認証は Firebase Auth の `signInWithProvider` / `reauthenticateWithProvider`（ネイティブ）と `signInWithPopup`（Web）に統一済み
- ネイティブ固有のSDK（`google_sign_in`, `sign_in_with_apple` 等）は使わない。`firebase_auth` に統一する

## Mac ローカル環境
- **プロジェクトパス**: `~/Desktop/sofvo`
- **Xcodeワークスペース (iOS)**: `~/Desktop/sofvo/ios/Runner.xcworkspace`
- **ユーザー名**: shusuke
- **Mac**: MacBook-Pro-2

## ローカルデータを最新にする手順
```bash
cd ~/Desktop/sofvo
git stash
git pull origin main --rebase
git stash pop
```
- 必ず `cd` でプロジェクトディレクトリに移動してから実行すること
- `git stash` で未コミットの変更を退避してからpullし、`git stash pop` で戻す

## iOS ビルド & App Store Connect アップロード手順

### 前提
- **Xcode**: `ios/Runner.xcworkspace` を使う（`.xcodeproj` ではない）
- **署名**: Automatically manage signing → Team: SHUSUKE NAKAMURA
- **Bundle ID**: com.sofvo.app

### 手順

#### Step 1: コード最新化
```bash
cd ~/Desktop/sofvo
git checkout main
git checkout -- .
git pull origin main --rebase
```
- `unstaged changes` エラー時: `git checkout -- .` でローカル変更を破棄してからpull
- コンフリクト時: `git rebase --abort && git fetch origin main && git reset --hard origin/main`

#### Step 2: Flutter クリーン & 依存関係取得
```bash
flutter clean
flutter pub get
```

#### Step 3: CocoaPods インストール
```bash
cd ios
rm -rf Pods Podfile.lock
pod install --repo-update
cd ..
```
- `Module 'cloud_firestore' not found` → この手順が抜けている可能性大

#### Step 4: Xcode でビルド & Archive
1. `open ios/Runner.xcworkspace` でXcodeを開く
2. 上部のデバイスを **「Any iOS Device (arm64)」** に変更
3. **Product → Clean Build Folder** (Shift+Cmd+K)
4. **Product → Archive** (アーカイブ作成、数分かかる)

#### Step 5: App Store Connect にアップロード
1. Archive完了後 **Organizer** が自動で開く（開かない場合: Window → Organizer）
2. 最新のArchiveを選択 → **Distribute App**
3. **App Store Connect** → **Upload**
4. オプションはデフォルトのまま **Next** → **Upload**
5. アップロード完了まで待つ（数分）

#### Step 6: App Store Connect で審査提出
1. [App Store Connect](https://appstoreconnect.apple.com/) にログイン
2. アプリ「Sofvo」→ 新しいビルドが処理完了するまで待つ（5〜30分）
3. バージョンページでアップロードしたビルドを選択
4. 審査に関する情報を確認（テストアカウント、審査メモ）
5. **審査に提出** をクリック

### バージョン番号の更新（必要な場合）
- **App Storeで承認済み or 配信準備完了のバージョンと同じバージョンでは新ビルドを提出できない**
- 機能追加・バグ修正時はマイナーバージョンを上げる（例: `1.0.2` → `1.0.3`）
- 同じバージョンで再提出する場合、ビルド番号だけ上げればOK（例: `1.0.3+16` → `1.0.3+17`）
```bash
# pubspec.yaml の version を変更
# "+" の前がバージョン、"+" の後がビルド番号
```

### バージョン履歴
| バージョン | ビルド | 状態 | 内容 |
|---|---|---|---|
| 1.0.0 | 5-13 | 承認済み | 初回リリース |
| 1.0.1 | 14 | 配信準備完了 | バグ修正 |
| 1.0.2 | 15 | 配信準備完了 | プッシュ通知・バッジ・タブバー改善 |
| 1.0.3 | 16 | 審査提出済み | 未読カウント修正・ステータスバー白統一・管理メニュー全画面化 |
| 1.0.4 | 17 | 審査提出済み | 公式アカウント・管理者機能・FAQ・紹介リンク・プッシュ通知改善 |
| 1.0.5 | 18 | 審査提出済み | サムネイル・リリースノート自動化 |
| 1.0.6 | 19 | 審査提出済み | アップデートチェック機能・ボタンデザイン統一・ドメイン統一 |
| 1.0.7 | 20 | 審査提出済み | 大会作成フロー改善 |
| 1.0.8 | 21 | 配信準備完了 | 大会編集修正・ヘッダーデザイン統一・エラーハンドリング強化 |
| 1.0.9 | 22 | 審査待ち | App Storeメタデータ大幅改善（説明文充実・キーワード最適化・URL統一） |
| 1.0.10 | ? | 配信準備完了 | （以前のセッションで提出済み） |
| 1.0.11 | 24 | 配信準備完了 | iOSバッジ同期の根本原因修正（build 24 はアップロード済みだが未リリース） |
| 1.0.12 | 26 | リリース済み | 1.0.11 + チャット既読時のバッジ同期レース修正（でも MethodChannel 未登録バグで無効化） |
| 1.0.13 | 27 | 審査提出準備 | **真の根本原因修正**: AppDelegate の MethodChannel 登録を didInitializeImplicitFlutterEngine に移動（1.0.10〜1.0.12 ではバッジ同期コードが一切動いていなかった） |
| 1.0.14 | 28 | 審査提出準備 | お知らせ配信にリンク機能・予約配信・OS別配信対象を追加（バージョン番号が既に使用済みのため 1.0.15 で再提出） |
| 1.0.15 | 29 | リリース済み | お知らせ配信にリンクボタン・予約配信・OS別配信対象（iOS/Android/全員）を追加 |
| 1.0.18 | 32 | リリース済み | チェックイン Universal Links・対戦表生成と大会ステータス・公式向けマイ大会/閲覧・収支修正・大会準備中表記等 |
| 1.0.19 | 33 | リリース済み | 安定性・信頼性の向上、チェックイン・大会運営・収支まわりの細かな改善・利用しやすさの調整 |
| 1.0.20 | 34 | リリース済み | チェックイン強化（sofvo://・掲示QRのPDF/画像エクスポート・カメラから起動）、大会準備中表記の統一、さがす/マイ大会の見え方調整（公式向けなど） |
| 1.0.21 | 35 | リリース済み | 旧ステータス「試合準備中」を「大会準備中」に統一、プロフィールで性別・生年月日を必須化 |
| 1.0.22 | 36 | リリース済み | 公式：タイムライン全表示・他人の大会/募集編集、さがす進行中大会、チェックインQR画像共有修正 |
| 1.0.23 | 37 | リリース済み | チェックインQR「画像で保存」を写真ライブラリへ直接保存するよう修正 |
| 1.0.24 | 38 | リリース済み | 収支管理チーム数修正・収入追加機能（協賛金など） |
| 1.0.25 | 39 | リリース済み | 収支管理の表示エラー修正（再提出） |
| 1.0.26 | 40 | リリース済み | 友達紹介リンクのアプリ直接起動・自動フォロー対応（sofvo://invite・ネイティブでの ref 処理） |
| 1.0.27 | 41 | リリース済み | 新規インストール時の紹介コード引き継ぎ（Android Install Referrer・iOS クリップボード）・Android App Links 有効化 |
| 1.0.28 | 42 | リリース済み | 大会終了後のスコア閲覧・感想投稿再通知・「大会の流れ」終了後非表示 |
| 1.0.29 | 43 | リリース済み | QRチェックイン不具合修正・順位表のチーム名タップでチーム対戦結果表示（セット別得点）・4チームリーグの決勝/3位決定戦スコア入力修正 |
| 1.0.30 | 44 | リリース済み | 大会結果（順位表・チーム対戦結果）の画像保存/シェア機能・ボトムナビをすりガラス調の浮島型デザインに刷新 |
| 1.0.31 | 45 | リリース済み | ボトムナビを浮島型に刷新（下スクロールで縮小・後ろが透けるすりガラス）・各タブ背景を白に統一・FAB/ボタンの重なり解消 |
| 1.0.32 | 46 | リリース済み | ボトムナビ磨き込み（選択カプセルのスライド移動・透過強化・アイコン/文字を黒・位置調整・縮小時のズレ修正） |
| 1.0.33 | 47 | リリース済み | 結果シェア画像の余白を自然化（順位表・チーム対戦結果・Sofvo紹介を均等配置＋下端にブランドフッター） |
| 1.0.34 | 48 | 欠番 | バージョン番号が既に使用済みのため提出不可（1.0.35 で再提出） |
| 1.0.35 | 49 | リリース済み | お知らせ「募集開始」タップで大会詳細へ遷移・大会詳細に閲覧数（主催者のみ：閲覧人数/延べアクセス数）を追加 |
| 1.0.36 | 50 | 審査提出準備 | 進行中大会バナーの不具合修正（公式/管理者で全大会表示）・体験デモ大会が各画面に漏れる問題の修正・ログイン中のデモ起動でアカウントが汚染される不具合の修正 |
| 1.0.37 | 51 | リリース済み | 招待コード基盤を追加（友達紹介・チーム招待・大会招待を共通化）。iOSのクリップボード依存を廃止し、登録画面の招待コード入力で確実に相互フォロー＋チーム参加。未登録メンバーをエントリー画面/チーム管理から招待可能に（1.0.36 の修正も同梱） |
| 1.0.38 | 52 | リリース済み | 大会エントリーを承認制に（選んだメンバー全員が承認して初めて成立・承認待ちは entryDrafts に隔離し既存の対戦表/人数/収支等に影響なし）・チーム招待も承認制（参加リクエスト→オーナー承認）・大会共有ボタンの不具合修正（ネイティブで Uri.base.origin が例外→sofvo.com 直指定）・大会詳細に役割別招待（運営者:キャプテン招待＋メンバー招待／参加者:メンバー招待）・プロフィール編集でも都道府県を必須化 |
| 1.0.39 | 53 | リリース済み | 登録後に「仲間を見つけよう」画面を追加（招待コード入力・同じ地域のプレイヤーのフォロー）・友達さがす強化（カタカナ/ひらがな/大文字小文字/打ち間違いに強い検索・招待コードの発行/共有）・公式アカウントを自動フォロー・大会エントリーのメンバー入れ替えも承認制・プロフィール未入力時の追加入力画面・プロフィール追加入力の表示不具合修正・細かな表示調整と安定性改善 |
| 1.0.40 | 54 | リリース済み | 公式アカウントの画像投稿をスワイプ式カルーセルで表示（比率そのまま）・画像タップで全画面表示＋横スワイプ切替＋×/タップ/下スワイプで閉じる・画像を即表示（フェードなし）。※Googleドライブ連携の公式自動投稿（画像のみ・週次スケジュール）はサーバー側（Functions）で稼働 |
| 1.0.41 | 55 | リリース済み | 友達紹介の招待コードを「入力」から「表示」に変更（自分の招待コードを発行・共有し、相手が登録時に入力すると自動で相互フォロー）・投稿に「いいね」した人の一覧表示・投稿/保存ボタンを上部ヘッダーへ移動・FABとボトムナビの重なり解消などレイアウト調整 |
| 1.0.42 | 56 | リリース済み | 管理者用のユーザー詳細画面に「アカウント削除」機能を追加（isAdmin限定の adminDeleteUser で Firestore＋Auth を一括削除・確認ダイアログ付き。テストアカウント等をアプリ内から削除可能に） |
| 1.0.43 | 57 | リリース済み | 大会要項PDFを正式書式に刷新＋画像(JPG)保存/プレビュー・マイページに「他の人からの見え方」プレビュー・運営チャットボットを会話ごとにオン/オフ（管理者のみ）＋文脈理解と口調を改善・エントリー成立時の重複メンバー再チェック |
| 1.0.44 | 59 | 審査提出済み | タイムラインに公式・フォロー中の投稿が出ないバグを修正（whereIn 30件制限の取りこぼし解消・公式アカウント自動フォローの再試行）。**GitHub Actions から提出した初のバージョン**（build 58 は TestFlight 検証用） |
| 1.0.45 | 60 | リリース済み | エントリーのメンバー選択欄の表記修正・エントリー成立時に参加者へ主催者フォローを自動付与・大会エントリー招待の見逃し対策（起動時ポップアップ・既読/未読表示・重複選択防止）・Android版LINE共有の不具合修正（パッケージ可視性制限） |
| 1.0.46 | 61 | リリース済み | 起動時ポップアップに大会名・日付を追加・公式アカウントにもフォロー/フォロワー数を表示・管理者用ユーザー詳細画面からフォロー/フォロー解除できるように・メンバー検索の表記ゆれ対応・チーム参加リクエストも見逃し防止ポップアップに統合・通知用メールアドレス機能を追加 |
| 1.0.47 | 62 | リリース済み | 大会エントリーの承認待ちドラフトに個別メンバー取り消し・追加招待機能を追加・主催者/編集者向けに承認待ちチーム一覧を表示・間違えて辞退した場合に参加へ戻せるボタンを追加・辞退した人を自動除外して手動取り消しを忘れても成立するように修正 |
| 1.0.48 | 63 | リリース済み | メンバー選択画面に都道府県を表示（同名アカウント誤招待防止）・招待の再通知（ベルアイコン）・キャプテン/主催者/管理者による代理承認機能・アカウント切り替え時に古いユーザー情報を参照し続けるバグを13画面で修正・大会詳細のチームタブでエントリーメンバー確認機能・チャットの大会URLプレビュー表示 |
| 1.0.48 | 64 | TestFlight のみ | ボトムナビの移動中の泡を本物の Liquid Glass に（liquid_glass_widgets・縁の屈折/虹色/横長/押すとガラス化）。実機確認用で審査には未提出。**審査提出時は 1.0.49+65 以降** |
| 1.0.49 | 65 | TestFlight のみ | 1.0.48+63 以降の修正をまとめて実機確認（泡の Liquid Glass・招待の再通知の確認ダイアログ/1時間クールダウン・招待の既読表示・招待通知の対応済み/取り消し済み表示・承認待ちチーム詳細の見た目刷新・代理承認を主催者/管理者のみに・エントリー関連のプッシュ通知）。OKなら 1.0.49+66 で審査提出 |
| 1.0.49 | 66 | 審査提出済み | 1.0.49+65（TestFlight で確認済み）と同じ内容で提出。ボトムナビの泡を本物の Liquid Glass に・招待の再通知に確認ダイアログと1時間クールダウン・招待の既読表示・招待通知の対応済み/取り消し済み表示・承認待ちチーム詳細の見た目刷新・代理承認を主催者/管理者のみに・エントリー関連のプッシュ通知。**Android は 2026-09-26 に Play Console で公開**（1.0.31 以来の配信） |
| 1.0.50 | 67 | TestFlight のみ | 実機確認用。ホームタブに未読バッジ（ベル通知＋お知らせ合計）・エントリー招待通知タップで大会詳細へ遷移・「あなた宛」タブにもエントリー招待を表示・承認待ちエントリーカードを折りたたみ式に（大会詳細が隠れる問題を解消）・お知らせ配信画面に「大会を選んでリンクを自動入力」・大会名が空欄になる通知バグ修正（Functions側は提出不要で反映済み） |
| 1.0.50 | 68 | TestFlight のみ | 1.0.50+67 に追加で実機確認。「あなた宛」タブのエントリー招待カードに送信者アバター（＋種類バッジ）と太字の名前を表示（誰からの招待か一目でわかるように）。OKなら 1.0.50+69 で審査提出 |

### iOS提出時のリリースノート
- **iOSアップロード時は必ず「このバージョンの最新情報」も一緒に出すこと**

### Macローカルでの提出時の注意
- **unstaged changesエラー**: `git checkout -- .` で変更を破棄してからpull
- **`flutter clean && flutter pub get` を必ず実行する**: pubspec.yamlの変更がビルドに反映されない
- **fastlaneがない場合**: Xcodeで手動Archive → Distribute App で提出可能（fastlaneなしでOK）

### 大会の見え方（クイック表・全項目）

一覧の判定は `lib/utils/tournament_status.dart` の `normalizeTournamentStatus` で旧表記を正規化したあとの `status` を前提とする。コードとの差分があれば `lib/screens/tournament/tournament_search_screen.dart` の `_buildTournamentList` を正とし、本節を追従する。

#### 前提・アカウント

| 項目 | 内容 |
|------|------|
| **一般** | `users.isOfficial` が **true でない** |
| **公式** | `isOfficial == true` |
| **正規化後** | 以下の「ステータス正規化」表を適用した `status` で判定 |

#### ステータス正規化（DBの表記ゆれ）

| 正しい値（正規化後） | 吸収する旧値 |
|----------------------|--------------|
| **エントリー締切** | `エントリー締め切` |
| **大会準備中** | `試合準備中`, `試合準備` |
| （その他） | そのまま |

#### さがす — フォロー中／みんな（大会・メンバー募集共通）

| タブ | 一覧に出る主催者／募集者 |
|------|---------------------------|
| **フォロー中** | **フォローしている人** ＋ **自分** |
| **みんな** | **まだフォローしていない人**（自分が主催する大会は「みんな」側の対象外） |

#### さがす — 大会タブ（ステータス × 一般／公式）

| 正規化後の `status` | 一般 | 公式 |
|---------------------|------|------|
| 準備中 | × | ○ |
| 終了（「過去の大会を表示」オフ） | × | ○ |
| 終了（オン） | ○ | ○ |
| 募集中 | ○ | ○ |
| 満員 | ○ | ○ |
| エントリー締切 | × | ○ |
| 大会準備中 | ○ | ○ |
| 開催中 | × | ○（**フォロー中／みんなは無視**・検索・エリア等のフィルターは適用） |
| 決勝中 | × | ○（同上） |
| 順位決定中 | × | ○（同上） |
| 上記以外の文字列 | 上記の×条件に当てはまらなければ一覧に出る（未使用値はコード確認） | 同左（進行中3種以外のステータス除外は行わない） |

（**一般**: **○**＝ステータス条件を満たし、かつ **フォロー中／みんな・種目・エリア・日付・検索** などのフィルターも満たすと一覧に出る。**×**＝大会一覧のフィルターで除外。）  
（**公式**: **開催中・決勝中・順位決定中** は一般と同様に非表示。**それ以外**のステータス（準備中・締切後・終了オフ時の終了など）は除外せず、フォロー中／みんな・種目・エリア・日付・検索のフィルターを満たせば一覧に出る。）

#### さがす — メンバー募集タブ

| 項目 | 内容 |
|------|------|
| 大会の `status` で隠すか | **隠さない**（募集ドキュメント単位） |
| 絞り込み | **フォロー中／みんな** ＋ **検索・エリア・日付・種目** |

#### マイ大会

| 項目 | 一般 | 公式 |
|------|------|------|
| 一覧に載る条件 | 自分が **主催** または **エントリー参加** | **主催のみ**（参加者としての想定なし） |
| 「これから」タブ | `status` が **終了** 以外（正規化後） | 同じ |
| 「これまで」タブ | `status` が **終了**（正規化後） | 同じ |
| 詳細へ渡す `status` 等 | 正規化してから渡す想定 | 同じ |

#### 大会詳細（一般 vs 公式）

| 項目 | 一般 | 公式 |
|------|------|------|
| フォロー案内バナー | フォロー前提の文言 | 閲覧は可能・エントリー等はフォローが必要、といった文言 |
| 下部（メンバー募集／エントリー） | フォロー前提の操作が中心 | 未フォローでも導線を出し、エントリー時にフォロー補完など |
| フォロー状態の同期 | 限定的 | **FollowService と連動** |

#### 実装参照（メモ用）

| 項目 | 参照先 |
|------|--------|
| 正規化 | `lib/utils/tournament_status.dart` の `normalizeTournamentStatus` |
| さがす大会の出し分け | `lib/screens/tournament/tournament_search_screen.dart` の `_buildTournamentList` |

### トラブルシュート

#### 「Command PhaseScriptExecution failed with a nonzero exit code」
最も多いビルドエラー。以下で解決:
```bash
cd ~/Desktop/sofvo
flutter clean
flutter pub get
cd ios && rm -rf Pods Podfile.lock && pod install --repo-update && cd ..
# → Xcodeで Clean Build Folder → Archive
```
それでもダメな場合:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData
```

#### Xcode のディスク容量を減らす
- **審査提出前（推奨・1コマンド）**: `./scripts/pre-app-store-disk-cleanup.sh`（Archives + DerivedData。上記 fastlane 手順の先頭と同じ）
- **プロジェクト内**: リポジトリ直下で `./scripts/clean-xcode-disk.sh`（`flutter clean` と `build/`・`ios/Pods` 等の削除。次回 `cd ios && pod install --repo-update` が必要）
- **DerivedData 全削除**（対話確認付き）: `./scripts/clean-xcode-disk.sh --derived`
- **古いシミュレータ**: `./scripts/clean-xcode-disk.sh --simulators` または `xcrun simctl delete unavailable`
- **手動（任意）**: Xcode → **Window → Organizer** で Archive 削除、`iOS DeviceSupport` の古いバージョン削除、SwiftPM / CocoaPods キャッシュ
- **Mac 全体の掃除**: `./scripts/mac-disk-cleanup.sh`（下記「Mac のディスク掃除」参照）。Xcode だけでなく Adobe キャッシュ等も含めた定期メンテ用

## Mac のディスク掃除（定期メンテナンス）

```bash
cd ~/Desktop/sofvo
git pull origin main --rebase
./scripts/mac-disk-cleanup.sh          # 調べるだけ（何も消さない）
./scripts/mac-disk-cleanup.sh --clean  # 安全なものだけ消す
```

- **半年〜1年に1回でよい**。溜まるのはほぼ Adobe のキャッシュなので、それ以上の頻度は不要
- 消すのは「消えても作り直されるキャッシュ」と「アプリが無いのに残った抜け殻」だけ。書類・写真・メール・メモ・ブックマーク・パスワードには触れない
- 途中で `sudo` のパスワードを聞かれることがある（OS アップデートの残骸を消すとき）。入力しても画面には表示されないが正常
- **PDF マニュアル**: `docs/Mac容量そうじマニュアル.pdf`（ターミナルでの調べ方・減らし方を手順化したもの。元データは `docs/mac-disk-cleanup-manual.html`。修正したら Chromium の `--print-to-pdf` で作り直す）

### 2026-08-30 の実績（空き 16GB → 195GB）

| 消したもの | 削減 |
|---|---|
| `~/Library/Caches/Adobe` | **138GB**（これが原因のほぼ全て） |
| `~/Library/Application Support/Claude/vm_bundles` | 8.6GB |
| Xcode の DerivedData・シミュレータ・iOS DeviceSupport | 8.3GB |
| Android Studio（未使用のため削除） | 3.0GB |
| Chrome のキャッシュ | 2.9GB |
| Cinema 4D 2025 / R22（旧バージョン） | 2.2GB |
| アプリの抜け殻（Zoom / Postman / Genspark 等） | 0.5GB |

### 消してはいけない場所（調査で紛らわしかったもの）

| 場所 | 理由 |
|---|---|
| `~/Library/CloudStorage/GoogleDrive-*` | `du` では 18GB に見えるが**実体はクラウド**。ディスクは使っていない（実使用量は `~/Library/Application Support/Google/DriveFS` で確認。1GB 程度なら正常） |
| `~/Library/Application Support/Google/Chrome` | ブックマーク・保存パスワード。Chrome の設定画面からしか減らさない |
| `~/Library/Containers/com.apple.Notes` | 「メモ」の中身そのもの |
| `~/Library/Metadata` | Spotlight の索引。消しても再作成されるだけで Mac が数時間重くなる |
| `~/Library/Application Support/Adobe` | Adobe 本体が使用中（キャッシュは `~/Library/Caches/Adobe` の方） |
| `/Library`, `/System` | macOS 本体 |

#### 「Module 'xxx' not found」
`pod install` が未実行。Step 3を実行する。

#### Archiveがグレーアウト
デバイスが「Any iOS Device (arm64)」になっていない。シミュレータ選択中はArchiveできない。

#### 「iOS XX.X is not installed」「Unable to find a destination … generic:1, platform:iOS」
- **原因**: `flutter build ipa` / `flutter build ios --release` は **実機向け（iphoneos）** のビルドであり、Xcode が **その iOS バージョン用のデバイス・プラットフォーム**（Settings → **Platforms** / 旧 Components）を要求する。SDK が `-showsdks` に出ていても、プラットフォーム未導入だと同様のエラーになる。
- **ログ例（2026/05）**: `error:iOS 26.5 is not installed` と **接続中の iPhone / iPad**（`arch:arm64e`）および **Any iOS Device** が ineligible → **iPhoneOS 26.5 の「プラットフォーム」本体**が未インストール。USB を複数本挿していても、根本は **Xcode に 26.5 の実機用プラットフォームを入れる**こと。シミュレータ用ランタイムだけ入っていても足りない。
- **エラー文言の「Components」**: 新しい Xcode では **Settings → Platforms**（旧 **Settings → Platforms / Components**）で同じ意味。
- **`xcodebuild -downloadPlatform iOS` の注意**: ログに **Simulator** と出る場合は **シミュレータ用ランタイム**のみ。App Store 用 IPA に必要な **実機ビルド用プラットフォーム**とは別のため、これだけでは直らないことが多い。
- **対処（推奨順）**:
  1. **Xcode → Settings → Platforms** で **iOS 26.5**（エラーに出たバージョン）を **完了までインストール**（一覧に無い場合は Xcode を App Store から最新化）。
  2. ターミナルで `xcodebuild -showsdks` に **`iphoneos26.5`**（または要求バージョン）が出ることを確認。
  3. まだ失敗する場合は **USB の実機を一度外して**から再実行（接続端末の OS が要求ランタイムを引き上げていることがある）。
  4. それでも不可なら、プラットフォームが揃った **別 Mac** または **GitHub Actions 等の CI** で `flutter build ipa` を検討。
- **fastlane 前の Git**: `git stash` 後に `stash pop` で **未コミットの `ios/` 変更**が残ると混乱の元。提出前は `git status` をクリーンにするか、意図した変更だけコミットしてから `fastlane release` すること。
- **手動で `git pull` するとき**（`error: cannot pull with rebase: You have unstaged changes`）: 未追跡の `ios/Podfile.lock` 等があると `git stash` だけでは退避されない。`git stash push -u -m wip` → `git pull origin main --rebase` → `git stash pop`。または `fastlane release` 先頭で同様に `-u` 付き stash を実行（リポジトリの Fastfile を最新化）。

## App Store Connect
- **Bundle ID**: com.sofvo.app
- **Team**: SHUSUKE NAKAMURA
- **Apple Developer アカウント**: Shusuke Nakamura

## Firebase
- **Project ID**: sofvo-19d84
- **Firebase CLI**: `npm install -g firebase-tools --force` でインストール/更新
- **Node**: v25.6.1 / npm 11.9.0（Mac環境）

### Firebase デプロイ（CI で自動化済み・ただし2系統ある）
- **`claude/**` ブランチへの push** → `.github/workflows/auto-merge.yml` が自動発火し、
  mainへの自動マージ ＋ **Hosting（Flutter Web）と Functions のみ**を自動デプロイする
  （変更ファイルの種類で `hosting`/`functions` フラグを判定し、該当する分だけビルド・デプロイする）
- **`firestore.rules` / `firestore.indexes.json` はこの auto-merge.ymlではデプロイされない**。
  コメントに「main push (firebase-deploy.yml) でデプロイ」とあるが、auto-merge.yml のマージ push は
  **GitHub Actions の既定 `GITHUB_TOKEN` で行われるため、他ワークフローの `push` トリガーを起動しない**
  （無限ループ防止のGitHub側の仕様）。そのため **Firestore rules/indexes の変更を含めたときは、
  マージ完了後に `firebase-deploy.yml` を `actions_run_trigger`（`run_workflow`, `ref: main`）で
  手動トリガーすること**（2026-09-22 に実測確認済み。忘れると新しいインデックスが反映されず
  該当クエリが `FAILED_PRECONDITION` で失敗する）
- ワークフロー: `.github/workflows/firebase-deploy.yml`（`push: branches: [main]` が一応トリガーだが、
  上記の理由で人間が直接 `main` に push した場合以外は基本的に自動発火しないと考えて、
  Firestore rules/indexes を変更したら毎回手動トリガーする運用にすること）
- 対象（firebase-deploy.yml）: Functions, Firestore rules/indexes, Storage rules, Hosting（Web ビルド含む）
- シークレット: `FIREBASE_SERVICE_ACCOUNT`（GitHub リポジトリの Secrets に設定済み）

手動デプロイが必要な場合（緊急時のみ）:
```bash
firebase deploy --only storage    # Storage rules のデプロイ
firebase deploy --only firestore  # Firestore rules のデプロイ
firebase deploy --only functions  # Cloud Functions のデプロイ
firebase deploy --only hosting    # Hosting のデプロイ
```

## ドメイン移管（sofvo.com: XServer → ムームードメイン）→ 完了
- **レジストラ**: ムームードメイン（2026/04/03 移管完了）
- **ドメイン**: sofvo.com（利用期限: 2027/09/13）
- **移管費用**: ¥2,154（ムームードメイン） + ¥1,721（XServer特典解除費用）
- **ステータス**: **移管完了**

### 移管後のTODO
- [x] Firebase Hosting にカスタムドメイン `sofvo.com` を追加（SSL接続済み）
- [x] Firebase Auth の承認済みドメインに `sofvo.com` を追加
- [x] Google Cloud Console で OAuth リダイレクトURIに `https://sofvo.com/__/auth/handler` を追加
- [x] `lib/firebase_options.dart` の `authDomain` を `sofvo.com` に変更
- [x] Google Workspace 契約 & MXレコード設定（`info@sofvo.com`）
- [x] DNS設定（ムームードメインのネームサーバー設定）
- [x] コードベース内の `sofvo-19d84.web.app` / `sofvo-19d84.firebaseapp.com` を `sofvo.com` に統一
- [x] SPFレコード統合（Google Workspace + Firebase を1レコードに統合済み）
- [ ] Firebase Auth メールテンプレート用カスタムドメイン認証（DNS反映待ち → 認証後に送信元を `noreply@sofvo.com` に変更）

## アプリ化 進捗（2026/05/18 更新）

### リリース状況
- **iOS**: 🟢 1.0.48 リリース済み（メンバー選択画面に都道府県表示・招待再通知・代理承認機能・アカウント切り替えバグ修正・エントリーメンバー確認機能・チャット大会URLプレビュー）
- **Android**: 🟢 1.0.49 リリース済み（2026-09-26 に Play Console で手動公開。**それまでは 1.0.31 のまま**だった → 下記「Android（全自動）」の注意参照）

### Macローカル環境
- **fastlaneインストール済み**（Ruby 4.0.2 + fastlane 2.232.2）
- iOS提出: **`./scripts/app-store-release.sh`** 1本（「iOS（fastlane）審査提出・推奨手順（Mac）」参照）

## 審査メール自動通知（2026/04/15 稼働開始）

### 概要
`info@sofvo.com` に届く Apple / Google Play からの審査関連メールを
**Google Apps Script** が定期的にスキャンし、`sofvo-dev/sofvo` リポジトリに
GitHub Issue を自動作成する仕組み。Claude Code は GitHub MCP 経由で Issue を
読めるため、審査ステータスを即座に確認して次のアクションに繋げられる。

### 構成
- **スクリプト本体**: `scripts/apps-script/app-review-notifier.gs`
- **セットアップ手順**: `scripts/apps-script/README.md`
- **実行環境**: Google Apps Script（`info@sofvo.com` の Google Workspace 内）
- **定期実行**: 1時間ごとのトリガー
- **対象送信元**: `no_reply@email.apple.com`, `noreply@email.apple.com`, `googleplay-noreply@google.com`, `googleplay-developer-noreply@google.com`
- **重複防止**: Gmail に `AppReview/Processed` ラベルを付与

### 使い方
- 審査メールが届く → 1時間以内に GitHub Issue が自動作成される（ラベル: `app-review`）
- Claude Code に「最近の app-review Issue を見せて」と聞けば取得してくれる
- 審査通過 → CLAUDE.md のバージョン履歴表を「リリース済み」に更新するトリガーにもなる

### メリット
- **新規ツール登録ゼロ**: Google Workspace + GitHub のみ（Zapier などは不要）
- **無料**: Apps Script の無料枠で完結
- **履歴が GitHub に残る**: 審査の流れが Issue として時系列で追える

### トラブルシュート
- Issue が作成されない → Apps Script の「実行数」で実行ログを確認
- 再処理したいメールがある → Gmail で `AppReview/Processed` ラベルを外せばOK
- GitHub Token の期限切れ → Script Properties の `GITHUB_TOKEN` を更新

## スーパーアドミン（最高権限）設定手順
1. [Firebase Console](https://console.firebase.google.com/) を開く
2. プロジェクト **sofvo-19d84** を選択
3. 左メニューの **Firestore Database** をクリック
4. `users` コレクション → 対象ユーザーの **UID** のドキュメントを開く
5. **フィールドを追加** → 名前: `isAdmin`、型: `boolean`、値: `true`
- UIDがわからない場合: Firebase Console の **Authentication → Users** タブでメールアドレスから検索
- `isAdmin: true` を持つユーザーは全大会で主催者権限を持ち、トラブル時に介入可能
- 設定画面のアカウント情報に「権限: 管理者」と表示される（本人のみ）

## 新規登録フロー（2026/03/17 決定）

### メール登録の場合
```
新規登録（メール + パスワード入力）
  ↓
仮登録メール配信（Firebase 自動）
  ↓
メールのURLクリック → Web版に戻る
  ↓
プロフィール設定（ユーザー名など）
  ↓
本登録完了メール（Cloud Functions で送信）
  ↓
アプリ/Web版の案内
```

### Google/Apple 登録の場合
```
サインイン（メール確認不要）
  ↓
プロフィール設定（ユーザー名など）
  ↓
本登録完了メール（Cloud Functions で送信）
  ↓
アプリ/Web版の案内
```

### 実装メモ
- メール登録: Firebase の `sendEmailVerification()` で仮登録メール自動送信
- 本登録完了メール: Cloud Functions の `onUpdate` トリガーでプロフィール保存時に送信
- 現在アプリ未公開のため、案内はWeb版（`https://sofvo-19d84.web.app`）へ誘導

## 認証・セッション管理のバグ（2026/03/17 報告）

### 報告された問題
1. **アカウント切り替えができない**: ログアウト後に別アカウントでログインできない（キャッシュ残留）
2. **LINEで招待リンクを開くと送信者のアカウントにログインされる**

### 原因
1. `signOut()` が Firebase Auth のみサインアウト → Google OAuth セッションが残る
2. LINEアプリ内ブラウザで `localStorage`（`Persistence.LOCAL`）が共有される

### 修正方針
- **`lib/services/auth_service.dart` の `signOut()`**: Google OAuth / Firestore キャッシュもクリアする
- **招待リンク**: LINEアプリ内ブラウザ検出 → 外部ブラウザで開くよう促す
- **優先度**: signOut修正 = 高、招待リンク対策 = 中

## TODO: Google認証画面のドメイン表示を sofvo.com に変更（ドメイン移管完了後）

### 概要
Google OAuth認証画面に `sofvo-19d84.firebaseapp.com` と表示される → `sofvo.com` に変更したい。
**ドメイン移管（XServer → ムームードメイン）完了後に対応する。**

### 手順
1. **Firebase Hosting にカスタムドメインを追加**
   - Firebase Console → Hosting → 「カスタムドメインを追加」→ `sofvo.com` を設定（DNS設定が必要）
2. **Firebase Auth の承認済みドメインに追加**
   - Firebase Console → Authentication → Settings → 「承認済みドメイン」→ `sofvo.com` を追加
3. **Google Cloud Console で OAuth リダイレクトURIを更新**
   - APIとサービス → 認証情報 → OAuth 2.0 クライアントID
   - 承認済みリダイレクトURIに `https://sofvo.com/__/auth/handler` を追加
4. **Firebase の `authDomain` を変更**
   - `lib/firebase_options.dart` の `authDomain` を `sofvo-19d84.firebaseapp.com` → `sofvo.com` に変更

### 前提条件
- [ ] ドメイン移管完了（XServer → ムームードメイン）
- [ ] DNS設定完了

## ウェルカムメール テスト送信（2026/03/19 追加）

### 概要
`testWelcomeEmail` Cloud Function を追加。管理者が任意のメールアドレスにウェルカムメールをテスト送信できる。

### 使い方
```bash
firebase deploy --only functions
firebase functions:shell
> testWelcomeEmail({email: "shusuke1027@gmail.com", nickname: "Shusuke"})
```

### パラメータ
- `email`（必須）: 送信先メールアドレス
- `nickname`（任意）: メール内の宛名（デフォルト: テストユーザー）

### 備考
- 管理者権限（`isAdmin: true`）が必要
- ウェルカムメールのHTMLテンプレートは `sendWelcomeMailTo()` 共通関数に集約済み
- メール内に「詳しくはこちら」→ Welcome LP（`/welcome`）へのリンクあり

## TODO: 将来の改善タスク

- [x] **通知用メールアドレス機能**（2026/09/23 実装）: Apple/Google Sign Inユーザーは認証メールが変更できないため、通知送信先を別途設定できるようにした
  - 設定画面「アカウント」に「通知用メールアドレス」を追加（`settings_screen.dart`）。ステータス表示は「認証済み: xxx」「認証待ち: xxx（メール内のリンクを確認してください）」「未設定」の3状態
  - 確認メール認証フロー: `requestNotificationEmailVerification`（onCall・本人がメール入力→確認メール送信）と`verifyNotificationEmail`（onRequest・メール内リンクから叩かれる、ログイン不要、24時間で失効）
  - 保存先は `users/{uid}` 本体ではなく **`users/{uid}/private/info`**（本人のみ読み書き可）。メールアドレスは個人情報のため、誰でも読める本体ドキュメントには置かない
  - `sendWelcomeEmail` / `sendWelcomeEmailOnUpdate` / `sendAccountDeletedEmail` は共通ヘルパー `resolveNotificationEmail(uid)` で `private/info` の認証済み通知用メールを優先し、無ければ認証メールにフォールバック
  - 新規追加した2関数はアプリ/メールリンクから呼ばれるため `fix-function-invokers.yml` の対象リストに追加済み
- [ ] **大会検索・フィルター機能の強化**: 大会数が増えたら、オンボーディング画面（「大会をさがす」）の検索・絞り込みUIを改善する（地域・日程・レベル等）
- [x] **試合・セットの時間データ記録（進捗データ収集）**: 「1セット/1試合がどのくらいで終わったか」を記録する。後から欲しくなっても過去分は取り戻せないため、収集だけ先行で開始（2026/06/14 実装）。
  - **実装済みの記録フィールド**（すべて `FieldValue.serverTimestamp()` ＝ サーバー時刻）:
    | フィールド | 場所 | 意味／用途 |
    |---|---|---|
    | `startedAt` | 試合ドキュメント（`rounds/{r}/matches/{m}` ・`brackets/{b}/matches/{m}`） | 最初のスコア入力時に1回だけ記録。試合開始時刻 |
    | `completedAt` | 同上 | スコア確定（status→completed）時刻。`completedAt - startedAt` で**試合所要時間** |
    | `setConfirmedAt`（マップ） | 同上 | 各セット確定時刻をセット番号キーで保存（例 `{0: ts, 1: ts}`）。`setConfirmedAt[i] - setConfirmedAt[i-1]`（先頭は `startedAt`）で**1セットの所要時間**。※ serverTimestamp は配列内に書けないため `sets` 配列とは別マップにしている |
    | `completedAt`（ラウンド） | ラウンドドキュメント（`tournaments/{id}/rounds/{round}`） | ラウンド全試合完了時刻。ラウンド全体の進行時間 |
  - **算出例（後から自由に分析可能）**: 試合時間・セット時間・コート回転率（同コートの前試合 `completedAt` → 次試合 `startedAt`）・進行遅延・チェックイン→試合開始リード（既存 `checkedInAt` との差）。
  - **実装箇所**: `lib/screens/tournament/score_input_screen.dart` の `_autoSave()`（startedAt）/`_recordSetConfirmedAt()`（setConfirmedAt）/`_saveResult()`（completedAt・ラウンド completedAt）。
  - **注意**: 必ずサーバー時刻で記録（クライアント端末時計は設定でズレるため統計に使えない）。`startedAt` はローカルフラグで二重書き込みを防止。

  - **追加で記録するデータ（2026/06/14 実装・①②④）**:
    | フィールド | 場所 | 意味／用途 |
    |---|---|---|
    | `outcome` | 試合ドキュメント | 結果種別。通常確定は `'normal'`、棄権・不戦勝は `'walkover'`、両者不在は `'noShow'`。**棄権を通常の0-25と区別**し順位・統計の歪みを防ぐ。主催者が AppBar の旗アイコン（開催中のみ表示）から記録 |
    | `confirmedBy` | 同上 | 初回にスコアを確定したユーザーの uid（監査）。修正では上書きしない |
    | `editCount` | 同上 | スコア修正回数（初回0、再確定ごとに +1） |
    | `lastEditedBy` / `lastEditedAt` | 同上 | 最後に確定/修正した uid・サーバー時刻 |
    | `editLog`（配列） | 同上 | 修正履歴。各要素 `{by, at(Timestamp.now()), prevResult, prevSets, newResult/newOutcome}`。※ serverTimestamp は配列に書けないためクライアント時刻 |
    | `wentLiveAt` | 大会ドキュメント（`tournaments/{id}`） | ステータスが「開催中」に切り替わった実時刻（サーバー時刻）。予定時刻 `date`+`matchStartTime`（既存・永続）との差で**進行開始の遅延**を算出 |
    - **棄権/不戦勝の順位反映**: 不戦勝側に `setsA/B = 必要セット数`・敗者0、`totalPoints` は0-0。`noShow` は勝者なし（`winner: '引き分け'`）・セット0-0。
    - **実装箇所（追加分）**: `score_input_screen.dart` の `_showSpecialOutcomeDialog()`/`_recordSpecialOutcome()`（outcome）・`_saveResult()`（confirmedBy/editCount/editLog）、`tournament_management_screen.dart` の `_showStatusDialog()`（wentLiveAt）。
  - **遅延分析メモ（④）**: 予定開始は `tournaments/{id}` の `date`+`matchStartTime` に既に保存済み（取り返せるデータ）。実開始は `wentLiveAt`（大会全体）と各試合 `startedAt`。per-match の予定時刻スケジューリング機能は未実装（必要なら別途）。

  - **未実装（必要になったら次段階）**: 試合の実出場メンバー（選手単位・入力負担あり）、セットの「開始」時刻を入力開始トリガで別途取る（現状は確定時刻のみ）。
  - **デプロイ区分**: 入力が `lib/` 配下のため**ストア再提出が必要**（Firestore ルールは `rounds/brackets` 配下・`tournaments` ともに `allow write: if isAuthenticated()` でフィールド制限なし → ルール変更不要）。
