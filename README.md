# Kindle Capture for Windows / macOS
Kindleのページを自動送りしながら連番PNGを保存し、透明OCRテキスト付きPDFを作成します。

Version 3.0.0でWindows専用構成からWindows/macOS共通構成へ移行しました。
Version 3.1.0では、カーソルを本文に合わせると緑枠が画面境界へ自動吸着し、1回クリックで確定する範囲指定を復元しました。
Version 3.2.0では、スクリーンショットの保存形式をPNGへ変更しました。PDF内でも可逆圧縮を使い、文字や細い線をJPEG圧縮で劣化させません。
Version 3.3.0では、PNG保存とページ描画待ちを並行化し、確認済み画面の再取得とPDF化時の再圧縮を省く高速化を追加しました。

> 初めて使う方は「[ダウンロードするファイル](#ダウンロードするファイル)」から順に進めてください。Windows/macOSとも、最初は2ページだけ保存する動作確認手順を用意しています。

## 対応状況

| 機能 | Windows 10/11 | macOS 12以降 |
|---|---:|---:|
| Kindleウィンドウの選択 | ✓ Win32 | ✓ Core Graphics |
| カーソル自動指定・1クリック確定 | ✓ 子ウィンドウ境界 | ✓ アクセシビリティ境界 |
| 自動ページ送り・方向判定 | ✓ | ✓ |
| 変化・重複・鮮明度判定 | ✓ | ✓ |
| 連番PNG・A4 PDF | ✓ | ✓ |
| OS標準OCR | Windows OCR | Apple Vision |
| F12・停止ボタン | ✓ | ✓ |
| スリープ抑止 | Win32 | `caffeinate` |
| ネイティブ配布物 | `.exe` | `.app` |

GUI、画像判定、PNG/PDF生成、設定、ログは共通です。画面取得、キー送信、OCR、スリープ抑止だけをOS別バックエンドへ分離しています。

## 主な機能

- 選択したウィンドウとプロセスIDを照合し、別アプリの誤キャプチャを防止
- カーソル位置の本文領域へ緑枠を自動吸着し、1回クリックで確定（ドラッグ不要）
- 領域を検出できなければKindleのクライアント領域へ自動フォールバック
- 確定した本文範囲を比率で保持し、ウィンドウ移動・拡大縮小へ追従
- 160×120の画面特徴量によるページ変化・重複・最終ページ判定
- ラプラシアン輪郭強度による低解像度の仮表示・ぼやけ待ち
- `Turbo` / `Balanced` / `Safe` の速度モード
- 左右のページ送り方向を自動判定
- スクリーンショットをPNGで保存し、画素を維持した可逆圧縮でPDFへ格納
- PNG保存と次ページの描画待ちを並行処理（保存待ちは1枚まで）
- RGB PNGの圧縮データを再利用し、PDF作成時の展開・再圧縮を省略
- Windows OCRまたはApple Visionによる透明OCRテキスト
- 途中停止時も保存済み画像からPDFを作成
- `capture-session.json` と `capture-error.txt` による復旧情報
- 保存済み画像からのPDF再作成
- GUIとコマンドラインの両方に対応

## ダウンロードするファイル

初めて使う場合は、Pythonの設定が不要な「配布版」をおすすめします。[最新のReleases](https://github.com/masoniana/kindle-capture/releases/latest)から自分のOS用ZIPをダウンロードしてください。開発途中の動作確認版は「Actions > Build applications」のArtifactsにもあります。

配布ZIPには、この初期設定だけを抜き出した `FIRST_RUN.txt` も同梱されます。

| パソコン | ダウンロードするファイル |
|---|---|
| Windows 10/11（通常のIntel/AMD PC） | `KindleCapture-Windows.zip` |
| Apple Silicon Mac（M1/M2/M3/M4など） | `KindleCapture-macOS-arm64.zip` |
| Intel Mac | `KindleCapture-macOS-x86_64.zip` |

Macの種類が分からない場合は、画面左上のAppleメニュー  から「このMacについて」を開きます。「チップ」にApple Mシリーズが表示されれば `arm64`、「プロセッサ」にIntelと表示されれば `x86_64` です（[Appleの確認方法](https://support.apple.com/ja-jp/116943)）。

GitHubの「Code > Download ZIP」で入手できるのは配布アプリではなくソースコードです。こちらを使う場合は、後述の「ソースコードから起動」を参照してください。

## Windows：ダウンロード後の初期設定

配布版ではPythonも管理者権限も不要です。

1. Kindle for PCをインストールし、Amazonアカウントへサインインします。
2. ダウンロードした `KindleCapture-Windows.zip` を右クリックし、「すべて展開」を選びます。ZIPの中から直接起動しないでください。
3. 展開先の `KindleCapture.exe` をダブルクリックします。
4. Windows SmartScreenで「WindowsによってPCが保護されました」と表示されることがあります。このGitHubリポジトリから入手したファイルであることを確認した場合だけ、「詳細情報」>「実行」を選びます。SmartScreen自体を無効にする必要はありません。
5. Kindle for PCで本を開き、Kindle Captureの「更新」を押します。「Kindleウィンドウ」に本のウィンドウが表示されれば初期設定完了です。

SmartScreenは、インターネットから取得した認知度の低いアプリについて警告するWindowsの保護機能です（[Microsoftの説明](https://support.microsoft.com/en-us/office/protect-my-pc-from-viruses)）。入手元を確認できないファイルでは警告を回避しないでください。

### Windows OCRの準備

日本語OCRを使う場合は、Windowsの「設定 > 時刻と言語 > 言語と地域」に日本語を追加しておきます。OCR開始時に「OCR言語 ja-JP がWindowsにありません」と表示された場合は、日本語の「言語のオプション」から言語機能をダウンロードし、Kindle Captureを再起動してください。OCRをオフにしても、画像入りPDFは作成できます。

### Windowsで起動できないとき

- ZIPを展開したフォルダへ書き込みできるか確認します。通常は「ダウンロード」または「ドキュメント」内で問題ありません。
- セキュリティソフトが隔離した場合は、ファイルの入手元を再確認してください。保護機能を恒久的に無効化することは推奨しません。
- Kindleウィンドウが一覧にない場合は、Kindleで本を開いた状態にして「更新」を押します。最小化されたウィンドウは先に元へ戻してください。

## macOS：ダウンロード後の初期設定

配布版ではPythonは不要です。初回だけGatekeeperの確認と、2種類の権限設定が必要です。

1. Kindle for Macをインストールし、Amazonアカウントへサインインします。
2. Macの種類に合うZIPをダウンロードして展開します。Actionsから入手した場合は、外側のArtifact ZIPと、その中の `KindleCapture-macOS-*.zip` の2回展開が必要なことがあります。
3. 展開された `Kindle Capture.app` を「アプリケーション」フォルダへ移動します。
4. `Kindle Capture.app` をダブルクリックします。「開発元を確認できない」または「Appleは悪質なソフトウェアかどうかを検証できない」と表示された場合は、いったんダイアログを閉じます。
5. Appleメニュー  >「システム設定」>「プライバシーとセキュリティ」を開き、下へスクロールしてKindle Captureの「このまま開く」を押し、もう一度「開く」を選びます。これはこのアプリだけを例外登録する操作で、Mac全体の保護を無効にするものではありません（[Appleの手順](https://support.apple.com/ja-jp/102445)）。
6. Kindle Captureを起動し、求められた次の権限を許可します。

   - 「画面収録」または「画面収録とシステムオーディオ録音」：Kindleの本文画像を取得するため
   - 「アクセシビリティ」：Kindleを前面にして左右矢印を送るため

7. 権限ダイアログが出ない場合は、「システム設定 > プライバシーとセキュリティ」で上記2項目を開き、`Kindle Capture` をオンにします。
8. 権限変更後はKindle Captureを完全に終了し、もう一度起動します。Kindleで本を開き、「更新」を押して本のウィンドウが表示されれば初期設定完了です。

「このアプリは破損しているため開けません」と表示された場合は、セキュリティを解除するコマンドを実行せず、ZIPを削除してこのリポジトリから再ダウンロードしてください。会社・学校が管理しているMacでは、管理者が権限変更を制限している場合があります。

## 最初の動作確認（Windows/macOS共通）

いきなり本全体を処理せず、最初は2〜3ページで確認します。

1. Kindleで本を開き、キャプチャを始めたいページを表示します。
2. Kindle Captureの「Kindleウィンドウ」で本のウィンドウを選びます。
3. 「画面部分を自動指定」を押し、Kindle本文にカーソルを合わせます。緑枠が本文の画面境界へ吸着したら、1回クリックして確定します。ドラッグや追加の確認ボタンは不要です。検出できない場合はクライアント領域が緑枠になります。`Esc`でキャンセルできます。
4. 「保存ページ数」を `2`、「ページ送り」を `Right` または `Left` にします。
5. 保存先を確認して「キャプチャ開始」を押します。開始後は終了するまでKindle以外を操作しません。
6. 保存先の `captures_日時` フォルダに `page_00001.png`、`page_00002.png` とPDFができていることを確認します。

文字が欠ける、ページ方向が逆、画像がぼやける場合は、本番前に範囲・方向・速度を調整してください。

## ソースコードから起動

ソース版ではPython 3.10以降と、初回セットアップ時のインターネット接続が必要です。Pythonは [python.org](https://www.python.org/downloads/) 版を推奨します。

### Windowsのソース版

1. GitHubの「Code > Download ZIP」からソースをダウンロードし、「すべて展開」します。
2. 展開したフォルダの `run_windows.cmd` をダブルクリックします。
3. 初回は `.venv` の作成と依存パッケージのインストールが自動で行われます。完了するとGUIが開きます。

### macOSのソース版

ソースを展開したフォルダでターミナルを開き、次を実行します。

```zsh
chmod +x run.command build_macos.command
./run.command
```

初回は `.venv` の作成と依存パッケージのインストールが自動で行われます。Homebrew版PythonでTkinterが見つからない場合は、`brew install python-tk` を実行してください。画面収録とアクセシビリティでは、システム設定に表示された `ターミナル`、`Python`、または `Kindle Capture` を許可し、許可後に一度終了して起動し直します。

## 共通の使い方

1. Kindleでキャプチャを始めるページを開き、ツールバーやメニューを閉じます。
2. 「Kindleウィンドウ」で本文を表示しているウィンドウを選びます。
3. 「カーソル自動指定」を使う場合は「画面部分を自動指定」を押します。Kindle本文へカーソルを移動すると、その位置を含む大きな画面部品の境界へ緑枠が吸着するので、本文に合った状態で1回クリックします。未指定のまま開始した場合も自動指定画面が開きます。
4. 保存ページ数を指定します。`0`なら、同じ画面が指定回数続くまで実行します。
5. 最初のページから始める場合はページ送りを `Auto` にできます。途中ページからなら `Right` または `Left` の手動指定が安全です。
6. 「キャプチャ開始」を押した後は、Kindle以外を操作しないでください。
7. `F12`（Macではキーボード設定により `fn` + `F12`）または「停止」で終了できます。

キャプチャ中の停止は、保存済みPNGからPDFを作って終了します。PDF/OCR中にもう一度停止するとPDF作成を中止し、PNGだけを残します。

保存先には実行ごとの `captures_YYYYMMDD_HHMMSS` フォルダが作られます。

処理は「本文をスクリーンショット → 連番PNG保存 → PNGをまとめてPDF作成」の順です。PNGとPDF内の画像は同じ画素数を保ち、PDFへの格納時にJPEGへ変換したり縮小したりしません。OCRはPNGを読み取り、PDFに透明テキストを重ねます。速度モードを変えてもPNGの画質は変わりません。

自動指定はWindowsではKindleの子ウィンドウ、macOSではアクセシビリティから取得した本文側の画面部品を使います。検出できないKindleのバージョンでは、タイトルバーなどを除いたクライアント領域を自動選択します。フォールバックした範囲は確定前の画面内に表示されます。選択中にKindleの位置やサイズが変わった場合は、もう一度指定してください。

## 速度調整

- まず `Turbo`、高解像度待ち `350 ms` で試します。
- 文字がぼやける場合は、高解像度待ちを `500〜900 ms` へ増やします。
- ページアニメーション途中の画像が残る場合は `Balanced`、さらに残る場合は `Safe` にします。
- 画面の変化を検出できない場合だけ、最大待ちを `3000〜5000 ms` に増やします。
- 最終ページで止まらない場合は類似判定を少し大きくし、異なるページを同一扱いする場合は小さくします。

### Version 3.3.0の高速化

追加の設定変更は不要です。PNGの画質、OCRの認識精度、高解像度待ち、連続した安定画面の確認回数は変更していません。

- 取得した画面を独立した画像として保持し、PNG保存中に次ページの描画を待ちます。未完了の保存は1枚までなので、長い本でも画像がメモリに溜まり続けません。
- ページ変化・安定・鮮明度の確認が成功した場合だけ、その確認に使った画面を保存に再利用します。タイムアウトした場合は従来どおり再取得します。
- 通常のRGB PNGは圧縮済みデータをPDFへ直接格納します。画素数・色・細い線は変えません。透過・インターレースなどの特殊なPNGは従来の可逆変換へフォールバックし、旧版のJPEGも読み込めます。
- PDF作成では次の1枚の画像準備をOCRと並行処理します。OS標準OCR自体は同じスレッド・同じ精度で順番に実行します。
- キャプチャを停止した場合は、取得済みPNGの保存完了を待ってからPDFを作成します。保存失敗はエラーとして報告し、未保存のページを保存済みには数えません。

ローカル測定例（Windows、1600×2100ピクセルの日本語テスト画像、各3回の中央値）：PDF作成のみ24ページはVersion 3.2.0の0.990秒から0.014秒、Windows OCR付き6ページは0.566秒から0.323秒になりました。これはPDF作成部分の測定で、実機Kindleのキャプチャ全体の速度を保証するものではありません。描画待ちやOCRが長い環境では、その処理時間は引き続き必要です。PDF容量はPNGの圧縮結果に依存し、以前の版より増える場合があります（この測定画像では約8%増）。

## コマンドライン

```text
# Windows
.venv\Scripts\kindle-capture.exe list-windows
.venv\Scripts\kindle-capture.exe capture --window-id 1234 --pages 10 --direction Right

# macOS
.venv/bin/kindle-capture list-windows
.venv/bin/kindle-capture capture --window-id 1234 --pages 10 --direction Right
```

画像からPDFを再作成する例です。

```text
kindle-capture rebuild PATH_TO_CAPTURES_FOLDER
```

PDF再作成は `page_*.png` をページ番号順に読み込みます。旧版で保存した `page_*.jpg` / `page_*.jpeg` も読み込めますが、既存のJPEGにある圧縮劣化を元に戻すことはできません。

`--region X Y WIDTH HEIGHT` はウィンドウに対する0〜1の比率です。左右5%、上下8%を除外するなら `--region 0.05 0.08 0.90 0.84` です。

## 配布アプリをローカルビルド

Windows PowerShell:

```powershell
.\build_windows.ps1
```

生成物:

- `dist\KindleCapture.exe`
- `dist\KindleCapture-Windows.zip`

macOS:

```zsh
chmod +x build_macos.command
./build_macos.command
```

生成物:

- `dist/Kindle Capture.app`
- `dist/KindleCapture-macOS-arm64.zip`（Apple Silicon上でビルドした場合）
- `dist/KindleCapture-macOS-x86_64.zip`（Intel Mac上でビルドした場合）

macOS版はAd-hoc署名です。第三者へ一般配布する場合、Gatekeeper警告を避けるにはApple Developer IDによる署名と公証を行ってください。

## GitHub Actions

- `.github/workflows/ci.yml`: Windows/macOSで静的検査とテストを実行
- `.github/workflows/build.yml`: 手動実行または `v*` タグでWindows x64、macOS Apple Silicon、macOS IntelのZIPを生成

GitHubへpush後、「Actions > Build applications > Run workflow」で両OSの配布物を作れます。手動実行の成果物は各workflow runのArtifactsから取得できます。

`v3.3.0` のようなタグをpushすると3環境のビルド後にGitHub Releaseも自動作成され、次のファイルが添付されます。ビルドが1つでも失敗した場合はReleaseを作成しません。

- `KindleCapture-Windows.zip`
- `KindleCapture-macOS-arm64.zip`
- `KindleCapture-macOS-x86_64.zip`

## 開発・テスト

```text
python -m venv .venv
python -m pip install -e ".[dev]"
python -m ruff check .
python -m pytest
```

自動テストは、画像比較、鮮明度、範囲比率、検索可能PDF、模擬キャプチャを対象にしています。OS固有の実画面取得とKindle操作は各OS上でスモークテストしてください。

## 注意事項

- 購入済み書籍を自分で利用する範囲に限定し、作成した画像やPDFを第三者へ共有・配布しないでください。
- DRMを解除するツールではありません。画面に表示された内容だけをキャプチャします。
- キャプチャ中に別アプリを操作すると、安全のため停止することがあります。
- KindleやOSの更新で画面取得・ページ送りの挙動が変わる可能性があります。

## ライセンス

元のWindows版と同じMIT Licenseです。詳細は `LICENSE` を参照してください。
