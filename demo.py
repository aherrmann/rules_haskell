#!/usr/bin/env python

import importlib
import sys

module_list = [
    "abc",
    "os",
    "platform",
    "glob",
    "contextlib",
    "bazel_tools.tools.python.runfiles",
    "itertools",
    "subprocess",
    "datetime",
    "shlex",
    "datetime",
]

for i in range(0, int(sys.argv[2])):
    importlib.import_module(module_list[i])

outfile = open(sys.argv[1], "w")
outfile.write(sys.argv[3])
