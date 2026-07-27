-- =====================================================================
-- tests/db/99_runner.sql — テストの実行係（run_all_tests / test_report）
--
--   ★開発用DB(dev)にだけ入れること。本番には絶対に入れない。
--
--   なぜこのファイルがあるか:
--     以前は public.run_all_tests() と public.test_report() の定義が
--     dev のDBに直接作られていて**リポジトリに存在しなかった**。
--     そのため「632本全合格」を、コミット済みのソースだけからは再現できなかった。
--     空のDBに 00_harness.sql → 01〜10 → 99_runner.sql の順で入れれば
--     同じ結果が再現できるよう、定義をここに置く。
--
--   入れる順番（tests/README.md にも同じ手順を書いてあります）:
--     1) tests/db/00_harness.sql
--     2) tests/db/01〜10_*.sql（各ファイルの do $$ ... $$; を
--        create or replace function tests.tNN_xxx() ... に包んで実行）
--     3) このファイル
--
--   関数名の取り決め:
--     テスト本体は tests.t01_… 〜 tests.t10_… という名前の
--     「引数なし・戻り値void」の関数にする。run_all_tests() は
--     pg_proc を見て ^t[0-9][0-9]_ に一致するものを名前順に呼ぶので、
--     テストを増やしても run_all_tests() を書き換える必要はない。
-- =====================================================================

-- ---------------------------------------------------------------------
-- run_all_tests(): 全テストを順に実行し、1件ごとの結果をそのまま返す
--
--   ※ security definer に**しない**こと。
--     Postgres は SECURITY DEFINER 関数の中で `set role` を禁止しており、
--     なりすまし（tests.as_user / as_anon）が全滅するため。
--     特権が必要な処理は tests.record / make_user 側が DEFINER で持っている。
-- ---------------------------------------------------------------------
create or replace function public.run_all_tests()
returns table(seq int, area text, name text, ok boolean, detail text)
language plpgsql
as $fn$
declare
  fn    text;
  found int := 0;
  missing text[] := '{}';
  prefix  text;
begin
  -- ※ search_path はあえて固定しない。
  --   固定すると gen_random_uuid() のような extensions スキーマの関数が
  --   テスト本体から見えなくなる環境がある。代わりに、この関数の中では
  --   参照するものを必ずスキーマ付き（tests. / public. / pg_catalog）で書いている。

  -- 結果表を空にする。
  -- ※Supabase は「WHERE の無い DELETE」を安全機能で拒否するため、
  --   常に真になる条件（seq は主キーなので必ず not null）を付けている。
  -- ※列名を r. で修飾するのは、この関数の戻り値（OUTパラメータ）にも seq があり、
  --   裸で書くと「seq が曖昧」と怒られて実行できないため。
  delete from tests.result as r where r.seq is not null;

  -- 連番も1に戻す（前回の実行の続き番号になると結果表が読みにくいため）。
  -- 権限が無い環境でも止まらないよう握りつぶす（番号がずれるだけで合否には影響しない）。
  begin
    perform setval(pg_get_serial_sequence('tests.result','seq'), 1, false);
  exception when others then null;
  end;

  -- テスト本体を名前順（= 01→10 の順）に呼ぶ
  for fn in
    select p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'tests'
       and p.proname ~ '^t[0-9][0-9]_'
       and p.pronargs = 0
       and p.prorettype = 'void'::regtype
     order by p.proname
  loop
    found := found + 1;
    begin
      execute format('select tests.%I()', fn);
    exception when others then
      -- 途中で落ちても残りのテストは続ける。落ちたこと自体を1件の不合格として残す。
      -- ※Postgresの仕組み上、例外で巻き戻るのは「そのテスト群が記録した結果」まで。
      --   すでに終わった群の結果は残るが、落ちた群は途中までの合格分も消える。
      --   本数が急に減っていたら、まず「★実行エラー」の行を見ること。
      perform tests.record('★実行エラー', fn || ' が途中で異常終了した', false, left(sqlerrm, 200));
    end;
    -- テスト関数が役割を切り替えたまま終わっていても、次のテストに影響させない
    begin
      perform tests.as_owner();
    exception when others then null;
    end;
  end loop;

  -- 「入れ忘れ」の検出。t01〜t10 のどれかが DB に無ければ不合格として表に出す。
  -- （これが無いと、ファイルを入れ忘れただけなのに「全部合格」に見えてしまう）
  for i in 1..10 loop
    prefix := 't' || lpad(i::text, 2, '0') || '_';
    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'tests' and p.proname like prefix || '%' and p.pronargs = 0
    ) then
      missing := missing || prefix;
    end if;
  end loop;
  if array_length(missing, 1) is not null then
    perform tests.record('★実行エラー', 'テスト本体がDBに入っていない', false,
      '見つからない: ' || array_to_string(missing, ', ') || '（tests/db/01〜10_*.sql を入れ直してください）');
  end if;
  if found = 0 then
    perform tests.record('★実行エラー', 'テストが1本も見つからない', false,
      'tests スキーマに t01_… 〜 t10_… の関数がありません');
  end if;

  return query
    select r.seq, r.area, r.name, r.ok, r.detail
      from tests.result r
     order by r.seq;
end $fn$;

-- ---------------------------------------------------------------------
-- test_report(): 人が読むための要約表
--   Supabase の SQL Editor で `select * from public.test_report();` と打つ用。
--   run_all_tests() を実際に走らせたうえで、区分ごとに集計して返す。
-- ---------------------------------------------------------------------
create or replace function public.test_report()
returns table("区分" text, "実行" int, "合格" int, "不合格" int, "内容" text)
language plpgsql
as $fn$
begin
  -- 副作用（テスト実行）だけが目的なので、返ってきた行は数えるだけで捨てる
  perform count(*) from public.run_all_tests();

  return query
  select t.c_area, t.c_total, t.c_pass, t.c_fail, t.c_note
    from (
      -- 区分ごとの内訳
      select r.area                                       as c_area,
             count(*)::int                                as c_total,
             (count(*) filter (where r.ok))::int           as c_pass,
             (count(*) filter (where not r.ok))::int       as c_fail,
             case when count(*) filter (where not r.ok) = 0 then 'OK'
                  else string_agg(r.name || ' … ' || coalesce(r.detail, ''), E'\n')
                         filter (where not r.ok)
             end                                          as c_note,
             1                                            as c_sort
        from tests.result r
       group by r.area
      union all
      -- 全体の合計（この行だけ見れば全体の合否が分かる）
      select '★合計',
             count(*)::int,
             (count(*) filter (where r.ok))::int,
             (count(*) filter (where not r.ok))::int,
             case when count(*) filter (where not r.ok) = 0
                  then 'すべて合格' else '不合格があります' end,
             2
        from tests.result r
    ) t
   order by t.c_sort, t.c_area;
end $fn$;

-- REST（tests/run_db_tests.mjs）からも呼べるようにしておく。
-- dev 専用のため anon に開けているが、本番にはこのファイル自体を入れない。
-- ※確実なのは Supabase の SQL Editor（postgres 権限）から実行する方法。
--   REST 経由は接続役(authenticator)の権限次第で下準備のINSERTが弾かれることがあるので、
--   run_db_tests.mjs が権限エラーを出したら SQL Editor で
--   `select * from public.test_report();` を実行してください。
grant execute on function public.run_all_tests() to anon, authenticated, service_role;
grant execute on function public.test_report()  to anon, authenticated, service_role;
