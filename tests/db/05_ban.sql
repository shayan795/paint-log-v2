-- 停止(BAN) のテスト（自動生成・dev専用）
do $$
declare
  area_name constant text := '停止(BAN)';
  u1 uuid; u2 uuid; u3 uuid; u4 uuid; adm uuid; adm2 uuid;
  r_pub   uuid := gen_random_uuid();
  r_priv  uuid := gen_random_uuid();
  r_del   uuid := gen_random_uuid();
  r_other uuid := gen_random_uuid();
  d1      uuid := gen_random_uuid();
  ghost   uuid := gen_random_uuid();
  c1 bigint;
  cnt int; b boolean; t text; ts timestamptz;
begin
  -- ================= 下準備（すべて特権状態で作る） =================
  perform tests.as_owner();
  u1   := tests.make_user();        -- 停止される利用者
  u2   := tests.make_user();        -- 停止されない一般利用者
  u3   := tests.make_user();        -- 停止中の退会テスト用
  u4   := tests.make_user();        -- 理由を省略した停止のテスト用
  adm  := tests.make_user(true);    -- 管理者
  adm2 := tests.make_user(true);    -- もう1人の管理者

  insert into public.recipes(id, owner_id, title, grid, is_public, created_at) values
    (r_pub,   u1, '停止テスト用の公開投稿',   '{}'::jsonb, true,  now() - interval '2 hours'),
    (r_priv,  u1, '停止テスト用の非公開投稿', '{}'::jsonb, false, now() - interval '2 hours'),
    (r_del,   u1, '停止中に削除する投稿',     '{}'::jsonb, false, now() - interval '2 hours'),
    (r_other, u2, '他の利用者の公開投稿',     '{}'::jsonb, true,  now() - interval '2 hours');

  insert into public.drafts(id, owner_id, title, grid)
    values (d1, u1, '停止テスト用の下書き', '{}'::jsonb);

  insert into public.comments(recipe_id, user_id, body, created_at)
    values (r_other, u1, '編集テスト用のコメントです', now() - interval '1 hour')
    returning id into c1;

  insert into public.reports(recipe_id, reporter_id, reason, detail, created_at)
    values (r_pub, u2, 'テスト', '通報サマリ確認用', now() - interval '1 hour');

  -- ================= 1) 停止前の状態 =================
  perform tests.ok(area_name, '停止していない利用者は is_banned が false',
    public.is_banned(u1) = false, '停止していないのに停止中と判定されています');

  perform tests.as_user(u2);
  perform tests.allowed(area_name, '停止されていない利用者はふつうに投稿できる（前提確認）',
    format('insert into public.recipes(owner_id,title,grid,is_public, created_at) values (%L,%L,%L::jsonb,false, now() - interval ''1 hour'')',
           u2, '前提確認の投稿', '{}'));

  -- ================= 2) 管理者による停止 =================
  perform tests.as_user(adm);
  perform tests.allowed(area_name, '管理者は一般利用者を停止できる',
    format('select public.set_user_ban(%L::uuid, true, %L)', u1, '荒らし行為のため'));

  perform tests.as_owner();
  select banned_at, banned_reason into ts, t from public.profiles where id = u1;
  perform tests.ok(area_name, '停止すると profiles.banned_at に時刻が記録される',
    ts is not null, 'banned_at が null のままです');
  perform tests.eq(area_name, '停止理由が profiles.banned_reason に保存される', t, '荒らし行為のため'::text);
  perform tests.eq(area_name, 'is_banned(対象ID) が true を返す', public.is_banned(u1), true);

  perform tests.as_user(u1);
  select public.is_banned() into b;
  perform tests.eq(area_name, '本人が引数なしで is_banned() を呼ぶと true が返る', b, true);

  -- ================= 3) 停止中は新規作成ができない =================
  perform tests.denied(area_name, '停止中は新しい投稿(recipes)を作成できない',
    format('insert into public.recipes(owner_id,title,grid,is_public, created_at) values (%L,%L,%L::jsonb,false, now() - interval ''1 hour'')',
           u1, '停止中に作ろうとした投稿', '{}'),
    'ご利用を停止しています');

  perform tests.denied(area_name, '停止中は新しい下書き(drafts)を作成できない',
    format('insert into public.drafts(owner_id,title,grid) values (%L,%L,%L::jsonb)',
           u1, '停止中に作ろうとした下書き', '{}'),
    'ご利用を停止しています');

  perform tests.denied(area_name, '停止中は新しいコメントを投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           r_other, u1, '停止中に書こうとしたコメント'),
    'ご利用を停止しています');

  perform tests.denied(area_name, '停止中は新しい通報(reports)を送信できない',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,%L,%L)',
           r_other, u1, 'スパム', '停止中に送ろうとした通報'),
    'ご利用を停止しています');

  -- ================= 4) 停止中でも既存データの閲覧・編集はできる =================
  select count(*)::int into cnt from public.recipes where owner_id = u1;
  perform tests.eq(area_name, '停止中でも自分の投稿（公開・非公開とも）を閲覧できる', cnt, 3);

  perform tests.affects(area_name, '停止中でも自分の投稿を編集できる',
    format('update public.recipes set title = %L where id = %L', '停止中に編集したタイトル', r_pub), 1);

  perform tests.affects(area_name, '停止中でも自分の投稿を削除できる',
    format('delete from public.recipes where id = %L', r_del), 1);

  perform tests.affects(area_name, '停止中でも自分の下書きを編集できる',
    format('update public.drafts set title = %L where id = %L', '停止中に編集した下書き', d1), 1);

  perform tests.affects(area_name, '停止中でも自分の既存コメントは編集できる（新規投稿のみ制限）',
    format('update public.comments set body = %L where id = %s', '停止中に編集したコメント', c1), 1);

  perform tests.affects(area_name, '停止中でも自分のプロフィール（表示名）は変更できる',
    format('update public.profiles set display_name = %L where id = %L', '停止中の表示名', u1), 1);

  perform tests.allowed(area_name, '停止中でもお問い合わせは送れる（停止理由を問い合わせる導線を残すため）',
    format('insert into public.inquiries(user_id,category,body) values (%L,%L,%L)',
           u1, 'その他', '停止理由を教えてください'));

  perform tests.allowed(area_name, '停止中でも他人の投稿のクリップ保存は妨げられない（制限対象は4種類のみ）',
    format('insert into public.clips(user_id,recipe_id) values (%L,%L)', u1, r_other));

  -- ================= 5) 停止の通知 =================
  select count(*)::int into cnt from public.notifications
   where user_id = u1 and type = 'system' and title = 'アカウントのご利用停止';
  perform tests.eq(area_name, '停止すると本人あてに停止通知が1件届く', cnt, 1);

  select count(*)::int into cnt from public.notifications
   where user_id = u1 and title = 'アカウントのご利用停止' and body like '%荒らし行為のため%';
  perform tests.eq(area_name, '停止通知の本文に管理者が入力した停止理由が入る', cnt, 1);

  -- ================= 6) 本人による自力解除ができないこと =================
  -- 設計上、UPDATE文そのものは通る（自分の行なので1件が対象になる）が、
  -- トリガが値を書き戻すため停止は解除されない＝is_admin と同じ「静かな無効化」方式。
  -- したがってここで見るべきは「影響行数」ではなく「値が変わっていないこと」（下のテスト）。
  perform tests.affects(area_name, '停止中の本人による banned_at の直接UPDATEは受け付けられる（値はトリガで戻る）',
    format('update public.profiles set banned_at = null, banned_reason = null where id = %L', u1), 1);

  perform tests.as_owner();
  select banned_at into ts from public.profiles where id = u1;
  perform tests.ok(area_name, '本人の直接UPDATE後も停止状態が維持されている',
    ts is not null, '本人が自分で banned_at を消して停止を解除できてしまいました');
  update public.profiles
     set banned_at = coalesce(banned_at, now()),
         banned_reason = coalesce(banned_reason, '荒らし行為のため')
   where id = u1;

  -- ================= 7) 他人・匿名から見た停止 =================
  perform tests.as_user(u2);
  select count(*)::int into cnt from public.notifications where user_id = u1;
  perform tests.eq(area_name, '停止通知は他の利用者からは読めない', cnt, 0);

  select count(*)::int into cnt from public.recipes where id = r_pub;
  perform tests.eq(area_name, '停止されても本人の公開投稿は他の利用者から見える（BANは投稿を隠さない）', cnt, 1);

  perform tests.affects(area_name, '一般利用者が他人の banned_at を書き換えても1件も反映されない',
    format('update public.profiles set banned_at = null where id = %L', u1), 0);

  perform tests.denied(area_name, '一般利用者は set_user_ban を実行できない',
    format('select public.set_user_ban(%L::uuid, false)', u1), '権限がありません');

  perform tests.as_anon();
  perform tests.denied(area_name, '匿名(未ログイン)は set_user_ban を実行できない',
    format('select public.set_user_ban(%L::uuid, true)', u1), 'set_user_ban');

  perform tests.denied(area_name, '匿名(未ログイン)は profiles.banned_at 列を読めない',
    'select banned_at from public.profiles limit 1', 'profiles');

  -- ================= 8) 管理者に対する制限 =================
  perform tests.as_user(adm);
  perform tests.denied(area_name, '管理者は自分自身を停止できない（締め出し防止）',
    format('select public.set_user_ban(%L::uuid, true, %L)', adm, '自分を停止'), '自分自身は停止できません');

  perform tests.denied(area_name, '管理者は他の管理者を停止できない',
    format('select public.set_user_ban(%L::uuid, true, %L)', adm2, '管理者を停止'), '管理者は停止できません');

  perform tests.denied(area_name, '存在しない利用者を停止しようとするとエラーになる（不整合な通知を作らない）',
    format('select public.set_user_ban(%L::uuid, true, %L)', ghost, '存在しない相手'), 'notifications');

  perform tests.allowed(area_name, '停止中の相手をもう一度停止してもエラーにならない（冪等）',
    format('select public.set_user_ban(%L::uuid, true, %L)', u1, '再確認'));

  perform tests.allowed(area_name, '停止理由を省略しても停止を実行できる',
    format('select public.set_user_ban(%L::uuid, true)', u4));

  perform tests.as_owner();
  select banned_reason into t from public.profiles where id = u4;
  perform tests.ok(area_name, '理由を省略した停止では banned_reason は空のまま',
    t is null, '理由を渡していないのに banned_reason が入っています');

  select count(*)::int into cnt from public.notifications
   where user_id = u4 and title = 'アカウントのご利用停止'
     and body like '%利用規約に違反する行為が確認されたため%';
  perform tests.eq(area_name, '理由を省略した停止では既定の説明文が本人に通知される', cnt, 1);

  -- ================= 9) 通報サマリ（管理者だけの判断材料） =================
  perform tests.as_user(u2);
  select count(*)::int into cnt from public.report_summary(30);
  perform tests.eq(area_name, '一般利用者が report_summary を呼んでも1件も返らない', cnt, 0);

  perform tests.as_user(adm);
  select count(*)::int into cnt from public.report_summary(30) s where s.owner_id = u1 and s.banned;
  perform tests.eq(area_name, '管理者の通報サマリに「停止中」が正しく表示される', cnt, 1);

  -- ================= 10) 停止中でも退会できる =================
  perform tests.as_user(adm);
  perform tests.allowed(area_name, '退会テスト用の利用者を停止できる',
    format('select public.set_user_ban(%L::uuid, true, %L)', u3, '退会テスト'));

  perform tests.as_user(u3);
  perform tests.allowed(area_name, '停止中でも退会(delete_user)できる', 'select public.delete_user()');

  perform tests.as_owner();
  select count(*)::int into cnt from auth.users where id = u3;
  perform tests.eq(area_name, '停止中の退会後は auth.users から消えている', cnt, 0);

  -- ================= 11) 解除 =================
  perform tests.as_user(adm);
  perform tests.allowed(area_name, '管理者は停止を解除できる',
    format('select public.set_user_ban(%L::uuid, false)', u1));

  perform tests.as_owner();
  select banned_at, banned_reason into ts, t from public.profiles where id = u1;
  perform tests.ok(area_name, '解除すると banned_at が null に戻る',
    ts is null, '解除したのに banned_at が残っています');
  perform tests.ok(area_name, '解除すると banned_reason も消える',
    t is null, '解除したのに停止理由が残っています');
  perform tests.eq(area_name, '解除後は is_banned が false に戻る', public.is_banned(u1), false);

  perform tests.as_user(u1);
  select count(*)::int into cnt from public.notifications
   where user_id = u1 and type = 'system' and title = 'ご利用停止を解除しました';
  perform tests.eq(area_name, '解除すると本人あてに解除通知が届く', cnt, 1);

  perform tests.allowed(area_name, '解除後は再び投稿(recipes)できる',
    format('insert into public.recipes(owner_id,title,grid,is_public, created_at) values (%L,%L,%L::jsonb,false, now() - interval ''1 hour'')',
           u1, '解除後の投稿', '{}'));

  perform tests.allowed(area_name, '解除後は再びコメントできる',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           r_other, u1, '解除後のコメントです'));

  perform tests.allowed(area_name, '解除後は再び下書きを作成できる',
    format('insert into public.drafts(owner_id,title,grid) values (%L,%L,%L::jsonb)',
           u1, '解除後の下書き', '{}'));

  perform tests.allowed(area_name, '解除後は再び通報できる',
    format('insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,%L,%L)',
           r_other, u1, 'スパム', '解除後の通報'));

  -- ================= 後片付け =================
  -- 後片付けが失敗したことに気づけるよう、結果を1件のテストとして必ず記録する
  -- （黙って握りつぶすと dev にテスト用データが残り続ける）
  begin
    perform tests.as_owner();
    delete from public.inquiries   where user_id    = any(array[u1,u2,u3,u4]);
    delete from public.clip_notified where clipper_id = any(array[u1,u2,u3,u4]);
    -- reports は recipe_id が ON DELETE CASCADE、reporter_id が ON DELETE SET NULL のため、
    -- 「お互いの投稿を通報し合った利用者」をまとめて削除すると外部キー違反になる。
    -- 先に通報を消しておく（テストの後片付け都合。製品の退会処理は1人ずつなので影響しない）。
    delete from public.reports
     where reporter_id = any(array[u1,u2,u3,u4])
        or recipe_id in (select id from public.recipes where owner_id = any(array[u1,u2,u3,u4]));
    perform tests.cleanup_users(array[u1,u2,u3,u4,adm,adm2]);
    perform tests.ok(area_name, '後片付け（テスト用の利用者とデータの削除）が成功する', true, null);
  exception when others then
    perform tests.ok(area_name, '後片付け（テスト用の利用者とデータの削除）が成功する', false,
      '後片付けに失敗: ' || left(sqlerrm,140));
  end;
end $$;
