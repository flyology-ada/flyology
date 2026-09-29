# Building a Project

```bash
alr -n build
```

To build in release mode:
```bash
alr -n build --release
```

To build in validation mode:
```bash
alr -n build --validation
```

To build in development mode (default):
```bash
alr -n build --development
```

## Known macOS Issue: duplicate LC_RPATH

On macOS, you may see an error like this even when the build succeeds:

```text
dyld: duplicate LC_RPATH '.../toolchains/gnat_native_.../lib' in .../bin/<program>
```

This is a runtime loader (`dyld`) error, not a compile failure. `gprbuild` can finish successfully while the program still exits with code 1 at launch time.

Check embedded runtime paths:

```bash
otool -l ./bin/<program> | grep -A2 LC_RPATH
```

If the same path appears more than once, remove one duplicate entry:

```bash
install_name_tool -delete_rpath ~/.local/share/alire/toolchains/gnat_native_<version>_<hash>/lib ./bin/<program>
```

If needed, rebuild and run again:

```bash
alr -n build
./bin/<program>
```
