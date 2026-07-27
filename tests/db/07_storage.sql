-- 画像・Storage のテスト（自動生成・dev専用）
do $$
declare
  ar   text := '画像・Storage';
  rb   text := 'https://plamo.supabase.co/storage/v1/object/public/recipes/';
  pb   text := 'https://plamo.supabase.co/storage/v1/object/public/profile/';
  uA uuid; uB uuid; uAdm uuid; uP uuid; uPP uuid;
  uD uuid; uD2 uuid; uDr uuid; uDel uuid; uTrg uuid; uOrp uuid;
  fakeu uuid := gen_random_uuid();
  rD uuid; rV uuid; rS uuid; rT uuid; dS uuid; rAn uuid;
  n int;
begin
  perform tests.as_owner();

  -- 判定ヘルパーを「なりすまし中」にも呼べるようにする（dev専用のtestsスキーマ・冪等）
  begin
    execute 'grant usage on schema tests to authenticated, anon';
    execute 'grant execute on all functions in schema tests to authenticated, anon';
  exception when others then null;
  end;

  uA   := tests.make_user();
  uB   := tests.make_user();
  uAdm := tests.make_user(true);
  uP   := tests.make_user();
  uPP  := tests.make_user();
  uD   := tests.make_user();
  uD2  := tests.make_user();
  uDr  := tests.make_user();
  uDel := tests.make_user();
  uTrg := tests.make_user();
  uOrp := tests.make_user();

  -- ================================================================
  -- A) Storageの一覧・書き込み権限（010_storage_policies.sql）
  --    ※ purge系を一度でも呼ぶと storage.allow_delete_query が
  --      トランザクション中ずっと true になるため、この節を最初に置く。
  -- ================================================================
  perform tests.put_object('recipes', uA::text||'/a1.jpg',     uA, '2 hours');
  perform tests.put_object('recipes', uA::text||'/a2.jpg',     uA, '2 hours');
  perform tests.put_object('profile', uA::text||'/avatar.jpg', uA, '2 hours');
  perform tests.put_object('recipes', uB::text||'/b1.jpg',     uB, '2 hours');
  perform tests.put_object('profile', uB::text||'/head.jpg',   uB, '2 hours');

  perform tests.as_anon();
  select count(*)::int into n from storage.objects;
  perform tests.as_owner();
  perform tests.eq(ar, '匿名（未ログイン）は storage.objects を1件も列挙できない', n, 0);

  perform tests.as_anon();
  select count(*)::int into n from storage.objects where bucket_id = 'recipes';
  perform tests.as_owner();
  perform tests.eq(ar, '匿名は recipes バケットのファイル一覧を取得できない', n, 0);

  perform tests.as_anon();
  select count(*)::int into n from storage.objects where bucket_id = 'profile';
  perform tests.as_owner();
  perform tests.eq(ar, '匿名は profile バケットのファイル一覧を取得できない', n, 0);

  perform tests.as_anon();
  select count(*)::int into n from storage.objects where name = uA::text||'/a1.jpg';
  perform tests.as_owner();
  perform tests.eq(ar, '匿名はファイル名を指定してもメタデータを取得できない', n, 0);

  perform tests.as_user(uA);
  select count(*)::int into n from storage.objects
   where bucket_id='recipes' and name like uA::text||'/%';
  perform tests.as_owner();
  perform tests.eq(ar, '本人は自分の recipes 画像（2件）を一覧できる', n, 2);

  perform tests.as_user(uA);
  select count(*)::int into n from storage.objects
   where bucket_id='profile' and name like uA::text||'/%';
  perform tests.as_owner();
  perform tests.eq(ar, '本人は自分の profile 画像（1件）を一覧できる', n, 1);

  perform tests.as_user(uA);
  select count(*)::int into n from storage.objects where name like uB::text||'/%';
  perform tests.as_owner();
  perform tests.eq(ar, '他人（uB）のファイルは uA の一覧に一切出ない', n, 0);

  perform tests.as_user(uB);
  select count(*)::int into n from storage.objects where name like uA::text||'/%';
  perform tests.as_owner();
  perform tests.eq(ar, '他人（uA）のファイルは uB の一覧に一切出ない', n, 0);

  perform tests.as_user(uB);
  select count(*)::int into n from storage.objects
   where bucket_id='recipes' and name like uB::text||'/%';
  perform tests.as_owner();
  perform tests.eq(ar, 'uB は自分の recipes 画像を一覧できる', n, 1);

  perform tests.as_user(uAdm);
  select count(*)::int into n from storage.objects where name like uA::text||'/%';
  perform tests.as_owner();
  perform tests.eq(ar, '管理者であっても他人のStorageファイルは一覧に出ない', n, 0);

  perform tests.as_user(uA);
  select count(*)::int into n from storage.objects;
  perform tests.as_owner();
  perform tests.eq(ar, 'uB の5ファイル中、uA から見えるのは自分の3件だけ', n, 3);

  perform tests.as_anon();
  perform tests.denied(ar, '匿名は storage.objects に行を追加できない',
    format('insert into storage.objects(bucket_id,name,owner) values (%L,%L,%L::uuid)',
           'recipes', uA::text||'/anon.jpg', uA),
    'row-level security');

  perform tests.as_user(uA);
  perform tests.allowed(ar, '本人は自分のフォルダに画像を追加できる',
    format('insert into storage.objects(bucket_id,name,owner) values (%L,%L,%L::uuid)',
           'recipes', uA::text||'/a3.jpg', uA));

  perform tests.as_user(uA);
  perform tests.denied(ar, '所有者を他人（uB）に偽装した画像は追加できない',
    format('insert into storage.objects(bucket_id,name,owner) values (%L,%L,%L::uuid)',
           'recipes', uA::text||'/spoof.jpg', uB),
    'row-level security');

  perform tests.as_user(uA);
  perform tests.affects(ar, '他人の画像を更新しようとしても0件しか効かない',
    format('update storage.objects set updated_at = now() where bucket_id=%L and name=%L',
           'recipes', uB::text||'/b1.jpg'), 0);

  perform tests.as_owner();
  perform set_config('storage.allow_delete_query','true',true);
  perform tests.as_user(uA);
  perform tests.affects(ar, '他人の画像を削除しようとしても0件しか効かない',
    format('delete from storage.objects where bucket_id=%L and name=%L',
           'recipes', uB::text||'/b1.jpg'), 0);

  perform tests.as_owner();
  perform set_config('storage.allow_delete_query','false',true);
  perform tests.as_user(uA);
  perform tests.denied(ar, '自分の画像でもSQLからの直接DELETEはStorageの保護で拒否される（削除はRPC経由のみ）',
    format('delete from storage.objects where bucket_id=%L and name=%L',
           'recipes', uA::text||'/a3.jpg'), null);

  perform tests.as_user(uA);
  perform tests.denied(ar, '他人のUUIDフォルダ名を使ったアップロードは拒否される',
    format('insert into storage.objects(bucket_id,name,owner) values (%L,%L,%L::uuid)',
           'recipes', uB::text||'/evil.jpg', uA),
    'row-level security');

  -- ================================================================
  -- B) purge_unreferenced_images（013）
  --    ★投稿・下書きを先に作ってから画像を置く（自動掃除トリガに先回りされないため）
  -- ================================================================
  perform tests.as_owner();
  insert into public.recipes(owner_id, title, grid, cover_url, is_public, created_at) values (uP, '掃除テスト投稿',
          jsonb_build_object(
            'photos', jsonb_build_array(rb||uP::text||'/photo1.jpg'),
            'rows',   jsonb_build_array(jsonb_build_object('photo', rb||uP::text||'/row1.jpg'))),
          rb||uP::text||'/cover.jpg', true, now() - interval '1 hour');
  insert into public.drafts(owner_id, title, grid, cover_url)
  values (uP, '掃除テスト下書き',
          jsonb_build_object('photos', jsonb_build_array(rb||uP::text||'/draft1.jpg')),
          rb||uP::text||'/draftcover.jpg');

  perform tests.put_object('recipes', uP::text||'/cover.jpg',      uP, '2 hours');
  perform tests.put_object('recipes', uP::text||'/photo1.jpg',     uP, '2 hours');
  perform tests.put_object('recipes', uP::text||'/row1.jpg',       uP, '2 hours');
  perform tests.put_object('recipes', uP::text||'/draft1.jpg',     uP, '2 hours');
  perform tests.put_object('recipes', uP::text||'/draftcover.jpg', uP, '2 hours');
  perform tests.put_object('recipes', uP::text||'/old.jpg',        uP, '2 hours');
  perform tests.put_object('recipes', uP::text||'/old2.jpg',       uP, '3 hours');
  perform tests.put_object('recipes', uP::text||'/fresh.jpg',      uP, '30 minutes');
  perform tests.put_object('profile', uP::text||'/prof.jpg',       uP, '2 hours');

  n := public.purge_unreferenced_images(uP);
  perform tests.eq(ar, '未参照画像の掃除で削除されたのはちょうど2件', n, 2);

  select count(*)::int into n from storage.objects where name = uP::text||'/cover.jpg';
  perform tests.eq(ar, '投稿のカバー画像は掃除で消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uP::text||'/photo1.jpg';
  perform tests.eq(ar, 'grid.photos から参照されている画像は掃除で消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uP::text||'/row1.jpg';
  perform tests.eq(ar, 'grid.rows[].photo から参照されている画像は掃除で消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uP::text||'/draft1.jpg';
  perform tests.eq(ar, '下書きが参照している画像は掃除で消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uP::text||'/draftcover.jpg';
  perform tests.eq(ar, '下書きのカバー画像は掃除で消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uP::text||'/old.jpg';
  perform tests.eq(ar, 'どこからも参照されていない2時間前の画像は掃除で消える', n, 0);

  select count(*)::int into n from storage.objects where name = uP::text||'/old2.jpg';
  perform tests.eq(ar, 'どこからも参照されていない3時間前の画像も掃除で消える', n, 0);

  select count(*)::int into n from storage.objects where name = uP::text||'/fresh.jpg';
  perform tests.eq(ar, 'アップロード直後（30分前）の未参照画像は保存前でも消されない', n, 1);

  select count(*)::int into n from storage.objects where name = uP::text||'/prof.jpg';
  perform tests.eq(ar, 'recipes の掃除で profile バケットの画像は消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uB::text||'/b1.jpg';
  perform tests.eq(ar, '他人（uB）の未参照な古い画像は uP の掃除では消えない', n, 1);

  n := public.purge_unreferenced_images(null);
  perform tests.eq(ar, '掃除関数に null を渡すと何もせず0を返す', n, 0);

  perform tests.as_user(uP);
  perform tests.denied(ar, '一般利用者は purge_unreferenced_images を実行できない',
    format('select public.purge_unreferenced_images(%L::uuid)', uP), 'permission denied');
  perform tests.as_anon();
  perform tests.denied(ar, '匿名は purge_unreferenced_images を実行できない',
    format('select public.purge_unreferenced_images(%L::uuid)', uP), 'permission denied');

  -- ================================================================
  -- C) purge_unreferenced_profile_images（013）
  -- ================================================================
  perform tests.as_owner();
  update public.profiles
     set avatar_url = pb||uPP::text||'/av_new.jpg',
         header_url = pb||uPP::text||'/hd_new.jpg'
   where id = uPP;

  perform tests.put_object('profile', uPP::text||'/av_new.jpg',   uPP, '2 hours');
  perform tests.put_object('profile', uPP::text||'/hd_new.jpg',   uPP, '2 hours');
  perform tests.put_object('profile', uPP::text||'/av_old.jpg',   uPP, '2 hours');
  perform tests.put_object('profile', uPP::text||'/hd_old.jpg',   uPP, '2 hours');
  perform tests.put_object('profile', uPP::text||'/av_fresh.jpg', uPP, '10 minutes');
  perform tests.put_object('recipes', uPP::text||'/r.jpg',        uPP, '2 hours');

  n := public.purge_unreferenced_profile_images(uPP);
  perform tests.eq(ar, 'プロフィール画像の掃除で削除されたのはちょうど2件', n, 2);

  select count(*)::int into n from storage.objects where name = uPP::text||'/av_new.jpg';
  perform tests.eq(ar, '現在使用中のアイコン画像は消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uPP::text||'/hd_new.jpg';
  perform tests.eq(ar, '現在使用中のヘッダー画像は消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uPP::text||'/av_old.jpg';
  perform tests.eq(ar, '差し替え前の古いアイコン画像は消える', n, 0);

  select count(*)::int into n from storage.objects where name = uPP::text||'/av_fresh.jpg';
  perform tests.eq(ar, 'アップロード直後（10分前）のプロフィール画像は消えない', n, 1);

  select count(*)::int into n from storage.objects where name = uPP::text||'/r.jpg';
  perform tests.eq(ar, 'プロフィール画像の掃除で recipes バケットの画像は消えない', n, 1);

  perform tests.as_user(uPP);
  perform tests.denied(ar, '一般利用者は purge_unreferenced_profile_images を実行できない',
    format('select public.purge_unreferenced_profile_images(%L::uuid)', uPP), 'permission denied');

  -- ================================================================
  -- D) delete_recipe_with_images（011）
  -- ================================================================
  perform tests.as_owner();
  insert into public.recipes(owner_id, title, grid, cover_url, is_public, created_at) values (uD, '削除テスト投稿',
          jsonb_build_object(
            'photos', jsonb_build_array(rb||uD::text||'/d_photo.jpg'),
            'rows',   jsonb_build_array(jsonb_build_object('photo', rb||uD::text||'/d_row.jpg'))),
          rb||uD::text||'/d_cover.jpg', true, now() - interval '1 hour')
  returning id into rD;

  perform tests.put_object('recipes', uD::text||'/d_cover.jpg', uD, '2 hours');
  perform tests.put_object('recipes', uD::text||'/d_photo.jpg', uD, '2 hours');
  perform tests.put_object('recipes', uD::text||'/d_row.jpg',   uD, '2 hours');
  perform tests.put_object('recipes', uD::text||'/keep.jpg',    uD, '10 minutes');

  perform tests.as_user(uD2);
  perform tests.denied(ar, '他人の投稿は delete_recipe_with_images で削除できない',
    format('select public.delete_recipe_with_images(%L::uuid)', rD),
    'この投稿を削除する権限がありません');

  perform tests.as_owner();
  select count(*)::int into n from public.recipes where id = rD;
  perform tests.eq(ar, '他人が削除を試みても投稿本文は残っている', n, 1);
  select count(*)::int into n from storage.objects where name = uD::text||'/d_cover.jpg';
  perform tests.eq(ar, '他人が削除を試みても画像は残っている（巻き戻る）', n, 1);

  perform tests.as_user(uD);
  perform tests.denied(ar, '存在しない投稿IDを渡すとエラーになる',
    format('select public.delete_recipe_with_images(%L::uuid)', gen_random_uuid()),
    '投稿が見つかりません');

  -- ※匿名の削除試行は「捨て駒の投稿」に対して行う（この検査が落ちても後続の検査を巻き込まないため）
  perform tests.as_owner();
  insert into public.recipes(owner_id, title, grid, cover_url, is_public, created_at)
  values (uD2, '匿名削除テスト用', '{}'::jsonb, null, true, now() - interval '1 hour')
  returning id into rAn;

  perform tests.as_anon();
  perform tests.denied(ar, '匿名は delete_recipe_with_images を実行できない',
    format('select public.delete_recipe_with_images(%L::uuid)', rAn), 'permission denied');

  perform tests.as_user(uD);
  perform tests.allowed(ar, '投稿者本人は自分の投稿を画像ごと削除できる',
    format('select public.delete_recipe_with_images(%L::uuid)', rD));

  perform tests.as_owner();
  select count(*)::int into n from public.recipes where id = rD;
  perform tests.eq(ar, '削除後は投稿本文が消えている', n, 0);
  select count(*)::int into n from storage.objects where name = uD::text||'/d_cover.jpg';
  perform tests.eq(ar, '削除後はカバー画像も消えている', n, 0);
  select count(*)::int into n from storage.objects where name = uD::text||'/d_photo.jpg';
  perform tests.eq(ar, '削除後は本文(photos)の画像も消えている', n, 0);
  select count(*)::int into n from storage.objects where name = uD::text||'/d_row.jpg';
  perform tests.eq(ar, '削除後は本文(rows)の画像も消えている', n, 0);
  select count(*)::int into n from storage.objects where name = uD::text||'/keep.jpg';
  perform tests.eq(ar, '投稿削除の巻き添えで直近アップロードの無関係な画像は消えない', n, 1);

  insert into public.recipes(owner_id, title, grid, cover_url, is_public, created_at) values (uD2, '通報対応テスト投稿', '{}'::jsonb, rb||uD2::text||'/v_cover.jpg', true, now() - interval '1 hour')
  returning id into rV;
  perform tests.put_object('recipes', uD2::text||'/v_cover.jpg', uD2, '2 hours');

  perform tests.as_user(uAdm);
  perform tests.allowed(ar, '管理者は他人の投稿を画像ごと削除できる（通報対応）',
    format('select public.delete_recipe_with_images(%L::uuid)', rV));

  perform tests.as_owner();
  select count(*)::int into n from public.recipes where id = rV;
  perform tests.eq(ar, '管理者削除の後は投稿本文が消えている', n, 0);
  select count(*)::int into n from storage.objects where name = uD2::text||'/v_cover.jpg';
  perform tests.eq(ar, '管理者削除の後は他人の画像も消えている（公開URLに残らない）', n, 0);

  -- ================================================================
  -- E) delete_draft_with_images（011）— 公開投稿と共有する画像を消さない
  -- ================================================================
  perform tests.as_owner();
  insert into public.recipes(owner_id, title, grid, cover_url, is_public, created_at) values (uDr, '昇格済みの投稿', '{}'::jsonb, rb||uDr::text||'/shared.jpg', true, now() - interval '1 hour')
  returning id into rS;
  insert into public.drafts(owner_id, title, grid, cover_url)
  values (uDr, '共有画像を持つ下書き',
          jsonb_build_object('photos', jsonb_build_array(rb||uDr::text||'/donly.jpg')),
          rb||uDr::text||'/shared.jpg')
  returning id into dS;

  perform tests.put_object('recipes', uDr::text||'/shared.jpg', uDr, '2 hours');
  perform tests.put_object('recipes', uDr::text||'/donly.jpg',  uDr, '2 hours');

  perform tests.as_user(uB);
  perform tests.denied(ar, '他人の下書きは delete_draft_with_images で削除できない',
    format('select public.delete_draft_with_images(%L::uuid)', dS),
    'この下書きを削除する権限がありません');

  perform tests.as_owner();
  select count(*)::int into n from public.drafts where id = dS;
  perform tests.eq(ar, '他人が削除を試みても下書きは残っている', n, 1);

  perform tests.as_user(uDr);
  perform tests.allowed(ar, '存在しない下書きIDを渡してもエラーにならない',
    format('select public.delete_draft_with_images(%L::uuid)', gen_random_uuid()));

  perform tests.as_user(uDr);
  perform tests.allowed(ar, '本人は自分の下書きを画像ごと削除できる',
    format('select public.delete_draft_with_images(%L::uuid)', dS));

  perform tests.as_owner();
  select count(*)::int into n from public.drafts where id = dS;
  perform tests.eq(ar, '削除後は下書き本体が消えている', n, 0);
  select count(*)::int into n from storage.objects where name = uDr::text||'/donly.jpg';
  perform tests.eq(ar, '下書きだけが使っていた画像は消えている', n, 0);
  select count(*)::int into n from storage.objects where name = uDr::text||'/shared.jpg';
  perform tests.eq(ar, '公開投稿と共有している画像は下書き削除でも消えない', n, 1);
  select count(*)::int into n from public.recipes where id = rS;
  perform tests.eq(ar, '共有画像を使っている投稿本体はそのまま残っている', n, 1);

  -- ================================================================
  -- F) delete_user（009）— 退会で本人の画像が消える
  -- ================================================================
  perform tests.as_owner();
  perform tests.put_object('recipes', uDel::text||'/x.jpg', uDel, '2 hours');
  perform tests.put_object('profile', uDel::text||'/y.jpg', uDel, '2 hours');

  perform tests.as_user(uDel);
  perform tests.allowed(ar, '退会（delete_user）は本人が実行できる', 'select public.delete_user()');

  perform tests.as_owner();
  select count(*)::int into n from storage.objects where name = uDel::text||'/x.jpg';
  perform tests.eq(ar, '退会すると本人の recipes 画像が消える', n, 0);
  select count(*)::int into n from storage.objects where name = uDel::text||'/y.jpg';
  perform tests.eq(ar, '退会すると本人の profile 画像が消える', n, 0);
  select count(*)::int into n from auth.users where id = uDel;
  perform tests.eq(ar, '退会するとアカウント自体も消える', n, 0);
  select count(*)::int into n from storage.objects where name = uB::text||'/b1.jpg';
  perform tests.eq(ar, '退会処理で他人の画像は巻き込まれない', n, 1);

  -- ================================================================
  -- G) 自動掃除トリガ trg_purge_images（013）
  -- ================================================================
  perform tests.as_owner();
  perform tests.put_object('recipes', uTrg::text||'/stale.jpg',  uTrg, '2 hours');
  perform tests.put_object('recipes', uTrg::text||'/fresh2.jpg', uTrg, '5 minutes');

  insert into public.recipes(owner_id, title, grid, cover_url, is_public, created_at) values (uTrg, 'トリガ確認用', '{}'::jsonb, null, true, now() - interval '1 hour')
  returning id into rT;

  select count(*)::int into n from storage.objects where name = uTrg::text||'/stale.jpg';
  perform tests.eq(ar, '投稿を保存すると未参照の古い画像が自動で掃除される', n, 0);
  select count(*)::int into n from storage.objects where name = uTrg::text||'/fresh2.jpg';
  perform tests.eq(ar, '自動掃除でもアップロード直後(5分前)の画像は消さない', n, 1);

  -- 掃除は「写真が不要になり得る変更」のときだけ走る（017で grid / cover_url の更新時に限定）。
  -- 題名だけの変更では画像の参照関係は変わらないので掃除は走らない＝走らないことが正しい。
  -- （以前は閲覧数の+1でも毎回Storage全走査が起き、閲覧のたびに重い処理が発生していた）
  perform tests.put_object('recipes', uTrg::text||'/stale2.jpg', uTrg, '2 hours');
  update public.recipes set title = '編集後' where id = rT;
  select count(*)::int into n from storage.objects where name = uTrg::text||'/stale2.jpg';
  perform tests.eq(ar, '題名だけの変更では画像の掃除は走らない（無駄な全走査を避ける）', n, 1);

  -- 本文(grid)を変えたときは、参照が変わり得るので掃除が走る
  update public.recipes set grid = jsonb_build_object('procs','[]'::jsonb,'rows','[]'::jsonb) where id = rT;
  select count(*)::int into n from storage.objects where name = uTrg::text||'/stale2.jpg';
  perform tests.eq(ar, '本文(grid)を変更したときは未参照画像の掃除が走る', n, 0);

  -- ================================================================
  -- H) purge_orphan_storage（009）— 退会済みUUIDフォルダの掃除
  -- ================================================================
  perform tests.as_owner();
  perform tests.put_object('recipes', fakeu::text||'/ghost.jpg',  uOrp, '2 hours');
  perform tests.put_object('profile', fakeu::text||'/ghost2.jpg', uOrp, '2 hours');
  perform tests.put_object('recipes', uOrp::text||'/alive.jpg',   uOrp, '2 hours');

  perform tests.as_user(uOrp);
  perform tests.denied(ar, '一般利用者は purge_orphan_storage を実行できない',
    'select public.purge_orphan_storage()', 'permission denied');

  perform tests.as_owner();
  n := public.purge_orphan_storage();
  perform tests.ok(ar, '孤児画像の掃除が2件以上を削除した', n >= 2,
    '削除件数=' || coalesce(n::text,'null'));

  select count(*)::int into n from storage.objects where name = fakeu::text||'/ghost.jpg';
  perform tests.eq(ar, '存在しない（退会済み）UUIDフォルダの recipes 画像は消える', n, 0);
  select count(*)::int into n from storage.objects where name = fakeu::text||'/ghost2.jpg';
  perform tests.eq(ar, '存在しない（退会済み）UUIDフォルダの profile 画像も消える', n, 0);
  select count(*)::int into n from storage.objects where name = uOrp::text||'/alive.jpg';
  perform tests.eq(ar, '現役ユーザーの画像は孤児掃除では消えない', n, 1);

  -- ================================================================
  -- 後片付け（失敗しても止めない）
  -- ================================================================
  begin
    perform tests.as_owner();
    perform set_config('storage.allow_delete_query','true',true);
    delete from storage.objects where (storage.foldername(name))[1] = fakeu::text;
    perform tests.cleanup_users(array[uA,uB,uAdm,uP,uPP,uD,uD2,uDr,uDel,uTrg,uOrp]);
  exception when others then null;
  end;
end $$;
