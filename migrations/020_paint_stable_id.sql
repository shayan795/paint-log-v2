-- =====================================================================
-- 020 塗料の指し方を「リストの位置」から「安定ID」へ移行する
--   ※ Supabase の SQL Editor で実行してください（019の後）。冪等（何度実行しても安全）。
-- ---------------------------------------------------------------------
-- 何が問題だったか:
--   レシピの1マス(セル)は、これまで「塗料リストの何番目か」で塗料を指していた。
--     例: {"i": 8}  ＝ 8番目 ＝ GSIクレオス C9 ゴールド
--   この方式だと、塗料リストの先頭に1色でも足すと全部が1つずつ後ろにズレ、
--   同じ {"i": 8} が別の塗料を指すようになる。
--   **エラーも警告も出ないまま、過去の全レシピの色が静かに化ける**（最悪の壊れ方）。
--
-- どう直すか:
--   塗料そのものに付いた変わらない番号（安定ID = paints.id = 'pt_xxxxxxxxxxxx'）で指す。
--     例: {"id": "pt_ade165e77574", "i": 8}
--   IDは塗料の内容から作った番号なので、リストの並びが変わっても不変。
--
-- このSQLがやること:
--   (1) 既存レシピ・下書きの全セルに、対応する安定IDを **足す**（既存の "i" は消さない）
--   (2) 検索用の明細を作る sync_recipe_paints を「安定ID優先」に書き換える
--   (3) 明細(recipe_paints)を新しい方式で作り直す
--
-- 安全性:
--   ・(1)は追加のみ。元の "i" を残すので、何かあれば足した "id" を消せば完全に元に戻る
--   ・(2)も "id" が無ければ従来どおり "i" を見るので、変換し忘れたデータがあっても動く
--   ・移行前に paints テーブル512件と画面側の塗料リスト512件が完全一致することを確認済み
-- =====================================================================

-- ---------------------------------------------------------------------
-- (0) 移行前の記録を残す（何件変換したかを後から検証できるように）
-- ---------------------------------------------------------------------
create table if not exists public.paint_id_migration_log (
  id          bigint generated always as identity primary key,
  ran_at      timestamptz not null default now(),
  target      text not null,          -- 'recipes' / 'drafts'
  rows_seen   int  not null,          -- 対象となった行数
  cells_with_i int not null,          -- 位置参照を持つセル数
  cells_fixed  int not null           -- 安定IDを足せたセル数
);
alter table public.paint_id_migration_log enable row level security;
-- 運用記録なので誰にも公開しない（RLS有効＋ポリシー無し＝誰も読めない。管理者はSQL Editorから見る）
revoke all on public.paint_id_migration_log from anon, authenticated;

-- ---------------------------------------------------------------------
-- (1) grid の中の全セルに安定IDを足す
--   jsonb の入れ子（rows[] → cells{} → セル）を、形を保ったまま書き換える。
--   ・"i" が数値で、その位置の塗料が paints にある場合だけ "id" を足す
--   ・すでに "id" があるセルは触らない（何度実行しても同じ結果＝冪等）
--   ・手入力("c"だけ)のセルも触らない
-- ---------------------------------------------------------------------
create or replace function public.add_paint_ids_to_grid(g jsonb)
returns jsonb language plpgsql immutable as $$
declare
  rows_in jsonb; row_elem jsonb; new_rows jsonb := '[]'::jsonb;
  cells_in jsonb; new_cells jsonb; ck text; cv jsonb; pid text;
begin
  if g is null or jsonb_typeof(g->'rows') <> 'array' then return g; end if;
  rows_in := g->'rows';

  for row_elem in select jsonb_array_elements(rows_in) loop
    cells_in := row_elem->'cells';
    if jsonb_typeof(cells_in) = 'object' then
      new_cells := '{}'::jsonb;
      for ck, cv in select key, value from jsonb_each(cells_in) loop
        -- 対象は「まだ id が無く」「i が数値」のセルだけ
        if jsonb_typeof(cv) = 'object'
           and not (cv ? 'id')
           and cv ? 'i'
           -- 桁数を9桁までに制限。int の範囲を超える値をキャストすると例外になり、
           -- 移行そのものが途中で止まる（015と同じ理由の防御）
           and (cv->>'i') ~ '^[0-9]{1,9}$'
        then
          select p.id into pid from public.paints p where p.sort_order = (cv->>'i')::int;
          if pid is not null then
            cv := cv || jsonb_build_object('id', pid);
          end if;
        end if;
        new_cells := new_cells || jsonb_build_object(ck, cv);
      end loop;
      row_elem := row_elem || jsonb_build_object('cells', new_cells);
    end if;
    new_rows := new_rows || jsonb_build_array(row_elem);
  end loop;

  return g || jsonb_build_object('rows', new_rows);
end; $$;
-- 中身を書き換えられる関数なので、外部からは呼べないようにする
revoke all on function public.add_paint_ids_to_grid(jsonb) from public, anon, authenticated;

-- 実際に変換する（recipes と drafts の両方）
do $$
declare
  v_seen int; v_with_i int; v_fixed int;
begin
  -- ▼ recipes
  select count(*) into v_seen from public.recipes;
  select count(*) into v_with_i from (
    select (jsonb_each(case when jsonb_typeof(re->'cells')='object' then re->'cells' else '{}'::jsonb end)).value as cell
    from public.recipes r,
         lateral jsonb_array_elements(case when jsonb_typeof(r.grid->'rows')='array' then r.grid->'rows' else '[]'::jsonb end) re
  ) t where cell ? 'i';

  update public.recipes set grid = public.add_paint_ids_to_grid(grid)
   where grid is not null and jsonb_typeof(grid->'rows') = 'array';

  select count(*) into v_fixed from (
    select (jsonb_each(case when jsonb_typeof(re->'cells')='object' then re->'cells' else '{}'::jsonb end)).value as cell
    from public.recipes r,
         lateral jsonb_array_elements(case when jsonb_typeof(r.grid->'rows')='array' then r.grid->'rows' else '[]'::jsonb end) re
  ) t where cell ? 'id';

  insert into public.paint_id_migration_log(target, rows_seen, cells_with_i, cells_fixed)
  values ('recipes', v_seen, v_with_i, v_fixed);
  raise notice '[020] recipes: % 件を確認 / 位置参照 % セル / 安定ID付き % セル', v_seen, v_with_i, v_fixed;

  -- ▼ drafts
  select count(*) into v_seen from public.drafts;
  select count(*) into v_with_i from (
    select (jsonb_each(case when jsonb_typeof(re->'cells')='object' then re->'cells' else '{}'::jsonb end)).value as cell
    from public.drafts d,
         lateral jsonb_array_elements(case when jsonb_typeof(d.grid->'rows')='array' then d.grid->'rows' else '[]'::jsonb end) re
  ) t where cell ? 'i';

  update public.drafts set grid = public.add_paint_ids_to_grid(grid)
   where grid is not null and jsonb_typeof(grid->'rows') = 'array';

  select count(*) into v_fixed from (
    select (jsonb_each(case when jsonb_typeof(re->'cells')='object' then re->'cells' else '{}'::jsonb end)).value as cell
    from public.drafts d,
         lateral jsonb_array_elements(case when jsonb_typeof(d.grid->'rows')='array' then d.grid->'rows' else '[]'::jsonb end) re
  ) t where cell ? 'id';

  insert into public.paint_id_migration_log(target, rows_seen, cells_with_i, cells_fixed)
  values ('drafts', v_seen, v_with_i, v_fixed);
  raise notice '[020] drafts: % 件を確認 / 位置参照 % セル / 安定ID付き % セル', v_seen, v_with_i, v_fixed;
end $$;

-- ---------------------------------------------------------------------
-- (2) 検索用の明細を作る関数を「安定ID優先」に書き換える
--   これまでは cell->'i' から paints.sort_order を引いていた。
--   つまり **明細の側も塗料リストの並びに依存していた**（画面と同じ爆弾を抱えていた）。
--   これからは cell->'id' をそのまま使い、無いときだけ従来の方法に落とす。
--
--   ★土台は 015 の定義。005ではなく015を必ず基準にすること。
--     015 で「壊れたデータでも投稿の保存が失敗しない」ようにする2つの防御が入っている:
--       ・procs の要素がオブジェクトでない（数値など）場合に読み飛ばす
--       ・c.i の桁数を9桁までに制限し、int の範囲を超える値で例外にしない
--     005 を土台にするとこの2つが消え、壊れたデータを持つ人が投稿できなくなる
--     （実際に一度この巻き戻しを起こし、DBテストが検出した）。
-- ---------------------------------------------------------------------
create or replace function public.sync_recipe_paints(p_recipe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g jsonb; proc_map jsonb := '{}'::jsonb; p jsonb; row_elem jsonb;
  cell_key text; cell_val jsonb; v_proc text; v_paint_id text; v_free text;
begin
  select grid into g from public.recipes where id = p_recipe_id;
  delete from public.recipe_paints where recipe_id = p_recipe_id;
  if g is null then return; end if;

  if jsonb_typeof(g->'procs') = 'array' then
    for p in select jsonb_array_elements(g->'procs') loop
      if jsonb_typeof(p) = 'object' and p->>'id' is not null then     -- 015: 型を確認してから使う
        proc_map := proc_map || jsonb_build_object(p->>'id', p->>'name');
      end if;
    end loop;
  end if;

  if jsonb_typeof(g->'rows') = 'array' then
    for row_elem in select jsonb_array_elements(g->'rows') loop
      if jsonb_typeof(row_elem) = 'object' and jsonb_typeof(row_elem->'cells') = 'object' then
        for cell_key, cell_val in select key, value from jsonb_each(row_elem->'cells') loop
          v_proc := proc_map->>cell_key; v_paint_id := null; v_free := null;
          if jsonb_typeof(cell_val) = 'object' then

            -- ★020: 安定IDが最優先。実在するIDのときだけ採用する
            --   （知らないIDをそのまま入れると外部キー違反になり、保存全体が失敗するため）
            if cell_val ? 'id' then
              select p2.id into v_paint_id from public.paints p2 where p2.id = cell_val->>'id';
            end if;

            -- IDが無い/見つからないときだけ、従来どおり位置から引く（過去データ互換）
            -- 015: 桁数を9桁までに制限（int の範囲を超える値で例外にしない）
            if v_paint_id is null and cell_val ? 'i' and (cell_val->>'i') ~ '^[0-9]{1,9}$' then
              select p3.id into v_paint_id from public.paints p3 where p3.sort_order = (cell_val->>'i')::int;
            end if;

            if v_paint_id is null and cell_val ? 'c' then
              v_free := nullif(btrim(cell_val->>'c'), '');
            end if;
          end if;
          if v_paint_id is not null or v_free is not null then
            insert into public.recipe_paints(recipe_id, paint_id, free_name, proc_name)
            values (p_recipe_id, v_paint_id, v_free, v_proc);
          end if;
        end loop;
      end if;
    end loop;
  end if;
end; $$;

-- ---------------------------------------------------------------------
-- (3) 明細を新しい方式で作り直す
--   (1)でgridを書き換えたので、明細も同じ内容から作り直して整合させる。
-- ---------------------------------------------------------------------
do $$
declare r record; n int := 0;
begin
  for r in select id from public.recipes loop
    perform public.sync_recipe_paints(r.id);
    n := n + 1;
  end loop;
  raise notice '[020] 検索用の明細を % 件のレシピについて作り直しました', n;
end $$;

-- ---------------------------------------------------------------------
-- (4) 検算 — 移行できていないセルが残っていないかを表示する
--   「位置参照はあるが安定IDが無い」セルが0件なら成功。
--   0でない場合は、その "i" に対応する塗料が paints に無い（＝リストのズレ）ことを意味する。
-- ---------------------------------------------------------------------
do $$
declare v_left int;
begin
  select count(*) into v_left from (
    select (jsonb_each(case when jsonb_typeof(re->'cells')='object' then re->'cells' else '{}'::jsonb end)).value as cell
    from public.recipes r,
         lateral jsonb_array_elements(case when jsonb_typeof(r.grid->'rows')='array' then r.grid->'rows' else '[]'::jsonb end) re
  ) t where cell ? 'i' and not (cell ? 'id');

  if v_left = 0 then
    raise notice '[020] ✓ 検算OK: 安定IDに変換できていないセルは0件';
  else
    raise warning '[020] ★未変換のセルが % 件あります。対応する塗料が paints に見つかりません', v_left;
  end if;
end $$;
