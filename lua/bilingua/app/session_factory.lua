local errors = require("bilingua.domain.error")
local session_module = require("bilingua.app.session")

local SessionFactory = {}
SessionFactory.__index = SessionFactory

local CONTRACTS = {
  editor = {
    "capabilities",
    "create_target_view",
    "get_document",
    "get_text",
    "get_version",
    "apply_edits",
    "subscribe_changes",
    "set_unit_anchors",
    "get_anchor_hints",
    "unit_at_cursor",
    "focus_side",
    "focus_group",
    "render_group_states",
    "set_target_modifiable",
    "set_target_modified",
    "dispose",
  },
  document_adapter = {
    "capabilities",
    "parse",
    "extract_fragment",
    "build_initial_target",
    "plan_replace",
    "validate_edits",
  },
  unit_tracker = { "capabilities", "reconcile" },
  aligner = { "capabilities", "initialize", "reconcile" },
  translation_service = { "capabilities", "open", "submit", "close" },
}

local IDENTIFIED_CONTRACTS = {
  document_adapter = true,
  unit_tracker = true,
  aligner = true,
}

local function assert_contract(name, instance)
  if type(instance) ~= "table" or instance.api_version ~= 1 then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        ("%s must implement extension API version 1"):format(name),
        false
      )
  end
  if IDENTIFIED_CONTRACTS[name] and (type(instance.id) ~= "string" or instance.id == "") then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        ("%s must expose a non-empty id"):format(name),
        false
      )
  end
  for _, method in ipairs(CONTRACTS[name]) do
    if type(instance[method]) ~= "function" then
      return nil,
        errors.new(
          errors.codes.INVALID_ARGUMENT,
          ("%s must implement %s()"):format(name, method),
          false
        )
    end
  end
  return true
end

local function dispose_partial(instances)
  local service = instances.translation_service
  if service and type(service.close) == "function" then
    pcall(service.close, service, function() end)
  end
  local editor = instances.editor
  if editor and type(editor.dispose) == "function" then
    pcall(editor.dispose, editor, { force = true })
  end
end

local function instantiate(name, factory, config, context)
  local called, instance, factory_error = pcall(factory, config, context)
  if not called then
    return nil,
      errors.new(
        errors.codes.INTERNAL,
        ("The %s factory raised an internal error"):format(name),
        false,
        { component = name },
        instance
      )
  end
  if
    instance == nil
    and type(factory_error) == "table"
    and type(factory_error.code) == "string"
  then
    return nil, factory_error
  end
  return instance
end

local function resolve_route(config, filetype)
  local routes = config.documents.routes
  local route = routes[filetype]
  if route then
    return route
  end
  local aliases = config.documents.aliases or {}
  local canonical = aliases[filetype]
  if canonical and routes[canonical] then
    return routes[canonical]
  end
  if config.documents.fallback_to_plaintext then
    return { adapter = "plaintext", tracker = "hybrid", aligner = "generated_id" }
  end
  return nil
end

function SessionFactory.new(options)
  if
    type(options) ~= "table"
    or type(options.registry) ~= "table"
    or type(options.editor_factory) ~= "function"
  then
    error("SessionFactory requires a registry and editor factory", 2)
  end
  return setmetatable({
    registry = options.registry,
    editor_factory = options.editor_factory,
    scheduler = options.scheduler,
    sha256 = options.sha256,
    backend_runtime = options.backend_runtime,
    document_runtime = options.document_runtime,
    warn = options.warn,
    sequence = 0,
  }, SessionFactory)
end

function SessionFactory:next_session_id()
  self.sequence = self.sequence + 1
  return ("session:%d"):format(self.sequence)
end

function SessionFactory:create(context, config)
  if type(context) ~= "table" or type(config) ~= "table" then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Session context and configuration are required",
        false
      )
  end
  local route = resolve_route(config, context.filetype)
  if not route then
    return nil,
      errors.new(
        errors.codes.UNSUPPORTED_FILETYPE,
        "No document route matches this filetype",
        false
      )
  end

  local factories = {
    document_adapter = self.registry:get_document_adapter(route.adapter),
    unit_tracker = self.registry:get_unit_tracker(route.tracker),
    aligner = self.registry:get_aligner(route.aligner),
    translation_service = self.registry:get_translation_service(config.translation.service),
  }
  for name, factory in pairs(factories) do
    if type(factory) ~= "function" then
      return nil,
        errors.new(
          errors.codes.INVALID_ARGUMENT,
          ("No factory is registered for %s"):format(name),
          false,
          { route = route, component = name }
        )
    end
  end

  local session_id = self:next_session_id()
  local component_context = {
    session_id = session_id,
    source_buf = context.source_buf,
    source_window = context.source_window,
    source_path = context.source_path,
    filetype = context.filetype,
    config = config,
    registry = self.registry,
    scheduler = self.scheduler,
    sha256 = self.sha256,
    backend_runtime = self.backend_runtime,
    document_runtime = self.document_runtime,
    warn = self.warn,
  }
  local definitions = {
    { "editor", self.editor_factory },
    { "document_adapter", factories.document_adapter },
    { "unit_tracker", factories.unit_tracker },
    { "aligner", factories.aligner },
    { "translation_service", factories.translation_service },
  }
  local instances = {}
  for _, definition in ipairs(definitions) do
    local name, factory = definition[1], definition[2]
    local instance, factory_error = instantiate(name, factory, config, component_context)
    if not instance then
      dispose_partial(instances)
      return nil, factory_error
    end
    instances[name] = instance
    local valid, contract_error = assert_contract(name, instance)
    if not valid then
      dispose_partial(instances)
      return nil, contract_error
    end
  end

  local function translator_factory()
    local service, factory_error =
      instantiate("translation_service", factories.translation_service, config, component_context)
    if not service then
      return nil, factory_error
    end
    local valid, contract_error = assert_contract("translation_service", service)
    if not valid then
      dispose_partial({ translation_service = service })
      return nil, contract_error
    end
    return service
  end

  local constructed, session = pcall(session_module.new, {
    id = session_id,
    editor = instances.editor,
    document_adapter = instances.document_adapter,
    unit_tracker = instances.unit_tracker,
    aligner = instances.aligner,
    translator = instances.translation_service,
    translator_factory = translator_factory,
    scheduler = self.scheduler,
    config = config,
  })
  if not constructed or type(session) ~= "table" then
    dispose_partial(instances)
    return nil,
      errors.new(
        errors.codes.INTERNAL,
        "Final Session construction failed",
        false,
        { component = "session" },
        session
      )
  end
  session.source_buf = context.source_buf
  session.source_window = context.source_window
  session.source_path = context.source_path
  return session
end

return {
  new = SessionFactory.new,
}
