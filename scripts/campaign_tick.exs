#!/usr/bin/env elixir

args = System.argv()
root = Path.expand(Path.join([__DIR__, ".."]))

{output, status} =
  System.cmd(Path.join(root, "bin/jx"), ["campaign" | args],
    cd: root,
    stderr_to_stdout: true
  )

IO.write(output)
System.halt(status)
