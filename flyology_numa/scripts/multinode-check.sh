#!/bin/sh
#  Runs the host test suite against guests that have several memory nodes.
#
#  Most machines have one memory domain, so the parts of the suite that
#  choose between nodes never run on them.  A guest can be given as many
#  nodes as wanted, with processors attached to some and not others, which
#  is what makes those parts reachable.
#
#  This is not part of ./scripts/test.sh: it needs a Linux host, a kernel
#  image to boot, and qemu.  Run it directly.

set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "$(uname -s)" != "Linux" ]
then
   printf '%s\n' "multinode-check needs a Linux host; this is $(uname -s)" >&2
   exit 2
fi

#  A guest runs the architecture it is tested for, so that the placement
#  calls it makes are the ones this architecture's table names.
case "$(uname -m)" in
   x86_64)
      emulator=qemu-system-x86_64
      console=ttyS0
      machine=""
      ;;
   aarch64)
      emulator=qemu-system-aarch64
      console=ttyAMA0
      machine="-machine virt -cpu max"
      ;;
   *)
      printf '%s\n' "multinode-check has no guest for $(uname -m)" >&2
      exit 2
      ;;
esac

for tool in "$emulator" busybox cpio
do
   if ! command -v "$tool" >/dev/null 2>&1
   then
      printf '%s\n' "multinode-check needs $tool" >&2
      exit 2
   fi
done

kernel=${FLYOLOGY_NUMA_KERNEL:-$(ls /boot/vmlinuz-* 2>/dev/null | head -1)}

if [ -z "$kernel" ] || [ ! -r "$kernel" ]
then
   printf '%s\n' \
     "no kernel to boot; set FLYOLOGY_NUMA_KERNEL to a readable image" >&2
   exit 2
fi

alr=$("$crate_root/../scripts/find-alr.sh")
work=$(mktemp -d "${TMPDIR:-/tmp}/flyology-numa-multinode.XXXXXX")

cleanup()
{
   rm -rf "$work"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

cd "$crate_root/tests"
"$alr" -n build

#  A guest has no libraries of its own, so the ones the test binary resolves
#  to are carried in at the paths its loader will look for them.
mkdir -p "$work/root/bin" "$work/root/proc" "$work/root/sys"
cp "$(command -v busybox)" "$work/root/bin/busybox"
ln -sf busybox "$work/root/bin/sh"
cp "$crate_root/tests/bin/tests" "$work/root/tests"

ldd "$crate_root/tests/bin/tests" \
  | grep -oE '/[^ ]+\.so[^ )]*' \
  | sort -u \
  | while read -r library
do
   mkdir -p "$work/root$(dirname "$library")"
   cp -L "$library" "$work/root$library"
done

cat > "$work/root/init" <<'GUEST'
#!/bin/sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
echo "online: $(cat /sys/devices/system/node/online)"
for node in /sys/devices/system/node/node*/
do
   echo "$(/bin/busybox basename "$node") cpulist=$(cat "$node/cpulist")"
done
/tests
echo "GUEST_EXIT=$?"
/bin/busybox poweroff -f
GUEST

chmod +x "$work/root/init"
(cd "$work/root" && find . | cpio -o -H newc 2>/dev/null | gzip) \
  > "$work/initramfs.cpio.gz"

run_guest()
{
   name=$1
   shift

   printf '\n== %s ==\n' "$name"

   if ! timeout 1800 "$emulator" -nographic -no-reboot $machine \
      -kernel "$kernel" -initrd "$work/initramfs.cpio.gz" \
      -append "console=$console rdinit=/init panic=1 loglevel=3" \
      "$@" 2>&1 | tr -d '\r' | tee "$work/log"
   then
      printf '%s\n' "$name did not finish" >&2
      exit 1
   fi

   if ! grep -q "all flyology_numa host tests passed" "$work/log"
   then
      printf '%s\n' "$name did not pass the host suite" >&2
      exit 1
   fi

   if ! grep -q "GUEST_EXIT=0" "$work/log"
   then
      printf '%s\n' "$name reported a failure" >&2
      exit 1
   fi
}

#  Two nodes, each with processors: the smallest topology that makes
#  choosing between nodes mean anything.
#
#  The processors are laid out one socket per node.  A guest whose sockets
#  straddle its nodes is a machine that does not exist, and some guest
#  architectures say so.
run_guest "two nodes" \
  -m 2048 -smp 4,sockets=2,cores=2 \
  -object memory-backend-ram,id=m0,size=1024M \
  -object memory-backend-ram,id=m1,size=1024M \
  -numa node,nodeid=0,memdev=m0,cpus=0-1 \
  -numa node,nodeid=1,memdev=m1,cpus=2-3 \
  -numa dist,src=0,dst=1,val=21

#  Four nodes with uneven distances, one of them carrying memory and no
#  processor at all.  A memory expander looks like this, and so does a
#  high-bandwidth tier.
run_guest "four nodes, one without processors" \
  -m 2048 -smp 6,sockets=3,cores=2 \
  -object memory-backend-ram,id=m0,size=512M \
  -object memory-backend-ram,id=m1,size=512M \
  -object memory-backend-ram,id=m2,size=512M \
  -object memory-backend-ram,id=m3,size=512M \
  -numa node,nodeid=0,memdev=m0,cpus=0-1 \
  -numa node,nodeid=1,memdev=m1,cpus=2-3 \
  -numa node,nodeid=2,memdev=m2,cpus=4-5 \
  -numa node,nodeid=3,memdev=m3 \
  -numa dist,src=0,dst=1,val=11 \
  -numa dist,src=0,dst=2,val=21 \
  -numa dist,src=0,dst=3,val=31 \
  -numa dist,src=1,dst=2,val=21 \
  -numa dist,src=1,dst=3,val=31 \
  -numa dist,src=2,dst=3,val=31

printf '\nall flyology_numa multi-node guests passed on %s\n' "$(uname -m)"
