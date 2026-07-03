-- 003_comment_ngword.sql
-- コメントのNG語フィルタを2点修正する。
--
-- ① before insert or update → before insert のみ。
--    編集時にもNG語チェックが再実行されると、（部分一致で巻き込まれた）既存コメントが
--    永久に編集不能になる不具合が起きる。投稿時だけチェックすれば十分。
--
-- ② 部分一致リストの最小化。
--    `ilike '%カス%'` の部分一致は「カス」→「カスタム」（模型で頻出）等の正当語を誤ブロックする。
--    ゴミ/クズ/ブス等も同様。語句フィルタは誤爆が多く回避も容易なため、
--    荒らし対策の本命は「通報＋管理者モデレーション」に委ね、フィルタは
--    死・暴力の直接的な語のみの最小の第一防波堤に留める。
--    （必要ならこの配列を空 array[]::text[] にしてフィルタ自体を無効化してもよい）

create or replace function public.check_comment_ngword()
returns trigger language plpgsql as $$
declare ng text;
begin
  for ng in select unnest(array[
    '死ね','殺す','消えろ'
  ]) loop
    if NEW.body ilike '%' || ng || '%' then
      raise exception 'このコメントには使用できない語句が含まれています。';
    end if;
  end loop;
  return NEW;
end; $$;

drop trigger if exists trg_check_comment_ngword on public.comments;
create trigger trg_check_comment_ngword before insert on public.comments
  for each row execute function public.check_comment_ngword();
