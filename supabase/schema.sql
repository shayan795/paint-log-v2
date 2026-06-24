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
alter table public.profiles add column if not exists has_password boolean not null default false;  -- メール+パスワード認証を持つか（Google単独はfalse／設定変更時のみtrue化）

-- ユーザーID（半角英数_・公開ID・一度決めたら変更不可）。display_name はニックネーム(変更可)
alter table public.profiles add column if not exists user_id text;
create unique index if not exists profiles_user_id_key on public.profiles(lower(user_id));  -- 大小無視で一意

-- 段5: 閲覧数（人気/トレンド表示用）。公開投稿のみ加算。他人投稿も増やせるよう SECURITY DEFINER RPC
alter table public.recipes add column if not exists view_count int not null default 0;
create or replace function public.increment_view(rid uuid)
returns void language sql security definer set search_path = public as $$
  update public.recipes set view_count = view_count + 1 where id = rid and is_public = true;
$$;
grant execute on function public.increment_view(uuid) to anon, authenticated;

-- user_id を不変にする（一度設定したら変更不可）
create or replace function public.lock_user_id()
returns trigger language plpgsql as $$
begin
  if old.user_id is not null and new.user_id is distinct from old.user_id then
    raise exception 'user_id は変更できません';
  end if;
  return new;
end; $$;
drop trigger if exists trg_lock_user_id on public.profiles;
create trigger trg_lock_user_id before update on public.profiles
  for each row execute function public.lock_user_id();

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
drop policy if exists reports_delete    on public.reports;

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
create policy reports_delete on public.reports
  for delete using (public.is_admin());

-- recipes: 削除に管理者例外を追加(運営は通報対応で消せる)
drop policy if exists recipes_delete on public.recipes;
create policy recipes_delete on public.recipes
  for delete using (owner_id = auth.uid() or public.is_admin());

-- ----------------------------------------------------------------------------
-- 9) inquiries — お問い合わせ(段6)。送信=ログイン本人 / 閲覧・更新=管理者のみ
-- ----------------------------------------------------------------------------
create table if not exists public.inquiries (
  id         bigint generated always as identity primary key,
  user_id    uuid references public.profiles(id) on delete set null,
  category   text,
  body       text not null,
  status     text not null default 'open',
  created_at timestamptz not null default now()
);
create index if not exists idx_inquiries_status on public.inquiries(status, created_at desc);
alter table public.inquiries enable row level security;
drop policy if exists inquiries_insert on public.inquiries;
drop policy if exists inquiries_select on public.inquiries;
drop policy if exists inquiries_update on public.inquiries;
drop policy if exists inquiries_delete on public.inquiries;
create policy inquiries_insert on public.inquiries for insert with check (user_id = auth.uid());
create policy inquiries_select on public.inquiries for select using (public.is_admin());
create policy inquiries_update on public.inquiries for update using (public.is_admin()) with check (public.is_admin());
create policy inquiries_delete on public.inquiries for delete using (public.is_admin());

-- ----------------------------------------------------------------------------
-- 10) events — プロダクト・アナリティクス（段7-3.6）
--   匿名含め全員が書き込み可（fire-and-forget）／読み取りは管理者のみ
-- ----------------------------------------------------------------------------
create table if not exists public.events(
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  user_id uuid references public.profiles(id) on delete set null,
  session_id text,
  event_name text not null,
  properties jsonb not null default '{}'::jsonb
);
create index if not exists idx_events_name_at on public.events(event_name, occurred_at desc);
create index if not exists idx_events_user on public.events(user_id);

alter table public.events enable row level security;
drop policy if exists events_insert on public.events;
drop policy if exists events_select on public.events;
create policy events_insert on public.events for insert with check (true);
create policy events_select on public.events for select using (public.is_admin());

-- ----------------------------------------------------------------------------
-- 11) notifications — アプリ内通知（段7-3.8）
-- ----------------------------------------------------------------------------
create table if not exists public.notifications(
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  type        text not null,
  title       text,
  body        text,
  link        text,
  read_at     timestamptz
);
create index if not exists idx_notifications_user_unread
  on public.notifications(user_id, read_at, created_at desc);

alter table public.notifications enable row level security;
drop policy if exists notifications_select on public.notifications;
drop policy if exists notifications_update on public.notifications;
create policy notifications_select on public.notifications
  for select using (user_id = auth.uid());
create policy notifications_update on public.notifications
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 共通：認証ユーザーが自分宛にだけ通知を作れるRPC（セキュリティ変更通知用）
create or replace function public.notify_self(_type text, _title text, _body text, _link text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications(user_id, type, title, body, link)
  values (auth.uid(), _type, _title, _body, _link);
end; $$;
revoke all on function public.notify_self(text,text,text,text) from public, anon;
grant execute on function public.notify_self(text,text,text,text) to authenticated;

-- clips→saved（投稿者に通知）。自分が自分の投稿を保存した時はスキップ
create or replace function public.on_clip_inserted()
returns trigger language plpgsql security definer set search_path = public as $$
declare ownerid uuid; rtitle text;
begin
  select owner_id, coalesce(title,'無題') into ownerid, rtitle
    from public.recipes where id = NEW.recipe_id;
  if ownerid is not null and ownerid <> NEW.user_id then
    insert into public.notifications(user_id, type, title, body, link)
    values (ownerid, 'saved', '投稿が保存されました',
            'あなたの投稿「'||rtitle||'」が保存されました。',
            'legacy.html?id='||NEW.recipe_id::text||'#view');
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_clip_inserted on public.clips;
create trigger trg_clip_inserted after insert on public.clips
  for each row execute function public.on_clip_inserted();

-- reports insert → 管理者全員へ new_report
create or replace function public.on_report_inserted()
returns trigger language plpgsql security definer set search_path = public as $$
declare admin_id uuid;
begin
  for admin_id in select id from public.profiles where is_admin = true loop
    insert into public.notifications(user_id, type, title, body, link)
    values (admin_id, 'new_report', '新しい通報',
            '通報が届きました（理由: '||coalesce(NEW.reason,'未指定')||'）',
            'index.html#reports');
  end loop;
  return NEW;
end; $$;
drop trigger if exists trg_report_inserted on public.reports;
create trigger trg_report_inserted after insert on public.reports
  for each row execute function public.on_report_inserted();

-- 連投制限：通報は同一ユーザー30秒間隔（スパム/管理画面埋め立て防止・サーバ側で強制）
create or replace function public.check_report_rate()
returns trigger language plpgsql as $$
declare last_at timestamptz;
begin
  if NEW.reporter_id is null then return NEW; end if;
  select max(created_at) into last_at from public.reports where reporter_id = NEW.reporter_id;
  if last_at is not null and now() - last_at < interval '30 seconds' then
    raise exception '通報が連続しています。少し時間をおいてからお試しください。';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_check_report_rate on public.reports;
create trigger trg_check_report_rate before insert on public.reports
  for each row execute function public.check_report_rate();

-- 連投制限：お問い合わせは同一ユーザー60秒間隔
create or replace function public.check_inquiry_rate()
returns trigger language plpgsql as $$
declare last_at timestamptz;
begin
  if NEW.user_id is null then return NEW; end if;
  select max(created_at) into last_at from public.inquiries where user_id = NEW.user_id;
  if last_at is not null and now() - last_at < interval '60 seconds' then
    raise exception 'お問い合わせが連続しています。1分ほどおいてからお試しください。';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_check_inquiry_rate on public.inquiries;
create trigger trg_check_inquiry_rate before insert on public.inquiries
  for each row execute function public.check_inquiry_rate();

-- reports update（open→reviewed）→ 通報対象投稿の所有者へ report_reviewed
create or replace function public.on_report_status_changed()
returns trigger language plpgsql security definer set search_path = public as $$
declare ownerid uuid;
begin
  if (OLD.status is distinct from NEW.status) and NEW.status = 'reviewed' then
    select owner_id into ownerid from public.recipes where id = NEW.recipe_id;
    if ownerid is not null then
      insert into public.notifications(user_id, type, title, body, link)
      values (ownerid, 'report_reviewed', '通報の確認が完了しました',
              'あなたの投稿に対する通報が運営により確認されました。',
              'legacy.html?id='||NEW.recipe_id::text||'#view');
    end if;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_report_status on public.reports;
create trigger trg_report_status after update on public.reports
  for each row execute function public.on_report_status_changed();

-- inquiries insert → 管理者全員へ new_inquiry
create or replace function public.on_inquiry_inserted()
returns trigger language plpgsql security definer set search_path = public as $$
declare admin_id uuid;
begin
  for admin_id in select id from public.profiles where is_admin = true loop
    insert into public.notifications(user_id, type, title, body, link)
    values (admin_id, 'new_inquiry', '新しいお問い合わせ',
            'お問い合わせが届きました。',
            'index.html#inquiries');
  end loop;
  return NEW;
end; $$;
drop trigger if exists trg_inquiry_inserted on public.inquiries;
create trigger trg_inquiry_inserted after insert on public.inquiries
  for each row execute function public.on_inquiry_inserted();

-- inquiries update（open→reviewed）→ 問い合わせ者へ inquiry_replied
create or replace function public.on_inquiry_status_changed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (OLD.status is distinct from NEW.status) and NEW.status = 'reviewed' then
    insert into public.notifications(user_id, type, title, body, link)
    values (NEW.user_id, 'inquiry_replied', 'お問い合わせの対応が完了',
            '運営があなたのお問い合わせを確認しました。',
            'index.html#settings');
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_inquiry_status on public.inquiries;
create trigger trg_inquiry_status after update on public.inquiries
  for each row execute function public.on_inquiry_status_changed();

-- ----------------------------------------------------------------------------
-- 12) comments — 投稿へのコメント（段7-3.9）
-- ----------------------------------------------------------------------------
alter table public.profiles add column if not exists notify_comments boolean not null default true;  -- 自分の投稿にコメントが付いた時の通知ON/OFF
alter table public.recipes  add column if not exists comments_disabled boolean not null default false; -- 投稿者がコメントを停止できる

create table if not exists public.comments(
  id          bigint generated always as identity primary key,
  recipe_id   uuid not null references public.recipes(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now(),
  edited_at   timestamptz
);
create index if not exists idx_comments_recipe on public.comments(recipe_id, created_at);
create index if not exists idx_comments_user   on public.comments(user_id);

-- 返信機能：1階層フラット（Instagram式）。返信は parent_id にトップレベルコメントのIDを入れる
alter table public.comments add column if not exists parent_id bigint references public.comments(id) on delete cascade;
create index if not exists idx_comments_parent on public.comments(parent_id) where parent_id is not null;

alter table public.comments enable row level security;
drop policy if exists comments_select on public.comments;
drop policy if exists comments_insert on public.comments;
drop policy if exists comments_update on public.comments;
drop policy if exists comments_delete on public.comments;
-- 読み：公開投稿のコメントは誰でも／非公開は投稿者のみ
create policy comments_select on public.comments
  for select using (
    exists (select 1 from public.recipes r
            where r.id = recipe_id and (r.is_public or r.owner_id = auth.uid()))
  );
-- 書き込み：本人のみ。投稿が公開かつコメント許可中であること（RLSで強制）
create policy comments_insert on public.comments
  for insert with check (
    user_id = auth.uid()
    and exists (select 1 from public.recipes r
                where r.id = recipe_id and r.is_public = true and r.comments_disabled = false)
  );
-- 編集：本人のみ
create policy comments_update on public.comments
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
-- 削除：本人 or 管理者
create policy comments_delete on public.comments
  for delete using (user_id = auth.uid() or public.is_admin());

-- 節度確保(1) 連投制限：同一ユーザーは30秒間隔
create or replace function public.check_comment_rate()
returns trigger language plpgsql as $$
declare last_at timestamptz;
begin
  select max(created_at) into last_at from public.comments where user_id = NEW.user_id;
  if last_at is not null and now() - last_at < interval '30 seconds' then
    raise exception '連続投稿を制限しています。30秒お待ちください。';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_check_comment_rate on public.comments;
create trigger trg_check_comment_rate before insert on public.comments
  for each row execute function public.check_comment_rate();

-- 節度確保(2) NGワード：露骨な攻撃・差別語の最小セットを弾く（リストは schema 内でのみ管理）
create or replace function public.check_comment_ngword()
returns trigger language plpgsql as $$
declare ng text;
begin
  for ng in select unnest(array[
    '死ね','殺す','クズ','ゴミ','うざい','馬鹿野郎','カス','消えろ','ブス','キモい'
  ]) loop
    if NEW.body ilike '%' || ng || '%' then
      raise exception 'このコメントには使用できない語句が含まれています。';
    end if;
  end loop;
  return NEW;
end; $$;
drop trigger if exists trg_check_comment_ngword on public.comments;
create trigger trg_check_comment_ngword before insert or update on public.comments
  for each row execute function public.check_comment_ngword();

-- 編集時に edited_at を自動セット
create or replace function public.on_comment_updated()
returns trigger language plpgsql as $$
begin NEW.edited_at = now(); return NEW; end; $$;
drop trigger if exists trg_comment_updated on public.comments;
create trigger trg_comment_updated before update on public.comments
  for each row execute function public.on_comment_updated();

-- insert→投稿者へ通知＋（返信時のみ）親コメント投稿者にも通知
-- 重複防止：同一人物には1通だけ
create or replace function public.on_comment_inserted()
returns trigger language plpgsql security definer set search_path = public as $$
declare ownerid uuid; recv_pref boolean; rtitle text; parent_userid uuid;
begin
  select owner_id, coalesce(title,'無題') into ownerid, rtitle
    from public.recipes where id = NEW.recipe_id;

  -- 1) 投稿者への通知（自分宛/通知オフ なら除外）
  if ownerid is not null and ownerid <> NEW.user_id then
    select notify_comments into recv_pref from public.profiles where id = ownerid;
    if coalesce(recv_pref, true) then
      insert into public.notifications(user_id, type, title, body, link)
      values (ownerid,
              case when NEW.parent_id is null then 'comment' else 'reply' end,
              case when NEW.parent_id is null then '投稿にコメントが届きました' else '投稿に返信が届きました' end,
              '「'||rtitle||'」: '||left(NEW.body, 80),
              'legacy.html?id='||NEW.recipe_id::text||'#view');
    end if;
  end if;

  -- 2) 返信の場合、親コメント投稿者にも通知（投稿者と同一/自分自身/通知オフ ならスキップ）
  if NEW.parent_id is not null then
    select user_id into parent_userid from public.comments where id = NEW.parent_id;
    if parent_userid is not null
       and parent_userid <> NEW.user_id
       and (ownerid is null or parent_userid <> ownerid) then
      select notify_comments into recv_pref from public.profiles where id = parent_userid;
      if coalesce(recv_pref, true) then
        insert into public.notifications(user_id, type, title, body, link)
        values (parent_userid, 'reply',
                'あなたのコメントに返信が届きました',
                '「'||rtitle||'」: '||left(NEW.body, 80),
                'legacy.html?id='||NEW.recipe_id::text||'#view');
      end if;
    end if;
  end if;

  return NEW;
end; $$;
drop trigger if exists trg_comment_inserted on public.comments;
create trigger trg_comment_inserted after insert on public.comments
  for each row execute function public.on_comment_inserted();

-- ----------------------------------------------------------------------------
-- 13) comment_likes — コメントへのいいね（段7-3.10）
-- ----------------------------------------------------------------------------
create table if not exists public.comment_likes(
  comment_id bigint not null references public.comments(id) on delete cascade,
  user_id    uuid   not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
create index if not exists idx_comment_likes_user on public.comment_likes(user_id);

alter table public.comment_likes enable row level security;
drop policy if exists comment_likes_select on public.comment_likes;
drop policy if exists comment_likes_insert on public.comment_likes;
drop policy if exists comment_likes_delete on public.comment_likes;

-- 読み：そのコメントが見える人は全員見える（コメントRLSと一致させる）
create policy comment_likes_select on public.comment_likes
  for select using (
    exists (select 1 from public.comments c join public.recipes r on r.id = c.recipe_id
            where c.id = comment_likes.comment_id and (r.is_public or r.owner_id = auth.uid()))
  );
-- 書き：本人のみ
create policy comment_likes_insert on public.comment_likes
  for insert with check (user_id = auth.uid());
-- 削除：本人のみ
create policy comment_likes_delete on public.comment_likes
  for delete using (user_id = auth.uid());

-- ============================================================================
-- 段5: 集計の土台 — recipe_paints をグリッドから自動展開（人気塗料ランキング用）
-- 前提: paints.sort_order = クライアント配列index = レシピ grid の c.i（整列seed適用済み）
-- ----------------------------------------------------------------------------
-- grid(JSONB) を読んで recipe_paints に展開する。
-- grid.rows[].cells[<colId>] = {"i": sort_order} or {"c": "自由名"}
-- grid.procs[] = [{"id":"q1","name":"サフ"} ...] で colId→工程名
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
          if cell_val ? 'i' then
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

-- recipes の grid が入る/変わるたびに recipe_paints を同期（cover/view_count更新では発火しない）
create or replace function public.trg_sync_recipe_paints()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.sync_recipe_paints(NEW.id); return NEW; end; $$;
drop trigger if exists trg_recipe_paints_sync on public.recipes;
create trigger trg_recipe_paints_sync after insert or update of grid on public.recipes
  for each row execute function public.trg_sync_recipe_paints();

-- 既存投稿を一括バックフィル（過去分も集計対象に）
do $$ declare r record; begin
  for r in select id from public.recipes loop perform public.sync_recipe_paints(r.id); end loop;
end $$;

-- ============================================================================
-- 完了。次に seed_paints.sql を実行して塗料512色を投入する。
-- ============================================================================
