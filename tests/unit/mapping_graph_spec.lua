local test = require("tests.testlib")
local mapping_graph = require("bilingua.domain.mapping_graph")

-- Preconditions: Two ordered groups describe one source-to-two-target mapping
-- and one source orphan. Prerequisites: A unit may belong to at most one group,
-- while either side of a group may contain zero or more units. Verification
-- items: group order is preserved and both side indexes point to the owning group
-- without inventing a target membership for the orphan.
test.it("indexes one-to-many mappings and explicit orphans", function()
  local graph, err = mapping_graph.new({
    {
      id = "group:1",
      source_unit_ids = { "src:u:000001" },
      target_unit_ids = { "tgt:u:000001", "tgt:u:000002" },
      state = "clean",
    },
    {
      id = "group:2",
      source_unit_ids = { "src:u:000002" },
      target_unit_ids = {},
      state = "dirty_source",
    },
  })

  test.eq(nil, err)
  test.eq({ "group:1", "group:2" }, graph.order)
  test.eq({ "group:1" }, graph.source_index["src:u:000001"])
  test.eq({ "group:1" }, graph.target_index["tgt:u:000002"])
  test.eq(nil, graph.target_index["src:u:000002"])
  test.eq(1, graph.revision)
end)

-- Preconditions: One graph contains independent one-to-one, one-to-many,
-- many-to-one, many-to-many, source-orphan, and target-orphan groups.
-- Prerequisites: Membership is exclusive per side but group arity is otherwise
-- unrestricted. Verification items: order and every source/target reverse index
-- identify the exact owner without filling either explicit orphan.
test.it("indexes every supported mapping shape and both orphan directions", function()
  local graph = assert(mapping_graph.new({
    {
      id = "one:one",
      source_unit_ids = { "s1" },
      target_unit_ids = { "t1" },
      state = "clean",
    },
    {
      id = "one:many",
      source_unit_ids = { "s2" },
      target_unit_ids = { "t2", "t3" },
      state = "clean",
    },
    {
      id = "many:one",
      source_unit_ids = { "s3", "s4" },
      target_unit_ids = { "t4" },
      state = "clean",
    },
    {
      id = "many:many",
      source_unit_ids = { "s5", "s6" },
      target_unit_ids = { "t5", "t6" },
      state = "clean",
    },
    {
      id = "source:orphan",
      source_unit_ids = { "s7" },
      target_unit_ids = {},
      state = "dirty_source",
    },
    {
      id = "target:orphan",
      source_unit_ids = {},
      target_unit_ids = { "t7" },
      state = "dirty_target",
    },
  }))

  test.eq({ "one:one" }, graph.source_index.s1)
  test.eq({ "one:one" }, graph.target_index.t1)
  test.eq({ "one:many" }, graph.target_index.t3)
  test.eq({ "many:one" }, graph.source_index.s4)
  test.eq({ "many:many" }, graph.source_index.s6)
  test.eq({ "many:many" }, graph.target_index.t6)
  test.eq({ "source:orphan" }, graph.source_index.s7)
  test.eq(nil, graph.target_index.s7)
  test.eq({ "target:orphan" }, graph.target_index.t7)
  test.eq(nil, graph.source_index.t7)
end)

-- Preconditions: A graph is reconstructed after membership changes, and two
-- malformed candidates separately reuse one source ID and one target ID.
-- Prerequisites: MappingGraph construction rebuilds indexes from the supplied
-- groups and forbids duplicate membership on either side. Verification items:
-- the rebuilt graph has no stale target index and both duplicate cases return
-- E_ALIGNMENT without exposing a partial graph.
test.it("rebuilds indexes and rejects duplicate membership on either side", function()
  local rebuilt = assert(mapping_graph.new({
    {
      id = "group:new",
      source_unit_ids = { "s1", "s2" },
      target_unit_ids = { "t2" },
      state = "clean",
    },
  }, 4))
  test.eq(4, rebuilt.revision)
  test.eq({ "group:new" }, rebuilt.source_index.s2)
  test.eq({ "group:new" }, rebuilt.target_index.t2)
  test.eq(nil, rebuilt.target_index.t1)

  for _, duplicate in ipairs({
    {
      { id = "a", source_unit_ids = { "same" }, target_unit_ids = { "t1" } },
      { id = "b", source_unit_ids = { "same" }, target_unit_ids = { "t2" } },
    },
    {
      { id = "a", source_unit_ids = { "s1" }, target_unit_ids = { "same" } },
      { id = "b", source_unit_ids = { "s2" }, target_unit_ids = { "same" } },
    },
  }) do
    local graph, graph_error = mapping_graph.new(duplicate)
    test.eq(nil, graph)
    test.eq("E_ALIGNMENT", graph_error.code)
  end
end)
