# Printing Environment Variables

Printenv is convenient if you need to run any of the build commands or tools manually, then printenv provides you
with a way to easily grab the environment variables that are being used.

Print the environment variables that Alire sets for the current crate:
```bash
alr printenv
```

This outputs shell commands that can be evaluated to set up the environment manually:
```bash
eval "$(alr printenv)"
```
