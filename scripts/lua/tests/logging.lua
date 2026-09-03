local core = require "core"
local test = require "core.test"

test.describe("persistent application logging", function()
  test.it("writes and flushes each entry to the current run log", function()
    test.type(core.log_file_path, "string")
    local marker = string.format(
      "persistent-log-test-%d-%d",
      system.get_process_id(),
      math.floor(system.get_time() * 1000000)
    )

    core.log_quiet("%s", marker)

    local file, err = io.open(core.log_file_path, "rb")
    test.ok(file, err)
    local contents = file:read("*a")
    file:close()
    test.match(contents, marker, nil, true)
    test.match(contents, "%[INFO%]")
  end)
end)
