# 自動テスト

変更を加えたときに「他のところが壊れていないか」を機械的に確かめる仕組み。
合計 **690本**（データベース604本＋画面まわり31本＋Worker 55本）。

## 実行方法

### ふだんの運用
**Claude（AI）が実行します。** 変更を加えたあとに「テストして」と言うか、
実装を頼めば最後に自動で走らせます。結果は日本語で報告されます。

### 自分で実行したいとき

**① 画面まわり（31本・数秒）** — ターミナルで:

```bash
node tests/run_front_tests.mjs
```

**② Worker（55本・数秒）** — ターミナルで:

```bash
node tests/run_worker_tests.mjs
```

**③ データベース（604本・1〜2分）** — Supabase の SQL Editor に貼って Run:

```sql
select * from public.test_report();
```

→ 区分ごとに「実行／合格／不合格」と、失敗した場合はその内容が表で出ます。
`★合計` の行だけ見れば全体の合否が分かります。

> ⚠️ **必ず開発用プロジェクト（plamo-paint-dev）で実行すること。**
> 本番には `tests` スキーマを入れていないので、間違えても実行できないようにしてあります。

## 何をテストしているか

| 区分 | 本数 | 主な内容 |
|---|---:|---|
| 検索・関数の安全性 | 78 | 検索に非公開投稿が出ない／内部関数を匿名が叩けない |
| 画像・Storage | 74 | 匿名が一覧できない／掃除が現役画像を消さない／削除で画像も消える |
| データ整合 | 71 | 日時の偽装ができない／壊れたデータで落ちない／容量上限 |
| 権限:プロフィール | 67 | 自分を管理者にできない／内部列が匿名に見えない |
| 通知・保存・通報 | 63 | 他人の通知が読めない／通報は管理者だけが見られる |
| 閲覧数・ランキング | 57 | 閲覧数を盛れない／ランキングを操作できない |
| RLS:コメント | 53 | 停止中の投稿にコメントできない／返信先を偽装できない |
| 停止(BAN) | 51 | 停止中は投稿できない／本人が自力解除できない／解除で戻る |
| RLS:投稿 | 48 | 他人の非公開が読めない／他人の投稿を書き換え・削除できない |
| 上限・レート制限 | 42 | 非公開10件・下書き5件・連投制限 |
| Worker（入口） | 55 | 内部ファイル(BOMBS.md/schema.sql)の遮断・OGPのHTMLエスケープ・画像URLの許可判定 |
| 画面まわり | 31 | XSS対策・CSS注入対策・サムネイルの縦横比 |

## 仕組み（技術メモ）

- **DBテスト**は `tests` スキーマの中にある。RLS（行レベル権限）は「その人としてログインした状態」
  でしか検証できないため、`request.jwt.claims` を差し替えて `auth.uid()` を切り替える
  （`tests.as_user()` / `as_anon()` / `as_owner()`）。
- Postgresの制約で **SECURITY DEFINER 関数の中では `set role` が使えない**。そのため
  なりすまし系は通常関数、結果の記録だけを特権関数に分けている。
  許可/拒否を確かめる関数も通常関数（特権にすると権限が上がって検証にならない）。
- RLSで弾かれた UPDATE/DELETE は **エラーにならず「0件」になる**だけなので、
  `tests.affects()` で影響行数を検証している。
- **画面まわりのテスト**は HTML から安全用の関数（`esc` / `safePhoto` / `safeColor` /
  `safePos` / `safeUrl` / `thumbUrl`）を取り出して直接実行する。ブラウザ不要。
- **Workerのテスト**も同じ考え方で、`worker/src/worker.js` から「外部に触らない関数」
  （`isBlockedPath` / `esc` / `isAllowedImageOrigin` / `buildDescription` / `UUID_RE`）だけを
  正規表現で抜き出して実行する。`worker.js` は `export default` を含むためそのままは読み込めない。
  関数の書き方（行頭の `function` 宣言）を変えると抜き出せなくなるので、その時は
  `tests/run_worker_tests.mjs` の `PATTERNS` も直すこと（抜き出せない場合はエラーで止まる）。

## 空の開発用DBに入れ直す手順

**この順番どおりに実行すれば、コミットされているファイルだけで604本を再現できる。**
（以前は実行係の関数がdevのDBに直接作られていて、リポジトリから再現できなかった）

1. **土台** — `tests/db/00_harness.sql` をそのまま SQL Editor に貼って Run。
2. **テスト本体** — `tests/db/01_*.sql` 〜 `10_*.sql` を1ファイルずつ。
   各ファイルは `do $$ ... $$;` の形なので、**関数に包んでから** Run する。
   包み方（ファイル番号と同じ `tNN_` で始まる名前にすること）:

   ```sql
   create or replace function tests.t01_rls_recipes() returns void language plpgsql as $fn$
   -- ここに 01_rls-recipes.sql の「do $$」を除いた中身（declare 〜 end）を貼る
   $fn$;
   ```

   | ファイル | 関数名 |
   |---|---|
   | 01_rls-recipes.sql | `tests.t01_rls_recipes()` |
   | 02_rls-comments.sql | `tests.t02_rls_comments()` |
   | 03_rls-social.sql | `tests.t03_rls_social()` |
   | 04_profiles-admin.sql | `tests.t04_profiles_admin()` |
   | 05_ban.sql | `tests.t05_ban()` |
   | 06_view-rank.sql | `tests.t06_view_rank()` |
   | 07_storage.sql | `tests.t07_storage()` |
   | 08_integrity.sql | `tests.t08_integrity()` |
   | 09_limits.sql | `tests.t09_limits()` |
   | 10_search-func.sql | `tests.t10_search_func()` |

   > 中身に `$$` が出てくると入れ子で壊れるため、包む側は `$fn$` を使う。
3. **実行係** — `tests/db/99_runner.sql` をそのまま Run。
   `public.run_all_tests()`（1件ずつの結果）と `public.test_report()`（区分ごとの要約）が作られる。
4. 確認 — `select * from public.test_report();`

`run_all_tests()` は `tests` スキーマの `t01_…`〜`t10_…`（引数なし・戻り値void）を
**名前順に自動で探して**呼ぶので、テストを増やしても実行係を書き換える必要はない。
逆に入れ忘れがあると「★実行エラー」の行が出て不合格になる（黙って本数が減らない）。

## テスト自体が機能しているかの確認

「全部合格」と出るテストが実は何も見ていない、というのはよくある失敗。
`safePhoto` の防御をわざと外すと7本が即座に失敗することを確認済み（戻すと全合格）。

## 更新するとき

- テスト本体: `tests/db/01`〜`10_*.sql`（`do $$ ... $$;` の1ブロック）
- 土台: `tests/db/00_harness.sql` ／ 実行係: `tests/db/99_runner.sql`
- dev に反映するには上の「空の開発用DBに入れ直す手順」と同じく、各ファイルを
  `create or replace function tests.tNN_xxx() returns void language plpgsql as $fn$ 〜 $fn$;`
  の形に包んで SQL Editor で実行する。
- 判定ヘルパーの引数の数を間違えないこと（型が合わず実行時に落ちる）:
  `tests.allowed(区分, 名前, SQL)` は3つ、`tests.denied(区分, 名前, SQL, 期待エラー文字列)` は
  最大4つで**第4引数はtext**。日時などを足してはいけない。
- **不合格が出たら、テストを甘くして通してはいけない。** まず「実装が悪いのか、テストが悪いのか」
  を判断する。実装の問題なら実装を直す（これまで16件の実バグがこの方針で見つかった）。
