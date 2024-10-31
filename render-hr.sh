#!/bin/bash

set -e
set -o pipefail

err() {
  echo "$@" >&2
  exit 1
}

log() {
  echo >&2 "$@"
}

usage() {
  log "Wrong usage:" "$@"
  cat >&2 <<EOF

Usage: $0 [-s NAMESPACE_SOURCECONTROLLER] [-n NAMESPACE] [-f VALUES] [-x HELMARGS] [-o OUTPUT] HELMRELEASE [TEMPLATE_RELEASE_NAME]

  NAMESPACE: Namespace of Helm release.
  NAMESPACE_SOURCECONTROLLER: Namespace of flux source controller. Defaults to "flux-system".
  HELMARGS: Additonal arguments for "helm template" command. Can be specified multiple times.
  OUTPUT: Write rendered chart to file.
  TEMPLATE_RELEASE_NAME: Optional release name for "helm template" command.
  VALUES: Additional overlay values.yaml (only supported once).
   

  Environment variables:
    KUBECTL: Use this command for kubectl. Defaults to "kubectl". Needs "get" and "list" permissions.
    KUBECTLELEVATED: Use this command for elevated access. Defaults to "kubectl sudo" (compare https://github.com/postfinance/kubectl-sudo). Requires e.g. copy permissions from flux source-controller's file-system.


  Example: Render "my-hr" in current namespace
    $0 my-hr
  
  Example: Render "my-hr" in current namespace but set/shadow some values as defined in "myValues.yaml"
    $0 -f myValues.yaml my-hr
  
  Example: Render "my-hr" in "foo" namespace and set release name to "MyReleaseName". Save output to "rendered.yaml".
    $0 -o rendered.yaml -n foo my-hr "MyReleaseName"

  Example: Render "my-hr" in current namespace and set helm options "--render-subchart-notes" as well as disable fictional "ingress.enabled" key 
    $0 -x --render-subchart-notes -x --set -x ingress.enabled=false -o rendered.yaml my-hr
EOF
exit 2
}

checkdeps() {
  for dep in yq helm sed "$kubectl" tar
  do
    [ "$(which "$dep")" ] || err "Missing dependency '$dep'"
  done
}

summarize_args() {
  displayed_namespace="$namespace"
  [ "$displayed_namespace" ] || displayed_namespace="$(kubectl config view --minify -o jsonpath='{..namespace}')"
  displayed_output="$output"
  [ "$displayed_output" ] || displayed_output="(stdout)"
  cat >&2 <<EOF
  Basic Arguments:
    Helm Release: "$hr"
    Namespace: "$displayed_namespace"
    NamespaceSourceController: "$namespace_sourcecontroller"
    Output: "$output"

  Templating settings:
    Release Name: "$template_release_name"
    Helm Args: "${helmargs[@]}"

EOF
}

render() {
  cd "$1"
  log "Fetching Helm Release $hr"
  args=
  [ "$namespace" ] && args="-n $namespace"
  
  # shellcheck disable=SC2086 
  $kubectl get hr $args "$hr" -o json >hr.json
  
  <hr.json jq -r '.spec.values' > values.json
  
  name="$hr"
  namespace="$(<hr.json jq -r '.metadata.namespace')"
  version="$(<hr.json jq -r '.spec.chart.spec.version')"
  chart_source_namespace="$(<hr.json jq -r '.spec.chart.spec.sourceRef.namespace')"
  
  [ "$name" != "null" ] || err "failed extracting name"
  [ "$namespace" != "null" ] || err "failed extracting namespace"
  [ "$version" != "null" ] || err "failed extracting version"
  [ "$chart_source_namespace" != "null" ] || err "failed extracting sourceRef namespace"
  
  log "Fetching corresponding helmcharts"
  $kubectl get helmchart -n "$chart_source_namespace" -l "helm.toolkit.fluxcd.io/name=$name" -l "helm.toolkit.fluxcd.io/namespace=$namespace" -o json >all-charts.json
  
  log "Extracting version $version"
  <all-charts.json jq -rc '.items[] | select(.spec.version == "'"$version"'")' >chart.json
  
  [ "$(<chart.json wc -l  | sed -re 's/^ +//g')" == "0" ] && err "Found no charts with same version"
  [ "$(<chart.json wc -l  | sed -re 's/^ +//g')" == "1" ] || err "Found multiple charts with same version"
  
  path="$(<chart.json jq -r '.status.artifact.path')"
  
  log "Fetching source controller pod name"
  sourcecontroller="$($kubectl get pods -n "$namespace_sourcecontroller" -l app=source-controller -o json | jq -cr '.items[].metadata.name')"
  [ "$(wc -l <<<"$sourcecontroller" | sed -re 's/^ +//g')" == "1" ] || err "Found multiple pods"
  
  log "Fetching helm chart artifact"
  mkdir build
  $kubectlelevated cp -n "$namespace_sourcecontroller" "${sourcecontroller}:/data/$path" build/chart.tar.gz
  
  cd build
  
  log "Preparing chart"
  tar xvvf chart.tar.gz
  
  cd "$(find . -type d -mindepth 1 -maxdepth 1 | head -n1)"
  cp ../../values.json values-overlay.json
  [ "$valuesyaml" ] && cp ../../values-overlay.yaml values-custom-overlay.yaml

  log "Rendering chart"
  log "helm template . -f values.yaml -f values-overlay.json " "${helmargs[@]}"
  helm dependency build
  helm template . -f values.yaml -f values-overlay.json "${helmargs[@]}"

}

namespace=
hr=
kubectl="kubectl"
kubectlelevated="$kubectl sudo"
helmargs=()
output=
template_release_name="."
valuesyaml=
namespace_sourcecontroller=flux-system

export namespace
export hr
export kubectl
export helmargs
export output
export template_release_name
export valuesyaml
export namespace_sourcecontroller

[ "$KUBECTL" ] && kubectl="$KUBECTL"
[ "$KUBECTLELEVATED" ] && kubectlelevated="$KUBECTLELEVATED"

checkdeps

while getopts "n:x:o:f:s:" arg; do
  case "$arg" in
    n)
      namespace="$OPTARG"
      ;;
    s)
      namespace_sourcecontroller="$OPTARG"
      ;;
    x)
      helmargs+=("$OPTARG")
      ;;
    o)
      output="$OPTARG"
      ;;
    f)
      helmargs+=("-f")
      helmargs+=("values-custom-overlay.yaml")
      valuesyaml="$OPTARG"
      ;;
    *)
      usage "Wrong option"
      ;;
  esac
done
shift $((OPTIND-1))

[ "$#" -lt "1" ] && usage "Too few arguments"
[ "$#" -gt "2" ] && usage "Too many arguments"

hr="$1"
[ "$2" ] && template_release_name="$2"

summarize_args

log "Setting up temporary work folder"
tmpdir="$(mktemp -d)"
[ "$tmpdir" ] || err "Unable to create tmpdir"

# shellcheck disable=SC2064
trap "rm -rf $tmpdir" SIGINT SIGTERM EXIT

if [ "$valuesyaml" ]; then
  [ -f "$valuesyaml" ] || err "Overlay values $valuesyaml is not a file"
  cp "$valuesyaml" "$tmpdir/values-overlay.yaml"
fi

[ "$output" ] || output=/dev/stdout

(

  render "$tmpdir" >"$output"
)
