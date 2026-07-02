/* 塗装方法マスター（単一の真実の源）。
   index.html / legacy.html の両方が config.js の直後に読み込む。
   ここを変更すれば両画面に反映される（以前は両HTMLに同一内容を二重定義していた）。 */
"use strict";
var PAINT_METHODS = [
  { slug:"grad",       label:"グラデーション塗装" },
  { slug:"candy",      label:"キャンディ塗装" },
  { slug:"candy_red",  label:"キャンディ塗装 レッド" },
  { slug:"candy_blue", label:"キャンディ塗装 ブルー" },
  { slug:"wrap",       label:"ラップ塗装" },
  { slug:"marble",     label:"大理石塗装" },
  { slug:"weather",    label:"ウェザリング" },
  { slug:"brush",      label:"筆塗り" },
  { slug:"metal",      label:"メタリック塗装" },
  { slug:"matte",      label:"つや消し仕上げ" },
  { slug:"mask",       label:"マスキング塗り分け" }
];
var METHOD_LABEL = {}; PAINT_METHODS.forEach(function(m){ METHOD_LABEL[m.slug] = m.label; });
