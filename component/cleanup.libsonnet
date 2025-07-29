local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;

local name = 'cleanup-old-clusterserviceversions';
local namespace = params._namespace;

local role = kube.Role(name) {
  metadata+: {
    namespace: namespace,
    annotations+: {
      'argocd.argoproj.io/hook': 'PreSync',
    },
  },
  rules: [
    {
      apiGroups: [ 'operators.coreos.com' ],
      resources: [ 'clusterserviceversions' ],
      verbs: [ 'get', 'list', 'delete' ],
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

local roleBinding = kube.RoleBinding(name) {
  metadata+: {
    namespace: namespace,
    annotations+: {
      'argocd.argoproj.io/hook': 'PreSync',
    },
  },
  subjects_: [ serviceAccount ],
  roleRef_: role,
};

local job = kube.Job(name) {
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
            command: [ 'sh', '-c' ],
            args: [
              |||
                kubectl -n %(namespace)s get clusterserviceversion -ojson \
                  | jq '.items[] | select(.spec.version | test("^%(currentVersion)s[+]") | not) | .metadata.name' \
                  | xargs --no-run-if-empty kubectl -n %(namespace)s delete clusterserviceversions
              ||| % {
                namespace: namespace,
                currentVersion: params.olm.full_version,
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

[ role, serviceAccount, roleBinding, job ]
