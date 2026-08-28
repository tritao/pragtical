local test = require "core.test"
local font = require "core.font"

local regular_path = DATADIR .. "/fonts/JetBrainsMono-Regular.ttf"
local bold_path = DATADIR .. "/fonts/JetBrainsMono-Bold.ttf"
local symbols_path = DATADIR .. "/fonts/NotoSansSymbols2-Regular.ttf"

test.describe("shared font stacks", function()
  test.test("resolves the bundled bold face at the requested size", function()
    local regular = renderer.font.load(regular_path, 13)
    local bold, synthetic = font.resolve_face(regular, 19, {
      weight = "bold"
    })

    test.equal(font.get_primary_path(bold), bold_path)
    test.equal(bold:get_size(), 19)
    test.not_ok(synthetic)
  end)

  test.test("adds deterministic symbol fallbacks without changing size", function()
    local regular = renderer.font.load(regular_path, 17)
    local stack = font.build_stack(regular, 17)
    local paths = stack:get_path()
    if type(paths) ~= "table" then paths = { paths } end

    test.equal(paths[1], regular_path)
    test.contains(paths, symbols_path)
    test.equal(stack:get_size(), 17)
  end)

  test.test("uses synthetic weight when no matching face is registered", function()
    local symbols = renderer.font.load(symbols_path, 11)
    local resolved, synthetic = font.resolve_face(symbols, 15, {
      weight = "bold"
    })

    test.equal(font.get_primary_path(resolved), symbols_path)
    test.equal(resolved:get_size(), 15)
    test.ok(synthetic)
  end)
end)
