-- =====================================================================
-- 004_review_fixes.sql
--   Codex×Claude 相互レビューで確認された DB 側の指摘のうち、
--   小工数で潰せる4件をまとめて修正する。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（既存001-003の後）。
--   すべて冪等（create or replace / revoke / drop ... if exists）。
-- =====================================================================

-- ---------------------------------------------------------------------
-- #6 通報/問い合わせの連投制限が効いていない（RLSでmaxが常にNULL）
--   check_report_rate / check_inquiry_rate は既定の SECURITY INVOKER のため、
--   関数内の max(created_at) が呼び出しユーザー権限で走り、reports/inquiries の
--   SELECT が管理者限定（using(is_admin())）→ 非管理者は0件しか見えず last_at=NULL
--   → 30秒/60秒の制限が完全に無効だった。
--   SECURITY DEFINER にして所有者権限で履歴を読み、制限を実際に効かせる。
--   併せて同一ユーザーの同時INSERT競合を advisory lock で締める。
-- ---------------------------------------------------------------------
create or replace function public.check_report_rate()
returns trigger language plpgsql security definer set search_path = public as $$
declare last_at timestamptz;
begin
  if NEW.reporter_id is null then return NEW; end if;
  perform pg_advisory_xact_lock(hashtextextended(NEW.reporter_id::text, 0));
  select max(created_at) into last_at from public.reports where reporter_id = NEW.reporter_id;
  if last_at is not null and now() - last_at < interval '30 seconds' then
    raise exception '通報が連続しています。少し時間をおいてからお試しください。';
  end if;
  return NEW;
end; $$;

create or replace function public.check_inquiry_rate()
returns trigger language plpgsql security definer set search_path = public as $$
declare last_at timestamptz;
begin
  if NEW.user_id is null then return NEW; end if;
  perform pg_advisory_xact_lock(hashtextextended(NEW.user_id::text, 0));
  select max(created_at) into last_at from public.inquiries where user_id = NEW.user_id;
  if last_at is not null and now() - last_at < interval '60 seconds' then
    raise exception 'お問い合わせが連続しています。1分ほどおいてからお試しください。';
  end if;
  return NEW;
end; $$;

-- ---------------------------------------------------------------------
-- #21 退会済み利用者の問い合わせを「対応済み」にできない（NOT NULL違反でrollback）
--   inquiries.user_id は退会で SET NULL になるが、on_inquiry_status_changed が
--   無条件で NOT NULL の notifications.user_id へ INSERT していた。
--   通報側(on_report_status_changed)と同様に NULL ガードを追加する。
-- ---------------------------------------------------------------------
create or replace function public.on_inquiry_status_changed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (OLD.status is distinct from NEW.status) and NEW.status = 'reviewed'
     and NEW.user_id is not null then
    insert into public.notifications(user_id, type, title, body, link)
    values (NEW.user_id, 'inquiry_replied', 'お問い合わせの対応が完了',
            '運営があなたのお問い合わせを確認しました。',
            'index.html#settings');
  end if;
  return NEW;
end; $$;

-- ---------------------------------------------------------------------
-- #7 内部用 SECURITY DEFINER 関数が匿名RPCとして叩ける（EXECUTE未revoke）
--   purge_old_events() と sync_recipe_paints(uuid) は既定で PUBLIC 実行可のため、
--   匿名が /rest/v1/rpc/... 経由で events の削除や派生表の反復更新(DoS)を起こせた。
--   内部利用（trigger/cron/バックフィル）は所有者権限で動くため revoke しても無影響。
-- ---------------------------------------------------------------------
revoke all on function public.purge_old_events()          from public, anon, authenticated;
revoke all on function public.sync_recipe_paints(uuid)    from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- #22 派生表 recipe_paints をユーザーが直接改ざんできる
--   recipe_paints は grid から trigger(sync_recipe_paints=definer)が生成する派生表。
--   なのに rp_insert/rp_update/rp_delete で所有者の直接書き込みを許可しており、
--   grid に無い塗料を公開投稿へ紐付けて人気/急上昇集計を操作できた。
--   クライアントは select しか使わない（作例表示のみ）ので、書き込み権限を剥奪し、
--   書き込みは definer trigger だけに限定する。SELECT(rp_select)は維持。
-- ---------------------------------------------------------------------
drop policy if exists rp_insert on public.recipe_paints;
drop policy if exists rp_update on public.recipe_paints;
drop policy if exists rp_delete on public.recipe_paints;
revoke insert, update, delete on public.recipe_paints from anon, authenticated;
