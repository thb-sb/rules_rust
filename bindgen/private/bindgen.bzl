# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rust Bindgen rules"""

load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
)
load("@rules_cc//cc:defs.bzl", "CcInfo")
load("//rust:defs.bzl", "rust_library")
load("//rust:rust_common.bzl", "BuildInfo")

# buildifier: disable=bzl-visibility
load("//rust/private:rustc.bzl", "get_linker_and_args")

# buildifier: disable=bzl-visibility
load("//rust/private:utils.bzl", "find_cc_toolchain", "get_lib_name_default", "get_preferred_artifact")

# TODO(hlopko): use the more robust logic from rustc.bzl also here, through a reasonable API.
def _get_libs_for_static_executable(dep):
    """find the libraries used for linking a static executable.

    Args:
        dep (Target): A cc_library target.

    Returns:
        depset: A depset[File]
    """
    linker_inputs = dep[CcInfo].linking_context.linker_inputs.to_list()
    return depset([get_preferred_artifact(lib, use_pic = False) for li in linker_inputs for lib in li.libraries])

def rust_bindgen_library(
        name,
        header,
        cc_lib,
        bindgen_flags = None,
        bindgen_features = None,
        clang_flags = None,
        **kwargs):
    """Generates a rust source file for `header`, and builds a rust_library.

    Arguments are the same as `rust_bindgen`, and `kwargs` are passed directly to rust_library.

    Args:
        name (str): A unique name for this target.
        header (str): The label of the .h file to generate bindings for.
        cc_lib (str): The label of the cc_library that contains the .h file. This is used to find the transitive includes.
        bindgen_flags (list, optional): Flags to pass directly to the bindgen executable. See https://rust-lang.github.io/rust-bindgen/ for details.
        bindgen_features (list, optional): The `features` attribute for the `rust_bindgen` target.
        clang_flags (list, optional): Flags to pass directly to the clang executable.
        **kwargs: Arguments to forward to the underlying `rust_library` rule.
    """

    tags = kwargs.get("tags") or []
    if "tags" in kwargs:
        kwargs.pop("tags")

    sub_tags = tags + ([] if "manual" in tags else ["manual"])

    bindgen_kwargs = {}
    for shared in (
        "target_compatible_with",
        "exec_compatible_with",
    ):
        if shared in kwargs:
            bindgen_kwargs.update({shared: kwargs[shared]})

    rust_bindgen(
        name = name + "__bindgen",
        header = header,
        cc_lib = cc_lib,
        bindgen_flags = bindgen_flags or [],
        features = bindgen_features,
        clang_flags = clang_flags or [],
        tags = sub_tags,
        **bindgen_kwargs
    )

    tags = depset(tags + ["__bindgen", "no-clippy", "no-rustfmt"]).to_list()

    deps = kwargs.get("deps") or []
    if "deps" in kwargs:
        kwargs.pop("deps")

    rust_library(
        name = name,
        srcs = [name + "__bindgen.rs"],
        deps = deps + [name + "__bindgen"],
        tags = tags,
        **kwargs
    )

def _get_user_link_flags(cc_lib):
    linker_flags = []

    for linker_input in cc_lib[CcInfo].linking_context.linker_inputs.to_list():
        linker_flags.extend(linker_input.user_link_flags)

    return linker_flags

def _generate_cc_link_build_info(ctx, cc_lib):
    """Produce the eqivilant cargo_build_script providers for use in linking the library.

    Args:
        ctx (ctx): The rule's context object
        cc_lib (Target): The `rust_bindgen.cc_lib` target.

    Returns:
        The `BuildInfo` provider.
    """
    compile_data = []

    rustc_flags = []
    linker_search_paths = []

    for linker_input in cc_lib[CcInfo].linking_context.linker_inputs.to_list():
        for lib in linker_input.libraries:
            if lib.static_library:
                rustc_flags.append("-lstatic={}".format(get_lib_name_default(lib.static_library)))
                linker_search_paths.append(lib.static_library.dirname)
                compile_data.append(lib.static_library)
            elif lib.pic_static_library:
                rustc_flags.append("-lstatic={}".format(get_lib_name_default(lib.pic_static_library)))
                linker_search_paths.append(lib.pic_static_library.dirname)
                compile_data.append(lib.pic_static_library)

    if not compile_data:
        fail("No static libraries found in {}".format(
            cc_lib.label,
        ))

    rustc_flags_file = ctx.actions.declare_file("{}.rustc_flags".format(ctx.label.name))
    ctx.actions.write(
        output = rustc_flags_file,
        content = "\n".join(rustc_flags),
    )

    link_search_paths = ctx.actions.declare_file("{}.link_search_paths".format(ctx.label.name))
    ctx.actions.write(
        output = link_search_paths,
        content = "\n".join([
            "-Lnative=${{pwd}}/{}".format(path)
            for path in depset(linker_search_paths).to_list()
        ]),
    )

    return BuildInfo(
        compile_data = depset(compile_data),
        dep_env = None,
        flags = rustc_flags_file,
        # linker_flags is provided via CcInfo
        linker_flags = None,
        link_search_paths = link_search_paths,
        out_dir = None,
        rustc_env = None,
    )

def _rust_bindgen_impl(ctx):
    # nb. We can't grab the cc_library`s direct headers, so a header must be provided.
    cc_lib = ctx.attr.cc_lib
    header = ctx.file.header
    cc_header_list = ctx.attr.cc_lib[CcInfo].compilation_context.headers.to_list()
    if header not in cc_header_list:
        fail("Header {} is not in {}'s transitive headers.".format(ctx.attr.header, cc_lib), "header")

    toolchain = ctx.toolchains[Label("//bindgen:toolchain_type")]
    bindgen_bin = toolchain.bindgen
    clang_bin = toolchain.clang
    libclang = toolchain.libclang
    libstdcxx = toolchain.libstdcxx

    output = ctx.outputs.out

    cc_toolchain, feature_configuration = find_cc_toolchain(ctx = ctx)

    tools = depset([clang_bin], transitive = [cc_toolchain.all_files])

    # libclang should only have 1 output file
    libclang_dir = _get_libs_for_static_executable(libclang).to_list()[0].dirname

    env = {
        "CLANG_PATH": clang_bin.path,
        "LIBCLANG_PATH": libclang_dir,
        "RUST_BACKTRACE": "1",
    }

    args = ctx.actions.args()

    executable = bindgen_bin

    # When running on darwin, we have to forward the SDKROOT environment variable,
    # otherwise some system include files may not be found if the clang compiled
    # from source is being used.
    # Since the sdk directory given by the apple toolchain[1] may be a dummy
    # variable, we have to use the process_wrapper.
    #
    # [1]: https://bazel.build/rules/lib/builtins/apple_toolchain.html#sdk_dir
    if apple_common != None:
        args.add_all(["--subst", "SDKROOT=${SDKROOT}"])
        args.add_all(["--subst", "DEVELOPER_DIR=${DEVELOPER_DIR}"])
        args.add_all(["--", bindgen_bin])
        tools = depset([bindgen_bin], transitive = [tools])
        executable = ctx.executable._process_wrapper

    # Configure Bindgen Arguments
    args.add_all(ctx.attr.bindgen_flags)
    args.add(header)
    args.add("--output", output)

    # Vanilla usage of bindgen produces formatted output, here we do the same if we have `rustfmt` in our toolchain.
    rustfmt_toolchain = ctx.toolchains[Label("//rust/rustfmt:toolchain_type")]
    if toolchain.default_rustfmt:
        # Bindgen is able to find rustfmt using the RUSTFMT environment variable
        env.update({"RUSTFMT": rustfmt_toolchain.rustfmt.path})
        tools = depset(transitive = [tools, rustfmt_toolchain.all_files])
    else:
        args.add("--no-rustfmt-bindings")

    # Configure Clang Arguments
    args.add("--")

    compile_variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        include_directories = cc_lib[CcInfo].compilation_context.includes,
        quote_include_directories = cc_lib[CcInfo].compilation_context.quote_includes,
        system_include_directories = cc_lib[CcInfo].compilation_context.system_includes,
        user_compile_flags = ctx.attr.clang_flags,
    )
    compile_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_COMPILE_ACTION_NAME,
        variables = compile_variables,
    )

    # Bindgen forcibly uses clang.
    # It's possible that the selected cc_toolchain isn't clang, and may specify flags which clang doesn't recognise.
    # Ideally we could depend on a more specific toolchain, requesting one which is specifically clang via some constraint.
    # Unfortunately, we can't currently rely on this, so instead we filter only to flags we know clang supports.
    # We can add extra flags here as needed.
    flags_known_to_clang = ("-I", "-iquote", "-isystem", "--sysroot", "--gcc-toolchain")
    open_arg = False
    for arg in compile_flags:
        if open_arg:
            args.add(arg)
            open_arg = False
            continue

        # The cc_toolchain merged these flags into its returned flags - don't strip these out.
        if arg in ctx.attr.clang_flags:
            args.add(arg)
            continue

        if not arg.startswith(flags_known_to_clang):
            continue

        args.add(arg)

        if arg in flags_known_to_clang:
            open_arg = True
            continue

    _, _, linker_env = get_linker_and_args(ctx, ctx.attr, "bin", cc_toolchain, feature_configuration, None)
    env.update(**linker_env)

    # Set the dynamic linker search path so that clang uses the libstdcxx from the toolchain.
    # DYLD_LIBRARY_PATH is LD_LIBRARY_PATH on macOS.
    if libstdcxx:
        env["LD_LIBRARY_PATH"] = ":".join([f.dirname for f in _get_libs_for_static_executable(libstdcxx).to_list()])
        env["DYLD_LIBRARY_PATH"] = env["LD_LIBRARY_PATH"]

    ctx.actions.run(
        executable = executable,
        inputs = depset(
            [header],
            transitive = [
                cc_lib[CcInfo].compilation_context.headers,
                _get_libs_for_static_executable(libclang),
            ] + ([
                _get_libs_for_static_executable(libstdcxx),
            ] if libstdcxx else []),
        ),
        outputs = [output],
        mnemonic = "RustBindgen",
        progress_message = "Generating bindings for {}..".format(header.path),
        env = env,
        arguments = [args],
        tools = tools,
    )

    return [
        _generate_cc_link_build_info(ctx, cc_lib),
        # As in https://github.com/bazelbuild/rules_rust/pull/2361, we want
        # to link cc_lib to the direct parent (rlib) using `-lstatic=<cc_lib>`
        # rustc flag. Hence, we do not need to provide the whole CcInfo of
        # cc_lib because it will cause the downstream binary to link the cc_lib
        # again. The CcInfo here only contains the custom link flags (i.e.
        # linkopts attribute) specified by users in cc_lib.
        CcInfo(
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([cc_common.create_linker_input(
                    owner = ctx.label,
                    user_link_flags = _get_user_link_flags(cc_lib),
                )]),
            ),
        ),
        OutputGroupInfo(
            bindgen_bindings = depset([output]),
        ),
    ]

rust_bindgen = rule(
    doc = "Generates a rust source file from a cc_library and a header.",
    implementation = _rust_bindgen_impl,
    attrs = {
        "bindgen_flags": attr.string_list(
            doc = "Flags to pass directly to the bindgen executable. See https://rust-lang.github.io/rust-bindgen/ for details.",
        ),
        "cc_lib": attr.label(
            doc = "The cc_library that contains the `.h` file. This is used to find the transitive includes.",
            providers = [CcInfo],
            mandatory = True,
        ),
        "clang_flags": attr.string_list(
            doc = "Flags to pass directly to the clang executable.",
        ),
        "header": attr.label(
            doc = "The `.h` file to generate bindings for.",
            allow_single_file = True,
            mandatory = True,
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "_process_wrapper": attr.label(
            default = Label("//util/process_wrapper"),
            executable = True,
            allow_single_file = True,
            cfg = "exec",
        ),
    },
    outputs = {"out": "%{name}.rs"},
    fragments = ["cpp"],
    toolchains = [
        str(Label("//bindgen:toolchain_type")),
        str(Label("//rust:toolchain_type")),
        str(Label("//rust/rustfmt:toolchain_type")),
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
)

def _rust_bindgen_toolchain_impl(ctx):
    return platform_common.ToolchainInfo(
        bindgen = ctx.executable.bindgen,
        clang = ctx.executable.clang,
        libclang = ctx.attr.libclang,
        libstdcxx = ctx.attr.libstdcxx,
        default_rustfmt = ctx.attr.default_rustfmt,
    )

rust_bindgen_toolchain = rule(
    _rust_bindgen_toolchain_impl,
    doc = """\
The tools required for the `rust_bindgen` rule.

This rule depends on the [`bindgen`](https://crates.io/crates/bindgen) binary crate, and it
in turn depends on both a clang binary and the clang library. To obtain these dependencies,
`rust_bindgen_dependencies` imports bindgen and its dependencies.

```python
load("@rules_rust//bindgen:defs.bzl", "rust_bindgen_toolchain")

rust_bindgen_toolchain(
    name = "bindgen_toolchain_impl",
    bindgen = "//my/rust:bindgen",
    clang = "//my/clang:clang",
    libclang = "//my/clang:libclang.so",
    libstdcxx = "//my/cpp:libstdc++",
)

toolchain(
    name = "bindgen_toolchain",
    toolchain = "bindgen_toolchain_impl",
    toolchain_type = "@rules_rust//bindgen:toolchain_type",
)
```

This toolchain will then need to be registered in the current `WORKSPACE`.
For additional information, see the [Bazel toolchains documentation](https://docs.bazel.build/versions/master/toolchains.html).
""",
    attrs = {
        "bindgen": attr.label(
            doc = "The label of a `bindgen` executable.",
            executable = True,
            cfg = "exec",
        ),
        "clang": attr.label(
            doc = "The label of a `clang` executable.",
            executable = True,
            cfg = "exec",
            allow_files = True,
        ),
        "default_rustfmt": attr.bool(
            doc = "If set, `rust_bindgen` targets will always format generated sources with `rustfmt`.",
            mandatory = False,
            default = True,
        ),
        "libclang": attr.label(
            doc = "A cc_library that provides bindgen's runtime dependency on libclang.",
            cfg = "exec",
            providers = [CcInfo],
            allow_files = True,
        ),
        "libstdcxx": attr.label(
            doc = "A cc_library that satisfies libclang's libstdc++ dependency. This is used to make the execution of clang hermetic. If None, system libraries will be used instead.",
            cfg = "exec",
            providers = [CcInfo],
            mandatory = False,
            allow_files = True,
        ),
    },
)
