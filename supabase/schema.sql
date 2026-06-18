-- ============================================================================
-- 塗装レシピ録 / Paint Log v2 — データベース設計図(schema)
-- ----------------------------------------------------------------------------
-- 使い方: Supabaseの SQL Editor にこのファイルを貼って実行 → 次に seed_paints.sql を実行。
-- 何度実行しても安全(作り直しに耐えるよう書いてある)。
--
-- 設計方針(C=ハイブリッド):
--   recipes.grid に レシピ本体をJSONBで丸ごと保存(表示・編集用)
--   recipe_paints に 使った塗料を1行ずつ保存(検索・集計用)
-- 最重要: RLS(行レベルセキュリティ)で「他人の投稿を編集・削除できない」ことを保証する。
-- ============================================================================

-- 拡張機能(UUID生成用)。Supabaseでは既定で有効だが念のため。
create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1) profiles — ユーザー公開プロフィール(auth.users と1対1)
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  handle       text unique,                 -- @ユーザー名(後から設定可)
  display_name text,
  x_account    text,                         -- Xアカウント(@GunplaKuxii 等)
  bio          text,
  created_at   timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 2) paints — 塗料マスタ(512色)。seed_paints.sql で投入。読み取り専用。
-- ----------------------------------------------------------------------------
create table if not exists public.paints (
  id         text primary key,              -- 内容ハッシュの安定ID(例 pt_acd5816ded21)
  brand      text not null,                 -- ブランド/シリーズ(例 Mr.カラー)
  code       text,                          -- 型番(例 C1。空の塗料もある)
  name       text not null,                 -- 名称(例 ホワイト)
  hex        text,                          -- 近似色
  sort_order int                            -- 表示順(元データの並び)
);

-- ----------------------------------------------------------------------------
-- 3) recipes — 投稿(レシピ本体)。grid に v1の state 相当をJSONBで持つ。
-- ----------------------------------------------------------------------------
create table if not exists public.recipes (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.profiles(id) on delete cascade,
  title        text,                         -- キット名(state.kit)
  author_label text,                         -- 表示する制作者名(state.author)
  memo         text,                         -- 自由メモ(state.memo)
  grid         jsonb not null default '{}',  -- レシピ全体(procs/rows/cells/photos)
  cover_url    text,                         -- 表紙画像のURL(実体はR2。base64は入れない)
  is_public    boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 4) recipe_paints — 「どのレシピが・どの塗料を・どの工程で」使ったかの明細
--    検索(この塗料を使ったレシピ一覧)と集計(塗料別使用数・人気配色)の素。
-- ----------------------------------------------------------------------------
create table if not exists public.recipe_paints (
  id         bigint generated always as identity primary key,
  recipe_id  uuid not null references public.recipes(id) on delete cascade,
  paint_id   text references public.paints(id),  -- マスタの塗料(自由入力のときは null)
  free_name  text,                                -- マスタに無い手入力塗料名
  proc_name  text                                 -- 工程名(サフ/基本色/スミ入れ 等)
);

-- ----------------------------------------------------------------------------
-- 5) clips — 気に入った投稿のクリップ(あとで使う。今は箱だけ用意)
-- ----------------------------------------------------------------------------
create table if not exists public.clips (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  recipe_id  uuid not null references public.recipes(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, recipe_id)
);

-- ----------------------------------------------------------------------------
-- 索引(検索を速くする)
-- ----------------------------------------------------------------------------
create index if not exists idx_recipes_owner       on public.recipes(owner_id);
create index if not exists idx_recipes_public_new  on public.recipes(is_public, created_at desc);
create index if not exists idx_rp_recipe           on public.recipe_paints(recipe_id);
create index if not exists idx_rp_paint            on public.recipe_paints(paint_id);
create index if not exists idx_clips_recipe        on public.clips(recipe_id);

-- ----------------------------------------------------------------------------
-- updated_at を自動更新するトリガー
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

drop trigger if exists trg_recipes_updated_at on public.recipes;
create trigger trg_recipes_updated_at
  before update on public.recipes
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 新規ユーザー登録時に profiles を自動作成するトリガー
-- ----------------------------------------------------------------------------
-- プライバシー: Googleの本名は入れない。display_nameは空のまま作り、本人がニックネームを設定する。
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================================
-- RLS(行レベルセキュリティ)— ここが事故防止の核
-- ============================================================================
alter table public.profiles      enable row level security;
alter table public.paints        enable row level security;
alter table public.recipes       enable row level security;
alter table public.recipe_paints enable row level security;
alter table public.clips         enable row level security;

-- 作り直しに耐えるよう、既存ポリシーを落としてから作る
drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists paints_select   on public.paints;
drop policy if exists recipes_select  on public.recipes;
drop policy if exists recipes_insert  on public.recipes;
drop policy if exists recipes_update  on public.recipes;
drop policy if exists recipes_delete  on public.recipes;
drop policy if exists rp_select       on public.recipe_paints;
drop policy if exists rp_insert       on public.recipe_paints;
drop policy if exists rp_update       on public.recipe_paints;
drop policy if exists rp_delete       on public.recipe_paints;
drop policy if exists clips_all       on public.clips;

-- profiles: 読みは全員(公開プロフィール)/ 書きは本人の行だけ
create policy profiles_select on public.profiles
  for select using (true);
create policy profiles_insert on public.profiles
  for insert with check (id = auth.uid());
create policy profiles_update on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- paints: 読みは全員 / 書き込みポリシーは作らない = 一般ユーザーは変更不可
create policy paints_select on public.paints
  for select using (true);

-- recipes: 読みは「公開 or 自分」/ 作成・更新・削除は「自分の行」だけ
create policy recipes_select on public.recipes
  for select using (is_public or owner_id = auth.uid());
create policy recipes_insert on public.recipes
  for insert with check (owner_id = auth.uid());
create policy recipes_update on public.recipes
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy recipes_delete on public.recipes
  for delete using (owner_id = auth.uid());

-- recipe_paints: 親recipeが読めれば読める / 書きは親recipeの所有者だけ
create policy rp_select on public.recipe_paints
  for select using (exists (
    select 1 from public.recipes r
    where r.id = recipe_id and (r.is_public or r.owner_id = auth.uid())
  ));
create policy rp_insert on public.recipe_paints
  for insert with check (exists (
    select 1 from public.recipes r
    where r.id = recipe_id and r.owner_id = auth.uid()
  ));
create policy rp_update on public.recipe_paints
  for update using (exists (
    select 1 from public.recipes r
    where r.id = recipe_id and r.owner_id = auth.uid()
  ));
create policy rp_delete on public.recipe_paints
  for delete using (exists (
    select 1 from public.recipes r
    where r.id = recipe_id and r.owner_id = auth.uid()
  ));

-- clips: 本人だけ(読み書き全て)
create policy clips_all on public.clips
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- 段1 追加: 管理者フラグ / タグ / 通報
-- ----------------------------------------------------------------------------
-- profiles に管理者フラグを追加(運営削除・通報閲覧用。自分のidだけ手動でtrueにする)
alter table public.profiles add column if not exists is_admin boolean not null default false;

-- プロフィール公開情報の追加列(emailはauth側で非公開のまま)
alter table public.profiles add column if not exists link       text;  -- 任意リンク(X/サイト等)
alter table public.profiles add column if not exists avatar_url text;  -- アイコン画像URL(画像ステップで使用)
alter table public.profiles add column if not exists header_url text;  -- ヘッダー画像URL(画像ステップで使用)
alter table public.profiles add column if not exists terms_agreed_at timestamptz;  -- 利用規約・プライバシーへの同意時刻

-- 自分が管理者か判定するヘルパー(RLSの再帰を避けるため security definer)
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- ----------------------------------------------------------------------------
-- 6) tags — 塗装方法などのタグ(段5の集計で使う。器は今作る)
-- ----------------------------------------------------------------------------
create table if not exists public.tags (
  id    bigint generated always as identity primary key,
  slug  text unique not null,      -- URL用の安定キー(例 "gradation")
  label text not null              -- 表示名(例 "グラデーション塗装")
);

-- 7) recipe_tags — 投稿とタグの紐付け(多対多)
create table if not exists public.recipe_tags (
  recipe_id uuid   not null references public.recipes(id) on delete cascade,
  tag_id    bigint not null references public.tags(id)    on delete cascade,
  primary key (recipe_id, tag_id)
);

-- 8) reports — 通報(段4で使う。器は今作る)
create table if not exists public.reports (
  id          bigint generated always as identity primary key,
  recipe_id   uuid not null references public.recipes(id) on delete cascade,
  reporter_id uuid references public.profiles(id) on delete set null,  -- 通報者(ログイン必須)
  reason      text,                                  -- 種別(スパム/不適切 等)
  detail      text,                                  -- 自由記述
  status      text not null default 'open',          -- open / reviewed / closed
  created_at  timestamptz not null default now()
);

-- 索引
create index if not exists idx_recipe_tags_tag on public.recipe_tags(tag_id);
create index if not exists idx_reports_status  on public.reports(status, created_at desc);
create index if not exists idx_reports_recipe  on public.reports(recipe_id);

-- ----------------------------------------------------------------------------
-- RLS(タグ・通報)
-- ----------------------------------------------------------------------------
alter table public.tags        enable row level security;
alter table public.recipe_tags enable row level security;
alter table public.reports     enable row level security;

drop policy if exists tags_select       on public.tags;
drop policy if exists tags_admin_write  on public.tags;
drop policy if exists rt_select         on public.recipe_tags;
drop policy if exists rt_insert         on public.recipe_tags;
drop policy if exists rt_delete         on public.recipe_tags;
drop policy if exists reports_insert    on public.reports;
drop policy if exists reports_select    on public.reports;
drop policy if exists reports_update    on public.reports;

-- tags: 読みは全員 / 書きは管理者のみ
create policy tags_select on public.tags
  for select using (true);
create policy tags_admin_write on public.tags
  for all using (public.is_admin()) with check (public.is_admin());

-- recipe_tags: 親recipeが読めれば読める / 付け外しは親recipeの所有者
create policy rt_select on public.recipe_tags
  for select using (exists (
    select 1 from public.recipes r
    where r.id = recipe_id and (r.is_public or r.owner_id = auth.uid())
  ));
create policy rt_insert on public.recipe_tags
  for insert with check (exists (
    select 1 from public.recipes r
    where r.id = recipe_id and r.owner_id = auth.uid()
  ));
create policy rt_delete on public.recipe_tags
  for delete using (exists (
    select 1 from public.recipes r
    where r.id = recipe_id and r.owner_id = auth.uid()
  ));

-- reports: 追加はログイン済み本人 / 読み・更新は管理者のみ(通報内容は一般非公開)
create policy reports_insert on public.reports
  for insert with check (reporter_id = auth.uid());
create policy reports_select on public.reports
  for select using (public.is_admin());
create policy reports_update on public.reports
  for update using (public.is_admin()) with check (public.is_admin());

-- recipes: 削除に管理者例外を追加(運営は通報対応で消せる)
drop policy if exists recipes_delete on public.recipes;
create policy recipes_delete on public.recipes
  for delete using (owner_id = auth.uid() or public.is_admin());

-- ============================================================================
-- 完了。次に seed_paints.sql を実行して塗料512色を投入する。
-- ============================================================================
