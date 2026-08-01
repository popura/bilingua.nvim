std = "lua51"
globals = { "vim" }

-- Port contracts intentionally retain colon receivers, and nested disposable
-- methods use their own colon receiver while closing over the owning object.
ignore = {
  "212/self",
  "432/self",
}
max_line_length = false
