--- Test registration.
---
--- A module rather than a global so the repository-wide type check stays clean:
--- an undeclared `it` would be an undefined global in every spec file.

local spec = {}

spec.cases = {}

function spec.it(name, body)
  spec.cases[#spec.cases + 1] = { name = name, body = body }
end

return spec
