-- ============================================================================
-- 033: 本番の現状に合わせる（023〜032が中身を持っていなかった問題の解消）
-- ============================================================================
-- ★なぜこのファイルが必要か（外部監査 H-10）
--   2026-08-01〜03の修正は、SQLを直接本番へ流して適用した。
--   その際 023 / 026 / 029 / 031 を「説明コメントだけ」のファイルとして残し、
--   024 / 028 / 030 / 032 に至ってはファイルすら作らなかった。
--   結果、**リポジトリのSQLを順に流しても本番と同じ状態にならない**。
--   バックアップからの復旧、開発環境の作り直し、別プロジェクトへの引っ越しをすると、
--   その時点で修正前の脆弱な定義に戻る＝復旧作業そのものが穴を開ける。
--
--   このファイルは、その差分をすべて実行可能なSQLとして書き起こしたもの。
--   001〜032 を流したあとに最後にこれを流せば、本番と同じ状態になる。
--   すべて create or replace / drop if exists なので、何度実行しても安全。
--
-- ★実行順序
--   supabase/schema.sql → seed → Storageバケット作成 → migrations/001〜032 → **このファイル**
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) internal スキーマ（APIに公開されない置き場）
-- ----------------------------------------------------------------------------
-- ★PostgREST(Data API)は public スキーマの関数を全部APIとして公開する。
--   「誰が停止中か」を判定する関数を public に置いていたため、
--   IDを渡すだけで他人の停止状態を1件ずつ確認できてしまっていた。
--   RLSポリシーからは呼べる必要があるが、APIからは呼べてはいけないので、
--   公開対象でない internal スキーマへ置く。
create schema if not exists internal;
grant usage on schema internal to anon, authenticated;

create or replace function internal.is_banned(uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select banned_at is not null from public.profiles where id = uid), false);
$$;
grant execute on function internal.is_banned(uuid) to anon, authenticated;

create or replace function internal.owner_is_banned(uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles p where p.id = uid and p.banned_at is not null);
$$;
grant execute on function internal.owner_is_banned(uuid) to anon, authenticated;

-- 旧 public 版は削除する（APIから見える入口を消す）
drop function if exists public.owner_is_banned(uuid);
drop function if exists public.is_banned(uuid);

-- 本人専用（引数を取らないので、他人の状態は原理的に聞けない）
create or replace function public.is_banned()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select banned_at is not null from public.profiles where id = auth.uid()), false);
$$;
revoke all on function public.is_banned() from public, anon;
grant execute on function public.is_banned() to authenticated;

-- ----------------------------------------------------------------------------
-- 2) 停止(BAN)した人の投稿・コメントを公開から隠す
-- ----------------------------------------------------------------------------
-- ★権利侵害や違法な画像を投稿した人を停止しても、投稿が公開されたままでは被害が続く。
--   ただし削除はしない（誤って停止したときに戻せなくなる／通報の証拠が消える）ため、
--   「見えなくする」だけにする。本人と管理者からは見える。
--   管理者の例外は公開投稿に限る＝運営でも他人の非公開レシピは見られない。
drop policy if exists recipes_select on public.recipes;
create policy recipes_select on public.recipes for select using (
  owner_id = auth.uid()
  or (is_public and (not internal.owner_is_banned(owner_id) or public.is_admin()))
);

-- 投稿が見えないなら、そこに付いたコメントも見えない（「非公開」の約束を守る）
drop policy if exists comments_select on public.comments;
create policy comments_select on public.comments for select using (
  (not internal.owner_is_banned(user_id) or public.is_admin())
  and exists (
    select 1 from public.recipes r
     where r.id = comments.recipe_id
       and (r.owner_id = auth.uid()
            or (r.is_public and (not internal.owner_is_banned(r.owner_id) or public.is_admin())))
  )
);

-- ----------------------------------------------------------------------------
-- 3) ランキングも停止した人を除く
-- ----------------------------------------------------------------------------
-- ★security definer の関数は「所有者の権限」で動くため、上のRLSが適用されない。
--   そのため停止した人のカバー画像がトップページに出続けていた。
--   RLSと同じ判定を関数の中にも書く必要がある。
create or replace function public.popular_paints(limit_n integer default 12)
returns table(pid text, label text, brand text, hex text, uses bigint, sample_cover text, sample_id uuid)
language sql stable security definer set search_path to 'public' as $$
  select coalesce(rp.paint_id,'free:'||rp.free_name), coalesce(pt.name,rp.free_name),
    coalesce(pt.brand,'自由入力'), pt.hex, count(distinct rp.recipe_id),
    (array_agg(r.cover_url order by r.view_count desc) filter (where r.cover_url is not null))[1],
    (array_agg(r.id order by r.view_count desc) filter (where r.cover_url is not null))[1]
  from public.recipe_paints rp
  join public.recipes r on r.id = rp.recipe_id and r.is_public = true
       and not internal.owner_is_banned(r.owner_id)
  left join public.paints pt on pt.id = rp.paint_id
  where coalesce(rp.proc_name,'') !~ '(サフ|下地|サーフェ|プライマ|トップ|クリア|スミ)'
  group by 1,2,3,4 order by 5 desc, 2 limit limit_n;
$$;

create or replace function public.rising_paints(limit_n integer default 12)
returns table(pid text, label text, brand text, hex text, recent bigint, total bigint, score numeric)
language sql stable security definer set search_path to 'public' as $$
  with base as (
    select coalesce(rp.paint_id,'free:'||rp.free_name) pid, coalesce(pt.name,rp.free_name) label,
      coalesce(pt.brand,'自由入力') brand, pt.hex hex,
      count(distinct rp.recipe_id) total,
      count(distinct rp.recipe_id) filter (where r.created_at > now() - interval '7 days') recent
    from public.recipe_paints rp
    join public.recipes r on r.id = rp.recipe_id and r.is_public = true
         and not internal.owner_is_banned(r.owner_id)
    left join public.paints pt on pt.id = rp.paint_id
    where coalesce(rp.proc_name,'') !~ '(サフ|下地|サーフェ|プライマ|トップ|クリア|スミ)'
    group by 1,2,3,4 )
  select pid,label,brand,hex,recent,total,
    round((recent::numeric*(recent::numeric/nullif(total,0)))::numeric,3)
  from base where recent>0 order by 7 desc, recent desc limit limit_n;
$$;

create or replace function public.popular_methods(limit_n integer default 12)
returns table(method text, uses bigint)
language sql stable security definer set search_path to 'public' as $$
  select m, count(distinct r.id) from public.recipes r,
    lateral jsonb_array_elements_text(to_jsonb(r.methods)) as m
  where r.is_public = true and not internal.owner_is_banned(r.owner_id)
  group by m order by 2 desc, 1 limit limit_n;
$$;

-- ----------------------------------------------------------------------------
-- 4) 停止中の人の書き込みを止めるトリガー（internal版を使う）
-- ----------------------------------------------------------------------------
create or replace function public.block_if_banned()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and internal.is_banned(auth.uid()) then
    raise exception 'このアカウントは現在ご利用を停止しています。';
  end if;
  return NEW;
end $$;

create or replace function public.block_banned_update()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and internal.is_banned(auth.uid()) then
    raise exception 'このアカウントは現在ご利用を停止しています。';
  end if;
  return NEW;
end $$;

create or replace function public.block_banned_profile_update()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and auth.uid() = NEW.id and internal.is_banned(auth.uid())
     and (NEW.display_name is distinct from OLD.display_name
       or NEW.bio          is distinct from OLD.bio
       or NEW.link         is distinct from OLD.link
       or NEW.x_account    is distinct from OLD.x_account
       or NEW.user_id      is distinct from OLD.user_id
       or NEW.avatar_url   is distinct from OLD.avatar_url
       or NEW.header_url   is distinct from OLD.header_url)
  then
    raise exception 'このアカウントは現在ご利用を停止しています。';
  end if;
  return NEW;
end $$;

-- ----------------------------------------------------------------------------
-- 5) 画像アップロードの制限（停止判定を最優先で行う）
-- ----------------------------------------------------------------------------
-- ★以前は「大きさが増えないなら素通し」の近道が停止判定より手前にあり、
--   停止された人が同じURLのまま画像の中身だけ差し替えられた。
--   停止判定はどんな近道よりも先に行う。
create or replace function public.storage_upload_denied_reason(p_bucket text, p_name text, p_metadata jsonb)
returns text language plpgsql stable security definer
set search_path to 'public','storage' as $$
declare
  uid uuid := auth.uid(); lim_bytes bigint := 209715200; lim_files int := 500;
  assumed bigint; new_bytes bigint; used_bytes bigint; used_files int; size_txt text;
begin
  if uid is null then return null; end if;
  if p_bucket is null or p_bucket not in ('recipes','profile') then return null; end if;
  if internal.is_banned(uid) then
    return 'このアカウントは現在ご利用を停止しています。画像のアップロードはできません。';
  end if;
  select coalesce(max(b.file_size_limit), 10485760) into assumed
    from storage.buckets b where b.id = p_bucket;
  size_txt := p_metadata->>'size';
  new_bytes := case when size_txt ~ '^[0-9]+$' then size_txt::bigint else assumed end;
  select coalesce(sum(case when o.metadata->>'size' ~ '^[0-9]+$' then (o.metadata->>'size')::bigint else 0 end), 0),
         count(*)
    into used_bytes, used_files
    from storage.objects o
   where o.bucket_id in ('recipes','profile')
     and o.name like uid::text || '/%'
     and (storage.foldername(o.name))[1] = uid::text
     and not (o.bucket_id = p_bucket and o.name = p_name);
  if used_files + 1 > lim_files then
    return '保存できる画像の枚数の上限に達しました。不要な投稿や下書きを削除してからお試しください。';
  end if;
  if used_bytes + new_bytes > lim_bytes then
    return '保存できる画像の合計容量の上限に達しました。不要な投稿や下書きを削除してからお試しください。';
  end if;
  return null;
end $$;

create or replace function public.check_storage_upload()
returns trigger language plpgsql security definer
set search_path to 'public','storage' as $$
declare reason text; old_size bigint := 0; new_size bigint := 0; uid uuid := auth.uid();
begin
  -- ★停止判定は必ず最初（近道より前）
  if uid is not null and internal.is_banned(uid) then
    raise exception 'このアカウントは現在ご利用を停止しています。画像のアップロードはできません。';
  end if;
  if TG_OP = 'UPDATE' then
    begin old_size := coalesce((OLD.metadata->>'size')::bigint, 0); exception when others then old_size := 0; end;
    begin new_size := coalesce((NEW.metadata->>'size')::bigint, 0); exception when others then new_size := 0; end;
    if NEW.bucket_id is not distinct from OLD.bucket_id
       and NEW.name is not distinct from OLD.name and new_size <= old_size then return NEW; end if;
  end if;
  reason := public.storage_upload_denied_reason(NEW.bucket_id, NEW.name, NEW.metadata);
  if reason is not null then raise exception '%', reason; end if;
  return NEW;
end $$;

do $$
begin
  begin
    drop trigger if exists trg_check_storage_upload on storage.objects;
    execute 'create trigger trg_check_storage_upload before insert or update on storage.objects'
         || ' for each row execute function public.check_storage_upload()';
  exception when others then
    raise notice '★storage.objects のトリガーを作れませんでした（権限）: %', sqlerrm;
  end;
end $$;

-- ----------------------------------------------------------------------------
-- 6) 利用停止と解除
-- ----------------------------------------------------------------------------
-- ★以前は remember_banned_email を1引数で呼んでおり（実在するのは2引数版）、
--   毎回失敗したうえ例外を握りつぶしていたため、再登録の禁止が一度も記録されていなかった。
--   また解除しても禁止リストが残り、その人は退会後に戻れなくなっていた。
create or replace function public.set_user_ban(target uuid, ban boolean, reason text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare target_email text;
begin
  if not public.is_admin() then raise exception '権限がありません'; end if;
  if target = auth.uid() then raise exception '自分自身は停止できません'; end if;
  if (select is_admin from public.profiles where id = target) then
    raise exception '管理者は停止できません';
  end if;
  perform set_config('app.allow_ban', '1', true);
  update public.profiles
     set banned_at = case when ban then now() else null end,
         banned_reason = case when ban then reason else null end
   where id = target;
  perform set_config('app.allow_ban', '', true);

  if ban then
    perform public.remember_banned_email(target, reason);
  else
    select u.email into target_email from auth.users u where u.id = target;
    if target_email is not null then
      delete from public.banned_emails where lower(email) = lower(target_email);
    end if;
  end if;

  insert into public.notifications(user_id, type, title, body, link)
  values (target, 'system',
          case when ban then 'アカウントのご利用停止' else 'ご利用停止を解除しました' end,
          case when ban then coalesce(nullif(btrim(reason),''),
                 '利用規約に違反する行為が確認されたため、投稿機能のご利用を停止しました。')
               else '投稿機能のご利用を再開いただけます。' end,
          case when ban then 'index.html#feedback' else 'index.html' end);
end $$;

-- ----------------------------------------------------------------------------
-- 7) 通知
-- ----------------------------------------------------------------------------
-- ★notify_self は種別を自由に指定でき、'system' を名乗ればレート制限を回避できた。
create or replace function public.notify_self(_type text, _title text, _body text, _link text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if _type is null or _type not in ('email_changed','password_changed') then
    raise exception 'この種別の通知は作成できません';
  end if;
  insert into public.notifications(user_id, type, title, body, link)
  values (auth.uid(), _type, left(coalesce(_title,''), 100), left(coalesce(_body,''), 500), left(_link, 300));
end $$;
revoke all on function public.notify_self(text,text,text,text) from public, anon;
grant execute on function public.notify_self(text,text,text,text) to authenticated;

-- ★上限に達したとき例外を投げると、コメント投稿など元の操作まで巻き添えで失敗する。
--   通知が届かないだけにして、本体の操作は成功させる。
create or replace function public.check_notify_rate()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if auth.uid() is null then return NEW; end if;
  if public.is_admin() then return NEW; end if;
  select count(*) into n from public.notifications
   where user_id = NEW.user_id and created_at > now() - interval '1 hour';
  if n >= 100 then return null; end if;
  return NEW;
end $$;

-- ★コメントを消しても通知に本文が残らないよう、元コメントのIDを記録する。
--   017で伏せ字の仕組みを入れたのに、記録側が対応しておらず一度も動いていなかった。
create or replace function public.on_comment_inserted()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare ownerid uuid; recv_pref boolean; rtitle text; parent_userid uuid;
begin
  select owner_id, coalesce(title,'無題') into ownerid, rtitle
    from public.recipes where id = NEW.recipe_id;
  if ownerid is not null and ownerid <> NEW.user_id then
    select notify_comments into recv_pref from public.profiles where id = ownerid;
    if coalesce(recv_pref, true) then
      insert into public.notifications(user_id, type, title, body, link, source_comment_id)
      values (ownerid,
              case when NEW.parent_id is null then 'comment' else 'reply' end,
              case when NEW.parent_id is null then '投稿にコメントが届きました' else '投稿に返信が届きました' end,
              '「'||rtitle||'」: '||left(NEW.body, 80),
              'legacy.html?id='||NEW.recipe_id::text||'#view',
              NEW.id);
    end if;
  end if;
  if NEW.parent_id is not null then
    select user_id into parent_userid from public.comments where id = NEW.parent_id;
    if parent_userid is not null and parent_userid <> NEW.user_id
       and (ownerid is null or parent_userid <> ownerid) then
      select notify_comments into recv_pref from public.profiles where id = parent_userid;
      if coalesce(recv_pref, true) then
        insert into public.notifications(user_id, type, title, body, link, source_comment_id)
        values (parent_userid, 'reply', 'あなたのコメントに返信が届きました',
                '「'||rtitle||'」: '||left(NEW.body, 80),
                'legacy.html?id='||NEW.recipe_id::text||'#view', NEW.id);
      end if;
    end if;
  end if;
  return NEW;
end $$;

-- ★通報の確認完了通知が、コメント通報でもレシピ所有者へ届いていた。
create or replace function public.on_report_status_changed()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare notify_to uuid; msg text; lnk text;
begin
  if (OLD.status is distinct from NEW.status) and NEW.status = 'reviewed' then
    if NEW.target_type = 'comment' then
      notify_to := NEW.target_user_id;
      msg := 'あなたのコメントに対する通報が運営により確認されました。';
    else
      notify_to := coalesce(NEW.target_user_id,
                            (select owner_id from public.recipes where id = NEW.recipe_id));
      msg := 'あなたの投稿に対する通報が運営により確認されました。';
    end if;
    lnk := case when NEW.recipe_id is not null
                then 'legacy.html?id='||NEW.recipe_id::text||'#view' else 'index.html' end;
    if notify_to is not null then
      insert into public.notifications(user_id, type, title, body, link)
      values (notify_to, 'report_reviewed', '通報の確認が完了しました', msg, lnk);
    end if;
  end if;
  return NEW;
end $$;

-- ----------------------------------------------------------------------------
-- 8) 通報の集計（退会しても消えないようにする）
-- ----------------------------------------------------------------------------
-- ★以前は profiles と内部結合しており、通報された人が確認前に退会すると
--   通報記録は残っているのに管理画面から消えていた。
create or replace function public.report_summary(limit_n integer default 30)
returns table(owner_id uuid, user_id text, display_name text, report_count bigint,
              recipe_count bigint, last_report timestamptz, distinct_reporters bigint, banned boolean)
language sql stable security definer set search_path to 'public' as $$
  select rp.target_user_id as owner_id,
         coalesce(p.user_id, '(退会済み)') as user_id,
         coalesce(p.display_name, '(退会済みの利用者)') as display_name,
         count(*) as report_count,
         count(distinct rp.recipe_id) as recipe_count,
         max(rp.created_at) as last_report,
         count(distinct rp.reporter_id) as distinct_reporters,
         (p.banned_at is not null) as banned
  from public.reports rp
  left join public.profiles p on p.id = rp.target_user_id
  where public.is_admin() and rp.target_user_id is not null
  group by rp.target_user_id, p.user_id, p.display_name, p.banned_at
  order by count(distinct rp.reporter_id) desc, count(*) desc, max(rp.created_at) desc
  limit greatest(1, least(coalesce(limit_n,30), 100));
$$;

-- ----------------------------------------------------------------------------
-- 9) プロフィールの列権限（★ここが一番間違えやすい）
-- ----------------------------------------------------------------------------
-- ★Postgresは「テーブル全体のSELECT権限」がある限り、列単位のrevokeを無視する。
--   022では列単位でしか外しておらず、実際には何も剥奪できていなかった。
--   必ず「テーブル権限を外してから、公開してよい列だけを付け直す」順序で書くこと。
--   これを間違えると、ログインした人が他人の
--   is_admin（誰が運営か）/ banned_at（誰が停止中か）/ has_password を一覧できてしまう。
revoke select on public.profiles from anon;
revoke select on public.profiles from authenticated;
grant select (id, handle, user_id, display_name, bio, link,
              avatar_url, header_url, x_account, created_at)
  on public.profiles to anon;
grant select (id, handle, user_id, display_name, bio, link,
              avatar_url, header_url, x_account, created_at)
  on public.profiles to authenticated;

-- 自分の分（内部列を含む）は、この関数からだけ読む
create or replace function public.my_profile()
returns table (id uuid, user_id text, display_name text, avatar_url text, header_url text,
  bio text, link text, x_account text, has_password boolean, notify_comments boolean,
  terms_agreed_at timestamptz, is_admin boolean, banned_at timestamptz, created_at timestamptz)
language sql security definer set search_path to 'public','auth' as $$
  select p.id, p.user_id, p.display_name, p.avatar_url, p.header_url, p.bio, p.link,
         p.x_account, p.has_password, p.notify_comments, p.terms_agreed_at,
         p.is_admin, p.banned_at, p.created_at
    from public.profiles p where p.id = auth.uid() limit 1;
$$;
revoke all on function public.my_profile() from public, anon;
grant execute on function public.my_profile() to authenticated;

-- 管理者だけが他人の停止状態を取得できる入口（通報画面用）
create or replace function public.admin_user_states(ids uuid[])
returns table (id uuid, user_id text, display_name text, banned_at timestamptz)
language plpgsql security definer set search_path to 'public','auth' as $$
begin
  if not public.is_admin() then raise exception '権限がありません'; end if;
  return query
    select p.id, p.user_id, p.display_name, p.banned_at
      from public.profiles p
     where p.id = any(coalesce(ids, '{}'::uuid[])) limit 500;
end $$;
revoke all on function public.admin_user_states(uuid[]) from public, anon;
grant execute on function public.admin_user_states(uuid[]) to authenticated;

-- ----------------------------------------------------------------------------
-- 10) 最後に、意図どおりになったか自己点検する
-- ----------------------------------------------------------------------------
-- ★「流したのに効いていない」を防ぐ。1つでも外れていればエラーで止める。
do $$
declare ng text := '';
begin
  if has_table_privilege('authenticated','public.profiles','SELECT')
     then ng := ng || 'profilesのテーブル権限が残っている / '; end if;
  if has_column_privilege('authenticated','public.profiles','banned_at','SELECT')
     then ng := ng || '他人のbanned_atが読める / '; end if;
  if not has_column_privilege('authenticated','public.profiles','display_name','SELECT')
     then ng := ng || '表示名が読めない(壊れている) / '; end if;
  if to_regprocedure('public.owner_is_banned(uuid)') is not null
     then ng := ng || 'public.owner_is_banned が残っている / '; end if;
  if to_regprocedure('public.is_banned(uuid)') is not null
     then ng := ng || 'public.is_banned(uuid) が残っている / '; end if;
  if to_regprocedure('internal.is_banned(uuid)') is null
     then ng := ng || 'internal.is_banned が無い / '; end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='popular_paints'
         and pg_get_functiondef(p.oid) like '%owner_is_banned%') = 0
     then ng := ng || 'ランキングに停止判定が無い / '; end if;
  if ng <> '' then
    raise exception '033の適用結果が想定と違います: %', ng;
  end if;
  raise notice '033: 自己点検OK';
end $$;
