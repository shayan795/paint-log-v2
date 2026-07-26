-- RLS:投稿 のテスト（自動生成・dev専用）
do $$
declare
  ua uuid; ub uuid; adm uuid; uc uuid; ud uuid;
  r_pub_a uuid; r_priv_a uuid; r_pub_b uuid; r_priv_b uuid;
  r_own_x uuid; r_del_own uuid; r_del_adm uuid;
  d_a uuid; d_b uuid; d_del uuid;
  n int; v boolean;
begin
  -- ============ 下準備（すべて特権状態で作る） ============
  perform tests.as_owner();
  ua  := tests.make_user();        -- 本人（Aさん）
  ub  := tests.make_user();        -- 他人（Bさん）
  adm := tests.make_user(true);    -- 管理者
  uc  := tests.make_user();        -- 投稿レート制限にかからない新規ユーザー（許可テスト用）
  ud  := tests.make_user();        -- 偽装INSERTを試すユーザー

  insert into public.recipes(owner_id, title, is_public, created_at) values (ua, 'A公開投稿',   true, now() - interval '1 hour')  returning id into r_pub_a;
  insert into public.recipes(owner_id, title, is_public, created_at) values (ua, 'A非公開投稿', false, now() - interval '1 hour') returning id into r_priv_a;
  insert into public.recipes(owner_id, title, is_public, created_at) values (ub, 'B公開投稿',   true, now() - interval '1 hour')  returning id into r_pub_b;
  insert into public.recipes(owner_id, title, is_public, created_at) values (ub, 'B非公開投稿', false, now() - interval '1 hour') returning id into r_priv_b;
  insert into public.recipes(owner_id, title, is_public, created_at) values (ua, 'A更新用',     false, now() - interval '1 hour') returning id into r_own_x;
  insert into public.recipes(owner_id, title, is_public, created_at) values (ua, 'A削除用',     true, now() - interval '1 hour')  returning id into r_del_own;
  insert into public.recipes(owner_id, title, is_public, created_at) values (ub, 'B削除用(管理者が消す)', true, now() - interval '1 hour') returning id into r_del_adm;

  insert into public.drafts(owner_id, title) values (ua, 'Aの下書き')     returning id into d_a;
  insert into public.drafts(owner_id, title) values (ub, 'Bの下書き')     returning id into d_b;
  insert into public.drafts(owner_id, title) values (ua, 'A削除用下書き') returning id into d_del;

  -- ============ 1. SELECT（読み取り）============
  perform tests.as_anon();
  select count(*) into n from public.recipes where id = r_pub_a;
  perform tests.eq('RLS:投稿','未ログインでも公開投稿は読める', n, 1);

  select count(*) into n from public.recipes where id = r_priv_a;
  perform tests.eq('RLS:投稿','未ログインでは他人の非公開投稿は読めない', n, 0);

  select count(*) into n from public.recipes where id in (r_pub_a, r_priv_a, r_pub_b, r_priv_b);
  perform tests.eq('RLS:投稿','未ログインの一覧には公開投稿2件だけが出る（非公開は混ざらない）', n, 2);

  perform tests.as_user(ua);
  select count(*) into n from public.recipes where id = r_priv_a;
  perform tests.eq('RLS:投稿','本人は自分の非公開投稿を読める', n, 1);

  select count(*) into n from public.recipes where id = r_pub_a;
  perform tests.eq('RLS:投稿','本人は自分の公開投稿を読める', n, 1);

  select count(*) into n from public.recipes where id in (r_pub_a, r_priv_a, r_pub_b, r_priv_b);
  perform tests.eq('RLS:投稿','本人の一覧は「自分の全部＋他人の公開」の3件になる', n, 3);

  perform tests.as_user(ub);
  select count(*) into n from public.recipes where id = r_pub_a;
  perform tests.eq('RLS:投稿','ログイン中の他人でも公開投稿は読める', n, 1);

  select count(*) into n from public.recipes where id = r_priv_a;
  perform tests.eq('RLS:投稿','ログイン中の他人は他人の非公開投稿を読めない', n, 0);

  perform tests.as_user(adm);
  select count(*) into n from public.recipes where id = r_priv_a;
  perform tests.eq('RLS:投稿','管理者でも他人の非公開投稿は読めない（読み取りに管理者例外は無い）', n, 0);

  -- ============ 2. INSERT（作成）============
  perform tests.as_user(uc);
  perform tests.allowed('RLS:投稿','本人名義（owner_id=自分）の投稿は作成できる',
    format('insert into public.recipes(owner_id,title,is_public, created_at) values (%L,%L,false)', uc, '自分名義の投稿'), now() - interval '1 hour');

  perform tests.as_user(ud);
  perform tests.denied('RLS:投稿','owner_idを他人に偽装した投稿は作成できない',
    format('insert into public.recipes(owner_id,title,is_public, created_at) values (%L,%L,false)', ua, '他人になりすました投稿'),
    'row-level security', now() - interval '1 hour');

  perform tests.denied('RLS:投稿','owner_idを他人に偽装した「公開」投稿も作成できない',
    format('insert into public.recipes(owner_id,title,is_public, created_at) values (%L,%L,true)', ub, '他人名義の公開投稿'),
    'row-level security', now() - interval '1 hour');

  perform tests.as_user(adm);
  perform tests.denied('RLS:投稿','管理者でも他人名義の投稿は作成できない',
    format('insert into public.recipes(owner_id,title,is_public, created_at) values (%L,%L,false)', ua, '管理者による他人名義投稿'),
    'row-level security', now() - interval '1 hour');

  perform tests.as_anon();
  perform tests.denied('RLS:投稿','未ログインでは投稿を作成できない',
    format('insert into public.recipes(owner_id,title,is_public, created_at) values (%L,%L,true)', ua, '匿名からの投稿'), now() - interval '1 hour');

  -- ============ 3. UPDATE（更新）============
  perform tests.as_user(ua);
  perform tests.affects('RLS:投稿','本人は自分の投稿の題名を更新できる（1件反映）',
    format('update public.recipes set title=%L where id=%L', '題名を変更しました', r_own_x), 1);

  perform tests.affects('RLS:投稿','本人は自分の投稿の公開/非公開を切り替えられる（1件反映）',
    format('update public.recipes set is_public=true where id=%L', r_own_x), 1);

  perform tests.denied('RLS:投稿','自分の投稿でもowner_idを他人に付け替えることはできない',
    format('update public.recipes set owner_id=%L where id=%L', ub, r_own_x),
    'row-level security');

  perform tests.as_user(ub);
  perform tests.affects('RLS:投稿','他人の公開投稿の題名は更新できない（0件）',
    format('update public.recipes set title=%L where id=%L', '乗っ取り題名', r_pub_a), 0);

  perform tests.affects('RLS:投稿','他人の非公開投稿は更新できない（0件）',
    format('update public.recipes set title=%L where id=%L', '乗っ取り題名', r_priv_a), 0);

  perform tests.affects('RLS:投稿','他人の非公開投稿を勝手に公開に変えられない（0件）',
    format('update public.recipes set is_public=true where id=%L', r_priv_a), 0);

  perform tests.affects('RLS:投稿','他人の公開投稿を勝手に非公開に変えられない（0件）',
    format('update public.recipes set is_public=false where id=%L', r_pub_a), 0);

  perform tests.affects('RLS:投稿','他人の投稿の本文(grid)を書き換えられない（0件）',
    format('update public.recipes set grid=%L::jsonb where id=%L', '{"hacked":true}', r_pub_a), 0);

  perform tests.affects('RLS:投稿','他人の投稿のコメント許可設定を変えられない（0件）',
    format('update public.recipes set comments_disabled=true where id=%L', r_pub_a), 0);

  perform tests.affects('RLS:投稿','他人の投稿のowner_idを自分に付け替えて奪えない（0件）',
    format('update public.recipes set owner_id=%L where id=%L', ub, r_pub_a), 0);

  perform tests.as_user(adm);
  perform tests.affects('RLS:投稿','管理者でも他人の投稿は更新できない（0件）',
    format('update public.recipes set title=%L where id=%L', '管理者による改変', r_pub_a), 0);

  perform tests.as_anon();
  perform tests.affects('RLS:投稿','未ログインでは投稿を更新できない（0件）',
    format('update public.recipes set title=%L where id=%L', '匿名による改変', r_pub_a), 0);

  -- 上の攻撃がすべて空振りしていることを実データで確認
  perform tests.as_owner();
  select is_public into v from public.recipes where id = r_priv_a;
  perform tests.eq('RLS:投稿','攻撃後もA非公開投稿は非公開のまま', v, false);
  select count(*) into n from public.recipes where id = r_pub_a and title = 'A公開投稿' and owner_id = ua;
  perform tests.eq('RLS:投稿','攻撃後もA公開投稿の題名と所有者は元のまま', n, 1);

  -- ============ 4. DELETE（削除）============
  perform tests.as_user(ub);
  perform tests.affects('RLS:投稿','他人の公開投稿は削除できない（0件）',
    format('delete from public.recipes where id=%L', r_pub_a), 0);

  perform tests.affects('RLS:投稿','他人の非公開投稿は削除できない（0件）',
    format('delete from public.recipes where id=%L', r_priv_a), 0);

  perform tests.denied('RLS:投稿','他人の投稿は削除RPC(delete_recipe_with_images)でも削除できない',
    format('select public.delete_recipe_with_images(%L)', r_pub_a),
    '権限がありません');

  perform tests.as_anon();
  perform tests.affects('RLS:投稿','未ログインでは投稿を削除できない（0件）',
    format('delete from public.recipes where id=%L', r_pub_a), 0);

  perform tests.as_user(ua);
  perform tests.affects('RLS:投稿','本人は自分の投稿を削除できる（1件反映）',
    format('delete from public.recipes where id=%L', r_del_own), 1);

  perform tests.as_user(adm);
  perform tests.affects('RLS:投稿','管理者は通報対応として他人の投稿を削除できる（1件反映）',
    format('delete from public.recipes where id=%L', r_del_adm), 1);

  -- ============ 5. drafts（下書き）============
  perform tests.as_user(ua);
  select count(*) into n from public.drafts where id = d_a;
  perform tests.eq('RLS:投稿','下書き: 本人は自分の下書きを読める', n, 1);

  select count(*) into n from public.drafts where id = d_b;
  perform tests.eq('RLS:投稿','下書き: 他人の下書きは読めない', n, 0);

  perform tests.as_user(ub);
  select count(*) into n from public.drafts where id = d_a;
  perform tests.eq('RLS:投稿','下書き: 別の他人から見ても下書きは見えない', n, 0);

  perform tests.as_user(adm);
  select count(*) into n from public.drafts where id = d_a;
  perform tests.eq('RLS:投稿','下書き: 管理者でも他人の下書きは読めない', n, 0);

  perform tests.as_anon();
  select count(*) into n from public.drafts where id in (d_a, d_b, d_del);
  perform tests.eq('RLS:投稿','下書き: 未ログインでは下書きを1件も読めない', n, 0);

  perform tests.denied('RLS:投稿','下書き: 未ログインでは下書きを作成できない',
    format('insert into public.drafts(owner_id,title) values (%L,%L)', ua, '匿名の下書き'));

  perform tests.affects('RLS:投稿','下書き: 未ログインでは下書きを更新できない（0件）',
    format('update public.drafts set title=%L where id=%L', '匿名による改変', d_a), 0);

  perform tests.as_user(ua);
  perform tests.allowed('RLS:投稿','下書き: 本人名義の下書きは作成できる',
    format('insert into public.drafts(owner_id,title) values (%L,%L)', ua, '自分の新しい下書き'));

  perform tests.denied('RLS:投稿','下書き: owner_idを他人に偽装した下書きは作成できない',
    format('insert into public.drafts(owner_id,title) values (%L,%L)', ub, '他人名義の下書き'),
    'row-level security');

  perform tests.denied('RLS:投稿','下書き: 自分の下書きのowner_idを他人に付け替えられない',
    format('update public.drafts set owner_id=%L where id=%L', ub, d_a),
    'row-level security');

  perform tests.affects('RLS:投稿','下書き: 他人の下書きは更新できない（0件）',
    format('update public.drafts set title=%L where id=%L', '乗っ取り下書き', d_b), 0);

  perform tests.affects('RLS:投稿','下書き: 他人の下書きは削除できない（0件）',
    format('delete from public.drafts where id=%L', d_b), 0);

  perform tests.denied('RLS:投稿','下書き: 他人の下書きは削除RPC(delete_draft_with_images)でも削除できない',
    format('select public.delete_draft_with_images(%L)', d_b),
    '権限がありません');

  perform tests.affects('RLS:投稿','下書き: 本人は自分の下書きを削除できる（1件反映）',
    format('delete from public.drafts where id=%L', d_del), 1);

  perform tests.as_user(adm);
  perform tests.affects('RLS:投稿','下書き: 管理者でも他人の下書きは削除できない（0件）',
    format('delete from public.drafts where id=%L', d_a), 0);

  perform tests.as_owner();
  select count(*) into n from public.drafts where id = d_a;
  perform tests.eq('RLS:投稿','下書き: 一連の攻撃後もAの下書きは無事に残っている', n, 1);

  -- ============ 後片付け ============
  begin
    perform tests.as_owner();
    perform tests.cleanup_users(array[ua, ub, adm, uc, ud]);
  exception when others then null;
  end;
end $$;
