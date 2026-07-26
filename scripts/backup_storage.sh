#!/bin/bash
# =====================================================================
# backup_storage.sh — 投稿写真(Supabase Storage)のバックアップ【全自動】
#
#   使い方:  bash scripts/backup_storage.sh
#
#   なぜ必要か:
#     既存の自動バックアップは pg_dump（データベースの中身）だけで、
#     利用者がアップロードした「写真」は1枚もバックアップされない。
#     写真が消えるとDBにはURLだけが残り、全レシピがリンク切れになる。
#     利用者が撮り直せない完成品の写真なので、消えたら取り返しがつかない。
#
#   以前の版はパス一覧を手作業でSQLからコピーする方式だったため、
#   実行を忘れると静かに漏れが増えた（実際に4ファイル漏れていた）。
#   この版は公開レシピ・下書き・プロフィールが参照しているURLをAPIから
#   自動収集するので、手作業は不要。
#
#   ★制約: 匿名キーで取得できるのは「公開レシピが参照する画像」のみ。
#     非公開投稿・下書きの画像まで完全に取るには、Supabaseダッシュボードの
#     SQL Editor で下記を実行し、結果を scripts/storage_paths.local.txt に貼る:
#       select bucket_id || '/' || name from storage.objects
#        where bucket_id in ('recipes','profile') order by 1;
#     ファイルがあればそれを優先して使う（漏れゼロになる）。
# =====================================================================
set -u

SUPABASE_URL="https://zlkbaojclitlxshpxwpr.supabase.co"
ANON_KEY="sb_publishable_ZMaz3JjPfU0q_pq7Y9QwSQ_QimbhfgX"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/../backups/storage/$(date +%Y%m%d)"
LIST="$HERE/storage_paths.local.txt"
TMP="$(mktemp)"

mkdir -p "$DEST"

if [ -f "$LIST" ]; then
  echo "パス一覧: $LIST を使用（完全版）"
  cp "$LIST" "$TMP"
else
  echo "パス一覧: 公開データから自動収集（非公開・下書きは対象外）"
  # 公開レシピの cover_url と grid 内の写真URL、プロフィール画像を集める
  curl -sS "$SUPABASE_URL/rest/v1/recipes?is_public=eq.true&select=cover_url,grid" \
       -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
  | python3 -c '
import json,sys,re
out=set()
for r in json.load(sys.stdin):
    urls=[r.get("cover_url")]
    g=r.get("grid") or {}
    urls += (g.get("photos") or [])
    for e in (g.get("rows") or []):
        if isinstance(e,dict): urls.append(e.get("photo"))
    for u in urls:
        if not u: continue
        m=re.search(r"/object/public/(.+)$", u)
        if m: out.add(m.group(1))
for p in sorted(out): print(p)
' > "$TMP"
  curl -sS "$SUPABASE_URL/rest/v1/profiles?select=avatar_url,header_url" \
       -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
  | python3 -c '
import json,sys,re
out=set()
for r in json.load(sys.stdin):
    for u in (r.get("avatar_url"), r.get("header_url")):
        if not u: continue
        m=re.search(r"/object/public/(.+)$", u)
        if m: out.add(m.group(1))
for p in sorted(out): print(p)
' >> "$TMP"
fi

total=$(grep -c . "$TMP" 2>/dev/null || echo 0)
echo "対象: ${total} ファイル"
ok=0; ng=0; skip=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  out="$DEST/$p"
  mkdir -p "$(dirname "$out")"
  if [ -f "$out" ]; then skip=$((skip+1)); continue; fi
  code=$(curl -sS -o "$out" -w '%{http_code}' "$SUPABASE_URL/storage/v1/object/public/$p")
  if [ "$code" = "200" ]; then ok=$((ok+1)); else ng=$((ng+1)); rm -f "$out"; echo "  取得失敗($code): $p" >&2; fi
done < "$TMP"
rm -f "$TMP"

echo "完了: 新規取得 $ok / 既存スキップ $skip / 失敗 $ng"
echo "保存先: $DEST"
du -sh "$DEST" 2>/dev/null

# 直近のバックアップと比較して、増減を知らせる（漏れの早期発見）
prev=$(ls -1d "$HERE/../backups/storage"/*/ 2>/dev/null | sort | tail -2 | head -1)
if [ -n "$prev" ] && [ "$prev" != "$DEST/" ]; then
  a=$(find "$prev" -type f 2>/dev/null | wc -l | tr -d ' ')
  b=$(find "$DEST" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "前回 $a ファイル → 今回 $b ファイル"
fi
