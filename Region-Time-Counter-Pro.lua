-- Region Time Counter Pro (macOS-safe UI)
-- Author: 34birds
-- @version 3.0.0
-- @description Wrap-list variant: TOP border fixed (safe-zone guards are used), BOTTOM border NOT fixed yet (intentional). Markers are shown but don't affect totals.
-- @about
--   No js_ReaScriptAPI required.

local r = reaper
local proj = 0

-- ===== Fixed window =====
local WINDOW_TITLE = "Region Time Counter Pro"
local WIN_W, WIN_H = 520, 520

-- ===== Typography =====
local FONT_MAIN  = "Helvetica"
local TITLE_SIZE = 26
local LABEL_SIZE = 24
local VALUE_SIZE = 24
local LIST_SIZE  = 14
local SEARCH_SIZE= 16

-- ===== Layout =====
local PAD = 14
local GAP = 14

local BTN_W = 90
local BTN_H = 26
local BTN_GAP = 10
local SEARCH_H = 26

local STATS_LINE_GAP = 5
local STATS_TO_CONTROLS_GAP = 18

-- List/table look
local ROW_PAD_Y  = 8
local COL_GAP    = 3
local CELL_PAD_X = 7

-- These were your “almost perfect” settings (TOP fixed via padding):
local TEXT_STRICT_CLIP = false     -- true = strict (A), false = soft (B)
local TEXT_CLIP_PAD_TOP = 1       -- top safe-zone padding (fixes TOP border bleed)
local TEXT_CLIP_PAD_BOT = 12        -- bottom NOT fixed yet (intentional for this rollback)

local ICON_W = 25          -- col 0: square/check
local COL1_W = 35          -- col 1: M#/R#
local LEN_W  = 72          -- reserved on the right of col 2 for hh:mm:ss (regions only)

local LINE_H = LIST_SIZE + 4

-- Scroll (pixel-based because variable row height)
local SCROLL_W = 12
local SCROLL_MARGIN_R = 0
local SCROLL_RESERVE = SCROLL_W + SCROLL_MARGIN_R + 6
local WHEEL_STEP_PX = (LINE_H * 2)

-- Refresh
local AUTO_REFRESH = true
local REFRESH_INTERVAL_SEC = 0.5

-- Persistence (in project)
local EXT_SECTION = "RTCPro"
local EXT_KEY_CHECKED = "checked_keys" -- stores "R12,M5,..." (prefix + id)

-- ===== Colors (light theme) =====
local BG_R, BG_G, BG_B = 223/255, 225/255, 225/255
local SEL_R, SEL_G, SEL_B = 241/255, 241/255, 241/255
local BORDER_A = 0.10

-- squares
local SQ_REGION_R, SQ_REGION_G, SQ_REGION_B = 0.55, 0.55, 0.55
local SQ_MARKER_R, SQ_MARKER_G, SQ_MARKER_B = 0.75, 0.10, 0.10
local SQ_FILL_A = 0.06
local SQ_BORDER_A = 0.85

-- checkmark
local CHECK_TX_R, CHECK_TX_G, CHECK_TX_B = 0, 0, 0

-- Scrollbar (only thumb)
local SCROLL_THUMB_A = 0.38

-- Stats colors (for light bg)
local COL_TOTAL = {0.10, 0.55, 0.15, 1}
local COL_SEL   = {0.65, 0.52, 0.05, 1}

-- ===== State =====
local items = {}            -- merged list: markers + regions, time-sorted
local region_by_id = {}     -- regions only, for totals/selected
local checked = {}          -- checked[key] = true, where key is "R12" or "M7"

local total_sec = 0.0
local selected_sec = 0.0
local last_refresh = 0

-- filtered list
local search_query = ""
local search_focus = false
local display = {}

-- scroll + cache
local scroll_y = 0
local total_h = 0
local max_scroll = 0
local row_cache = {} -- [i] = {h=..., lines={...}}

-- scrollbar drag
local sb_drag = false
local sb_drag_offset = 0

-- shift anchor (display indices)
local last_clicked_disp_index = nil

-- ===== Helpers =====
local function clamp(x, a, b) if x<a then return a elseif x>b then return b else return x end end
local function trim(s) if not s then return "" end return (tostring(s):gsub("^%s+",""):gsub("%s+$","")) end
local function in_rect(mx,my,x,y,w,h) return mx>=x and mx<(x+w) and my>=y and my<(y+h) end

local function format_hhmmss(sec)
  sec = math.max(0, math.floor(sec + 0.5))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  return string.format("%02d:%02d:%02d", h, m, s)
end

local function union_length(intervals)
  if not intervals or #intervals == 0 then return 0.0 end
  table.sort(intervals, function(a,b)
    if a[1]==b[1] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  local total = 0.0
  local cur_s, cur_e = intervals[1][1], intervals[1][2]
  for i=2,#intervals do
    local s,e = intervals[i][1], intervals[i][2]
    if s <= cur_e then
      if e > cur_e then cur_e = e end
    else
      total = total + (cur_e - cur_s)
      cur_s, cur_e = s, e
    end
  end
  total = total + (cur_e - cur_s)
  return total
end

local function lower(s) return string.lower(tostring(s or "")) end
local function contains_ci(hay, needle)
  if needle == "" then return true end
  return lower(hay):find(lower(needle), 1, true) ~= nil
end

-- UTF-8 safe iterator
local function utf8_chars(s)
  return tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

local function make_key(isrgn, id)
  return (isrgn and "R" or "M") .. tostring(tonumber(id) or 0)
end

-- ===== Persistence =====
local function save_checked()
  local keys = {}
  for k,on in pairs(checked) do
    if on then keys[#keys+1] = tostring(k) end
  end
  table.sort(keys)
  r.SetProjExtState(proj, EXT_SECTION, EXT_KEY_CHECKED, table.concat(keys, ","))
end

local function load_checked()
  local ret, s = r.GetProjExtState(proj, EXT_SECTION, EXT_KEY_CHECKED)
  if ret ~= 1 or not s or s == "" then return end
  checked = {}
  for token in tostring(s):gmatch("[RM]%d+") do
    checked[token] = true
  end
end

-- ===== Data rebuild (markers + regions) =====
local function rebuild_items()
  items = {}
  region_by_id = {}

  local _, numMarkers, numRegions = r.CountProjectMarkers(proj)
  local total = numMarkers + numRegions

  for enum_idx = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name, shown_id = r.EnumProjectMarkers3(proj, enum_idx)
    if retval then
      shown_id = tonumber(shown_id) or 0
      local it = {
        enum_idx = enum_idx,
        isrgn = (isrgn == true),
        pos = pos or 0,
        rgnend = rgnend or 0,
        name = name or "",
        shown_id = shown_id,
        key = make_key(isrgn == true, shown_id),
        len = 0.0,
      }

      if it.isrgn and (it.rgnend > it.pos) then
        it.len = (it.rgnend - it.pos)
        region_by_id[shown_id] = { start=it.pos, ["end"]=it.rgnend }
      end

      items[#items+1] = it
    end
  end

  table.sort(items, function(a,b)
    if a.pos == b.pos then
      if a.isrgn == b.isrgn then return a.shown_id < b.shown_id end
      return (a.isrgn == false)
    end
    return a.pos < b.pos
  end)

  -- prune checks that no longer exist
  local existing = {}
  for _,it in ipairs(items) do existing[it.key] = true end
  for k,_ in pairs(checked) do
    if not existing[k] then checked[k] = nil end
  end
end

local function compute_total()
  local intervals = {}
  for _,reg in pairs(region_by_id) do
    intervals[#intervals+1] = {reg.start, reg["end"]}
  end
  total_sec = union_length(intervals)
end

local function compute_selected()
  local intervals = {}
  for k,on in pairs(checked) do
    if on and k:sub(1,1) == "R" then
      local id = tonumber(k:sub(2))
      local reg = id and region_by_id[id]
      if reg then intervals[#intervals+1] = {reg.start, reg["end"]} end
    end
  end
  selected_sec = union_length(intervals)
end

local function rebuild_display(reset_anchor)
  display = {}
  local q = trim(search_query)
  for _,it in ipairs(items) do
    local tag = (it.isrgn and "R" or "M") .. tostring(it.shown_id)
    if q == "" or contains_ci(it.name, q) or contains_ci(tag, q) then
      display[#display+1] = it
    end
  end
  if reset_anchor then last_clicked_disp_index = nil end
end

local function refresh(reset_anchor)
  rebuild_items()
  compute_total()
  compute_selected()
  rebuild_display(reset_anchor)
  last_refresh = r.time_precise()
end

-- ===== Wrap (rollback state: same as your last pasted version; single long word WITHOUT spaces can still be unwrapped) =====
local function wrap_text_to_width(text, max_w)
  if not text or text == "" then return {""} end
  if max_w < 20 then return {tostring(text)} end

  local lines = {}
  local words = {}

  for w in tostring(text):gmatch("%S+") do
    words[#words+1] = w
  end
  if #words == 0 then return {""} end

  local cur = words[1]

  for i = 2, #words do
    local cand = cur .. " " .. words[i]
    if gfx.measurestr(cand) <= max_w then
      cur = cand
    else
      if gfx.measurestr(words[i]) > max_w then
        lines[#lines+1] = cur
        cur = ""

        local chunk = ""
        local s = words[i]
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          local cand2 = chunk .. ch
          if gfx.measurestr(cand2) <= max_w then
            chunk = cand2
          else
            if chunk ~= "" then lines[#lines+1] = chunk end
            chunk = ch
          end
        end
        cur = chunk
      else
        lines[#lines+1] = cur
        cur = words[i]
      end
    end
  end

  if cur ~= "" then lines[#lines+1] = cur end
  return lines
end

local function calc_row_h(num_lines)
  if num_lines < 1 then num_lines = 1 end
  return (ROW_PAD_Y * 2) + LIST_SIZE + ((num_lines - 1) * LINE_H)
end

-- ===== UI atoms =====
local function draw_button(x,y,w,h,label,hot)
  if hot then gfx.set(0,0,0,0.08) else gfx.set(0,0,0,0.05) end
  gfx.rect(x,y,w,h,1)
  gfx.set(0,0,0,0.20); gfx.rect(x,y,w,h,0)

  gfx.setfont(1, FONT_MAIN, LIST_SIZE)
  gfx.set(0,0,0,1)
  local tw, th = gfx.measurestr(label)
  gfx.x = x + math.floor((w - tw)/2)
  gfx.y = y + math.floor((h - th)/2)
  gfx.drawstr(label)
end

local function draw_search_box(x,y,w,h,focused)
  gfx.set(0,0,0,0.04); gfx.rect(x,y,w,h,1)
  if focused then gfx.set(0,0,0,0.30) else gfx.set(0,0,0,0.20) end
  gfx.rect(x,y,w,h,0)

  gfx.setfont(1, FONT_MAIN, SEARCH_SIZE)
  local text = search_query
  if text == "" and not focused then
    gfx.set(0,0,0,0.35)
    gfx.x = x + 8; gfx.y = y + 5
    gfx.drawstr("Search markers/regions…")
  else
    gfx.set(0,0,0,1)
    gfx.x = x + 8; gfx.y = y + 5
    gfx.drawstr(text)
    if focused then
      local tw = select(1, gfx.measurestr(text))
      gfx.x = x + 8 + tw + 1
      gfx.y = y + 5
      gfx.drawstr("|")
    end
  end
end

local function draw_square(x, y, size, is_region)
  if is_region then
    gfx.set(SQ_REGION_R, SQ_REGION_G, SQ_REGION_B, SQ_BORDER_A)
  else
    gfx.set(SQ_MARKER_R, SQ_MARKER_G, SQ_MARKER_B, SQ_BORDER_A)
  end
  gfx.rect(x, y, size, size, 0)

  if is_region then
    gfx.set(SQ_REGION_R, SQ_REGION_G, SQ_REGION_B, SQ_FILL_A)
  else
    gfx.set(SQ_MARKER_R, SQ_MARKER_G, SQ_MARKER_B, SQ_FILL_A)
  end
  gfx.rect(x+1, y+1, size-2, size-2, 1)
end

local function draw_checkmark(x, y)
  gfx.set(CHECK_TX_R, CHECK_TX_G, CHECK_TX_B, 1)
  gfx.x = x
  gfx.y = y
  gfx.drawstr("✓")
end

-- ===== Scrollbar (pixel-based) =====
local function clamp_scroll()
  if scroll_y < 0 then scroll_y = 0 end
  if scroll_y > max_scroll then scroll_y = max_scroll end
  scroll_y = math.floor(scroll_y + 0.5)
end

local function get_thumb(list_y, list_h)
  local track_y = list_y
  local track_h = list_h
  local total = math.max(1, total_h)
  local visible_ratio = list_h / total
  local thumb_h = math.max(18, track_h * visible_ratio)
  if thumb_h > track_h then thumb_h = track_h end

  local thumb_y = track_y
  if max_scroll > 0 then
    thumb_y = track_y + (track_h - thumb_h) * (scroll_y / max_scroll)
  end
  return math.floor(thumb_y), math.floor(thumb_h)
end

local function set_scroll_from_thumb(my, list_y, list_h, thumb_h, drag_offset)
  local track_y = list_y
  local track_h = list_h
  local range = track_h - thumb_h
  if range <= 0 or max_scroll <= 0 then scroll_y = 0; return end
  local new_thumb_y = clamp(my - drag_offset, track_y, track_y + range)
  local t = (new_thumb_y - track_y) / range
  scroll_y = t * max_scroll
  clamp_scroll()
end

-- ===== Checking logic =====
local function set_all(on)
  if on then
    for _,it in ipairs(items) do checked[it.key] = true end
  else
    checked = {}
  end
  compute_selected()
  save_checked()
end

local function apply_range(from_i, to_i, on)
  if from_i > to_i then from_i, to_i = to_i, from_i end
  for i=from_i, to_i do
    local it = display[i]
    if it then
      if on then checked[it.key] = true else checked[it.key] = nil end
    end
  end
end

-- ===== Hit test (variable heights) =====
local function hit_test_row(mx, my, content_x, content_y, content_w, content_h)
  if mx < content_x or mx > (content_x + content_w) then return nil end
  if my < content_y or my > (content_y + content_h) then return nil end

  local yy = content_y - scroll_y
  for i=1,#display do
    local rh = (row_cache[i] and row_cache[i].h) or (ROW_PAD_Y*2 + LIST_SIZE)
    if my >= yy and my <= (yy + rh) then return i end
    yy = yy + rh
  end
  return nil
end

-- ===== Keys =====
local KEY_BACKSPACE = 8
local KEY_ENTER1    = 13
local KEY_ENTER2    = 10
local KEY_UP   = 30064
local KEY_DOWN = 1685026670

local function handle_key(ch)
  if ch == 0 then return end

  if ch == KEY_UP then scroll_y = scroll_y - WHEEL_STEP_PX; clamp_scroll(); return end
  if ch == KEY_DOWN then scroll_y = scroll_y + WHEEL_STEP_PX; clamp_scroll(); return end

  if not search_focus then return end

  if ch == KEY_BACKSPACE then
    if #search_query > 0 then
      search_query = search_query:sub(1, #search_query-1)
      rebuild_display(true)
      scroll_y = 0
    end
    return
  elseif ch == KEY_ENTER1 or ch == KEY_ENTER2 then
    search_focus = false
    return
  end

  if ch >= 32 and ch <= 126 then
    search_query = search_query .. string.char(ch)
    rebuild_display(true)
    scroll_y = 0
  end
end

-- ===== Main loop =====
local last_mouse_cap = 0

local function loop()
  if gfx.w ~= WIN_W or gfx.h ~= WIN_H then
    gfx.init(WINDOW_TITLE, WIN_W, WIN_H, 0, 200, 150)
  end

  local ch = gfx.getchar()
    if ch < 0 or ch == 27 then return end
  if ch > 0 then handle_key(ch) end

  if AUTO_REFRESH then
    local now = r.time_precise()
    if (now - last_refresh) >= REFRESH_INTERVAL_SEC then
      local keep_query = search_query
      refresh(false)
      search_query = keep_query
      rebuild_display(false)
    end
  end

  local mx, my = gfx.mouse_x, gfx.mouse_y
  local cap = gfx.mouse_cap
  local lmb_down = (cap & 1) == 1
  local lmb_click = (lmb_down and (last_mouse_cap & 1) == 0)
  local lmb_release = ((cap & 1) == 0 and (last_mouse_cap & 1) == 1)
  local shift = (cap & 8) == 8

  -- background
  gfx.set(BG_R, BG_G, BG_B, 1)
  gfx.rect(0,0,gfx.w,gfx.h,1)

  -- title
  gfx.setfont(1, FONT_MAIN, TITLE_SIZE)
  gfx.set(0,0,0,1)
  gfx.x = PAD; gfx.y = PAD
  gfx.drawstr(WINDOW_TITLE)
  local _, title_h = gfx.measurestr(WINDOW_TITLE)

  -- stats
  local right_edge = gfx.w - PAD
  local line1_y = PAD + title_h + GAP
  local line2_y = line1_y + VALUE_SIZE + STATS_LINE_GAP

  local function draw_right_pair(y, label, value, value_color)
    gfx.setfont(1, FONT_MAIN, LABEL_SIZE)
    local lw = select(1, gfx.measurestr(label))
    gfx.setfont(1, FONT_MAIN, VALUE_SIZE)
    local vw = select(1, gfx.measurestr(value))

    local gap = 10
    local x_label = right_edge - (lw + gap + vw)
    local x_value = right_edge - vw

    gfx.setfont(1, FONT_MAIN, LABEL_SIZE)
    gfx.set(0,0,0,0.70)
    gfx.x = x_label; gfx.y = y
    gfx.drawstr(label)

    gfx.setfont(1, FONT_MAIN, VALUE_SIZE)
    gfx.set(value_color[1], value_color[2], value_color[3], value_color[4] or 1)
    gfx.x = x_value; gfx.y = y
    gfx.drawstr(value)
  end

  draw_right_pair(line1_y, "Total:", format_hhmmss(total_sec), COL_TOTAL)
  draw_right_pair(line2_y, "Selected:", format_hhmmss(selected_sec), COL_SEL)

  -- controls row
  local controls_y = line2_y + VALUE_SIZE + STATS_TO_CONTROLS_GAP

  local all_x = PAD
  local clr_x = PAD + BTN_W + BTN_GAP
  local hot_all = in_rect(mx,my,all_x,controls_y,BTN_W,BTN_H)
  local hot_clr = in_rect(mx,my,clr_x,controls_y,BTN_W,BTN_H)

  draw_button(all_x, controls_y, BTN_W, BTN_H, "All", hot_all)
  draw_button(clr_x, controls_y, BTN_W, BTN_H, "Clear", hot_clr)

  local search_w = 260
  local search_x = gfx.w - PAD - search_w
  local hot_search = in_rect(mx,my,search_x,controls_y,search_w,SEARCH_H)
  draw_search_box(search_x, controls_y, search_w, SEARCH_H, search_focus)

  if lmb_click then
    if hot_all then
      set_all(true)
    elseif hot_clr then
      set_all(false)
    elseif hot_search then
      search_focus = true
    else
      search_focus = false
    end
  end

  -- list/table rect
  local list_y = controls_y + math.max(BTN_H, SEARCH_H) + GAP
  local list_x = PAD
  local list_w = gfx.w - PAD*2
  local list_h = gfx.h - list_y - PAD

  -- outer frame
  gfx.set(0,0,0,BORDER_A)
  gfx.rect(list_x, list_y, list_w, list_h, 0)

  -- inner content (reserve scrollbar)
  local content_x = list_x
  local content_y = list_y
  local content_w = list_w - SCROLL_RESERVE
  local content_h = list_h

  local icon_w = ICON_W
  local col1_w = COL1_W
  local col2_w = content_w - icon_w - COL_GAP - col1_w - COL_GAP
  if col2_w < 120 then col2_w = 120 end

  gfx.setfont(1, FONT_MAIN, LIST_SIZE)

  -- wrap width inside col2 (reserve len on the right)
  local wrap_w = col2_w - (CELL_PAD_X*2) - LEN_W
  if wrap_w < 40 then wrap_w = 40 end

  -- build row cache + total height
  row_cache = {}
  total_h = 0
  for i=1,#display do
    local it = display[i]
    local lines = wrap_text_to_width(trim(it.name), wrap_w)
    local rh = calc_row_h(#lines)
    row_cache[i] = { h = rh, lines = lines }
    total_h = total_h + rh
  end

  max_scroll = math.max(0, total_h - content_h)
  clamp_scroll()

  -- wheel scroll
  if in_rect(mx,my,content_x,content_y,content_w,content_h) and gfx.mouse_wheel ~= 0 then
    local delta = (gfx.mouse_wheel / 120) * WHEEL_STEP_PX
    scroll_y = scroll_y - delta
    gfx.mouse_wheel = 0
    clamp_scroll()
  else
    gfx.mouse_wheel = 0
  end

  -- ===== Render rows (TOP fixed via guards; BOTTOM intentionally not fixed yet) =====
  local y = content_y - scroll_y
  local table_w = icon_w + COL_GAP + col1_w + COL_GAP + col2_w
  local last_drawn_bottom = nil

  local vp_top = content_y
  local vp_bot = content_y + content_h

  for i=1,#display do
    local it = display[i]
    local cache = row_cache[i]
    local rh = cache and cache.h or calc_row_h(1)

    local row_top = y
    local row_bot = y + rh

    local vis_y0 = math.max(row_top, vp_top)
    local vis_y1 = math.min(row_bot, vp_bot)

    if vis_y1 > vis_y0 then
      local is_checked = (checked[it.key] == true)

      local x0 = content_x
      local x1 = x0 + icon_w
      local x2 = x1 + COL_GAP + col1_w
      local x3 = x2 + COL_GAP + col2_w

      -- highlight (slice only)
      if is_checked then
        gfx.set(SEL_R, SEL_G, SEL_B, 1)
        gfx.rect(x0, vis_y0, table_w, (vis_y1 - vis_y0), 1)
      end

      -- vertical borders (slice only)
      gfx.set(0,0,0,BORDER_A)
      local clip_bot = math.min(vis_y1, vp_bot - 2)
      local x_len_divider = math.floor(x0 + icon_w + COL_GAP + col1_w + COL_GAP + col2_w - LEN_W)
      gfx.line(x0, vis_y0, x0, clip_bot, 1)
      gfx.line(x1, vis_y0, x1, clip_bot, 1)
      gfx.line(x2 + COL_GAP, vis_y0, x2 + COL_GAP, clip_bot, 1)
      gfx.line(x_len_divider, vis_y0, x_len_divider, clip_bot, 1)
      gfx.line(x3 + COL_GAP, vis_y0, x3 + COL_GAP, clip_bot, 1)

      -- top horizontal line
      if row_top >= vp_top and row_top <= vp_bot then
        gfx.line(x0, row_top, x3 + COL_GAP, row_top, 1)
      end

      local sq = 12
      local sx = math.floor(x0 + (icon_w - sq)/2)
      local sy = math.floor(row_top + ROW_PAD_Y)
      local tx = math.floor(x0 + icon_w + COL_GAP + col1_w + COL_GAP + CELL_PAD_X)
      local ty = sy
      
      local top_fade = vp_top + 1  -- единый порог для всех элементов
      
      if sy >= top_fade and (sy + sq) <= vp_bot then
        draw_square(sx, sy, sq, it.isrgn)
        if is_checked then draw_checkmark(sx + 2, sy - 2) end
      end
      
      if sy >= top_fade and (sy + LIST_SIZE) <= vp_bot then
        local label = (it.isrgn and "R" or "M") .. tostring(it.shown_id)
        gfx.set(0,0,0,1)
        gfx.x = math.floor(x0 + icon_w + COL_GAP + 3); gfx.y = sy
        gfx.drawstr(label)
      end
      
      if it.isrgn and ty >= top_fade and (ty + LIST_SIZE) <= vp_bot then
        local len_str = format_hhmmss(it.len or 0.0)
        local lw = select(1, gfx.measurestr(len_str))
        local len_x = math.floor(x0 + icon_w + COL_GAP + col1_w + COL_GAP + col2_w - CELL_PAD_X - lw)
        gfx.set(0,0,0,0.55)
        gfx.x = len_x; gfx.y = ty
        gfx.drawstr(len_str)
      end
      
      gfx.set(0,0,0,1)
      local lines = (cache and cache.lines) or {trim(it.name)}
      for li=1,#lines do
        local ly = math.floor(ty + (li-1) * LINE_H)
        if ly >= top_fade and (ly + LINE_H) <= vp_bot then
          gfx.x = tx; gfx.y = ly
          gfx.drawstr(lines[li] or "")
        end
      end
      
      last_drawn_bottom = math.min(row_bot, vp_bot)
    end

    y = y + rh
  end

  -- bottom line
  if last_drawn_bottom and last_drawn_bottom >= vp_top and last_drawn_bottom < (vp_bot - 1) then
    gfx.set(0,0,0,BORDER_A)
    gfx.line(content_x, last_drawn_bottom, content_x + table_w, last_drawn_bottom, 1)
  end

  -- click handling
  if lmb_click and in_rect(mx,my,content_x,content_y,content_w,content_h) then
    local idx = hit_test_row(mx, my, content_x, content_y, content_w, content_h)
    if idx and display[idx] then
      local it = display[idx]
      local desired = not (checked[it.key] == true)

      if shift and last_clicked_disp_index then
        apply_range(last_clicked_disp_index, idx, desired)
      else
        if desired then checked[it.key]=true else checked[it.key]=nil end
      end

      last_clicked_disp_index = idx
      compute_selected()
      save_checked()
    end
  end

  -- scrollbar (thumb only)
  if max_scroll > 0 then
    local bar_x = math.floor(list_x + list_w - SCROLL_W - SCROLL_MARGIN_R)
    local bar_y = math.floor(list_y)
    local bar_h = math.floor(list_h)

    local thumb_y, thumb_h = get_thumb(bar_y, bar_h)
    gfx.set(0,0,0,SCROLL_THUMB_A)
    gfx.rect(bar_x, thumb_y, SCROLL_W, thumb_h, 1)

    local over_thumb = in_rect(mx,my,bar_x,thumb_y,SCROLL_W,thumb_h)

    if lmb_click and over_thumb then
      sb_drag = true
      sb_drag_offset = my - thumb_y
    end

    if sb_drag then
      if lmb_down then
        set_scroll_from_thumb(my, bar_y, bar_h, thumb_h, sb_drag_offset)
      end
      if lmb_release then sb_drag = false end
    end
  else
    sb_drag = false
  end

  gfx.update()
  last_mouse_cap = cap
  r.defer(loop)
end

-- ===== Init =====
gfx.init(WINDOW_TITLE, WIN_W, WIN_H, 0, 150, 350)
gfx.setfont(1, FONT_MAIN, LIST_SIZE)

load_checked()
refresh(true)
loop()
