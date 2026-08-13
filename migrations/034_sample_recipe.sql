-- ============================================================================
-- 034: 「サイトの見本投稿」を1件だけ指定できるようにする
-- ※ Supabase の SQL Editor で実行してください（033の後）。冪等。
-- ============================================================================
--
-- ★何のためか
--   初めて来た人に「このサイトを使うと何が残るのか」を1秒で見せたい。
--   そのために、実在する投稿を1件だけ「見本」として指定できるようにする。
--   文章の説明書は読まれないうえ、UIを変えるたび古くなる。
--   本物の投稿を指すなら、中身が古くなることはない。
--
-- ★設計の要点
--   ・投稿そのものを特別扱いしない。ふつうの投稿に「印」を1つ付けるだけ。
--     → 印を外せば即座にふつうの投稿へ戻る。取り返しがつく。
--   ・見本は同時に1件だけ（部分ユニーク索引で構造的に保証する）。
--   ・見本はランキング（人気の塗料・人気の塗装方法）から除外する。
--     運営が置いた投稿が集計を押し上げると、数字が実態を表さなくなるため。
--   ・利用者が自分の投稿を勝手に見本にすることはできない（下のトリガで防ぐ）。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) 印そのもの
-- ----------------------------------------------------------------------------
alter table public.recipes
  add column if not exists is_sample boolean not null default false;

comment on column public.recipes.is_sample is
  'サイトの見本として固定表示する投稿。同時に1件だけ。ランキングからは除外される。';

-- 「同時に1件だけ」をデータベース側で保証する。
-- ★アプリ側のチェックだけに頼らない。二重に指定された状態は画面がどう壊れるか読めず、
--   しかも気づきにくい。構造で不可能にしておく方が安全。
--   （where is_sample を付けているので、false の行はいくつあっても衝突しない）
create unique index if not exists recipes_one_sample
  on public.recipes ((is_sample)) where is_sample;

-- ----------------------------------------------------------------------------
-- (2) 利用者が自分で見本印を立てられないようにする
-- ----------------------------------------------------------------------------
-- ★なぜトリガで防ぐか
--   recipes の UPDATE ポリシーは「自分の投稿なら更新してよい」。
--   列単位の制限をかけると通常の編集が壊れるため、値の書き換えだけを差し戻す。
--   拒否（エラー）ではなく「元の値に戻す」ことで、ふつうに編集した人が
--   身に覚えのないエラーで保存できなくなる事故を避ける。
create or replace function public.guard_sample_flag()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return NEW; end if;      -- 内部処理・移行は対象外
  if public.is_admin() then return NEW; end if;       -- 管理者はそのまま通す
  if TG_OP = 'INSERT' then
    NEW.is_sample := false;
  elsif NEW.is_sample is distinct from OLD.is_sample then
    NEW.is_sample := OLD.is_sample;
  end if;
  return NEW;
end $$;

drop trigger if exists trg_guard_sample_flag on public.recipes;
create trigger trg_guard_sample_flag
  before insert or update on public.recipes
  for each row execute function public.guard_sample_flag();

-- ----------------------------------------------------------------------------
-- (3) 取得と設定の入口
-- ----------------------------------------------------------------------------
-- 誰でも呼べる。見本が無ければ0行を返すだけ（画面側は枠を出さない）。
-- 停止中(BAN)の利用者の投稿は返さない。他の一覧と同じ扱いに揃える。
create or replace function public.sample_recipe()
returns table(id uuid, title text, cover_url text, author_label text, memo text, created_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select r.id, r.title, r.cover_url, r.author_label, r.memo, r.created_at
    from public.recipes r
   where r.is_sample
     and r.is_public
     and not internal.owner_is_banned(r.owner_id)
   limit 1;
$$;

-- 見本の指定・解除は管理者だけ。rid に null を渡すと解除。
create or replace function public.set_sample_recipe(rid uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_admin() then raise exception '権限がありません'; end if;
  update public.recipes set is_sample = false where is_sample and (rid is null or id <> rid);
  if rid is not null then
    if not exists (select 1 from public.recipes where id = rid and is_public) then
      raise exception '公開されている投稿だけを見本にできます';
    end if;
    update public.recipes set is_sample = true where id = rid;
  end if;
end $$;

revoke all on function public.set_sample_recipe(uuid) from public, anon;
grant execute on function public.set_sample_recipe(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- (4) ランキングから見本を除外する
-- ----------------------------------------------------------------------------
-- ★運営が置いた1件が「人気の塗料」を押し上げると、数字が実態を表さなくなる。
--   見本は宣伝であって人気ではないので、集計から外す。
-- ★★ ここは本番で動いている定義をそのまま写し、`and not r.is_sample` だけを足している。
--   一度、頭の中で「こういう形だろう」と書き直したものを入れかけた。
--   実物は返す列が pid/label/sample_cover なのに、書き直した方は paint_id/name/cover_url
--   になっており、そのまま流していたら画面側(index.html)が読む名前と食い違って
--   「人気の塗料」から名前と作例写真が消えていた。
--   しかも CREATE OR REPLACE は戻り値の型を変えられないため、復旧の途中でエラーになって
--   そこで止まる。移行ファイルは「頭の中の理想形」ではなく**実物の写し**でなければならない。
create or replace function public.popular_paints(limit_n integer default 12)
returns table(pid text, label text, brand text, hex text, uses bigint, sample_cover text, sample_id uuid)
language sql stable security definer set search_path to 'public' as $$
  select coalesce(rp.paint_id,'free:'||rp.free_name), coalesce(pt.name,rp.free_name),
    coalesce(pt.brand,'自由入力'), pt.hex, count(distinct rp.recipe_id),
    (array_agg(r.cover_url order by r.view_count desc) filter (where r.cover_url is not null))[1],
    (array_agg(r.id order by r.view_count desc) filter (where r.cover_url is not null))[1]
  from public.recipe_paints rp
  join public.recipes r on r.id = rp.recipe_id and r.is_public = true
       and not internal.owner_is_banned(r.owner_id) and not r.is_sample
  left join public.paints pt on pt.id = rp.paint_id
  where coalesce(rp.proc_name,'') !~ '(サフ|下地|サーフェ|プライマ|トップ|クリア|スミ)'
  group by 1,2,3,4 order by 5 desc, 2 limit limit_n;
$$;

create or replace function public.popular_methods(limit_n integer default 12)
returns table(method text, uses bigint)
language sql stable security definer set search_path to 'public' as $$
  select m, count(distinct r.id) from public.recipes r,
    lateral jsonb_array_elements_text(to_jsonb(r.methods)) as m
  where r.is_public = true and not internal.owner_is_banned(r.owner_id) and not r.is_sample
  group by m order by 2 desc, 1 limit limit_n;
$$;

-- ----------------------------------------------------------------------------
-- (5) 自己点検：本当に入ったかを確認して、入っていなければ止める
-- ----------------------------------------------------------------------------
do $$
declare miss text := '';
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='recipes' and column_name='is_sample')
    then miss := miss || 'is_sample列 '; end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='recipes_one_sample')
    then miss := miss || '一意索引 '; end if;
  if not exists (select 1 from pg_trigger where tgname='trg_guard_sample_flag')
    then miss := miss || 'guardトリガ '; end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname='sample_recipe')
    then miss := miss || 'sample_recipe関数 '; end if;
  if miss <> '' then
    raise exception '034が完全に適用されていません: %', miss;
  end if;
  raise notice '034: すべて適用されました';
end $$;
