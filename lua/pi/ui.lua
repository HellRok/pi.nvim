local M = {}

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local ns = vim.api.nvim_create_namespace("pi_status")

vim.api.nvim_set_hl(0, "PiStatus", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "PiStatusError", { link = "DiagnosticError", default = true })

local active_statuses = {
  collecting_context = true,
  starting = true,
  thinking = true,
  running_tool = true,
  applying = true,
}

local function has_rich_notify()
  if _G.__pi_force_notify_backend then
    return true
  end

  if package.loaded.notify ~= nil or pcall(require, "notify") then
    return true
  end

  local mini_notify = rawget(_G, "MiniNotify")
  return type(mini_notify) == "table" and type(mini_notify.add) == "function"
end

local function is_session_window_valid(session)
  return session and session.winnr and vim.api.nvim_win_is_valid(session.winnr)
end

local function is_session_buffer_valid(session)
  return session and session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr)
end

local function title_for(session)
  if session.status == "error" then
    return session.ui_backend ~= "float" and "pi error" or " pi error "
  end
  return session.ui_backend ~= "float" and "pi" or " pi "
end

local function status_line(session)
  local prefix = ""
  if session.ui_backend ~= "notify" and active_statuses[session.status] then
    session.spinner_idx = ((session.spinner_idx or 0) % #spinner) + 1
    prefix = spinner[session.spinner_idx] .. " "
  end

  if session.status == "running_tool" and session.active_tool then
    return prefix .. (session.ui_backend ~= "float" and "Pi calling tool: " or "Running tool: ") .. session.active_tool
  end

  local notify_labels = {
    collecting_context = "Pi collecting context...",
    starting = "Pi starting...",
    thinking = "Pi thinking...",
    running_tool = "Pi calling tool...",
    applying = "Pi applying edits...",
    done = "Pi done",
    error = session.last_error or "pi failed",
    cancelled = "Pi cancelled",
  }

  local float_labels = {
    idle = "Idle",
    collecting_context = "Collecting context...",
    starting = "Starting pi...",
    thinking = "Thinking...",
    running_tool = "Running tool...",
    applying = "Applying edits...",
    done = "Done",
    error = session.last_error or "pi failed",
    cancelled = "Cancelled",
  }

  local labels = session.ui_backend ~= "float" and notify_labels or float_labels
  local message = labels[session.status]
  if not message then
    return nil
  end
  return prefix .. message
end

local function notification_level(session)
  if session.status == "error" then
    return vim.log.levels.ERROR
  end
  if session.status == "cancelled" then
    return vim.log.levels.WARN
  end
  return vim.log.levels.INFO
end

local function render_notify(session)
  local message = status_line(session)
  if not message then
    return
  end

  local signature = session.status .. "|" .. (session.active_tool or "") .. "|" .. (session.last_error or "")
  if session.last_notified_signature == signature then
    return
  end
  session.last_notified_signature = signature

  vim.notify(message, notification_level(session), {
    title = title_for(session),
  })
end

local function render_float(session)
  if not is_session_buffer_valid(session) then
    return
  end

  local lines = { status_line(session) }
  local start_idx = math.max(1, #session.history - 3)
  for i = start_idx, #session.history do
    lines[#lines + 1] = session.history[i]
  end

  vim.bo[session.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)
  vim.bo[session.bufnr].modifiable = false

  if is_session_window_valid(session) then
    pcall(vim.api.nvim_win_set_config, session.winnr, vim.tbl_extend("force", vim.api.nvim_win_get_config(session.winnr), {
      title = title_for(session),
      height = math.min(math.max(#lines, 1), math.max(3, math.floor(vim.o.lines * 0.25))),
    }))
  end
end

local function render_virtualtext(session)
  local bufnr = session.source_bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local text = status_line(session)
  if not text then
    return
  end

  local count = vim.api.nvim_buf_line_count(bufnr)
  local line = session.anchor_line or 1
  local id = session.status_extmark

  if id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
    if #mark > 0 and not mark[3].invalid then
      line = mark[1] + 1
    else
      -- Edits invalidated or deleted the anchor: re-anchor at the cursor,
      -- or at the clamped old line when the source window is gone.
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
      id = nil
      local win = session.source_winnr
      if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        line = vim.api.nvim_win_get_cursor(win)[1]
      end
    end
  end

  line = math.min(math.max(line, 1), count)
  session.anchor_line = line
  session.status_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
    id = id,
    virt_text = { { text, session.status == "error" and "PiStatusError" or "PiStatus" } },
    virt_text_pos = "eol",
    invalidate = true,
    undo_restore = false,
  })
end

local function clear_virtualtext(session)
  local bufnr = session.source_bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  session.status_extmark = nil
end

local pending = nil

--- Clears a lingering final-state status immediately.
local function flush_pending()
  local current = pending
  if not current then
    return
  end
  pending = nil
  if current.timer then
    current.timer:stop()
    current.timer:close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, current.group)
  clear_virtualtext(current.session)
end

local function schedule_clear(session)
  flush_pending()
  local cfg = require("pi.config").get().ui
  local is_error = session.status == "error"
  local current = {
    session = session,
    group = vim.api.nvim_create_augroup("PiStatusClear", { clear = true }),
  }
  pending = current

  current.timer = vim.loop.new_timer()
  current.timer:start(is_error and cfg.error_ms or cfg.linger_ms, 0, vim.schedule_wrap(function()
    if pending == current then
      flush_pending()
    end
  end))

  if is_error then
    vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
      group = current.group,
      callback = function()
        if pending == current then
          flush_pending()
        end
      end,
    })
  end
end

local function render(session)
  if session.ui_backend == "virtualtext" then
    render_virtualtext(session)
  elseif session.ui_backend == "notify" then
    render_notify(session)
  else
    render_float(session)
  end
end

local function stop_timer(session)
  if session.ui_timer then
    session.ui_timer:stop()
    session.ui_timer:close()
    session.ui_timer = nil
  end
end

--- Shows the final state, lingers, and fires the single completion notify.
local function finalize_virtualtext(session)
  if session.ui_finalized then
    return
  end
  session.ui_finalized = true
  stop_timer(session)

  local bufnr = session.source_bufnr
  local message = status_line(session)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    render_virtualtext(session)
    schedule_clear(session)
  end
  if message then
    vim.notify(message, notification_level(session), { title = title_for(session) })
  end
end

local function ensure_timer(session)
  if session.ui_backend == "notify" or session.ui_timer or not active_statuses[session.status] then
    return
  end

  session.ui_timer = vim.loop.new_timer()
  session.ui_timer:start(100, 100, vim.schedule_wrap(function()
    local alive = session.ui_backend == "virtualtext" or is_session_buffer_valid(session)
    if not alive or not active_statuses[session.status] then
      stop_timer(session)
      return
    end
    render(session)
  end))
end

local function open_float(session, focus)
  local width = math.min(60, math.max(40, math.floor(vim.o.columns * 0.45)))
  local height = 4
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  session.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[session.bufnr].buftype = "nofile"
  vim.bo[session.bufnr].bufhidden = "wipe"
  vim.bo[session.bufnr].swapfile = false
  vim.bo[session.bufnr].modifiable = false
  vim.api.nvim_buf_set_name(session.bufnr, "pi-session://" .. session.id)

  session.winnr = vim.api.nvim_open_win(session.bufnr, focus, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title_for(session),
    title_pos = "center",
    noautocmd = true,
  })

  vim.wo[session.winnr].wrap = true
  vim.wo[session.winnr].linebreak = true
  vim.wo[session.winnr].winfixbuf = true
end

local function pick_backend(session)
  local configured = require("pi.config").get().ui.backend
  if configured == "auto" or configured == "virtualtext" then
    local bufnr = session.source_bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return "virtualtext"
    end
  elseif configured ~= nil and configured ~= "auto" then
    return configured
  end
  return has_rich_notify() and "notify" or "float"
end

function M.open(session, focus)
  session.ui_backend = pick_backend(session)

  if session.ui_backend == "virtualtext" then
    flush_pending()
    vim.api.nvim_buf_clear_namespace(session.source_bufnr, ns, 0, -1)
  end

  if session.ui_backend == "float" then
    open_float(session, focus)
  else
    session.winnr = nil
    session.bufnr = nil
  end

  render(session)
  ensure_timer(session)
end

function M.update(session)
  if active_statuses[session.status] then
    ensure_timer(session)
  else
    stop_timer(session)
    if session.ui_backend == "virtualtext" then
      finalize_virtualtext(session)
      return
    end
  end
  render(session)
end

function M.close(session)
  stop_timer(session)

  if session.ui_backend == "virtualtext" then
    if session.cancelled then
      session.status = "cancelled"
    elseif session.status ~= "error" then
      session.status = "done"
    end
    finalize_virtualtext(session)
    return
  end

  if session.ui_backend == "float" then
    if is_session_window_valid(session) then
      pcall(vim.api.nvim_win_close, session.winnr, true)
    end
    if is_session_buffer_valid(session) then
      pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
    end
    session.winnr = nil
    session.bufnr = nil
    return
  end

  session.winnr = nil
  session.bufnr = nil

  if session.cancelled then
    session.status = "cancelled"
    render(session)
    return
  end

  if session.status ~= "error" then
    session.status = "done"
    render(session)
  end
end

return M
