-- 閲覧数・ランキング のテスト（自動生成・dev専用）
do $$
declare
  area text := '閲覧数・ランキング';
  uA uuid; uB uuid; uIns uuid; adm uuid;
  tag text;
  pA text; pB text; pC text; pD text; pE text; pF text;
  m1 text; m2 text; m3 text; mP text;
  cov1 text; cov2 text;
  rGuard uuid; rView uuid; rThr uuid; rTog uuid; rPriv uuid;
  rPub1 uuid; rPub2 uuid; rSuf uuid; rDup uuid; rOld uuid;
  rF1 uuid; rF2 uuid; rF3 uuid; rIns uuid; rGhost uuid;
  n int; b bigint; sc numeric; t text; u uuid; i int;
begin
  ------------------------------------------------------------------
  -- 下準備（すべて特権＝as_owner の状態で作る。auth.uid()がnullなので
  -- 投稿間隔20秒・1日30件などの制限にも掛からない）
  ------------------------------------------------------------------
  perform tests.as_owner();
  tag  := substr(replace(gen_random_uuid()::text,'-',''),1,8);
  uA   := tests.make_user();
  uB   := tests.make_user();
  uIns := tests.make_user();
  adm  := tests.make_user(true);

  pA := 'ZZ塗料A_'||tag;  pB := 'ZZ塗料B_'||tag;  pC := 'ZZ塗料C_'||tag;
  pD := 'ZZ塗料D_'||tag;  pE := 'ZZ塗料E_'||tag;  pF := 'ZZ塗料F_'||tag;
  m1 := 'ZZ方法1_'||tag;  m2 := 'ZZ方法2_'||tag;  m3 := 'ZZ方法3_'||tag;  mP := 'ZZ非公開方法_'||tag;
  cov1 := 'https://example.test/'||tag||'_cover1.jpg';
  cov2 := 'https://example.test/'||tag||'_cover2.jpg';

  rGuard := gen_random_uuid(); rView := gen_random_uuid(); rThr := gen_random_uuid();
  rTog   := gen_random_uuid(); rPriv := gen_random_uuid(); rPub1 := gen_random_uuid();
  rPub2  := gen_random_uuid(); rSuf  := gen_random_uuid(); rDup  := gen_random_uuid();
  rOld   := gen_random_uuid(); rF1   := gen_random_uuid(); rF2   := gen_random_uuid();
  rF3    := gen_random_uuid(); rIns  := gen_random_uuid(); rGhost := gen_random_uuid();

  -- 閲覧数まわりの検証用（塗料・タグなし）
  insert into public.recipes(id,owner_id,title,is_public,created_at)
  values (rGuard,uA,'ZZ改ざん防止確認用',true, now()-interval '2 hours'),
         (rView ,uA,'ZZ閲覧加算確認用'  ,true, now()-interval '2 hours'),
         (rThr  ,uA,'ZZ連打抑制確認用'  ,true, now()-interval '2 hours');
  insert into public.recipes(id,owner_id,title,is_public,created_at)
  values (rTog,uA,'ZZ公開切替確認用',false, now()-interval '2 hours');

  -- 非公開投稿（塗料pB・タグmP はランキングに出てはいけない）
  insert into public.recipes(id,owner_id,title,is_public,methods,grid,created_at)
  values (rPriv,uA,'ZZ非公開投稿',false, array[mP],
    jsonb_build_object(
      'procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows' , jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pB))))),
    now()-interval '2 hours');

  -- 公開投稿2件（同じ塗料pA を使用＝使用数2。代表作例の選ばれ方も見る）
  insert into public.recipes(id,owner_id,title,cover_url,is_public,methods,grid,created_at)
  values (rPub1,uA,'ZZ公開投稿1',cov1,true, array[m1,m1,m1],
    jsonb_build_object(
      'procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows' , jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pA))))),
    now()-interval '2 hours');
  insert into public.recipes(id,owner_id,title,cover_url,is_public,methods,grid,created_at)
  values (rPub2,uA,'ZZ公開投稿2',cov2,true, array[m2,m3],
    jsonb_build_object(
      'procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows' , jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pA))))),
    now()-interval '2 hours');

  -- サフ工程だけで使った塗料pC（集計から除外されるはず）
  insert into public.recipes(id,owner_id,title,is_public,grid,created_at)
  values (rSuf,uA,'ZZサフのみ投稿',true,
    jsonb_build_object(
      'procs', jsonb_build_array(jsonb_build_object('id','p1','name','サフ')),
      'rows' , jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pC))))),
    now()-interval '2 hours');

  -- 1投稿の中で同じ塗料pD を2箇所に使う（使用数は1のはず）
  insert into public.recipes(id,owner_id,title,is_public,methods,grid,created_at)
  values (rDup,uA,'ZZ同一塗料2箇所',true, array[m2],
    jsonb_build_object(
      'procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows' , jsonb_build_array(
                 jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pD))),
                 jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pD))))),
    now()-interval '2 hours');

  -- 30日前の公開投稿（定番には出るが急上昇には出ないはず）
  insert into public.recipes(id,owner_id,title,is_public,grid,created_at)
  values (rOld,uA,'ZZ30日前の投稿',true,
    jsonb_build_object(
      'procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows' , jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pE))))),
    now()-interval '30 days');

  -- 急上昇スコア計算用：塗料pF＝直近7日に2件・30日前に1件（合計3件）
  insert into public.recipes(id,owner_id,title,is_public,grid,created_at)
  values (rF1,uA,'ZZ急上昇1',true,
    jsonb_build_object('procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows', jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pF))))),
    now()-interval '1 hour'),
         (rF2,uA,'ZZ急上昇2',true,
    jsonb_build_object('procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows', jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pF))))),
    now()-interval '2 hours'),
         (rF3,uA,'ZZ急上昇3(古い)',true,
    jsonb_build_object('procs', jsonb_build_array(jsonb_build_object('id','p1','name','基本色')),
      'rows', jsonb_build_array(jsonb_build_object('cells', jsonb_build_object('p1', jsonb_build_object('c', pF))))),
    now()-interval '30 days');

  ------------------------------------------------------------------
  -- 前提確認（この後の集計テストが「空振り」でないことを保証する）
  ------------------------------------------------------------------
  select count(*) into b from public.recipe_paints where recipe_id = rDup;
  perform tests.eq(area,'前提: 1投稿に同じ塗料を2箇所書いた明細が2行できている', b, 2::bigint);
  select count(*) into b from public.recipe_paints where recipe_id = rPub1;
  perform tests.eq(area,'前提: 公開投稿1の塗料明細が1行できている', b, 1::bigint);

  ------------------------------------------------------------------
  -- 1) 閲覧数の改ざん防止（increment_view を通さない書き換え）
  --    ※ increment_view を呼ぶ前に実施（呼ぶと同一トランザクションに許可フラグが残るため）
  ------------------------------------------------------------------
  perform tests.as_user(uIns);
  perform tests.allowed(area,'新規投稿の作成そのものは view_count を指定しても成功する',
    format('insert into public.recipes(id,owner_id,title,is_public,view_count,created_at) values (%L,%L,%L,true,9999,%L)',
           rIns, uIns, 'ZZ初期値水増し試行', now() - interval '1 hour'));
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rIns;
  perform tests.eq(area,'作成時に view_count=9999 を仕込んでも必ず0から始まる', n, 0);

  perform tests.as_user(uA);
  perform tests.affects(area,'所有者が自分の投稿の view_count を直接UPDATEすると行自体は更新される',
    format('update public.recipes set view_count = 9999 where id = %L', rGuard), 1);
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rGuard;
  perform tests.eq(area,'所有者が直接UPDATEしても view_count は元の値に戻される', n, 0);

  perform tests.as_user(uB);
  perform tests.affects(area,'他人は投稿の view_count を直接UPDATEできない（0件）',
    format('update public.recipes set view_count = 9999 where id = %L', rGuard), 0);

  perform tests.as_anon();
  perform tests.affects(area,'匿名は投稿の view_count を直接UPDATEできない（0件）',
    format('update public.recipes set view_count = 9999 where id = %L', rGuard), 0);

  perform tests.as_user(adm);
  perform tests.affects(area,'管理者でも他人の投稿の view_count は直接UPDATEできない（0件）',
    format('update public.recipes set view_count = 9999 where id = %L', rGuard), 0);

  perform tests.as_owner();
  update public.recipes set view_count = 555 where id = rGuard;
  n := null; select view_count into n from public.recipes where id = rGuard;
  perform tests.eq(area,'特権（SQL直実行）で書き換えても increment_view 経由でなければ戻される', n, 0);

  ------------------------------------------------------------------
  -- 2) increment_view の基本動作
  ------------------------------------------------------------------
  perform tests.as_anon();
  perform tests.allowed(area,'匿名でも increment_view を実行する権限がある',
    format('select public.increment_view(%L::uuid)', rView));
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rView;
  perform tests.eq(area,'公開投稿は匿名の閲覧で view_count が1増える', n, 1);

  perform tests.as_anon();
  perform public.increment_view(rView);
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rView;
  perform tests.eq(area,'閲覧のたびに1ずつ増える（2回で2）', n, 2);

  perform tests.as_user(uB);
  perform tests.allowed(area,'ログイン中の利用者も increment_view を実行できる',
    format('select public.increment_view(%L::uuid)', rView));
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rView;
  perform tests.eq(area,'他人（ログイン中）の閲覧でも公開投稿の view_count が増える', n, 3);

  perform tests.as_user(uA);
  perform public.increment_view(rView);
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rView;
  perform tests.eq(area,'投稿者本人の閲覧も加算される（自己閲覧の除外はしていない仕様）', n, 4);

  perform tests.as_anon();
  n := null; select view_count into n from public.recipes where id = rView;
  perform tests.eq(area,'匿名でも公開投稿の閲覧数を読める（ランキング表示のため）', n, 4);

  b := null; select count(*) into b from public.recipes where id = rPriv;
  perform tests.eq(area,'匿名からは他人の非公開投稿が行ごと見えない', b, 0::bigint);
  perform tests.as_user(uB);
  b := null; select count(*) into b from public.recipes where id = rPriv;
  perform tests.eq(area,'他のログイン利用者からも非公開投稿は見えない', b, 0::bigint);

  -- increment_view 呼び出し後に許可フラグが残っていないか（多層防御の確認）
  perform tests.as_user(uA);
  perform tests.affects(area,'increment_view の後の直接UPDATEも行自体は更新される',
    format('update public.recipes set view_count = 1234 where id = %L', rView), 1);
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rView;
  perform tests.eq(area,'increment_view を呼んだ後でも直接UPDATEは巻き戻される（許可フラグが同一トランザクションに残らない）', n, 4);
  perform set_config('app.allow_view','',true);

  ------------------------------------------------------------------
  -- 3) 非公開投稿・存在しない投稿・公開切替
  ------------------------------------------------------------------
  perform tests.as_anon();
  perform tests.allowed(area,'非公開投稿に対する increment_view はエラーにならない',
    format('select public.increment_view(%L::uuid)', rPriv));
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rPriv;
  perform tests.eq(area,'非公開投稿は閲覧されても view_count が増えない', n, 0);

  perform tests.as_anon();
  perform tests.allowed(area,'存在しない投稿IDで increment_view を呼んでもエラーにならない',
    format('select public.increment_view(%L::uuid)', rGhost));

  perform tests.as_anon();
  perform public.increment_view(rTog);
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rTog;
  perform tests.eq(area,'非公開のうちは閲覧されても0のまま', n, 0);
  update public.recipes set is_public = true where id = rTog;
  perform tests.as_anon();
  perform public.increment_view(rTog);
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rTog;
  perform tests.eq(area,'公開に切り替えた後は閲覧数が増えるようになる', n, 1);
  perform set_config('app.allow_view','',true);

  ------------------------------------------------------------------
  -- 4) 連打の上限（1投稿あたり1分60回まで）
  ------------------------------------------------------------------
  perform tests.as_anon();
  for i in 1..61 loop
    perform public.increment_view(rThr);
  end loop;
  perform tests.as_owner();
  n := null; select view_count into n from public.recipes where id = rThr;
  perform tests.eq(area,'1分間に61回連打しても閲覧数は60で頭打ちになる', n, 60);
  n := null;
  select cnt into n from public.view_throttle
   where recipe_id = rThr and minute = date_trunc('minute', now());
  perform tests.eq(area,'連打抑制の記録（view_throttle）には呼び出し回数61が残る', n, 61);
  perform set_config('app.allow_view','',true);

  perform tests.as_anon();
  perform tests.denied(area,'匿名は連打抑制テーブル(view_throttle)を読めない',
    'select cnt from public.view_throttle limit 1', 'permission denied');
  perform tests.as_user(uB);
  perform tests.denied(area,'ログイン利用者も連打抑制テーブルに書き込めない',
    'insert into public.view_throttle(recipe_id, minute, cnt) values (gen_random_uuid(), now(), 1)', null);

  ------------------------------------------------------------------
  -- 5) ランキング用の閲覧数を付ける（代表作例の選ばれ方の検証に使う）
  --    公開投稿2 に3回、公開投稿1 に1回 → 代表は公開投稿2 になるはず
  ------------------------------------------------------------------
  perform tests.as_owner();
  perform public.increment_view(rPub2);
  perform public.increment_view(rPub2);
  perform public.increment_view(rPub2);
  perform public.increment_view(rPub1);
  perform set_config('app.allow_view','',true);
  n := null; select view_count into n from public.recipes where id = rPub2;
  perform tests.eq(area,'前提: 代表作例の判定に使う閲覧数が正しく付いている', n, 3);

  ------------------------------------------------------------------
  -- 6) ランキングRPCが匿名から呼べること
  ------------------------------------------------------------------
  perform tests.as_anon();
  perform tests.allowed(area,'匿名でも popular_paints（定番塗料）を呼べてエラーにならない',
    'select * from public.popular_paints(12)');
  perform tests.allowed(area,'匿名でも rising_paints（急上昇塗料）を呼べてエラーにならない',
    'select * from public.rising_paints(12)');
  perform tests.allowed(area,'匿名でも popular_methods（人気の塗装方法）を呼べてエラーにならない',
    'select * from public.popular_methods(12)');
  perform tests.allowed(area,'引数を省略してもランキングRPCが動く（既定値12）',
    'select * from public.popular_paints()');

  ------------------------------------------------------------------
  -- 7) 定番塗料（popular_paints）の中身
  ------------------------------------------------------------------
  perform tests.as_owner();

  b := null;
  begin select uses into b from public.popular_paints(5000) where pid = 'free:'||pA;
  exception when others then b := null; end;
  perform tests.eq(area,'定番塗料: 公開2投稿で使われた塗料の使用数が2になる', b, 2::bigint);

  b := null;
  begin select count(*) into b from public.popular_paints(5000) where pid = 'free:'||pB;
  exception when others then b := null; end;
  perform tests.eq(area,'定番塗料: 非公開投稿だけで使った塗料は集計に出ない', b, 0::bigint);

  b := null;
  begin select count(*) into b from public.popular_paints(5000) where pid = 'free:'||pC;
  exception when others then b := null; end;
  perform tests.eq(area,'定番塗料: サフ工程だけの塗料は除外される', b, 0::bigint);

  b := null;
  begin select uses into b from public.popular_paints(5000) where pid = 'free:'||pD;
  exception when others then b := null; end;
  perform tests.eq(area,'定番塗料: 同じ投稿内で同じ塗料を2箇所使っても使用数は1', b, 1::bigint);

  b := null;
  begin select uses into b from public.popular_paints(5000) where pid = 'free:'||pE;
  exception when others then b := null; end;
  perform tests.eq(area,'定番塗料: 古い公開投稿の塗料も累計として数えられる', b, 1::bigint);

  t := null;
  begin select label into t from public.popular_paints(5000) where pid = 'free:'||pA;
  exception when others then t := null; end;
  perform tests.eq(area,'定番塗料: 自由入力の塗料名がそのまま表示名になる', t, pA);

  t := null;
  begin select brand into t from public.popular_paints(5000) where pid = 'free:'||pA;
  exception when others then t := null; end;
  perform tests.eq(area,'定番塗料: 自由入力の塗料はブランドが「自由入力」になる', t, '自由入力');

  t := null; u := null;
  begin select sample_cover, sample_id into t, u from public.popular_paints(5000) where pid = 'free:'||pA;
  exception when others then t := null; u := null; end;
  perform tests.eq(area,'定番塗料: 代表作例の表紙は閲覧数が最も多い投稿のものになる', t, cov2);
  perform tests.eq(area,'定番塗料: 代表作例のIDも閲覧数が最も多い投稿になる', u, rPub2);

  b := null;
  begin select count(*) into b from public.popular_paints(2);
  exception when others then b := null; end;
  perform tests.eq(area,'定番塗料: limit_n で指定した件数を超えて返さない', b, 2::bigint);

  ------------------------------------------------------------------
  -- 8) 急上昇塗料（rising_paints）の中身
  ------------------------------------------------------------------
  b := null;
  begin select recent into b from public.rising_paints(5000) where pid = 'free:'||pF;
  exception when others then b := null; end;
  perform tests.eq(area,'急上昇: 直近7日の使用投稿数（2件）が正しく数えられる', b, 2::bigint);

  b := null;
  begin select total into b from public.rising_paints(5000) where pid = 'free:'||pF;
  exception when others then b := null; end;
  perform tests.eq(area,'急上昇: 累計の使用投稿数（3件）が正しく数えられる', b, 3::bigint);

  sc := null;
  begin select score into sc from public.rising_paints(5000) where pid = 'free:'||pF;
  exception when others then sc := null; end;
  perform tests.eq(area,'急上昇: スコアが「直近数×(直近数÷累計)」で計算される', sc, 1.333);

  b := null;
  begin select count(*) into b from public.rising_paints(5000) where pid = 'free:'||pE;
  exception when others then b := null; end;
  perform tests.eq(area,'急上昇: 30日前の投稿だけの塗料は出てこない', b, 0::bigint);

  b := null;
  begin select count(*) into b from public.rising_paints(5000) where pid = 'free:'||pB;
  exception when others then b := null; end;
  perform tests.eq(area,'急上昇: 非公開投稿の塗料は出てこない', b, 0::bigint);

  b := null;
  begin select count(*) into b from public.rising_paints(5000) where pid = 'free:'||pC;
  exception when others then b := null; end;
  perform tests.eq(area,'急上昇: サフ工程だけの塗料は除外される', b, 0::bigint);

  b := null;
  begin select count(*) into b from public.rising_paints(1);
  exception when others then b := null; end;
  perform tests.eq(area,'急上昇: limit_n で指定した件数を超えて返さない', b, 1::bigint);

  ------------------------------------------------------------------
  -- 9) 人気の塗装方法（popular_methods）の中身
  ------------------------------------------------------------------
  b := null;
  begin select uses into b from public.popular_methods(5000) where method = m1;
  exception when others then b := null; end;
  perform tests.eq(area,'人気方法: 1投稿に同じタグを3回入れても使用数は1（1投稿での順位乗っ取り防止）', b, 1::bigint);

  b := null;
  begin select uses into b from public.popular_methods(5000) where method = m2;
  exception when others then b := null; end;
  perform tests.eq(area,'人気方法: 別々の公開2投稿で使われたタグは使用数2になる', b, 2::bigint);

  b := null;
  begin select uses into b from public.popular_methods(5000) where method = m3;
  exception when others then b := null; end;
  perform tests.eq(area,'人気方法: 公開1投稿だけのタグは使用数1になる', b, 1::bigint);

  b := null;
  begin select count(*) into b from public.popular_methods(5000) where method = mP;
  exception when others then b := null; end;
  perform tests.eq(area,'人気方法: 非公開投稿のタグは集計に出ない', b, 0::bigint);

  b := null;
  begin select count(*) into b from public.popular_methods(3);
  exception when others then b := null; end;
  perform tests.eq(area,'人気方法: limit_n で指定した件数を超えて返さない', b, 3::bigint);

  ------------------------------------------------------------------
  -- 10) 後片付け（失敗しても止めない）
  ------------------------------------------------------------------
  begin
    perform tests.as_owner();
    delete from public.view_throttle
     where recipe_id in (rGuard,rView,rThr,rTog,rPriv,rPub1,rPub2,rSuf,rDup,rOld,rF1,rF2,rF3,rIns,rGhost);
    delete from public.recipes
     where id in (rGuard,rView,rThr,rTog,rPriv,rPub1,rPub2,rSuf,rDup,rOld,rF1,rF2,rF3,rIns);
    perform tests.cleanup_users(array[uA,uB,uIns,adm]);
  exception when others then null;
  end;
end $$;
