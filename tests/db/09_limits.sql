-- 上限・レート制限 のテスト（自動生成・dev専用）
do $$
declare
  a  text := '上限・レート制限';
  t0 timestamptz := now();
  u_priv uuid; u_priv_other uuid; u_prem uuid;
  u_drf uuid; u_drf_prem uuid; u_drf_other uuid;
  u_rate uuid; u_rate_ok uuid; u_rate_other uuid;
  u_day30 uuid; u_day29 uuid; u_old30 uuid; u_day_other uuid;
  u_rec uuid; u_cm uuid; u_cm_other uuid;
  u_rp uuid; u_rp_other uuid; u_iq uuid; u_iq_other uuid;
  us uuid[];
  r_pub  uuid := gen_random_uuid();
  r_tgt  uuid := gen_random_uuid();
  r_priv uuid; d_one uuid;
  i int; n int; ts timestamptz;
begin
  -- ============ 下準備（すべて特権＝as_owner で作る） ============
  perform tests.as_owner();

  u_priv       := tests.make_user();
  u_priv_other := tests.make_user();
  u_prem       := tests.make_user();
  u_drf        := tests.make_user();
  u_drf_prem   := tests.make_user();
  u_drf_other  := tests.make_user();
  u_rate       := tests.make_user();
  u_rate_ok    := tests.make_user();
  u_rate_other := tests.make_user();
  u_day30      := tests.make_user();
  u_day29      := tests.make_user();
  u_old30      := tests.make_user();
  u_day_other  := tests.make_user();
  u_rec        := tests.make_user();
  u_cm         := tests.make_user();
  u_cm_other   := tests.make_user();
  u_rp         := tests.make_user();
  u_rp_other   := tests.make_user();
  u_iq         := tests.make_user();
  u_iq_other   := tests.make_user();

  us := array[u_priv,u_priv_other,u_prem,u_drf,u_drf_prem,u_drf_other,
              u_rate,u_rate_ok,u_rate_other,u_day30,u_day29,u_old30,u_day_other,
              u_rec,u_cm,u_cm_other,u_rp,u_rp_other,u_iq,u_iq_other];

  -- コメント/通報の対象になる「公開投稿」（作成は2日前扱いにして投稿レート制限に触れないようにする）
  insert into public.recipes(id, owner_id, title, is_public, created_at)
  values (r_tgt, u_rec, 'コメント対象の公開投稿', true, now() - interval '2 days');

  -- 非公開上限テスト用: 9件だけ先に作る（10件目は本人に作らせて確かめる）
  for i in 1..9 loop
    insert into public.recipes(owner_id,title,is_public,created_at)
    values (u_priv, '非公開'||i, false, now() - interval '2 days')
    returning id into r_priv;
  end loop;

  -- プレミアム上限突破テスト用: 非公開10件（＝無料なら上限到達）＋プレミアム付与
  for i in 1..10 loop
    insert into public.recipes(owner_id,title,is_public,created_at)
    values (u_prem, 'P非公開'||i, false, now() - interval '2 days');
  end loop;
  insert into public.premium_users(user_id) values (u_prem);

  -- 下書き上限テスト用
  for i in 1..4 loop
    insert into public.drafts(owner_id,title) values (u_drf, '下書き'||i) returning id into d_one;
  end loop;
  for i in 1..5 loop
    insert into public.drafts(owner_id,title) values (u_drf_prem, 'P下書き'||i);
  end loop;
  insert into public.premium_users(user_id) values (u_drf_prem);

  -- 投稿レート（20秒間隔）テスト用
  insert into public.recipes(owner_id,title,is_public,created_at)
  values (u_rate, '直前の投稿', true, now());
  insert into public.recipes(owner_id,title,is_public,created_at)
  values (u_rate_ok, '21秒前の投稿', true, now() - interval '21 seconds');
  insert into public.recipes(owner_id,title,is_public,created_at)
  values (u_rate_other, '別人の直前の投稿', true, now());

  -- 投稿レート（1日30件）テスト用
  for i in 1..30 loop
    insert into public.recipes(owner_id,title,is_public,created_at)
    values (u_day30, '本日'||i, true, now() - interval '1 hour');
  end loop;
  for i in 1..29 loop
    insert into public.recipes(owner_id,title,is_public,created_at)
    values (u_day29, '本日29-'||i, true, now() - interval '1 hour');
  end loop;
  for i in 1..30 loop
    insert into public.recipes(owner_id,title,is_public,created_at)
    values (u_old30, '2日前'||i, true, now() - interval '2 days');
  end loop;

  -- ============ 1) 非公開投稿は10件まで ============
  perform tests.as_user(u_priv);
  perform tests.allowed(a,'非公開投稿は10件目までは作成できる',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'非公開10',false)$f$, u_priv), now() - interval '1 hour');

  -- 10件目が「今」作られたため、次は投稿間隔(20秒)に先に引っかかる。上限だけを見たいので過去日時へ寄せる
  perform tests.as_owner();
  update public.recipes set created_at = now() - interval '2 days' where owner_id = u_priv;

  perform tests.as_user(u_priv);
  perform tests.denied(a,'非公開投稿が10件ある状態で11件目を作るとエラーになる',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'非公開11',false)$f$, u_priv),
    'PRIVATE_LIMIT', now() - interval '1 hour');

  perform tests.allowed(a,'非公開が上限でも公開投稿は作成できる（公開は無制限）',
    format($f$insert into public.recipes(id,owner_id,title,is_public, created_at) values (%L,%L,'公開投稿',true)$f$, r_pub, u_priv), now() - interval '1 hour');

  perform tests.denied(a,'非公開が上限のとき公開投稿を非公開に切り替えるとエラーになる',
    format($f$update public.recipes set is_public = false where id = %L$f$, r_pub),
    'PRIVATE_LIMIT');

  perform tests.affects(a,'非公開が上限でも既存の非公開投稿は編集できる',
    format($f$update public.recipes set title = '編集後' where id = %L$f$, r_priv), 1);

  perform tests.as_user(u_priv_other);
  perform tests.allowed(a,'非公開投稿の上限は利用者ごと（他人が上限でも自分は作成できる）',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'別人の非公開',false)$f$, u_priv_other), now() - interval '1 hour');

  -- ============ 2) プレミアムは上限を超えられる ============
  perform tests.as_user(u_prem);
  perform tests.allowed(a,'プレミアム利用者は非公開投稿の11件目を作成できる',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'P非公開11',false)$f$, u_prem), now() - interval '1 hour');

  select count(*)::int into n from public.premium_users where user_id = u_prem;
  perform tests.eq(a,'プレミアム利用者は自分のプレミアム状態を読める', n, 1);

  perform tests.as_user(u_priv_other);
  select count(*)::int into n from public.premium_users where user_id = u_prem;
  perform tests.eq(a,'他人のプレミアム状態は読めない（自分の行だけ）', n, 0);

  perform tests.denied(a,'一般利用者は自分をプレミアムとして登録できない（上限の自力解除を防ぐ）',
    format($f$insert into public.premium_users(user_id) values (%L)$f$, u_priv_other), null);

  perform tests.as_owner();
  update public.recipes set created_at = now() - interval '2 days' where owner_id = u_prem;
  delete from public.premium_users where user_id = u_prem;

  perform tests.as_user(u_prem);
  perform tests.denied(a,'プレミアムを外すと非公開投稿の上限が再び効く',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'P非公開12',false)$f$, u_prem),
    'PRIVATE_LIMIT', now() - interval '1 hour');

  -- ============ 3) 下書きは5件まで ============
  perform tests.as_user(u_drf);
  perform tests.allowed(a,'下書きは5件目までは作成できる',
    format($f$insert into public.drafts(owner_id,title) values (%L,'下書き5')$f$, u_drf));
  perform tests.denied(a,'下書きが5件ある状態で6件目を作るとエラーになる',
    format($f$insert into public.drafts(owner_id,title) values (%L,'下書き6')$f$, u_drf),
    'DRAFT_LIMIT');
  perform tests.affects(a,'下書きが上限でも既存の下書きは更新できる',
    format($f$update public.drafts set title = '下書き更新' where id = %L$f$, d_one), 1);

  perform tests.as_user(u_drf_other);
  perform tests.allowed(a,'下書きの上限は利用者ごと（他人が上限でも自分は作成できる）',
    format($f$insert into public.drafts(owner_id,title) values (%L,'別人の下書き')$f$, u_drf_other));

  perform tests.as_user(u_drf_prem);
  perform tests.allowed(a,'プレミアム利用者は下書きの6件目を作成できる',
    format($f$insert into public.drafts(owner_id,title) values (%L,'P下書き6')$f$, u_drf_prem));

  perform tests.as_user(u_day30);
  perform tests.allowed(a,'投稿を30件していても下書きの上限には影響しない（別々に数える）',
    format($f$insert into public.drafts(owner_id,title) values (%L,'投稿多数でも下書きOK')$f$, u_day30));

  -- ============ 4) 投稿レート（20秒間隔／1日30件） ============
  perform tests.as_user(u_rate);
  perform tests.denied(a,'直前に投稿した直後（20秒以内）の公開投稿は拒否される',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'連投',true)$f$, u_rate),
    '投稿の間隔が短すぎます', now() - interval '1 hour');
  perform tests.denied(a,'20秒以内の連続投稿は非公開投稿でも拒否される',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'連投(非公開)',false)$f$, u_rate),
    '投稿の間隔が短すぎます', now() - interval '1 hour');
  perform tests.denied(a,'created_atを過去に指定しても20秒間隔の制限は回避できない',
    format($f$insert into public.recipes(owner_id,title,is_public,created_at) values (%L,'偽装連投',true, now() - interval '1 day')$f$, u_rate),
    '投稿の間隔が短すぎます');

  perform tests.as_user(u_rate_ok);
  perform tests.allowed(a,'前の投稿から20秒以上あいていれば投稿できる',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'21秒後の投稿',true)$f$, u_rate_ok), now() - interval '1 hour');

  perform tests.as_user(u_day30);
  perform tests.denied(a,'24時間以内に30件投稿していると31件目は拒否される',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'31件目',true)$f$, u_day30),
    '1日に投稿できる件数の上限', now() - interval '1 hour');

  perform tests.as_user(u_day29);
  perform tests.allowed(a,'24時間以内が29件なら30件目は投稿できる',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'30件目',true)$f$, u_day29), now() - interval '1 hour');

  perform tests.as_user(u_old30);
  perform tests.allowed(a,'24時間より前の投稿30件は日次カウントに入らない（投稿できる）',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'古い投稿の後',true)$f$, u_old30), now() - interval '1 hour');

  perform tests.as_user(u_rate_other);
  perform tests.denied(a,'投稿間隔の制限は本人には効く（別人テストの前提確認）',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'別人の連投',true)$f$, u_rate_other),
    '投稿の間隔が短すぎます', now() - interval '1 hour');

  perform tests.as_user(u_day_other);
  perform tests.allowed(a,'投稿レート制限は別の利用者には影響しない（他人が上限でも投稿できる）',
    format($f$insert into public.recipes(owner_id,title,is_public, created_at) values (%L,'無関係な人の初投稿',true)$f$, u_day_other), now() - interval '1 hour');

  -- ============ 5) コメントは30秒間隔 ============
  perform tests.as_user(u_cm);
  perform tests.allowed(a,'同一利用者の最初のコメントは投稿できる',
    format($f$insert into public.comments(recipe_id,user_id,body) values (%L,%L,'最初のコメント')$f$, r_tgt, u_cm));
  perform tests.denied(a,'コメント直後（30秒以内）の2回目のコメントは拒否される',
    format($f$insert into public.comments(recipe_id,user_id,body) values (%L,%L,'2回目のコメント')$f$, r_tgt, u_cm),
    '連続投稿を制限しています');
  perform tests.denied(a,'created_atを過去に指定してもコメントの30秒制限は回避できない',
    format($f$insert into public.comments(recipe_id,user_id,body,created_at) values (%L,%L,'偽装コメント', now() - interval '1 hour')$f$, r_tgt, u_cm),
    '連続投稿を制限しています');

  perform tests.as_user(u_cm_other);
  perform tests.allowed(a,'コメントの連投制限は別の利用者には影響しない',
    format($f$insert into public.comments(recipe_id,user_id,body) values (%L,%L,'別人のコメント')$f$, r_tgt, u_cm_other));

  -- 「31秒前にコメント済み」の状態を作り直す（コメントは整合トリガでcreated_atを更新できないため入れ直す）
  perform tests.as_owner();
  delete from public.comments where user_id = u_cm;
  insert into public.comments(recipe_id,user_id,body,created_at)
  values (r_tgt, u_cm, '31秒前のコメント', now() - interval '31 seconds');

  perform tests.as_user(u_cm);
  perform tests.allowed(a,'前のコメントから30秒以上あいていればコメントできる',
    format($f$insert into public.comments(recipe_id,user_id,body,created_at) values (%L,%L,'時刻偽装つきコメント', now() - interval '2 days')$f$, r_tgt, u_cm));
  select created_at into ts from public.comments where user_id = u_cm and body = '時刻偽装つきコメント';
  perform tests.ok(a,'コメントのcreated_atは過去を指定しても現在時刻に矯正される（連投制限の回避封じ）',
    ts is not null and ts >= now() - interval '5 seconds',
    '保存されたcreated_at=' || coalesce(ts::text,'null'));

  -- ============ 6) 通報は30秒間隔 ============
  perform tests.as_user(u_rp);
  perform tests.allowed(a,'同一利用者の最初の通報は送信できる',
    format($f$insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,'スパム','テスト通報1')$f$, r_tgt, u_rp));
  perform tests.denied(a,'通報直後（30秒以内）の2回目の通報は拒否される',
    format($f$insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,'スパム','テスト通報2')$f$, r_tgt, u_rp),
    '通報が連続しています');
  perform tests.denied(a,'created_atを過去に指定しても通報の30秒制限は回避できない',
    format($f$insert into public.reports(recipe_id,reporter_id,reason,detail,created_at) values (%L,%L,'スパム','偽装通報', now() - interval '1 hour')$f$, r_tgt, u_rp),
    '通報が連続しています');

  perform tests.as_user(u_rp_other);
  perform tests.allowed(a,'通報の連投制限は別の利用者には影響しない',
    format($f$insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,'不適切','別人の通報')$f$, r_tgt, u_rp_other));

  perform tests.as_owner();
  update public.reports set created_at = now() - interval '31 seconds' where reporter_id = u_rp;

  perform tests.as_user(u_rp);
  perform tests.allowed(a,'前の通報から30秒以上あいていれば通報できる',
    format($f$insert into public.reports(recipe_id,reporter_id,reason,detail) values (%L,%L,'スパム','31秒後の通報')$f$, r_tgt, u_rp));

  -- ============ 7) 問い合わせは60秒間隔 ============
  perform tests.as_user(u_iq);
  perform tests.allowed(a,'同一利用者の最初の問い合わせは送信できる',
    format($f$insert into public.inquiries(user_id,category,body) values (%L,'その他','テスト問い合わせ1')$f$, u_iq));
  perform tests.denied(a,'問い合わせ直後（60秒以内）の2回目の送信は拒否される',
    format($f$insert into public.inquiries(user_id,category,body) values (%L,'その他','テスト問い合わせ2')$f$, u_iq),
    'お問い合わせが連続しています');

  perform tests.as_owner();
  update public.inquiries set created_at = now() - interval '40 seconds' where user_id = u_iq;
  perform tests.as_user(u_iq);
  perform tests.denied(a,'前の問い合わせから40秒（60秒未満）ではまだ送信できない',
    format($f$insert into public.inquiries(user_id,category,body) values (%L,'その他','40秒後の問い合わせ')$f$, u_iq),
    'お問い合わせが連続しています');

  perform tests.as_owner();
  update public.inquiries set created_at = now() - interval '61 seconds' where user_id = u_iq;
  perform tests.as_user(u_iq);
  perform tests.allowed(a,'前の問い合わせから60秒以上あいていれば送信できる',
    format($f$insert into public.inquiries(user_id,category,body) values (%L,'その他','61秒後の問い合わせ')$f$, u_iq));

  perform tests.as_owner();
  update public.inquiries set created_at = now() where user_id = u_iq;
  perform tests.as_user(u_iq_other);
  perform tests.allowed(a,'問い合わせの連投制限は別の利用者には影響しない',
    format($f$insert into public.inquiries(user_id,category,body) values (%L,'その他','別人の問い合わせ')$f$, u_iq_other));

  -- ============ 後片付け（失敗しても止めない） ============
  begin perform tests.as_owner(); exception when others then null; end;
  begin delete from public.inquiries where user_id = any(us); exception when others then null; end;
  begin delete from public.reports   where reporter_id = any(us); exception when others then null; end;
  begin delete from public.notifications where type = 'new_report' and created_at >= t0; exception when others then null; end;
  begin delete from public.premium_users where user_id = any(us); exception when others then null; end;
  begin perform tests.cleanup_users(us); exception when others then null; end;
end $$;
