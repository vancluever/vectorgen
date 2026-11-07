# vectorgen - z2d Serialization Suite

This is a simple set of libraries and CLI tools that can create serializations
for [z2d](https://github.com/vancluever/z2d) paths.

It's mainly focused on exporting text, but there are are also functions for
generating serializations for paths as well.

Functions exist for serialization representations as Zig structs, and also as
`.zon` files, which can then be `@import`ed straight into projects that need
them.

## CLI use

There are two main commands:

* `text2vec` - This can be used to convert a text string to a `.zon`
  representation.
* `reserialize` - Can be used to convert a straight (non-`.zon`) serialization
  to a `.zon` representation.

To build these, simply download the repository and run `zig build`.

For command usage details, run each command with `-help`.

## Library use

First, fetch the library in the project that you wish to use it in.

```
zig fetch --save https://github.com/vancluever/vectorgen/archive/COMMIT.tar.gz
```

When using the library, you have two options:

### Default use

In your `build.zig`:

```zig
const vectorgen_dep = b.dependency("vectorgen", .{});
your_module.addImport(vectorgen_dep, vectorgen_dep.dependency("vectorgen"));
```

This will load vectorgen with its in-use z2d dependency and the default
floating-point precision of `.single`.

### Bring-your-own z2d dependency

Note that the above approach can cause conflicts if you are using the same
version of z2d that vectorgen is currently using. To get around this, provide
your own dependency:

```zig
const vectorgen_dep = b.dependency("vectorgen", .{ .skip_deps = true });
const vectorgen_mod = vectorgen_dep.module("vectorgen"));
const z2d_dep = b.dependency("z2d", .{ ... });
const z2d_mod = z2d_dep.module("z2d");
vectorgen_mod.addImport("z2d", z2d_mod);
your_module.addImport("vectorgen", vectorgen_mod);
your_module.addImport("z2d", z2d_mod);
```

This will also allow you to control other z2d options (e.g., setting
`.float_precision` to `.double` if you need better floating-point precision.

### API reference

The entirety of the library is in [`src/vectorgen.zig`](src/vectorgen.zig).

## License

This project is licensed MPL 2.0. See LICENSE for a copy of the MPL.
