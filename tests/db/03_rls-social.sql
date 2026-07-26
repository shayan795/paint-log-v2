-- RLS:通知・保存・通報 のテスト（自動生成・dev専用）
do $$
declare
  ar   text := 'RLS:通知・保存・通報';
  ua uuid; ub uuid; uc uuid; ud uuid; adm uuid;
  ra uuid; rb uuid;
  n  int;
  t0 timestamptz;
  ts1 timestamptz;
  nid_a bigint; nid_b bigint;
  rep1 bigint;
  inq_b bigint; inq_gone bigint;
begin
  ---------------------------------------------------------------------------
  -- 下準備（すべて特権状態で作る＝auth.uid()がnullなので連投制限に当たらない）
  ---------------------------------------------------------------------------
  perform tests.as_owner();
  t0  := now();
  ua  := tests.make_user();        -- 投稿者A
  ub  := tests.make_user();        -- 一般B（保存・通報・問い合わせをする人）
  uc  := tests.make_user();        -- 一般C（第三者）
  ud  := tests.make_user();        -- 停止(BAN)される人
  adm := tests.make_user(true);    -- 管理者

  insert into public.recipes(owner_id, title, is_public, created_at) values (ua, 'テスト投稿A', true, now() - interval '1 hour') returning id into ra;
  insert into public.recipes(owner_id, title, is_public, created_at) values (ub, 'テスト投稿B', true, now() - interval '1 hour') returning id into rb;

  insert into public.notifications(user_id, type, title, body, link)
    values (ua, 'system', 'A宛のテスト通知', '本文A', 'index.html') returning id into nid_a;
  insert into public.notifications(user_id, type, title, body, link)
    values (ub, 'system', 'B宛のテスト通知', '本文B', 'index.html') returning id into nid_b;

  ---------------------------------------------------------------------------
  -- 1) notifications（通知）の閲覧
  ---------------------------------------------------------------------------
  perform tests.as_user(ub);

  n := 1;
  begin select count(*)::int into n from public.notifications where id = nid_a;
  exception when others then n := 0; end;
  perform tests.eq(ar, '他人宛の通知は1件も読めない', n, 0);

  n := -1;
  begin select count(*)::int into n from public.notifications where id = nid_b;
  exception when others then n := -1; end;
  perform tests.eq(ar, '自分宛の通知は読める', n, 1);

  n := -1;
  begin select count(*)::int into n from public.notifications where user_id = ua and title = 'A宛のテスト通知';
  exception when others then n := -1; end;
  perform tests.eq(ar, '他人のIDを指定して通知を検索しても漏れない', n, 0);

  perform tests.as_anon();
  n := 1;
  begin select count(*)::int into n from public.notifications where id in (nid_a, nid_b);
  exception when others then n := 0; end;
  perform tests.eq(ar, '未ログインでは通知を一切読めない', n, 0);

  ---------------------------------------------------------------------------
  -- 2) notifications の作成（直接INSERTは誰にも許されていない）
  ---------------------------------------------------------------------------
  perform tests.as_user(ub);
  perform tests.denied(ar, '他人宛の通知を勝手に作れない',
    format('insert into public.notifications(user_id,type,title,body) values (%L,%L,%L,%L)',
           ua, 'system', 'なりすまし通知', '本文'), 'notifications');
  perform tests.denied(ar, '自分宛でも通知テーブルへ直接は書き込めない',
    format('insert into public.notifications(user_id,type,title,body) values (%L,%L,%L,%L)',
           ub, 'system', '自作自演通知', '本文'), 'notifications');

  perform tests.allowed(ar, '専用RPC(notify_self)なら自分宛の通知を作れる',
    format('select public.notify_self(%L,%L,%L,%L)', 'system', '自分宛RPCテスト', '本文', 'index.html'));
  n := -1;
  begin select count(*)::int into n from public.notifications where user_id = ub and title = '自分宛RPCテスト';
  exception when others then n := -1; end;
  perform tests.eq(ar, 'notify_selfで作られた通知の宛先は必ず自分になる', n, 1);

  perform tests.as_anon();
  perform tests.denied(ar, '未ログインではnotify_selfを実行できない',
    format('select public.notify_self(%L,%L,%L,%L)', 'system', '匿名RPC', '本文', 'index.html'), 'notify_self');

  ---------------------------------------------------------------------------
  -- 3) notifications の更新（既読）・削除
  ---------------------------------------------------------------------------
  perform tests.as_user(ub);
  perform tests.affects(ar, '自分の通知は既読にできる',
    format('update public.notifications set read_at = now() where id = %s', nid_b), 1);
  perform tests.affects(ar, '他人の通知は既読にできない（0件しか動かない）',
    format('update public.notifications set read_at = now() where id = %s', nid_a), 0);
  perform tests.affects(ar, '他人の通知をまとめて既読にする攻撃も0件で終わる',
    format('update public.notifications set read_at = now() where user_id = %L', ua), 0);
  perform tests.denied(ar, '自分の通知の宛先を他人に付け替えられない',
    format('update public.notifications set user_id = %L where id = %s', ua, nid_b), 'notifications');

  perform tests.affects(ar, '通知の作成日時の書き換えは実行できる（値は戻される）',
    format('update public.notifications set created_at = now() - interval ''1 year'' where id = %s', nid_b), 1);
  perform tests.as_owner();
  select created_at into ts1 from public.notifications where id = nid_b;
  perform tests.ok(ar, '通知の作成日時を1年前に偽装できない', ts1 >= t0,
    '作成日時=' || coalesce(ts1::text, 'null'));

  perform tests.as_user(ub);
  perform tests.affects(ar, '他人の通知は削除できない（0件しか動かない）',
    format('delete from public.notifications where id = %s', nid_a), 0);
  perform tests.affects(ar, '自分の通知は削除できる',
    format('delete from public.notifications where id = %s', nid_b), 1);

  ---------------------------------------------------------------------------
  -- 4) clips（保存）と保存通知
  ---------------------------------------------------------------------------
  perform tests.allowed(ar, '自分名義なら投稿を保存できる',
    format('insert into public.clips(user_id,recipe_id) values (%L,%L)', ub, ra));

  perform tests.as_owner();
  n := -1;
  select count(*)::int into n from public.notifications where user_id = ua and type = 'saved';
  perform tests.eq(ar, '保存されると投稿者に通知が1件届く', n, 1);

  perform tests.as_user(ub);
  perform tests.affects(ar, '自分の保存は解除できる',
    format('delete from public.clips where user_id = %L and recipe_id = %L', ub, ra), 1);
  perform tests.allowed(ar, '解除した投稿をもう一度保存できる',
    format('insert into public.clips(user_id,recipe_id) values (%L,%L)', ub, ra));
  perform tests.as_owner();
  n := -1;
  select count(*)::int into n from public.notifications where user_id = ua and type = 'saved';
  perform tests.eq(ar, '同じ人が保存し直しても通知は増えない(clip_notified)', n, 1);

  perform tests.as_user(ub);
  perform tests.denied(ar, '他人名義の保存は作れない',
    format('insert into public.clips(user_id,recipe_id) values (%L,%L)', ua, rb), 'clips');
  perform tests.as_anon();
  perform tests.denied(ar, '未ログインでは保存できない',
    format('insert into public.clips(user_id,recipe_id) values (%L,%L)', ub, rb), 'clips');

  perform tests.as_user(ua);
  n := 1;
  begin select count(*)::int into n from public.clips where user_id = ub;
  exception when others then n := 0; end;
  perform tests.eq(ar, '他人が何を保存したかは見えない', n, 0);
  perform tests.affects(ar, '他人の保存を勝手に解除できない（0件しか動かない）',
    format('delete from public.clips where user_id = %L and recipe_id = %L', ub, ra), 0);
  perform tests.affects(ar, '他人の保存を書き換えられない（0件しか動かない）',
    format('update public.clips set recipe_id = %L where user_id = %L', rb, ub), 0);

  perform tests.as_user(ub);
  n := -1;
  begin select count(*)::int into n from public.clips where user_id = ub and recipe_id = ra;
  exception when others then n := -1; end;
  perform tests.eq(ar, '自分の保存は自分で見える', n, 1);
  perform tests.denied(ar, '内部管理表clip_notifiedはクライアントから読めない',
    'select count(*) from public.clip_notified', 'clip_notified');

  perform tests.as_user(uc);
  perform tests.allowed(ar, '別の利用者も同じ投稿を保存できる',
    format('insert into public.clips(user_id,recipe_id) values (%L,%L)', uc, ra));
  perform tests.as_owner();
  n := -1;
  select count(*)::int into n from public.notifications where user_id = ua and type = 'saved';
  perform tests.eq(ar, '別の人が保存した時はきちんと通知が届く', n, 2);

  perform tests.as_user(ua);
  perform tests.allowed(ar, '自分の投稿を自分で保存できる',
    format('insert into public.clips(user_id,recipe_id) values (%L,%L)', ua, ra));
  perform tests.as_owner();
  n := -1;
  select count(*)::int into n from public.notifications where user_id = ua and type = 'saved';
  perform tests.eq(ar, '自分の投稿を自分で保存しても自分に通知は来ない', n, 2);

  ---------------------------------------------------------------------------
  -- 5) reports（通報）
  ---------------------------------------------------------------------------
  perform tests.as_user(ub);
  perform tests.allowed(ar, '本人名義なら通報できる',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,%L,%L)',
           ra, ub, 'スパム', 'テスト通報'));
  perform tests.denied(ar, '30秒以内の連続通報は拒否される',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,%L,%L)',
           ra, ub, 'スパム', '連投テスト'), '通報が連続しています');

  perform tests.as_owner();
  select id into rep1 from public.reports where reporter_id = ub order by id desc limit 1;
  n := -1;
  select count(*)::int into n from public.notifications where user_id = adm and type = 'new_report';
  perform tests.eq(ar, '通報が入ると管理者に通知が届く', n, 1);

  perform tests.as_user(uc);
  perform tests.denied(ar, '他人名義（なりすまし）の通報は作れない',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,%L,%L)',
           ra, ua, 'スパム', 'なりすまし通報'), 'reports');
  perform tests.as_anon();
  perform tests.denied(ar, '未ログインでは通報できない',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,%L,%L)',
           ra, ua, 'スパム', '匿名通報'), 'reports');
  n := 1;
  begin select count(*)::int into n from public.reports;
  exception when others then n := 0; end;
  perform tests.eq(ar, '未ログインでは通報の中身が見えない', n, 0);

  perform tests.as_user(uc);
  n := 1;
  begin select count(*)::int into n from public.reports;
  exception when others then n := 0; end;
  perform tests.eq(ar, '一般利用者には通報の中身が見えない', n, 0);
  perform tests.affects(ar, '一般利用者は通報の状態を変えられない（0件しか動かない）',
    format('update public.reports set status = ''reviewed'' where id = %s', rep1), 0);
  perform tests.affects(ar, '一般利用者は通報を消せない（0件しか動かない）',
    format('delete from public.reports where id = %s', rep1), 0);

  perform tests.as_user(ub);
  n := 1;
  begin select count(*)::int into n from public.reports where id = rep1;
  exception when others then n := 0; end;
  perform tests.eq(ar, '通報した本人ですら自分の通報を読み返せない（管理者専用）', n, 0);

  perform tests.as_user(adm);
  n := -1;
  begin select count(*)::int into n from public.reports where recipe_id = ra;
  exception when others then n := -1; end;
  perform tests.eq(ar, '管理者は通報を読める', n, 1);
  perform tests.affects(ar, '管理者は通報を確認済みにできる',
    format('update public.reports set status = ''reviewed'' where id = %s', rep1), 1);

  perform tests.as_owner();
  n := -1;
  select count(*)::int into n from public.notifications where user_id = ua and type = 'report_reviewed';
  perform tests.eq(ar, '通報が確認済みになると投稿者へ通知が届く', n, 1);
  update public.profiles set banned_at = now(), banned_reason = 'テスト' where id = ud;

  perform tests.as_user(ud);
  perform tests.denied(ar, '利用停止(BAN)中の人は通報できない',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,%L,%L)',
           ra, ud, 'スパム', 'BANテスト'), 'ご利用を停止しています');

  perform tests.as_user(adm);
  perform tests.affects(ar, '管理者は通報を削除できる',
    format('delete from public.reports where id = %s', rep1), 1);

  ---------------------------------------------------------------------------
  -- 6) inquiries（お問い合わせ）
  ---------------------------------------------------------------------------
  perform tests.as_user(ub);
  perform tests.allowed(ar, '本人名義ならお問い合わせを送れる',
    format('insert into public.inquiries(user_id,category,body) values (%L,%L,%L)', ub, 'バグ報告', 'テスト問い合わせ'));
  perform tests.denied(ar, '60秒以内の連続したお問い合わせは拒否される',
    format('insert into public.inquiries(user_id,category,body) values (%L,%L,%L)', ub, 'バグ報告', '連投テスト'),
    'お問い合わせが連続しています');

  perform tests.as_owner();
  select id into inq_b from public.inquiries where user_id = ub order by id desc limit 1;
  n := -1;
  select count(*)::int into n from public.notifications where user_id = adm and type = 'new_inquiry';
  perform tests.eq(ar, 'お問い合わせが入ると管理者に通知が届く', n, 1);

  perform tests.as_user(uc);
  perform tests.denied(ar, '他人名義のお問い合わせは送れない',
    format('insert into public.inquiries(user_id,category,body) values (%L,%L,%L)', ua, 'バグ報告', 'なりすまし'),
    'inquiries');
  n := 1;
  begin select count(*)::int into n from public.inquiries;
  exception when others then n := 0; end;
  perform tests.eq(ar, '一般利用者にはお問い合わせの中身が見えない', n, 0);
  perform tests.affects(ar, '一般利用者はお問い合わせの状態を変えられない（0件しか動かない）',
    format('update public.inquiries set status = ''reviewed'' where id = %s', inq_b), 0);
  perform tests.affects(ar, '一般利用者はお問い合わせを消せない（0件しか動かない）',
    format('delete from public.inquiries where id = %s', inq_b), 0);

  perform tests.as_anon();
  perform tests.denied(ar, '未ログインではお問い合わせを送れない',
    format('insert into public.inquiries(user_id,category,body) values (%L,%L,%L)', ua, 'バグ報告', '匿名問い合わせ'),
    'inquiries');
  n := 1;
  begin select count(*)::int into n from public.inquiries;
  exception when others then n := 0; end;
  perform tests.eq(ar, '未ログインではお問い合わせの中身が見えない', n, 0);

  perform tests.as_user(ub);
  n := 1;
  begin select count(*)::int into n from public.inquiries where id = inq_b;
  exception when others then n := 0; end;
  perform tests.eq(ar, '送った本人ですら自分のお問い合わせを読み返せない（管理者専用）', n, 0);

  perform tests.as_user(adm);
  n := -1;
  begin select count(*)::int into n from public.inquiries where id = inq_b;
  exception when others then n := -1; end;
  perform tests.eq(ar, '管理者はお問い合わせを読める', n, 1);
  perform tests.affects(ar, '管理者はお問い合わせを対応済みにできる',
    format('update public.inquiries set status = ''reviewed'' where id = %s', inq_b), 1);

  perform tests.as_owner();
  n := -1;
  select count(*)::int into n from public.notifications where user_id = ub and type = 'inquiry_replied';
  perform tests.eq(ar, '対応済みにすると送信者へ通知が届く', n, 1);

  -- 退会済み（user_id が NULL になった）お問い合わせ
  insert into public.inquiries(user_id, category, body) values (uc, 'その他', '退会者テスト') returning id into inq_gone;
  update public.inquiries set user_id = null where id = inq_gone;
  perform tests.as_user(adm);
  perform tests.affects(ar, '退会済み利用者のお問い合わせも対応済みにできる（エラーにならない）',
    format('update public.inquiries set status = ''reviewed'' where id = %s', inq_gone), 1);
  perform tests.as_owner();
  n := -1;
  select count(*)::int into n from public.notifications where type = 'inquiry_replied' and created_at >= t0;
  perform tests.eq(ar, '退会済みへの返信通知は作られない（通知は1件のまま）', n, 1);

  ---------------------------------------------------------------------------
  -- 後片付け（失敗しても止めない）
  ---------------------------------------------------------------------------
  begin
    perform tests.as_owner();
    delete from public.inquiries where id in (inq_b, inq_gone);
    delete from public.reports    where reporter_id = any(array[ua, ub, uc, ud]);
    delete from public.clip_notified where clipper_id = any(array[ua, ub, uc, ud]);
    delete from public.notifications
      where created_at >= t0
        and type in ('new_report', 'new_inquiry')
        and user_id <> all (array[ua, ub, uc, ud, adm]);
    perform tests.cleanup_users(array[ua, ub, uc, ud, adm]);
  exception when others then null;
  end;
end $$;
