#!/usr/bin/env bash
# ============================================================================
# 開発用のサイトを手元で立ち上げる
#
#   使い方:  bash scripts/dev.sh
#   止め方:  ターミナルで Control + C
#
# ★何が起きるか
#   本番とまったく同じ仕組み（Cloudflare Worker + 静的ファイル）が
#   手元のパソコンの中だけで動き、http://localhost:8787 で開けるようになる。
#   Safari でも Chrome でも開ける。
#
# ★本番との違いはひとつだけ
#   つなぐデータベースが「開発用」に切り替わる。
#     ・ブラウザ側 … src/config.js が localhost を見て自動で開発DBへ
#     ・Worker側   … worker/.dev.vars が wrangler.toml の設定を上書きして開発DBへ
#   つまり ここで何をしても本番のデータは1件も変わらない。
#   投稿を作ろうが消そうが、本番のサイトには何の影響もない。
#
# ★写真について
#   開発DBの投稿が指している画像URLは本番のものをそのまま使っている（読むだけ）。
#   見た目の確認には十分で、本番側には手を触れない。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

G="\033[32m"; B="\033[1m"; Y="\033[33m"; X="\033[0m"

if [ ! -f worker/.dev.vars ]; then
  echo -e "${Y}worker/.dev.vars がありません。これが無いと表示だけ開発DB・裏側は本番DBというねじれた状態になります。${X}"
  exit 1
fi

# 同じWi-Fiのスマホから開くためのアドレス。
# ★実機で見ないと分からない不具合が多い（指で押せるか、写真の大きさ、縦の長さ）。
#   パソコンの画面を細くして見るのとは別物なので、必ず実機で確認できるようにしておく。
LAN="$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || /usr/sbin/ipconfig getifaddr en1 2>/dev/null || true)"

echo -e "${B}開発用のサイトを立ち上げます${X}"
echo -e "  つなぎ先 : ${B}開発用データベース${X}（本番には一切影響しません）"
echo -e "  パソコン : ${G}${B}http://localhost:8787${X}"
if [ -n "$LAN" ] && [ "${DEV_BIND:-0.0.0.0}" = "0.0.0.0" ]; then
  echo -e "  スマホ   : ${G}${B}http://${LAN}:8787${X}  ← 同じWi-Fiに繋いで開く"
  echo -e "  ${Y}※ 同じWi-Fiの他の人からも見えます。外出先のWi-Fiでは次のように起動してください:${X}"
  echo -e "  ${Y}   DEV_BIND=127.0.0.1 bash scripts/dev.sh${X}"
elif [ "${DEV_BIND:-}" = "127.0.0.1" ]; then
  echo -e "  スマホ   : ${Y}使えません（このパソコンからだけ見える設定で起動しています）${X}"
else
  echo -e "  ${Y}スマホ用のアドレスを取得できませんでした（Wi-Fi未接続かもしれません）${X}"
fi
# ★合言葉はここに書かない。worker/.dev.vars（Gitに入らない）から読んで表示するだけにする。
#   一度ここに直書きしてしまったが、このファイルはGitに入るので
#   「合言葉は .dev.vars にしかない」という前提が自分で崩れていた。
DEV_MAIL="$(/usr/bin/sed -n 's/^DEV_LOGIN_EMAIL *= *"\(.*\)"/\1/p' worker/.dev.vars 2>/dev/null | /usr/bin/tail -1)"
if [ -n "$DEV_MAIL" ]; then
  echo -e "  ログイン : ${DEV_MAIL}（自動でログインされます）"
fi
echo -e "  止めるとき: Control + C"
echo ""

cd worker
# ★どこまで公開するかを選べるようにする。
#   既定は 0.0.0.0（同じWi-Fiのスマホから見るため。実機確認が要るので、ここは譲れない）。
#   ただし「同じWi-Fiの他人からも見える」ことは事実なので、それを隠さず伝える。
#   外出先のWi-Fi（喫茶店・ホテル等）では DEV_BIND=127.0.0.1 を付けて、
#   このパソコンからだけ見えるようにする:
#       DEV_BIND=127.0.0.1 bash scripts/dev.sh
exec npx wrangler dev --port 8787 --ip "${DEV_BIND:-0.0.0.0}" --local
