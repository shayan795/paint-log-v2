#!/bin/bash
# =====================================================================
# backup_storage.sh — 投稿写真(Supabase Storage)のバックアップ
#
#   なぜ必要か: 既存の自動バックアップは pg_dump（データベースの中身）だけで、
#   利用者がアップロードした「写真」は1枚もバックアップされていない。
#   写真が消えるとDBにはURLだけ残り、全レシピがリンク切れになる。
#   （利用者が撮り直せない完成品の写真なので、消えたら取り返しがつかない）
#
# 使い方:
#   1) Supabase の SQL Editor で下記を実行し、結果をコピーして
#      scripts/storage_paths.txt に貼る（1行1パス）:
#        select bucket_id || '/' || name from storage.objects
#         where bucket_id in ('recipes','profile') order by 1;
#   2) bash scripts/backup_storage.sh
#      → backups/storage/<日付>/ 以下に元の階層のまま保存される
#
# 注意: 保存先(backups/)は .gitignore 済み。利用者の写真なのでGitHubに上げないこと。
# =====================================================================
set -u

SUPABASE_URL="https://zlkbaojclitlxshpxwpr.supabase.co"
LIST="$(dirname "$0")/storage_paths.txt"
DEST="$(dirname "$0")/../backups/storage/$(date +%Y%m%d)"

if [ ! -f "$LIST" ]; then
  echo "エラー: $LIST がありません。上記の手順1でパス一覧を作ってください。" >&2
  exit 1
fi

mkdir -p "$DEST"
ok=0; ng=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  out="$DEST/$p"
  mkdir -p "$(dirname "$out")"
  if [ -f "$out" ]; then ok=$((ok+1)); continue; fi          # 既に取得済みはスキップ（再実行しやすく）
  code=$(curl -sS -o "$out" -w '%{http_code}' "$SUPABASE_URL/storage/v1/object/public/$p")
  if [ "$code" = "200" ]; then ok=$((ok+1)); else ng=$((ng+1)); rm -f "$out"; echo "  取得失敗($code): $p" >&2; fi
done < "$LIST"

echo "完了: 成功 $ok 件 / 失敗 $ng 件"
echo "保存先: $DEST"
du -sh "$DEST" 2>/dev/null
