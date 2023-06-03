---
title: Developing Nix Libraries with Subflakes
date: 2023-06-06
---

A library usually consists of two parts:
the implementation, which implements the public interface people are able to use,
and development, which can be anything from testing to deployment.

It is very common for the development part to have its own dependencies
in addition to what the implementation part requires, things like testing frameworks and formatters.

## The Problem

Some package managers allow users to specify development-only dependencies,
for example, Cargo (Rust's package manager) supports this with the `dev-dependencies` table:

```toml
[dependencies]
serde = "1" # this is for the implementation

[dev-dependencies]
insta = "1" # this is for development only
```

Something like this has been [proposed](https://github.com/nixos/nix/issues/6124) for Nix flakes,
but it is unsupported due to limitations of the flake schema:

> [We cannot have dev-only inputs without dev-only outputs \[...\] we would need a `devOutputs` function in addition to `outputs`](https://github.com/nixos/nix/issues/6124#issuecomment-1046726191)

Unlike traditional programming languages, Nix is almost designed for development.
While Cargo's `dev-dependencies` is usually only used for testing.
Nix is able to do a lot more:
[testing][namaka],
[formatting][treefmt-nix],
[linting][craneLib.cargoClippy],
[git hooks][pre-commit-hooks.nix],
[containers][arion],
[MicroVMs][microvm.nix]...
There are even [frameworks][std] to help unify all these tools,
just because there are so many of them, not to mention
[all][flake-utils]
[the][flake-utils-plus]
[Nix][flake-parts]
[libraries][haumea]
just to help you write Nix.

For Nix, there can be a lot more dependencies for development, or in Nix terms, flake inputs,
but no way to make them development-only without any workarounds.

## Subflakes

Subflakes is a rather undocumented pattern of Nix flakes.
By having a separate flake in a subdirectory, the subflake is able to access its
parent directory's contents with `../.`[<sup>\*</sup>](#drawbacks).

We can put the development-only flake inputs in the subflake,
and dependent flakes will not get these dependencies in their `flake.lock`.

There is one issue - using `../.` only gives you a path, but not the flake contents.
In the subflake, you can add the parent flake as a flake input:

```nix
inputs.parent.url = "../.";`,
```

But by doing that, every time anything changes, the subflake's `flake.lock` would be updated,
which is not very ideal, and `builtins.getFlake` doesn't work for a similar reason.

There are things [proposed](https://github.com/nixos/nix/issues/3978) to fix this, but for now we have to work around it,
and yes I am suggesting workarounds for a workaround, but this is what worked the best for me.

The solution is to "reimplement" the flakes logic in Nix (the language).
There are existing libraries that do this, so you don't have to implement it yourself:

- [call-flake]
- [get-flake]
- [flake-compat] (and a maintained [fork][flake-compat-fork]) might also work depending on your use case

## Example

I will be using [call-flake] here for demonstration since it just copies from upstream Nix,
together with [namaka] for testing and [flake-parts] to make my life easier.
[get-flake] should work just as well, and you don't need either namaka or flake-parts.

Let's start by creating a git repository and a simple `flake.nix`:

```nix
{
  outputs = { self }: {
    lib = {
      answer = 42;
      double = x: x * 2;
    };
  };
}
```

```
$ nix eval .#lib
{ answer = 42; double = <LAMBDA>; }
```

We can create a subflake in the `dev` directory:

```nix
# dev/flake.nix
{
  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    namaka = {
      url = "github:nix-community/namaka/v0.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = inputs@{ flake-parts, namaka, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem = { inputs', pkgs, ... }: {
        devShells.default = pkgs.mkShell {
          packages = [
            inputs'.namaka.packages.default
          ];
        };
      };
    };
}
```

If you are not familiar with flake-parts, this essentially creates a dev shell with namaka's CLI.
We can enter it with `nix develop ./dev`:

```console
$ namaka --version
namaka 0.2.0
```

Now we can start implementing the tests.
We can use call-flake here to import our flake into the subflake:

```nix
# add this to inputs
call-flake.url = "github:divnix/call-flake";
```

and we can make namaka load the tests from the `tests` directory:

```nix
# add this to outputs
flake.checks = namaka.lib.load {
  src = ./tests;
  inputs = {
    foo = (call-flake ../.).lib;
  };
};
```

Now we can create the tests to make sure `42 * 2` is always 84:

```bash
mkdir -p dev/tests/works
echo "{ foo }: foo.double foo.answer" > dev/tests/works/expr.nix
```

Namaka is a snapshot testing library, meaning
you don't need to write `84` yourself, and the `namaka` CLI will do this for you.

Always typing out `dev` can be annoying, so we can [configure](https://github.com/nix-community/namaka#configuration)
namaka to always work with the `dev` directory.
At the root of git repository, create a `namaka.toml` with the following contents:

```toml
[check]
cmd = ["nix", "eval", "./dev#checks"]
# or
# cmd = ["nix", "flake", "check", "./dev"]

[eval]
cmd = ["nix", "eval", "./dev#checks"]
```

Run `namaka check` then `namaka review` to update the snapshots.
Make sure the newly created files are added to git.

Now if we run `namaka check` again, all the tests should be passing.

```
✔ works
All 1 tests succeeded
```

And now we get to use libraries like [namaka] and [flake-parts] for development
without having to worry about these dependencies being propagated to our users!

---

A modified version of this example is also available as a template,
so you can start using subflakes for development with just one command:

```bash
nix flake init -t github:nix-community/namaka#subflake
```

## Drawbacks

- With flakes, `../.` only works if you are in a git repository,
  so things like `nix flake check path:dev` wouldn't work.

- You would have to append `./dev` to your commands.
  [namaka] makes this easier by allowing a config file,
  but you still have to deal with this with commands like `nix develop` and `nix flake check`.

- You need to keep track of two `flake.lock` files. This can make updating slightly more cumbersome.

[arion]: https://docs.hercules-ci.com/arion
[call-flake]: https://github.com/divnix/call-flake
[craneLib.cargoClippy]: https://crane.dev/API.html#cranelibcargoclippy
[flake-compat-fork]: https://github.com/nix-community/flake-compat
[flake-compat]: https://github.com/edolstra/flake-compat
[flake-parts]: https://flake.parts
[flake-utils-plus]: https://github.com/gytis-ivaskevicius/flake-utils-plus
[flake-utils]: https://github.com/numtide/flake-utils
[get-flake]: https://github.com/ursi/get-flake
[haumea]: https://nix-community.github.io/haumea
[microvm.nix]: https://astro.github.io/microvm.nix
[namaka]: https://github.com/nix-community/namaka
[pre-commit-hooks.nix]: https://github.com/cachix/pre-commit-hooks.nix
[std]: https://github.com/divnix/std
[treefmt-nix]: https://github.com/numtide/treefmt-nix
