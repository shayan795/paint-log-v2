-- =====================================================================
-- 005_review_fixes2.sql
--   Codex×Claude 相互レビューの Medium 群（DB側）をまとめて修正する。
--   いずれも「正規利用には影響せず、不正だけを塞ぐ」締め付け。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（004 の後）。冪等。
-- =====================================================================

-- ---------------------------------------------------------------------
-- #11 閲覧数の水増し（INSERT時の view_count 任意指定）
--   guard_view_count は before update のみで、所有者が作成時に view_count=9999 等を
--   仕込めた。before insert も対象にし、新規は必ず 0 から始める。
-- ---------------------------------------------------------------------
create or replace function public.guard_view_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    NEW.view_count := 0;                                   -- 新規は必ず0(初期値水増しを封じる)
  elsif NEW.view_count is distinct from OLD.view_count
     and coalesce(current_setting('app.allow_view', true), '') <> '1' then
    NEW.view_count := OLD.view_count;                      -- increment_view 以外の直接変更は戻す
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_guard_view_count on public.recipes;
create trigger trg_guard_view_count before insert or update on public.recipes
  for each row execute function public.guard_view_count();

-- ---------------------------------------------------------------------
-- #8 profiles の自己昇格（INSERT時の is_admin 指定）
--   guard_profile_admin は before update のみ。profile欠損ユーザーが自分の行を
--   is_admin=true で INSERT する隙があった。before insert も塞ぎ、
--   INSERT policy でも is_admin=false を強制する（handle_new_user は definer で無影響）。
-- ---------------------------------------------------------------------
create or replace function public.guard_profile_admin()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    if auth.uid() is not null then NEW.is_admin := false; end if;   -- 一般ユーザーの自己昇格を封じる
  elsif auth.uid() is not null and NEW.is_admin is distinct from OLD.is_admin then
    NEW.is_admin := OLD.is_admin;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_guard_profile_admin on public.profiles;
create trigger trg_guard_profile_admin before insert or update on public.profiles
  for each row execute function public.guard_profile_admin();

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles
  for insert with check (id = auth.uid() and coalesce(is_admin, false) = false);

-- ---------------------------------------------------------------------
-- #9 events のなりすまし（user_id/occurred_at 偽装）
--   匿名INSERTが with check(true) のため、公開profile UUIDで他人名義イベントを
--   投入できた。BEFORE INSERT で user_id と occurred_at をサーバー側で確定する。
--   （session_id は重複排除に使うためクライアント値のまま）
-- ---------------------------------------------------------------------
create or replace function public.guard_event_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  NEW.user_id := auth.uid();      -- クライアント申告を無視して確定(匿名はnull)
  NEW.occurred_at := now();
  return NEW;
end; $$;
drop trigger if exists trg_guard_event_insert on public.events;
create trigger trg_guard_event_insert before insert on public.events
  for each row execute function public.guard_event_insert();

-- ---------------------------------------------------------------------
-- #10 grid の無制限（サイズ／不正 c.i）
--   (a) 巨大 grid でDoS・検索/Worker増幅 → サイズ上限CHECK(約256KB)。既存行を止めない NOT VALID。
--   (b) sync_recipe_paints の (cell_val->>'i')::int が非数値 c.i で例外→保存中断。
--       数値のときだけキャストするようガード。
-- ---------------------------------------------------------------------
alter table public.recipes drop constraint if exists recipes_grid_size;
alter table public.recipes add  constraint recipes_grid_size check (pg_column_size(grid) < 262144) not valid;

create or replace function public.sync_recipe_paints(p_recipe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g jsonb; proc_map jsonb := '{}'::jsonb; p jsonb; row_elem jsonb;
  cell_key text; cell_val jsonb; v_proc text; v_paint_id text; v_free text;
begin
  select grid into g from public.recipes where id = p_recipe_id;
  delete from public.recipe_paints where recipe_id = p_recipe_id;   -- 入れ直し
  if g is null then return; end if;

  if jsonb_typeof(g->'procs') = 'array' then
    for p in select jsonb_array_elements(g->'procs') loop
      proc_map := proc_map || jsonb_build_object(p->>'id', p->>'name');
    end loop;
  end if;

  if jsonb_typeof(g->'rows') = 'array' then
    for row_elem in select jsonb_array_elements(g->'rows') loop
      if jsonb_typeof(row_elem->'cells') = 'object' then
        for cell_key, cell_val in select key, value from jsonb_each(row_elem->'cells') loop
          v_proc := proc_map->>cell_key; v_paint_id := null; v_free := null;
          if cell_val ? 'i' and (cell_val->>'i') ~ '^[0-9]+$' then          -- 数値のときだけキャスト
            select id into v_paint_id from public.paints where sort_order = (cell_val->>'i')::int;
          elsif cell_val ? 'c' then
            v_free := nullif(btrim(cell_val->>'c'), '');
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
-- #5 コメントの所属改変・返信先偽装・NG回避
--   (a) 不変列: 更新で recipe_id/user_id/parent_id/created_at を変えられないように。
--   (b) 返信先(parent_id)は「同じ投稿のトップレベルコメント」だけ許可(1階層フラット設計に一致)。
--   (c) NGワードは insert のみ→ body 変更を伴う update でも再チェック（回避封じ・語句は最小のまま）。
-- ---------------------------------------------------------------------
create or replace function public.guard_comment_integrity()
returns trigger language plpgsql set search_path = public as $$
begin
  if TG_OP = 'UPDATE' then
    if NEW.recipe_id  is distinct from OLD.recipe_id
       or NEW.user_id is distinct from OLD.user_id
       or NEW.parent_id is distinct from OLD.parent_id
       or NEW.created_at is distinct from OLD.created_at then
      raise exception 'コメントの所属情報は変更できません';
    end if;
  end if;
  if NEW.parent_id is not null then
    if not exists (
      select 1 from public.comments c
      where c.id = NEW.parent_id and c.parent_id is null and c.recipe_id = NEW.recipe_id
    ) then
      raise exception '不正な返信先です';
    end if;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_guard_comment_integrity on public.comments;
create trigger trg_guard_comment_integrity before insert or update on public.comments
  for each row execute function public.guard_comment_integrity();

create or replace function public.check_comment_ngword()
returns trigger language plpgsql set search_path = public as $$
declare ng text;
begin
  if TG_OP = 'INSERT' or NEW.body is distinct from OLD.body then
    for ng in select unnest(array['死ね','殺す','消えろ']) loop
      if NEW.body ilike '%' || ng || '%' then
        raise exception 'このコメントには使用できない語句が含まれています。';
      end if;
    end loop;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_check_comment_ngword on public.comments;
create trigger trg_check_comment_ngword before insert or update on public.comments
  for each row execute function public.check_comment_ngword();

-- ---------------------------------------------------------------------
-- #4(一部) 退会時に本人のStorage画像が孤児化して公開URLで残る
--   delete_user は auth.users しか消さず、recipes/profile バケットの画像が残っていた。
--   本人の uid プレフィックス配下を物理削除する（退会=完全削除の約束を満たす）。
--   ※recipes バケットの private 化＋署名URL移行は影響大のため別途（本修正は孤児化のみ解消）。
-- ---------------------------------------------------------------------
create or replace function public.delete_user()
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
begin
  delete from storage.objects
   where bucket_id in ('recipes','profile')
     and (storage.foldername(name))[1] = auth.uid()::text;
  delete from auth.users where id = auth.uid();
end; $$;
