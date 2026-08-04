#!/bin/sh
set -eu

comparison_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$comparison_root/../.." && pwd)
bootstrap="$comparison_root/scripts/run-kubernetes-container.sh"
revision=${HTTP_BENCH_GIT_REVISION:-$(git -C "$project_root" rev-parse HEAD)}
repository=${HTTP_BENCH_GIT_REPOSITORY:-https://github.com/flyology-ada/flyology.git}
arm_node=${HTTP_BENCH_ARM64_NODE:-}
amd_node=${HTTP_BENCH_AMD64_NODE:-}
arches=${HTTP_BENCH_ARCHES:-"arm64 amd64"}
duration=${HTTP_BENCH_DURATION:-30s}
warmup=${HTTP_BENCH_WARMUP:-5s}
concurrencies=${HTTP_BENCH_CONCURRENCIES:-1}
arm_concurrencies=${HTTP_BENCH_ARM64_CONCURRENCIES:-$concurrencies}
amd_concurrencies=${HTTP_BENCH_AMD64_CONCURRENCIES:-$concurrencies}
trials=${HTTP_BENCH_TRIALS:-7}
cooldown=${HTTP_BENCH_COOLDOWN:-20}
tiers=${HTTP_BENCH_TIERS:-"plain application"}
server_cpuset=${HTTP_BENCH_SERVER_CPUSET:-0-7}
client_cpuset=${HTTP_BENCH_CLIENT_CPUSET:-8-15}
loops=${HTTP_BENCH_LOOPS:-16}
cpu_limit=${HTTP_BENCH_POD_CPUS:-16}
memory_limit=${HTTP_BENCH_POD_MEMORY:-8Gi}
rust_workers=${HTTP_BENCH_RUST_WORKERS:-8}
saturation_probe=${HTTP_BENCH_SATURATION_PROBE:-0}
local_overlay=${HTTP_BENCH_LOCAL_OVERLAY:-1}
deadline=${HTTP_BENCH_JOB_DEADLINE_SECONDS:-14400}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
namespace_timestamp=$(printf '%s' "$timestamp" | tr '[:upper:]' '[:lower:]')
namespace=${HTTP_BENCH_NAMESPACE:-flyology-http-bench-$namespace_timestamp}
output_root=${HTTP_BENCH_OUTPUT_ROOT:-"$project_root/build/http-comparison/kubernetes-results/$timestamp"}

case "$local_overlay:$saturation_probe" in
   0:0|0:1|1:0|1:1) ;;
   *) printf '%s\n' "HTTP_BENCH_LOCAL_OVERLAY and HTTP_BENCH_SATURATION_PROBE must be 0 or 1" >&2; exit 2 ;;
esac

for command_name in jq kubectl; do
   if ! command -v "$command_name" >/dev/null 2>&1; then
      printf '%s\n' "$command_name is required" >&2
      exit 1
   fi
done

mkdir -p "$output_root/logs"
created_namespace=0
artifacts_collected=0
privacy_scanned=0
overlay_archive=
overlay_dirty=0
private_context=$(kubectl config current-context 2>/dev/null || true)
private_cluster=$(kubectl config view --minify \
   --output jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)
private_server=$(kubectl config view --minify \
   --output jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)

if [ "$local_overlay" -eq 1 ]; then
   overlay_archive=$(mktemp /tmp/flyology-http-overlay.XXXXXX.tar.gz)
   tar -czf "$overlay_archive" -C "$project_root" \
      --exclude='showcases/http-comparison/servers/*/alire' \
      --exclude='showcases/http-comparison/servers/*/bin' \
      --exclude='showcases/http-comparison/servers/*/config' \
      --exclude='showcases/http-comparison/servers/*/obj' \
      --exclude='showcases/http-comparison/servers/rust/target' \
      showcases/http-comparison
   overlay_dirty=1
fi

collect_artifacts () {
   [ "$created_namespace" -eq 1 ] || return 0
   [ "$artifacts_collected" -eq 0 ] || return 0
   for arch in $arches; do
      job="http-benchmark-$arch"
      pod=$(kubectl get pods --namespace "$namespace" \
         --selector "job-name=$job" \
         --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      if [ -n "$pod" ]; then
         kubectl logs --namespace "$namespace" "$pod" --container benchmark \
            >"$output_root/logs/$arch.log" 2>&1 || true
         mkdir -p "$output_root/$arch"
         kubectl cp "$namespace/$pod:/results/." "$output_root/$arch" \
            --container collector \
            >/dev/null 2>&1 || true
      fi
   done
   artifacts_collected=1
}

privacy_scan () {
   [ "$artifacts_collected" -eq 1 ] || return 0
   [ "$privacy_scanned" -eq 0 ] || return 0
   HTTP_BENCH_PRIVATE_TOKENS=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$arm_node" "$amd_node" "$namespace" "$private_context" \
      "$private_cluster" "$private_server") \
      "$comparison_root/scripts/privacy_scan.py" "$output_root"
   privacy_scanned=1
}

cleanup () {
   status=$?
   trap - EXIT HUP INT TERM
   collect_artifacts
   if ! privacy_scan; then
      status=1
   fi
   namespace_deleted=false
   if [ "$created_namespace" -eq 1 ]; then
      if kubectl delete namespace "$namespace" --wait=true >/dev/null 2>&1 &&
         ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
         namespace_deleted=true
      else
         status=1
      fi
   fi
   printf '{"schema":1,"temporary_namespace_deleted":%s}\n' \
      "$namespace_deleted" >"$output_root/cleanup.json"
   if [ -n "$overlay_archive" ]; then
      rm -f "$overlay_archive"
   fi
   exit "$status"
}
trap cleanup EXIT HUP INT TERM

validate_node () {
   node=$1
   expected_arch=$2
   actual_arch=$(kubectl get node "$node" \
      --output jsonpath='{.metadata.labels.kubernetes\.io/arch}')
   ready=$(kubectl get node "$node" \
      --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
   if [ "$actual_arch" != "$expected_arch" ] || [ "$ready" != True ]; then
      printf '%s\n' "$node is not a ready $expected_arch node" >&2
      exit 1
   fi
}

for arch in $arches; do
   case "$arch" in
      arm64)
         [ -n "$arm_node" ] || { printf '%s\n' "HTTP_BENCH_ARM64_NODE is required" >&2; exit 2; }
         validate_node "$arm_node" arm64
         ;;
      amd64)
         [ -n "$amd_node" ] || { printf '%s\n' "HTTP_BENCH_AMD64_NODE is required" >&2; exit 2; }
         validate_node "$amd_node" amd64
         ;;
      *) printf '%s\n' "HTTP_BENCH_ARCHES accepts arm64 and amd64" >&2; exit 2 ;;
   esac
done

kubectl create namespace "$namespace" >/dev/null
created_namespace=1
kubectl label namespace "$namespace" \
   app.kubernetes.io/name=flyology-http-benchmark \
   app.kubernetes.io/managed-by=benchmark-script \
   purpose=temporary-benchmark >/dev/null
if [ -n "$overlay_archive" ]; then
   kubectl create configmap benchmark-bootstrap --namespace "$namespace" \
      --from-file=bootstrap.sh="$bootstrap" \
      --from-file=overlay.tar.gz="$overlay_archive" >/dev/null
else
   kubectl create configmap benchmark-bootstrap --namespace "$namespace" \
      --from-file=bootstrap.sh="$bootstrap" >/dev/null
fi

create_job () {
   arch=$1
   node=$2
   if [ "$arch" = arm64 ]; then
      arch_concurrencies=$arm_concurrencies
   else
      arch_concurrencies=$amd_concurrencies
   fi
   job="http-benchmark-$arch"
   kubectl create job "$job" --namespace "$namespace" \
      --image ubuntu:24.04 --dry-run=client --output=json \
      | jq \
         --arg node "$node" \
         --arg arch "$arch" \
         --arg revision "$revision" \
         --arg repository "$repository" \
         --arg duration "$duration" \
         --arg warmup "$warmup" \
         --arg concurrencies "$arch_concurrencies" \
         --arg trials "$trials" \
         --arg cooldown "$cooldown" \
         --arg tiers "$tiers" \
         --arg server_cpuset "$server_cpuset" \
         --arg client_cpuset "$client_cpuset" \
         --arg loops "$loops" \
         --arg cpu_limit "$cpu_limit" \
         --arg memory_limit "$memory_limit" \
         --arg rust_workers "$rust_workers" \
         --arg saturation_probe "$saturation_probe" \
         --arg git_dirty "$overlay_dirty" \
         --argjson deadline "$deadline" \
         '.spec.backoffLimit = 0
          | .spec.activeDeadlineSeconds = $deadline
          | .spec.template.spec.nodeName = $node
          | .spec.template.spec.hostname = ("benchmark-" + $arch)
          | .spec.template.spec.terminationGracePeriodSeconds = 30
          | .spec.template.spec.containers[0].name = "benchmark"
          | .spec.template.spec.containers[0].command = ["/bin/sh", "/bootstrap/bootstrap.sh"]
          | .spec.template.spec.containers[0].env = [
              {name:"HTTP_BENCH_GIT_REVISION",value:$revision},
              {name:"HTTP_BENCH_GIT_REPOSITORY",value:$repository},
              {name:"HTTP_BENCH_DURATION",value:$duration},
              {name:"HTTP_BENCH_WARMUP",value:$warmup},
              {name:"HTTP_BENCH_CONCURRENCIES",value:$concurrencies},
              {name:"HTTP_BENCH_TRIALS",value:$trials},
              {name:"HTTP_BENCH_COOLDOWN",value:$cooldown},
              {name:"HTTP_BENCH_TIERS",value:$tiers},
              {name:"HTTP_BENCH_SERVER_CPUSET",value:$server_cpuset},
              {name:"HTTP_BENCH_CLIENT_CPUSET",value:$client_cpuset},
              {name:"HTTP_BENCH_INCLUDE_CHURN",value:"0"},
              {name:"HTTP_BENCH_LOOPS",value:$loops},
              {name:"HTTP_BENCH_OUTPUT_ROOT",value:"/results"},
              {name:"HTTP_BENCH_RUST_WORKERS",value:$rust_workers},
              {name:"HTTP_BENCH_SATURATION_PROBE",value:$saturation_probe},
              {name:"HTTP_BENCH_GIT_DIRTY",value:$git_dirty}
            ]
          | .spec.template.spec.containers[0].resources = {
              requests:{cpu:$cpu_limit,memory:$memory_limit},
              limits:{cpu:$cpu_limit,memory:$memory_limit}
            }
          | .spec.template.spec.containers[0].volumeMounts = [
              {name:"bootstrap",mountPath:"/bootstrap",readOnly:true},
              {name:"results",mountPath:"/results"}
            ]
          | .spec.template.spec.containers += [{
              name:"collector",
              image:"ubuntu:24.04",
              command:["/bin/sh","-c","sleep 21600"],
              resources:{
                requests:{cpu:"10m",memory:"32Mi"},
                limits:{cpu:"100m",memory:"64Mi"}
              },
              volumeMounts:[{name:"results",mountPath:"/results"}]
            }]
          | .spec.template.spec.volumes = [
              {name:"bootstrap",configMap:{name:"benchmark-bootstrap",defaultMode:365}},
              {name:"results",emptyDir:{}}
            ]' \
      | kubectl apply --namespace "$namespace" --filename=- >/dev/null
}

for arch in $arches; do
   case "$arch" in
      arm64) create_job arm64 "$arm_node" ;;
      amd64) create_job amd64 "$amd_node" ;;
   esac
done
printf 'running %s jobs in namespace %s\n' "$arches" "$namespace"

expected=0
for arch in $arches; do expected=$((expected + 1)); done
failed=0
while :; do
   terminated=0
   for arch in $arches; do
      job="http-benchmark-$arch"
      pod=$(kubectl get pods --namespace "$namespace" \
         --selector "job-name=$job" \
         --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      exit_code=
      if [ -n "$pod" ]; then
         exit_code=$(kubectl get pod "$pod" --namespace "$namespace" --output=json \
            | jq -r '.status.containerStatuses[]?
               | select(.name == "benchmark")
               | .state.terminated.exitCode // empty')
      fi
      if [ -n "$exit_code" ]; then
         terminated=$((terminated + 1))
         if [ "$exit_code" -ne 0 ]; then failed=1; fi
      fi
   done
   [ "$terminated" -eq "$expected" ] && break
   sleep 15
done

collect_artifacts
if [ "$failed" -ne 0 ]; then
   printf '%s\n' "one or more benchmark jobs failed; partial artifacts were preserved" >&2
   exit 1
fi
printf '%s\n' "Kubernetes comparison results are under $output_root"
