#!/usr/bin/env python

from bazel_tools.tools.python.runfiles import runfiles as bazel_runfiles
import sys

outfile = open(sys.argv[1], "w")
outfile.write(sys.argv[2])
