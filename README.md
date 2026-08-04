# 塗装レシピ録 / Plamo-Paint

模型・ガンプラの「塗装レシピ」（どの塗料を・どの部位に・どの順で）を記録し、URL一つで共有できる無料Webサービス。
本番: **https://plamo-paint.com**

> このREADMEは引き継ぎ用の説明書です。**別のエンジニアやAIツールがこのリポジトリだけで運用を引き継げる**ことを目的にしています。
> サイトはClaude等のAIに依存して動いていません（AI APIは一切呼んでいない）。動いているのは下記の外部サービス上です。

---

## 1. アーキテクチャ（全体像）

```
ブラウザ
   │
   ▼
Cloudflare Worker (worker/src/worker.js)   ← 全リクエストの入口
   ├─ /r/:id            → レシピ閲覧。Supabaseからレシピ取得し、OGP+JSON-LDを動的注入した legacy.html を返す
   ├─ /sitemap.xml      → 公開レシピを動的列挙
   ├─ /robots.txt       → 明示返却
   └─ それ以外          → Worker に同梱した静的ファイルを直接配信（[assets]）
   │
   ▼
（静的ファイルは Worker に同梱。外部の配信元は無い ← 2026-07-28に GitHub Pages から移行）
   │
   ▼（フロントJSから直接）
Supabase（認証・PostgreSQL・Storage・RLS・RPC・トリガー）
```

- **ビルド無しの素の静的サイト**（フレームワーク/バンドラ無し。npm build不要）。
- フロントは `index.html`（アプリシェルSPA）と `legacy.html`（レシピ閲覧/編集/作成）の2枚が主体。
- 認証メール送信は **Brevo（独自SMTP）** 経由（Supabase標準メールの低い上限を回避）。
- ドメイン・DNSは **Cloudflare** 管理。

---

## 2. リポジトリ構成（主要ファイル）

| パス | 役割 |
|---|---|
| `index.html` | アプリシェル（探す/記録/プロフィール/通知/設定/塗料ページ等）。ルート `/` で配信 |
| `legacy.html` | レシピの閲覧・編集・作成。`/r/:id`（Worker経由）と `/legacy.html?id=`（後方互換）で配信 |
| `help.html` `privacy.html` `terms.html` `course.html` | ヘルプ・プライバシー・規約・塗装講座（準備中） |
| `diagnostics.html` `goodbye.html` | 接続診断 / 退会後ページ |
| `src/config.js` | Supabase接続設定（**公開anonキー**。dev/prod切替あり。§5参照） |
| `src/methods.js` | 塗装方法マスター（index/legacyから共有） |
| `src/supabase.js` | Supabaseクライアント補助 |
| `assets/paints.js` | **未使用の旧ファイル**（どのページからも読み込まれていない）。塗料マスターの正本は `legacy.html` 内の `PAINTS` 配列 と `supabase/seed_paints_realigned.sql`。§7のB-002注意 |
| `assets/*.png` | ロゴ・favicon・ホーム画面アイコン |
| `worker/src/worker.js` | Cloudflare Worker本体（OGP注入・sitemap・robots・プロキシ・cover_url検証） |
| `worker/wrangler.toml` | Worker設定（ルート・環境変数） |
| `supabase/schema.sql` | **DBの正本**：全テーブル・RLS・RPC・トリガー・インデックス |
| `supabase/seed_paints_realigned.sql` | 塗料マスターの整列seed |
| `migrations/0XX_*.sql` | schema.sql以降に足した追加SQL（検索RPC・events保護・NGワード・Storageポリシー・BAN等）。**連番順に全部実行が必須**（§5） |
| `manifest.webmanifest` `sw.js` | PWA（ホーム画面追加・オフライン最小対応） |
| `robots.txt` | （Workerが動的返却するが静的も同梱） |
| `BOMBS.md` | **時限爆弾台帳**（「今は動くが前提が崩れると壊れる」箇所の記録・§7） |
| `CLAUDE引き継ぎ.md` `claude-code-prompt.md` | 開発時のメモ・レビュー指示書（参考） |

---

## 3. ローカルで動かす

ビルド不要。静的サーバーで開くだけ（`file://` 直開きはSupabase認証周りの挙動が変わるため不可）。

```bash
cd <repo>
python3 -m http.server 4173
# → http://localhost:4173/ を開く
```

`.claude/launch.json` にも同等の起動設定（"static"）がある。

⚠️ **既定では localhost も本番Supabaseに接続する**（本番データを触る）。開発用DBに切り替える方法は §5。

---

## 4. デプロイ（**2系統**・混同注意）

> ⚠️ **2026-07-28に配信のしくみが変わりました。`git push` だけでは公開されません。**

| 変更したファイル | 反映方法 |
|---|---|
| **すべて**（`*.html` / `src/` / `assets/` / `worker/src/worker.js`） | **`cd worker && npx wrangler deploy`** |

静的ファイルもWorkerに同梱して配信しているため、1回のdeployで全部が同時に反映されます。
（コードと静的ファイルがズレる時間帯が構造的に生じない、という利点があります）

`git push` すると `.github/workflows/deploy.yml` が自動でdeployします。ただし
**`CLOUDFLARE_API_TOKEN` をリポジトリのSecretsに登録するまでは動きません**
（未登録の間はActionsに黄色の警告が出て、何も公開されません）。

- deploy後は必ず `curl -sI https://plamo-paint.com/` と `/r/<id>` で壊れていないか検証すること。
- **`src/config.js` か `src/methods.js` を変えたら、push前に必ず `node scripts/bump_asset_version.mjs` を実行する**（HTMLが読むURLの `?v=` を更新し、デプロイ直後に古いJSが使われるのを防ぐ／確認だけなら `--check`）。
- 静的側の反映はGitHub Pages 10分キャッシュ + Worker cacheTtl 300秒により**デプロイ直後5〜10分は旧新混成**があり得る（BOMBS.md B-003）。
  上の `?v=` でブラウザとCloudflareの層は解消済み。残るGitHub Pages層のズレは、画面側の `version_skew` 検出（console.error＋eventsテーブル）で気づけるようにしてある。

---

## 4.5 ライブラリを更新する（Supabase）

### 前提: なぜ固定しているか

以前は `https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2` と書いていた。
末尾の `@2` は「2で始まる中で一番新しいものを毎回取ってくる」という意味で、**誰も版を決めていない**状態だった。

実測: このライブラリは **90日で21回**（平均4.3日に1回）新版が出る。
つまり **4日に1度、誰にも知らされないままサイトの心臓部が別のプログラムに差し替わっていた。**
何も変更していないのに突然ログインできなくなり、しかも「動いていた版」に戻す手段も無い、という事故が起こりうる。
さらに配信元(jsDelivr)が落ちると、Supabaseが正常でもサイトが動かなくなる。

そこで **版を固定して `vendor/` に置き、自分のドメインから配信**している。
- 突然の差し替えが構造的に起きない
- jsDelivrが落ちてもサイトは動く（外部依存が2つ→1つに減る）
- 別ドメインへの接続が減るぶん表示も速い

### 更新を忘れないための仕掛け（3重）

| 仕掛け | いつ気づくか |
|---|---|
| ① `node tests/run_front_tests.mjs` の最後に自動表示 | **開発するたび**（主役） |
| ② Claudeに「やることある？」と聞いたとき | **オーナーが唯一必ず聞く場面** |
| ③ GitHub Actionsが毎週Issueを立てる | 開発していない期間の保険 |

固定した日は **`vendor/pinned.json` の `pinnedAt`** に書いてある。
ファイルの更新日時では判定していない（`git clone` や `checkout` をすると全ファイルの日時が
その時刻に書き換わり、何年前に固定したものでも「今日固定したばかり」に見えてしまうため）。

判定は3段階で、**90日を過ぎると「検討」から「実行」に自動で切り替わる**:

| 経過 | 表示 | 意味 |
|---|---|---|
| 新版なし・90日未満 | 緑「最新です」 | 何もしなくてよい |
| 新版あり・90日未満 | 黄「新しい版が出ています」 | 急ぎではない |
| **90日以上** | **赤「更新してください（N日経過・期限超過）」** | **最新のままでも更新作業を通す** |

> ⚠️ 版を上げたら `vendor/pinned.json` の `version` と **`pinnedAt` を両方**書き換えること。
> 日付を忘れると次の90日判定がずれる。書き換え漏れは自動で検出され、赤字で警告が出る。

### 更新手順

**Claudeに「Supabaseライブラリを更新して」と言えば全部やる。** 自分でやる場合:

```bash
V=2.111.0          # ← 新しい版に置き換える

# 1) 取得
curl -sSL "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@${V}/dist/umd/supabase.js" \
     -o "vendor/supabase-js-${V}.js"

# 2) npm公式の中身と一致するか確認（すり替えられていないかの検証・必須）
curl -sSL "https://registry.npmjs.org/@supabase/supabase-js/-/supabase-js-${V}.tgz" -o /tmp/sb.tgz
tar -xzf /tmp/sb.tgz -C /tmp package/dist/umd/supabase.js
cmp "/tmp/package/dist/umd/supabase.js" "vendor/supabase-js-${V}.js" && echo "一致OK"

# 3) 読み込み先を差し替える（index.html / legacy.html / diagnostics.html の3か所）
#    ※ index.html の記述が「いま使っている版」の正本。チェック用スクリプトはここを読む

# 4) 古いファイルを消す
git rm vendor/supabase-js-<古い版>.js

# 5) テスト（画面31/塗料23/Worker55）
node tests/run_front_tests.mjs && node tests/run_paint_tests.mjs && node tests/run_worker_tests.mjs
```

**5の後、必ずブラウザで「ログイン・投稿・画像アップロード」を実際に通すこと。**
自動テストはライブラリ本体の動作までは見ていない（HTMLから安全用の関数を取り出して調べているだけ）。

> ⚠️ `vendor/` のファイルは**手で書き換えないこと**。npm公式と1バイトでも違うと、
> 上の(2)の検証が意味を失う。差し替えるときは必ず丸ごと入れ替える。

## 5. 環境変数・設定（dev / prod 分離）

### フロント: `src/config.js`
- **公開anonキーのみ**を持つ（ブラウザに出てOKな公開キー。防御は**RLS**で行う）。`service_role` キーは**絶対に置かない**。
- **dev/prod切替**：
  - `PROD` … 本番Supabaseの URL / anonキー（常にこれが既定）。
  - `DEV` … 開発用Supabaseの URL / anonキー（**2つ目の無料Supabaseプロジェクトを作ったらここに貼る**）。未設定(null)なら localhost でも PROD にフォールバック。
  - ロジック：**`localhost` かつ `DEV` 設定済みのときだけ DEV**。それ以外（本番ドメイン含む）は**必ず PROD**（フェイルセーフ＝本番が誤って別DBに繋ぐ経路を作らない）。

### 開発用DBを用意する手順（dev環境を"稼働"させる）

⚠️ **順番が重要**。下の①〜⑦をこの順で実行しないと本番と同じ状態にならない。
特に **Storageバケットを migrations より前に作る**こと（`migrations/010`・`016` はバケットが
既に存在している前提で、そのポリシーと容量上限を書き換えるため。先に作っていないと
`update storage.buckets` が **0行更新（＝エラーも出ずに無視）** され、
1ファイル10MB制限やMIME制限が**付かないまま**になる）。

1. Supabaseで**2つ目の無料プロジェクト**を作成（無料枠は2プロジェクトまで）。
2. SQL Editor で **`supabase/schema.sql`** を実行（テーブル・RLS・RPCの土台）。
3. **【2026年5月以降に作成したプロジェクトのみ】Data API用のGRANTを付ける。**
   新しいSupabaseプロジェクトでは `anon` / `authenticated` にテーブル・シーケンスの権限が
   **既定で付かなくなった**。付けないと画面が `permission denied for table recipes` 等で
   何も表示できない（本番プロジェクトはそれ以前に作ったので既に付いている）。
   **必ず migrations より前に1回だけ**実行する:
   ```sql
   grant usage on schema public to anon, authenticated;
   grant all on all tables    in schema public to anon, authenticated;
   grant all on all sequences in schema public to anon, authenticated;
   -- migrations で後から作られるテーブルにも自動で付くようにしておく
   alter default privileges in schema public grant all on tables    to anon, authenticated;
   alter default privileges in schema public grant all on sequences to anon, authenticated;
   ```
   - 権限を広く付けても安全なのは**防御の本体がRLS**だから（Supabase標準の設計と同じ）。
   - 🚫 **migrations実行後にこのGRANTをやり直してはいけない。**
     `004`/`007`/`016` が意図的に外している権限（例: プロフィールの内部列を匿名から隠す
     `revoke select on public.profiles from anon`）まで復活し、**脆弱な状態に戻る**。
   - Dashboard → Settings → API の **Exposed schemas に `public` が入っている**ことも確認する。
4. **`supabase/seed_paints_realigned.sql`** を実行（塗料マスター512色）。
   - ⚠️ 塗料seedは **`seed_paints_realigned.sql` が正本**（`seed_paints.sql` は並び順がズレた旧ファイル・使用禁止）。
5. **Storageバケットを作る**（Dashboard → Storage → New bucket）。
   - `recipes` … Public bucket
   - `profile` … Public bucket
   - ポリシーはこの時点では未設定でよい（次の `migrations/010` が正しい定義を入れる）。
6. **`migrations/001` 〜 `032` を連番順に全部**実行し、**最後に必ず `033_reconcile_catalog.sql`** を実行する。
   - ⚠️ **migrations を飛ばすと、修正前の脆弱な定義のままになる。**
     `schema.sql` は初期設計であり、**その後のセキュリティ修正はすべて migrations 側にある**。
   - ⚠️ **`033` は必須。** 023〜032の一部は「説明コメントだけ」で中身を持っていない
     （本番へ直接SQLを流して適用したため）。033がその差分をまとめて埋める。
     033の末尾には自己点検が入っており、**意図どおりにならなければエラーで止まる**ので、
     「流したのに効いていない」状態には気づける。
   - すべて冪等（何度実行しても安全）。
7. （任意）DBテストを入れる場合は `tests/db/00_harness.sql` → `01`〜`10_*.sql` を実行（§6.5）。

最後に:
- `src/config.js` の `DEV` に、devプロジェクトの `SUPABASE_URL` と anonキーを貼る。
- `python3 -m http.server 4173` で localhost を開くと**自動でdev DBに接続**（本番は無影響）。

### Worker: `worker/wrangler.toml` の `[vars]`
- `ORIGIN` … GitHub raw のベースURL（配信元）
- `SITE` … `https://plamo-paint.com`
- `SUPABASE_URL` / `SUPABASE_ANON_KEY` … Worker用（公開anonキー）

---

## 6. データベース（Supabase）

- **正本は `supabase/schema.sql`**。全テーブル・**RLS（行レベル権限）**・RPC・トリガー・インデックスを定義。
- 追加分は `migrations/` に連番SQL（例: 検索RPC `search_recipes`、events保護、コメントNGワード）。SQLは**ダッシュボードのSQL Editorで手動実行**する運用。
- 主要テーブル: `recipes`(grid=JSONBでレシピ本体), `recipe_paints`(集計用に展開), `profiles`, `drafts`, `comments`(+`comment_likes`), `notifications`, `events`(自前アナリティクス), `reports`/`inquiries`, `premium_users`, `paints`。
- **セキュリティの要はRLS**：非公開投稿・メール等は本人のみ。他人のデータは更新/削除不可。`is_admin()` はDB側判定＋自己昇格防止トリガー。CSS/画像出力は `safeColor()`/`safeUrl()`/`esc()` でサニタイズ。
- **バックアップ**：別リポジトリ **`shayan795/plamo-paint-backups`**（Private）でGitHub Actions cronが毎日 pg_dump → 最新7個ローテ保存。
  - ⚠️ **pg_dump はデータベースの中身だけ。利用者がアップロードした写真（Storage）は対象外**。
    写真は `bash scripts/backup_storage.sh` で別途取得する。保存先 `backups/storage/<YYYYMMDD>/` はGit管理外。
    - このスクリプトは**直近7世代だけ残して古いものを自動削除**し、取得したファイルの一覧とサイズを
      各世代の `manifest.txt` に記録する。**1件でも取得に失敗すると終了コード1で異常終了**する
      （cron等に載せたときに黙って壊れないようにするため）。
    - ⚠️ **既定では「公開レシピ・公開プロフィールが参照している画像」しか取れない**（匿名キーのため）。
      非公開投稿・下書き・孤児ファイルまで含めた**完全版**にするには、SQL Editorで
      `select bucket_id || '/' || name from storage.objects where bucket_id in ('recipes','profile') order by 1;`
      の結果を `scripts/storage_paths.local.txt` に貼ってから実行する（詳細はスクリプト冒頭のコメント）。
  - ⚠️ **GitHub Actions の cron は、リポジトリに60日間操作が無いと自動停止する**。停止すると通知は出ないため、
    月に一度は当該リポジトリで実行履歴を確認するか、`workflow_dispatch` で手動実行して活動を維持すること。

---

## 6.5 自動テスト（DB 604本 ＋ 画面 31本 ＋ Worker）

変更後に「他が壊れていないか」を機械的に確かめる。詳細は **`tests/README.md`**。

| 対象 | 本数 | 実行方法 |
|---|---:|---|
| データベース（RLS・トリガー・RPC・Storage） | 604 | 開発用プロジェクトの SQL Editor で `select * from public.test_report();` |
| 画面まわり（XSS・CSS注入・サムネイル） | 31 | `node tests/run_front_tests.mjs` |
| Worker（OGP/JSON-LD注入・プロキシ・cover_url検証） | 実行時に表示 | `node tests/run_worker_tests.mjs` |

- **`node` のテストはビルド不要・数秒**で終わる。DBを触らないので本番にも影響しない。
- Worker（`worker/src/worker.js`）を触ったら `run_worker_tests.mjs` を、
  `index.html` / `legacy.html` を触ったら `run_front_tests.mjs` を必ず実行する。

- **必ず開発用DB(dev)で実行する。** 本番には `tests` スキーマを入れていない。
- テストは実際に**本番稼働中のCritical脆弱性を含む実バグ16件を発見**した実績がある
  （例: 未ログインでも他人の投稿を削除できた／BANされた本人が自力解除できた）。
- **不合格が出てもテストを甘くしない。** 実装の問題か、テストの問題かを必ず切り分ける。

---

## 7. 運用上の注意 / 時限爆弾（BOMBS.md）

- `BOMBS.md` に「今は動くが前提が崩れた瞬間に壊れる」箇所を台帳化している。引き継ぎ時に**必ず一読**。
- 特に **B-002（塗料マスターの並び順 c.i 依存）** は、**`legacy.html` 内の `PAINTS` 配列**の並びを変えると既存レシピの色が静かにズレる（エラーは出ない）。並び替え・途中削除は禁止、追加は末尾のみ。DB側の `paints.sort_order`（`seed_paints_realigned.sql`）も同じ並びを保つこと。安定ID `c.id` への移行が将来課題。※`assets/paints.js` は未使用の旧ファイルなので、これを正本として再生成しないこと。
- 教訓（解決済み）：**ルート以外のパス(/r/:id 等)で配信されるHTMLは、ローカル資産・内部リンクを必ず絶対パス(先頭 /)で参照する**。相対パスはWorkerのキャッチオール・ルートと衝突して壊れる。

---

## 8. 外部サービス一覧（引き継ぎ時に必要なアカウント）

| サービス | 用途 |
|---|---|
| **GitHub** (`shayan795/paint-log-v2`) | コード・静的配信元。バックアップ用に `plamo-paint-backups`(Private) |
| **Supabase** (project ref `zlkbaojclitlxshpxwpr`) | 認証・DB・Storage |
| **Cloudflare** | ドメイン(plamo-paint.com)・DNS・Worker(`paintlog-v2`) |
| **Brevo** | 認証メールの独自SMTP送信 |
| **Amazon Associates / 楽天アフィリエイト** | 塗料リンクの収益化 |

すべて**オーナーのアカウント所有**。この5つのアカウント＋本リポジトリがあれば、別の開発者/AIで運用を継続できる。
