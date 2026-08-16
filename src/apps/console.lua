--- Fleet command console hosted inside a normal ICOS desktop page.

package.path = "/?.lua;/?/init.lua;" .. package.path

require("core.console").run(term.current(), { name = "ICOS" })
