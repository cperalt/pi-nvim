local M = {}

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
--- @field context_format "inline"|"reference"  How to attach context: embed contents ("inline", default) or send file references like @file:L1-L10 ("reference")
--- @field auto_send boolean  If false, :Pi queues context instead of sending immediately; use :PiFlush to send (default: true)
--- @field show_popup boolean  If false, :Pi sends/queues silently with a notification instead of opening the floating dialog (default: true)
M.config = {
  socket_path = nil,
  context_format = "inline",
  auto_send = true,
  show_popup = true,
}

--- Queue of context strings accumulated in compose mode (auto_send = false).
--- @type string[]
M._queue = {}

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Auto-reload buffers when files are changed externally (e.g. by pi agent).
  -- Only polls when a pi session is reachable. Respects existing autoread setting.
  if not vim.o.autoread then
    vim.o.autoread = true
  end
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(0, 1000, vim.schedule_wrap(function()
    if M.get_socket_path() then
      pcall(vim.cmd, "silent! checktime")
    end
  end))

  -- Commands
  vim.api.nvim_create_user_command("PiSend", function()
    M.prompt()
  end, { desc = "Send a prompt to pi" })

  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { desc = "Send current file to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendSelection", function()
    M.send_selection()
  end, { range = true, desc = "Send visual selection to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { desc = "Send entire buffer to pi with a prompt" })

  vim.api.nvim_create_user_command("Pi", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    if not M.config.auto_send then
      -- Compose mode: add to queue, no dialog
      M.add_to_queue(selection)
    elseif not M.config.show_popup then
      -- Auto-send without popup: format and send immediately
      M.send_context(selection)
    else
      ui.open({ selection = selection })
    end
  end, { range = true, desc = "Send context to pi" })

  -- Add context to the queue without sending (explicit compose, ignores auto_send)
  vim.api.nvim_create_user_command("PiAdd", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    M.add_to_queue(selection)
  end, { range = true, desc = "Add current context to pi queue (compose mode)" })

  -- Flush the queue: prompt for text and send everything
  vim.api.nvim_create_user_command("PiFlush", function()
    M.flush()
  end, { desc = "Send queued context with a prompt" })

  -- Clear the queue
  vim.api.nvim_create_user_command("PiClear", function()
    M._queue = {}
    vim.notify("Pi queue cleared", vim.log.levels.INFO)
  end, { desc = "Clear the pi context queue" })

  -- Default keymap: <leader>p in normal and visual mode
  vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
  vim.keymap.set("v", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send selection to pi" })

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { desc = "List running pi sessions" })
end

--- Format a context item based on config.context_format.
--- @class pi_nvim.Context
--- @field type "selection"|"buffer"|"file"
--- @field file string  Relative path
--- @field abs_file string  Absolute path
--- @field start_line integer|nil
--- @field end_line integer|nil
--- @field ft string|nil
--- @field text string|nil  Contents (used by "inline" format)
---
--- @param ctx pi_nvim.Context
--- @return string
function M.format_context(ctx)
  if M.config.context_format == "reference" then
    if ctx.type == "selection" and ctx.start_line then
      return string.format("@%s:%d-%d", ctx.file, ctx.start_line, ctx.end_line)
    else
      local path = ctx.file ~= "" and ctx.file or ctx.abs_file
      return string.format("@%s", path)
    end
  else
    -- inline (default)
    if ctx.type == "selection" then
      local header = string.format("%s lines %d-%d", ctx.file, ctx.start_line, ctx.end_line)
      return string.format("From %s:\n```%s\n%s\n```", header, ctx.ft or "", ctx.text or "")
    elseif ctx.type == "buffer" then
      return string.format("File: %s\n```%s\n%s\n```", ctx.file, ctx.ft or "", ctx.text or "")
    else
      return ctx.abs_file
    end
  end
end

--- Queue a context reference without sending.
--- Used by :PiAdd and by :Pi when auto_send = false.
--- @param selection table|nil  Visual selection object from ui.capture_selection()
function M.add_to_queue(selection)
  local ref
  if selection then
    ref = M.format_context({
      type = "selection",
      file = selection.file,
      abs_file = vim.fn.expand("%:p"),
      start_line = selection.start_line,
      end_line = selection.end_line,
      ft = selection.ft,
      text = selection.text,
    })
  else
    local abs_file = vim.fn.expand("%:p")
    local rel_file = vim.fn.expand("%:.")
    if abs_file == "" then
      vim.notify("No file open", vim.log.levels.WARN)
      return
    end
    ref = M.format_context({
      type = "file",
      file = rel_file,
      abs_file = abs_file,
    })
  end
  table.insert(M._queue, ref)
  local n = #M._queue
  vim.notify(string.format("Pi: queued %s (%d item%s — :PiFlush to send)", ref, n, n == 1 and "" or "s"), vim.log.levels.INFO)
end

--- Format context and send immediately (no dialog).
--- Used by :Pi when auto_send = true and show_popup = false.
--- @param selection table|nil  Visual selection object from ui.capture_selection()
function M.send_context(selection)
  local ref
  if selection then
    ref = M.format_context({
      type = "selection",
      file = selection.file,
      abs_file = vim.fn.expand("%:p"),
      start_line = selection.start_line,
      end_line = selection.end_line,
      ft = selection.ft,
      text = selection.text,
    })
  else
    local abs_file = vim.fn.expand("%:p")
    local rel_file = vim.fn.expand("%:.")
    if abs_file == "" then
      vim.notify("No file open", vim.log.levels.WARN)
      return
    end
    ref = M.format_context({
      type = "file",
      file = rel_file,
      abs_file = abs_file,
    })
  end
  M.prompt(ref)
end

--- Flush the queue: prompt for text then send all queued context + prompt.
function M.flush()
  if #M._queue == 0 then
    vim.notify("Pi queue is empty. Use :Pi or :PiAdd to queue context first.", vim.log.levels.WARN)
    return
  end
  local queued = M._queue
  M._queue = {}
  vim.ui.input({ prompt = string.format("Pi prompt (%d queued): ", #queued) }, function(input)
    if input == nil then
      -- Cancelled: restore queue
      M._queue = queued
      return
    end
    local parts = {}
    if input ~= "" then
      table.insert(parts, input)
    end
    for _, item in ipairs(queued) do
      table.insert(parts, item)
    end
    if #parts == 0 then
      vim.notify("Nothing to send", vim.log.levels.WARN)
      return
    end
    M.prompt(table.concat(parts, "\n\n"))
  end)
end

--- Resolve the socket path to use.
--- Priority: config override > cwd-based > latest symlink
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  local sockets_dir = "/tmp/pi-nvim-sockets"
  local cwd = vim.uv.cwd()

  -- Scan the sockets directory for .info files
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if ok and files then
    -- First pass: exact cwd match, prefer newest socket
    local best_sock = nil
    local best_mtime = 0
    for _, info_path in ipairs(files) do
      local content_ok, content = pcall(vim.fn.readfile, info_path)
      if content_ok and content and content[1] then
        local parsed_ok, info = pcall(vim.json.decode, content[1])
        if parsed_ok and info then
          local sock = info_path:sub(1, -6) -- strip ".info"
          local stat = vim.uv.fs_stat(sock)
          if info.cwd == cwd and stat then
            if stat.mtime.sec > best_mtime then
              best_mtime = stat.mtime.sec
              best_sock = sock
            end
          end
        end
      end
    end
    if best_sock then return best_sock end

    -- Second pass: any live session (newest)
    for _, info_path in ipairs(files) do
      local sock = info_path:sub(1, -6)
      local stat = vim.uv.fs_stat(sock)
      if stat then
        if stat.mtime.sec > best_mtime then
          best_mtime = stat.mtime.sec
          best_sock = sock
        end
      end
    end
    if best_sock then return best_sock end
  end

  -- Fall back to latest symlink
  local latest = "/tmp/pi-nvim-latest.sock"
  if vim.uv.fs_stat(latest) then
    return latest
  end

  return nil
end

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
function M.send_raw(msg, cb)
  local sock_path = M.get_socket_path()
  if not sock_path then
    local err = "No pi session found. Is pi running with pi-nvim extension?"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local client = vim.uv.new_pipe(false)
  if not client then
    local err = "Failed to create pipe"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        if cb then cb(err, nil) end
      end)
      return
    end

    local payload = vim.json.encode(msg) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
          if cb then cb(read_err, nil) end
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl = buf:find("\n")
        if nl then
          local line = buf:sub(1, nl - 1)
          client:read_stop()
          client:close()
          vim.schedule(function()
            local ok, resp = pcall(vim.json.decode, line)
            if ok and resp then
              if cb then cb(nil, resp) end
            else
              if cb then cb("Invalid response from pi", nil) end
            end
          end)
        end
      else
        -- EOF
        client:close()
      end
    end)
  end)
end

--- Send a prompt string to pi.
--- @param message string|nil  If nil, prompts the user for input
function M.prompt(message)
  if message then
    M.send_raw({ type = "prompt", message = message }, function(err, resp)
      if err then return end
      if resp and resp.ok then
        vim.notify("Sent to pi", vim.log.levels.INFO)
      else
        vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt(input)
      end
    end)
  end
end

--- Send the current file path with optional prompt.
function M.send_file()
  local abs_file = vim.fn.expand("%:p")
  local rel_file = vim.fn.expand("%:.")
  if abs_file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end

  local ctx_str = M.format_context({ type = "file", file = rel_file, abs_file = abs_file })

  vim.ui.input({ prompt = "Pi prompt (file: " .. rel_file .. "): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      if M.config.context_format == "reference" then
        message = ctx_str
      else
        message = string.format("Look at this file: %s", abs_file)
      end
    else
      message = string.format("%s\n\n%s", input, ctx_str)
    end
    M.prompt(message)
  end)
end

--- Send the visual selection with a prompt.
function M.send_selection()
  -- Get the visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getregion(start_pos, end_pos, { type = vim.fn.visualmode() })
  local selection_text = table.concat(lines, "\n")

  if selection_text == "" then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return
  end

  local file = vim.fn.expand("%:.")
  local abs_file = vim.fn.expand("%:p")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local ft = vim.bo.filetype

  local ctx_str = M.format_context({
    type = "selection",
    file = file,
    abs_file = abs_file,
    start_line = start_line,
    end_line = end_line,
    ft = ft,
    text = selection_text,
  })

  vim.ui.input({ prompt = "Pi prompt (selection): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      if M.config.context_format == "reference" then
        message = ctx_str
      else
        message = string.format("Look at this code from %s lines %d-%d:\n\n```%s\n%s\n```",
          file, start_line, end_line, ft, selection_text)
      end
    else
      message = string.format("%s\n\n%s", input, ctx_str)
    end
    M.prompt(message)
  end)
end

--- Send the entire buffer contents with a prompt.
function M.send_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")
  local rel_file = vim.fn.expand("%:.")
  local abs_file = vim.fn.expand("%:p")
  local ft = vim.bo.filetype

  local ctx_str = M.format_context({
    type = "buffer",
    file = rel_file,
    abs_file = abs_file,
    ft = ft,
    text = content,
  })

  vim.ui.input({ prompt = "Pi prompt (buffer): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      if M.config.context_format == "reference" then
        message = ctx_str
      else
        message = string.format("Look at this file %s:\n\n```%s\n%s\n```", rel_file, ft, content)
      end
    else
      message = string.format("%s\n\n%s", input, ctx_str)
    end
    M.prompt(message)
  end)
end

--- Ping the pi session to check connectivity.
function M.ping()
  M.send_raw({ type = "ping" }, function(err, resp)
    if err then
      vim.notify("Pi not reachable: " .. err, vim.log.levels.ERROR)
    elseif resp and resp.type == "pong" then
      vim.notify("Pi is alive! ✓", vim.log.levels.INFO)
    else
      vim.notify("Unexpected response from pi", vim.log.levels.WARN)
    end
  end)
end

--- List all running pi sessions.
function M.list_sessions()
  local sockets_dir = "/tmp/pi-nvim-sockets"
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if not ok or not files or #files == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local sessions = {}
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock = info_path:sub(1, -6)
        local alive = vim.uv.fs_stat(sock) ~= nil
        if alive then
          -- Format start time as relative or short time
          local started = ""
          if info.startedAt then
            local ok2, ts = pcall(function()
              -- Parse ISO 8601: "2026-03-01T14:10:09.123Z"
              local y, mo, d, h, mi, s = info.startedAt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
              if h and mi then
                return string.format("%s:%s", h, mi)
              end
              return info.startedAt
            end)
            if ok2 then started = ts end
          end
          table.insert(sessions, {
            cwd = info.cwd or "?",
            pid = info.pid or "?",
            started = started,
            socket = sock,
          })
        end
      end
    end
  end

  if #sessions == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local items = {}
  local current = M.get_socket_path()
  for _, s in ipairs(sessions) do
    local marker = (current == s.socket) and "●" or "○"
    local time_str = s.started ~= "" and string.format(" started %s", s.started) or ""
    table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd, s.pid, time_str))
  end

  vim.ui.select(items, { prompt = "Pi sessions:" }, function(choice, idx)
    if not choice or not idx then return end
    local session = sessions[idx]
    if session then
      M.config.socket_path = session.socket
      vim.notify(string.format("Connected to pi at %s [pid %s]", session.cwd, session.pid), vim.log.levels.INFO)
    end
  end)
end

return M
