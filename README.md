# Render in-cluster flux Helm Release

Helper script to render a flux helm-release in-cluster.

```
Usage: ./build-hr.sh [-s NAMESPACE_SOURCECONTROLLER] [-n NAMESPACE] [-f VALUES] [-x HELMARGS] [-o OUTPUT] HELMRELEASE [TEMPLATE_RELEASE_NAME]

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
    ./build-hr.sh my-hr
  
  Example: Render "my-hr" in current namespace but set/shadow some values as defined in "myValues.yaml"
    ./build-hr.sh -f myValues.yaml my-hr
  
  Example: Render "my-hr" in "foo" namespace and set release name to "MyReleaseName". Save output to "rendered.yaml".
    ./build-hr.sh -o rendered.yaml -n foo my-hr "MyReleaseName"

  Example: Render "my-hr" in current namespace and set helm options "--render-subchart-notes" as well as disable fictional "ingress.enabled" key 
    ./build-hr.sh -x --render-subchart-notes -x --set -x ingress.enabled=false -o rendered.yaml my-hr
```
