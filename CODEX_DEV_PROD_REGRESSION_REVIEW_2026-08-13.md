# 開発版／本番版 分離リグレッションレビュー

- 監査時点: 2026-08-13 18:42 JST
- 対象HEAD: `28882a0151c38e84564875c55706a2f0b3d9fcf6`
- 対象差分: 未コミットの `index.html` / `legacy.html` / `src/config.js` / `worker/src/worker.js` / `tests/run_front_tests.mjs` と、未追跡の migrations 034〜036 / `scripts/dev.sh`
- PROD: `plamo-paint.com` と本番Supabase
- DEV: ローカルworktreeと開発Supabase
- 外部確認は匿名・読取専用で実施。DB、Storage、本番配信物への書込みは行っていない。

## 環境境界の確認

- 本番の `index.html`、`legacy.html`、`src/config.js`、`sw.js` のSHA-256は、4件ともコミット済みHEADと一致した。`index.html`、`legacy.html`、`src/config.js` は現在の開発worktreeとは不一致だった。
- 本番の `/`、`/healthz`、`/sitemap.xml` は調査時点でHTTP 200。既存の公開レシピURLもHTTP 200だった。
- 本番DBには `is_sample` と `sample_recipe()` は存在するが、`cover_pos` と `share_url` は存在せず、匿名RESTで各HTTP 400 / PostgreSQL `42703` を返した。
- 開発DBには `is_sample`、`cover_pos`、`share_url`、`sample_recipe()` が存在する。
- したがって、以下の「新版を公開すると発症」とした指摘は、現在の本番障害ではない。現在の本番と開発版候補は分離して評価している。

## 指摘

### H-01 — 通常のmigration順で既存SNSカードの実体が消える

- **重大度:** High
- **告知前に直すべきか:** yes
- **分類:** 開発版で実損あり／本番投入時のデータ破壊
- **該当箇所:** `README.md:54,215-223`、`migrations/035_cover_pos_and_share.sql:48-56`、`migrations/036_protect_share_url.sql:4,31-42`、`migrations/013_purge_unreferenced_images.sql:31-59,91-100`、`migrations/017_codex_fixes.sql:259-262`
- **問題:** READMEどおりmigrationを連番順 `035 → 036` で適用すると、035で `share_url` へ移した旧カバー画像を、036適用前の孤児画像掃除が削除する。
- **根拠:** 035は先に `set share_url = cover_url`、次に `set cover_url = grid->'photos'->>0` を実行する。`cover_url` の更新では `trg_purge_images_recipes` が発火するが、旧 `purge_unreferenced_images` の使用中集合には `cover_url` と `grid` しかなく、`share_url` がない。さらに掃除対象は `created_at < now() - interval '1 hour'` であり、例外はトリガ内の `exception when others then null` で握り潰される。036自身は「035より先に流す」と書くが、READMEの連番順とファイル番号に反する。
- **実測:** DEV公開3件のうち `share_url` がある2件を確認し、1件はStorage GETがHTTP 400 `not_found`、もう1件はHTTP 206だった。PROD公開2件の現カバーはどちらも先頭写真と別の `_cover.jpg` で、実体はHTTP 200、最終更新は1時間より十分古い。PRODは035未適用なので現時点では無傷である。
- **壊れる条件:** 通常の番号順で035を本番実行する。旧カードのDB URLだけが残り、X/LINE等の共有画像が欠ける。Workerは画像の存在確認をせず、許可originなら死んだ `share_url` をOGPへ採用する (`worker/src/worker.js:460-468`)。
- **推奨する修正:** `列追加 → purge/delete関数のshare対応 → データbackfill → cover_url切替` を単一トランザクション・単一migrationへ統合する。逆順の手作業を前提にしない。DEVの欠損URLはnull化またはカード再生成し、本番適用前後に全対象のStorage実体をHEAD検査する。古いStorage objectを含むfresh migrationテストを追加する。
- **確度:** Confirmed。なお、引用符で囲まれたPL/pgSQL本体はCREATE時に全参照が解決されるとは限らないため、「036を先にCREATEすると即失敗する」という指摘は採用していない。[PostgreSQL CREATE FUNCTION](https://www.postgresql.org/docs/current/sql-createfunction.html)

### H-02 — 新版コードをDBより先に出すと全レシピURLと保存が壊れる

- **重大度:** High
- **告知前に直すべきか:** yes
- **分類:** 本番投入順序の回帰／現在の本番は未発症
- **該当箇所:** `worker/src/worker.js:64-82,569`、`index.html:1090,1479,1544,2538,3092`、`legacy.html:4260-4282`、`migrations/035_cover_pos_and_share.sql:6-11`、`.github/workflows/deploy.yml:60-103`、`worker/src/worker.js:703-735`
- **問題:** 現在の開発版Worker/HTMLは、本番DBにまだない `share_url` / `cover_pos` を必須列として使う。配備フローにDB前提条件の検査がない。
- **根拠:** Workerの取得列は `"...,cover_url,share_url,..."`、legacyの保存は `payload.share_url` と `payload.cover_pos` を送る。indexも複数の一覧SELECTで `cover_pos` を要求する。本番への読取実測では両列が `42703 column does not exist`。035自身も「逆順にすると投稿と更新が全部失敗する」と明記する。一方 `/healthz` は `paints?select=id&limit=1` しか見ないため、この不整合があっても200を返す。
- **壊れる条件:** WorkerまたはHTMLだけを先に本番公開する。`/r/:id` はレシピ取得エラーから503になり、一覧の一部は読込失敗、投稿・更新は42703で失敗する。通常のhealth checkは緑のままになる。
- **推奨する修正:** H-01の安全なmigrationを先に適用するexpand-contract配備にする。公開前に本番へ `recipes?select=id,cover_pos,share_url&limit=0` と必須RPC署名を照会し、満たさなければdeployを止める。公開後smokeに実在する `/r/:id` と、開発環境での認証済み保存を加える。
- **確度:** Confirmed

### H-03 — 削除時に画像を先に消すため、通信失敗で本文だけ残る

- **重大度:** High
- **告知前に直すべきか:** yes
- **分類:** 本番にも存在する未解消の部分失敗経路
- **該当箇所:** `legacy.html:4164-4178,4432-4454`
- **問題:** レシピと下書きの削除は、Storage APIで画像を不可逆に削除してからDB削除RPCを呼ぶ。2操作は原子的でない。
- **根拠:** 実装は `unusedStoragePaths(...).then(purgeStorage).then(() => sb.rpc("delete_recipe_with_images"...))`、下書きも `.then(purgeStorage).then(() => sb.rpc("delete_draft_with_images"...))` の順である。直前コメントは旧実装の問題として「本文の削除に失敗すると画像だけ永久に消える」と説明しているが、現在の順序が同じ失敗を再導入している。
- **壊れる条件:** Storage remove成功直後に通信断、セッション切れ、RPCの5xx、権限エラー、migration不整合が起きる。DB行は残るが、本文が参照する画像だけが失われる。
- **推奨する修正:** クライアントの2段削除をやめ、DBで削除要求/outboxを原子的に記録し、service-roleのサーバ処理でStorage削除を冪等に再試行する。最低限でも本文削除の確定を先にし、物理画像削除を非同期化する。「Storage成功直後にRPC失敗」を注入する統合テストを追加する。
- **確度:** Confirmed。破壊的な本番再現は行っていない。

### H-04 — PROD/DEVのDB catalogが一致せず、復旧時に入力防御が消える

- **重大度:** High
- **告知前に直すべきか:** yes
- **分類:** 環境差／復旧・検証基盤の欠陥
- **該当箇所:** `migrations/026_notify_and_input_limits.sql:11-13`、`migrations/033_reconcile_catalog.sql:4-18,48-53`、`README.md:215-223`
- **問題:** 「033まで流せば本番と同じ」という契約が成立していない。DEVテスト合格はPRODの同型環境を検証していない。
- **根拠:** catalogの読取比較で、PRODだけに `recipes_title_len`、`recipes_author_len`、`recipes_memo_len`、`recipes_methods_n`、`reports_reason_len`、`reports_detail_len`、`inquiries_cat_len`、`inquiries_body_len` の8 CHECKがあり、DEVにはなかった。026は「詳細は本番のcatalogを参照」と書くだけでDDLを収録せず、033は「差分をすべて実行可能なSQLとして書き起こした」と宣言するが、この8制約を作らない。さらに `public.is_banned()` の匿名実行はPRODが401、DEVが200で、033の `revoke ... from anon` とDEV実体が一致しない。034〜036は未追跡で、READMEの復旧手順は033で終わる。
- **壊れる条件:** DEVで通った巨大入力がPRODだけ拒否される。逆に空DBへREADMEどおり復旧すると8つの長さ制限を失い、DB容量枯渇対策が後退する。ACL差によりDEVで本番の信頼境界を再現できない。
- **推奨する修正:** 直接適用した全DDLを追跡migrationへ戻す。schema、constraint、policy、trigger、関数本体、`proacl` の期待fingerprintを作り、fresh DBとDEV/PRODで機械比較する。migration ledgerもソースと一致させる。
- **確度:** Confirmed

### H-05 — GitHub Actionsが全工程skipでも緑になる

- **重大度:** High
- **告知前に直すべきか:** yes
- **分類:** 配備・運用上の信頼境界
- **該当箇所:** `.github/workflows/deploy.yml:44-58,62-103`
- **問題:** Cloudflare tokenがない場合、テスト、資産版確認、deploy、公開後確認をすべてskipしながらworkflow全体をsuccessにする。
- **根拠:** guardはtoken空で `ready=false` を設定するだけで成功終了し、以降4工程はすべて `if: steps.guard.outputs.ready == 'true'`。GitHub公開APIで全12 runを確認し、2026-07-28〜08-06の全runがgreen/successだが、4工程はすべてskippedだった。最新は [run 31063438469](https://github.com/shayan795/paint-log-v2/actions/runs/31063438469)。
- **壊れる条件:** greenを「テスト・公開成功」と解釈する。実際は自動公開が一度も動かず、手動deployがDB順序・asset check・smokeを迂回する。
- **推奨する修正:** secret欠落を明示的な失敗にする。テストとasset checkはtokenの有無にかかわらず必ず実行し、branch protectionの必須checkにする。deploy receipt、commit SHA、配信ファイルhashまで記録・照合する。
- **確度:** Confirmed

### H-06 — 607件合格でも現在の変更を一件も守っていない

- **重大度:** High
- **告知前に直すべきか:** yes
- **分類:** テストのfalse green
- **該当箇所:** `tests/run_db_tests.mjs:23-54`、`tests/db/99_runner.sql:91-105`、`tests/db/05_ban.sql:41-42,59,86-103,218`、`tests/run_worker_tests.mjs:7-23,45-74`、`.github/workflows/deploy.yml:62-68`
- **問題:** DBテストはCIから実行されず、ローカルrunnerも実行せずに過去の合格を表示して終了0にする。DEV DB内テストとリポジトリのテストも一致しない。
- **根拠:** `run_db_tests.mjs` は `最後に確認した結果: 605本すべて合格（2026-08-01）` と出して `process.exit(0)` するだけ。DEVへ直接問い合わせた現行結果は607/607だが、DB内だけに `t11` / `t12` があり、リポジトリは01〜10のみ。99_runnerも01〜10しか欠落検知しない。リポジトリ内テストに `is_sample`、`cover_pos`、`share_url` の参照は0件だった。Worker 92件は純粋関数を正規表現抽出して実行する方式で、実際のfetch/PostgREST列契約を通らない。また05_banは033でDROPされる `public.is_banned(uuid)` を今も呼ぶため、fresh schemaと矛盾する。
- **壊れる条件:** H-01のStorage破壊やH-02の列不存在、H-07のround-trip損失があっても、画面102件・paint 23件・Worker 92件・DEV DB 607件はすべて緑になる。
- **推奨する修正:** リポジトリだけから空のDEV DBを構築し、全migrationとテストを実行するCIを必須化する。t11/t12をソース化し、runnerの期待群をmanifest化する。aged Storage objectを含む035/036、sample権限とランキング、`cover_pos` round-trip、Workerルートと本番schema契約の統合テストを追加する。
- **確度:** Confirmed

### M-01 — `cover_pos` が無関係な編集保存でNULLへ戻る

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 今回変更による開発版のデータ回帰
- **該当箇所:** `worker/src/worker.js:64-68`、`legacy.html:3912-3920,3945-3956,4268-4280`
- **問題:** 読込側が `cover_pos` を取得しないのに、保存側は常に `cover_pos` を送る。
- **根拠:** Worker初期データのSELECTに `cover_pos` がない。直接Supabase取得は `id,owner_id,title,author_label,memo,grid,is_public,methods,comments_disabled` だけで、`cover_url`、`cover_pos`、`share_url`、`updated_at` がない。`applyRecipe` は `rec.cover_pos` があるときだけ復元し、保存は値がなければ `payload.cover_pos = null` とする。
- **壊れる条件:** DEVには `cover_pos='50% 12%'` の実レコードがあり、値はgridへ複製されていない。この投稿を開いてタイトル等だけ更新すると位置がNULLになり、一覧の切取位置が中央へ戻る。直接取得経路では `currentCoverUrl` もNULLとなり、削除前のStorage処理がカバーを見落とす。
- **推奨する修正:** Workerと直接取得の両SELECTを同じ契約へ揃え、`cover_url,cover_pos,share_url,updated_at` を取得する。公開・非公開の両経路で「読込→無関係編集→保存後も値不変」を検証する。
- **確度:** Confirmed

### M-02 — `share_url` の削除・孤児掃除・バックアップが一貫していない

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 今回追加した画像列のライフサイクル欠落
- **該当箇所:** `legacy.html:3718,3780-3825,4169-4174,4240-4274`、`migrations/036_protect_share_url.sql:38-66,76-124`、`scripts/backup_storage.sh:79-101`
- **問題:** 036はDB関数へshare画像を追加したが、クライアントのStorage API削除、参照判定、保存後掃除、公開分バックアップには追加されていない。
- **根拠:** `imageUrlsOf(grid, coverUrl)` はcover/gridしか集めず、`currentShareUrl` もない。`unusedStoragePaths` の参照条件もcover/gridだけ。保存のたびに乱数付きの新share cardをuploadするが、1時間以内の旧カードはpurge猶予で残り、その後に更新がなければ掃除を再実行する定期経路がない。公開分バックアップのSELECTは `cover_url,grid` のみ。036は `delete from storage.objects` を行うが、SupabaseはStorage schemaをread-only扱いとし、SQLによるmetadata削除では実オブジェクトが孤児化すると明記している。[Delete objects](https://supabase.com/docs/guides/storage/management/delete-objects)、[Storage schema](https://supabase.com/docs/guides/storage/schema/design)
- **壊れる条件:** 1時間以内に同じ投稿を複数回保存する、投稿を削除する、または `storage_paths.local.txt` なしで公開分バックアップを取る。不要なカードが残る一方、必要なカードはバックアップから漏れる。SQL削除後のCDN残存時間は要確認。
- **推奨する修正:** 読込時に `currentShareUrl` を保持し、候補収集、全参照判定、Storage API削除へ含める。保存成功後の旧share削除をoutboxで再試行するか、猶予経過後の孤児掃除をcron化する。バックアップSELECTへ `share_url` を追加し、復元訓練で実体を確認する。
- **確度:** Confirmed。CDN上で実際に見え続ける期間だけ要確認。

### M-03 — 他人が公開画像URLを参照すると、元所有者の画像削除を阻止できる

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 信頼境界／データ削除妨害
- **該当箇所:** `migrations/036_protect_share_url.sql:101-118`、`supabase/schema.sql:164-177`
- **問題:** 削除RPCは削除候補を被害者ownerのStorageフォルダへ絞る一方、「他の投稿・下書きが参照しているか」はowner条件なしで全利用者の行を見る。URL列/gridへ自分のStorage配下だけを保存させるDB制約もない。
- **根拠:** 参照保護条件は `select 1 from public.recipes o where o.id <> rid and (...)` と `select 1 from public.drafts d where (...)` であり、`o.owner_id = r.owner_id` / `d.owner_id = r.owner_id` がない。各利用者はRLSにより自分の投稿を更新できるため、他人の公開Storage URLを自分のcover/grid/shareとして保存できる。
- **悪用手順:** 攻撃者が被害者の公開画像URLを自分の投稿に設定する。被害者が元投稿を削除すると、SECURITY DEFINER RPCは攻撃者の参照を見つけ、本文だけを削除して画像を残す。公開URLを知る攻撃者は削除後も画像保持を妨害できる。
- **推奨する修正:** 参照として保護するのは同一ownerの行だけにし、両サブクエリへowner一致を追加する。保存時にも全画像pathが投稿owner配下であることをDB側で検証する。文字列LIKEではなく正規化Storage pathを正確比較し、「同一owner共有は保持・別owner参照は無視」のテストを追加する。
- **確度:** Confirmed（コード経路）。本番での破壊的な悪用再現は行っていない。

### M-04 — 既存の2枚目写真が非表示・編集不能になる

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 今回の1枚UI化による開発版の回帰
- **該当箇所:** `legacy.html:2167-2170,2649-2653,2697-2763,3062-3064,3112-3114,4232-4256`
- **問題:** 旧データの写真配列は全件保持するが、新UIと閲覧画面は先頭1枚しか見せない。2枚目だけを確認・削除する操作がない。
- **根拠:** `PHOTO_SLOTS = ["サムネイル"]`、閲覧は `.slice(0, 1)`。一方migrateは全文字列を保持し、保存も `snap.photos` 全件をStorage URL化して `g.photos` へ残す。カード生成は `.slice(0,2)` のため、画面で見えない2枚目を使うこともある。
- **実測:** PROD公開2件は両方とも `grid.photos.length=2`。DEVでも2枚の公開投稿があり、画面では完成写真と編集枠が各1件だけだった。
- **壊れる条件:** この開発版を公開すると、現在の全公開投稿で2枚目が閲覧不能になる。1枚目を残したまま2枚目だけ削除できず、非表示データとStorage容量が残る。
- **推奨する修正:** 旧2枚目を「旧追加写真」として表示し、個別削除または色グループ写真への移動を可能にする。明示同意なしに隠さない。旧2枚fixtureの閲覧・編集・保存テストを追加する。
- **確度:** Confirmed

### M-05 — `cover_pos` が検索・カテゴリ等の表示契約から漏れている

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 今回追加した表示機能の不整合
- **該当箇所:** `migrations/012_scale_guards.sql:13-25`、`migrations/034_sample_recipe.sql:68-76,108-120`、`index.html:1147-1163,1535,1574-1580,3123-3129,3187-3238`
- **問題:** 一覧によって切取位置が反映されたり中央に戻ったりする。
- **根拠:** `search_recipes` の戻り値は `id,title,cover_url,...` で `cover_pos` がなく、通常検索経路はその結果をカードへ渡す。クライアントfallbackだけは `cover_pos` をSELECTする。塗料作例、カテゴリ代表、話題の作例、popular_paints/sample_recipeの契約にも位置情報がない。
- **壊れる条件:** `50% 12%` 等を設定した投稿を検索結果・塗料・カテゴリ等から見る。トップの一部では意図した中心、別画面では中央となり、被写体が切れる。
- **推奨する修正:** 戻り型変更が必要なRPCはDROP/再CREATEし、`cover_pos` を返す。全SELECTとtile helperへ値を伝播し、同一fixtureを全表示面で比較するDOM/visual testを追加する。
- **確度:** Confirmed

### M-06 — 見本投稿UIは常時hiddenで、急上昇ランキング除外も漏れている

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 今回追加した機能の未完成回帰
- **該当箇所:** `index.html:722-731,3351-3356`、`migrations/034_sample_recipe.sql:68-76,97-129`、`migrations/033_reconcile_catalog.sql:101-117`
- **問題:** DBへ見本を設定してもトップに表示されず、見本の塗料は急上昇集計へ混入する。
- **根拠:** `sampleSec` は `hidden` で作られたが、リポジトリ全体に `sample_recipe` RPC呼出しや `sampleSec` の解除処理がない。起動処理も `renderReco` 等だけ。034はpopular_paints/popular_methodsへ `not r.is_sample` を加えるが、`rising_paints` は同条件を持たない。`sample_recipe` の戻り値にも `cover_pos` がない。
- **壊れる条件:** 管理者が見本を指定しても利用者には一切表示されない。7日以内の見本投稿は急上昇のrecent/total/scoreへ入る。
- **推奨する修正:** `renderSample()` を実装し、0件・成功・通信失敗を分ける。risingも除外し、sample RPCへ `cover_pos` を追加する。指定、非公開化、BAN、解除、0件の統合テストを追加する。
- **確度:** Confirmed。調査時点ではPROD/DEVとも見本指定0件なので、現在の画面上の実害はまだない。

### M-07 — cover画像の外部追跡対策をavatar/headerから回避できる

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 既存修正の回避経路／本番にも存在
- **該当箇所:** `index.html:997-1011,1025-1036,1731-1742,1757-1760,2576-2600,2646-2647`、`supabase/schema.sql:152-158,208-209`、`migrations/033_reconcile_catalog.sql:150-165,401-408`
- **問題:** 新しい `safeThumbSrc` はcover画像を自サイト/Supabase originへ限定したが、avatar/headerは任意HTTP(S) URLを表示する。
- **根拠:** `safeUrl` は構文文字を弾くだけで任意HTTP(S) originを返す。公開プロフィールではavatarを `<img src>`、headerを `backgroundImage` に設定し、ログイン中の `avatarMarkup` は `safeUrl` すら通さない。profilesの本人UPDATE RLSとguardには画像origin・owner path制約がない。
- **悪用手順:** 攻撃者が自分の `avatar_url` / `header_url` を追跡用HTTPS URLへRESTで更新する。別利用者がプロフィールや攻撃者の表示を開くと、攻撃者サーバへIP、UA、時刻が送信される。
- **推奨する修正:** リンク用 `safeUrl` と画像用 `safeImageUrl` を分離し、全avatar/header sinkを自サイトまたは対象Supabase Storage originへ限定する。DB側でも許可origin、owner path、最大長を検証する。プロフィール、ドロワー、サイドバー、コメントの全sinkをテストする。
- **確度:** Confirmed

### M-08 — 開発用ログイン資格情報を同一LANへ平文配信する

- **重大度:** Medium
- **告知前に直すべきか:** no（本番経路外。ただし開発継続前には修正推奨）
- **分類:** DEV限定の信頼境界
- **該当箇所:** `scripts/dev.sh:34-43,57-60`、`worker/src/worker.js:580-598,810-813`
- **問題:** 開発サーバを平文HTTPで `0.0.0.0` にbindし、全HTMLへ開発アカウントのemail/passwordを埋め込む。
- **根拠:** Workerは `window.DEV_AUTOLOGIN={email,password}` を生成し、LOCAL_DEV時のHTMLへ注入する。独立ポートで再現し、loopbackとLAN IPv4の両方からHTTP 200、HTML内にemail/passwordフィールドがあることを確認した（値は記録・掲載していない）。
- **悪用手順:** 同一Wi-Fiの第三者または平文通信を観測できる者がHTMLを取得し、開発アカウントへログインしてDEVデータを変更・削除する。DEV投稿は本番Storage画像を参照しているため、権限設計を誤ると影響評価も難しくなる。
- **推奨する修正:** 標準bindを `127.0.0.1` にする。明示的な `--lan` では資格情報注入を無効化し、手動ログインまたは短命・低権限のワンタイム手段を使う。可能ならローカルHTTPSを使い、`.dev.vars` は0600にする。
- **確度:** Confirmed。本番配信物に当該scriptはなく、LOCAL_DEVの本番設定も確認されていないため、本番漏洩とは判定していない。

### M-09 — 開発サーバ二重起動で先に動いているサーバを壊す

- **重大度:** Medium
- **告知前に直すべきか:** no（DEV限定）
- **分類:** 開発版リテイク時の再現性低下
- **該当箇所:** `scripts/dev.sh:24-32,57-60`、`worker/wrangler.toml:40-45`、`scripts/build_public.mjs:57-59`
- **問題:** ポート競合を確認する前に共有 `public/` を再帰削除・再生成するため、2本目の起動失敗が1本目のassetを壊す。
- **根拠:** Wrangler起動時buildは `rmSync(OUT, { recursive:true, force:true })` を実行し、dev.shにはport lock/preflightがない。8787稼働中に2本目を起動する再現で、2本目はport競合で失敗し、先行serverは500/503になった。並行buildでは `ENOTEMPTY` も観測した。
- **壊れる条件:** ターミナルを跨いでdev.shを二重起動する、または別のbuildと重なる。画面上はアプリ回帰に見えるため、誤診・上書き修正を誘発する。
- **推奨する修正:** build前にport/process lockを取る。プロセス別staging directoryへ構築してatomic renameするか、各dev process専用の出力dirを使う。
- **確度:** Confirmed

### M-10 — 同時編集が後勝ちで、先の変更を無警告に消す

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 前回解消済みとされたが現行コードに残る既存欠陥
- **該当箇所:** `supabase/schema.sql:61,96-108`、`legacy.html:3920,4260-4282,4358-4365`
- **問題:** `updated_at` はあるが、レシピ更新に楽観ロック/CASがない。今回追加した `cover_pos` / `share_url` も古いタブのpayloadで上書きされる。
- **根拠:** 読込SELECTは `updated_at` を取らず、UPDATE条件は `.eq("id", currentRecipeId)` だけ。下書きもidだけで更新する。
- **壊れる条件:** 同じ投稿をA/Bの2タブまたは2端末で開き、A保存後に古いBを保存する。Aの本文、画像、位置、共有カードをBが無警告で上書きする。
- **推奨する修正:** 読込時の `updated_at` またはversionを保持し、`id + version` 一致時だけ更新するRPCへ寄せる。0件更新ならreload/mergeを促し、新規upload済みファイルも安全に掃除する。2クライアント競合テストを追加する。
- **確度:** Confirmed（コード経路）。本番データを使う破壊的再現は行っていない。

### M-11 — バックアップ異常が監視へ伝わらず、ローカル秘密・画像が0644

- **重大度:** Medium
- **告知前に直すべきか:** yes
- **分類:** 運用・事業継続
- **該当箇所:** `scripts/backup_storage.sh:45-66,135-149`、`scripts/check_backups.mjs:17-18,71-80,131-135`
- **問題:** バックアップ鮮度がbadでも終了コード0で、監視に組み込めない。バックアップ作成時のumask/chmodもなく、DEV資格情報と非公開画像のローカル権限が広い。
- **根拠:** `checkBackups()` はworstを計算するが直接実行時は無条件に `process.exit(0)`。未来日での検査でもbad表示＋exit 0を確認した。実ファイル確認では `worker/.dev.vars`、`scripts/storage_paths.local.txt`、Storage backup 233ファイルが0644、親ディレクトリが0755だった。
- **壊れる条件:** cron/監視が終了コードだけを見ると、30日超の古いバックアップでも成功扱いになる。同一Macの同一group別アカウントまたはローカル侵害者がDEV認証情報・非公開画像を読める。
- **推奨する修正:** `--fail-on-stale` を追加して監視では非0終了させる。backup script冒頭を `umask 077` とし、秘密/manifest/画像を0600、ディレクトリを0700へ変更し、既存ファイルも権限修正する。M-02の `share_url` も対象へ加える。
- **確度:** Confirmed

### L-01 — 現worktreeはasset version不一致で、正規CIなら公開不能

- **重大度:** Low
- **告知前に直すべきか:** yes
- **分類:** リリースブロッカー
- **該当箇所:** `index.html:876-883`、`legacy.html:1084-1091`、`diagnostics.html:56-62`、`scripts/bump_asset_version.mjs:167-173`
- **問題:** HTMLの `?v=` が現在のconfig/methods fingerprintと一致しない。
- **根拠:** `node scripts/bump_asset_version.mjs --check` はexit 1。期待値 `1cefac5a` に対してHTMLは `3e1a7c81` だった。
- **壊れる条件:** H-05を直すとCIでdeployが止まる。手動deployで迂回すると旧config/JSと新HTMLがキャッシュ混在する可能性がある。
- **推奨する修正:** 変更完了後にbump scriptを実行し、再checkする。手動を含む単一deploy commandの先頭で必須化する。
- **確度:** Confirmed

## 確認したが追加指摘なし

- **本番と開発の分離:** 配信4ファイルのhash、DB新列の有無、HTTP応答を別々に確認した。今回の未コミットUI/Workerは現在の本番へ出ていない。
- **RLS・認証認可:** 旧 `public.is_banned(uuid)` はPROD/DEVともData APIで404、`internal` schemaは両環境とも406で、他人のBAN状態列挙の再発は確認しなかった。036の削除RPCも認証、owner/admin判定、対象pathのowner folder制限を維持している。ただしH-04/M-03の環境差・参照妨害は残る。
- **Worker XSS・origin検証:** share/coverの採用はURL origin完全一致で、外部originやprefix偽装をOGPへ直接出す新しい回避経路は確認しなかった。保存値のHTMLエスケープも維持されている。ただしH-01の「許可originだが実体がないURL」は別問題として残る。
- **`sw.js`:** worktreeとHEADが同一で、Cache APIを使わないnavigation network-firstのまま。今回変更によるService Worker cache回帰は確認しなかった。
- **機械テスト:** 最新worktreeで画面102件、paint 23件、Worker 92件は合格。DEV DB `public.test_report()` は607/607合格。ただしH-06のとおり、今回の主要回帰はカバレッジ外である。
- **不確実な候補の除外:** `legacy.html` に同一storage keyのSupabase clientが3個あるが、現行環境でrefresh競合の実障害を再現していないため、確定指摘には含めなかった。
