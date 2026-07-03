# 塗装レシピ録（plamo-paint.com）改修タスク指示書

あなたはこのリポジトリの改修を担当する。本サイトは「模型の塗装レシピを記録・共有するサービス」（塗装レシピのクックパッド）で、外部レビューにより以下の問題が特定された。**Phase順に、1つのPhaseが完了するごとに停止して報告し、私の承認を得てから次に進むこと。**

## 背景（前提知識）

- 構成: 静的HTML（index.html 約2500行・CSS/JS内蔵の1ファイルSPA）+ legacy.html（レシピの閲覧/編集/作成ページ）+ Supabase（認証・DB・Storage）
- `src/config.js` に `PAINTLOG_CONFIG.SUPABASE_URL` / `SUPABASE_ANON_KEY` がある
- レシピURLは現在 `legacy.html?id=<uuid>#view`
- PWA対応済み（manifest.webmanifest + sw.js）
- 検索は「公開recipesを新着300件fetch→クライアント側フィルタ」で実装されている
- `events` テーブルにクライアントから匿名insertする自前アナリティクス（`track()`関数）がある
- 管理者判定は `sb.rpc("is_admin")`。テーブルRLSはSupabase側で設定済みの想定

## 絶対に守ること（全Phase共通）

1. **既存機能を壊さない。** 特に: Googleログイン、レシピ作成/編集/閲覧、ダークモード、PWA（sw.js登録・pull-to-refresh）、管理者メニュー、退会フロー。
2. **`esc()` / `safeUrl()` によるエスケープ方針を維持する。** ユーザー入力をinnerHTMLに入れる箇所は必ず `esc()` を通す。
3. **Supabaseのanon keyはクライアント公開が前提の設計。** これをエラー扱いしない。ただしRLSに依存するので、SQLを書く際は必ずRLSポリシーもセットで書く。
4. **DBスキーマ変更・RLS変更・RPC作成はコードから直接実行しない。** 全て `migrations/` ディレクトリに連番付きSQLファイル（例 `migrations/001_search_rpc.sql`）として出力し、「Supabaseダッシュボード SQL Editorで実行してください」と私に指示する。私が実行完了を伝えるまで、そのSQLに依存するフロント変更をデプロイ前提にしない。
5. **共有済みURLを死なせない。** `legacy.html?id=...` 形式のリンクは既にユーザーがSNSに貼っている可能性がある。恒久的にリダイレクトで救済する。
6. 変更は最小差分で。リファクタリング衝動を抑え、指示された範囲だけ触る。
7. 各Phase完了時に「変更ファイル一覧・変更理由・手動確認手順・ロールバック方法」を報告する。

---

## Phase 0: 調査（コード変更禁止）

まず以下を調査し、結果を報告せよ。**このPhaseでは一切ファイルを変更しない。**

1. ホスティング先の特定: リポジトリ内の設定ファイル（`wrangler.toml`, `netlify.toml`, `vercel.json`, `.github/workflows/`, `firebase.json`, CNAMEファイル等）からデプロイ先を特定。不明なら私に質問する。**Phase 2のOGP注入方式はホスティング先に依存するため、ここが最重要。**
2. `legacy.html` の構造確認: レシピ閲覧時のデータ取得方法、`view_count` の加算方法（クライアントからのupdateか、RPCか）、レシピ本文のレンダリングでの `esc()` 適用状況。
3. `sw.js` のキャッシュ戦略確認: index.html/legacy.htmlをprecacheしているか。しているなら「デプロイ後に旧HTMLが配信され続ける」リスクを評価。
4. `recipes` テーブルで使われている列の一覧をコードから逆引きして整理（`id, title, cover_url, is_public, created_at, view_count, owner_id, methods, grid` など）。
5. robots.txt / sitemap.xml の有無。

報告フォーマット: 「ホスティング: ___ / view_count加算方式: ___ / SWキャッシュ: ___ / 懸念点: ___」

---

## Phase 1: 恒久URLの導入（/r/{id}）

目的: レシピの恒久URLを `https://plamo-paint.com/r/<id>` に統一する。`legacy` という単語をユーザーが目にするURLから排除する。

1. ホスティング先のリライト/リダイレクト機能（Phase 0で特定したもの）で以下を設定:
   - `/r/:id` → `legacy.html?id=:id#view` を返す（可能ならリライト、無理なら302ではなく**301リダイレクトは使わずJS遷移用の薄いHTMLでもよい**。ただしPhase 2のOGP注入と両立する方式を選ぶこと）
   - 旧URL `legacy.html?id=xxx` は引き続き動作させる（削除しない）
2. index.html / legacy.html 内の**レシピへのリンク生成箇所を全て** `/r/<id>` に置換する（`location.href = "legacy.html?id=..."` の箇所。grepで `legacy.html?id` を全件洗い出すこと）。編集画面 (`#edit`) や新規作成への遷移は従来どおりでよい。閲覧URLのみ対象。
3. 共有ボタン・URLコピー機能があれば、コピーされるURLを `/r/<id>` にする。
4. canonicalタグ: legacy.htmlが閲覧モードで開かれた際、JSで `<link rel="canonical" href="https://plamo-paint.com/r/<id>">` を動的に設定する。

完了条件: `/r/<有効なID>` でレシピが表示される。旧URLも動く。サイト内のレシピ遷移が全て新URL経由になっている。

---

## Phase 2: 個別レシピのOGP動的注入 + sitemap

目的: レシピURLをX等に貼ったとき、**そのレシピのタイトルとカバー画像**がカードに表示されるようにする。現状は全レシピが同一の汎用OGPになっており、拡散導線として致命的。

方式はPhase 0で特定したホスティングに合わせて選択する:

- **Cloudflare Pages/Workersの場合**: `/r/:id` へのリクエストをWorker（またはPages Functions `functions/r/[id].js`）で受け、Supabase REST API（anon key使用、`is_public=eq.true` のレシピのみ）から `title, cover_url` を取得し、legacy.htmlのHTMLに対して `<!--OG_START-->`〜`<!--OG_END-->` 相当のメタタグ部分をレシピ固有の値に差し替えて返す。**bot判定は不要**（全リクエストで注入してよい。人間にも正しいメタが返るだけ）。
- **Netlify/Vercelの場合**: 同等のEdge Function / Serverless Functionで実装。
- **GitHub Pages等、動的処理が一切不可能な場合**: 実装せず停止し、「Cloudflare Pagesへの移行を推奨する。移行手順は___」と私に提案する。**勝手に移行作業を始めないこと。**

実装上の必須要件:
- Supabaseから取得した `title` / `cover_url` は**HTMLエスケープしてから**メタタグに埋め込む（保存型XSS対策。title に `"><script>` が入っても壊れないこと）
- 非公開レシピ・存在しないIDの場合は汎用OGPのまま返す（存在有無を外部に漏らさない）
- fetch失敗時は汎用OGPでフォールバック（レシピ表示自体は止めない）
- og:title, og:description, og:image, og:url, twitter:card 一式を差し替える

sitemap:
- 公開レシピの `/r/<id>` 一覧を返す `sitemap.xml` を動的生成（同じFunction基盤で `sitemap.xml` エンドポイントを作る。Supabaseから `is_public=true` のid+created_atを取得）。件数が5万を超える設計は不要、単一ファイルでよい。
- `robots.txt` を静的ファイルとして追加: 全許可 + `Sitemap: https://plamo-paint.com/sitemap.xml` の行。
- 完了報告時に「Google Search Consoleにsitemapを登録してください」と私への手順を添える。

完了条件: `curl -A "Twitterbot" https://plamo-paint.com/r/<公開ID>` のレスポンスに該当レシピのtitleが含まれる。非公開IDでは含まれない。

---

## Phase 3: 検索のサーバーサイド化

目的: 現在の「新着300件fetch→クライアント側フィルタ」は、投稿が300件を超えた時点で古いレシピが検索不能になる。Postgres側の検索RPCに置き換える。

1. `migrations/00X_search.sql` を作成:
   - `pg_trgm` 拡張の有効化
   - `search_recipes(_q text, _limit int default 50)` RPC（`security definer` は使わず `security invoker`、内部で `is_public = true` を強制）
   - 検索対象: `title` の部分一致（ILIKE + trgmインデックス）、`methods` 配列（タグ）、`grid` JSON内の自由入力塗料名（`grid::text ILIKE` で開始し、遅ければ後で正規化検討、というコメントをSQLに残す）
   - `_q` 内の `%` `_` はエスケープしてから使う
   - 返却列は現在のクライアントが使う `id,title,cover_url,is_public,created_at,methods,grid,owner_id` に合わせる。可能なら「マッチ理由（title/tag/paint）」も返す
   - trgmインデックスのCREATE INDEX文も含める
2. index.html の `openSearchResults()` を `sb.rpc("search_recipes", ...)` 呼び出しに書き換える。**RPC未適用環境でも壊れないよう**、RPCがエラーを返した場合は現行の300件フェッチ方式にフォールバックする（フォールバックは既存コードを関数として残して呼ぶ）。
3. マッチ理由ラベル（「タイトル一致」等）の表示は維持する。
4. `track("search", ...)` の計測呼び出しは維持する。

完了条件: SQLファイルが完成し私に実行手順が提示されている。フロントはRPC優先+フォールバックで動作する。

---

## Phase 4: events（アナリティクス）とview_countの保護

目的: 匿名insertが無制限に可能な `events` テーブルはスパム攻撃でSupabase無料枠(500MB)を食い潰せる。また `view_count` がクライアント加算ならランキング操作が可能。

1. `migrations/00X_events_protection.sql` を作成:
   - `events` のRLS確認用コメント: SELECTはis_adminのみ / INSERTは許可（匿名込み）の現状方針を維持しつつ、
   - INSERTに制約を追加: `event_name` をホワイトリスト（`page_view, view_recipe, click_paint, search, click_buy` + コード内をgrepして実際に使われている全イベント名）でCHECK制約。`properties` のサイズ上限CHECK（`pg_column_size(properties) < 2048` 程度）
   - 保持期間: 90日より古い行を削除する関数 + `pg_cron` があればスケジュール登録、なければ「Supabaseダッシュボードで pg_cron を有効化して以下を実行」という手順コメント
2. view_count: Phase 0の調査結果に基づき、クライアントから直接 `update recipes set view_count = ...` している場合は、`increment_view(_recipe_id uuid)` RPC（公開レシピのみ加算）に置き換えるSQLとフロント修正を行う。既にRPCなら何もしない。
3. レート制限はSupabase単体では困難なので、**実装しない**。代わりに「将来的な選択肢（Cloudflare WAFルール等）」をREADMEかコメントに1段落で残すだけにする。

---

## Phase 5: 小規模修正（まとめて1コミット群でよい）

1. **viewport修正**: index.html / legacy.html / その他全HTMLの `maximum-scale=1` を削除する（ピンチズーム禁止はアクセシビリティ違反。老眼ユーザーが塗料名を拡大できない）。`viewport-fit=cover` は残す。
2. **ilikeワイルドカード**: `profiles` の user_id 重複チェックで `ilike("user_id", id)` を使っている箇所を修正。入力に `%` `_` が含まれると誤マッチする。対応: (a) user_idの許容文字を英数と `_` に制限するクライアントバリデーションを確認/追加し、(b) クエリは `eq` + 小文字正規化（DB側でlower比較できる形）に変更。あわせて `migrations/` にUNIQUE制約（`lower(user_id)` のユニークインデックス）を出力。
3. **塗装方法マスターの一元化**: index.html と legacy.html に重複して埋め込まれている「塗装方法マスター」を `src/methods.js`（`window.PAINT_METHODS = {...}` 形式の1ファイル）に切り出し、両HTMLから `<script src>` で読む。内容の食い違いがあれば差分を報告してから統合する。
4. **データエクスポート**: 設定画面（`openSettings` 付近）に「自分のデータをエクスポート（JSON）」ボタンを追加。ログインユーザー自身の profiles + recipes（公開/非公開とも）を取得し、`paintlog-export-YYYYMMDD.json` としてダウンロードさせる。既存のRLS（自分の行はSELECT可）の範囲内で実装できるはずで、新規SQLは不要の想定。不可能ならその理由を報告。
5. **sw.js確認**: Phase 0の調査でHTMLをprecacheしていた場合、HTML類は network-first（またはstale-while-revalidateでもよいが必ず更新が届く方式）に変更する。していなければ何もしない。

---

## 進め方の再確認

- Phase 0から順に。**各Phase終了ごとに停止して報告し、承認を待つ。**
- SQLは全て `migrations/` にファイル出力 → 私がSupabaseで実行 → 実行完了の連絡後にフロント側をコミット、の順。
- 判断に迷ったら勝手に決めず選択肢を提示して質問する。特にホスティング移行・課金・ライブラリ追加は必ず事前確認。
- 動作確認はローカルで `python3 -m http.server` 等の静的サーバー越しに行う（file:// 直開きはSupabase認証まわりの挙動が変わるため不可）。
