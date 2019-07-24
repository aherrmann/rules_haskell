def _demo_rule_impl(ctx):
    prev = None
    for i in range(1, 10):
        curr = ctx.actions.declare_file(ctx.label.name + "-" + str(i))
        tools, manifest = ctx.resolve_tools(tools = [ctx.attr._demo])
        ctx.actions.run_shell(
            command = """
            for j in `seq 1 10`; do
                $1 $2 $3$j
            done
            """,
            inputs = [prev] if prev else [],
            input_manifests = manifest,
            outputs = [curr],
            tools = tools,
            arguments = [ctx.executable._demo.path, curr.path, str(i)],
        )
        prev = curr
    return [DefaultInfo(
        files = depset(direct = [prev]),
    )]

demo_rule = rule(
    implementation = _demo_rule_impl,
    attrs = {
        "_demo": attr.label(
            default = Label("//:demo"),
            executable = True,
            cfg = "host",
        ),
    },
)
