-- =====================================================================
-- tests/db/00_harness.sql — データベーステストの土台
--
--   ★開発用DB(dev)にだけ入れること。本番には絶対に入れない。
--
--   仕組み: tests.run_all() を呼ぶと全テストが順に走り、
--           「区分 / テスト名 / 合否 / 詳細」の表が返る。
--
--   なぜDBの中でテストするのか:
--     このサイトの安全性の要は RLS（行レベル権限＝誰がどの行を読み書きできるか）。
--     RLSは「その人としてログインした状態」でしか検証できないため、DB内で
--     利用者になりすまして（request.jwt.claims を差し替えて）確認する。
--
--   設計上の注意（Postgresの制約）:
--     ・SECURITY DEFINER 関数の中では `set role` が禁止されている。
--       → なりすまし系(as_user等)は通常関数にする。
--     ・逆に、結果の記録や利用者の作成には特権が要る。
--       → そこだけ SECURITY DEFINER に分ける。
--     ・許可/拒否を確かめる関数は「なりすました本人として」SQLを走らせる必要があるため
--       通常関数にする（DEFINERにすると権限が上がってしまい検証にならない）。
-- =====================================================================

create schema if not exists tests;

create table if not exists tests.result(
  seq    serial primary key,
  area   text,
  name   text,
  ok     boolean,
  detail text
);

-- ---- 結果の記録（特権が要るのでDEFINER。役割の切替はしない） ----
create or replace function tests.record(p_area text, p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql security definer set search_path=tests as $$
begin
  insert into tests.result(area,name,ok,detail)
  values (p_area, p_name, coalesce(p_ok,false), case when coalesce(p_ok,false) then null else p_detail end);
end $$;

-- ---- なりすまし（通常関数。DEFINERにすると set role が禁止される） ----
create or replace function tests.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function tests.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
end $$;

create or replace function tests.as_owner() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims','',true);
end $$;

-- ---- 判定ヘルパー ----
create or replace function tests.ok(p_area text, p_name text, p_cond boolean, p_detail text default null)
returns void language plpgsql as $$
begin
  perform tests.record(p_area,p_name,coalesce(p_cond,false), coalesce(p_detail,'条件を満たしませんでした'));
end $$;

create or replace function tests.eq(p_area text, p_name text, p_actual anyelement, p_expected anyelement)
returns void language plpgsql as $$
begin
  perform tests.record(p_area,p_name, p_actual is not distinct from p_expected,
    '期待値=' || coalesce(p_expected::text,'null') || ' / 実際=' || coalesce(p_actual::text,'null'));
end $$;

-- 「拒否されるべき操作」が本当に拒否されるか（なりすました本人として実行する）
create or replace function tests.denied(p_area text, p_name text, p_sql text, p_expect text default null)
returns void language plpgsql as $$
declare msg text;
begin
  begin
    execute p_sql;
    perform tests.record(p_area,p_name,false,'拒否されるべき操作が成功してしまいました');
    return;
  exception when others then
    msg := SQLERRM;
  end;
  perform tests.record(p_area,p_name,
    (p_expect is null or msg like '%'||p_expect||'%'),
    '想定と違うエラー: ' || left(msg,140));
end $$;

-- 「許可されるべき操作」が通るか
create or replace function tests.allowed(p_area text, p_name text, p_sql text)
returns void language plpgsql as $$
declare msg text;
begin
  begin
    execute p_sql;
    perform tests.record(p_area,p_name,true,null);
    return;
  exception when others then
    msg := SQLERRM;
  end;
  perform tests.record(p_area,p_name,false,'許可されるべき操作が失敗: ' || left(msg,140));
end $$;

-- 更新/削除が「0件しか効かない」ことの確認（RLSで弾かれるとエラーではなく0件になるため）
create or replace function tests.affects(p_area text, p_name text, p_sql text, p_expected int)
returns void language plpgsql as $$
declare n int; msg text;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    msg := SQLERRM;
    perform tests.record(p_area,p_name,false,'実行時エラー: ' || left(msg,140));
    return;
  end;
  perform tests.record(p_area,p_name, n = p_expected,
    '影響行数 期待=' || p_expected || ' / 実際=' || n);
end $$;

-- ---- テスト用の利用者（特権が要るのでDEFINER） ----
create or replace function tests.make_user(p_admin boolean default false)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare u uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'test_'||replace(u::text,'-','')||'@example.test','x',now(),now(),now());
  insert into public.profiles(id) values (u) on conflict (id) do nothing;
  if p_admin then update public.profiles set is_admin = true where id = u; end if;
  return u;
end $$;

create or replace function tests.cleanup_users(p_users uuid[])
returns void language plpgsql security definer set search_path=public,auth,storage as $$
begin
  perform set_config('storage.allow_delete_query','true',true);
  delete from storage.objects where (storage.foldername(name))[1] = any(select unnest(p_users)::text);
  delete from auth.users where id = any(p_users);
end $$;

-- Storageにテスト用ファイルを置く（DEFINER）
create or replace function tests.put_object(p_bucket text, p_name text, p_owner uuid, p_age interval default '2 hours')
returns void language plpgsql security definer set search_path=storage,public as $$
begin
  insert into storage.objects(bucket_id,name,owner,created_at)
  values (p_bucket,p_name,p_owner, now() - p_age)
  on conflict do nothing;
end $$;
