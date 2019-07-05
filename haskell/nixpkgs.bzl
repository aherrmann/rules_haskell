"""Workspace rules (Nixpkgs)"""

load(
    "@io_tweag_rules_nixpkgs//nixpkgs:nixpkgs.bzl",
    "nixpkgs_package",
)
load(
    ":private/workspace_utils.bzl",
    "ghc_is_static",
)

def _ghc_nixpkgs_haskell_toolchain_impl(repository_ctx):
    compiler_flags_select = "select({})".format(
        repository_ctx.attr.compiler_flags_select or {
            "//conditions:default": [],
        },
    )
    locale_archive = repository_ctx.attr.locale_archive
    nixpkgs_ghc_path = repository_ctx.path(repository_ctx.attr._nixpkgs_ghc).dirname.dirname

    # Symlink content of ghc external repo. In effect, this repo has
    # the same content, but with a BUILD file that includes generated
    # content (not a static one like nixpkgs_package supports).
    for target in _find_children(repository_ctx, nixpkgs_ghc_path):
        basename = target.rpartition("/")[-1]
        repository_ctx.symlink(target, basename)

    # Generate BUILD file entries describing each prebuilt package.
    pkgdb_to_bzl = repository_ctx.path(Label("@io_tweag_rules_haskell//haskell:private/pkgdb_to_bzl.py"))
    result = repository_ctx.execute([
        pkgdb_to_bzl,
        repository_ctx.attr.name,
        "lib/ghc-{}".format(repository_ctx.attr.version),
    ])
    if result.return_code:
        fail("Error executing pkgdb_to_bzl.py: {stderr}".format(stderr = result.stderr))
    toolchain_libraries = result.stdout

    # Haddock files on nixpkgs are stored outside of the ghc package
    # The pkgdb_to_bzl.py program generates bazel labels for theses files
    # and asks the parent process to generate the associated bazel symlink
    for line in result.stdout.split("\n"):
        if line.startswith("#SYMLINK:"):
            _, name, path = line.split(" ")
            repository_ctx.symlink(path, name)

    repository_ctx.file(
        "BUILD",
        executable = False,
        content = """
load(
    "@io_tweag_rules_haskell//haskell:haskell.bzl",
    "haskell_import",
    "haskell_toolchain",
)

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "bin",
    srcs = glob(["bin/*"]),
)

{toolchain_libraries}

haskell_toolchain(
    name = "toolchain-impl",
    tools = {tools},
    libraries = toolchain_libraries,
    version = "{version}",
    is_static = {is_static},
    compiler_flags = {compiler_flags} + {compiler_flags_select},
    haddock_flags = {haddock_flags},
    repl_ghci_args = {repl_ghci_args},
    # On Darwin we don't need a locale archive. It's a Linux-specific
    # hack in Nixpkgs.
    {locale_archive_arg}
    locale = {locale},
)
        """.format(
            toolchain_libraries = toolchain_libraries,
            tools = ["@io_tweag_rules_haskell_ghc_nixpkgs//:bin"],
            version = repository_ctx.attr.version,
            is_static = ghc_is_static(repository_ctx),
            compiler_flags = repository_ctx.attr.compiler_flags,
            compiler_flags_select = compiler_flags_select,
            haddock_flags = repository_ctx.attr.haddock_flags,
            repl_ghci_args = repository_ctx.attr.repl_ghci_args,
            locale_archive_arg = "locale_archive = {},".format(repr(locale_archive)) if locale_archive else "",
            locale = repr(repository_ctx.attr.locale),
        ),
    )

_ghc_nixpkgs_haskell_toolchain = repository_rule(
    _ghc_nixpkgs_haskell_toolchain_impl,
    attrs = {
        # These attributes just forward to haskell_toolchain.
        # They are documented there.
        "version": attr.string(),
        "compiler_flags": attr.string_list(),
        "compiler_flags_select": attr.string_list_dict(),
        "haddock_flags": attr.string_list(),
        "repl_ghci_args": attr.string_list(),
        "locale_archive": attr.string(),
        # Unfortunately, repositories cannot depend on each other
        # directly. They can only depend on files inside each
        # repository. We need to be careful to depend on files that
        # change anytime any content in a repository changes, like
        # bin/ghc, which embeds the output path, which itself changes
        # if any input to the derivation changed.
        "_nixpkgs_ghc": attr.label(default = "@io_tweag_rules_haskell_ghc_nixpkgs//:bin/ghc"),
        "locale": attr.string(
            default = "en_US.UTF-8",
        ),
    },
)

def _ghc_nixpkgs_toolchain_impl(repository_ctx):
    # These constraints might look tautological, because they always
    # match the host platform if it is the same as the target
    # platform. But they are important to state because Bazel
    # toolchain resolution prefers other toolchains with more specific
    # constraints otherwise.
    target_constraints = ["@bazel_tools//platforms:x86_64"]
    if repository_ctx.os.name == "linux":
        target_constraints.append("@bazel_tools//platforms:linux")
    elif repository_ctx.os.name == "mac os x":
        target_constraints.append("@bazel_tools//platforms:osx")
    exec_constraints = list(target_constraints)
    exec_constraints.append("@io_tweag_rules_haskell//haskell/platforms:nixpkgs")

    repository_ctx.file(
        "BUILD",
        executable = False,
        content = """
toolchain(
    name = "toolchain",
    toolchain_type = "@io_tweag_rules_haskell//haskell:toolchain",
    toolchain = "@io_tweag_rules_haskell_ghc_nixpkgs_haskell_toolchain//:toolchain-impl",
    exec_compatible_with = {exec_constraints},
    target_compatible_with = {target_constraints},
)
        """.format(
            exec_constraints = exec_constraints,
            target_constraints = target_constraints,
        ),
    )

_ghc_nixpkgs_toolchain = repository_rule(_ghc_nixpkgs_toolchain_impl)

def haskell_register_ghc_nixpkgs(
        version,
        build_file = None,
        build_file_content = None,
        compiler_flags = None,
        compiler_flags_select = None,
        haddock_flags = None,
        repl_ghci_args = None,
        locale_archive = None,
        attribute_path = "haskellPackages.ghc",
        nix_file = None,
        nix_file_deps = [],
        locale = None,
        repositories = {},
        nix_file_content = ""):
    """Register a package from Nixpkgs as a toolchain.

    Toolchains can be used to compile Haskell code. To have this
    toolchain selected during [toolchain
    resolution][toolchain-resolution], set a host platform that
    includes the `@io_tweag_rules_haskell//haskell/platforms:nixpkgs`
    constraint value.

    [toolchain-resolution]: https://docs.bazel.build/versions/master/toolchains.html#toolchain-resolution

    Example:

      ```
      haskell_register_ghc_nixpkgs(
          locale_archive = "@glibc_locales//:locale-archive",
          atttribute_path = "haskellPackages.ghc",
          version = "1.2.3",   # The version of GHC
      )
      ```

      Setting the host platform can be done on the command-line like
      in the following:

      ```
      --host_platform=@io_tweag_rules_haskell//haskell/platforms:linux_x86_64_nixpkgs
      ```

    """
    nixpkgs_ghc_repo_name = "io_tweag_rules_haskell_ghc_nixpkgs"
    haskell_toolchain_repo_name = "io_tweag_rules_haskell_ghc_nixpkgs_haskell_toolchain"
    toolchain_repo_name = "io_tweag_rules_haskell_ghc_nixpkgs_toolchain"

    # The package from the system.
    nixpkgs_package(
        name = nixpkgs_ghc_repo_name,
        attribute_path = attribute_path,
        build_file = build_file,
        build_file_content = build_file_content,
        nix_file = nix_file,
        nix_file_deps = nix_file_deps,
        nix_file_content = nix_file_content,
        repositories = repositories,
    )

    # haskell_toolchain + haskell_import definitions.
    _ghc_nixpkgs_haskell_toolchain(
        name = haskell_toolchain_repo_name,
        version = version,
        compiler_flags = compiler_flags,
        compiler_flags_select = compiler_flags_select,
        haddock_flags = haddock_flags,
        repl_ghci_args = repl_ghci_args,
        locale_archive = locale_archive,
        locale = locale,
    )

    # toolchain definition.
    _ghc_nixpkgs_toolchain(name = toolchain_repo_name)
    native.register_toolchains("@{}//:toolchain".format(toolchain_repo_name))

def _find_children(repository_ctx, target_dir):
    find_args = [
        "find",
        "-L",
        target_dir,
        "-maxdepth",
        "1",
        # otherwise the directory is printed as well
        "-mindepth",
        "1",
        # filenames can contain \n
        "-print0",
    ]
    exec_result = repository_ctx.execute(find_args)
    if exec_result.return_code:
        fail("_find_children() failed.")
    return exec_result.stdout.rstrip("\0").split("\0")
