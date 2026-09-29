# Executing a Command in the Project Environment

Run an arbitrary command with the crate's environment (PATH, GPR_PROJECT_PATH, etc.) set up. Always use this when running
gnatprove on an Alire enabled project.



```bash
alr exec -- <command> <args>
```

Examples:
```bash
alr exec -- gdb ./bin/main
```
