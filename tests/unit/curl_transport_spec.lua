local test = require("tests.testlib")
local fake_process = require("tests.fakes.system_process")
local curl = require("bilingua.adapters.translation.transports.curl")

local function harness(transport_options)
  local pending = {}
  local process = fake_process.new()
  local options = transport_options or {}
  options.command = options.command or { "curl" }
  options.process_factory = options.process_factory
    or function(command, process_options, on_exit)
      return process:process_factory(command, process_options, on_exit)
    end
  options.schedule = options.schedule
    or function(callback)
      pending[#pending + 1] = callback
    end
  options.max_response_bytes = options.max_response_bytes or 1024
  options.max_stderr_bytes = options.max_stderr_bytes or 64

  local function flush()
    while #pending > 0 do
      local callbacks = pending
      pending = {}
      for _, callback in ipairs(callbacks) do
        callback()
      end
    end
  end

  return {
    transport = curl.new(options),
    process = process,
    pending = pending,
    flush = flush,
  }
end

-- Preconditions: A GET has two deliberately unsorted headers, a fractional-second
-- timeout, and a multiline body whose CRLF status marker is split across chunks.
-- Prerequisites: curl receives an argv list with proxy bypass and no redirect or
-- stdin flags; stream callbacks only collect bytes, while exit parsing and delivery
-- are deferred through the injected scheduler.
-- Verification items: argv/header order and timeout conversion are deterministic,
-- GET writes nothing, text mode is enabled, the final marker alone yields status,
-- the separator CR is removed, stderr defaults empty, and callback runs after flush.
test.it("invokes a deterministic GET and parses a scheduled response", function()
  local context = harness()
  local response
  local transport_error
  context.transport:request({
    method = "GET",
    url = "http://127.0.0.1:8080/health",
    headers = {
      ["X-Zeta"] = "last",
      Accept = "application/json",
    },
    timeout_ms = 1500,
  }, function(value, err)
    response = value
    transport_error = err
  end)

  test.eq({
    "curl",
    "--silent",
    "--show-error",
    "--noproxy",
    "*",
    "--request",
    "GET",
    "--header",
    "Accept: application/json",
    "--header",
    "X-Zeta: last",
    "--connect-timeout",
    "1.5",
    "--max-time",
    "1.5",
    "--write-out",
    "\n__BILINGUA_HTTP_STATUS__:%{http_code}",
    "http://127.0.0.1:8080/health",
  }, context.process.command)
  test.eq(true, context.process.options.text)
  test.eq(nil, context.process.options.stdin)
  local writes, stdin_closed = context.process:writes()
  test.eq({}, writes)
  test.eq(false, stdin_closed)

  context.process:emit_stdout('{\n  "message": "first\\nsecond"\n}\r')
  context.process:emit_stdout("\n__BILINGUA_HTTP_")
  context.process:emit_stdout("STATUS__:200")
  context.process:exit(0)
  test.eq(nil, response)
  context.flush()

  test.eq(nil, transport_error)
  test.eq(200, response.status)
  test.eq('{\n  "message": "first\\nsecond"\n}', response.body)
  test.eq("", response.stderr)
end)

-- Preconditions: A POST carries a JSON document body, one content header, and a
-- whole-second timeout. Prerequisites: secret request data must travel only through
-- the child process stdin; curl receives `--data-binary @-` rather than inline data,
-- and stdin is closed explicitly after the complete body is written.
-- Verification items: POST argv ordering is exact, text/stdin modes are enabled,
-- body is absent from every argv element, writes contain only the original bytes,
-- stdin closes once, and a successful response is still delivered asynchronously.
test.it("streams a POST body through stdin without exposing it in argv", function()
  local context = harness()
  local secret_body = '{"document":"SECRET DOCUMENT PAYLOAD"}'
  local response
  context.transport:request({
    method = "POST",
    url = "http://127.0.0.1:8080/v1/chat/completions",
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = secret_body,
    timeout_ms = 120000,
  }, function(value, err)
    assert(not err, err and err.message)
    response = value
  end)

  test.eq({
    "curl",
    "--silent",
    "--show-error",
    "--noproxy",
    "*",
    "--request",
    "POST",
    "--header",
    "Content-Type: application/json",
    "--connect-timeout",
    "120",
    "--max-time",
    "120",
    "--write-out",
    "\n__BILINGUA_HTTP_STATUS__:%{http_code}",
    "--data-binary",
    "@-",
    "http://127.0.0.1:8080/v1/chat/completions",
  }, context.process.command)
  test.eq(true, context.process.options.text)
  test.eq(true, context.process.options.stdin)
  for _, argument in ipairs(context.process.command) do
    test.eq(false, argument:find(secret_body, 1, true) ~= nil)
  end
  local writes, stdin_closed = context.process:writes()
  test.eq({ secret_body }, writes)
  test.eq(true, stdin_closed)

  context.process:emit_stdout('{"choices":[]}\n__BILINGUA_HTTP_STATUS__:201')
  context.process:exit(0)
  test.eq(nil, response)
  context.flush()
  test.eq(201, response.status)
  test.eq('{"choices":[]}', response.body)
end)

-- Preconditions: Each request has exactly one invalid transport-owned field:
-- unsupported method, empty URL, non-string POST body, invalid timeout, or a CR/LF
-- in a header name/value. Prerequisites: validation occurs before argv construction
-- and process creation, and error delivery uses the injected scheduler without
-- reflecting potentially sensitive header values in diagnostics.
-- Verification items: no process is spawned, callback runs once only after flush,
-- response is nil, every error is `protocol`, and its fixed message omits secrets.
test.it("rejects unsafe or malformed request fields before spawning curl", function()
  local cases = {
    {
      method = "DELETE",
      url = "http://127.0.0.1:8080/health",
      timeout_ms = 1000,
    },
    { method = "GET", url = "", timeout_ms = 1000 },
    {
      method = "POST",
      url = "http://127.0.0.1:8080/v1/chat/completions",
      body = {},
      timeout_ms = 1000,
    },
    {
      method = "GET",
      url = "http://127.0.0.1:8080/health",
      timeout_ms = -1,
    },
    {
      method = "GET",
      url = "http://127.0.0.1:8080/health",
      headers = { ["Unsafe\nName"] = "value" },
      timeout_ms = 1000,
    },
    {
      method = "GET",
      url = "http://127.0.0.1:8080/health",
      headers = { Authorization = "SECRET\r\nInjected: value" },
      timeout_ms = 1000,
    },
  }

  for _, request in ipairs(cases) do
    local context = harness()
    local callbacks = 0
    local response
    local transport_error
    context.transport:request(request, function(value, err)
      callbacks = callbacks + 1
      response = value
      transport_error = err
    end)

    test.eq(0, context.process.spawn_count)
    test.eq(0, callbacks)
    context.flush()
    test.eq(1, callbacks)
    test.eq(nil, response)
    test.eq("protocol", transport_error.kind)
    test.eq(nil, transport_error.message:find("SECRET", 1, true))
  end
end)

-- Preconditions: curl exits successfully after returning representative client and
-- server HTTP statuses, and the exit callback is repeated to model a broken adapter.
-- Prerequisites: HTTP status is application-level data, not a transport failure;
-- delivery is scheduled and guarded independently from process callback behavior.
-- Verification items: 400 and 503 both return response tables with their bodies,
-- no transport error is produced, and duplicate exits cannot invoke callback twice.
test.it("returns HTTP error statuses as exactly-once transport successes", function()
  for _, status in ipairs({ 400, 503 }) do
    local context = harness()
    local callbacks = 0
    local response
    local transport_error
    context.transport:request({
      method = "GET",
      url = "http://127.0.0.1:8080/health",
      timeout_ms = 1000,
    }, function(value, err)
      callbacks = callbacks + 1
      response = value
      transport_error = err
    end)

    context.process:emit_stdout(
      ('{"status":%d}\n__BILINGUA_HTTP_STATUS__:%03d'):format(status, status)
    )
    context.process:exit(0)
    context.process:exit(0)
    test.eq(0, callbacks)
    context.flush()

    test.eq(1, callbacks)
    test.eq(nil, transport_error)
    test.eq(status, response.status)
    test.eq(('{"status":%d}'):format(status), response.body)
  end
end)

-- Preconditions: A spawned curl process terminates with every categorized exit
-- code, after stderr receives text that must not become a user-facing error message.
-- Prerequisites: curl's documented timeout and connection-family codes are mapped
-- at the transport boundary; all other non-zero codes are neutral I/O failures.
-- Verification items: callback is deferred and exactly once, response stays nil,
-- kind and exit_code match the mapping, and diagnostic stderr is not interpolated.
test.it("normalizes curl exit codes without exposing stderr", function()
  local cases = {
    { code = 28, kind = "timeout" },
    { code = 6, kind = "network" },
    { code = 7, kind = "network" },
    { code = 52, kind = "network" },
    { code = 55, kind = "network" },
    { code = 56, kind = "network" },
    { code = 2, kind = "io" },
  }

  for _, case in ipairs(cases) do
    local context = harness()
    local callbacks = 0
    local response
    local transport_error
    context.transport:request({
      method = "GET",
      url = "http://127.0.0.1:8080/health",
      timeout_ms = 1000,
    }, function(value, err)
      callbacks = callbacks + 1
      response = value
      transport_error = err
    end)
    context.process:emit_stderr("SECRET DOCUMENT DIAGNOSTIC")
    context.process:exit(case.code)
    context.process:exit(case.code)
    test.eq(0, callbacks)
    context.flush()

    test.eq(1, callbacks)
    test.eq(nil, response)
    test.eq(case.kind, transport_error.kind)
    test.eq(case.code, transport_error.exit_code)
    test.eq(nil, transport_error.message:find("SECRET", 1, true))
  end
end)

-- Preconditions: stdout crosses a deliberately tiny response limit before curl
-- exits, then emits another chunk and duplicate exit callbacks after being killed.
-- Prerequisites: byte accounting includes every accumulated stdout chunk and an
-- oversized response is a protocol violation that takes precedence over the signal
-- or exit status caused by terminating the child process.
-- Verification items: the process is killed once at the crossing chunk, no callback
-- occurs before exit/flush, response is nil, one protocol error is delivered, and
-- later chunks/exits cannot trigger another kill or callback.
test.it("kills curl and reports protocol failure when stdout exceeds its limit", function()
  local context = harness({ max_response_bytes = 8 })
  local callbacks = 0
  local response
  local transport_error
  context.transport:request({
    method = "GET",
    url = "http://127.0.0.1:8080/health",
    timeout_ms = 1000,
  }, function(value, err)
    callbacks = callbacks + 1
    response = value
    transport_error = err
  end)

  context.process:emit_stdout("1234")
  test.eq(false, context.process:was_killed())
  context.process:emit_stdout("56789")
  test.eq(true, context.process:was_killed())
  test.eq(1, context.process.kill_count)
  test.eq(0, callbacks)
  context.process:emit_stdout("ignored")
  test.eq(1, context.process.kill_count)

  context.process:exit(143, 15)
  context.process:exit(143, 15)
  test.eq(0, callbacks)
  context.flush()

  test.eq(1, callbacks)
  test.eq(nil, response)
  test.eq("protocol", transport_error.kind)
  test.eq(nil, transport_error.message:find("1234", 1, true))
end)

-- Preconditions: stderr arrives in multiple chunks and crosses a five-byte limit,
-- while stdout contains a valid response and curl exits successfully.
-- Prerequisites: stderr is diagnostic response metadata only; it is truncated by
-- bytes without failing or terminating an otherwise valid HTTP exchange.
-- Verification items: the stored stderr is exactly the first five bytes, the child
-- is not killed, status/body remain intact, and callback is deferred until flush.
test.it("truncates diagnostic stderr without failing the response", function()
  local context = harness({ max_stderr_bytes = 5 })
  local response
  local transport_error
  context.transport:request({
    method = "GET",
    url = "http://127.0.0.1:8080/health",
    timeout_ms = 1000,
  }, function(value, err)
    response = value
    transport_error = err
  end)

  context.process:emit_stderr("abc")
  context.process:emit_stderr("def")
  context.process:emit_stderr("ignored")
  context.process:emit_stdout('{"status":"ok"}\n__BILINGUA_HTTP_STATUS__:200')
  context.process:exit(0)
  test.eq(nil, response)
  context.flush()

  test.eq(nil, transport_error)
  test.eq(false, context.process:was_killed())
  test.eq(200, response.status)
  test.eq('{"status":"ok"}', response.body)
  test.eq("abcde", response.stderr)
end)

-- Preconditions: One process factory throws text containing a secret and another
-- returns nil instead of a vim.system-compatible object.
-- Prerequisites: spawn failures are normalized without using subprocess output or
-- thrown details, and user callbacks remain asynchronous even when spawning fails
-- synchronously inside request().
-- Verification items: both callbacks run once after flush with nil response,
-- `spawn` kind, no exit_code, and a neutral message that omits the thrown secret.
test.it("normalizes thrown and empty process spawn failures", function()
  local factories = {
    function()
      error("SECRET SPAWN DETAIL", 0)
    end,
    function()
      return nil
    end,
  }

  for _, factory in ipairs(factories) do
    local context = harness({ process_factory = factory })
    local callbacks = 0
    local response
    local transport_error
    context.transport:request({
      method = "GET",
      url = "http://127.0.0.1:8080/health",
      timeout_ms = 1000,
    }, function(value, err)
      callbacks = callbacks + 1
      response = value
      transport_error = err
    end)
    test.eq(0, callbacks)
    context.flush()

    test.eq(1, callbacks)
    test.eq(nil, response)
    test.eq("spawn", transport_error.kind)
    test.eq(nil, transport_error.exit_code)
    test.eq(nil, transport_error.message:find("SECRET", 1, true))
  end
end)

-- Preconditions: Successful curl exits carry either no status marker or a marker
-- whose status has only two digits. Prerequisites: only one anchored, three-digit
-- marker at the very end of stdout can terminate the response body.
-- Verification items: both malformed outputs produce one scheduled protocol error,
-- no response table, and no output content is copied into the error message.
test.it("rejects missing or malformed trailing status markers", function()
  for _, output in ipairs({
    "SECRET BODY WITHOUT MARKER",
    "SECRET BODY\n__BILINGUA_HTTP_STATUS__:20",
  }) do
    local context = harness()
    local callbacks = 0
    local response
    local transport_error
    context.transport:request({
      method = "GET",
      url = "http://127.0.0.1:8080/health",
      timeout_ms = 1000,
    }, function(value, err)
      callbacks = callbacks + 1
      response = value
      transport_error = err
    end)
    context.process:emit_stdout(output)
    context.process:exit(0)
    test.eq(0, callbacks)
    context.flush()

    test.eq(1, callbacks)
    test.eq(nil, response)
    test.eq("protocol", transport_error.kind)
    test.eq(nil, transport_error.message:find("SECRET", 1, true))
  end
end)

-- Preconditions: The response body itself contains a complete marker-like line,
-- followed by more body bytes and curl's actual final marker.
-- Prerequisites: the parser uses a greedy body capture plus an end anchor, so only
-- the last marker is transport metadata.
-- Verification items: the earlier marker remains byte-for-byte in the body and the
-- final marker alone determines status 200.
test.it("parses only the final status marker", function()
  local context = harness()
  local response
  local body = "prefix\n__BILINGUA_HTTP_STATUS__:418\nstill response body"
  context.transport:request({
    method = "GET",
    url = "http://127.0.0.1:8080/health",
    timeout_ms = 1000,
  }, function(value, err)
    assert(not err, err and err.message)
    response = value
  end)
  context.process:emit_stdout(body .. "\n__BILINGUA_HTTP_STATUS__:200")
  context.process:exit(0)
  context.flush()

  test.eq(200, response.status)
  test.eq(body, response.body)
end)

-- Preconditions: An active GET is cancelled twice before the process reports exit;
-- a separate invalid request is cancelled after its error has been scheduled.
-- Prerequisites: cancellation owns child termination but intentionally has no user
-- callback, and cancelling a queued delivery suppresses that delivery as well.
-- Verification items: active curl is killed exactly once, neither late exit nor a
-- duplicate cancel invokes callback, and pre-spawn scheduled errors are suppressed.
test.it("cancels idempotently and suppresses every later callback", function()
  local context = harness()
  local callbacks = 0
  local handle = context.transport:request({
    method = "GET",
    url = "http://127.0.0.1:8080/health",
    timeout_ms = 1000,
  }, function()
    callbacks = callbacks + 1
  end)
  handle:cancel()
  handle:cancel()
  test.eq(1, context.process.kill_count)
  context.process:exit(143, 15)
  context.flush()
  test.eq(0, callbacks)

  local invalid_callbacks = 0
  local invalid_handle = context.transport:request({ method = "DELETE" }, function()
    invalid_callbacks = invalid_callbacks + 1
  end)
  invalid_handle:cancel()
  context.flush()
  test.eq(0, invalid_callbacks)
end)

-- Preconditions: Construction omits the optional stderr limit and then mutates the
-- caller-owned two-part command list. Prerequisites: the transport owns a detached
-- command snapshot and uses the documented 64 KiB diagnostic default.
-- Verification items: construction succeeds, the stored stderr limit is 65536, and
-- later source mutation cannot alter either command element used by the transport.
test.it("copies its command and defaults the stderr diagnostic limit", function()
  local command = { "custom-curl", "--fixed-option" }
  local transport = curl.new({
    command = command,
    process_factory = function()
      error("not started")
    end,
    schedule = function() end,
    max_response_bytes = 1024,
  })
  command[1] = "mutated"
  command[2] = "mutated-option"

  test.eq(64 * 1024, transport.max_stderr_bytes)
  test.eq({ "custom-curl", "--fixed-option" }, transport.command)
end)
