local test = require("tests.testlib")

-- Preconditions: Global setup disables mappings and supplies a two-part backend
-- command and a protected pattern, while one start call enables mappings, supplies
-- one command element, and explicitly clears the protected-pattern array.
-- Prerequisites: public start resolves the same merged Session configuration used
-- by Coordinator; map options merge recursively but array options replace atomically.
-- Verification items: mapping installation receives the per-Session key and exact
-- one-element command plus an empty protected-pattern list, while the public
-- callback remains a detached status snapshot.
test.it("installs mappings from the resolved per-Session configuration", function()
  local saved = {
    bilingua = package.loaded["bilingua"],
    coordinator = package.loaded["bilingua.app.coordinator"],
    commands = package.loaded["bilingua.commands"],
    has = vim.fn.has,
  }
  local installed_config
  local callback_status
  local runtime = {}
  function runtime:start(_, callback)
    callback({ session_id = "session:override", source_buf = 71, target_buf = 72 })
    return true
  end
  local completed, failure = xpcall(function()
    package.loaded["bilingua"] = nil
    package.loaded["bilingua.app.coordinator"] = {
      new = function()
        return runtime
      end,
    }
    package.loaded["bilingua.commands"] = {
      install_session_mappings = function(config)
        installed_config = config
      end,
    }
    vim.fn.has = function(feature)
      if feature == "nvim-0.10" then
        return 1
      end
      return saved.has(feature)
    end

    local isolated = require("bilingua")
    assert(isolated.setup({
      mappings = { enabled = false },
      documents = { protected_patterns = { "GLOBAL:%d+" } },
      translation = { backend_options = { command = { "global", "--shared" } } },
    }))
    assert(isolated.start({
      mappings = { enabled = true, sync = "zx" },
      documents = { protected_patterns = {} },
      translation = { backend_options = { command = { "session" } } },
    }, function(status)
      callback_status = status
    end))
  end, debug.traceback)

  package.loaded["bilingua"] = saved.bilingua
  package.loaded["bilingua.app.coordinator"] = saved.coordinator
  package.loaded["bilingua.commands"] = saved.commands
  vim.fn.has = saved.has

  assert(completed, failure)
  test.eq(true, installed_config.mappings.enabled)
  test.eq("zx", installed_config.mappings.sync)
  test.eq({ "session" }, installed_config.translation.backend_options.command)
  test.eq({}, installed_config.documents.protected_patterns)
  test.eq("session:override", callback_status.session_id)
end)

-- Preconditions: Coordinator retries a failed start and completes with a detached
-- status plus the configuration resolved for the fresh Session. Prerequisites: the
-- public API must preserve asynchronous completion and install buffer-local mappings
-- exactly as ordinary start does. Verification items: retry passes a callback to
-- Coordinator, installs the returned Session configuration, and forwards status.
test.it("installs Session mappings after a failed start retry", function()
  local saved = {
    bilingua = package.loaded["bilingua"],
    coordinator = package.loaded["bilingua.app.coordinator"],
    commands = package.loaded["bilingua.commands"],
    has = vim.fn.has,
  }
  local installed
  local callback_status
  local runtime = {}
  function runtime:retry_current(callback)
    test.eq("function", type(callback))
    callback(
      { session_id = "session:retry", source_buf = 81, target_buf = 82 },
      nil,
      { mappings = { enabled = true, sync = "zy" } }
    )
    return true
  end
  local completed, failure = xpcall(function()
    package.loaded["bilingua"] = nil
    package.loaded["bilingua.app.coordinator"] = {
      new = function()
        return runtime
      end,
    }
    package.loaded["bilingua.commands"] = {
      install_session_mappings = function(config, source_buf, target_buf)
        installed = { config = config, source_buf = source_buf, target_buf = target_buf }
      end,
    }
    vim.fn.has = function(feature)
      if feature == "nvim-0.10" then
        return 1
      end
      return saved.has(feature)
    end

    local isolated = require("bilingua")
    assert(isolated.setup())
    assert(isolated.retry_current(function(status)
      callback_status = status
    end))
  end, debug.traceback)

  package.loaded["bilingua"] = saved.bilingua
  package.loaded["bilingua.app.coordinator"] = saved.coordinator
  package.loaded["bilingua.commands"] = saved.commands
  vim.fn.has = saved.has

  assert(completed, failure)
  test.eq("session:retry", callback_status.session_id)
  test.eq("zy", installed.config.mappings.sync)
  test.eq(81, installed.source_buf)
  test.eq(82, installed.target_buf)
end)
