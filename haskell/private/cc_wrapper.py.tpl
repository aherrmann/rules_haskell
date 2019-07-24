#!/usr/bin/env python3
"""CC toolchain wrapper

Usage: cc_wrapper [ARG]...

Wraps the C compiler of the Bazel CC toolchain. Transforms arguments to work
around limitations of Bazel and GHC and passes those via response file to the C
compiler.

- Shortens library search paths to stay below maximum path length on Windows.

    GHC generates library search paths that contain redundant up-level
    references (..). This can exceed the maximum path length on Windows, which
    will cause linking failures. This wrapper shortens library search paths to
    avoid that issue.

- Shortens rpaths and load commands on macOS.

    The rpaths and load commands generated by GHC and Bazel can quickly exceed
    the MACH-O header size limit on macOS. This wrapper shortens and combines
    rpaths and load commands to avoid exceeding that limit.

- Finds .so files if only .dylib are searched on macOS.

    Bazel's cc_library will generate .so files for dynamic libraries even on
    macOS. GHC strictly expects .dylib files on macOS. This wrapper hooks into
    gcc's --print-file-name feature to work around this mismatch in file
    extension.

"""

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

WORKSPACE = "{:workspace:}"
CC = "{:cc:}"
INSTALL_NAME_TOOL = "/usr/bin/install_name_tool"
OTOOL = "/usr/bin/otool"


def main():
    parsed = Args(load_response_files(sys.argv[1:]))

    if parsed.linking:
        link(parsed.output, parsed.libraries, parsed.rpaths, parsed.args)
    elif parsed.printing_file_name:
        print_file_name(parsed.print_file_name, parsed.args)
    else:
        run_cc(parsed.args, exit_on_error=True)


# --------------------------------------------------------------------
# Parse arguments


class Args:
    """Parsed command-line arguments.

    Attrs:
      args: The collected and transformed arguments.

      linking: The action is linking.
      printing_file_name: The action is print-file-name.

      output: The output binary or library when linking.
      library_paths: The library search paths when linking.
      libraries: The required libraries when linking.
      rpaths: The provided rpaths when linking.

      print_file_name: The queried file name on print-file-name.

    """
    LINK = "link"
    COMPILE = "compile"
    PRINT_FILE_NAME = "print-file-name"

    def __init__(self, args):
        """Parse the given arguments into an Args object.

        - Shortens library search paths.
        - Detects the requested action.
        - Keeps rpath arguments for further processing when linking.
        - Keeps print-file-name arguments for further processing.

        Args:
          args: Iterable over command-line arguments.

        """
        self.action = Args.LINK
        self.print_file_name = None
        self.libraries = []
        self.library_paths = []
        self.rpaths = []
        self.output = None
        self._prev_ld_arg = None

        self.args = list(self._handle_args(args))

        if not self.linking:
            # We don't expect rpath arguments if not linking, however, just in
            # case, forward them if we don't mean to modify them.
            self.args.extend(rpath_args(self.rpaths))

    @property
    def linking(self):
        """Whether this is a link invocation."""
        return self.action == Args.LINK and self.output is not None

    @property
    def compiling(self):
        """Whether this is a compile invocation."""
        return self.action == Args.COMPILE

    @property
    def printing_file_name(self):
        """Whether this is a print-file-name invocation."""
        return self.action == Args.PRINT_FILE_NAME and self.print_file_name is not None

    def _handle_args(self, args):
        """Argument handling pipeline.

        Args:
          args: Iterable, command-line arguments.

        Yields:
          Transformed command-line arguments.

        """
        args = iter(args)
        for arg in args:
            out = []
            # Poor man's pattern matching: Each handler function takes the
            # current argument, the stream of up-coming arguments, and a
            # reference to the list of arguments to forward. The handler must
            # return True if it consumes the argument, and return False if
            # another handler should consume the argument.
            if self._handle_output(arg, args, out):
                pass
            elif self._handle_library(arg, args, out):
                pass
            elif self._handle_library_path(arg, args, out):
                pass
            elif self._handle_linker_arg(arg, args, out):
                pass
            elif self._handle_print_file_name(arg, args, out):
                pass
            elif self._handle_compile(arg, args, out):
                pass
            else:
                yield arg

            for out_arg in out:
                yield out_arg

    def _handle_output(self, arg, args, out):
        if arg == "-o":
            # Remember the output filename.
            self.output = next(args)
            out.extend(["-o", self.output])
            return True
        else:
            return False

    def _handle_library(self, arg, args, out):
        if arg == "-l" or arg == "--library":
            library = next(args)
        elif arg.startswith("-l"):
            library = arg[2:]
        elif arg.startswith("--library="):
            library = arg[len("--library="):]
        else:
            return False

        # Remember the required libraries.
        self.libraries.append(library)
        out.append("-l{}".format(library))

        return True

    def _handle_library_path(self, arg, args, out):
        if arg == "-L" or arg == "--library-path":
            library_path = next(args)
        elif arg.startswith("-L"):
            library_path = arg[2:]
        elif arg.startswith("--library-path="):
            library_path = arg[len("--library-path="):]
        else:
            return False

        # Shorten the library search paths. On Windows library search paths may
        # exceed the maximum path length.
        shortened = shorten_path(library_path)
        # Remember the library search paths.
        self.library_paths.append(shortened)
        out.append("-L{}".format(shortened))

        return True

    def _handle_linker_arg(self, arg, args, out):
        if arg == "-Xlinker":
            ld_arg = next(args)
            if self._prev_ld_arg is None:
                if ld_arg == "-rpath":
                    self._prev_ld_arg = ld_arg
                else:
                    out.extend(["-Xlinker", ld_arg])
            elif self._prev_ld_arg == "-rpath":
                self._prev_ld_arg = None
                self._handle_rpath(ld_arg, out)
            else:
                # This indicates a programmer error and should not happen.
                raise RuntimeError("Unhandled _prev_ld_arg '{}'.".format(self._prev_ld_arg))
            return True
        elif arg.startswith("-Wl,"):
            ld_args = arg.split(",")[1:]
            if len(ld_args) == 2 and ld_args[0] == "-rpath":
                self._handle_rpath(ld_args[1], out)
                return True
            else:
                out.append(arg)
                return True
        else:
            return False

    def _handle_rpath(self, rpath, out):
        # Filter out all RPATH flags for now and manually add the needed ones
        # later on.
        self.rpaths.append(rpath)

    def _handle_print_file_name(self, arg, args, out):
        if arg == "--print-file-name":
            print_file_name = next(args)
        elif arg.startswith("--print-file-name="):
            print_file_name = arg[len("--print-file-name="):]
        else:
            return False

        # Remember print-file-name action. Don't forward to allow for later
        # manipulation.
        self.print_file_name = print_file_name
        self.action = Args.PRINT_FILE_NAME

        return True

    def _handle_compile(self, arg, args, out):
        if arg == "-c":
            self.action = Args.COMPILE
            out.append(arg)
        else:
            return False

        return True


def load_response_files(args):
    """Generator that loads arguments from response files.

    Passes through any regular arguments.

    Args:
      args: Iterable of arguments.

    Yields:
      All arguments, with response files replaced by their contained arguments.

    """
    args = iter(args)
    for arg in args:
        if arg == "-install_name":
            # macOS only: The install_name may start with an '@' character.
            yield arg
            yield next(args)
        elif arg.startswith("@"):
            with open(arg[1:], "r") as rsp:
                for line in rsp:
                    for rsp_arg in parse_response_line(line):
                        yield rsp_arg
        else:
            yield arg


def parse_response_line(s):
    # GHC writes response files with quoted lines.
    return shlex.split(s)


def shorten_path(input_path):
    """Shorten the given path if possible.

    Applies the following transformations if they shorten the path length:
      - Make path relative to CWD.
      - Remove redundant up-level references.
      - Resolve symbolic links.

    Args:
      input_path: The path to shorten.

    Returns:
      The shortened path.

    """
    exists = os.path.exists(input_path)
    shortened = input_path

    # Try relativizing to current working directory.
    rel = os.path.relpath(shortened)
    if len(rel) < len(shortened):
        shortened = rel

    # Try normalizing the path if possible.
    norm = os.path.normpath(shortened)
    if len(norm) < len(shortened):
        # Ensure that the path is still correct. Reducing up-level references
        # may change the meaning of the path in the presence of symbolic links.
        try:
            if not exists or os.path.samefile(norm, shortened):
                shortened = norm
        except IOError:
            # stat may fail if the path became invalid or does not exist.
            pass

    # Try resolving symlinks.
    try:
        real = os.path.relpath(os.path.realpath(shortened))
        if len(real) < len(shortened):
            shortened = real
    except IOError:
        # realpath may fail if the path does not exist.
        pass

    return shortened


def rpath_args(rpaths):
    """Generate arguments for RUNPATHs."""
    for rpath in rpaths:
        yield "-Xlinker"
        yield "-rpath"
        yield "-Xlinker"
        yield rpath


# --------------------------------------------------------------------
# Link binary or library


def link(output, libraries, rpaths, args):
    """Execute the link action.

    Args:
      output: The output binary or library.
      libraries: Library dependencies.
      rpaths: The provided rpaths.
      args: The command-line arguments.

    """
    if is_darwin():
        # Reserve space in load commands for later replacement.
        args.append("-headerpad_max_install_names")
        rpaths, darwin_rewrites = darwin_shorten_rpaths(
                rpaths, libraries, output)
    else:
        rpaths = shorten_rpaths(rpaths, libraries, output)

    args.extend(rpath_args(rpaths))
    run_cc(args, exit_on_error=True)

    if is_darwin():
        darwin_rewrite_load_commands(darwin_rewrites, output)


def shorten_rpaths(rpaths, libraries, output):
    """Avoid redundant rpaths.

    Filters out rpaths that are not required to load any library dependency.

    Args:
      rpaths: List of given rpaths.
      libraries: List of library dependencies.
      output: The output binary, used to resolve rpaths.

    Returns:
      List of required rpaths.

    """
    input_rpaths = sort_rpaths(rpaths)
    missing = set(libraries)

    rpaths = []

    for rpath in input_rpaths:
        if not missing:
            break
        rpath, rpath_dir = resolve_rpath(rpath, output)
        found, missing = find_library(missing, rpath_dir)
        if found:
            rpaths.append(rpath)

    return rpaths


def darwin_shorten_rpaths(rpaths, libraries, output):
    """Avoid redundant rpaths and adapt library load commands.

    Avoids redundant rpaths by detecting the solib directory and making load
    commands relative to the solib directory where applicable.

    Args:
      rpaths: List of given rpaths.
      libraries: List of library dependencies.
      output: The output binary, used to resolve rpaths.

    Returns:
      (rpaths, rewrites):
        rpaths: List of required rpaths.
        rewrites: List of load command rewrites.

    """
    input_rpaths = sort_rpaths(rpaths)
    missing = set(libraries)

    rpaths = []
    rewrites = []

    # References to core libs take up much space. Consider detecting the GHC
    # libdir and adding an rpath for that and making load commands relative to
    # that. Alternatively, https://github.com/bazelbuild/bazel/pull/8888 would
    # also avoid this issue.

    # Determine solib dir and rewrite load commands relative to solib dir.
    # This allows to replace potentially many rpaths by one.
    solib_rpath = find_solib_rpath(input_rpaths, output)
    if missing and solib_rpath is not None:
        solib_rpath, solib_dir = resolve_rpath(solib_rpath, output)

        found, missing = find_library_recursive(missing, solib_dir)
        if found:
            rpaths.append(solib_rpath)
            for f in found.values():
                soname = darwin_get_install_name(os.path.join(solib_dir, f))
                rewrites.append((soname, f))

    # For the remaining missing libraries, determine which rpaths are required.
    for rpath in input_rpaths:
        if not missing:
            break
        rpath, rpath_dir = resolve_rpath(rpath, output)
        found, missing = find_library(missing, rpath_dir)
        # Libraries with an absolute install_name don't require an rpath entry.
        found = dict(itertools.filterfalse(
                lambda item: os.path.isabs(darwin_get_install_name(os.path.join(rpath_dir, item[1]))),
                found.items()))
        if len(found) == 1:
            # Avoid unnecessary rpath if it is only relevant for one load command.
            [filename] = found.values()
            soname = darwin_get_install_name(os.path.join(rpath_dir, filename))
            rewrites.append((soname, os.path.join(rpath, filename)))
        elif found:
            rpaths.append(rpath)

    return rpaths, rewrites


def sort_rpaths(rpaths):
    """Sort RUNPATHs by preference.

    Preference in decsending order:
      - Relative to target
      - Absolute path
      - Relative to CWD

    """
    def rpath_priority(rpath):
        system = platform.system()
        if system == "Darwin":
            if rpath.startswith("@loader_path"):
                return 0
        elif system == "Linux":
            if rpath.startswith("$ORIGIN"):
                return 0
        if os.path.isabs(rpath):
            return 1
        return 2

    return sorted(rpaths, key=rpath_priority)


def find_solib_rpath(rpaths, output):
    """Find the solib directory rpath entry.

    The solib directory is the directory under which Bazel places dynamic
    library symbolic links on Unix. It has the form `_solib_<cpu>`.

    """
    for rpath in rpaths:
        components = rpath.replace("\\", "/").split("/")
        solib_rpath = []
        for comp in components:
            solib_rpath.append(comp)
            if comp.startswith("_solib_"):
                return "/".join(solib_rpath)

    if is_temporary_output(output):
        # GHC generates temporary libraries outside the execroot. In that case
        # the Bazel generated RPATHs are not forwarded, and the solib directory
        # is not visible on the command-line.
        candidates = glob.glob("**/bin/_solib_*", recursive=True)
        if candidates:
            return min(candidates)

    return None


def find_library_recursive(libraries, directory):
    """Find libraries in given directory tree.

    Args:
      libraries: List of missing libraries.
      directory: Root of directory tree.

    Returns:
      (found, missing):
        found: Dict of found libraries {libname: path} relative to directory.
        missing: Set of remaining missing libraries.

    """
    missing = set(libraries)
    found = {}
    for root, _, files in os.walk(directory, followlinks=True):
        prefix = os.path.relpath(root, directory)
        if not missing:
            break
        for f in files:
            libname = get_lib_name(f)
            if libname and libname in missing:
                found[libname] = os.path.join(prefix, f) if prefix != "." else f
                missing.discard(libname)
                if not missing:
                    break

    return found, missing


def find_library(libraries, directory):
    """Find libraries in the given directory.

    Args:
      libraries: List of missing libraries.
      directory: The directory in which to search for libraries.

    Returns:
      (found, missing):
        found: Dict of found libraries {libname: path} relative to directory.
        missing: Set of remaining missing libraries.

    """
    missing = set(libraries)
    found = {}
    for _, _, files in itertools.islice(os.walk(directory), 1):
        if not missing:
            break
        for f in files:
            libname = get_lib_name(f)
            if libname and libname in missing:
                found[libname] = f
                missing.discard(libname)

    return found, missing


def get_lib_name(filename):
    """Determine the library name of the given library file.

    The library name is the name by which the library is referred to in a -l
    argument to the linker.

    """
    if not filename.startswith("lib"):
        return None

    libname = filename[3:]
    dotsodot = libname.find(".so.")
    if dotsodot != -1:
        return libname[:dotsodot]

    libname, ext = os.path.splitext(libname)
    if ext in [".dll", ".dylib", ".so"]:
        return libname

    return None


def resolve_rpath(rpath, output):
    """Resolve the given rpath, replacing references to the binary."""
    def has_origin(rpath):
        return rpath.startswith("$ORIGIN") or rpath.startswith("@loader_path")

    def replace_origin(rpath, origin):
        rpath = rpath.replace("$ORIGIN/", origin)
        rpath = rpath.replace("$ORIGIN", origin)
        rpath = rpath.replace("@loader_path/", origin)
        rpath = rpath.replace("@loader_path", origin)
        return rpath

    if is_temporary_output(output):
        # GHC generates temporary libraries outside the execroot. The regular
        # relative rpaths don't work in that case and have to be converted to
        # absolute paths.
        if has_origin(rpath):
            # We don't know what $ORIGIN/@loader_path was meant to refer to.
            # Try to find an existing, matching rpath by globbing.
            stripped = replace_origin(rpath, "")
            candidates = glob.glob(os.path.join("**", stripped), recursive=True)
            if not candidates:
                # Path does not exist. It will be sorted out later, since no
                # library will be found underneath it.
                rpath = stripped
            else:
                rpath = os.path.abspath(shorten_path(min(candidates)))
        else:
            rpath = os.path.abspath(shorten_path(rpath))

        return rpath, rpath
    else:
        # Consider making relative rpaths relative to output.
        #   E.g. bazel-out/.../some/dir to @loader_path/.../some/dir
        outdir = os.path.dirname(output) + "/"
        resolved = replace_origin(rpath, outdir)
        return rpath, resolved


def darwin_get_install_name(lib):
    """Read the install_name of the given library."""
    lines = subprocess.check_output([OTOOL, "-D", lib]).splitlines()
    if len(lines) >= 2:
        return lines[1]
    else:
        return os.path.basename(lib)


def darwin_rewrite_load_commands(rewrites, output):
    """Rewrite the load commands in the given binary."""
    args = []
    for old, new in rewrites:
        args.extend(["-change", old, os.path.join("@rpath", new)])
    if args:
        subprocess.check_call([INSTALL_NAME_TOOL] + args + [output])


# --------------------------------------------------------------------
# print-file-name


def print_file_name(filename, args):
    """Execute the print-file-name action.

    Args:
      filename: The queried filename.
      args: The remaining arguments.

    """
    (basename, ext) = os.path.splitext(filename)
    found = run_cc_print_file_name(filename, args)
    if not found and is_darwin() and ext == ".dylib":
        # Bazel generates dynamic libraries with .so extension on Darwin.
        # However, GHC only looks for files with .dylib extension.

        # Retry with .so extension.
        found = run_cc_print_file_name("%s.so" % basename, args)

    # Note, gcc --print-file-name does not fail if the file was not found, but
    # instead just returns the input filename.
    if found:
        print(found)
    else:
        print(filename)

    sys.exit()


def run_cc_print_file_name(filename, args):
    """Run cc --print-file-name on the given file name.

    Args:
      filename: The filename to query for.
      args: Remaining command-line arguments. Relevant for -B flags.

    Returns:
      filename, res:
        filename: The returned filename, if it exists, otherwise None.
        res: CompletedProcess

    """
    args = args + ["--print-file-name", filename]
    _, stdoutbuf, _ = run_cc(args, capture_output=True, exit_on_error=True)
    filename = stdoutbuf.decode().strip()
    # Note, gcc --print-file-name does not fail if the file was not found, but
    # instead just returns the input filename.
    if os.path.isfile(filename):
        return filename
    else:
        return None


# --------------------------------------------------------------------


def run_cc(args, capture_output=False, exit_on_error=False, **kwargs):
    """Execute cc with a response file holding the given arguments.

    Args:
      args: Iterable of arguments to pass to cc.
      capture_output: Whether to capture stdout and stderr.
      exit_on_error: Whether to exit on error. Will print captured output first.

    Returns:
      (returncode, stdoutbuf, stderrbuf):
        returncode: The exit code of the the process.
        stdoutbuf: The captured standard output, None if not capture_output.
        stderrbuf: The captured standard error, None if not capture_output.

    """
    if capture_output:
        # The capture_output argument to subprocess.run was only added in 3.7.
        new_kwargs = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        new_kwargs.update(kwargs)
        kwargs = new_kwargs

    if os.path.isfile(CC):
        cc = CC
    else:
        # On macOS CC is a relative path to a wrapper script. If we're
        # being called from a GHCi REPL then we need to find this wrapper
        # script using Bazel runfiles.
        r = bazel_runfiles.Create()
        cc = r.Rlocation("/".join([WORKSPACE, CC]))
        if cc is None and platform.system() == "Windows":
            # We must use "/" instead of os.path.join on Windows, because the
            # Bazel runfiles_manifest file uses "/" separators.
            cc = r.Rlocation("/".join([WORKSPACE, CC + ".exe"]))
        if cc is None:
            sys.stderr.write("CC not found '{}'.\n".format(CC))
            sys.exit(1)

    stdoutbuf = None
    stderrbuf = None

    with response_file(args) as rsp:
        with subprocess.Popen([cc, "@" + rsp], **kwargs) as proc:
            if capture_output:
                (stdoutbuf, stderrbuf) = proc.communicate()

            returncode = proc.wait()

    if exit_on_error and returncode != 0:
        if capture_output:
            sys.stdout.write(stdout.decode())
            sys.stderr.write(stderr.decode())
        sys.exit(returncode)

    return (returncode, stdoutbuf, stderrbuf)


@contextmanager
def response_file(args):
    """Create a response file for the given arguments.

    Context manager, use in a with statement. The file will be deleted at the
    end of scope.

    Args:
      args: Iterable, the arguments to write in to the response file.

    Yields:
      The file name of the response file.

    """
    try:
        with tempfile.NamedTemporaryFile(mode="w", prefix="rsp", delete=False) as f:
            for arg in args:
                line = generate_response_line(arg)
                f.write(line)
            f.close()
            yield f.name
    finally:
        try:
            os.remove(f.name)
        except OSError:
            pass


def generate_response_line(arg):
    # Gcc expects one argument per line, surrounded by double quotes, with
    # inner double quotes escaped with backslash, and backslashes themselves
    # escaped. shlex.quote conflicts with this format.
    return '"{}"\n'.format(arg.replace("\\", "\\\\").replace('"', '\\"'))


def is_darwin():
    """Whether the execution platform is Darwin."""
    return platform.system() == "Darwin"


def is_temporary_output(output):
    """Whether the target is temporary.

    GHC generates temporary libraries in certain cases related to Template
    Haskell outside the execroot. This means that rpaths relative to $ORIGIN or
    @loader_path are going to be invalid.

    """
    # Assumes that the temporary directory is set to an absolute path, while
    # the outputs under the execroot are referred to by relative path. This
    # should be a valid assumption as the temporary directory needs to be
    # available irrespective of the current working directory, while Bazel uses
    # paths relative to the execroot to avoid things like user names creeping
    # into cache keys. If this turns out to be wrong we could instead look for
    # path components matching Bazel's output directory hierarchy.
    # See https://docs.bazel.build/versions/master/output_directories.html
    return os.path.isabs(output)


# --------------------------------------------------------------------


if __name__ == "__main__":
    main()


# vim: ft=python
