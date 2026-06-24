/* 塗装レシピ録 PWA サービスワーカー
   方針：頻繁に更新されるサイトなので「常に最新」を優先し、積極的キャッシュはしない。
   ナビゲーションはネットワーク優先＋オフライン時のみ簡易メッセージ。
   その他リソースはブラウザ標準（=常に最新・キャッシュ汚染なし）。 */
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
          + '<p>インターネット接続を確認して、もう一度お試しください。</p></body>',
          { headers: { 'content-type': 'text/html; charset=utf-8' } }
        );
      })
    );
  }
  /* navigate 以外は介入しない＝ブラウザ標準のネットワーク取得（常に最新） */
});
