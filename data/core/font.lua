local font = {}

local bundled_regular = DATADIR .. "/fonts/JetBrainsMono-Regular.ttf"
local bundled_faces = {
  [bundled_regular] = {
    bold = DATADIR .. "/fonts/JetBrainsMono-Bold.ttf"
  }
}

local function first_existing(paths)
  for _, path in ipairs(paths) do
    if path and system.get_file_info(path) then return path end
  end
end

local function primary_path(value)
  local paths = value and value:get_path()
  return type(paths) == "table" and paths[1] or paths
end

local function fallback_paths()
  local symbols = { DATADIR .. "/fonts/NotoSansSymbols2-Regular.ttf" }
  local emoji = {}
  if PLATFORM == "Windows" then
    local windows = os.getenv("WINDIR") or "C:\\Windows"
    symbols[#symbols + 1] = windows .. "\\Fonts\\seguisym.ttf"
    emoji[#emoji + 1] = windows .. "\\Fonts\\seguiemj.ttf"
  elseif PLATFORM == "Mac OS X" then
    symbols[#symbols + 1] = "/System/Library/Fonts/Apple Symbols.ttf"
    emoji[#emoji + 1] = "/System/Library/Fonts/Apple Color Emoji.ttc"
  else
    symbols[#symbols + 1] = "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf"
    symbols[#symbols + 1] = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    emoji[#emoji + 1] = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"
    emoji[#emoji + 1] = "/usr/local/share/fonts/NotoColorEmoji.ttf"
  end
  return first_existing(symbols), first_existing(emoji)
end

local function rendering_options(options, synthetic)
  return {
    antialiasing = options.antialiasing,
    hinting = options.hinting,
    smoothing = options.smoothing,
    bold = synthetic and options.weight == "bold" or nil,
    italic = synthetic and options.italic or nil
  }
end

function font.get_primary_path(value)
  return primary_path(value)
end

function font.resolve_face(value, size, options)
  options = options or {}
  size = size or value:get_size()
  local variants = bundled_faces[primary_path(value)]
  local variant = variants and options.weight and variants[options.weight]
  if variant and system.get_file_info(variant) then
    local loaded, result = pcall(
      renderer.font.load, variant, size, rendering_options(options, false))
    if loaded then return result, false end
  end
  local synthetic = options.weight == "bold" or options.italic
  return value:copy(size, rendering_options(options, synthetic)), synthetic
end

function font.build_stack(value, size, options)
  options = options or {}
  size = size or value:get_size()
  local primary = font.resolve_face(value, size, options)
  if options.fallbacks == false then return primary end

  local fonts = { primary }
  local existing = {}
  local paths = primary:get_path()
  if type(paths) ~= "table" then paths = { paths } end
  for _, path in ipairs(paths) do existing[path] = true end

  local symbols, emoji = fallback_paths()
  for _, path in ipairs { symbols, emoji } do
    if path and not existing[path] then
      local loaded, fallback = pcall(
        renderer.font.load, path, size, rendering_options(options, true))
      if loaded then
        fonts[#fonts + 1] = fallback
        existing[path] = true
      end
    end
  end
  return #fonts == 1 and primary or renderer.font.group(fonts)
end

function font.load_code(size, options)
  local primary = renderer.font.load(bundled_regular, size)
  return font.build_stack(primary, size, options)
end

return font
