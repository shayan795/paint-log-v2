-- 検索・関数の安全性 のテスト（自動生成・dev専用）
do $$
declare
  area      text := '検索・関数の安全性';
  u1 uuid; u2 uuid; adm uuid; adm2 uuid;
  tok text; tok_title text; tok_tag text; tok_paint text; tok_priv text; tok_draft text; tok_wild text; tok_bulk text;
  r_title uuid; r_tag uuid; r_paint uuid; r_priv uuid; r_pct uuid; r_und uuid; r_bsl uuid; r_del uuid;
  d1 uuid;
  n int; b boolean; mr text; vc0 int; vc1 int; i int;
begin
  -- =========================================================
  -- 下準備（すべて特権状態で作る）
  -- =========================================================
  perform tests.as_owner();
  tok       := 'zz' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  tok_title := tok || 'aaa';
  tok_tag   := tok || 'bbb';
  tok_paint := tok || 'ccc';
  tok_priv  := tok || 'ddd';
  tok_draft := tok || 'eee';
  tok_wild  := tok || 'fff';
  tok_bulk  := tok || 'ggg';

  u1   := tests.make_user();
  u2   := tests.make_user();
  adm  := tests.make_user(true);
  adm2 := tests.make_user(true);

  -- 公開：タイトル一致用
  insert into public.recipes(owner_id, title, is_public, methods, grid, created_at) values (u1, 'テスト' || tok_title, true, '{}'::text[], '{}'::jsonb, now() - interval '1 hour')
  returning id into r_title;

  -- 公開：タグ(methods)一致用
  insert into public.recipes(owner_id, title, is_public, methods, grid, created_at) values (u1, 'テスト無関係1', true, array[tok_tag]::text[], '{}'::jsonb, now() - interval '1 hour')
  returning id into r_tag;

  -- 公開：grid(自由入力塗料名)一致用
  insert into public.recipes(owner_id, title, is_public, methods, grid, created_at) values (u1, 'テスト無関係2', true, '{}'::text[],
          jsonb_build_object(
            'procs', jsonb_build_array(jsonb_build_object('id','q1','name','基本色')),
            'rows',  jsonb_build_array(jsonb_build_object('cells',
                       jsonb_build_object('q1', jsonb_build_object('c', tok_paint))))), now() - interval '1 hour')
  returning id into r_paint;

  -- 非公開：タイトル・タグ・gridすべてに秘密の語を入れる（絶対に検索に出てはいけない）
  insert into public.recipes(owner_id, title, is_public, methods, grid, created_at) values (u1, 'ひみつ' || tok_priv, false, array[tok_priv || 'メソッド']::text[],
          jsonb_build_object(
            'procs', jsonb_build_array(jsonb_build_object('id','q1','name','基本色')),
            'rows',  jsonb_build_array(jsonb_build_object('cells',
                       jsonb_build_object('q1', jsonb_build_object('c', tok_priv || '塗料'))))), now() - interval '1 hour')
  returning id into r_priv;

  -- 公開：LIKEワイルドカード検証用の3件（% / _ / \ をタイトルに含む）
  insert into public.recipes(owner_id, title, is_public, created_at) values (u1, 'ワイルド' || tok_wild || 'a%b', true, now() - interval '1 hour') returning id into r_pct;
  insert into public.recipes(owner_id, title, is_public, created_at) values (u1, 'ワイルド' || tok_wild || 'a_b', true, now() - interval '1 hour') returning id into r_und;
  insert into public.recipes(owner_id, title, is_public, created_at) values (u1, 'ワイルド' || tok_wild || 'a\b', true, now() - interval '1 hour') returning id into r_bsl;

  -- 削除RPC検証用
  insert into public.recipes(owner_id, title, is_public, created_at) values (u1, '削除テスト' || tok, true, now() - interval '1 hour') returning id into r_del;

  -- 下書き（検索に出てはいけない）
  insert into public.drafts(owner_id, title, grid)
  values (u1, '下書き' || tok_draft, jsonb_build_object('memo', tok_draft || '塗料'))
  returning id into d1;

  -- 通報（report_summary の検証用）
  begin
    insert into public.reports(recipe_id, reporter_id, reason, detail)
    values (r_title, u2, 'spam', 'テスト用');
  exception when others then null;
  end;

  -- =========================================================
  -- 1) 検索RPCの作り（定義そのもの）を確かめる
  -- =========================================================
  select not p.prosecdef into b
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'search_recipes';
  perform tests.ok(area, '検索RPCは呼び出した人の権限で動く(security invoker＝RLSが効く)',
                   coalesce(b,false), 'security definer になっているとRLSを素通りしてしまう');

  select pg_get_function_result(p.oid) !~* 'grid' into b
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'search_recipes';
  perform tests.ok(area, '検索の戻り値にレシピ本文(grid)が含まれない【転送量対策】',
                   coalesce(b,false), 'grid を返していると1件数KB×件数の無駄な転送が発生する');

  perform tests.as_anon();
  perform tests.denied(area, '検索結果から grid 列を取り出せない',
                       'select grid from public.search_recipes(''x'', 1)', 'grid');
  perform tests.allowed(area, '未ログインでも検索は使える(正規利用が壊れていない)',
                        'select count(*) from public.search_recipes(''a'', 5)');

  -- =========================================================
  -- 2) 非公開・下書きが検索に絶対に出ないこと
  -- =========================================================
  perform tests.as_anon();
  select count(*) into n from public.search_recipes(tok_priv, 50);
  perform tests.eq(area, '非公開レシピは未ログインの検索に出ない', n, 0);

  select count(*) into n from public.search_recipes(tok_priv || '塗料', 50);
  perform tests.eq(area, '非公開レシピのgrid内の塗料名で検索しても出ない', n, 0);

  select count(*) into n from public.search_recipes(tok_priv || 'メソッド', 50);
  perform tests.eq(area, '非公開レシピのタグ名で検索しても出ない', n, 0);

  perform tests.as_user(u2);
  select count(*) into n from public.search_recipes(tok_priv, 50);
  perform tests.eq(area, '非公開レシピは他の利用者の検索に出ない', n, 0);

  perform tests.as_user(u1);
  select count(*) into n from public.search_recipes(tok_priv, 50);
  perform tests.eq(area, '非公開レシピは所有者本人の検索にも出ない(検索は公開専用)', n, 0);

  select count(*) into n from public.recipes where id = r_priv;
  perform tests.eq(area, '非公開レシピ自体は本人が直接読める(テストが空振りでない証拠)', n, 1);

  select count(*) into n from public.search_recipes(tok_draft, 50);
  perform tests.eq(area, '下書きは本人の検索にも出ない', n, 0);

  select count(*) into n from public.search_recipes(tok_draft || '塗料', 50);
  perform tests.eq(area, '下書きのgrid内の語で検索しても出ない', n, 0);

  select count(*) into n from public.drafts where id = d1;
  perform tests.eq(area, '下書き自体は本人が直接読める(テストが空振りでない証拠)', n, 1);

  perform tests.as_anon();
  select coalesce(bool_and(is_public), true) into b from public.search_recipes('', 50);
  perform tests.ok(area, '検索が返す行はすべて公開(is_public=true)である', coalesce(b,false),
                   '非公開の行が1件でも混ざっている');

  -- =========================================================
  -- 3) 一致理由(match_reason)が正しい
  -- =========================================================
  select s.match_reason into mr from public.search_recipes(tok_title, 50) s where s.id = r_title;
  perform tests.eq(area, 'タイトル一致の理由が title と返る', mr, 'title'::text);

  select s.match_reason into mr from public.search_recipes(tok_tag, 50) s where s.id = r_tag;
  perform tests.eq(area, 'タグ一致の理由が tag と返る', mr, 'tag'::text);

  select s.match_reason into mr from public.search_recipes(tok_paint, 50) s where s.id = r_paint;
  perform tests.eq(area, '塗料名(grid)一致の理由が paint と返る', mr, 'paint'::text);

  -- =========================================================
  -- 4) LIKEのワイルドカード( % _ \ )を入力しても壊れない・全件返らない
  -- =========================================================
  select count(*) into n from public.search_recipes(tok_wild, 50);
  perform tests.eq(area, 'ワイルドカード検証用の3件が普通に検索できる', n, 3);

  select count(*) into n from public.search_recipes(tok_wild || 'a%b', 50) s where s.id = r_pct;
  perform tests.eq(area, '「%」を含む語で検索すると「%」を含む投稿が見つかる(文字として扱われる)', n, 1);

  select count(*) into n from public.search_recipes(tok_wild || 'a%b', 50) s where s.id in (r_und, r_bsl);
  perform tests.eq(area, '「%」が万能文字として働かない(a_b や a\b を巻き込まない)', n, 0);

  select count(*) into n from public.search_recipes(tok_wild || 'a_b', 50) s where s.id = r_und;
  perform tests.eq(area, '「_」を含む語で検索すると「_」を含む投稿が見つかる(文字として扱われる)', n, 1);

  select count(*) into n from public.search_recipes(tok_wild || 'a_b', 50) s where s.id in (r_pct, r_bsl);
  perform tests.eq(area, '「_」が1文字ワイルドカードとして働かない(a%b や a\b を巻き込まない)', n, 0);

  select count(*) into n from public.search_recipes(tok_wild || 'a\b', 50) s where s.id = r_bsl;
  perform tests.eq(area, '「\」を含む語で検索しても壊れず該当投稿が見つかる', n, 1);

  select count(*) into n from public.search_recipes(tok_wild || 'a\b', 50) s where s.id in (r_pct, r_und);
  perform tests.eq(area, '「\」がエスケープ記号として暴走しない(他の投稿を巻き込まない)', n, 0);

  select count(*) into n from public.search_recipes('%', 50) s where s.id = r_title;
  perform tests.eq(area, '「%」だけを検索しても全件は返らない(無関係な公開投稿が出ない)', n, 0);

  select count(*) into n from public.search_recipes('_', 50) s where s.id = r_title;
  perform tests.eq(area, '「_」だけを検索しても全件は返らない', n, 0);

  perform tests.allowed(area, '「%_\%」のような記号だけの検索でもエラーにならない',
                        'select count(*) from public.search_recipes(''%_\%'', 10)');
  perform tests.allowed(area, '「\\」だけの検索でもエラーにならない',
                        'select count(*) from public.search_recipes(''\\'', 10)');

  -- =========================================================
  -- 5) 返却件数の上限が効く【転送量対策】
  -- =========================================================
  perform tests.as_owner();
  for i in 1..55 loop
    insert into public.recipes(owner_id, title, is_public, created_at) values (u1, 'bulk' || tok_bulk || i::text, true, now() - interval '1 hour');
  end loop;

  perform tests.as_anon();
  select count(*) into n from public.search_recipes(tok_bulk, 5);
  perform tests.eq(area, '指定した件数(5件)ちょうどで打ち切られる', n, 5);

  select count(*) into n from public.search_recipes(tok_bulk, 1000);
  perform tests.eq(area, '巨大な件数(1000)を指定しても上限50件で頭打ちになる', n, 50);

  select count(*) into n from public.search_recipes(tok_bulk);
  perform tests.eq(area, '件数を省略すると既定の20件だけ返る', n, 20);

  select count(*) into n from public.search_recipes(tok_bulk, null);
  perform tests.eq(area, '件数にnullを渡しても既定の20件になる', n, 20);

  select count(*) into n from public.search_recipes(tok_bulk, 0);
  perform tests.eq(area, '件数0を渡しても最低1件に補正される(0件やエラーにならない)', n, 1);

  select count(*) into n from public.search_recipes(tok_bulk, -3);
  perform tests.eq(area, '件数にマイナスを渡しても最低1件に補正される', n, 1);

  select count(*) into n from public.search_recipes('', 1000);
  perform tests.ok(area, '空文字で検索しても上限50件を超えて返らない', n <= 50,
                   '実際の件数=' || n || '（全件ダンプされている恐れ）');

  -- =========================================================
  -- 6) 内部専用関数が外から実行できないこと（未ログイン）
  -- =========================================================
  perform tests.as_anon();
  perform tests.denied(area, '未ログインは purge_old_events を実行できない',
                       'select public.purge_old_events()', 'permission denied');
  perform tests.denied(area, '未ログインは sync_recipe_paints を実行できない',
                       format('select public.sync_recipe_paints(%L::uuid)', r_title), 'permission denied');
  perform tests.denied(area, '未ログインは purge_unreferenced_images を実行できない',
                       format('select public.purge_unreferenced_images(%L::uuid)', u1), 'permission denied');
  perform tests.denied(area, '未ログインは purge_unreferenced_profile_images を実行できない',
                       format('select public.purge_unreferenced_profile_images(%L::uuid)', u1), 'permission denied');
  perform tests.denied(area, '未ログインは purge_orphan_storage を実行できない',
                       'select public.purge_orphan_storage()', 'permission denied');
  perform tests.denied(area, '未ログインは notify_self（自分宛通知の作成）を実行できない',
                       'select public.notify_self(''system'',''t'',''b'',''l'')', 'permission denied');
  perform tests.denied(area, '未ログインは delete_user（退会）を実行できない',
                       'select public.delete_user()', 'permission denied');
  perform tests.denied(area, '未ログインは set_user_ban（利用停止）を実行できない',
                       format('select public.set_user_ban(%L::uuid, true, null)', u2), 'permission denied');
  perform tests.denied(area, '未ログインは report_summary（通報集計）を実行できない',
                       'select count(*) from public.report_summary(10)', 'permission denied');
  perform tests.denied(area, '未ログインは delete_recipe_with_images を実行できない',
                       format('select public.delete_recipe_with_images(%L::uuid)', r_del), 'permission denied');
  perform tests.denied(area, '未ログインは delete_draft_with_images を実行できない',
                       format('select public.delete_draft_with_images(%L::uuid)', d1), 'permission denied');

  -- =========================================================
  -- 7) 内部専用関数が外から実行できないこと（ログイン済みの一般利用者）
  -- =========================================================
  perform tests.as_user(u2);
  perform tests.denied(area, '一般利用者は purge_old_events を実行できない',
                       'select public.purge_old_events()', 'permission denied');
  perform tests.denied(area, '一般利用者は sync_recipe_paints を実行できない（集計表の改ざん防止）',
                       format('select public.sync_recipe_paints(%L::uuid)', r_title), 'permission denied');
  perform tests.denied(area, '一般利用者は purge_unreferenced_images を実行できない',
                       format('select public.purge_unreferenced_images(%L::uuid)', u1), 'permission denied');
  perform tests.denied(area, '一般利用者は purge_orphan_storage を実行できない',
                       'select public.purge_orphan_storage()', 'permission denied');

  -- =========================================================
  -- 8) is_admin() の判定
  -- =========================================================
  perform tests.as_user(u2);
  select public.is_admin() into b;
  perform tests.eq(area, 'is_admin() は一般利用者に false を返す', b, false);

  perform tests.as_anon();
  select public.is_admin() into b;
  perform tests.eq(area, 'is_admin() は未ログインに false を返す', b, false);

  perform tests.as_user(adm);
  select public.is_admin() into b;
  perform tests.eq(area, 'is_admin() は管理者に true を返す', b, true);

  -- =========================================================
  -- 9) report_summary（通報集計）は管理者以外に中身を返さない
  -- =========================================================
  perform tests.as_user(u2);
  select count(*) into n from public.report_summary(30);
  perform tests.eq(area, 'report_summary は一般利用者には0件しか返さない', n, 0);

  select count(*) into n from public.report_summary(1000);
  perform tests.eq(area, 'report_summary は件数を大きくしても一般利用者には0件', n, 0);

  perform tests.as_user(adm);
  select count(*) into n from public.report_summary(100);
  perform tests.ok(area, 'report_summary は管理者には集計結果を返す', n >= 1,
                   '管理者なのに0件（通報が作れていない可能性）');

  -- =========================================================
  -- 10) set_user_ban（利用停止）の権限確認
  -- =========================================================
  perform tests.as_user(u2);
  perform tests.denied(area, '一般利用者は他人を利用停止にできない',
                       format('select public.set_user_ban(%L::uuid, true, ''test'')', u1), '権限がありません');
  perform tests.as_user(adm);
  perform tests.denied(area, '管理者でも自分自身は利用停止にできない（締め出し防止）',
                       format('select public.set_user_ban(%L::uuid, true, null)', adm), '自分自身');
  perform tests.denied(area, '管理者は他の管理者を利用停止にできない',
                       format('select public.set_user_ban(%L::uuid, true, null)', adm2), '管理者は停止できません');
  perform tests.as_owner();
  select count(*) into n from public.profiles where id in (u1, u2) and banned_at is not null;
  perform tests.eq(area, '上記の拒否テストで誰も実際には停止されていない', n, 0);

  -- =========================================================
  -- 11) delete_recipe_with_images の権限確認
  -- =========================================================
  perform tests.as_user(u2);
  perform tests.denied(area, '他人の投稿を delete_recipe_with_images で消せない',
                       format('select public.delete_recipe_with_images(%L::uuid)', r_del), '権限がありません');
  perform tests.as_owner();
  select count(*) into n from public.recipes where id = r_del;
  perform tests.eq(area, '拒否された後も対象の投稿は残っている', n, 1);

  perform tests.as_user(u1);
  perform tests.allowed(area, '投稿者本人は delete_recipe_with_images で自分の投稿を消せる',
                        format('select public.delete_recipe_with_images(%L::uuid)', r_del));
  perform tests.as_owner();
  select count(*) into n from public.recipes where id = r_del;
  perform tests.eq(area, '本人の削除後は投稿が実際に消えている', n, 0);

  perform tests.as_user(u2);
  perform tests.denied(area, '他人の下書きを delete_draft_with_images で消せない',
                       format('select public.delete_draft_with_images(%L::uuid)', d1), '権限がありません');
  perform tests.as_owner();
  select count(*) into n from public.drafts where id = d1;
  perform tests.eq(area, '拒否された後も対象の下書きは残っている', n, 1);

  -- =========================================================
  -- 12) increment_view（閲覧数）は非公開投稿を増やさない
  -- =========================================================
  perform tests.as_owner();
  select view_count into vc0 from public.recipes where id = r_priv;
  perform tests.as_anon();
  perform tests.allowed(area, '未ログインでも increment_view は呼べる(正規利用が壊れていない)',
                        format('select public.increment_view(%L::uuid)', r_priv));
  perform tests.as_owner();
  select view_count into vc1 from public.recipes where id = r_priv;
  perform tests.eq(area, '非公開投稿は increment_view で閲覧数が増えない', vc1, vc0);

  select view_count into vc0 from public.recipes where id = r_title;
  perform tests.as_anon();
  perform tests.allowed(area, '公開投稿への increment_view は成功する',
                        format('select public.increment_view(%L::uuid)', r_title));
  perform tests.as_owner();
  select view_count into vc1 from public.recipes where id = r_title;
  perform tests.eq(area, '公開投稿は increment_view で閲覧数が1増える', vc1, vc0 + 1);

  -- =========================================================
  -- 13) 集計関数（ランキング）が非公開レシピを漏らさない
  -- =========================================================
  perform tests.as_anon();
  select count(*) into n from public.popular_methods(1000) m where m.method = tok_priv || 'メソッド';
  perform tests.eq(area, '人気の塗装方法に非公開レシピのタグが混ざらない', n, 0);

  select count(*) into n from public.popular_methods(1000) m where m.method = tok_tag;
  perform tests.eq(area, '人気の塗装方法に公開レシピのタグは集計される(空振りでない証拠)', n, 1);

  select count(*) into n from public.popular_paints(2000) p where p.label = tok_priv || '塗料';
  perform tests.eq(area, '定番塗料に非公開レシピの塗料が混ざらない', n, 0);

  select count(*) into n from public.popular_paints(2000) p where p.label = tok_paint;
  perform tests.eq(area, '定番塗料に公開レシピの塗料は集計される(空振りでない証拠)', n, 1);

  select count(*) into n from public.rising_paints(2000) p where p.label = tok_priv || '塗料';
  perform tests.eq(area, '急上昇塗料に非公開レシピの塗料が混ざらない', n, 0);

  perform tests.allowed(area, '未ログインでもランキング3種は呼べる(正規利用が壊れていない)',
                        'select count(*) from public.popular_paints(3), public.rising_paints(3), public.popular_methods(3)');

  -- =========================================================
  -- 後片付け（失敗しても止めない）
  -- =========================================================
  begin
    perform tests.as_owner();
    perform tests.cleanup_users(array[u1, u2, adm, adm2]);
  exception when others then null;
  end;
  begin
    perform tests.as_owner();
  exception when others then null;
  end;
end $$;
