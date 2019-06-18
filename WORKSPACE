workspace(name = "io_tweag_rules_haskell")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@io_tweag_rules_haskell//haskell:repositories.bzl", "haskell_repositories")

# Subrepositories of rules_haskell

# various examples
local_repository(
    name = "io_tweag_rules_haskell_examples",
    path = "examples",
)

# code for the tutorial
local_repository(
    name = "io_tweag_rules_haskell_tutorial",
    path = "tutorial",
)

# hazel, a way to generate bazel libraries from [st/h]ackage
local_repository(
    name = "ai_formation_hazel",
    path = "hazel",
)

# Some helpers for platform-dependent configuration
load("//tools:os_info.bzl", "os_info")

os_info(name = "os_info")

load("@os_info//:os_info.bzl", "is_linux", "is_windows")

# bazel dependencies
haskell_repositories()

http_archive(
    name = "happy",
    build_file_content = """
load("@io_tweag_rules_haskell//haskell:cabal.bzl", "haskell_cabal_binary")
haskell_cabal_binary(name = "happy", srcs = glob(["**"]), visibility = ["//visibility:public"])
    """,
    sha256 = "22eb606c97105b396e1c7dc27e120ca02025a87f3e44d2ea52be6a653a52caed",
    strip_prefix = "happy-1.19.10",
    urls = ["http://hackage.haskell.org/package/happy-1.19.10/happy-1.19.10.tar.gz"],
)

load("@io_tweag_rules_haskell//haskell:cabal.bzl", "stack_snapshot")

stack_snapshot(
    name = "stackage",
    packages = [
        # Core libraries
        "array",
        "base",
        "directory",
        "filepath",
        "process",
        # For tests
        "streaming",
        "void",
        "hspec",
        "hspec-core",
        "lens-family-core",
        "data-default-class",
        "lens-labels",
        "proto-lens",
        "lens-family",
    ],
    snapshot = "lts-13.15",
    tools = ["@happy"],
    deps = ["@zlib.dev//:zlib"],
)

rules_nixpkgs_version = "0.5.2"

rules_nixpkgs_version_is_hash = False

rules_nixpkgs_sha256 = "5a384daa57b49abf9f0b672852f1a66a3c52aecf9d4d2ac64f6de0fd307690c8"

http_archive(
    name = "io_tweag_rules_nixpkgs",
    sha256 = rules_nixpkgs_sha256,
    strip_prefix = "rules_nixpkgs-%s" % rules_nixpkgs_version,
    urls = ["https://github.com/tweag/rules_nixpkgs/archive/%s.tar.gz" % rules_nixpkgs_version] if rules_nixpkgs_version_is_hash else ["https://github.com/tweag/rules_nixpkgs/archive/v%s.tar.gz" % rules_nixpkgs_version],
)

load(
    "@io_tweag_rules_nixpkgs//nixpkgs:nixpkgs.bzl",
    "nixpkgs_cc_configure",
    "nixpkgs_local_repository",
    "nixpkgs_package",
)

nixpkgs_package(
    name = "ghc",
    repository = "@nixpkgs",
)

http_archive(
    name = "com_google_protobuf",
    sha256 = "73fdad358857e120fd0fa19e071a96e15c0f23bb25f85d3f7009abfd4f264a2a",
    strip_prefix = "protobuf-3.6.1.3",
    urls = ["https://github.com/google/protobuf/archive/v3.6.1.3.tar.gz"],
)

nixpkgs_local_repository(
    name = "nixpkgs",
    nix_file = "//nixpkgs:default.nix",
)

test_compiler_flags = [
    "-XStandaloneDeriving",  # Flag used at compile time
    "-threaded",  # Flag used at link time

    # Used by `tests/repl-flags`
    "-DTESTS_TOOLCHAIN_COMPILER_FLAGS",
    # this is the default, so it does not harm other tests
    "-XNoOverloadedStrings",
]

test_haddock_flags = ["-U"]

test_repl_ghci_args = [
    # The repl test will need this flag, but set by the local
    # `repl_ghci_args`.
    "-UTESTS_TOOLCHAIN_REPL_FLAGS",
    # The repl test will need OverloadedString
    "-XOverloadedStrings",
]

load(
    "@io_tweag_rules_haskell//:constants.bzl",
    "test_ghc_version",
)
load(
    "@io_tweag_rules_haskell//haskell:nixpkgs.bzl",
    "haskell_register_ghc_nixpkgs",
)

haskell_register_ghc_nixpkgs(
    attribute_path = "ghc",
    compiler_flags = test_compiler_flags,
    haddock_flags = test_haddock_flags,
    locale_archive = "@glibc_locales//:locale-archive",
    repl_ghci_args = test_repl_ghci_args,
    repositories = {"nixpkgs": "@nixpkgs"},
    version = test_ghc_version,
)

load(
    "@io_tweag_rules_haskell//haskell:haskell.bzl",
    "haskell_register_ghc_bindists",
)

haskell_register_ghc_bindists(
    compiler_flags = test_compiler_flags,
    version = test_ghc_version,
)

register_toolchains(
    "//tests:c2hs-toolchain",
    "//tests:doctest-toolchain",
    "//tests:hlint-toolchain",
    "//tests:protobuf-toolchain",
)

nixpkgs_cc_configure(
    nix_file = "//nixpkgs:cc-toolchain.nix",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "zlib",
    build_file_content = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "lib",
    srcs = glob(["lib/**/*.so*", "lib/**/*.dylib", "lib/**/*.a"]),
)

cc_library(
    name = "zlib",
    linkstatic = 1,
    srcs = [":lib"],
)
""",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "c2hs",
    attribute_path = "haskellPackages.c2hs",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "doctest",
    attribute_path = "haskellPackages.doctest",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "hlint",
    attribute_path = "hlint",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "proto-lens-protoc",
    attribute_path = "haskellPackages.proto-lens-protoc",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "sphinx",
    attribute_path = "python36Packages.sphinx",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "graphviz",
    attribute_path = "graphviz",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "zip",
    attribute_path = "zip",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "zlib.dev",
    build_file_content = """
package(default_visibility = ["//visibility:public"])

filegroup (
    name = "include",
    srcs = glob(["include/*.h"]),
)

cc_library(
    name = "zlib",
    deps = ["@zlib//:zlib"],
    hdrs = [":include"],
    strip_include_prefix = "include",
)
""",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "glibc_locales",
    attribute_path = "glibcLocales",
    build_file_content = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "locale-archive",
    srcs = ["lib/locale/locale-archive"],
)
""",
    repository = "@nixpkgs",
)

load("@bazel_tools//tools/build_defs/repo:jvm.bzl", "jvm_maven_import_external")

jvm_maven_import_external(
    name = "org_apache_spark_spark_core_2_10",
    artifact = "org.apache.spark:spark-core_2.10:1.6.0",
    artifact_sha256 = "28aad0602a5eea97e9cfed3a7c5f2934cd5afefdb7f7c1d871bb07985453ea6e",
    licenses = ["notice"],
    server_urls = ["http://central.maven.org/maven2"],
)

# c2hs rule in its own repository
local_repository(
    name = "c2hs_repo",
    path = "tests/c2hs/repo",
)

load(
    "@io_tweag_rules_haskell//tests/external-haskell-repository:workspace_dummy.bzl",
    "haskell_package_repository_dummy",
)

# dummy repo for the external haskell repo test (hazel)
haskell_package_repository_dummy(
    name = "haskell_package_repository_dummy",
)

# For Skydoc

nixpkgs_package(
    name = "nixpkgs_nodejs",
    # XXX Indirection derivation to make all of NodeJS rooted in
    # a single directory. We shouldn't need this, but it's
    # a workaround for
    # https://github.com/bazelbuild/bazel/issues/2927.
    nix_file_content = """
    with import <nixpkgs> { config = {}; overlays = []; };
    runCommand "nodejs-rules_haskell" { buildInputs = [ nodejs ]; } ''
      mkdir -p $out/nixpkgs_nodejs
      cd $out/nixpkgs_nodejs
      for i in ${nodejs}/*; do ln -s $i; done
      ''
    """,
    nixopts = [
        "--option",
        "sandbox",
        "false",
    ],
    repository = "@nixpkgs",
)

http_archive(
    name = "build_bazel_rules_nodejs",
    sha256 = "f79f605a920145216e64991d6eff4e23babc48810a9efd63a31744bb6637b01e",
    strip_prefix = "rules_nodejs-b4dad57d2ecc63d74db1f5523593639a635e447d",
    # Tip of https://github.com/bazelbuild/rules_nodejs/pull/471.
    urls = ["https://github.com/mboes/rules_nodejs/archive/b4dad57d2ecc63d74db1f5523593639a635e447d.tar.gz"],
)

http_archive(
    name = "io_bazel_rules_sass",
    sha256 = "1e135452dc627f52eab39a50f4d5b8d13e8ed66cba2e6da56ac4cbdbd776536c",
    strip_prefix = "rules_sass-1.15.2",
    urls = ["https://github.com/bazelbuild/rules_sass/archive/1.15.2.tar.gz"],
)

load("@io_bazel_rules_sass//:package.bzl", "rules_sass_dependencies")

rules_sass_dependencies()

load("@io_bazel_rules_sass//:defs.bzl", "sass_repositories")

sass_repositories()

load("@build_bazel_rules_nodejs//:defs.bzl", "node_repositories")

node_repositories(
    vendored_node = "@nixpkgs_nodejs",
)

http_archive(
    name = "io_bazel_skydoc",
    sha256 = "19eb6c162075707df5703c274d3348127625873dbfa5ff83b1ef4b8f5dbaa449",
    strip_prefix = "skydoc-0.2.0",
    urls = ["https://github.com/bazelbuild/skydoc/archive/0.2.0.tar.gz"],
)

load("@io_bazel_skydoc//:setup.bzl", "skydoc_repositories")

skydoc_repositories()

# For buildifier

http_archive(
    name = "io_bazel_rules_go",
    sha256 = "8be57ff66da79d9e4bd434c860dce589195b9101b2c187d144014bbca23b5166",
    strip_prefix = "rules_go-0.16.3",
    urls = ["https://github.com/bazelbuild/rules_go/archive/0.16.3.tar.gz"],
)

http_archive(
    name = "com_github_bazelbuild_buildtools",
    sha256 = "0a0920151acf18c51866331944d12db9023707a6861e78225366f5711efc845b",
    strip_prefix = "buildtools-0.25.1",
    urls = ["https://github.com/bazelbuild/buildtools/archive/0.25.1.tar.gz"],
)

# A repository that generates the Go SDK imports, see ./tools/go_sdk/README
local_repository(
    name = "go_sdk_repo",
    path = "tools/go_sdk",
)

load(
    "@io_bazel_rules_go//go:def.bzl",
    "go_register_toolchains",
    "go_rules_dependencies",
)

go_rules_dependencies()

# If Windows, ask Bazel to download a Go SDK. Otherwise use the nix-shell
# provided GO SDK.
go_register_toolchains() if is_windows else go_register_toolchains(go_version = "host")

load("@com_github_bazelbuild_buildtools//buildifier:deps.bzl", "buildifier_dependencies")

buildifier_dependencies()

# Hazel

load("@ai_formation_hazel//:workspace.bzl", "hazel_setup")

hazel_setup()
