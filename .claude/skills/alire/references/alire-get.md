# Fetching a Crate

Use `alr get` to download a crate from the index into a local directory without adding it as a dependency.

## Fetch a crate

```bash
alr get <crate_name>
```

This creates a `<crate_name>_<version>/` directory in the current folder.

## Fetch a specific version

```bash
alr get <crate_name>=<version>
```

## Fetch and build

```bash
alr get --build <crate_name>
```
