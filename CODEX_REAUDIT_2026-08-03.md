# plamo-paint.com 再・敵対的監査レポート

- 監査日: 2026-08-03 (JST)
- 対象HEAD: `cc023bdbd0b874d62116e7d70488ca05300ae28d`
- 対象: 現行リポジトリ全体、Git履歴、production/dev Supabase catalog、`plamo-paint.com` の読み取り実測、旧GitHub Pages導線、Cloudflare/Supabase無料枠と運用・法務表示
- 方針: 既知項目は再掲せず、現行HEADで残存する問題、修正の回避経路、新たに確認した問題のみを記載する。本番にデータを作る・変更する破壊的試験はしていない。

## High

### H-01 BANしても公開Storage画像のURLは失効せず、違法・権利侵害画像を直接取得できる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/025_ban_quarantine.sql:9-34`、`migrations/027_ban_quarantine_scope.sql:19-34`、`scripts/backup_storage.sh:30-31`
- 問題: BAN隔離は `recipes` / `comments` のSELECTポリシーだけを変更し、公開Storageオブジェクトを削除・移動・非公開化しない。
- 根拠: 025/027が変更するのは `recipes_select` と `comments_select` だけである。一方、スクリプト自身が「非公開画像もURLを知っていれば誰でも取得できる公開バケット」と明記している。SupabaseもPublic bucketはURL所持者のダウンロード時にアクセス制御を迂回すると説明している。[Supabase Storage buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals)
- 悪用手順または壊れる条件: 公開中に `cover_url` / `grid` 内の画像URLを保存した第三者、検索エンジン、SNSキャッシュは、投稿者のBAN後も旧URLへ直接アクセスできる。権利侵害・違法画像の送信防止措置を回避できる。
- 推奨する修正: BAN時に公開オブジェクトを失効させ、証拠用コピーだけを管理者限定のprivate quarantine bucketへ保存する。DBの隔離とStorage API処理をoutboxで連携し、再試行・監査可能にする。BAN後に旧URLが404/410になり、管理者だけが証拠を取得できる結合テストを追加する。

### H-02 BAN済み投稿がSECURITY DEFINERのランキングRPCから再露出する

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/025_ban_quarantine.sql:13-24`、`migrations/027_ban_quarantine_scope.sql:19-33`、`supabase/schema.sql:787-850`、`index.html:3218-3230`
- 問題: BAN用RLSを、匿名公開されたランキングRPCが迂回する。
- 根拠: 最終RLSは `is_public and not owner_is_banned(owner_id)` だが、`popular_paints` / `rising_paints` / `popular_methods` は `SECURITY DEFINER` で、条件は `r.is_public = true` だけである。本番 `pg_get_functiondef` も同じ定義だった。`popular_paints` は `sample_cover` と `sample_id` まで返し、トップ画面が描画する。
- 悪用手順または壊れる条件: 違法画像等で投稿者をBANして一覧・検索・共有URLを隠しても、トップのランキングから画像URL、レシピID、塗料・方法の集計が匿名へ再露出する。
- 推奨する修正: 3 RPCすべてに `not owner_is_banned(r.owner_id)` を明示するか、`SECURITY INVOKER` 化してRLSを唯一の認可正本にする。`increment_view` にも同じ公開条件を適用する。BAN前後でランキング3種に対象のID・cover・method・paintが一切現れないDBテストを追加する。

### H-03 BAN後も既存画像を同サイズ以下で上書きできる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/022_codex_audit_fixes.sql:61-84`、`migrations/019_upload_guard.sql:61-66`、`migrations/010_storage_policies.sql:41-49`
- 問題: UPDATE用Storage guardの早期returnがBAN判定まで飛ばす。
- 根拠: `migrations/022...:69-78` は、bucket/nameが同じで `new_size <= old_size` なら `storage_upload_denied_reason()` を呼ばず `return NEW` する。BAN判定は呼ばれなかった関数側にある。Storage RLSは所有者一致だけでBANを見ない。本番trigger/functionも同じ定義だった。
- 悪用手順または壊れる条件: BAN前に固定パスへ画像を置く。BAN後、保存済みJWTで同サイズ以下の画像をupsertする。URLを変えずに公開avatar/header/recipe画像を別内容へ差し替えられ、プロフィール・レシピのBAN更新triggerも動かない。
- 推奨する修正: active session、ユーザー存在、BANの確認を早期returnより前に行う。短絡してよいのは容量差分の計算だけにする。BAN後の同サイズ、小サイズ、metadata size欠落のupsertを実Storage APIで拒否するテストを追加する。

### H-04 画像削除・退会・孤児掃除はStorage実体を削除せず、容量上限もリセットできる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/013_purge_unreferenced_images.sql:54-59,78-83`、`migrations/015_test_found_fixes.sql:83-85,94-105`、`migrations/017_codex_fixes.sql:57-62,104-109`、`legacy.html:3450-3491`
- 問題: 実ファイル削除を `delete from storage.objects` に依存している。
- 根拠: SupabaseはStorage schemaをメタデータとして扱い、SQL DELETEでは実オブジェクトが孤児化して容量対象に残るため、Storage APIを使うよう明記している。[Supabase: Delete objects](https://supabase.com/docs/guides/storage/management/delete-objects)、[Storage schema design](https://supabase.com/docs/guides/storage/schema/design)。現行の投稿削除、下書き削除、退会、自動掃除はすべて直接SQL DELETEを行う。クライアント側 `remove()` は所有者の一部UI経路だけで、失敗を握ってDB削除を続行する。
- 悪用手順または壊れる条件: 200MBをアップロードしてレシピに参照させ、`delete_recipe_with_images` を直接呼ぶ。metadataが消えて次回quota集計は0に戻るが、実体は残る。約5回でFree Storage 1GBを物理的に枯渇できる。管理者削除や退会でも画像の即時削除を保証できない。
- 推奨する修正: `storage.objects` への直接DMLを全廃する。service-roleを保持するEdge Function/信頼済みWorkerからStorage APIを呼び、削除outbox、idempotency key、retry、dead-letterを持たせる。既存孤児をAPI/S3互換一覧で棚卸しして削除する。テストはmetadata件数でなく旧公開URLの404化と実使用量減少まで検証する。

### H-05 公開Git履歴に残った81件のStorageパスの一部が現在も取得できる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: commit `a26b4c9c0b745c3a57c84ecda5a94fcd7ef2a232` の `scripts/storage_paths.txt:1-81`
- 問題: ファイルを現行HEADから削除しただけで、漏えいしたURLを失効していない。
- 根拠: 公開repositoryの当該rawファイルは現在もHTTP 200で取得できる。81パス中27件は匿名GETがHTTP 200で、うち8件は現在の匿名 `recipes` / `profiles` APIが参照していなかった。具体的パスは本レポートに記載しない。8件が下書き・削除済み・単なる旧版のどれかはservice-roleで要確認だが、「現行公開画面から到達しない生存画像」であることは確認済み。
- 悪用手順または壊れる条件: Git履歴から一覧を取得し、公開Storage URLへ当てるだけで、画面上の匿名列挙遮断を回避して画像を取得できる。
- 推奨する修正: 81パスをすべて漏えい済みとして扱う。生存オブジェクトを新しいランダムパスへ再配置し、旧URLを削除・失効させる。非公開/下書きはprivate bucket＋短時間署名URLへ移す。Git履歴rewriteはURL失効後の二次対応とする。

### H-06 Storage quotaは並行uploadと複数アカウントで越境できる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/019_upload_guard.sql:42-95,120-163`、`migrations/022_codex_audit_fixes.sql:86-100`
- 問題: 使用量の `SUM/COUNT` と許可が非原子的で、プロジェクト全体の上限もない。trigger作成失敗もmigrationを成功扱いにする。
- 根拠: owner単位のlock・予約・quota ledgerなしに使用量を読み、その後INSERTを許可する。異なるpathへの並行transactionは互いの未commit行を見ない。上限は1ユーザー200MB/500件だけで、Free project全体1GBの安全弁がない。FreeのStorage枠は1GBである。[Supabase pricing](https://supabase.com/pricing)
- 悪用手順または壊れる条件: 空アカウントから10MBを多数並行送信すると各判定が同じ旧使用量を見て通る。並行性を使わなくても5アカウント×200MBで全体1GBに達する。trigger張り直しが失敗した環境ではNOTICEだけでmigrationが完了し、022にはUPDATE用fallback policyもない。
- 推奨する修正: user UUID単位のadvisory lockとatomicなquota reservation ledgerを導入し、project-global hard thresholdも設ける。migrationはcatalog上のtrigger/policyをassertし、作成不能なら失敗させる。21件/100件の並行uploadと5アカウント全体上限を結合テストする。

### H-07 退会直後の保存JWTでStorageへ再アップロードできる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/015_test_found_fixes.sql:94-108`、`migrations/010_storage_policies.sql:28-49`、`migrations/019_upload_guard.sql:56-66`
- 問題: 退会処理がAuth userを削除しても、Storage認可はJWTの `sub` とfolder/ownerしか確認しない。
- 根拠: SupabaseはAuth userを削除してもaccess JWTが期限まで有効と明記している。[Supabase user management](https://supabase.com/docs/guides/auth/managing-user-data)。Storage ownershipはJWTの `sub` から決まる。[Supabase Storage ownership](https://supabase.com/docs/guides/storage/security/ownership)。現行policyはowner/folder一致だけで、quota/BAN関数はprofile不在を非BANとして扱う。
- 悪用手順または壊れる条件: 退会前にaccess tokenを保存し、退会後、期限内に削除済UUID配下へpublic imageをuploadする。主体profileが存在しない孤児画像になり、再登録・退会を繰り返す容量攻撃にも使える。
- 推奨する修正: upload guardで `auth.users` / `profiles` のactive rowとJWT `session_id` に対応する `auth.sessions` の存在を確認する。退会前に全sessionを失効し、Storage API削除完了後にAuth userを削除する。保存JWTを使った退会後upload拒否テストを追加する。

### H-08 匿名events guardだけでは500MB DB枠を守れず、超過後もthrottle行を増やせる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/001_events_protection.sql:27`、`migrations/019_upload_guard.sql:196-238`
- 問題: global上限が1時間10,000 eventと大きく、保持は90日である。さらにsession counterをglobal判定より先にcommit対象へ追加する。
- 根拠: `check_event_rate()` は一意な `session_id` ごとの行を `event_throttle` にINSERTした後、global counterを増やして10,000超なら `return null` する。そのためeventを捨ててもsession bucket行は残る。許可分だけでも約2KB×10,000件/時≒20MB/時で、Free DB 500MBは行/index overheadを無視して約25時間で到達し得る。500MB到達時はread-onlyになる。[Supabase database size](https://supabase.com/docs/guides/platform/database-size)
- 悪用手順または壊れる条件: 匿名で毎回異なる64文字session IDと上限近いpropertiesをData APIへ送る。Workerを通らず、global許可分でDBを増やし、10,000件/時を超えた後も高cardinalityのthrottle rowを増やせる。
- 推奨する修正: global counterを最初にatomic更新し、超過時はsession rowを作らない。空/任意session IDを信用せず、edgeでサーバ生成・サンプリングする。eventの時単位hard byte budgetと短い保持を設ける。10,000超のunique SID送信後もthrottle件数が定数であるテストを追加する。

### H-09 256KB以内のgridでWorker CPU超過、ブラウザ固まり、派生表膨張を起こせる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/005_review_fixes2.sql:70-76`、`migrations/020_paint_stable_id.sql:150-199`、`worker/src/worker.js:229-274`、`legacy.html:1963-2024,2080-2221`、`tests/run_worker_tests.mjs:270-277`
- 問題: grid制約はバイト数だけで、工程数・行数・セル数・派生行数・計算量を制限しない。
- 根拠: Workerは `procs.filter(... rows.some(...))` で工程数×行数を走査し、その後も全行×使用工程を処理する。ローカル実測では6,000 procs＋6,000空rowsのJSONは172,910 bytesで制約内だが約250ms、Cloudflare Free CPU 10msを大幅に超えた。Cloudflareは超過時にError 1102を返す。[Workers limits](https://developers.cloudflare.com/workers/platform/limits/)。別形状では5,000 tiny cellsから5,000 `recipe_paints` 行を生成できる。
- 悪用手順または壊れる条件: 認証者がRESTから多数の工程・行・セルを持つ公開レシピを保存する。そのURLはWorker CPU超過で閲覧不能になり、JS側は大量DOM生成で端末を固める。1日30投稿でも派生表を15万行/日/account増やせる。
- 推奨する修正: DBでprocs、rows、総cells、photos、methods、各文字列、最大派生行数を個別に制限する。Workerは一度の走査で使用工程Setを作り、入力・出力・CPU予算で打ち切る。悪意ある対角/直積gridをDB、Worker、ブラウザの性能テストへ追加する。

### H-10 本番のセキュリティ修正をrepositoryから再現できない

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/023_moderation_and_notify_fixes.sql:1-24`、`migrations/026_notify_and_input_limits.sql:1-13`、欠落した `024` / `028`、`migrations/025_ban_quarantine.sql:3`、`supabase/schema.sql:432-439,510-527`、`README.md:52-54,181-221,235-239`
- 問題: production catalogへ直接適用した修正がmigrationの実SQLとして存在しない。
- 根拠: 023と026はコメントだけで実行SQLが0行。024/028はファイル自体がなく、025は「024の後」と指定する。`schema.sql` には旧 `notify_self` 等が残る。READMEはschemaを正本、最新migrationを019と記載する。本番ledgerにはrepoにない023/024/026/028相当があり、prod/devも別系統だった。
- 悪用手順または壊れる条件: 災害復旧、dev再構築、別project移行でREADMEどおり適用すると、通知種別/長さ、BAN再登録、コメント通知source、最終comments RLS等が修正前へ戻る。復旧作業そのものが脆弱性を再導入する。
- 推奨する修正: 本番の `pg_get_functiondef`、constraints、triggers、policies、grantsを取得し、完全な実行可能migrationへ取り込む。Supabase CLI等の単一ledgerとchecksumを正本にし、欠番・コメントだけのsecurity migrationをCIで拒否する。clean bootstrap後のcatalog diffを必須化する。

### H-11 「DB 605本合格」はrepositoryの現行SQLを検証していない

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `tests/run_db_tests.mjs:23-54`、`.github/workflows/deploy.yml:60-74`、`tests/README.md:73-109`、`tests/db/05_ban.sql:86-110`
- 問題: DB runnerは接続・実行せず、過去の合格文を表示して常にexit 0にする。dev内のstored testとrepoテストも一致しない。
- 根拠: runner自身が `process.exit(0)` と明記し、deploy workflowはDBテストを呼ばない。repoのBANテストは「BAN中もrecipe/draft/comment/profile編集を許可」を期待するが、現行prod/dev関数は更新を拒否する。それでもdev `test_report()` は605/605だったため、devで走ったのはrepoの現行テストではない。README、runner、実行結果の本数も604/605で不一致である。
- 悪用手順または壊れる条件: RLS/RPC/triggerを壊した変更、空のmigration、catalog driftがあってもCIとdeployは緑になる。今回の空023/026も検出されなかった。
- 推奨する修正: CIでephemeral Supabase/Postgresを起動し、baseline→全migration→repo内テストを自動適用する。SQL error、テスト数減少、catalog diff、1件の不合格のどれでもdeployを停止する。案内だけのrunnerをテストコマンドから外す。

### H-12 通報対象者が確認前に退会するとモデレーション集計から消える

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/018_report_target.sql:70-89`、`migrations/015_test_found_fixes.sql:94-106`
- 問題: `report_summary` が退会でcascade削除される `profiles` へINNER JOINする。
- 根拠: 集計は `join public.profiles p on p.id = rp.target_user_id` である。退会後もreportのtarget UUIDは残るが、profile行がないため管理キューから落ちる。BAN前なら `banned_emails` にも記録がない。
- 悪用手順または壊れる条件: 違反投稿を通報された本人が管理者確認前に退会する。通報自体は残っても集計・BAN導線から消え、同じメールで再登録して戻れる。
- 推奨する修正: moderation subject/tombstoneをprofile lifecycleから分離し、LEFT JOINで退会済み対象もキューに出す。退会時に必要最小限のabuse prevention recordを法的根拠・保持期限付きで保存する。report→withdraw→summary表示→再登録防止のテストを追加する。

### H-13 レシピ通報は違反本文・画像の証拠を保存しない

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `migrations/018_report_target.sql:22-49`
- 問題: コメント通報は本文をsnapshotするが、レシピ通報はowner/title/cover URLだけで `target_body := null` にする。
- 根拠: 通報時の `memo`、`grid`、画像hash/object key、公開状態がimmutable evidenceとして残らない。title/cover URLだけでは何が違反だったかを再現できない。
- 悪用手順または壊れる条件: 通報後、投稿者が本文/写真を編集、非公開化、削除、退会する。管理者は通報時点の違反内容を確認できず、適切なBAN、権利侵害対応、異議申立て検証ができない。
- 推奨する修正: boundedな本文snapshot、画像object key＋hash、通報時刻を管理者限定table/private bucketへ保存する。原画像保持は必要最小限・期限付きとし、監査logを付ける。edit/delete/private/withdraw後も同じ証拠を確認できるテストを追加する。

### H-14 Storageバックアップが不完全でも「完全版」と判定される

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `scripts/backup_storage.sh:72-116,131-168`、`scripts/check_backups.mjs:32-45,55-81,109-113`
- 問題: 手動path一覧の鮮度、remote全件との差分、取得ファイルの完全性を検証しない。
- 根拠: `storage_paths.local.txt` が存在するだけで更新日時・現行object一覧と比較せず「完全版」にする。現ファイルは34件で、更新は2026-07-27。既存local fileはsize/hash確認なしでskipし、manifestもsizeだけでhashがない。公開API経路はページングがない。checkerは日付ディレクトリだけを見て常にexit 0にする。
- 悪用手順または壊れる条件: 一覧作成後に増えた非公開/下書き画像は対象外のままになる。中断で部分ファイルが残ると次回skipされ、そのサイズで正常manifestが作られる。公開recipe/profileがAPI上限を超えても無言で欠落する。
- 推奨する修正: service-roleまたはS3互換APIで毎回全objectをページング列挙する。`.part`へ取得後にatomic renameし、SHA-256、件数、総容量、complete markerを検証する。不完全時にcheckerをnon-zeroにし、定期restore drillを行う。

### H-15 DBバックアップcheckerは復元不能な部分exportでも正常表示する

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `scripts/check_backups.mjs:55-69,99-113`、`README.md:241-250`
- 問題: 日付入りファイルの存在しか見ず、pg_dumpの存在・hash・artifact・restore成功を確認しない。
- 根拠: 実地確認したローカル控えは `paints` / `profiles` / `recipe_paints` / `recipes` の4 JSONだけで、auth、drafts、comments、reports、notifications等を含まない。checkerは別repoの自動backupを「ここから確認できない」と表示しつつexit 0である。
- 悪用手順または壊れる条件: 別repo側のbackupが停止・破損していてもローカル検査は緑になる。この部分exportを復旧元と信じると、アカウント、下書き、通報証拠、通知等を復元できない。
- 推奨する修正: backup repositoryの最新run、artifact、pg_dump checksumをAPIで確認する。暗号化されたdumpを定期的に空DBへrestoreし、主要table件数、Auth参照、Storage manifest、RLS/catalog hashまで照合する。ローカルJSONは「部分export」と明記する。

### H-16 Worker無料枠10万回/日を使い切るとトップ・ログイン・法定表示まで停止する

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `worker/wrangler.toml:43-56`
- 問題: 動的routeだけでなく `/`、全主要HTML、`/healthz` を `run_worker_first` に含めている。
- 根拠: Workers Freeは100,000 requests/day、10ms CPUである。[Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/)。`run_worker_first` 対象は枠超過後にstatic assetへfallbackせず429になる。[Static assets billing and limitations](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)。100,000/dayは平均約1.16 request/secである。
- 悪用手順または壊れる条件: botが `/`、`/healthz`、well-formed random UUIDの `/r/*` を10万回要求するか、告知が想定以上に拡散する。残りの当日はトップ、ログイン、規約、プライバシーを含む主要経路が利用不能になる。Cloudflare外部rate-limit/WAF設定の有無は要確認。
- 推奨する修正: HTTP→HTTPS/www正規化をCloudflare Redirect Rulesへ移し、静的HTMLをasset-firstにする。Worker-firstはSSR/sitemap等に絞り、health endpointは監視元制限または別routeにする。rate limit、Bot対策、quota alertを設定する。少なくとも告知時はWorkers Paid（最低$5/月）を検討する。

### H-17 本番CAPTCHAが無効で、Auth・認証メール枠をbotから消費できる

- 重大度: High
- 告知前に直すべきか: yes
- 該当箇所: `src/config.js:22-36`、`index.html:1763-1818,2153-2260`
- 問題: 本番 `TURNSTILE_SITE_KEY` が `null` で、登録、ログイン、再送、resetがcaptcha tokenなしでAuthへ到達する。
- 根拠: `getCaptchaToken()` は本番keyなしなら `undefined` を返す。本番への無効credential読み取り試験はcaptcha errorでなくAuthのcredential判定まで到達し、クライアント側CAPTCHA無効を確認した。Supabaseはsignup/sign-in/resetへのCAPTCHAをabuse対策として提供している。[Supabase CAPTCHA](https://supabase.com/docs/guides/auth/auth-captcha)。Auth email rateはproject-wideである。[Supabase rate limits](https://supabase.com/docs/guides/auth/rate-limits)
- 悪用手順または壊れる条件: 分散botがsignup/resend/resetを送信してBrevo/Auth枠を消費し、正規利用者の確認・再設定メールを止める。credential stuffingにも追加のbot判定がない。
- 推奨する修正: コメントに記載済みの順序でTurnstileのprod site keyとSupabase secretを有効化する。prod keyがnullならCIを失敗させる。tokenなし/不正tokenの登録・ログイン・再送・resetが拒否され、正規tokenが通る本番相当smoke testとquota alertを追加する。

## Medium

### M-01 clean bootstrap手順では認証者にprofiles内部列が再露出する

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `README.md:191-207`、`migrations/007_audit_fixes.sql:170-180`、`migrations/022_codex_audit_fixes.sql:20-23`、`tests/db/04_profiles-admin.sql:196-200`
- 問題: READMEの `grant all on all tables ... to authenticated` がtable-level SELECTを付けるが、後続migrationはauthenticatedのtable-level SELECTを剥がさない。
- 根拠: Postgresではtable-level SELECTがcolumn REVOKEより優先する。prodは偶然table SELECTなしで安全だったが、手順どおり構築したdevは認証者に他人の `has_password`、`banned_at/reason`、`is_admin`、通知設定、同意時刻等を読ませる状態だった。テストは他人の公開列だけを確認し、内部列拒否を検証しない。
- 悪用手順または壊れる条件: 災害復旧・新dev構築後、ログイン利用者がRESTで他人の `profiles` 内部列を列挙する。
- 推奨する修正: anon/authenticatedの両方からtable SELECTをrevokeし、公開列だけをcolumn grantする。本人の内部列は `my_profile()` のみで返す。clean bootstrapで「認証者が他人の全内部列を拒否される」テストを追加する。

### M-02 コメント・下書き・非公開投稿・通知の上限が並行実行で越境する

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `supabase/schema.sql:609-621,893-925`、`migrations/017_codex_fixes.sql:213-231`
- 問題: `count/max→check` にowner単位lockやatomic ledgerがない。
- 根拠: report/inquiry/recipeだけはadvisory lock済みだが、comment 30秒、draft 5件、private recipe 10件、notification 100件/時は競合可能な読み取り後判定である。
- 悪用手順または壊れる条件: 同じuserから並行INSERT/UPDATEを送ると、各transactionが同じ旧countを見て全件を許可し、上限を超える。UIのsingle-flightをREST直叩きで回避できる。
- 推奨する修正: user単位advisory lockまたはatomic counter/reservationを使う。上限直前から20並行requestを送るDB integration testを各機能へ追加する。

### M-03 BAN解除後もemail denylistが残り、再登録すると再BANされる

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `migrations/016_moderation_and_limits.sql:124-160`、`migrations/023_moderation_and_notify_fixes.sql:1-24`
- 問題: unban transactionが `banned_emails` を解除しない。
- 根拠: 本番 `set_user_ban` はban=true時だけemailを記録し、false時のdelete/deactivate処理がない。023はコメントだけで再現用SQLもない。
- 悪用手順または壊れる条件: 管理者が誤BANを解除する。本人が後日退会し、同じメールで登録すると、古いdenylistを `handle_new_user` が読み自動BANする。
- 推奨する修正: unban時にactive denylistを同一transactionで無効化する。監査履歴は別tableへ最小情報・期限付きで残す。ban→unban→退会→同一email再登録が非BANになるテストを追加する。

### M-04 026の入力制限は部分的で、公開text/URL/配列にDB上限がない

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `migrations/026_notify_and_input_limits.sql:1-13`、`supabase/schema.sql:50-62,206-215,856-863`
- 問題: 本番catalogに一部長さ制約はあるが、repoに実SQLがなく、複数の公開入力が未制約である。
- 根拠: `profiles.display_name/bio/link/x_account/avatar_url/header_url`、draft title/cover、recipe cover、methods各要素/件数、notification link、status/category enum等に一貫したDB制約がない。REST直叩きは画面のmaxlengthを通らない。
- 悪用手順または壊れる条件: 認証者が巨大文字列・大量method・任意URLを保存し、DB 500MB、公開API応答、ranking/grouping、ブラウザ描画を圧迫する。
- 推奨する修正: `octet_length`、array cardinality/全要素長、enum CHECK、URL origin/pathをDBで制約する。limit+1、マルチバイトbyte超過、大量配列を拒否するテストを追加する。

### M-05 BAN状態を任意UUIDで匿名・認証者が照会できる

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `migrations/025_ban_quarantine.sql:13-18`、`migrations/014_user_ban.sql:20-25`、`migrations/022_codex_audit_fixes.sql:27-46`
- 問題: 022で内部列を閉じた後、同じ情報を返すhelperを再び公開RPCにした。
- 根拠: 本番で匿名 `POST /rest/v1/rpc/owner_is_banned` にpublic owner UUIDを渡すとHTTP 200/booleanを返した。authenticatedは旧 `is_banned(arbitrary_uuid)` も実行できる。022のコメントは `admin_user_states` を唯一の入口としているため設計とも矛盾する。
- 悪用手順または壊れる条件: profile/recipeからUUIDを集め、誰が運営処分を受けたかを一覧化・晒しに利用できる。
- 推奨する修正: arbitrary-ID helperをData API非公開schemaへ移し、RLS内部だけから呼ぶ。公開側はself-onlyの引数なし関数にする。anon/authenticatedによる他人UUID照会拒否テストを追加する。

### M-06 cover/avatar/headerの外部画像URLで閲覧者を追跡できる

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `index.html:966-980,1013-1018,1671-1699,2516-2540,3032-3054,3128-3154,3167-3178`、`legacy.html:3762-3769,4433-4449,4522-4528,4592-4598`、`supabase/schema.sql:50-62,206-210`
- 問題: レシピ本文の `safePhoto()` はorigin限定済みだが、カード・プロフィール・コメント等は任意HTTP(S)画像を許可する。
- 根拠: `safeUrl()` はschemeと構文文字だけを検証し、任意hostを通す。DBにもorigin制約がない。複数sinkが値を `<img src>` / CSS backgroundへ設定する。
- 悪用手順または壊れる条件: 投稿者がRESTから一意token付き攻撃者HTTPS URLをcover/avatar/headerへ保存する。トップ、検索、プロフィール、コメントを見た利用者のIP、User-Agent、時刻、site originが攻撃者へ送られる。privacyの委託先一覧にもない第三者通信になる。
- 推奨する修正: 共通 `safeMediaUrl()` を作り、Supabase/self origin、bucket、owner folderまで検証して全画像sinkへ適用する。DBには検証済object pathを保存する。`referrerpolicy="no-referrer"` と限定的な `img-src` CSPも追加する。

### M-07 レシピ取得fetchのrejectが未処理で、全上流fetchにtimeoutがない

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `worker/src/worker.js:64-90,344-373,424-440,580-613,676-706`
- 問題: Supabase DNS/TLS reject時に設計済み503ではなくWorker未処理例外になる。応答停止も期限なく待つ。
- 根拠: `getRecipeFromSupabase()` の `await fetch` はtry/catch外で、`serveRecipePage()` はその呼び出しをorigin用tryより前に実行する。他のfetchはcatchがあってもAbortSignalを持たない。
- 悪用手順または壊れる条件: Supabaseの接続拒否/DNS障害で `/r/:id` が一貫した503/Retry-Afterを返さない。upstreamが接続を保持すると、platform期限まで処理を占有する。
- 推奨する修正: 共通 `fetchWithTimeout()` と `AbortSignal.timeout()` を使う。レシピfetch rejectも`"error"`に変換し、503＋Retry-After＋共通security headersを返す。reject、永久pending、invalid JSONをroute testする。

### M-08 画像upload→DB保存、Storage削除→DB削除が非原子的

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `legacy.html:3412-3491,3503-3515,3875-3927,3974-4003,4064-4083`
- 問題: 複数画像を先にuploadしてからrecipe/draftを保存し、削除時はStorageを先に消してからRPCを呼ぶ。
- 根拠: `Promise.all(jobs)` 完了後にDB queryを行う。カバー生成失敗はfalseへ変換する。削除のStorage APIエラーは警告だけで本文削除を続ける。transaction/outbox/idempotency keyはない。
- 悪用手順または壊れる条件: 一部upload成功後に次のupload/DB保存が失敗すると未参照画像が残る。Storage削除成功後にRPC失敗・通信断が起きるとrecipe行だけ残って画像切れになる。応答喪失後の再送で重複も起きる。
- 推奨する修正: staged uploadとcommit RPC、削除outbox、idempotency keyを信頼済みserver側で管理する。DBに削除意図を確定する前に実体を消さない。各段階の失敗・timeout・応答喪失をfault-injection testする。

### M-09 並行編集が無警告のlast-write-winsで、先の変更を失う

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `legacy.html:3908-3912,3987-3993`、`supabase/schema.sql:60-61,856-863`
- 問題: update条件がIDだけで、取得時version/`updated_at` を比較しない。
- 根拠: recipeは `.update(payload).eq("id", currentRecipeId)`、draftもIDだけである。`updated_at` は表示/更新に使っても競合判定に使わない。
- 悪用手順または壊れる条件: 2タブ・2端末で同じrecipe/draftを編集し、後から保存した方が先の変更を無警告で消す。画像cleanupと重なると先の保存が参照した画像も孤児/削除候補になる。
- 推奨する修正: version列または取得時 `updated_at` をcompare-and-swapするRPCを使い、0件更新なら競合解決画面を出す。2session同時保存テストを追加する。

### M-10 データexportが取得エラーを空データとして「成功」表示する

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `index.html:1137-1161,1165-1184,2600-2618`
- 問題: Supabaseのresolved `{error}` をrejectせず、profile null/recipes空としてJSONをdownloadする。
- 根拠: `exportMyData()` は `r[0].error` / `r[1].error` 時も空値を作り、`toast("控えを保存しました")` を表示する。settings/profileもRPC errorを空profileとして描画する。
- 悪用手順または壊れる条件: RLS drift、RPC未適用、一時通信障害時に不完全exportを完全な控えと誤認し、その後退会して復元不能になる。設定では実値が「未設定」に見える。
- 推奨する修正: 各responseの `.error` をthrowし、profile/recipes件数・必須fieldの完全性を検証した場合だけdownloadする。明示的な失敗画面と再試行を出す。

### M-11 legacy.htmlが同じstorage keyでGoTrueClientを3個生成する

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `legacy.html:3370-3374,4103-4107,4409-4414`
- 問題: 3 clientが同じlocalStorage sessionを永続化・自動refreshし、auth listenerも重複する。
- 根拠: 本番recipeページのconsoleでSupabase自身の `Multiple GoTrueClient instances detected ... may produce undefined behavior` 警告を2回確認した。具体的なlogout不整合の再現頻度は要確認だが、競合構造とruntime警告は確定である。
- 悪用手順または壊れる条件: token refresh、logout、password recovery、tab復帰が重なると、複数clientが同じsessionを更新・通知してraceする。セッション切れ対応が非決定的になる。
- 推奨する修正: `window.paintlogSb` を1度だけ作り全機能で共有する。auth subscriberも1個へ集約し、refresh/logout/recovery時のnetwork requestとeventが1回だけである統合テストを追加する。

### M-12 旧GitHub Pages導線がHTTPSからHTTPへdowngrade redirectする

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: 外部設定 `https://shayan795.github.io/paint-log/`、Cloudflare HSTS設定
- 問題: 旧公開URLの301 Locationが `http://plamo-paint.com/` である。
- 根拠: 2026-08-03実測でGitHub PagesはHTTP/2 301と `Location: http://plamo-paint.com/` を返した。`hstspreload.org` status APIでは `plamo-paint.com` は `unknown`、現HSTSも180日でpreload directiveなしだった。[HSTS preload status API](https://hstspreload.org/api/v2/status?domain=plamo-paint.com)
- 悪用手順または壊れる条件: plamo-paint.comを未訪問の端末が旧URLを開くと一度平文HTTPへ遷移する。公衆Wi-Fi等のMITMがCloudflareのHTTPS redirectより先に偽ページを返し、ログイン情報を騙し取れる。
- 推奨する修正: GitHub Pagesのcustom domain/Enforce HTTPS設定を直し、旧URLから直接 `https://plamo-paint.com/` へ移す。Cloudflare側はmax-age 1年以上＋preload要件を満たして申請するか、少なくとも旧HTTP redirectを直す。

### M-13 deploy tokenを持つstepで未固定のWrangler 4.xをinstallする

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `.github/workflows/deploy.yml:38-40,76-85`、`.github/workflows/check-deps.yml:26-29`、`worker/package.json:12-14`
- 問題: 可変Action tagと最新 `wrangler@4` を、Cloudflare credentialを設定したstepで実行する。
- 根拠: workflowは `actions/*@v4` と `npm install --no-save wrangler@4` を使い、lockfileの4.104.0を無視する。将来の4.x dependency graphがそのままsecretを読める。GitHubは第三者Actionのfull commit SHA pinを推奨している。[GitHub Actions hardening](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-third-party-actions)
- 悪用手順または壊れる条件: Action tagまたは新しいWrangler/npm dependencyが侵害・破損すると、Cloudflare tokenの窃取、任意Worker deploy、site改ざんが可能になる。
- 推奨する修正: Actionsをfull SHAへ固定し、job `permissions: contents: read` を明示する。secretなしstepで `npm ci`、secret付きstepでは `npx --no-install wrangler deploy` だけを実行する。Cloudflare tokenも対象zone/Workerへの最小権限にする。

### M-14 必須HTMLが欠落してもbuildとpost-deploy smoke testが成功する

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `scripts/build_public.mjs:48-68,99-125`、`.github/workflows/deploy.yml:89-104`
- 問題: `ROOT_FILES` の欠落はwarningだけで、参照scanと本番checkもlegal/helpページを覆わない。
- 根拠: `missing.length` は表示するだけでexit 1にしない。scan regexはassets/src/vendorだけを見る。一時copyで `privacy.html` を除いてbuildがexit 0になることを再現した。post-deploy checkは `/`、config、vendor、sitemapだけである。
- 悪用手順または壊れる条件: privacy/terms/help/goodbye等を誤削除してpushしてもdeployが成功し、本番404になる。告知時に法定・問い合わせ導線を失う。
- 推奨する修正: `missing.length > 0` を即失敗にする。全配信file manifest/hashを生成し、公開後に全HTML、auth入口、代表recipe、deploy SHAを検証する。

### M-15 退会時の「即時・完全削除」とローカルbackup/Storage実体が一致しない

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `privacy.html:114-121`、`terms.html:112-113`、`scripts/backup_storage.sh:56-60,172-196`、`.gitignore:13-17`、local `backups/storage/**` / `scripts/storage_paths.local.txt`
- 問題: 表示は委託先backupだけを説明するが、運営者端末へ画像を7世代複製し、退会削除を伝播しない。加えてlocal dataはdirectory 755/file 644である。
- 根拠: privacyはaccount/profile/post/imageを即時削除、termsは完全削除と記載する。実際にはlocal完全版backupが48MB/149 files存在し、旧世代をmanual script実行時だけ削除する。Storage実体もH-04のとおりSQL削除で残り得る。local filesは同じMacの他accountから読み取り可能なmodeで、暗号化状態は要確認である。
- 悪用手順または壊れる条件: 退会後も運営者local backupとStorage orphanに画像が残る。Macの別local user、backup同期先、端末紛失時にprivate/draft画像へ到達し得る。
- 推奨する修正: 表示を実態へ合わせ、operator backupの目的、場所、最大保持、access control、退会時処理を明記する。backupを暗号化・owner-only modeにし、退会ID/pathの削除台帳を全世代へ反映するか、user単位暗号鍵破棄で消去する。

### M-16 BAN時の保持方針がprivacy表示と正反対

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `privacy.html:114-120`、`migrations/025_ban_quarantine.sql:9-11`
- 問題: privacyは運営者による停止・削除時にデータを削除すると説明するが、migrationは証拠保全のため「消さずに隠す」とする。
- 根拠: 025は誤BAN復旧・通報証拠のため本人と管理者から見える状態で保持すると明記する。privacy 7項は停止と削除を一括し「保持されているデータは削除」と記載する。
- 悪用手順または壊れる条件: 停止利用者への説明と実際の処理が一致せず、削除請求、異議申立て、権利侵害紛争時に保持根拠・期限・閲覧者を説明できない。
- 推奨する修正: 一時停止/隔離とaccount削除を分け、隔離対象、access可能者、証拠保全目的、保持期限、解除/恒久削除条件を明記する。実装にも期限/hold理由を持たせる。

### M-17 通報・問い合わせの「最長2年」をSQLが保証しない

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `privacy.html:120`、`migrations/017_codex_fixes.sql:265-275`、`migrations/019_upload_guard.sql:230-239`
- 問題: 2年超でも `status = 'open'` の行を永久に残す。
- 根拠: purge条件は `created_at < now()-interval '2 years' and status <> 'open'` である。対応漏れ、管理者不在、status更新失敗に最大保持期間がない。`banned_emails` にもexpiryがない。
- 悪用手順または壊れる条件: openのreport/inquiry本文・利用者ID・違反内容がポリシー記載の2年を超えて残る。
- 推奨する修正: 2年で本文/identifierを匿名化するか、legal hold例外をprivacyに明記し、hold理由・期限・再審査日を列で管理する。期限超過テストを追加する。

### M-18 新規通報はsite内通知だけで、オーナー不在時のalert経路がない

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `supabase/schema.sql:460-475`、`index.html:1615-1618,2727-2728`
- 問題: 通報triggerはnotifications tableへINSERTするだけで、email/webhook/push/escalationがrepoにない。
- 根拠: frontendはログイン中に約45秒ごとに通知をpollする。オーナーがsiteを開いていなければ何も届かない。repository外のalert設定の存在は要確認。
- 悪用手順または壊れる条件: オーナー不在中に違法・権利侵害投稿と通報が入ると、次回ログインまで公開が継続する。H-01によりBAN後も画像URL対応が別途必要になる。
- 推奨する修正: 新規reportをBrevo等で即時email通知し、未確認時間で再通知する。法的申出用mail、対応台帳、休日を含む目標対応時間、代理/緊急停止手順を決める。

### M-19 BAN完了UIが隔離仕様と矛盾し、証拠を誤削除させる

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `index.html:2850-2864`、`migrations/025_ban_quarantine.sql:9-11`
- 問題: 管理画面は「既存投稿は残るので必要なら個別削除」と案内するが、実装目的は公開隔離＋証拠保全である。
- 根拠: UIとmigration commentが同じ操作について異なるmental modelを提示する。
- 悪用手順または壊れる条件: オーナーが案内どおり個別削除し、誤BAN復旧データや通報証拠を不可逆に失う。逆に削除しなければH-01のpublic URLは残る。
- 推奨する修正: 「公開から隔離済み、証拠としてprivate保全、旧公開URL失効済み」と状態を明示する。恒久削除は別操作・二段階確認にし、evidence retentionと連動する。

### M-20 利用不能等への全面免責は日本法上無効になる可能性がある（要法務確認）

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `terms.html:98-106`
- 問題: BAN措置、利用者間トラブル、サービス利用/不能による損害を広く「責任を負わない」とする。
- 根拠: 消費者契約法8条は、事業者の債務不履行・不法行為による損害賠償責任の全部免除条項を無効とする。無料の個人運営siteが各場面で消費者契約に該当するかは要確認であり、本指摘は適用断定ではない。[消費者庁・消費者契約法注釈](https://www.caa.go.jp/policies/policy/consumer_system/consumer_contract_act/annotations/assets/consumer_system_cms203_230915_12.pdf)
- 悪用手順または壊れる条件: 実際の情報漏えい、過失によるデータ消失、違法投稿放置等で条項を根拠に対応を拒むと、条項自体が無効となり説明・紛争対応が悪化する。
- 推奨する修正: 「法令上免責できない場合、故意・重過失の場合を除く」を入れ、通常過失の合理的上限を別途定める。日本法の専門家へ確認する。

### M-21 Supabaseのresolved errorをコメント/like/管理者表示が空データとして扱う

- 重大度: Medium
- 告知前に直すべきか: yes
- 該当箇所: `legacy.html:4433-4449,4736-4745`
- 問題: 取得失敗と「0件」を区別せず、Promise reject handlerもない経路がある。
- 根拠: comment/likeの `res.error` を空配列/0へ変換する。`getSession()` / `is_admin` reject時はrenderが呼ばれずloadingが残る。
- 悪用手順または壊れる条件: 一時通信断やRLS不整合で既存commentが「最初のコメント」に見え、管理操作が途中で固まる。利用者が再投稿・誤操作する。
- 推奨する修正: resolved errorとrejectを明示的なerror＋retryにする。管理者判定だけ失敗した場合は非管理者として読み取り表示を継続する。通信断fault testを追加する。

## Low

### L-01 壊れたURL hashでindex.htmlの起動処理が停止する

- 重大度: Low
- 告知前に直すべきか: no
- 該当箇所: `index.html:3298-3313`
- 問題: `decodeURIComponent` をtry/catchせずにroute初期化で呼ぶ。
- 根拠: `#q/%`、不正UTF-8、`#u/%` は `URIError` を投げる。
- 悪用手順または壊れる条件: 不正hash付きlinkを共有すると、その訪問者だけ検索/profile route初期化が停止する。
- 推奨する修正: safe decoderで例外時は通常topへ戻す。`%` と `%E0%A4%A` をtestする。

### L-02 動的routeはPOST等を受理し、`/r/<uuid>/suffix` も同じrecipeとして処理する

- 重大度: Low
- 告知前に直すべきか: no
- 該当箇所: `worker/src/worker.js:671-750`
- 問題: method guardがdynamic routeより後で、recipe pathが完全一致でない。
- 根拠: `POST /robots.txt` / `POST /sitemap.xml` がread処理を実行し、pathは `slice(3).split('/')[0]` だけを見る。データ改変経路は確認していない。
- 悪用手順または壊れる条件: method/suffix違いのURLを大量生成し、同じ上流処理とWorker quotaを消費できる。
- 推奨する修正: GET/HEAD guardをrouteの前へ移し、`^/r/<UUID>$` 完全一致にする。

### L-03 sitemapは5,000件で打ち切り、編集日時を反映しない

- 重大度: Low
- 告知前に直すべきか: no
- 該当箇所: `worker/src/worker.js:579-628`
- 問題: `limit=5000` 固定でpagingなし、`lastmod` は `created_at` である。
- 根拠: 5,001件目以降を取得する処理と `updated_at` selectがない。
- 悪用手順または壊れる条件: 公開投稿が5,000件を超えると古い投稿がsitemapから消え、編集しても再crawl手掛かりが更新されない。
- 推奨する修正: sitemap index＋分割pagingにし、`updated_at` をlastmodへ使う。

### L-04 robotsと一部503だけ共通security headersが欠落する

- 重大度: Low
- 告知前に直すべきか: no
- 該当箇所: `worker/src/worker.js:438-440,720-724`
- 問題: 通常responseとHSTS/frame/referrer挙動が揃わない。
- 根拠: headersに `...SECURITY_HEADERS` がない。直接的XSS経路は確認していない。
- 悪用手順または壊れる条件: origin障害時のHTMLだけframe/HSTS等が通常と異なる。
- 推奨する修正: 全Responseを共通helperから生成する。

### L-05 Google Fontsへの第三者通信がprivacyの委託先一覧にない

- 重大度: Low
- 告知前に直すべきか: no
- 該当箇所: `privacy.html:18-19,105-112`、同様のlinkを持つ主要HTML
- 問題: 全訪問者が `fonts.googleapis.com` / `fonts.gstatic.com` へ接続するが記載がない。
- 根拠: HTMLの外部font linkと委託先一覧が一致しない。Google Fontsはrequestを処理する際にIP等を扱うと説明している。[Google Fonts privacy FAQ](https://developers.google.com/fonts/faq/privacy)
- 悪用手順または壊れる条件: page表示だけでGoogleへ通信し、利用者への第三者通信説明が不完全になる。
- 推奨する修正: fontをself-hostするか、Google Fonts利用と送信情報をprivacyへ追記する。

## 確認したが、今回問題を確認しなかった観点

- Critical: 本監査で再現・コード経路を確認できたCritical相当は0件。上記Highは告知前blockerとして扱う。
- RLS: productionのpublic全tableでRLS有効、`public` schemaのCREATE権限はanon/authenticated/PUBLICにないことをcatalogで確認した。
- 検索: production `search_recipes` は `SECURITY INVOKER` でBAN用RLSを尊重することを確認した。
- Storage基本設定: production bucketのMIMEはJPEG/PNG/WebP、1file 10MB、`BEFORE INSERT OR UPDATE` guard triggerが存在する。ただしH-03/H-04/H-06/H-07の回避経路は残る。
- XSS: WorkerのHTML escape、JSON内 `<` の `\u003c` 化、function形式の `replace` は維持され、既知の `$` 置換/XSS回避経路は確認できなかった。
- Service Worker: `sw.js:25-45` はCache APIを使わず、navigationのnetwork failure時だけ503を返すため、現構成のcache poisoning/旧asset固定は確認できなかった。
- redirect: `returnTo` のlocal allowlistからopen redirectは確認できなかった。
- 秘密情報: 現行Git全blobをservice-role JWT、Cloudflare/GitHub token、SMTP password、credential付きPostgres URLのpatternで走査し、秘密値は確認しなかった。公開anon/publishable keyは秘密ではない。
- 本番外形: `/healthz` はHTTP 200でdatabase/assetsともok、主要pageにHSTS、frame制限、nosniff、referrer policyが付くことを確認した。
- 自動テスト: localでfrontend 98、paint 23、Worker 92が合格し、`npm audit --omit=dev` は0件。ただしH-11のとおりDB/E2E/実配線を保証しない。

## Claude Codeでの修正順

1. H-01〜H-07: BAN・Storageの公開停止、実削除、quota/sessionを同じserver-side lifecycleへ統合する。
2. H-10/H-11/M-01: production catalogを完全migration化し、clean bootstrap＋DB CIを先に作る。以後のDB修正はそのCI上だけで行う。
3. H-08/H-09/H-16/H-17: 無料枠を枯らす経路を閉じ、告知時のpaid/alert/rate-limit条件を決める。
4. H-12/H-13/M-18/M-19: 退会後も機能するモデレーション主体・証拠・通知・隔離UIを整える。
5. H-14/H-15/M-15〜M-17: restore可能なbackupと、実態に一致する保持・削除表示へ直す。
6. M-02〜M-14/M-20/M-21、Low項目を回帰test付きで処理する。
