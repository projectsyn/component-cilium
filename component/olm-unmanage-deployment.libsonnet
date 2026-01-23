local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;

local name = 'unmanage-olm-deployment';
local namespace = params._namespace;

local clusterRole = kube.ClusterRole(name) {
  metadata+: {
    annotations+: {
      'argocd.argoproj.io/hook': 'PreSync',
    },
  },
  rules: [
    {
      apiGroups: [ 'apps' ],
      resources: [ 'deployments' ],
      verbs: [ 'get', 'patch' ],
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
                |||
                  kubectl -n %(namespace)s label deploy clife-controller-manager argocd.argoproj.io/instance-
                ||| % {
                  namespace: namespace,
                },
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
