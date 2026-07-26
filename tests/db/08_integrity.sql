-- データ整合 のテスト（自動生成・dev専用）
do $$
declare
  a          text := 'データ整合';
  t0         timestamptz := now();
  users      uuid[] := '{}'::uuid[];
  author     uuid; pub uuid;
  u_rec      uuid; r_rec uuid;
  u_grid     uuid; r_grid uuid;
  u_draft    uuid; d_id uuid;
  u_g        uuid; rid uuid;
  u_cmt      uuid; u_cmt2 uuid; cid bigint;
  u_rep      uuid; u_inq uuid; u_clip uuid; u_notif uuid; nid bigint;
  u_ev       uuid; u_vic uuid;
  u_rp       uuid; r_rp uuid;
  big        text; props text; sess64 text;
  n          int; v_sort int; v_uid uuid; v_ts timestamptz; v_ts2 timestamptz;
  v_txt      text; v_txt2 text; v_pid text;
begin
  perform tests.as_owner();

  big    := (select string_agg(md5(g::text), '') from generate_series(1,20000) g);
  props  := (select string_agg(md5(g::text), '') from generate_series(1,100) g);
  sess64 := 'tstsess_' || repeat('b', 56);

  author  := tests.make_user();
  u_rec   := tests.make_user();
  u_grid  := tests.make_user();
  u_draft := tests.make_user();
  u_g     := tests.make_user();
  u_cmt   := tests.make_user();
  u_cmt2  := tests.make_user();
  u_rep   := tests.make_user();
  u_inq   := tests.make_user();
  u_clip  := tests.make_user();
  u_notif := tests.make_user();
  u_ev    := tests.make_user();
  u_vic   := tests.make_user();
  u_rp    := tests.make_user();
  users := array[author,u_rec,u_grid,u_draft,u_g,u_cmt,u_cmt2,u_rep,u_inq,u_clip,u_notif,u_ev,u_vic,u_rp];

  pub := gen_random_uuid();
  insert into public.recipes(id, owner_id, title, grid, is_public, created_at) values (pub, author, 'テスト用の公開レシピ', '{"procs":[],"rows":[]}'::jsonb, true, now() - interval '1 hour');

  r_rec := gen_random_uuid();
  perform tests.as_user(u_rec);
  perform tests.allowed(a, 'recipes: created_atに未来日時を指定したINSERT自体はエラーにならない',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,%L)',
           r_rec, u_rec, '未来日時の偽装テスト', '{"procs":[],"rows":[]}', now() + interval '30 days'));
  perform tests.as_owner();
  select created_at into v_ts from public.recipes where id = r_rec;
  perform tests.ok(a, 'recipes: 未来のcreated_atはサーバー時刻に上書きされる（新着枠の永久占拠を防ぐ）',
    v_ts is not null and v_ts < now() + interval '1 minute',
    '保存されたcreated_at=' || coalesce(v_ts::text,'行が作られなかった'));
  perform tests.ok(a, 'recipes: 上書き後のcreated_atが極端な過去にもなっていない',
    v_ts is not null and v_ts > now() - interval '5 minutes',
    '保存されたcreated_at=' || coalesce(v_ts::text,'null'));

  perform tests.as_user(u_rec);
  perform tests.affects(a, 'recipes: 自分の投稿のcreated_atをUPDATEする操作は行としては通る（拒否ではなく無効化）',
    format('update public.recipes set created_at = %L where id = %L', now() - interval '400 days', r_rec), 1);
  perform tests.as_owner();
  select created_at into v_ts2 from public.recipes where id = r_rec;
  perform tests.eq(a, 'recipes: UPDATEでcreated_atを過去に書き換えても元の値が保たれる', v_ts2, v_ts);

  perform tests.as_user(u_cmt);
  perform tests.allowed(a, 'comments: created_atに未来日時を指定してもコメント投稿自体は通る',
    format('insert into public.comments(recipe_id,user_id,body,created_at) values (%L,%L,%L,%L)',
           pub, u_cmt, 'created_at偽装テストのコメント', now() + interval '10 days'));
  perform tests.as_owner();
  select id, created_at into cid, v_ts from public.comments where user_id = u_cmt order by id desc limit 1;
  perform tests.ok(a, 'comments: 未来のcreated_atはサーバー時刻に上書きされる（30秒の連投制限を守るため）',
    v_ts is not null and v_ts < now() + interval '1 minute' and v_ts > now() - interval '5 minutes',
    '保存されたcreated_at=' || coalesce(v_ts::text,'行が作られなかった'));

  perform tests.as_user(u_cmt);
  perform tests.denied(a, 'comments: 投稿済みコメントのcreated_atはUPDATEで変更できない',
    format('update public.comments set created_at = %L where id = %s',
           now() - interval '5 days', coalesce(cid::text,'-1')), '変更できません');

  perform tests.as_user(u_rep);
  perform tests.allowed(a, 'reports: created_atに未来日時を指定しても通報自体は通る',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail,created_at) values (%L,%L,%L,%L,%L)',
           pub, u_rep, 'spam', 'created_at偽装テスト', now() + interval '10 days'));
  perform tests.as_owner();
  select created_at into v_ts from public.reports where reporter_id = u_rep order by id desc limit 1;
  perform tests.ok(a, 'reports: 未来のcreated_atはサーバー時刻に上書きされる（30秒の通報制限を守るため）',
    v_ts is not null and v_ts < now() + interval '1 minute' and v_ts > now() - interval '5 minutes',
    '保存されたcreated_at=' || coalesce(v_ts::text,'行が作られなかった'));

  perform tests.as_user(u_inq);
  perform tests.allowed(a, 'inquiries: created_atに未来日時を指定しても問い合わせ自体は通る',
    format('insert into public.inquiries(user_id,category,body,created_at) values (%L,%L,%L,%L)',
           u_inq, 'other', 'created_at偽装テストの問い合わせ', now() + interval '10 days'));
  perform tests.as_owner();
  select created_at into v_ts from public.inquiries where user_id = u_inq order by id desc limit 1;
  perform tests.ok(a, 'inquiries: 未来のcreated_atはサーバー時刻に上書きされる（60秒の連投制限を守るため）',
    v_ts is not null and v_ts < now() + interval '1 minute' and v_ts > now() - interval '5 minutes',
    '保存されたcreated_at=' || coalesce(v_ts::text,'行が作られなかった'));

  perform tests.as_user(u_clip);
  perform tests.allowed(a, 'clips: created_atに未来日時を指定しても保存(クリップ)自体は通る',
    format('insert into public.clips(user_id,recipe_id,created_at) values (%L,%L,%L)',
           u_clip, pub, now() + interval '10 days'));
  perform tests.as_owner();
  select created_at into v_ts from public.clips where user_id = u_clip and recipe_id = pub;
  perform tests.ok(a, 'clips: 未来のcreated_atはサーバー時刻に上書きされる',
    v_ts is not null and v_ts < now() + interval '1 minute' and v_ts > now() - interval '5 minutes',
    '保存されたcreated_at=' || coalesce(v_ts::text,'行が作られなかった'));

  insert into public.notifications(user_id, type, title, body)
  values (u_notif, 'system', 'テスト通知', 'created_at偽装テスト') returning id, created_at into nid, v_ts;
  perform tests.as_user(u_notif);
  perform tests.affects(a, 'notifications: 自分宛て通知のcreated_atをUPDATEする操作は行としては通る',
    format('update public.notifications set created_at = %L where id = %s', now() - interval '90 days', nid), 1);
  perform tests.as_owner();
  select created_at into v_ts2 from public.notifications where id = nid;
  perform tests.eq(a, 'notifications: created_atを過去に書き換えても元の値が保たれる', v_ts2, v_ts);

  perform tests.as_user(u_grid);
  perform tests.denied(a, 'recipes: 256KBを超えるgridはINSERTできない（DB容量の枯渇防止）',
    format('insert into public.recipes(owner_id,title,grid,is_public,created_at) values (%L,%L,jsonb_build_object(%L,%L),true,now() - interval ''1 hour'')',
           u_grid, '巨大grid', 'x', big), 'recipes_grid_size');

  r_grid := gen_random_uuid();
  perform tests.allowed(a, 'recipes: 通常サイズのgridは問題なくINSERTできる（上限が正規利用を邪魔しない）',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           r_grid, u_grid, '通常サイズgrid', '{"procs":[{"id":"q1","name":"基本色"}],"rows":[]}'));
  perform tests.denied(a, 'recipes: 既存投稿のgridを256KB超にUPDATEすることもできない',
    format('update public.recipes set grid = jsonb_build_object(%L,%L) where id = %L', 'x', big, r_grid),
    'recipes_grid_size');

  perform tests.as_user(u_draft);
  perform tests.denied(a, 'drafts: 256KBを超えるgridの下書きはINSERTできない（下書き経由の容量攻撃を封じる）',
    format('insert into public.drafts(owner_id,title,grid) values (%L,%L,jsonb_build_object(%L,%L))',
           u_draft, '巨大下書き', 'x', big), 'drafts_grid_size');
  d_id := gen_random_uuid();
  perform tests.allowed(a, 'drafts: 通常サイズの下書きは問題なく保存できる',
    format('insert into public.drafts(id,owner_id,title,grid) values (%L,%L,%L,%L::jsonb)',
           d_id, u_draft, '通常サイズ下書き', '{"rows":[]}'));
  perform tests.denied(a, 'drafts: 既存下書きのgridを256KB超にUPDATEすることもできない',
    format('update public.drafts set grid = jsonb_build_object(%L,%L) where id = %L', 'x', big, d_id),
    'drafts_grid_size');
  perform tests.as_owner();

  perform tests.allowed(a, 'grid: procs が配列でなくオブジェクト{}でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '壊れたgrid procs', '{"procs":{},"rows":[]}'));

  perform tests.allowed(a, 'grid: rows が配列でなく文字列でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '壊れたgrid rows', '{"procs":[],"rows":"こわれています"}'));

  perform tests.allowed(a, 'grid: cells がオブジェクトでなく配列でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '壊れたgrid cells',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":[1,2]}]}'));

  perform tests.allowed(a, 'grid: セルの中身が文字列（オブジェクトでない）でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '壊れたgrid cellvalue',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":"あ"}}]}'));

  perform tests.allowed(a, 'grid: 最上位が配列[]でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '壊れたgrid 配列', '[]'));

  perform tests.allowed(a, 'grid: 最上位がただの文字列でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '壊れたgrid 文字列', '"こわれています"'));

  perform tests.allowed(a, 'grid: procs の要素がオブジェクトでなく数値でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '壊れたgrid procs要素',
           '{"procs":[1,2,3],"rows":[{"cells":{"q1":{"c":"赤"}}}]}'));

  rid := gen_random_uuid();
  perform tests.allowed(a, 'grid: 塗料番号 c.i が数値でない文字列("abc")でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           rid, u_g, '不正なc.i',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"i":"abc"}}}]}'));
  select count(*) into n from public.recipe_paints where recipe_id = rid;
  perform tests.eq(a, 'grid: 数値でない c.i は recipe_paints に展開されない（集計を汚さない）', n, 0);

  rid := gen_random_uuid();
  perform tests.allowed(a, 'grid: 塗料番号 c.i が負の数(-5)でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           rid, u_g, '負のc.i',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"i":-5}}}]}'));
  select count(*) into n from public.recipe_paints where recipe_id = rid;
  perform tests.eq(a, 'grid: 負の c.i は recipe_paints に展開されない', n, 0);

  rid := gen_random_uuid();
  perform tests.allowed(a, 'grid: 塗料番号 c.i が小数(1.5)でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           rid, u_g, '小数のc.i',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"i":1.5}}}]}'));
  select count(*) into n from public.recipe_paints where recipe_id = rid;
  perform tests.eq(a, 'grid: 小数の c.i は recipe_paints に展開されない', n, 0);

  perform tests.allowed(a, 'grid: 塗料番号 c.i が桁あふれする巨大な数値でも投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           gen_random_uuid(), u_g, '巨大なc.i',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"i":99999999999999999999}}}]}'));

  rid := gen_random_uuid();
  perform tests.allowed(a, 'grid: 自由入力の塗料名(c)を含む投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           rid, u_g, '自由入力塗料',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"c":"  自由テスト名  "}}}]}'));
  select count(*) into n from public.recipe_paints where recipe_id = rid;
  perform tests.eq(a, 'grid: 自由入力の塗料は recipe_paints に1件だけ展開される', n, 1);
  select free_name, proc_name into v_txt, v_txt2 from public.recipe_paints where recipe_id = rid limit 1;
  perform tests.eq(a, 'grid: 自由入力の塗料名は前後の空白が取り除かれて保存される', v_txt, '自由テスト名');
  perform tests.eq(a, 'grid: セルの列IDから工程名(proc_name)が正しく引き当てられる', v_txt2, '基本色');

  rid := gen_random_uuid();
  perform tests.allowed(a, 'grid: 自由入力の塗料名が空白だけの投稿も保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           rid, u_g, '空白だけの自由入力',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"c":"   "}}}]}'));
  select count(*) into n from public.recipe_paints where recipe_id = rid;
  perform tests.eq(a, 'grid: 空白だけの塗料名は recipe_paints に展開されない', n, 0);

  rid := gen_random_uuid();
  perform tests.allowed(a, 'grid: procs に無い列IDのセルがあっても投稿を保存できる',
    format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
           rid, u_g, '未知の列ID',
           '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"zz":{"c":"謎の塗料"}}}]}'));
  select proc_name into v_txt from public.recipe_paints where recipe_id = rid limit 1;
  perform tests.ok(a, 'grid: procs に無い列IDのセルは工程名なし(null)で展開される',
    v_txt is null, '実際のproc_name=' || coalesce(v_txt,'null'));

  select min(sort_order) into v_sort from public.paints where sort_order is not null;
  if v_sort is not null then
    rid := gen_random_uuid();
    perform tests.allowed(a, 'grid: 正しい塗料番号 c.i を含む投稿を保存できる',
      format('insert into public.recipes(id,owner_id,title,grid,is_public,created_at) values (%L,%L,%L,%L::jsonb,true,now() - interval ''1 hour'')',
             rid, u_g, '正しいc.i',
             format('{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"i":%s}}}]}', v_sort)));
    select count(*) into n from public.recipe_paints where recipe_id = rid;
    perform tests.eq(a, 'grid: 正しい塗料番号は recipe_paints に1件展開される', n, 1);
    select paint_id into v_pid from public.recipe_paints where recipe_id = rid limit 1;
    perform tests.ok(a, 'grid: 正しい塗料番号は塗料マスタのIDに解決される',
      v_pid is not null, '実際のpaint_id=' || coalesce(v_pid,'null'));
  else
    perform tests.ok(a, 'grid: 正しい塗料番号が塗料マスタのIDに解決される', false,
      'paints テーブルが空のため検証できませんでした（seed未投入）');
  end if;

  rid := gen_random_uuid();
  insert into public.recipes(id,owner_id,title,grid,is_public, created_at) values (rid, u_g, 'grid更新の同期確認', '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"c":"更新前"}}}]}'::jsonb, true, now() - interval '1 hour');
  update public.recipes set grid = '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"c":"更新後"}}}]}'::jsonb
   where id = rid;
  select count(*) into n from public.recipe_paints where recipe_id = rid;
  perform tests.eq(a, 'grid: gridを更新すると recipe_paints は古い行を残さず入れ替わる', n, 1);
  select free_name into v_txt from public.recipe_paints where recipe_id = rid limit 1;
  perform tests.eq(a, 'grid: 更新後の塗料名が recipe_paints に反映される', v_txt, '更新後');

  r_rp := gen_random_uuid();
  insert into public.recipes(id,owner_id,title,grid,is_public, created_at) values (r_rp, u_rp, '派生表テスト', '{"procs":[{"id":"q1","name":"基本色"}],"rows":[{"cells":{"q1":{"c":"元の塗料"}}}]}'::jsonb, true, now() - interval '1 hour');

  perform tests.as_user(u_rp);
  perform tests.denied(a, 'recipe_paints: 自分の投稿の明細でも直接INSERTできない（人気ランキングの改ざん防止）',
    format('insert into public.recipe_paints(recipe_id,paint_id,free_name,proc_name) values (%L,null,%L,%L)',
           r_rp, '水増し塗料', '基本色'), 'permission denied');
  perform tests.denied(a, 'recipe_paints: 自分の投稿の明細でも直接UPDATEできない',
    format('update public.recipe_paints set free_name = %L where recipe_id = %L', '書き換え', r_rp), 'permission denied');
  perform tests.denied(a, 'recipe_paints: 自分の投稿の明細でも直接DELETEできない',
    format('delete from public.recipe_paints where recipe_id = %L', r_rp), 'permission denied');
  select count(*) into n from public.recipe_paints where recipe_id = r_rp;
  perform tests.eq(a, 'recipe_paints: 直接操作を試みても明細はgrid由来のまま変わらない', n, 1);

  perform tests.as_anon();
  perform tests.denied(a, 'recipe_paints: 未ログインからも直接INSERTできない',
    format('insert into public.recipe_paints(recipe_id,paint_id,free_name,proc_name) values (%L,null,%L,%L)',
           r_rp, '匿名の水増し', '基本色'), 'permission denied');
  perform tests.as_owner();
  select count(*) into n from public.recipe_paints where recipe_id = r_rp;
  perform tests.eq(a, 'recipe_paints: 一連の直接操作の後も明細件数は1件のまま', n, 1);

  perform tests.as_anon();
  perform tests.allowed(a, 'events: 未ログインでもイベント送信そのものは通る（計測が止まらない）',
    format('insert into public.events(user_id,session_id,event_name,properties,occurred_at) values (%L,%L,%L,%L::jsonb,%L)',
           u_vic, 'tstsess_anon', 'page_view', '{"p":1}', now() + interval '10 days'));
  perform tests.as_owner();
  select user_id, occurred_at into v_uid, v_ts from public.events where session_id = 'tstsess_anon' order by id desc limit 1;
  perform tests.ok(a, 'events: 未ログインから他人のuser_idを申告してもサーバーがnullに上書きする',
    v_uid is null, '保存されたuser_id=' || coalesce(v_uid::text,'null'));
  perform tests.ok(a, 'events: occurred_atの未来偽装はサーバー時刻に上書きされる',
    v_ts is not null and v_ts < now() + interval '1 minute' and v_ts > now() - interval '5 minutes',
    '保存されたoccurred_at=' || coalesce(v_ts::text,'行が作られなかった'));

  perform tests.as_user(u_ev);
  perform tests.allowed(a, 'events: ログイン中のイベント送信は通る',
    format('insert into public.events(user_id,session_id,event_name,occurred_at) values (%L,%L,%L,%L)',
           u_vic, 'tstsess_auth', 'view_recipe', now() - interval '30 days'));
  perform tests.as_owner();
  select user_id, occurred_at into v_uid, v_ts from public.events where session_id = 'tstsess_auth' order by id desc limit 1;
  perform tests.eq(a, 'events: 他人のuser_idを申告してもログイン中の本人IDで記録される', v_uid, u_ev);
  perform tests.ok(a, 'events: occurred_atの過去偽装もサーバー時刻に上書きされる',
    v_ts is not null and v_ts > now() - interval '5 minutes',
    '保存されたoccurred_at=' || coalesce(v_ts::text,'null'));

  perform tests.as_user(u_ev);
  perform tests.denied(a, 'events: 許可リストに無いevent_nameは拒否される（勝手なイベント名の混入防止）',
    format('insert into public.events(session_id,event_name) values (%L,%L)', 'tstsess_ng', 'evil_event'),
    'events_name_whitelist');
  perform tests.allowed(a, 'events: 許可リストにあるevent_name(comment_posted)は通る',
    format('insert into public.events(session_id,event_name) values (%L,%L)', 'tstsess_ok', 'comment_posted'));
  perform tests.denied(a, 'events: propertiesが2KBを超えると拒否される（容量の食い潰し防止）',
    format('insert into public.events(session_id,event_name,properties) values (%L,%L,jsonb_build_object(%L,%L))',
           'tstsess_big', 'page_view', 'x', props), 'events_props_size');
  perform tests.denied(a, 'events: session_idが64文字を超えると拒否される',
    format('insert into public.events(session_id,event_name) values (%L,%L)', repeat('z', 65), 'page_view'),
    'events_session_len');
  perform tests.allowed(a, 'events: session_idがちょうど64文字なら通る（上限が正規利用を邪魔しない）',
    format('insert into public.events(session_id,event_name) values (%L,%L)', sess64, 'page_view'));
  perform tests.as_owner();
  select session_id into v_txt from public.events where session_id = sess64 order by id desc limit 1;
  perform tests.eq(a, 'events: session_idはクライアントの値がそのまま保存される（重複排除に使うため）', v_txt, sess64);
  select count(*) into n from public.events where session_id in ('tstsess_ng','tstsess_big') or session_id = repeat('z', 65);
  perform tests.eq(a, 'events: 拒否されたイベントは1件も保存されていない', n, 0);

  perform tests.as_user(u_cmt2);
  perform tests.denied(a, 'comments: 500文字を超える本文は保存できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub, u_cmt2, repeat('あ', 501)), 'comments_body_check');
  perform tests.denied(a, 'comments: 空の本文は保存できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)', pub, u_cmt2, ''),
    'comments_body_check');
  perform tests.allowed(a, 'comments: 500文字ちょうどの本文は保存できる（上限が正規利用を邪魔しない）',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub, u_cmt2, repeat('い', 500)));

  perform tests.as_owner();

  begin
    perform tests.as_owner();
    delete from public.events where session_id like 'tstsess%' or session_id = repeat('z', 65);
    delete from public.notifications where created_at >= t0 and type in ('new_report','new_inquiry');
    delete from public.inquiries where user_id = any(users);
    delete from public.reports   where reporter_id = any(users);
    perform tests.cleanup_users(users);
  exception when others then null;
  end;
end $$;
