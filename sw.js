/* 塗装レシピ録 PWA サービスワーカー
   方針：頻繁に更新されるサイトなので「常に最新」を優先し、積極的キャッシュはしない。
   ナビゲーションはネットワーク優先＋オフライン時のみ簡易メッセージ。
   その他リソースはブラウザ標準（=常に最新・キャッシュ汚染なし）。

   ──────────────────────────────────────────────────────────────────────────
   ★2026-07-28 点検（BOMBS B-003「新しいHTML＋古いJS」対策）: このまま変更不要。
     理由を残しておく。ここを書き換えるとき（特にキャッシュ機能を足すとき）に必ず読むこと。

     1) このSWは caches API を一切使っていない。保存していないものは古くならないので、
        「SWが古いJSを握り続ける」事故は起きない。
        src/config.js などに ?v=<版> を付けた対策も、SWが素通しなので確実に効く。
     2) navigate 以外は event.respondWith() を呼んでいない＝一切介入しない。
        ブラウザ標準の取得になるので、URLが変われば必ず新しい方を取りに行く。
     3) install で skipWaiting()、activate で clients.claim() をしている。
        これは「新しいSWが古いSWを即座に置き換えられる」ための2点セット。
        ★この2行は絶対に消さないこと。消すと、古いSWが利用者の端末に残り続け、
          こちらから更新する手段が無くなる（SWは端末側に居座るので取り返しがつかない）。

     ⚠️ もし将来キャッシュ機能を足すなら:
        ・キャッシュ名に必ず版を入れ、activate で「自分の版以外のキャッシュ」を消すこと。
        ・HTML(navigate)だけは絶対にキャッシュしないこと。HTMLを保存すると、
          ?v= で新しくしたJSと、端末に残った古いHTMLが食い違い、B-003が再発する。
   ────────────────────────────────────────────────────────────────────────── */
self.addEventListener('install', function(){ self.skipWaiting(); });
self.addEventListener('activate', function(e){ e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function(event){
  if (event.request.mode === 'navigate'){
    event.respondWith(
      fetch(event.request).catch(function(){
        return new Response(
          '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>オフライン</title>'
          + '<body style="font-family:-apple-system,sans-serif;padding:48px 24px;text-align:center;color:#555;background:#FAFAF7">'
          + '<h1 style="font-size:1.2rem;color:#1E2430">オフラインです</h1>'
          + '<p>インターネット接続を確認して、もう一度お試しください。</p>'
          + '<p style="margin-top:20px"><button onclick="location.reload()" style="font:inherit;padding:10px 20px;border:1px solid #C9CFD9;border-radius:8px;background:#fff;cursor:pointer">再読み込み</button></p></body>',
          // ★status を 503 にする。既定の 200 のままだと、ブラウザや診断処理が
          //   「ページの取得に成功した」と誤解し、通信障害を正常状態として扱ってしまう。
          { status: 503, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } }
        );
      })
    );
  }
  /* navigate 以外は介入しない＝ブラウザ標準のネットワーク取得（常に最新） */
});
