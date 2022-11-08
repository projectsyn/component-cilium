local kube = import 'lib/kube.libjsonnet';

local ciliumRule(resources) =
  {
    apiGroups: [ 'cilium.io' ],
    resources: resources,
    verbs: [
      'get',
      'list',
      'watch',
    ],
  };

local view = kube.ClusterRole('syn-cilium-view') {
  metadata+: {
    labels+: {
      'rbac.authorization.k8s.io/aggregate-to-view': 'true',
      'rbac.authorization.k8s.io/aggregate-to-edit': 'true',
      'rbac.authorization.k8s.io/aggregate-to-admin': 'true',
    },
  },
  rules: [
    // ciliumnetworkpolicies and ciliumendpoints are namespace-scoped, so we
    // aggregate them to `view`, `ciliumconfigs` as well, but the operator
    // already creates aggregations for that one.
    ciliumRule([ 'networkpolicies', 'ciliumendpoints' ]),
  ],
};

local edit = kube.ClusterRole('syn-cilium-edit') {
  metadata+: {
    labels+: {
      'rbac.authorization.k8s.io/aggregate-to-edit': 'true',
      'rbac.authorization.k8s.io/aggregate-to-admin': 'true',
    },
  },
  rules: [
    // ciliumnetworkpolicies and ciliumendpoints are namespace-scoped, so we
    // aggregate them to `view`, `ciliumconfigs` as well, but the operator
    // already creates aggregations for that one.
    ciliumRule([ 'networkpolicies' ]) {
      verbs: [
        'create',
        'delete',
        'deletecollection',
        'patch',
        'update',
      ],
    },
  ],
};

local cluster_reader = kube.ClusterRole('syn-cilium-cluster-reader') {
  metadata+: {
    labels+: {
      'rbac.authorization.k8s.io/aggregate-to-cluster-reader': 'true',
    },
  },
  rules: [
    // We could explicitly list and maintain cluster-scoped resources here, but
    // that's overhead we don't really need, so we just grant "view" permissions
    // on all resources in `cilium.io` to `cluster-reader`.
    ciliumRule([ '*' ]),
  ],
};

{
  '02_aggregated_clusterroles': [
    view,
    edit,
    cluster_reader,
  ],
}
