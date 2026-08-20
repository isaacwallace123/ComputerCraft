"""Does every `module.field` call name something the module actually exports?

Written after `format.fit` - a call to a function that does not exist - shipped
past 623 specs and four static checks, and was found by a turtle in a world
refusing to draw its own screen.

Nothing was looking for it. The spec suite could not: nothing exercised that
line. The type checker could not: it does not follow a `require` return through
a local binding. And the failure is invisible until the exact moment the line
runs, which for a UI is the moment somebody looks at it.

The check is cheap because this codebase has one shape for a module - a local
table, functions assigned to it by name, returned at the end - so a module's
exports are every `function name.field` in it, and a caller's uses are every
`local.field` where `local` came from a `require`.

## It refuses to guess

Two rules keep it from becoming a noise generator, and both were learned by
running it: comments and strings are stripped first, because every module here
is documented in prose that names other files; and a use must not be preceded by
a dot, so `state.plan.configured` does not read as a call on the `plan` module.

Anything it cannot analyse confidently - a module built as a table literal, one
returning a metatable - is skipped rather than reported. A false positive costs
more than a miss here: a check people learn to ignore is worse than no check.
"""

import io
import os
import re
import sys

SRC = "src"

# The binding must be the whole module: `local x = require("m")`, not
# `require("m").FIELD`, which binds a member rather than the table.
MODULE_LOCAL = re.compile(r'^\s*local\s+(\w+)\s*=\s*require\("([\w.]+)"\)\s*$', re.M)

DEFINES = re.compile(r"^function\s+(\w+)[.:](\w+)", re.M)
ASSIGNS = re.compile(r"^(\w+)\.(\w+)\s*=", re.M)


def strip(text):
    """Remove comments and string literals.

    Without this the check reads the documentation. Every module in this
    codebase names other files in its header - `grid.lua`, `plan.lua` - and a
    scanner that counts those is a scanner reporting prose.
    """
    text = re.sub(r"--\[\[.*?\]\]", " ", text, flags=re.S)
    text = re.sub(r"--[^\n]*", " ", text)
    text = re.sub(r'"[^"\n]*"', '""', text)
    text = re.sub(r"'[^'\n]*'", "''", text)
    return text


def path_of(module):
    return os.path.join(SRC, module.replace(".", os.sep) + ".lua")


def exports(path):
    """Every name a module puts on its table, or None if it cannot be read."""
    try:
        raw = io.open(path, encoding="utf-8").read()
    except OSError:
        return None

    code = strip(raw)
    names = set()
    for _, field in DEFINES.findall(code):
        names.add(field)
    for _, field in ASSIGNS.findall(code):
        names.add(field)

    # A module that builds its table as a *non-empty* literal puts names on it
    # that no `function x.y` or `x.y =` line mentions - `ui/init.lua` is the one
    # here, and judging it flagged `ui.anim` as missing when it is defined three
    # lines from the top.
    #
    # `local x = {}` is fine and is the shape almost everything uses; only a
    # literal with entries in it is opaque.
    if re.search(r"^local\s+\w+\s*=\s*\{\s*$", code, re.M):
        return None

    # Likewise a metatable, or a module with nothing found at all. None means
    # "do not judge", and it is always the right answer when unsure: a false
    # positive costs more than a miss, because a check people learn to ignore is
    # worse than no check.
    if re.search(r"return\s+setmetatable", code) or not names:
        return None
    return names


def main():
    problems = []

    for base, _, files in os.walk(SRC):
        for name in files:
            if not name.endswith(".lua"):
                continue

            path = os.path.join(base, name)
            raw = io.open(path, encoding="utf-8").read()
            code = strip(raw)

            # Requires come from the raw text and uses from the stripped text,
            # which is not a detail: `strip` blanks string literals, so reading
            # the require out of it finds `require("")` and matches nothing. The
            # first version of this check did exactly that and reported a clean
            # tree while the bug it was written for sat three files away.
            for local, module in MODULE_LOCAL.findall(raw):
                target = path_of(module)
                if not os.path.exists(target):
                    continue
                if os.path.abspath(target) == os.path.abspath(path):
                    continue

                known = exports(target)
                if known is None:
                    continue

                # Not preceded by a dot or a word character, so `state.plan.x`
                # does not read as a use of the `plan` module. That one
                # distinction is most of the difference between a check and a
                # noise generator.
                used = re.compile(r"(?<![\w.])" + re.escape(local) + r"\.(\w+)")
                for field in sorted(set(used.findall(code))):
                    if field not in known:
                        rel = path.replace(os.sep, "/")
                        problems.append(
                            "%s calls %s.%s, which %s does not define"
                            % (rel, local, field, module)
                        )

    for line in sorted(set(problems)):
        print("  " + line)

    if problems:
        print("  %d call(s) name something that does not exist" % len(set(problems)))
        return 1

    print("  every module call resolves")
    return 0


sys.exit(main())
