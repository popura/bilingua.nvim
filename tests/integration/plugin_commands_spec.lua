local test = require("tests.testlib")

local COMMANDS = {
  "BilinguaStart",
  "BilinguaToggle",
  "BilinguaSync",
  "BilinguaSyncAll",
  "BilinguaUseSource",
  "BilinguaUseJapanese",
  "BilinguaNext",
  "BilinguaPrev",
  "BilinguaStatus",
  "BilinguaRetry",
  "BilinguaRestartBackend",
  "BilinguaStop",
  "BilinguaQuit",
}

local PLUG_MAPPINGS = {
  "Start",
  "Toggle",
  "Sync",
  "SyncAll",
  "UseSource",
  "UseJapanese",
  "Next",
  "Prev",
  "Status",
  "Retry",
  "RestartBackend",
  "Stop",
  "Quit",
}

-- Preconditions: The plugin loader has not run in this headless process because
-- runtimepath is prepended after startup. Prerequisites: plugin/bilingua.lua must
-- only define commands and mappings; it must not open a backend. Verification
-- items: every specified Ex command and <Plug> mapping exists after one load, and
-- loading it a second time remains idempotent without starting a Codex process.
test.it("loads the complete lazy command and Plug mapping surface idempotently", function()
  vim.g.loaded_bilingua_nvim = nil
  dofile("plugin/bilingua.lua")
  dofile("plugin/bilingua.lua")

  for _, command in ipairs(COMMANDS) do
    test.eq(2, vim.fn.exists(":" .. command))
  end
  for _, mapping in ipairs(PLUG_MAPPINGS) do
    test.eq(1, vim.fn.maparg("<Plug>(Bilingua" .. mapping .. ")", "n") ~= "" and 1 or 0)
  end
end)

-- Preconditions: No Session owns the current buffer. Prerequisites: commands
-- requiring a Session must route through the public API and normalize absence as
-- E_SESSION_STATE. Verification items: the Lua API returns the error table and an
-- Ex invocation reports it through vim.notify without raising an exception.
test.it("reports a sessionless command as a user-facing error", function()
  local bilingua = require("bilingua")
  local previous_notify = vim.notify
  local notifications = {}
  vim.notify = function(message)
    notifications[#notifications + 1] = message
  end

  local status, status_error = bilingua.status()
  test.eq(nil, status)
  test.eq("E_SESSION_STATE", status_error.code)
  local called = pcall(vim.cmd, "BilinguaToggle")

  vim.notify = previous_notify
  test.eq(true, called)
  test.eq(true, notifications[#notifications]:find("[E_SESSION_STATE]", 1, true) ~= nil)
end)

-- Preconditions: A normal buffer is opened from a real text file and the plugin
-- commands are loaded. Prerequisites: only the local compatibility predicate is
-- shimmed on an older test host; Ex commands, Coordinator, SessionFactory, concrete
-- NvimEditor, registry selection and Fake TranslationService remain real.
-- Verification items: :BilinguaStart reaches ready with source left and target
-- right, :BilinguaToggle moves both ways, :BilinguaSync updates the current group,
-- and :BilinguaStop! retains only the source file without a sidecar.
test.it("starts and stops a real file through public Ex commands", function()
  local bilingua = require("bilingua")
  local registry = require("bilingua.registry")
  local fake_translation = require("tests.fakes.translation_service")
  local path = vim.fn.tempname() .. ".txt"
  local source
  local target
  local service
  local original_has = vim.fn.has

  if original_has("nvim-0.10") ~= 1 then
    local compatibility_check_pending = true
    vim.fn.has = function(feature)
      if feature == "nvim-0.10" and compatibility_check_pending then
        compatibility_check_pending = false
        return 1
      end
      return original_has(feature)
    end
  end

  local completed, failure = xpcall(function()
    test.eq(0, vim.fn.writefile({ "Hello" }, path))
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    source = vim.api.nvim_get_current_buf()
    vim.bo[source].filetype = "text"

    assert(registry.register_translation_service("command_fake", function()
      service = fake_translation.new(function(task)
        local replacements = {}
        for index, unit in ipairs(task.edited_after.units) do
          replacements[index] = {
            local_id = ("command:%d"):format(index),
            corresponds_to_edited_unit_ids = { unit.unit_id },
            kind = unit.kind,
            content_text = task.kind == "initial_translate" and "訳文" or "更新訳",
            language = "ja",
          }
        end
        return {
          schema_version = 1,
          task_id = task.task_id,
          destination_side = "target",
          replacement_units = replacements,
          warnings = {},
          metadata = {},
        }
      end)
      return service
    end, { replace = true }))

    assert(bilingua.setup({
      mappings = { enabled = false },
      sync = { automatic = false },
      translation = { service = "command_fake", backend = "command_fake" },
    }))
    vim.cmd("BilinguaStart en")
    test.eq(
      true,
      vim.wait(500, function()
        local status = bilingua.status()
        return status and status.state == "ready"
      end, 10)
    )

    local status, status_error = bilingua.status()
    test.eq(nil, status_error)
    target = status.target_buf
    test.eq(source, status.source_buf)
    test.eq(path, status.source_path)
    test.eq("en", status.source_language)
    test.eq("", vim.bo[source].buftype)
    test.eq("nofile", vim.bo[target].buftype)
    test.eq(true, vim.bo[target].modifiable)
    test.eq("訳文", table.concat(vim.api.nvim_buf_get_lines(target, 0, -1, true), "\n"))

    local source_window = vim.fn.win_findbuf(source)[1]
    local target_window = vim.fn.win_findbuf(target)[1]
    test.eq(true, source_window ~= nil and target_window ~= nil)
    local source_position = vim.api.nvim_win_get_position(source_window)
    local target_position = vim.api.nvim_win_get_position(target_window)
    test.eq(true, source_position[2] < target_position[2])

    test.eq(target, vim.api.nvim_get_current_buf())
    vim.cmd("BilinguaToggle")
    test.eq(source, vim.api.nvim_get_current_buf())
    vim.api.nvim_buf_set_text(source, 0, 0, 0, #"Hello", { "Hello revised" })
    vim.schedule(function()
      vim.cmd("BilinguaSync")
    end)
    test.eq(
      true,
      vim.wait(500, function()
        return table.concat(vim.api.nvim_buf_get_lines(target, 0, -1, true), "\n") == "更新訳"
      end, 10)
    )
    test.eq("更新訳", table.concat(vim.api.nvim_buf_get_lines(target, 0, -1, true), "\n"))
    test.eq(2, #service.submitted)
    vim.cmd("BilinguaToggle")
    test.eq(target, vim.api.nvim_get_current_buf())

    vim.cmd("BilinguaStop!")
    test.eq(
      true,
      vim.wait(500, function()
        return bilingua.status() == nil
      end, 10)
    )
    test.eq("closed", service.state)
    test.eq(false, vim.api.nvim_buf_is_valid(target))
    test.eq(true, vim.api.nvim_buf_is_valid(source))
    test.eq(path, vim.api.nvim_buf_get_name(source))
    local related_paths = vim.fn.glob(path .. "*", false, true)
    test.eq({ path }, related_paths)
  end, debug.traceback)

  vim.fn.has = original_has
  local remaining = bilingua.status()
  if remaining then
    pcall(bilingua.stop, { force = true })
  end
  if source and vim.api.nvim_buf_is_valid(source) then
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end
  local removed = vim.fn.delete(path)
  pcall(bilingua.setup, { mappings = { enabled = false } })

  assert(completed, failure)
  test.eq(0, removed)
end)
