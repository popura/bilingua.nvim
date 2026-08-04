local plaintext = require("bilingua.adapters.document.plaintext")
local markdown = require("bilingua.adapters.document.markdown")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local codex_app_server = require("bilingua.adapters.translation.backends.codex_app_server")
local llama_server = require("bilingua.adapters.translation.backends.llama_server")
local initial_translation =
  require("bilingua.adapters.translation.codecs.initial_translation_json_v1")
local semantic_patch = require("bilingua.adapters.translation.codecs.semantic_patch_json_v1")
local translation_service = require("bilingua.adapters.translation.service")

local M = {}

local function copy_table(value)
  local copy = {}
  for key, item in pairs(value or {}) do
    if type(item) == "table" then
      copy[key] = copy_table(item)
    else
      copy[key] = item
    end
  end
  return copy
end

local function ensure(registry, category, name, factory)
  local getter = registry["get_" .. category]
  local register = registry["register_" .. category]
  if getter(registry, name) then
    return true
  end
  return register(registry, name, factory)
end

local function codec_options(config)
  return {
    max_input_chars = config.limits.max_task_input_chars,
    max_output_chars = config.limits.max_task_output_chars,
    timeout_ms = config.translation.timeout_ms,
  }
end

local function backend_options(config, context, backend_id)
  local options = copy_table((config.translation.backends or {})[backend_id] or {})
  options.timeout_ms = config.translation.timeout_ms
  options.ring_size = config.debug.ring_size

  for key, value in pairs((context and context.backend_runtime) or {}) do
    if options[key] == nil then
      options[key] = value
    end
  end
  return options
end

local function markdown_adapter(config, context)
  local runtime = context and context.document_runtime or nil
  local available = false
  if runtime and type(runtime.markdown_available) == "function" then
    local checked, result = pcall(runtime.markdown_available)
    available = checked and result == true and type(runtime.analyze_markdown) == "function"
  end
  if available then
    return markdown.new({
      sha256 = context and context.sha256,
      protected_patterns = config.documents.protected_patterns,
      tree_sitter_analyzer = runtime.analyze_markdown,
    })
  end
  if config.documents.fallback_to_plaintext then
    if context and type(context.warn) == "function" then
      pcall(
        context.warn,
        "Markdown Tree-sitter parser/query unavailable; using the Plaintext Adapter"
      )
    end
    return plaintext.new({
      sha256 = context and context.sha256,
      protected_patterns = config.documents.protected_patterns,
    })
  end
  return markdown.new({
    sha256 = context and context.sha256,
    protected_patterns = config.documents.protected_patterns,
    tree_sitter_required = true,
  })
end

function M.register(registry)
  if type(registry) ~= "table" then
    error("standard registration requires a Registry", 2)
  end
  local registrations = {
    {
      "document_adapter",
      "plaintext",
      function(config, context)
        return plaintext.new({
          sha256 = context and context.sha256,
          protected_patterns = config.documents.protected_patterns,
        })
      end,
    },
    {
      "document_adapter",
      "markdown",
      function(config, context)
        return markdown_adapter(config, context)
      end,
    },
    {
      "unit_tracker",
      "hybrid",
      function()
        return hybrid.new()
      end,
    },
    {
      "aligner",
      "generated_id",
      function()
        return generated_id.new()
      end,
    },
    {
      "translation_backend",
      "codex_app_server",
      function(config, context)
        return codex_app_server.new(backend_options(config, context, "codex_app_server"))
      end,
    },
    {
      "translation_backend",
      "llama_server",
      function(config, context)
        return llama_server.new(backend_options(config, context, "llama_server"))
      end,
    },
    {
      "task_codec",
      "initial_translation_json_v1",
      function(config)
        return initial_translation.new(codec_options(config))
      end,
    },
    {
      "task_codec",
      "semantic_patch_json_v1",
      function(config)
        return semantic_patch.new(codec_options(config))
      end,
    },
    {
      "translation_service",
      "default",
      function(config, context)
        local registry_for_session = context.registry
        local backend_factory =
          registry_for_session:get_translation_backend(config.translation.backend)
        local initial_factory =
          registry_for_session:get_task_codec(config.translation.initial_codec)
        local patch_factory = registry_for_session:get_task_codec(config.translation.patch_codec)
        if not backend_factory or not initial_factory or not patch_factory then
          error("The configured translation backend or task codec is not registered", 2)
        end
        local service_options = {
          backend = backend_factory(config, context),
          initial_codec = initial_factory(config, context),
          patch_codec = patch_factory(config, context),
          retry = config.sync.retry,
        }
        if context.scheduler then
          service_options.schedule = function(callback)
            return context.scheduler:schedule(callback)
          end
          service_options.defer = function(milliseconds, callback)
            return context.scheduler:defer(milliseconds, callback)
          end
        end
        return translation_service.new(service_options)
      end,
    },
  }

  for _, registration in ipairs(registrations) do
    local registered, registration_error =
      ensure(registry, registration[1], registration[2], registration[3])
    if not registered then
      return nil, registration_error
    end
  end
  return true
end

return M
