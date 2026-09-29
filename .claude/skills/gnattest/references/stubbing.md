# GNATtest Stub-Based Isolation Testing

## When to Use Stubbing

Use `--stub` when you need to **isolate the unit under test** from its
dependencies. Typical reasons:

- A dependency is hardware-facing or has side effects (I/O, network, sensors).
- A dependency is slow, flaky, or unavailable in the test environment.
- You need to test error-handling paths that are difficult to trigger with
  real dependencies.
- You want true unit tests that fail only when the unit under test is wrong.

If your dependencies are pure, fast, and testable themselves, integration-style
testing with the real implementations is often simpler and more valuable than
stubbing.

---

## What Gets Stubbed

GNATtest stubs the **direct package-level dependencies** of the unit under test:
every package that the unit's spec or body `with`s, except:

- Generic packages and their instantiations.
- The package containing the subprogram under test itself (same-package calls
  are never stubbed — the real code is always used).
- Packages listed in an exclusion file (`--exclude-from-stubbing`).

Stubs replace package bodies while keeping specs intact. They do this via GPR
**extending projects**, so the real bodies are hidden for each unit's test driver
without modifying source files.

---

## What `--stub` Generates

```bash
gnattest -P myproject.gpr --tests-root=../../tests --stub
```

In addition to the standard test skeleton and harness, gnattest generates:

```
<stubs-dir>/
  dep_pkg/
    dep_pkg.adb              ← stub body (returns defaults; safe to customise)
    dep_pkg-stub_data.ads    ← setter spec (regenerated)
    dep_pkg-stub_data.adb    ← setter body (yours to edit for test scenarios)
```

`--stub` **implies `--separate-drivers`** — a separate test driver executable
is produced for each unit under test, because each unit needs its own set of
stubs. See [separate-drivers.md](separate-drivers.md) for how to build and run
them.

---

## Setter Routines

For each stubbed subprogram `Do_Something` in `Dep_Pkg`, gnattest generates a
setter in `Dep_Pkg.Stub_Data`:

```ada
package Dep_Pkg.Stub_Data is
   procedure Set_Do_Something_Output
     (Return_Value : Integer;
      Stub_Number  : Natural := 0);
end Dep_Pkg.Stub_Data;
```

Call the setter from your test routine (in `*-test_data-tests.adb`) before
calling the unit under test:

```ada
with Dep_Pkg.Stub_Data;

procedure Test_My_Unit_Foo_... is
   use AUnit.Assertions;
begin
   --  Configure stub: next call to Dep_Pkg.Do_Something returns 42
   Dep_Pkg.Stub_Data.Set_Do_Something_Output (Return_Value => 42);

   My_Unit.Foo;

   Assert (My_Unit.Last_Result = 42, "Foo should use Dep result");
end Test_My_Unit_Foo_...;
```

`Stub_Number => 0` means "return this value for all calls". Use `Stub_Number
=> 1`, `2`, etc. to set different return values for successive calls.

**Stub bodies and stub-data bodies are yours to customise.** Gnattest will
not overwrite them after the initial generation. Commit them. Stub *specs*
(`dep_pkg-stub_data.ads`) are regenerated — do not commit them.

---

## Tutorial: Isolating a Hardware-Dependent Unit

Suppose `Sensor` is a package that reads from hardware and `Controller` depends
on it:

```
Controller  --with-->  Sensor
```

### Step 1: Generate with stubs

```bash
gnattest -P myproject.gpr \
  --tests-root=../../tests \
  --stubs-dir=tests/stubs \
  --stub
```

GNATtest generates:
- `tests/stubs/sensor/sensor.adb` — stub body (returns defaults)
- `tests/stubs/sensor/sensor-stub_data.ads/.adb` — setters

### Step 2: Build all test drivers

```bash
gprbuild -P <obj>/gnattest/harness/test_driver.gpr
```

Or using the generated Makefile:

```bash
make -f <obj>/gnattest/harness/Makefile
```

### Step 3: Configure stubs in your tests

In `controller-test_data-tests.adb`:

```ada
with Sensor.Stub_Data;

procedure Test_Controller_Process_... is
   use AUnit.Assertions;
begin
   --  Simulate a sensor reading of 100
   Sensor.Stub_Data.Set_Read_Value_Output (Return_Value => 100);

   Controller.Process;

   Assert (Controller.Output = Expected, "wrong output for sensor=100");
end Test_Controller_Process_...;
```

### Step 4: Run via test execution mode

```bash
gnattest <obj>/gnattest/harness/test_drivers.list -j4
```

---

## Excluding Units from Stubbing

If a package should never be stubbed (e.g., a pure utility library or a runtime
package), list its spec file in an exclusion file:

```
# no_stub.txt
string_utils.ads
ada-containers-vectors.ads
```

```bash
gnattest -P myproject.gpr --stub --exclude-from-stubbing=no_stub.txt
```

To exclude a package only when testing a specific unit:

```bash
--exclude-from-stubbing:spec=controller.ads=no_stub_for_controller.txt
```

Or in the project file:

```ada
for Default_Stub_Exclusion_List use "no_stub.txt";
for Stub_Exclusion_List ("controller.ads") use "no_stub_for_controller.txt";
```

---

## Common Pitfalls

- **Stub returns default (zero/null) if no setter is called.** Always call
  setters before the code path that invokes the stubbed subprogram — silent
  zero returns can mask bugs.
- **Stubs are per-unit, not per-test-case.** State set by a setter persists
  for the duration of the test driver run unless reset. Call setters in each
  test routine rather than relying on previous state.
- **Generic packages are not stubbed.** If your unit depends on a generic
  instantiation, the real instantiation body is used. Design tests accordingly.
- **Recursive stubs** are not generated by default. If a stubbed package itself
  has dependencies you want to stub, add `--recursive-stub` (use with care —
  this can produce a large stub tree).
