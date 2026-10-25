local herdr_bin = os.getenv("HERDR_BIN_PATH") or "herdr"
local root_pane = os.getenv("HERDR_PANE_ID") or ""

if root_pane == "" then
  io.stderr:write("missing HERDR_PANE_ID\n")
  os.exit(0)
end

local function shell_quote(value)
  value = tostring(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function command_string(args)
  local quoted = {}
  for index, value in ipairs(args) do
    quoted[index] = shell_quote(value)
  end
  return table.concat(quoted, " ")
end

local function ok_status(result)
  return result == true or result == 0
end

local function run(args)
  local command = command_string(args) .. " >/dev/null"
  local result, _, code = os.execute(command)
  if ok_status(result) then
    return
  end
  io.stderr:write("command failed: " .. command_string(args) .. "\n")
  os.exit(code or 1)
end

local function capture(args)
  local command = command_string(args) .. " 2>&1"
  local handle = assert(io.popen(command, "r"))
  local output = handle:read("*a")
  local result, _, code = handle:close()
  if not ok_status(result) then
    io.stderr:write("command failed: " .. command_string(args) .. "\n")
    io.stderr:write(output)
    os.exit(code or 1)
  end
  return output
end

local function pane_id_from_json(json)
  return json:match([["pane_id"%s*:%s*"([^"]+)"]])
end

local function herdr(...)
  local args = { herdr_bin, ... }
  run(args)
end

local function herdr_capture(...)
  local args = { herdr_bin, ... }
  return capture(args)
end

herdr("pane", "rename", root_pane, "editor")

local files_json = herdr_capture(
  "pane",
  "split",
  root_pane,
  "--direction",
  "right",
  "--ratio",
  "0.58",
  "--no-focus"
)
local files_pane = pane_id_from_json(files_json)

if not files_pane then
  io.stderr:write("failed to read files pane id\n")
  io.stderr:write(files_json .. "\n")
  os.exit(1)
end

herdr("pane", "rename", files_pane, "files")
herdr("pane", "run", files_pane, "printf 'files\\n\\n'; ls -la; printf '\\nready.\\n'")

local tasks_json = herdr_capture(
  "pane",
  "split",
  files_pane,
  "--direction",
  "down",
  "--ratio",
  "0.5",
  "--no-focus"
)
local tasks_pane = pane_id_from_json(tasks_json)

if not tasks_pane then
  io.stderr:write("failed to read tasks pane id\n")
  io.stderr:write(tasks_json .. "\n")
  os.exit(1)
end

herdr("pane", "rename", tasks_pane, "tasks")
herdr(
  "pane",
  "run",
  tasks_pane,
  "printf 'tasks\\n\\n'; git status --short 2>/dev/null || true; printf '\\ntry: just test\\n'"
)
herdr("pane", "run", root_pane, "nvim .")

print("created dev layout:")
print("  editor: " .. root_pane)
print("  files:  " .. files_pane)
print("  tasks:  " .. tasks_pane)
