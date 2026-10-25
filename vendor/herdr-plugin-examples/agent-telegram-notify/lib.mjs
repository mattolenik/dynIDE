import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const pluginRoot = dirname(fileURLToPath(import.meta.url));

export function loadDotEnv(path) {
  const paths = path ? [path] : defaultDotEnvPaths();
  for (const candidate of paths) {
    loadDotEnvFile(candidate);
  }
}

function defaultDotEnvPaths() {
  const paths = [];
  if (process.env.HERDR_PLUGIN_CONFIG_DIR) {
    paths.push(join(process.env.HERDR_PLUGIN_CONFIG_DIR, ".env"));
  }
  paths.push(join(pluginRoot, ".env"));
  return [...new Set(paths)];
}

function loadDotEnvFile(path) {
  let content;
  try {
    content = readFileSync(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      return;
    }
    throw error;
  }

  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }
    const equals = line.indexOf("=");
    if (equals === -1) {
      continue;
    }
    const key = line.slice(0, equals).trim();
    let value = line.slice(equals + 1).trim();
    if (!key || process.env[key] !== undefined) {
      continue;
    }
    process.env[key] = stripQuotes(value);
  }
}

export function envFlag(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") {
    return fallback;
  }
  return !["0", "false", "no", "off"].includes(raw.trim().toLowerCase());
}

export function modePath() {
  if (process.env.HERDR_PLUGIN_STATE_DIR) {
    return join(process.env.HERDR_PLUGIN_STATE_DIR, "enabled");
  }
  const stateHome =
    process.env.XDG_STATE_HOME ||
    (process.env.HOME ? join(process.env.HOME, ".local", "state") : pluginRoot);
  return join(stateHome, "herdr-plugin-examples", "agent-telegram-notify", "enabled");
}

export function modeEnabled() {
  const path = modePath();
  if (!existsSync(path)) {
    return envFlag("HERDR_TELEGRAM_ENABLED", true);
  }
  const raw = readFileSync(path, "utf8").trim().toLowerCase();
  return !["0", "false", "no", "off", "disabled"].includes(raw);
}

export function setMode(enabled) {
  const path = modePath();
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, enabled ? "enabled\n" : "disabled\n", "utf8");
}

export function setWindowTitleIndicator(enabled) {
  if (!envFlag("HERDR_TELEGRAM_SET_TITLE", true)) {
    return;
  }
  const title = process.env.HERDR_TELEGRAM_TITLE || "TG on";
  const args = enabled
    ? ["terminal", "title", "set", title]
    : ["terminal", "title", "clear"];
  const bins = [...new Set([process.env.HERDR_BIN_PATH, "herdr"].filter(Boolean))];
  let lastError;
  for (const herdrBin of bins) {
    const result = spawnSync(herdrBin, args, { encoding: "utf8" });
    if (result.error) {
      lastError = result.error;
      continue;
    }
    if (result.status !== 0) {
      const stderr = result.stderr?.trim();
      console.error(`title command exited ${result.status}${stderr ? `: ${stderr}` : ""}`);
      return;
    }
    const stdout = result.stdout?.trim();
    if (stdout) {
      console.error(`title command response: ${stdout}`);
    }
    return;
  }
  if (lastError) {
    console.error(`title command failed to start: ${lastError.message}`);
  }
}

function stripQuotes(value) {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }
  return value;
}
