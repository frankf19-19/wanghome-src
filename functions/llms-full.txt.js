import { llmsFull } from "../lib/seo.js";
export const onRequestGet = async ({ request, env }) => {
  let base = "";
  try { const r = await env.ASSETS.fetch(new URL("/llms.txt", request.url)); if (r.ok) base = await r.text(); } catch (_) {}
  return llmsFull(base || "# 汪喵回家（WangMiao Home）\n\n台灣免費的走失狗貓協尋網站與 App：https://wangmiaotw.com/");
};
