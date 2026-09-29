# flyology_cli

`flyology_cli` installs the `flyology` executable, an aggregate command-line
entry point for Flyology projects.

```sh
git clone https://github.com/flyology-ada/flyology.git
cd flyology/flyology_cli
alr install
flyology init my_service
```

`flyology init` scaffolds an Alire binary or library in the current directory
or a named destination. It can generate a downstream consumer or a
Flyology-maintained project, provision the shared `flyology-ada/agents` APM
profile, and add `flyology-ada/website-kit` plus website and GNATdoc build
scripts. It checks for the Flyology Alire index first and offers to install it
ahead of the community index when absent.

For reproducible, non-interactive setup, specify the choices directly:

```sh
flyology init service \
  --bin --yes

flyology init library \
  --lib --flyology-project --website --yes
```

Consumer projects are the default. Pass `--flyology-project` only for a crate
maintained as part of Flyology. Agent guidance is enabled by default, while
website generation is disabled by default. Use `--no-agents` to opt out of
guidance or `--website` to opt into the site scaffold. With `--yes`, omitted
choices use a binary consumer with agents enabled and no website.

## Extension commands

When a command is not built in, `flyology` looks for `flyology-<command>` on
`PATH`, passes through all remaining arguments, and returns the command's exit
status. For example, `flyology deploy staging` invokes
`flyology-deploy staging` when that executable is available.

## Development

```sh
alr build
alr test
```
