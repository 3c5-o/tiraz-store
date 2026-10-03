import { admin } from './shared.ts';


import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS"
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json" }
  });
}

async function requireAdmin(req: Request) { return admin(req,'owner'); }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const { sb } = await requireAdmin(req);

    if (req.method === "GET") {
      const [{ data: channels }, { data: credentials }] = await Promise.all([
        sb.from("integration_channels")
          .select("purpose,channel_id,enabled,updated_at")
          .order("purpose"),
        sb.from("integration_credentials")
          .select("telegram_bot_token,onesignal_rest_key")
          .eq("id", true)
          .maybeSingle()
      ]);

      return json({
        channels: channels || [],
        bot_configured: !!credentials?.telegram_bot_token,
        onesignal_key_configured: !!credentials?.onesignal_rest_key
      });
    }

    if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

    const body = await req.json();

    if (body.action === "test_telegram") {
      const { data: credentials } = await sb.from("integration_credentials")
        .select("telegram_bot_token")
        .eq("id", true)
        .maybeSingle();

      if (!credentials?.telegram_bot_token) return json({ error: "BOT_NOT_CONFIGURED" }, 400);

      const botReply = await fetch(
        `https://api.telegram.org/bot${credentials.telegram_bot_token}/getMe`
      );
      const bot = await botReply.json();

      if (!bot.ok) return json({ error: "TELEGRAM_ERROR", details: bot }, 400);

      const { data: channels } = await sb.from("integration_channels")
        .select("purpose,channel_id,enabled")
        .eq("enabled", true);

      const checks: Record<string, unknown>[] = [];
      for (const channel of channels || []) {
        if (!channel.channel_id) continue;
        try {
          const response = await fetch(
            `https://api.telegram.org/bot${credentials.telegram_bot_token}/getChat?chat_id=${encodeURIComponent(channel.channel_id)}`
          );
          const result = await response.json();
          checks.push({
            purpose: channel.purpose,
            ok: !!result.ok,
            title: result.result?.title || null
          });
        } catch {
          checks.push({ purpose: channel.purpose, ok: false, title: null });
        }
      }

      return json({
        ok: true,
        bot_username: bot.result?.username || null,
        channels: checks
      });
    }

    if (typeof body.telegram_bot_token === "string" && body.telegram_bot_token.trim()) {
      const { error } = await sb.from("integration_credentials").upsert({
        id: true,
        telegram_bot_token: body.telegram_bot_token.trim(),
        updated_at: new Date().toISOString()
      });
      if (error) throw error;
    }

    if (typeof body.onesignal_rest_key === "string" && body.onesignal_rest_key.trim()) {
      const { error } = await sb.from("integration_credentials").upsert({
        id: true,
        onesignal_rest_key: body.onesignal_rest_key.trim(),
        updated_at: new Date().toISOString()
      });
      if (error) throw error;
    }

    if (Array.isArray(body.channels)) {
      for (const channel of body.channels) {
        if (!channel?.purpose) continue;
        const { error } = await sb.from("integration_channels").upsert({
          purpose: channel.purpose,
          channel_id: channel.channel_id || null,
          enabled: !!channel.enabled,
          updated_at: new Date().toISOString()
        });
        if (error) throw error;
      }
    }

    return json({ ok: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json(
      { error: message },
      message === "UNAUTHORIZED" ? 401 : message === "FORBIDDEN" ? 403 : 400
    );
  }
});

