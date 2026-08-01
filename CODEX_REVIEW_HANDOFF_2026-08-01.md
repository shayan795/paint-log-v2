# plamo-paint.com フル監査 — Claude Code 引き継ぎ

監査基準日: 2026-08-01 JST  
監査対象HEAD: `f2cbf258c9f40d2bbe705d7c59cb2b76edab1b20`  
監査対象: 現行コード全体、Git履歴、本番への非破壊確認、Supabase RLS/RPC/Trigger/Storage、Cloudflare Worker、無料枠、バックアップ、モデレーション、法務表示  
監査結果: Critical 0 / High 12 / Medium 21 / Low 5

## Claude Codeへの依頼

以下を上から1件ずつ実コード・実環境へ当て、各項目を必ず次のいずれかへ分類すること。

- `CONFIRMED`: 記載どおり再現または静的に成立する
- `PARTIAL`: 問題はあるが、条件・影響・重大度が記載と異なる
- `FALSE_POSITIVE`: 防御または仕様により成立しない
- `NEEDS_PROD_CHECK`: コードだけでは決められず、本番設定・実測が必要

推測のまま修正しない。分類時には、確認したSQL、HTTP結果、ブラウザ挙動、テスト名などの根拠を残すこと。

修正は小さい単位で行い、最低限次を満たすこと。

1. 修正前に再現テストを追加する。
2. RLS、Trigger、RPC、列GRANTを単体ではなく組み合わせて確認する。
3. Supabaseの変更は最新公式仕様を確認する。特にStorageの物理削除、JWT削除後の有効期間、Data API GRANTを確認する。
4. migrationは既存番号を書き換えず、新しい連番migrationとして追加する。
5. migration適用後にcatalogと実APIの両方で効果を検証する。
6. `node tests/run_front_tests.mjs`、`node tests/run_paint_tests.mjs`、`node tests/run_worker_tests.mjs`を実行する。
7. DBテストが実行不能なまま「全合格」としない。
8. 本番反映・Git push・履歴書換え・Storage削除は、オーナーの明示承認後に行う。

## 現在確認できている状態

- ローカルworktreeは監査時点でclean。
- `main`は`origin/main`より1 commit先行している。
  - local: `f2cbf258c9f40d2bbe705d7c59cb2b76edab1b20`
  - remote: `3a3d7e924e1538583db9947db19ac9dd9199f1c6`
- 本番にはmigration 021相当と現行HTMLが手動反映済み。
- NodeテストはFront 92/92、Worker 92/92、Paint 23/23が合格。
- DB runnerは `HTTP 401 {"code":"42501", ... "permission denied for table recipes"}` で実行不能。
- 本番で任意authenticatedユーザーから他人の`has_password`と`banned_at`を列挙できた。
- 本番の`TURNSTILE_SITE_KEY`は`null`。
- 本番でBAN用1引数RPCは不存在、2引数関数は存在することを非破壊確認済み。
- 本番の代表coverは原寸315,640 bytes、変換後27,305 bytesで、現在は双方HTTP 200。

## High

### H-01 Git履歴からStorage画像URLを復元できる

- 告知前: yes
- 場所: `scripts/storage_paths.txt:1-81`（commit `a26b4c9c0b745c3a57c84ecda5a94fcd7ef2a232`、現HEADでは削除済み）、`privacy.html:84-86`
- 根拠: 公開Git履歴に81個のStorageパスが存在した。27パスが現在も匿名HTTP 200で取得でき、8パスは現在の公開レシピ・公開プロフィールから参照されていない。
- 要確認: 8件が非公開、下書き、削除済み旧画像のどれに当たるか。パスの実値はレポートへ再掲しないこと。
- 壊れる条件: Git履歴からURLを復元して直接取得される。非公開なら漏えい、削除済みなら削除・保持方針違反。
- 推奨: 81パスを漏えい済みとして分類し、不要物をStorage APIで物理削除。非公開画像はprivate bucket＋新規キー＋署名URLへ移行。Git履歴削除だけで済ませない。
- 必須テスト: 古いURLが403/404、匿名list不可、所有者だけ署名URL取得可。

### H-02 画像ライフサイクルが非原子的

- 告知前: yes
- 場所: `migrations/013_purge_unreferenced_images.sql:23-87`、`migrations/015_test_found_fixes.sql:83-105`、`migrations/017_codex_fixes.sql:57-109`、`legacy.html:3448-3491,3808-3823,3875-3912,4068-4083`、`index.html:2424-2446`
- 根拠:
  - RPCは `delete from storage.objects` を使う。Supabase公式仕様上、SQL削除では物理ファイルが消えない。
  - 削除は `.then(purgeStorage).then(...delete_*_with_images...)` でStorageを先に消す。
  - 保存は画像を先にアップロードし、その後DB INSERT/UPDATEする。
  - 退会前のStorage API削除はprofile bucketだけ。
- 壊れる条件:
  - Storage削除成功後にRPC失敗で、DB行だけ残り画像が破損。
  - 複数アップロードの一部成功後にDB失敗で物理孤児。
  - DB成功後のレスポンス消失・再試行で重複投稿・重複画像。
  - SQL掃除でmetadataだけ消え、容量guardの使用量がリセットされる。
- 推奨: service-role Edge Function等に削除outboxを作り、DBの削除意図とjob作成を同一トランザクション化。Storage API削除は冪等・再試行可能にする。アップロードはstaging prefix＋固定idempotency key。
- 必須テスト: Storage成功→DB失敗、partial upload、DB commit後response loss、管理者による他人の投稿削除、退会、再試行。

### H-03 Storage容量guardにUPDATE回避・競合・全体上限欠落がある

- 告知前: yes
- 場所: `migrations/019_upload_guard.sql:42-163`、`migrations/015_test_found_fixes.sql:223-241`
- 根拠:
  - triggerは `before insert`、代替policyも`for insert`だけ。
  - 既存の所有者policyは`for all`でUPDATEを許可。
  - 使用量はSELECT後の判定だけでlock・予約行がない。
  - triggerと代替policyが双方失敗してもNOTICEだけでmigration成功。
  - 1人200MBだけでプロジェクト全体1GBのhard limitがない。
- 要確認: 本番catalog上でtriggerまたはrestrictive policyが実在し、有効か。
- 壊れる条件: 既存オブジェクトUPDATE、並行INSERT、6アカウント×200MB、SQL孤児掃除後の再アップロード。
- 推奨: INSERT/UPDATE両方をguard。UPDATEはOLDとの差分で計算。所有者別atomic ledger/advisory lock、全体hard ceiling、migration末尾のcatalog assertを追加。
- 必須テスト: Storage APIのinsert/update/upsert、並行upload、BANユーザー、退会済みJWT、global quota。

### H-04 退会後も有効JWTで公開Storageへ書き込める

- 告知前: yes
- 場所: `migrations/015_test_found_fixes.sql:94-108,223-241`、`migrations/019_upload_guard.sql:47-65`
- 根拠: `delete_user()`はauth userを削除するが、Storage policyはJWT内の`auth.uid()`とfolderだけを確認する。Supabaseでは削除前に発行済みのaccess tokenは期限まで有効。
- 壊れる条件: JWT保存→退会→期限切れまで削除済みUUIDの公開folderへupload。profileがないためBAN判定もfalse相当。
- 推奨: session revokeを先行し、Storage書込み時に`session_id`が`auth.sessions`へ現存することとactive profileを確認。重要操作はgateway経由。
- 必須テスト: 退会直前tokenによるrecipe/profile bucketへのinsert/update/deleteを全拒否。

### H-05 BAN後の同一メール再登録防止が動作していない

- 告知前: yes
- 場所: `migrations/016_moderation_and_limits.sql:133-142`、`migrations/017_codex_fixes.sql:140-145`、`tests/db/05_ban.sql:194-217`
- 根拠: 関数定義は`remember_banned_email(target uuid, reason text)`だが、呼出しは`remember_banned_email(target)`。`exception when others then null`で失敗を隠す。
- 壊れる条件: BAN→`delete_user()`→同一メール再登録で新profileがBANされない。
- 推奨: 2引数で呼び、例外を握り潰さずBANと同一トランザクションにする。解除時のdenylist保持/削除方針も決める。
- 必須テスト: BAN→退会→同一メール再登録、BAN解除→退会→再登録、記録失敗時のrollback。

### H-06 通報後に編集・非公開化されると証拠を確認できない

- 告知前: yes
- 場所: `migrations/018_report_target.sql:22-54`、`supabase/schema.sql:164-172`、`index.html:2760-2794`
- 根拠: recipe通報はtitle/coverだけを保存し、`target_body=null`。管理者はrecipes SELECT policyの例外に含まれず、管理画面も現在の`/r/:id`を開くだけ。
- 壊れる条件: 通報後に本文を正常内容へ編集、または非公開化すると、運営者が元内容を確認できない。
- 推奨: 通報時点の制限済み本文・grid・画像キー・hashを改変不能な証拠領域へ保存。証拠画像はprivate bucketへ複製し、管理者閲覧は監査付きRPCにする。
- 必須テスト: 通報→編集、通報→非公開化でも元証拠を管理者だけが閲覧可能。

### H-07 BANしても既存違反投稿が公開され続ける

- 告知前: yes
- 場所: `migrations/017_codex_fixes.sql:123-158`、`index.html:2816-2840`
- 根拠: `set_user_ban`はprofile停止と通知だけ。UIも「既存の投稿は残ります」と表示する。
- 壊れる条件: 違法・権利侵害・荒らし投稿が一覧、検索、sitemap、共有URLで公開され続ける。
- 推奨: BAN時に投稿・コメントを可逆quarantineし、公開面から即除外。証拠保全と公開停止を分離。
- 必須テスト: BAN直後に一覧、REST、Worker、sitemap、コメントから全て非表示。解除時の復元方針も確認。

### H-08 `notify_self`の自己申告`system`でレート制限を回避できる

- 告知前: yes
- 場所: `supabase/schema.sql:431-439`、`migrations/017_codex_fixes.sql:208-231`
- 根拠: クライアント指定の`_type/_title/_body/_link`をそのままINSERTし、`NEW.type='system'`だけで件数制限をskip。type/linkに長さ制限がない。
- 壊れる条件: authenticatedユーザーが`system`＋巨大linkで連打し、Free DB 500MBを埋める。
- 推奨: クライアント用typeを固定whitelist化し、全列に上限。`system`は一般ユーザーがEXECUTEできない別関数へ分離。
- 必須テスト: クライアントからsystem拒否、link/type上限、rate超過、内部system通知は成功。

### H-09 匿名eventsがDB容量攻撃の入口になっている

- 告知前: yes
- 場所: `supabase/schema.sql:390-405`、`migrations/019_upload_guard.sql:196-224,230-238`
- 根拠:
  - events INSERT policyは`with check(true)`。
  - 空sessionは個別300件制限を通らず、10,000件/時保存可能。
  - 最大約2KBで約20MB/時、索引分は別。
  - session別throttle行をglobal判定より先にINSERTするため、global上限後も異なるsession IDで行を増やせる。
- 壊れる条件: 空sessionを約2.78 req/s、または毎回異なるsession IDで送信し続ける。
- 推奨: global fixed keyを最初に判定、空session拒否、高カーディナリティclient keyをDBに保存しない。Cloudflare rate limit/sampling＋短いTTL/partition。
- 必須テスト: 空session、10,001件目、毎回異なるsession、cleanup、並行request。

### H-10 全静的assetがCloudflare Worker日次枠を消費する

- 告知前: yes
- 場所: `worker/wrangler.toml:9-12,30-41`
- 根拠: catch-all route＋`run_worker_first=true`。Free Workersは100,000 requests/dayで、対象assetは超過時に静的fallbackせず429。
- 壊れる条件: 平均約1.16 req/sで日次枠を消費。通常ページも複数asset分を使い、サイト全体が429。
- 推奨: Worker-firstを`/r/*`、`/sitemap.xml`、`/healthz`等だけへ限定。静的headerは`_headers`へ。
- 必須テスト: JS/画像はWorker invocation対象外、動的routeは従来機能とsecurity headerを維持。

### H-11 256KB未満gridでもWorker CPU上限を超え得る

- 告知前: yes
- 場所: `worker/src/worker.js:229-275`、`migrations/005_review_fixes2.sql:70-76`、`tests/run_worker_tests.mjs:270-277`
- 根拠: `procs.filter(...rows.some...)`後に全rows×usedProcsを走査。3,400 procs＋3,400 rows、258,456 bytesがDB制約内で、ローカル約81-112ms。Free Worker CPUは10ms/request。
- 要確認: Edge実機でError 1102になるか。ただし入力受理とO(procs×rows)は確定。
- 推奨: DBでprocs/rows/cells数を個別制限。使用proc IDをSetで線形収集し、出力側にも上限。
- 必須テスト: 制約境界、3,400×3,400相当、Worker runtime CPU、ブラウザrender時間。

### H-12 DBテストとmigrationがdeploy gateになっていない

- 告知前: yes
- 場所: `tests/run_db_tests.mjs:11-54`、`.github/workflows/deploy.yml:60-85`、`README.md:181-222`
- 根拠: runnerは手動構築済みdev RPCを呼ぶだけ。現HEADでは401/42501で未実行。deployはFront/Paint/Workerのみ。READMEは019を最新として020/021を復旧手順から落としている。
- 壊れる条件: wrong-arity、ACLずれ、Storage guard作成失敗でもCIが緑。空環境復旧で020/021欠落。
- 推奨: 一時Supabase/Postgresへschema＋001以降全migration＋testsを適用するCI、migration ledger、本番schema version検査を必須化。
- 必須テスト: clean DB restore、全migration二重適用、RLS cross-user、Storage API integration、deploy gate失敗。

## Medium

### M-01 任意の外部画像URLを他ユーザーに取得させられる

- 告知前: yes
- 場所: `supabase/schema.sql:50-59,206-209`、`index.html:966-977,1001-1004,1405-1429,3008-3170`、`legacy.html:2798-2808,3762-3769,4434-4527,4597`
- 根拠: cover/grid/avatar/header URLにStorage origin・bucket・所有者folder制約がなく、`thumbUrl()`はStorage以外をそのまま返す。
- 壊れる条件: 追跡用URLを直接APIで保存し、閲覧者のIP/UA/時刻/referrerを第三者へ送信。画像の後日差替えも可能。
- 推奨: DB allowlist、全画像sinkの共通validator、CSP `img-src`限定。

### M-02 `header_url`から保存型CSS注入が可能

- 告知前: yes
- 場所: `index.html:955-966,2502-2506`
- 根拠: `safeUrl()`はhttp(s)接頭辞だけ。未引用の`url(...)`へ連結し、HTML escapeは`)`・`;`を無害化しない。
- 壊れる条件: `https://...);position:fixed;...`を保存し、プロフィールへoverlay等を適用。
- 推奨: HTML文字列でstyleを生成せず、検証済みURLをDOM propertyへ代入、または`<img>`化。

### M-03 本番認証にCAPTCHAがない

- 告知前: yes
- 場所: `src/config.js:22-35`、`index.html:1744-1777,2139-2232`
- 根拠: 本番site keyはnull。CAPTCHAなし不正ログインはcaptcha-requiredではなく通常のinvalid_credentials。
- 壊れる条件: Auth API直接呼出しでcredential stuffing、登録・確認再送・password resetによるメール枠消費。
- 推奨: site key配信確認後にSupabase側enforcement。有効化順序を逆にしない。

### M-04 authenticatedが他人の認証方式・BAN状態を列挙できる

- 告知前: yes
- 場所: `supabase/schema.sql:152-158`、`migrations/014_user_ban.sql:106-107`、`migrations/021_my_profile.sql:9-56`
- 根拠: profiles SELECT RLSは`using(true)`。021は本人RPC追加だけでauthenticatedのtable SELECTをrevokeしていない。本番で全profileの`has_password`,`banned_at`を取得できた。
- 推奨: authenticated table SELECTをrevoke、公開列だけregrant、内部列は`my_profile()`、管理列はadmin RPC。

### M-05 exportと設定画面がAPI失敗を成功・未設定として扱う

- 告知前: yes
- 場所: `index.html:1123-1147,1163-1171`
- 根拠: `{error}`をthrowせず、exportは`profile:null`,`recipes:[]`でも成功toast。設定も空profileから認証方式を推定。
- 推奨: 各response.errorをthrowし、全成功後だけdownload。error state＋再試行UI。

### M-06 複数タブ・端末編集でlost updateが起きる

- 告知前: yes
- 場所: `legacy.html:3908-3912,3988-3993`
- 根拠: `update(payload).eq(id)`だけでversion/旧updated_at条件がない。
- 推奨: optimistic concurrency、0行更新時の競合UI、merge/再読込。

### M-07 Worker上流fetchにdeadlineがなく一部rejectが503にならない

- 告知前: yes
- 場所: `worker/src/worker.js:64-93,424-440,594-605,687-705`
- 根拠: recipe取得fetchがtry外。全上流fetchにアプリ側timeoutなし。
- 推奨: AbortSignal timeout付き共通wrapper、reject/timeoutを503＋Retry-Afterへ統一。

### M-08 コメント取得失敗が0件または永久loadingになる

- 告知前: yes
- 場所: `legacy.html:4431-4449,4735-4745`
- 根拠: resolved errorを空配列へ変換、catchなし、ログイン中は`is_admin`成功時しかrenderしない。
- 推奨: error/empty分離、再試行UI、admin判定失敗時は非管理者へ倒す。

### M-09 通知上限到達がコメント・clip本体までrollbackする

- 告知前: yes
- 場所: `migrations/017_codex_fixes.sql:213-231`、`supabase/schema.sql:442-458,654-695`
- 根拠: 100件でraise exceptionし、AFTER trigger内の通知INSERTから元操作までrollback。
- 推奨: 上限時は通知だけdropするかoutboxへ分離。

### M-10 コメント削除時の通知伏せ字修正が配線されていない

- 告知前: yes
- 場所: `migrations/017_codex_fixes.sql:187-203`、`supabase/schema.sql:654-687`
- 根拠: scrubは`source_comment_id=OLD.id`を見るが、通知INSERTがsource_comment_idを保存しない。
- 推奨: 全comment/reply通知へNEW.idを保存し、既存通知をredact。

### M-11 コメント通報のreviewed通知がrecipe ownerへ送られる

- 告知前: yes
- 場所: `supabase/schema.sql:509-527`、`migrations/018_report_target.sql:15-18`
- 根拠: status triggerは`target_user_id`を使わずrecipe ownerへ「あなたの投稿」と送信。
- 要確認: product上、recipe ownerにも通知する意図があるか。少なくとも違反コメント投稿者への通知は別途必要。
- 推奨: target_type別に通知先・文面を分離。

### M-12 下書き・非公開投稿・コメント・通知上限が並行処理で超過する

- 告知前: yes
- 場所: `supabase/schema.sql:608-621,892-925`、`migrations/017_codex_fixes.sql:213-231`
- 根拠: count/max後の判定に共有lockなし。recipe INSERTは別triggerのlockが効くが、public→private UPDATE、draft、comment、notificationは未保護。
- 推奨: owner単位advisory lock、atomic ledger、並行transactionテスト。

### M-13 外部入力text/array/statusにDB上限がない

- 告知前: yes
- 場所: `supabase/schema.sql:50-60,293-301,365-373`
- 根拠: recipe title/memo/methods、report reason/detail/status、inquiry category/body/statusに長さ・要素数・enum制約なし。
- 推奨: byte/char/array数上限、enum whitelist、境界値テスト。

### M-14 軽量化後のsearch RPCも匿名からgrid全走査できる

- 告知前: yes
- 場所: `migrations/012_scale_guards.sql:14-47`
- 根拠: responseからgridを外しただけで、条件は`r.grid::text ilike '%...%'`。匿名実行可、検索語長・rate制限なし。
- 推奨: 保存時search document/tsvector、GIN/trigram、検索語長とrate制限。

### M-15 規約同意をクライアントが自己申告でき投稿時に検査されない

- 告知前: yes
- 場所: `supabase/schema.sql:164-170,206-211`、`index.html:2153-2156,2273-2275`
- 根拠: client時刻を本人UPDATEし、recipe/comment policyは現在版同意を確認しない。
- 推奨: versioned consent ledgerをserver timestampで記録し、現在版未同意のwriteを拒否。

### M-16 公表保持期間と実際の削除条件が一致しない

- 告知前: yes
- 場所: `privacy.html:114-121,130-131`、`terms.html:112-113`、`migrations/019_upload_guard.sql:230-238`、`README.md:241-250`
- 根拠: open report/inquiryは2年を超えても削除されない。運営者ローカルbackupがprivacyの保存先説明にない。画像即時削除もH-02のとおり不成立。
- 推奨: hard retention、削除ledger、backup expiryを実装し、privacyを実態へ合わせる。

### M-17 backup checkerが破損・未完了backupを正常判定する

- 告知前: yes
- 場所: `scripts/check_backups.mjs:32-45,55-113`、`scripts/backup_storage.sh:62-75,131-168`
- 根拠: 日付名だけでfresh判定し常にexit 0。開始前にdirectory作成、最終fileへ直接curl、既存fileをhash/size確認なしでskip。
- 推奨: `.part`→SHA/件数/remote size検証→atomic rename→`.complete`。異常時非0、restore drill。

### M-18 未知paint IDで位置参照へ戻り誤色化が再発する

- 告知前: yes
- 場所: `legacy.html:1857-1867`、`migrations/020_paint_stable_id.sql:175-185`、`tests/run_paint_tests.mjs:78-81`
- 根拠: `c.id`未発見でも`c.i`へfallbackし、テストもその挙動を正としている。
- 推奨: idが存在するが未知なら不明/廃番表示。位置fallbackはid自体がない旧データだけ。

### M-19 Freeでは提供対象外の画像変換へ帯域削減を依存している

- 告知前: yes
- 場所: `index.html:967-980`
- 根拠: `/render/image/`失敗時に原寸へfallback。Supabase公式ではImage TransformationsはPro以上。本番では現在変換成功しているため、Free申告との不一致理由は要確認。
- 壊れる条件: Freeへの仕様適用で代表画像が27KBから316KBへfallbackし、5GB egress消費が約11倍。
- 推奨: upload時に400px thumbnailを事前生成して保存し、`srcset`利用。

### M-20 本番tokenを持つstepで未固定npm packageを取得する

- 告知前: yes
- 場所: `.github/workflows/deploy.yml:38-40,76-85`、`worker/package.json:12-14`
- 根拠: token環境下で`npm install --no-save wrangler@4`。lockの4.104.0ではなく確認時4.118.0へ解決。Actionsも可変`@v4`。
- 推奨: `npm ci`、exact lock、`npx --no-install`、Actions full SHA、`permissions: contents: read`、最小権限token。

### M-21 deploy成功表示が実配信内容を証明せず、本番版がremoteにない

- 告知前: yes
- 場所: `scripts/build_public.mjs:28-55,63-109`、`.github/workflows/deploy.yml:44-58,89-104`、Git状態
- 根拠:
  - 必須ROOT_FILES欠落はwarningだけでbuild成功。
  - token未設定はworkflow成功で全step skip。
  - post-checkはHTTP statusだけでSHA一致を見ない。
  - local HEAD `f2cbf25`、origin/main `3a3d7e9`。
- 推奨: 必須file/secret欠落を失敗、artifactへSHA埋込み、post-checkでSHA/security headers/routes確認、現HEADをremoteへ保存。

## Low

### L-01 migration 020再実行で全recipeのupdated_atが変わる

- 告知前: no
- 場所: `migrations/020_paint_stable_id.sql:95-124`、`supabase/schema.sql:95-108`
- 根拠: 差分条件なしの全行UPDATEで`set_updated_at()`が発火。
- 推奨: 結果が`IS DISTINCT FROM`の行だけ更新し、migration ledgerで一度だけ実行。

### L-02 動的routeがPOSTと余分なsuffixを受け入れる

- 告知前: no
- 場所: `worker/src/worker.js:717-750`
- 根拠: method guardより先に動的routeを処理し、`/r/id/arbitrary`は最初のsegmentだけ採用。本番でPOST sitemap/recipeとsuffix付きrecipeが200。
- 推奨: method guardを先頭へ、recipe routeを完全一致UUID regexへ。

### L-03 sitemapのlastmodと5,000件上限が実データを反映しない

- 告知前: no
- 場所: `worker/src/worker.js:594-622`
- 根拠: `created_at`をlastmodに使用し、`limit=5000`でpaginationなし。
- 推奨: `updated_at`使用、paginationまたはsitemap index。

### L-04 Google Fontsへの外部通信がprivacyに未記載

- 告知前: no
- 場所: `privacy.html:105-112`、各HTMLのGoogle Fonts link
- 根拠: 全訪問でGoogleへIP/URL/UA/referrerを送るが、委託先・外部送信説明にGoogleがない。
- 推奨: self-hostまたは送信情報・目的・Google privacy linkを記載。

### L-05 user IDのDB契約とUI契約が不一致

- 告知前: no
- 場所: `migrations/007_audit_fixes.sql:161-167`、`index.html:2257-2268`、`migrations/017_codex_fixes.sql:291`
- 根拠: DBは2-20文字、UIは3-20文字。user_idは後から変更不可。
- 推奨: 3-20文字へ統一し、既存2文字IDの移行方針を決める。

## 今回確認済みで再指摘不要な点

- 匿名から他人の投稿・下書きを削除する旧Critical経路は、login必須、`is distinct from`、anonymous EXECUTE revokeで閉じている。
- BAN本人による`banned_at`直接解除は`guard_profile_admin()`が巻き戻す。
- Storage匿名一覧取得経路は確認できない。H-01は既知URLがGit履歴から漏れた別問題。
- 非公開recipe本文はWorker `is_public=eq.true`、DBは公開または本人のみ。SWもHTMLをcacheしない。
- Worker OGP/JSON-LD/initial dataの既知保存型XSSは、replacement callback、HTML escape、`<`のUnicode escapeで閉じている。
- SWはCache API未使用で、navigate障害時のみ503/no-store。
- 内部ファイルはbuild allowlist＋Worker block、本番404。
- Google OAuthとemail signupは本番Auth設定上で有効。メール到達性の実地確認は別の既知課題。
- 現在の無料サービスと表示から、景表法・特商法・affiliate表示の確定違反は認定していない。
- 未ログイン権利者向けのメール申出導線は存在する。

## 既知事項として重複報告しないもの

次はオーナーが既に把握している。新しい回避経路・修正不備を確認した場合だけ報告すること。

- backup GitHub Actions cronが60日で自動停止する。
- `supabase-js@2`の浮動version。
- 旧gridの`c.i`位置依存そのもの。M-18はmigration 020のfallback不備なので別件。
- recipe本文のSSR未対応という旧状態。現WorkerのSSR範囲は現コードを基準に確認する。
- メール登録の実地未検証。
- トップにサイト説明がない。
- 人気の塗装方法tileが空という旧状態。
- 外部障害監視が未設定。
- reportsがrecipe削除でCASCADEされる既知問題。
- raw.githubusercontent.com配信元の旧問題。現行はWorker同梱assetを基準に確認する。

## 公式仕様リンク

- Supabase Storageの削除: https://supabase.com/docs/guides/storage/management/delete-objects
- Supabase User削除後のJWT: https://supabase.com/docs/guides/auth/managing-user-data
- Supabase Storage Access Control: https://supabase.com/docs/guides/storage/security/access-control
- Supabase CAPTCHA: https://supabase.com/docs/guides/auth/auth-captcha
- Supabase Free quotas: https://supabase.com/docs/guides/platform/billing-on-supabase
- Supabase Database size: https://supabase.com/docs/guides/platform/database-size
- Supabase Image Transformations: https://supabase.com/docs/guides/storage/serving/image-transformations
- Cloudflare Workers limits: https://developers.cloudflare.com/workers/platform/limits/
- Cloudflare Static Assets billing: https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/
- GitHub Actions secure use: https://docs.github.com/en/actions/reference/security/secure-use
- Google Fonts privacy: https://developers.google.com/fonts/faq/privacy

## 完了条件

- 全38件に分類と根拠が付いている。
- `CONFIRMED`と`PARTIAL`には再現テストがある。
- Highの修正後にRLS/RPC/Trigger/Storage APIを含む統合テストが通る。
- clean DBへ全migrationを適用して復旧できる。
- devとproductionのGRANT/RLS/function signature/schema versionが一致する。
- 本番ArtifactとGit commit SHAが対応付けられる。
- Storage物理孤児とGit履歴流出パスについて、実体の棚卸し・削除・キー失効が完了する。
- NodeテストとDBテストを実行し、実行不能を合格扱いしない。
