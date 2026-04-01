local M = {}

--- Capture visual selection info before it's lost.
--- @return table|nil
function M.capture_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 and end_pos[2] == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = vim.fn.visualmode() })
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local text = table.concat(lines, "\n")
  if text == "" then return nil end

  return {
    text = text,
    file = vim.fn.expand("%:."),
    start_line = start_pos[2],
    end_line = end_pos[2],
    ft = vim.bo.filetype,
  }
end

--- Open the Pi send dialog as two floating windows.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local pi = require("pi-nvim")
  local selection = opts.selection
  local file = vim.fn.expand("%:p")
  local rel_file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype
  local send_buffer = false
  local source_buf = vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

  -- Build info lines
  local file_info = "File: " .. (rel_file ~= "" and rel_file or "(no file)")
  local context_info
  if selection then
    local n = select(2, selection.text:gsub("\n", "")) + 1
    if pi.config.context_format == "reference" then
      context_info = string.format("Selection: %d lines (%d-%d) → @%s:%d-%d",
        n, selection.start_line, selection.end_line,
        selection.file, selection.start_line, selection.end_line)
    else
      context_info = string.format("Selection: %d lines (%d-%d)", n, selection.start_line, selection.end_line)
    end
  else
    context_info = "Send buffer: [ ] (Tab to toggle)"
  end

  -- Show queue count if items are pending
  local queue_info = nil
  if #pi._queue > 0 then
    queue_info = string.format("Queue: %d item%s pending", #pi._queue, #pi._queue == 1 and "" or "s")
  end

  -- Layout
  local width = math.min(72, math.floor(vim.o.columns * 0.5))
  local info_height = queue_info and 3 or 2
  local max_input_height = 6
  local gap = 0 -- no gap between bubbles
  local top_row = math.floor((vim.o.lines - (info_height + 2 + gap + max_input_height + 2)) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  -- Accent highlights
  local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local accent_fg = accent_hl.fg
  vim.api.nvim_set_hl(0, "PiNvimBorder", { fg = accent_fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, "PiNvimTitle", { fg = accent_fg, bg = normal_hl.bg })


  -- Top bubble: info
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[info_buf].buftype = "nofile"
  local info_lines = { " " .. file_info, " " .. context_info }
  if queue_info then
    table.insert(info_lines, " " .. queue_info)
  end
  vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, info_lines)
  vim.bo[info_buf].modifiable = false

  local info_win = vim.api.nvim_open_win(info_buf, false, {
    relative = "editor",
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[info_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[info_win].cursorline = false

  -- Bottom bubble: prompt input
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "pi-nvim-prompt"
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  local input_row = top_row + info_height + 2 + gap -- +2 for info border
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = input_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " prompt ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[input_win].wrap = true

  -- Resize the input window to fit content (1..max_input_height rows)
  local function resize_input()
    if not vim.api.nvim_win_is_valid(input_win) then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    -- Count visual rows (each buffer line may wrap across multiple display rows)
    local visual_rows = 0
    for _, line in ipairs(lines) do
      -- A blank line still takes 1 row
      visual_rows = visual_rows + math.max(1, math.ceil((#line == 0 and 1 or #line) / width))
    end
    local new_height = math.max(1, math.min(max_input_height, visual_rows))
    vim.api.nvim_win_set_height(input_win, new_height)
    -- Scroll so the cursor line is always visible (bottom of window)
    local cursor_line = vim.api.nvim_win_get_cursor(input_win)[1]
    local top_line = math.max(1, cursor_line - new_height + 1)
    vim.api.nvim_win_call(input_win, function()
      vim.fn.winrestview({ topline = top_line })
    end)
  end

  -- Highlight the visual selection in the source buffer while the dialog is open
  local sel_ns = nil
  if selection and vim.api.nvim_buf_is_valid(source_buf) then
    sel_ns = vim.api.nvim_create_namespace("pi_nvim_selection")
    for lnum = selection.start_line, selection.end_line do
      vim.api.nvim_buf_add_highlight(source_buf, sel_ns, "Visual", lnum - 1, 0, -1)
    end
  end

  -- Start in insert mode
  vim.cmd("noautocmd startinsert!")

  local closed = false

  local function close()
    if closed then return end
    closed = true
    vim.cmd("noautocmd stopinsert")
    -- Remove selection highlight from source buffer
    if sel_ns and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, sel_ns, 0, -1)
    end
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, info_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, info_buf, { force = true })
  end

  local function update_context()
    if selection then return end
    local marker = send_buffer and "[x]" or "[ ]"
    local line = " Send buffer: " .. marker .. " (Tab to toggle)"
    vim.bo[info_buf].modifiable = true
    vim.api.nvim_buf_set_lines(info_buf, 1, 2, false, { line })
    vim.bo[info_buf].modifiable = false
  end

  local function send()
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local prompt_text = vim.fn.trim(table.concat(lines, "\n"))
    close()

    -- Build context string using configured format
    local ctx_str = nil
    local is_reference = pi.config.context_format == "reference"

    if selection then
      ctx_str = pi.format_context({
        type = "selection",
        file = selection.file,
        abs_file = vim.fn.expand("%:p"),
        start_line = selection.start_line,
        end_line = selection.end_line,
        ft = selection.ft,
        text = selection.text,
      })
    elseif send_buffer and rel_file ~= "" then
      ctx_str = pi.format_context({
        type = "buffer",
        file = rel_file,
        abs_file = file,
        ft = ft,
        text = table.concat(buf_lines, "\n"),
      })
    elseif file ~= "" then
      ctx_str = pi.format_context({ type = "file", file = rel_file, abs_file = file })
    end

    -- Assemble message: queued items + current context + prompt
    local parts = {}
    for _, item in ipairs(pi._queue) do
      table.insert(parts, item)
    end
    pi._queue = {}

    if ctx_str then
      table.insert(parts, ctx_str)
    end

    local message
    if #parts == 0 then
      if prompt_text == "" then
        vim.notify("Nothing to send", vim.log.levels.WARN)
        return
      end
      message = prompt_text
    elseif prompt_text == "" then
      -- No user prompt: use a default preamble only for inline format
      if is_reference then
        message = table.concat(parts, "\n")
      else
        -- Inline: keep the old default "Look at this..." preamble for single items
        if #parts == 1 and not selection and not send_buffer then
          message = string.format("Look at this file: %s", file)
        elseif #parts == 1 and selection then
          message = string.format("Look at this code from %s lines %d-%d:\n\n```%s\n%s\n```",
            selection.file, selection.start_line, selection.end_line, selection.ft, selection.text)
        elseif #parts == 1 and send_buffer then
          message = string.format("Look at this file %s:\n\n```%s\n%s\n```",
            rel_file, ft, table.concat(buf_lines, "\n"))
        else
          message = table.concat(parts, "\n\n")
        end
      end
    else
      -- User typed a prompt: prepend it
      message = prompt_text .. "\n\n" .. table.concat(parts, "\n\n")
    end

    pi.prompt(message)
  end

  local kopts = { buffer = input_buf, noremap = true, silent = true }

  vim.keymap.set("i", "<CR>", send, kopts)
  vim.keymap.set({ "i", "n" }, "<Esc>", close, kopts)
  vim.keymap.set({ "i", "n" }, "<C-c>", close, kopts)
  vim.keymap.set({ "i", "n" }, "<Tab>", function()
    if not selection then
      send_buffer = not send_buffer
      update_context()
    end
  end, kopts)

  -- Resize window as text is typed
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_buf,
    callback = resize_input,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
