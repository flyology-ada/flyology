# Cross-Compiling for Raspberry Pi Pico (RP2040)

## Required crate

| Crate | Purpose |
|---|---|
| `pico_bsp` | Board support package — pin definitions, board-level config |

Other crates will be added as needed.

## Steps

### 1. Add the dependency
From inside the project directory:
```bash
alr -n with pico_bsp
```

### 2. Configure the GPR file
Add the following to the project `.gpr` file:
```ada
for Target use "arm-eabi";
for Runtime ("Ada") use "light-cortex-m0p";
```

### 3. Build
```bash
alr -n build
```

A successful build produces an ELF binary in `bin/`.

### 4. Flash to the Pico
Convert the ELF to UF2 and copy to the device's mass storage, or use `picotool`:
```bash
picotool load bin/<project_name> --force
```
