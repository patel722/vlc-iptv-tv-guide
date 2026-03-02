-- IPTV TV Guide for VLC (Compatible UI: no set_value())
-- Works on VLC builds where dropdown:set_value() is missing.
-- Features:
--  - Load M3U -> groups + channel list
--  - Load EPG -> compute NOW/NEXT for all channels (one pass)
--  - Search + group filter + scroll list showing NOW/NEXT per row
--  - Click -> Play

function descriptor()
  return {
    title = "IPTV TV Guide",
    version = "3.0",
    author = "patel722",
    shortdesc = "Guide (NOW/NEXT) – compatible UI",
    description = "M3U guide + XMLTV now/next. Compatible with VLC Lua UI lacking dropdown:set_value().",
    capabilities = { "input-listener" }
  }
end

-- UI
local dlg
local lbl_status
local lbl_m3u_src
local lbl_epg_src
local txt_search
local dd_profile
local dd_group
local lst

local btn_profile_edit
local btn_load_m3u
local btn_load_epg
local btn_apply
local btn_play
local btn_details

local lbl_sel
local lbl_now
local lbl_next
local lbl_desc

local txt_editor_name
local txt_editor_m3u
local txt_editor_epg
local lbl_editor_status
local editor_original_name = nil

local cb_profile_pick
local cb_profile_edit
local cb_load_m3u
local cb_load_epg
local cb_apply
local cb_play
local cb_details

-- Data
local channels = {}         -- {name, group, url, tvg_id}
local groups = {}           -- set
local group_list = {}       -- id(string) -> group name
local filtered = {}         -- indices into channels
local tvg_to_channel_index = {}
local epg_summary = {}      -- tvg_id -> { now=..., next=... }
local epg_path = nil
local profiles = {}         -- name -> { m3u, epg }
local profile_ids = {}      -- dropdown id -> profile name
local current_profile_name = "Default"
local saved_m3u = ""
local saved_epg = ""

-- ---------- utils ----------
local function trim(s)
  if s == nil then return "" end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(s) return (s or ""):lower() end

local function pad_right(s, width)
  s = tostring(s or "")
  if #s >= width then return s end
  return s .. string.rep(" ", width - #s)
end

local function fixed_text(s, width)
  s = trim(s or "")
  if #s > width then
    s = s:sub(1, width - 1) .. "..."
  end
  return pad_right(s, width)
end

local function set_status(s)
  if lbl_status then
    local ok = pcall(function()
      lbl_status:set_text("Status: " .. fixed_text(s or "", 72))
    end)
    if not ok then
      lbl_status = nil
    end
  end
end

local function log_err(s)
  pcall(function() vlc.msg.err("[IPTV TV Guide] " .. tostring(s)) end)
end

local function safe_call(name, fn)
  return function()
    local ok, err = pcall(fn)
    if not ok then
      local msg = name .. " error: " .. tostring(err)
      set_status(msg)
      log_err(msg)
    end
  end
end

local function cfg_path()
  return vlc.config.userdatadir() .. "\\iptv_tv_guide.cfg"
end

local function profiles_cfg_path()
  return vlc.config.userdatadir() .. "\\iptv_tv_guide_profiles.cfg"
end

local function sanitize_profile_name(name)
  local s = trim(name or "")
  s = s:gsub("[\r\n\t]", " ")
  s = s:gsub("=", "_")
  s = s:gsub("%s+", " ")
  if s == "" then s = "Default" end
  return s
end

local function sorted_profile_names()
  local names = {}
  for name in pairs(profiles) do
    table.insert(names, name)
  end
  table.sort(names, function(a, b)
    return lower(a) < lower(b)
  end)
  return names
end

local function ensure_profiles()
  local name = sanitize_profile_name(current_profile_name)
  current_profile_name = name
  if not profiles[name] then
    profiles[name] = { m3u = saved_m3u or "", epg = saved_epg or "" }
  end
end

local function read_kv_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end

  local data = f:read("*all") or ""
  f:close()

  local kv = {}
  for line in data:gmatch("[^\r\n]+") do
    local k, v = line:match("^([^=]+)=(.*)$")
    if k then kv[trim(k)] = v end
  end
  return kv
end

local function write_cfg_file(path, active_m3u, active_epg)
  local f = io.open(path, "wb")
  if not f then
    log_err("Config save failed: " .. path)
    return false
  end

  f:write("current_profile=" .. current_profile_name .. "\n")
  f:write("m3u=" .. (active_m3u or "") .. "\n")
  f:write("epg=" .. (active_epg or "") .. "\n")
  for _, name in ipairs(sorted_profile_names()) do
    local p = profiles[name] or {}
    f:write("profile." .. name .. ".m3u=" .. (p.m3u or "") .. "\n")
    f:write("profile." .. name .. ".epg=" .. (p.epg or "") .. "\n")
  end

  f:close()
  return true
end

local function load_cfg()
  profiles = {}
  profile_ids = {}
  current_profile_name = "Default"
  saved_m3u = ""
  saved_epg = ""

  local kv = read_kv_file(profiles_cfg_path()) or read_kv_file(cfg_path())
  if not kv then
    ensure_profiles()
    return {}
  end

  for k, v in pairs(kv) do
    local profile_name = k:match("^profile%.(.*)%.m3u$")
    if profile_name then
      profile_name = sanitize_profile_name(profile_name)
      profiles[profile_name] = profiles[profile_name] or { m3u = "", epg = "" }
      profiles[profile_name].m3u = v or ""
    else
      profile_name = k:match("^profile%.(.*)%.epg$")
      if profile_name then
        profile_name = sanitize_profile_name(profile_name)
        profiles[profile_name] = profiles[profile_name] or { m3u = "", epg = "" }
        profiles[profile_name].epg = v or ""
      end
    end
  end

  current_profile_name = sanitize_profile_name(kv["current_profile"] or current_profile_name)
  saved_m3u = kv["m3u"] or ""
  saved_epg = kv["epg"] or ""

  if next(profiles) == nil then
    profiles[current_profile_name] = { m3u = saved_m3u, epg = saved_epg }
  elseif not profiles[current_profile_name] then
    local names = sorted_profile_names()
    current_profile_name = names[1] or current_profile_name
  end

  ensure_profiles()

  local cur = profiles[current_profile_name] or {}
  if saved_m3u == "" then saved_m3u = cur.m3u or "" end
  if saved_epg == "" then saved_epg = cur.epg or "" end
  profiles[current_profile_name].m3u = saved_m3u
  profiles[current_profile_name].epg = saved_epg

  return {
    m3u = saved_m3u,
    epg = saved_epg,
    current_profile = current_profile_name
  }
end

local function save_cfg(m3u, epg)
  ensure_profiles()
  current_profile_name = sanitize_profile_name(current_profile_name)
  saved_m3u = m3u or ""
  saved_epg = epg or ""
  profiles[current_profile_name] = profiles[current_profile_name] or { m3u = "", epg = "" }
  profiles[current_profile_name].m3u = saved_m3u
  profiles[current_profile_name].epg = saved_epg

  local ok_profiles = write_cfg_file(profiles_cfg_path(), saved_m3u, saved_epg)
  local ok_legacy = write_cfg_file(cfg_path(), saved_m3u, saved_epg)
  return ok_profiles and ok_legacy
end

local function save_current_cfg()
  save_cfg(saved_m3u, saved_epg)
end

local function get_current_sources()
  return saved_m3u or "", saved_epg or ""
end

local function set_source_inputs(m3u, epg)
  saved_m3u = m3u or ""
  saved_epg = epg or ""
  if lbl_m3u_src then
    local shown = saved_m3u ~= "" and saved_m3u or "-"
    shown = fixed_text(shown, 72)
    local ok = pcall(function()
      lbl_m3u_src:set_text(shown)
    end)
    if not ok then
      lbl_m3u_src = nil
    end
  end
  if lbl_epg_src then
    local shown = saved_epg ~= "" and saved_epg or "-"
    shown = fixed_text(shown, 72)
    local ok = pcall(function()
      lbl_epg_src:set_text(shown)
    end)
    if not ok then
      lbl_epg_src = nil
    end
  end
end

local function update_active_profile_label()
  return
end

local function rebuild_profile_dropdown()
  if not dd_profile then return end

  dd_profile:clear()
  profile_ids = {}
  ensure_profiles()

  local ordered = {}
  table.insert(ordered, current_profile_name)
  for _, name in ipairs(sorted_profile_names()) do
    if name ~= current_profile_name then
      table.insert(ordered, name)
    end
  end

  for i, name in ipairs(ordered) do
    local id = i
    dd_profile:add_value(name, id)
    profile_ids[id] = name
    profile_ids[tostring(id)] = name
  end
end

local function current_profile_selection()
  local v = nil
  if dd_profile then
    pcall(function() v = dd_profile:get_value() end)
  end
  v = trim(v or "")
  if v == "" then return current_profile_name end
  if profile_ids[v] then return profile_ids[v] end
  local n = tonumber(v)
  if n and profile_ids[n] then return profile_ids[n] end
  if profiles[v] then return v end
  return current_profile_name
end

local function load_profile_into_inputs(name)
  name = sanitize_profile_name(name or current_profile_name)
  ensure_profiles()
  local p = profiles[name]
  if not p then
    set_status("Profile not found: " .. name)
    return false
  end

  current_profile_name = name
  set_source_inputs(p.m3u or "", p.epg or "")
  update_active_profile_label()
  rebuild_profile_dropdown()
  save_cfg(saved_m3u, saved_epg)
  return true
end

local function save_profile_named(name, m3u, epg, old_name)
  name = sanitize_profile_name(name)
  m3u = trim(m3u or saved_m3u or "")
  epg = trim(epg or saved_epg or "")
  old_name = old_name and sanitize_profile_name(old_name) or nil

  if old_name and old_name ~= name and profiles[old_name] then
    profiles[old_name] = nil
  end

  current_profile_name = name
  profiles[name] = profiles[name] or { m3u = "", epg = "" }
  profiles[name].m3u = m3u
  profiles[name].epg = epg
  set_source_inputs(m3u, epg)
  update_active_profile_label()
  rebuild_profile_dropdown()
  return name, save_cfg(m3u, epg)
end

local function delete_profile_named(name)
  name = sanitize_profile_name(name or current_profile_name)
  if not profiles[name] then
    set_status("Profile not found: " .. name)
    return false
  end

  local names = sorted_profile_names()
  if #names <= 1 then
    profiles[name] = { m3u = "", epg = "" }
    current_profile_name = name
    set_source_inputs("", "")
    update_active_profile_label()
    rebuild_profile_dropdown()
    save_cfg("", "")
    return true
  end

  profiles[name] = nil
  names = sorted_profile_names()
  current_profile_name = names[1] or "Default"
  local p = profiles[current_profile_name] or { m3u = "", epg = "" }
  set_source_inputs(p.m3u or "", p.epg or "")
  update_active_profile_label()
  rebuild_profile_dropdown()
  save_cfg(saved_m3u, saved_epg)
  return true
end

local function sync_profile_from_dropdown()
  local name = current_profile_selection()
  if name ~= current_profile_name then
    return load_profile_into_inputs(name)
  end
  return true
end

local function set_editor_status(s)
  if lbl_editor_status then
    lbl_editor_status:set_text("Status: " .. (s or ""))
  end
end

local function fill_profile_editor(name)
  name = sanitize_profile_name(name or current_profile_name)
  local p = profiles[name] or { m3u = "", epg = "" }
  editor_original_name = name
  if txt_editor_name then txt_editor_name:set_text(name) end
  if txt_editor_m3u then txt_editor_m3u:set_text(p.m3u or "") end
  if txt_editor_epg then txt_editor_epg:set_text(p.epg or "") end
  set_editor_status("Editing: " .. name)
end

local function build_main_dialog()
  dlg = vlc.dialog("IPTV TV Guide")

  dlg:add_label("Profile:", 1, 1, 1, 1)
  dd_profile = dlg:add_dropdown(2, 1, 4, 1)
  if dd_profile and dd_profile.add_callback then
    dd_profile:add_callback(safe_call("Pick Profile", cb_profile_pick))
  end
  btn_profile_edit = dlg:add_button("Edit...", safe_call("Edit Profiles", cb_profile_edit), 6, 1, 1, 1)

  dlg:add_label("M3U:", 1, 2, 1, 1)
  lbl_m3u_src = dlg:add_label("-", 2, 2, 5, 1)

  dlg:add_label("EPG (XMLTV path/URL):", 1, 3, 1, 1)
  lbl_epg_src = dlg:add_label("-", 2, 3, 5, 1)

  btn_load_m3u = dlg:add_button("Load M3U", safe_call("Load M3U", cb_load_m3u), 1, 4, 1, 1)
  btn_load_epg = dlg:add_button("Load EPG", safe_call("Load EPG", cb_load_epg), 2, 4, 1, 1)
  btn_apply = dlg:add_button("Apply", safe_call("Apply", cb_apply), 3, 4, 1, 1)
  btn_play = dlg:add_button("Play", safe_call("Play", cb_play), 4, 4, 2, 1)

  dlg:add_label("Search:", 1, 5, 1, 1)
  txt_search = dlg:add_text_input("", 2, 5, 2, 1)

  dlg:add_label("Group:", 4, 5, 1, 1)
  dd_group = dlg:add_dropdown(5, 5, 2, 1)
  dd_group:add_value("(All)", "ALL")
  group_list["ALL"] = "(All)"

  lst = dlg:add_list(1, 6, 6, 10)

  btn_details = dlg:add_button("Show Details", safe_call("Show Details", cb_details), 1, 16, 2, 1)

  lbl_status = dlg:add_label("Status: ready", 1, 17, 6, 1)

  dlg:add_label("— Details —", 1, 18, 6, 1)
  lbl_sel = dlg:add_label("Selected: -", 1, 19, 6, 1)
  lbl_now = dlg:add_label("NOW: -", 1, 20, 6, 1)
  lbl_next = dlg:add_label("NEXT: -", 1, 21, 6, 1)
  lbl_desc = dlg:add_label("", 1, 22, 6, 3)

  local cfg = load_cfg()
  rebuild_profile_dropdown()
  set_source_inputs(cfg["m3u"] or "", cfg["epg"] or "")

  set_status("Ready. Pick a profile or click Edit... to manage profiles.")
end

local function close_profile_manager()
  if dlg then dlg:delete() end
  dlg = nil
  txt_editor_name = nil
  txt_editor_m3u = nil
  txt_editor_epg = nil
  lbl_editor_status = nil
  editor_original_name = nil
  build_main_dialog()
end

cb_profile_pick = function()
  if sync_profile_from_dropdown() then
    set_status("Profile loaded: " .. current_profile_name)
  end
end

local function cb_profile_manager_new()
  editor_original_name = nil
  if txt_editor_name then txt_editor_name:set_text("New Profile") end
  if txt_editor_m3u then txt_editor_m3u:set_text("") end
  if txt_editor_epg then txt_editor_epg:set_text("") end
  set_editor_status("New profile")
end

local function cb_profile_manager_save()
  local name = txt_editor_name and trim(txt_editor_name:get_text()) or current_profile_name
  local m3u = txt_editor_m3u and trim(txt_editor_m3u:get_text()) or ""
  local epg = txt_editor_epg and trim(txt_editor_epg:get_text()) or ""
  local ok = nil
  name, ok = save_profile_named(name, m3u, epg, editor_original_name)
  if ok then
    editor_original_name = name
    fill_profile_editor(name)
    set_status("Profile saved: " .. name)
  else
    set_editor_status("Save failed")
  end
end

local function cb_profile_manager_delete()
  local name = editor_original_name or (txt_editor_name and trim(txt_editor_name:get_text())) or current_profile_name
  if delete_profile_named(name) then
    fill_profile_editor(current_profile_name)
    set_status("Profile removed: " .. name)
  else
    set_editor_status("Delete failed")
  end
end

cb_profile_edit = function()
  sync_profile_from_dropdown()
  if dlg then dlg:delete() end
  dlg = vlc.dialog("IPTV Profiles")
  txt_search = nil
  dd_profile = nil
  dd_group = nil
  lst = nil
  lbl_status = nil
  lbl_m3u_src = nil
  lbl_epg_src = nil
  lbl_sel = nil
  lbl_now = nil
  lbl_next = nil
  lbl_desc = nil

  dlg:add_label("Name:", 1, 1, 1, 1)
  txt_editor_name = dlg:add_text_input("", 2, 1, 5, 1)
  dlg:add_label("M3U:", 1, 2, 1, 1)
  txt_editor_m3u = dlg:add_text_input("", 2, 2, 5, 1)
  dlg:add_label("EPG:", 1, 3, 1, 1)
  txt_editor_epg = dlg:add_text_input("", 2, 3, 5, 1)
  dlg:add_button("New", safe_call("Profile New", cb_profile_manager_new), 1, 4, 1, 1)
  dlg:add_button("Save", safe_call("Profile Save", cb_profile_manager_save), 2, 4, 1, 1)
  dlg:add_button("Delete", safe_call("Profile Delete", cb_profile_manager_delete), 3, 4, 1, 1)
  dlg:add_button("Close", safe_call("Profile Close", close_profile_manager), 4, 4, 1, 1)
  lbl_editor_status = dlg:add_label("Status: ready", 1, 5, 6, 1)
  fill_profile_editor(current_profile_name)
end

local function html_unescape(s)
  if not s then return "" end
  s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  s = s:gsub("&quot;", "\""):gsub("&#39;", "'")
  return s
end

local function shorten(s, maxlen)
  s = trim(s or "")
  if #s <= maxlen then return s end
  return s:sub(1, maxlen-1) .. "…"
end

local function parse_xmltv_time(t)
  if not t then return nil end
  local y,mo,d,h,mi,se = t:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
  if not y then return nil end

  local epoch = os.time({
    year=tonumber(y), month=tonumber(mo), day=tonumber(d),
    hour=tonumber(h), min=tonumber(mi), sec=tonumber(se)
  })

  local tzsign, tzh, tzm = t:match("([%+%-])(%d%d)(%d%d)$")
  if tzsign and tzh and tzm then
    local offset = tonumber(tzh) * 3600 + tonumber(tzm) * 60
    if tzsign == "+" then epoch = epoch - offset else epoch = epoch + offset end
  end
  return epoch
end

local function fmt_hhmm(epoch)
  if not epoch then return "" end
  return os.date("%I:%M %p", epoch)
end

local function mins_remaining(stop_epoch)
  if not stop_epoch then return "-" end
  local diff = stop_epoch - os.time()
  if diff <= 0 then return "0m" end
  return tostring(math.floor(diff/60)) .. "m"
end

local function line_iter_from_string(data)
  local text = data or ""
  local pos = 1
  local len = #text

  return function()
    if pos > len then return nil end
    local s, e = text:find("\n", pos, true)
    if s then
      local line = text:sub(pos, s - 1):gsub("\r$", "")
      pos = e + 1
      return line
    end

    local line = text:sub(pos)
    pos = len + 1
    return line
  end
end

local function powershell_single_quote(s)
  return (tostring(s or ""):gsub("'", "''"))
end

local function temp_fetch_path()
  return vlc.config.userdatadir() .. "\\iptv_tv_guide_fetch.tmp"
end

local function temp_epg_fetch_path()
  return vlc.config.userdatadir() .. "\\iptv_tv_guide_epg.tmp"
end

local function download_url_to_file(url, out_path)
  if not os or not os.execute then return false, "Shell fetch unavailable" end

  pcall(function() os.remove(out_path) end)

  local cmd = string.format(
    [[powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "$ProgressPreference = 'SilentlyContinue'; try { Invoke-WebRequest -UseBasicParsing -Uri '%s' -OutFile '%s' } catch { exit 1 }"]],
    powershell_single_quote(url),
    powershell_single_quote(out_path)
  )

  local ok = pcall(function() os.execute(cmd) end)
  if not ok then
    return false, "Shell fetch failed to start"
  end

  local f = io.open(out_path, "rb")
  if not f then
    return false, "Shell fetch did not create a file"
  end

  local first = f:read(1)
  f:close()
  if first == nil then
    pcall(function() os.remove(out_path) end)
    return false, "URL returned no data"
  end

  return true, nil
end

local function read_url_text_powershell(url)
  local tmp = temp_fetch_path()
  local ok, err = download_url_to_file(url, tmp)
  if not ok then return nil, err end

  local f = io.open(tmp, "rb")
  if not f then
    return nil, "Shell fetch did not create a file"
  end

  local data = f:read("*all") or ""
  f:close()
  pcall(function() os.remove(tmp) end)

  if data == "" then
    return nil, "URL returned no data"
  end

  return data, nil
end

local function line_iter_from_url_stream(url)
  local st = vlc.stream(url)
  if not st then return nil, "Failed to open URL stream" end

  local buffer = ""
  return function()
    while true do
      local s = buffer:find("\n", 1, true)
      if s then
        local line = buffer:sub(1, s-1)
        buffer = buffer:sub(s+1)
        return line:gsub("\r$", "")
      end

      local chunk = st:read(65536)
      if chunk == nil then
        if #buffer > 0 then
          local line = buffer
          buffer = ""
          return line:gsub("\r$", "")
        end
        return nil
      end
      if #chunk == 0 then return nil end
      buffer = buffer .. chunk
    end
  end, nil
end

-- ---------- IO ----------
local function line_iter_from_path_or_url(path_or_url)
  local src = trim(path_or_url or "")
  if src == "" then return nil, "Empty input" end

  if src:match("^https?://") then
    local data, shell_err = read_url_text_powershell(src)
    if data then
      return line_iter_from_string(data), nil
    end

    local it, err = line_iter_from_url_stream(src)
    if not it then return nil, shell_err or err end
    return it, nil
  else
    local f = io.open(src, "rb")
    if not f then return nil, "Failed to open file: " .. src end
    return function()
      local line = f:read("*line")
      if not line then f:close(); return nil end
      return line
    end, nil
  end
end

-- ---------- resets ----------
local function reset_m3u()
  channels = {}
  groups = {}
  group_list = {}
  filtered = {}
  tvg_to_channel_index = {}
end

local function reset_epg()
  epg_summary = {}
end

-- ---------- M3U parse ----------
local function parse_m3u(next_line)
  reset_m3u()

  local pending = nil
  while true do
    local line = next_line()
    if not line then break end
    line = trim(line)

    if line:match("^#EXTINF") then
      local tvg_id = trim(line:match('tvg%-id="(.-)"') or "")
      local name = trim(line:match(",(.*)$") or "")
      local group = trim((line:match('group%-title="(.-)"') or ""):gsub("%s+", " "))
      pending = { tvg_id=tvg_id, name=name, group=group }
      if group ~= "" then groups[group] = true end

    elseif pending and line ~= "" and not line:match("^#") then
      local url = trim(line)
      local ch = {
        name = pending.name ~= "" and pending.name or url,
        group = pending.group,
        url = url,
        tvg_id = pending.tvg_id
      }
      table.insert(channels, ch)
      local idx = #channels
      if ch.tvg_id ~= "" and tvg_to_channel_index[ch.tvg_id] == nil then
        tvg_to_channel_index[ch.tvg_id] = idx
      end
      pending = nil
    end
  end
end

local function rebuild_group_dropdown()
  dd_group:clear()
  group_list = {}

  -- We DO NOT call dd_group:set_value (not available)
  -- First entry is always All. Many VLC builds auto-select first entry.
  dd_group:add_value("(All)", 1)
  group_list[1] = "(All)"
  group_list["1"] = "(All)"
  group_list["ALL"] = "(All)"

  local list = {}
  for g in pairs(groups) do table.insert(list, g) end
  table.sort(list)

  local n = 1
  for _, g in ipairs(list) do
    n = n + 1
    local id = n
    dd_group:add_value(g, id)
    group_list[id] = g
    group_list[tostring(id)] = g
  end
end

local function current_group_selection()
  local v = nil
  pcall(function() v = dd_group:get_value() end) -- get_value exists on your build
  v = trim(v or "")
  if v == "" then return "(All)" end
  if group_list[v] then return group_list[v] end
  local n = tonumber(v)
  if n and group_list[n] then return group_list[n] end
  if groups[v] then return v end
  return "(All)"
end

-- ---------- EPG compute now/next (one pass) ----------
local function init_epg_summary()
  reset_epg()
  for tvg_id in pairs(tvg_to_channel_index) do
    epg_summary[tvg_id] = { now=nil, next=nil }
  end
end

local function compute_epg_now_next(epg_src)
  epg_path = epg_src
  init_epg_summary()

  local next_line, err = nil, nil
  local epg_tmp = nil
  if epg_src:match("^https?://") then
    epg_tmp = temp_epg_fetch_path()
    local ok = nil
    ok, err = download_url_to_file(epg_src, epg_tmp)
    if ok then
      next_line, err = line_iter_from_path_or_url(epg_tmp)
    end
    if not next_line then
      pcall(function() os.remove(epg_tmp) end)
      epg_tmp = nil
      next_line, err = line_iter_from_path_or_url(epg_src)
    end
  else
    next_line, err = line_iter_from_path_or_url(epg_src)
  end
  if not next_line then
    set_status("EPG open failed: " .. err)
    return false
  end

  local now_ts = os.time()

  local remaining = 0
  for _ in pairs(epg_summary) do remaining = remaining + 1 end

  local in_prog = false
  local prog_channel = ""
  local prog_start, prog_stop = nil, nil
  local prog_title, prog_desc = "", ""

  local function done_for(cid)
    local s = epg_summary[cid]
    return s and s.now and s.next
  end

  while true do
    local line = next_line()
    if not line then break end
    line = trim(line:gsub("\r$", ""))

    if (not in_prog) and line:find("<programme", 1, true) then
      local ch = line:match('channel="(.-)"') or ""
      if epg_summary[ch] ~= nil then
        in_prog = true
        prog_channel = ch
        prog_start = parse_xmltv_time(line:match('start="(.-)"') or "")
        prog_stop  = parse_xmltv_time(line:match('stop="(.-)"') or "")
        prog_title, prog_desc = "", ""
      end

    elseif in_prog then
      local t = line:match("<title[^>]*>(.-)</title>")
      if t then prog_title = trim(html_unescape(t)) end
      local d = line:match("<desc[^>]*>(.-)</desc>")
      if d then prog_desc = trim(html_unescape(d)) end

      if line:find("</programme>", 1, true) then
        local s = epg_summary[prog_channel]
        if s and prog_start and prog_stop then
          if (prog_start <= now_ts) and (now_ts < prog_stop) then
            if not s.now then s.now = {start=prog_start, stop=prog_stop, title=prog_title, desc=prog_desc} end
          elseif (prog_start > now_ts) then
            if not s.next then s.next = {start=prog_start, stop=prog_stop, title=prog_title, desc=prog_desc} end
          end

          if done_for(prog_channel) and not s.__done then
            s.__done = true
            remaining = remaining - 1
            if remaining <= 0 then break end
          end
        end

        in_prog = false
        prog_channel = ""
      end
    end
  end
  if epg_tmp then
    pcall(function() os.remove(epg_tmp) end)
  end
  return true
end

-- ---------- render ----------
local function apply_filters_and_render()
  lst:clear()
  filtered = {}

  local q = lower(trim(txt_search:get_text()))
  local gsel = current_group_selection()

  for i, ch in ipairs(channels) do
    local ok = true

    if gsel ~= "(All)" then ok = (ch.group == gsel) end

    if ok and q ~= "" then
      local hay = lower(ch.name) .. " " .. lower(ch.group or "")
      local s = (ch.tvg_id ~= "" and epg_summary[ch.tvg_id]) or nil
      if s and s.now and s.now.title then
        hay = hay .. " " .. lower(s.now.title)
      end
      if s and s.next and s.next.title then
        hay = hay .. " " .. lower(s.next.title)
      end
      ok = hay:find(q, 1, true) ~= nil
    end

    if ok then
      table.insert(filtered, i)

      local nowtxt, nexttxt, rem = "-", "-", "-"
      local s = (ch.tvg_id ~= "" and epg_summary[ch.tvg_id]) or nil

      if s and s.now then
        nowtxt = string.format("%s–%s %s",
          fmt_hhmm(s.now.start), fmt_hhmm(s.now.stop),
          s.now.title ~= "" and shorten(s.now.title, 42) or "-")
        rem = mins_remaining(s.now.stop)
      end

      if s and s.next then
        nexttxt = string.format("%s %s",
          fmt_hhmm(s.next.start),
          s.next.title ~= "" and shorten(s.next.title, 42) or "-")
      end

      local label = fixed_text(string.format("%s  |  NOW: %s (%s)  |  NEXT: %s",
        shorten(ch.name, 28), nowtxt, rem, nexttxt), 96)

      lst:add_value(label, tostring(#filtered))
    end
  end

  set_status(string.format("Channels: %d | Showing: %d | Group: %s",
    #channels, #filtered, gsel))
end

-- ---------- selection/details/play ----------
local function get_selected_filtered_index()
  local sel = lst:get_selection()
  if not sel then return nil end
  for k, _ in pairs(sel) do return tonumber(k) end
  return nil
end

local function show_details_for_selected()
  local fidx = get_selected_filtered_index()
  if not fidx then return end
  local idx = filtered[fidx]
  if not idx then return end
  local ch = channels[idx]
  if not ch then return end

  lbl_sel:set_text("Selected: " .. fixed_text(shorten(ch.name, 60) .. (ch.group ~= "" and ("  ["..shorten(ch.group, 24).."]") or ""), 72))

  local s = (ch.tvg_id ~= "" and epg_summary[ch.tvg_id]) or nil
  if s and s.now then
    lbl_now:set_text(string.format("NOW:  %s–%s  %s",
      fmt_hhmm(s.now.start), fmt_hhmm(s.now.stop), fixed_text(s.now.title ~= "" and shorten(s.now.title, 60) or "-", 52)))
    lbl_desc:set_text(fixed_text(s.now.desc and s.now.desc ~= "" and ("DESC: " .. shorten(s.now.desc, 72)) or "", 72))
  else
    lbl_now:set_text("NOW:  " .. fixed_text("-", 52))
    lbl_desc:set_text(fixed_text("", 72))
  end

  if s and s.next then
    lbl_next:set_text(string.format("NEXT: %s–%s  %s",
      fmt_hhmm(s.next.start), fmt_hhmm(s.next.stop), fixed_text(s.next.title ~= "" and shorten(s.next.title, 60) or "-", 52)))
  else
    lbl_next:set_text("NEXT: " .. fixed_text("-", 52))
  end
end

local function play_selected()
  local fidx = get_selected_filtered_index()
  if not fidx then 
    set_status("No channel selected.")
    log_err("Play: No channel selected.")
    return 
  end
  local idx = filtered[fidx]
  if not idx then 
    set_status("Selected index not found in filtered list.")
    log_err("Play: Selected index not found in filtered list.")
    return 
  end
  local ch = channels[idx]
  if not ch then 
    set_status("Channel not found.")
    log_err("Play: Channel not found.")
    return 
  end
  if not ch.url or ch.url == "" then 
    set_status("Channel URL missing.")
    log_err("Play: Channel URL missing.")
    return 
  end

  set_status("Playing: " .. ch.name .. " (" .. ch.url .. ")")
  log_err("Play: Attempting to play " .. ch.name .. " (" .. ch.url .. ")")
  vlc.playlist.add({ { path = ch.url, name = ch.name } })
  vlc.playlist.play()
end

-- ---------- callbacks ----------
cb_load_m3u = function()
  sync_profile_from_dropdown()
  local m3u_src = trim(saved_m3u)
  if m3u_src == "" then set_status("Set M3U path/URL"); return end

  set_status("Loading M3U…")
  local it, err = line_iter_from_path_or_url(m3u_src)
  if not it then set_status("M3U open failed: " .. err); return end

  parse_m3u(it)
  rebuild_group_dropdown()
  reset_epg() -- EPG not loaded yet
  apply_filters_and_render()
  if #channels > 0 then
    set_status("Loaded " .. tostring(#channels) .. " channels.")
  else
    set_status("No channels found in M3U.")
  end

  save_cfg(m3u_src, trim(saved_epg))
  -- Status already set above
end

cb_load_epg = function()
  sync_profile_from_dropdown()
  if #channels == 0 then set_status("Load M3U first."); return end
  local epg_src = trim(saved_epg)
  if epg_src == "" then set_status("Set EPG path/URL"); return end

  set_status("Computing EPG NOW/NEXT…")
  local ok = compute_epg_now_next(epg_src)
  if not ok then return end

  save_cfg(trim(saved_m3u), epg_src)
  apply_filters_and_render()
  set_status("EPG loaded. NOW/NEXT computed for all channels.")
end

cb_apply = function()
  sync_profile_from_dropdown()
  apply_filters_and_render()
end

cb_play = function()
  sync_profile_from_dropdown()
  play_selected()
  show_details_for_selected()
end

cb_details = function()
  sync_profile_from_dropdown()
  show_details_for_selected()
end

-- ---------- lifecycle ----------
function activate()
  build_main_dialog()
end

function close()
  if dlg then dlg:delete() end
  dlg = nil
  dd_profile = nil
  dd_group = nil
  txt_search = nil
  lst = nil
  lbl_status = nil
  lbl_m3u_src = nil
  lbl_epg_src = nil
  lbl_sel = nil
  lbl_now = nil
  lbl_next = nil
  lbl_desc = nil
  txt_editor_name = nil
  txt_editor_m3u = nil
  txt_editor_epg = nil
  lbl_editor_status = nil
  editor_original_name = nil
end

function deactivate()
  dlg = nil
  dd_profile = nil
  dd_group = nil
  txt_search = nil
  lst = nil
  lbl_status = nil
  lbl_m3u_src = nil
  lbl_epg_src = nil
  lbl_sel = nil
  lbl_now = nil
  lbl_next = nil
  lbl_desc = nil
  txt_editor_name = nil
  txt_editor_m3u = nil
  txt_editor_epg = nil
  lbl_editor_status = nil
  editor_original_name = nil
end
