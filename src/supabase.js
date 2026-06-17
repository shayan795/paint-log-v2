// ============================================================================
// Supabaseクライアント(共有)
// ----------------------------------------------------------------------------
// アプリ全体で1個だけ作って使い回す。Stage2(ログイン)以降で本格利用。
// config.js(classicスクリプト)が先に読まれて window.PAINTLOG_CONFIG を用意している前提。
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cfg = (typeof window !== "undefined" && window.PAINTLOG_CONFIG) || {};

export const hasConfig = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY);

export const supabase = hasConfig
  ? createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY)
  : null;
