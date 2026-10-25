import { loadDotEnv, modeEnabled } from "./lib.mjs";

loadDotEnv();
if (!modeEnabled()) {
  process.exit(0);
}

const token = process.env.TELEGRAM_BOT_TOKEN?.trim();
const chatId = process.env.TELEGRAM_CHAT_ID?.trim();

if (!token || !chatId) {
  console.error("missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID");
  process.exit(0);
}

const context = readJsonEnv("HERDR_PLUGIN_CONTEXT_JSON");
const event = readJsonEnv("HERDR_PLUGIN_EVENT_JSON");
const status = statusFromEvent(event) ?? statusFromContext(context);

if (!["done", "blocked"].includes(status)) {
  process.exit(0);
}

const text = formatMessage(context, event, status);
await sendTelegram(token, chatId, text);

function readJsonEnv(name) {
  const raw = process.env[name];
  if (!raw) {
    return {};
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    console.error(`invalid ${name}: ${error.message}`);
    return {};
  }
}

function statusFromEvent(event) {
  const status = event?.data?.agent_status;
  return typeof status === "string" ? status.toLowerCase() : undefined;
}

function statusFromContext(context) {
  const direct = context.focused_pane_status ?? context.agent_status ?? context.status;
  if (typeof direct === "string") {
    return direct.toLowerCase();
  }

  const eventStatus =
    context.event?.status ??
    context.event?.agent_status ??
    context.event?.pane?.agent_status ??
    context.event?.pane?.agent?.status;
  if (typeof eventStatus === "string") {
    return eventStatus.toLowerCase();
  }

  return undefined;
}

function formatMessage(context, event, status) {
  const agent = agentLabel(context, event);
  const statusLabel = statusText(status);
  const contextLabel = contextLabelFromContext(context, event);
  const emoji = emojiForStatus(status);

  return [`${emoji} ${agent} is ${statusLabel}`, contextLabel].join("\n");
}

function agentLabel(context, event) {
  const raw =
    event?.data?.display_agent ??
    event?.data?.agent ??
    context.focused_pane_agent ??
    context.agent ??
    "agent";
  return titleCase(raw);
}

function statusText(status) {
  return String(status ?? "idle").trim().toLowerCase() || "idle";
}

function emojiForStatus(status) {
  return status === "blocked" ? "⚠️" : "✅";
}

function contextLabelFromContext(context, event) {
  const workspace =
    context.workspace_label ?? event?.data?.workspace_id ?? context.workspace_id ?? "workspace";
  const tab = namedTabLabel(context.tab_label);
  return tab ? `${workspace} · ${tab}` : workspace;
}

function namedTabLabel(label) {
  const text = String(label ?? "").trim();
  if (!text || /^\d+$/.test(text)) {
    return undefined;
  }
  return text;
}

function titleCase(value) {
  const text = String(value).trim();
  if (!text) {
    return "Agent";
  }
  return text.charAt(0).toUpperCase() + text.slice(1);
}

async function sendTelegram(token, chatId, text) {
  const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      chat_id: chatId,
      text,
      disable_web_page_preview: true,
    }),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`telegram sendMessage failed: ${response.status} ${body}`);
  }
}
