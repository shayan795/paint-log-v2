-- =====================================================================
-- 007_audit_fixes.sql
--   Opus5 全面レビュー（敵対的検証済み）のDB側修正をまとめたもの。
--   いずれも「正規利用は今まで通り・不正だけを塞ぐ」締め付け。冪等。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（006 の後）。
-- =====================================================================

-- ---------------------------------------------------------------------
-- (1) created_at の偽装を封じる【High相当・影響が広い】
--   クライアントは REST で created_at を自由に指定でき、その結果:
--     ・コメント30秒/通報30秒/問い合わせ60秒の連投制限が「常にNULL比較」で全て無効化
--     ・recipes を未来日時にして 新着/おすすめ/トレンド/急上昇 を恒久占拠
--   INSERT は now() を強制、UPDATE は元の値を維持する。
--   auth.uid() が null（SQL Editor・service_role からのバックフィル）は従来通り自由。
-- ---------------------------------------------------------------------
create or replace function public.guard_created_at()
returns trigger language plpgsql as $$
begin
  if auth.uid() is null then return NEW; end if;   -- 管理・移行用の直接操作は許可
  if TG_OP = 'INSERT' then
    NEW.created_at := now();
  else
    NEW.created_at := OLD.created_at;
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_guard_created_at on public.recipes;
create trigger trg_guard_created_at before insert or update on public.recipes
  for each row execute function public.guard_created_at();
drop trigger if exists trg_guard_created_at on public.comments;
create trigger trg_guard_created_at before insert or update on public.comments
  for each row execute function public.guard_created_at();
drop trigger if exists trg_guard_created_at on public.reports;
create trigger trg_guard_created_at before insert or update on public.reports
  for each row execute function public.guard_created_at();
drop trigger if exists trg_guard_created_at on public.inquiries;
create trigger trg_guard_created_at before insert or update on public.inquiries
  for each row execute function public.guard_created_at();
drop trigger if exists trg_guard_created_at on public.clips;
create trigger trg_guard_created_at before insert or update on public.clips
  for each row execute function public.guard_created_at();
drop trigger if exists trg_guard_created_at on public.notifications;
create trigger trg_guard_created_at before insert or update on public.notifications
  for each row execute function public.guard_created_at();

-- ---------------------------------------------------------------------
-- (2) 保存(クリップ)の付け外しによる通知爆撃を止める
--   clips は (user_id, recipe_id) が主キーなので、解除→再保存を繰り返すと
--   そのたびに投稿者へ通知が飛ぶ。「誰が・どの投稿に対して通知済みか」を別表に残し、
--   同じ人×同じ投稿では二度目以降を通知しない（他の人の保存は今まで通り通知される）。
-- ---------------------------------------------------------------------
create table if not exists public.clip_notified (
  clipper_id uuid not null,
  recipe_id  uuid not null,
  created_at timestamptz not null default now(),
  primary key (clipper_id, recipe_id)
);
alter table public.clip_notified enable row level security;   -- ポリシー無し＝クライアントからは触れない

create or replace function public.on_clip_inserted()
returns trigger language plpgsql security definer set search_path = public as $$
declare ownerid uuid; rtitle text;
begin
  select owner_id, coalesce(title,'無題') into ownerid, rtitle
    from public.recipes where id = NEW.recipe_id;
  if ownerid is not null and ownerid <> NEW.user_id
     and not exists (select 1 from public.clip_notified
                     where clipper_id = NEW.user_id and recipe_id = NEW.recipe_id) then
    insert into public.notifications(user_id, type, title, body, link)
    values (ownerid, 'saved', '投稿が保存されました',
            'あなたの投稿「'||rtitle||'」が保存されました。',
            'legacy.html?id='||NEW.recipe_id::text||'#view');
    insert into public.clip_notified(clipper_id, recipe_id) values (NEW.user_id, NEW.recipe_id)
      on conflict do nothing;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_clip_inserted on public.clips;
create trigger trg_clip_inserted after insert on public.clips
  for each row execute function public.on_clip_inserted();

-- ---------------------------------------------------------------------
-- (3) 通知を本人が削除できるようにする（DELETEポリシーが無く、溜まると誰も消せない）
-- ---------------------------------------------------------------------
drop policy if exists notifications_delete on public.notifications;
create policy notifications_delete on public.notifications
  for delete using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- (4) 閲覧数の無限水増しを抑える
--   increment_view は匿名で無制限に呼べ、重複排除はクライアントのlocalStorageのみ。
--   サーバー側に「1投稿あたり1分60回まで」の上限を設ける（通常の閲覧には影響しない）。
-- ---------------------------------------------------------------------
create table if not exists public.view_throttle (
  recipe_id uuid not null,
  minute    timestamptz not null,
  cnt       int not null default 0,
  primary key (recipe_id, minute)
);
alter table public.view_throttle enable row level security;   -- ポリシー無し＝クライアントからは触れない

create or replace function public.increment_view(rid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m timestamptz := date_trunc('minute', now()); c int;
begin
  insert into public.view_throttle(recipe_id, minute, cnt) values (rid, m, 1)
    on conflict (recipe_id, minute) do update set cnt = public.view_throttle.cnt + 1
    returning cnt into c;
  if c > 60 then return; end if;                    -- 1分60回を超えた分は数えない
  perform set_config('app.allow_view', '1', true);
  update public.recipes set view_count = view_count + 1 where id = rid and is_public = true;
end; $$;
grant execute on function public.increment_view(uuid) to anon, authenticated;

-- 古い抑制記録の掃除も purge にまとめる（pg_cron 未使用なら手動実行でよい）
create or replace function public.purge_old_events()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.events        where occurred_at < now() - interval '90 days';
  delete from public.view_throttle where minute      < now() - interval '1 day';
end; $$;
revoke all on function public.purge_old_events() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- (5) 「人気の塗装方法」が1投稿で乗っ取れる
--   count(*) はタグ配列の要素数を数えるため、同じタグを大量に入れた1投稿で順位を独占できる。
--   投稿数（distinct recipe id）で数えるよう修正。
-- ---------------------------------------------------------------------
create or replace function public.popular_methods(limit_n int default 12)
returns table(method text, uses bigint)
language sql stable security definer set search_path = public as $$
  select m as method, count(distinct r.id) as uses
  from public.recipes r,
       lateral jsonb_array_elements_text(to_jsonb(r.methods)) as m
  where r.is_public = true
  group by m
  order by uses desc, m
  limit limit_n;
$$;
grant execute on function public.popular_methods(int) to anon, authenticated;

-- ---------------------------------------------------------------------
-- (6) 保存のたびに塗料マスターを全走査していた（索引が無い）
--   sync_recipe_paints が paints.sort_order で1セルずつ引くため、セル数×512行の走査になる。
-- ---------------------------------------------------------------------
create index if not exists idx_paints_sort_order on public.paints(sort_order);

-- ---------------------------------------------------------------------
-- (7) 容量枯渇の穴を塞ぐ
--   ・drafts.grid は recipes と違いサイズ無制限（下書き経由で無料枠500MBを一撃で埋められる）
--   ・events.session_id は長さ無制限（properties だけ2KB制限がある）
--   既存行を止めないよう NOT VALID（新規INSERTには即効く）。
-- ---------------------------------------------------------------------
alter table public.drafts drop constraint if exists drafts_grid_size;
alter table public.drafts add  constraint drafts_grid_size check (pg_column_size(grid) < 262144) not valid;

alter table public.events drop constraint if exists events_session_len;
alter table public.events add  constraint events_session_len check (char_length(coalesce(session_id,'')) <= 64) not valid;

-- ---------------------------------------------------------------------
-- (8) 公開ユーザーID(user_id)の形式をサーバー側でも検証
--   なりすまし表示（記号や空白混じり）を防ぐ。半角英数と _ のみ・2〜20文字。
-- ---------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_user_id_format;
alter table public.profiles add  constraint profiles_user_id_format
  check (user_id is null or user_id ~ '^[A-Za-z0-9_]{2,20}$') not valid;

-- ---------------------------------------------------------------------
-- (9) プロフィールの内部列を匿名から隠す
--   profiles_select は using(true) のため、is_admin（誰が管理者か）・has_password（認証方式）・
--   terms_agreed_at・notify_comments まで匿名で列挙できる。
--   ※Postgresはテーブル全体のSELECT権限が列単位の制限より優先されるため、
--     いったんテーブル権限を外し「公開して良い列だけ」を付け直す。
--   フロントの匿名経路は id,user_id,display_name,bio,link,avatar_url,header_url,x_account しか
--   使っていないことを確認済み（select * は自分のプロフィール取得＝ログイン時のみ）。
-- ---------------------------------------------------------------------
revoke select on public.profiles from anon;
grant  select (id, handle, user_id, display_name, bio, link, avatar_url, header_url, x_account, created_at)
  on public.profiles to anon;

-- ---------------------------------------------------------------------
-- (10) 内部管理用テーブルはクライアントから一切触れないようにする（多層防御）
--   RLSポリシー無しでも既定のテーブル権限が付くため明示的に剥奪する。
--   どちらも SECURITY DEFINER のトリガー/関数だけが読み書きする。
-- ---------------------------------------------------------------------
revoke all on public.view_throttle from anon, authenticated;
revoke all on public.clip_notified from anon, authenticated;
