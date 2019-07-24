def _demo_rule_impl(ctx):
    prev = None
    for i in range(1, 10):
        curr = ctx.actions.declare_file(ctx.label.name + "-" + str(i))
        ctx.actions.run(
            executable = ctx.executable._demo,
            inputs = [prev] if prev else [],
            outputs = [curr],
            arguments = [curr.path, str(i)],
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
