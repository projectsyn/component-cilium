local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;

local name = 'prepare-upgrade-to-clife';
local namespace = params._namespace;

local clusterRole = kube.ClusterRole(name) {
  metadata+: {
    annotations+: {
      'argocd.argoproj.io/hook': 'PreSync',
    },
  },
  rules: [
    {
      apiGroups: [ '*' ],
      resources: [ '*' ],
      verbs: [ '*' ],
    },
  ],
};

local serviceAccount = kube.ServiceAccount(name) {
  metadata+: {
    namespace: namespace,
    annotations+: {
      'argocd.argoproj.io/hook': 'PreSync',
    },
  },
};

local clusterRoleBinding = kube.ClusterRoleBinding(name) {
  metadata+: {
    annotations+: {
      'argocd.argoproj.io/hook': 'PreSync',
    },
  },
  subjects_: [ serviceAccount ],
  roleRef_: clusterRole,
};

local job =
  local jobconfig = {
    namespace: namespace,
    cilium_config: 'cilium-enterprise',
    old_release_name: 'cilium-enterprise',
    new_release_name: 'cilium-release',
    sa: 'clife-controller-manager',
    old: 'cilium-ee-olm',
    new: 'clife-controller-manager',
  };
  kube.Job(name) {
    metadata+: {
      namespace: namespace,
      annotations+: {
        'argocd.argoproj.io/hook': 'PreSync',
        'argocd.argoproj.io/hook-delete-policy': 'HookSucceeded',
      },
    },
    spec+: {
      template+: {
        spec+: {
          serviceAccountName: serviceAccount.metadata.name,
          containers_+: {
            patch_crds: kube.Container(name) {
              image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
              workingDir: '/home',
              command: [ 'bash', '-e', '-c' ],
              args: [
                // adapted from Isovalent migration guide
                // TODO(sg): Figure out a way to test this
                // maybe we can implement the reverse for going back from clife to cilium-ee-olm
                |||
                  if ! kubectl -n %(namespace)s get sa %(sa)s &>/dev/null; then
                    echo "Preparing migration from %(old)s to %(new)s..."
                    kubectl -n %(namespace)s delete deploy %(old)s --ignore-not-found=true
                    kubectl delete operator cilium-enterprise.cilium --ignore-not-found=true
                    kubectl delete operator cilium.cilium --ignore-not-found=true
                    kubectl -n %(namespace)s delete cm cilium-ee-olm --ignore-not-found=true
                    kubectl -n %(namespace)s delete cm cilium-olm --ignore-not-found=true
                    for object in $(kubectl -n %(namespace)s get serviceaccount,role,rolebinding,deploy,daemonset,configmap,secret -o yaml | \
                        yq '.items[]
                           | select( (.metadata.ownerReferences // []) | map(.kind == "CiliumConfig") | contains([true]) )
                           | (.kind + "/" + .metadata.name)')
                    do
                      kubectl -n %(namespace)s patch $object --type json -p='[{"op": "remove", "path": "/metadata/ownerReferences"}]'
                    done
                    for object in $(kubectl -n %(namespace)s get serviceaccount,role,rolebinding,clusterrole,clusterrolebinding,deploy,daemonset,configmap,secret -o yaml | \
                        yq '.items[]
                        | select(.metadata.annotations."meta.helm.sh/release-name" == "%(old_release_name)s")
                        | (.kind + "/" + .metadata.name)')
                    do
                      kubectl -n %(namespace)s patch $object --type json -p='[{"op": "replace", "path": "/metadata/annotations/meta.helm.sh~1release-name", "value": "%(new_release_name)s"}]'
                    done
                    kubectl -n %(namespace)s delete secret -l owner=helm
                    kubectl -n %(namespace)s patch ciliumconfig %(cilium_config)s --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
                    kubectl -n %(namespace)s delete ciliumconfig %(cilium_config)s
                    kubectl delete crd ciliumconfigs.cilium.io
                    kubectl api-resources --api-group=cilium.io
                    kubectl -n syn delete pods syn-argocd-application-controller-0
                  else
                    echo "%(new)s is already present on the cluster, doing nothing."
                  fi
                ||| % jobconfig,
              ],
              env: [
                { name: 'HOME', value: '/home' },
              ],
              volumeMounts: [
                { name: 'home', mountPath: '/home' },
              ],
            },
          },
          volumes+: [
            { name: 'home', emptyDir: {} },
          ],
        },
      },
    },
  };

[
  clusterRole,
  serviceAccount,
  clusterRoleBinding,
  job,
]
