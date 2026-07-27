-- =====================================================================
-- 019_upload_guard.sql
--   Codex指摘 #7 / #8 の対策（どちらも「無料枠を他人に食い潰される」穴）
--
--   #7 Storageは「ログインさえしていれば」無制限に置けた
--      書き込みポリシーは bucket と owner（＋自分のフォルダ）しか見ておらず、
--      ・停止中(BAN)の利用者でもアップロードだけは通る
--      ・1人あたりの合計容量・件数の上限が無い
--      ため、10MiB(=1ファイル上限)の画像を103回送るだけで無料枠1GBに到達できた。
--      投稿には20秒間隔・1日30件の制限(012)があるが、アップロードは投稿と別経路なので
--      その制限を素通りしてしまう。
--
--   #8 events は匿名から無制限にINSERTできた
--      events_insert は with check (true)。1件あたりは小さくても、
--      連続で送られればDBの無料枠(500MB)を埋められる。
--      001の「90日で削除」は事後の掃除であって、その場の流量は止められない。
--
--   ※ Supabase の SQL Editor で実行してください（018の後）。冪等。
-- =====================================================================


-- =====================================================================
-- (1)【#7】Storageのアップロードに「停止中の拒否」と「1人あたりの上限」を付ける
-- =====================================================================

-- ---------------------------------------------------------------------
-- 判定本体。拒否理由の文言を返し、問題なければ null を返す。
--   ★トリガからもRLSポリシーからも同じ判定を使えるよう、あえて関数に切り出している
--     （storage.objects にトリガを作れない環境でもポリシー側で同じ制限をかけられるように）。
--
--   ★引数に owner を取らず、必ず auth.uid()（＝ログイン中の本人）で判定する理由:
--     他人のUUIDを渡して「あの人は停止中か／容量を使い切っているか」を探れないようにするため。
--
--   ★サイズが分からないときの扱い（安全側）:
--     Supabaseの版によっては、アップロード完了前の行は metadata が空のことがある。
--     ・これから入る1件 → 分からなければ「バケットの1ファイル上限(016で10MB)」とみなす（＝多めに見積もる）
--     ・既にある行     → 分からなければ 0 とみなす
--     既存行まで多めに見積もると、万一 metadata が常に空の版だった場合に
--     「20枚で上限」になって正規利用者がアップロードできなくなる。
--     その場合でも件数上限(500件)は必ず効くので、青天井にはならない。
-- ---------------------------------------------------------------------
create or replace function public.storage_upload_denied_reason(
  p_bucket text, p_name text, p_metadata jsonb
) returns text
language plpgsql stable security definer set search_path to 'public','storage' as $$
declare
  uid         uuid   := auth.uid();
  lim_bytes   bigint := 209715200;   -- 1人あたり合計 200MB まで
  lim_files   int    := 500;         -- 1人あたり 500ファイルまで
  assumed     bigint;                -- サイズ不明のときの想定値（＝バケットの1ファイル上限）
  new_bytes   bigint;
  used_bytes  bigint;
  used_files  int;
  size_txt    text;
begin
  -- 管理・移行・退会処理など、ログイン利用者以外の直接操作は対象外（012 check_recipe_rate と同じ方針）
  if uid is null then return null; end if;
  -- 自サイトが使う2つのバケット以外には関与しない
  if p_bucket is null or p_bucket not in ('recipes','profile') then return null; end if;

  -- 停止中(BAN)の利用者は新規アップロード不可。
  -- 014は recipes/drafts/comments/reports の INSERT しか止めていなかったため、
  -- 「投稿はできないが画像だけは置ける」＝容量攻撃の抜け道になっていた。
  if public.is_banned(uid) then
    return 'このアカウントは現在ご利用を停止しています。画像のアップロードはできません。';
  end if;

  select coalesce(max(b.file_size_limit), 10485760) into assumed
    from storage.buckets b where b.id = p_bucket;

  -- 数字以外が入っていても落ちないようにしてから数値化する（例外でアップロードを壊さない）
  size_txt := p_metadata->>'size';
  new_bytes := case when size_txt ~ '^[0-9]+$' then size_txt::bigint else assumed end;

  -- 自分のフォルダ配下の使用量。name の前方一致も付けているのは索引(bucket_id, name)を効かせるため。
  -- （foldername() だけだと毎回の全走査になり、アップロードのたびに重くなる）
  select coalesce(sum(
           case when o.metadata->>'size' ~ '^[0-9]+$' then (o.metadata->>'size')::bigint else 0 end
         ), 0),
         count(*)
    into used_bytes, used_files
    from storage.objects o
   where o.bucket_id in ('recipes','profile')
     and o.name like uid::text || '/%'
     and (storage.foldername(o.name))[1] = uid::text
     -- 上書き保存(upsert)のときに、同じパスの旧ファイルを二重に数えない
     and not (o.bucket_id = p_bucket and o.name = p_name);

  if used_files + 1 > lim_files then
    return '保存できる画像の枚数の上限に達しました。不要な投稿や下書きを削除してからお試しください。';
  end if;
  if used_bytes + new_bytes > lim_bytes then
    return '保存できる画像の合計容量の上限に達しました。不要な投稿や下書きを削除してからお試しください。';
  end if;
  return null;
end $$;
-- 匿名にも実行権を与えるのは、後述のRLSポリシー経路になった場合に
-- 「関数の権限エラー」ではなく従来どおりの権限エラーで弾かれるようにするため（中身は uid=null で即 null を返す）。
grant execute on function public.storage_upload_denied_reason(text, text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- トリガ本体。理由が返ってきたら日本語のメッセージで拒否する。
-- ---------------------------------------------------------------------
create or replace function public.check_storage_upload()
returns trigger language plpgsql security definer set search_path to 'public','storage' as $$
declare reason text;
begin
  reason := public.storage_upload_denied_reason(NEW.bucket_id, NEW.name, NEW.metadata);
  if reason is not null then raise exception '%', reason; end if;
  return NEW;
end $$;

-- ---------------------------------------------------------------------
-- storage.objects は supabase_storage_admin の持ち物なので、
-- 環境によってはトリガを作る権限が無いことがある。
--   ・作れた場合  → トリガで判定（日本語の理由をそのまま利用者に返せるので、こちらを優先）
--   ・作れない場合 → RLSの制限ポリシー(restrictive)で同じ判定をかける（理由は出ないが確実に止まる）
-- どちらに転んでも実行が止まらないよう、例外を握って NOTICE を出す。
-- ---------------------------------------------------------------------
do $$
begin
  execute 'drop trigger if exists trg_check_storage_upload on storage.objects';
  execute 'create trigger trg_check_storage_upload before insert on storage.objects'
       || ' for each row execute function public.check_storage_upload()';
  raise notice '019: storage.objects にトリガを作成しました（トリガ方式で制限します）';
exception when others then
  raise notice '019: storage.objects にトリガを作れませんでした（%）。RLSポリシー方式に切り替えます。', sqlerrm;
end $$;

do $$
declare has_trigger boolean;
begin
  select exists (
    select 1 from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'storage' and c.relname = 'objects'
       and t.tgname = 'trg_check_storage_upload' and not t.tgisinternal
  ) into has_trigger;

  if has_trigger then
    -- トリガが効いているので、ポリシー方式は使わない（二重判定にすると同じ検索が2回走って無駄）
    begin
      execute 'drop policy if exists objects_insert_guard on storage.objects';
    exception when others then null;
    end;
  else
    -- 制限(restrictive)ポリシーにするのは、既存の recipes_img_write / profile_write が
    -- 許可(permissive)ポリシーで、許可同士は OR で足し算されるため。
    -- restrictive は AND で掛かるので「既存の条件 かつ 上限内」にできる。
    -- INSERT だけに掛けるのは、DELETE にも掛けると
    -- 「上限に達した人が、消して減らすこともできない」状態になってしまうため。
    begin
      execute 'drop policy if exists objects_insert_guard on storage.objects';
      execute 'create policy objects_insert_guard on storage.objects'
           || ' as restrictive for insert to authenticated'
           || ' with check (public.storage_upload_denied_reason(bucket_id, name, metadata) is null)';
      raise notice '019: storage.objects に制限ポリシーを作成しました（ポリシー方式で制限します）';
    exception when others then
      raise notice '019: ★storage.objects に制限をかけられませんでした（%）。Supabaseサポート経由での設定が必要です。', sqlerrm;
    end;
  end if;
end $$;


-- =====================================================================
-- (2)【#8】events の流量制限（1時間あたりの上限）
-- =====================================================================

-- ---------------------------------------------------------------------
-- 数え札。毎回 count(*) で数えると、たまったeventsを毎回走査することになり
-- 「計測のためにDBが重くなる」ので、007の view_throttle と同じ「1行を足していく」方式にする。
--   bucket: 's:'||session_id（利用者ごと） / '*'（全体）
--   ポリシーを作らない＝クライアントからは読み書きできない（トリガはsecurity definerで動く）
-- ---------------------------------------------------------------------
create table if not exists public.event_throttle (
  bucket text        not null,
  hour   timestamptz not null,
  cnt    int         not null default 0,
  primary key (bucket, hour)
);
alter table public.event_throttle enable row level security;   -- ポリシー無し＝クライアントからは触れない
revoke all on public.event_throttle from anon, authenticated;

-- ---------------------------------------------------------------------
-- 超過時に例外ではなく RETURN NULL（静かに捨てる）にしている理由:
--   events は fire-and-forget の計測用で、失敗させると
--   「画面の操作そのものがエラーになる」おそれがある。
--   計測が欠けるのは困らないが、本体機能が止まるのは困る。
--
-- 全体上限も置く理由:
--   session_id はクライアントが自由に決められる値なので、毎回変えれば
--   「1セッション300件」の制限は簡単に迂回できる。最後の砦として全体量にも蓋をする。
--   1時間10000件＝おおよそ毎秒3件。個人サイトの通常の利用では到達しない。
-- ---------------------------------------------------------------------
create or replace function public.check_event_rate()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  h   timestamptz := date_trunc('hour', now());
  sid text;
  c   int;
begin
  sid := left(btrim(coalesce(NEW.session_id, '')), 64);

  -- 利用者（セッション）ごと: 1時間300件まで
  if sid <> '' then
    insert into public.event_throttle(bucket, hour, cnt) values ('s:' || sid, h, 1)
      on conflict (bucket, hour) do update set cnt = public.event_throttle.cnt + 1
      returning cnt into c;
    if c > 300 then return null; end if;
  end if;

  -- 全体: 1時間10000件まで（session_idが無い分もここで頭打ちになる）
  insert into public.event_throttle(bucket, hour, cnt) values ('*', h, 1)
    on conflict (bucket, hour) do update set cnt = public.event_throttle.cnt + 1
    returning cnt into c;
  if c > 10000 then return null; end if;

  return NEW;
end $$;

drop trigger if exists trg_check_event_rate on public.events;
create trigger trg_check_event_rate before insert on public.events
  for each row execute function public.check_event_rate();

-- ---------------------------------------------------------------------
-- 数え札そのものが溜まらないよう、既存の定期掃除に1行足す
-- （017の内容をそのまま引き継ぎ、event_throttle の掃除だけ追加）
-- ---------------------------------------------------------------------
create or replace function public.purge_old_events()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.events         where occurred_at < now() - interval '90 days';
  delete from public.view_throttle  where minute      < now() - interval '1 day';
  delete from public.event_throttle where hour        < now() - interval '1 day';
  -- 対応が終わっているものだけを、2年経過後に削除する（対応中は残す）
  delete from public.reports   where created_at < now() - interval '2 years' and status <> 'open';
  delete from public.inquiries where created_at < now() - interval '2 years' and status <> 'open';
end $$;
revoke all on function public.purge_old_events() from public, anon, authenticated;
