#!/usr/bin/env python

from bazel_tools.tools.python.runfiles import runfiles as bazel_runfiles
from contextlib import contextmanager
import glob
import itertools
import os
import platform
import shlex
import subprocess
import sys
import tempfile

import datetime

outfile = open(sys.argv[1], "w")
outfile.write(sys.argv[2])
