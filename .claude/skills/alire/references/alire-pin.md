# Pinning Dependencies

Use `alr pin` to link a dependency to a specific source outside the Alire index, such as a local directory, a Git repository or a specific release version.

## Pin to a local directory

```bash
alr pin <crate_name> --use <path/to/local/crate>
```

## Pin to a Git repository

```bash
alr pin <crate_name> --url <repository_url>
```

Pin to a specific branch:
```bash
alr pin <crate_name> --url <repository_url> --branch <branch_name>
```

Pin to a specific commit:
```bash
alr pin <crate_name> --url <repository_url> --commit <commit_hash>
```

## List current pins

```bash
alr pin
```

## Remove a pin

```bash
alr pin --unpin <crate_name>
```
