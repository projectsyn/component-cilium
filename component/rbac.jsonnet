local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local hubble_subjects =
  assert
    std.all([ v == null || v == {} for v in std.objectValues(params.hubble_access.port_forward_users) ])
    : 'Expected user values to be null or empty objects';
  assert
    std.all([ v == null || v == {} for v in std.objectValues(params.hubble_access.port_forward_groups) ])
    : 'Expected group values to be null or empty objects';
  com.generateResources(
    params.hubble_access.port_forward_users,
    function(username) {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'User',
      name: username,
    },
  ) + com.generateResources(
    params.hubble_access.port_forward_groups,
    function(groupname) {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'Group',
      name: groupname,
    },
  );

local hubble_portforward_role = kube.Role('syn:hubble-port-forward') {
  metadata+: {
    namespace: params._namespace,
  },
  rules: [
    {
      apiGroups: [ '' ],
      resources: [ 'pods/portforward' ],
      verbs: [ 'create' ],
    },
  ],
};

local hubble_portforward_rolebinding = kube.RoleBinding('syn:hubble-port-forward') {
  metadata+: {
    namespace: params._namespace,
  },
  roleRef_: hubble_portforward_role,
  subjects: hubble_subjects,
};

local hubble_rbac = [
  hubble_portforward_role,
  hubble_portforward_rolebinding,
];

{
  [if std.length(hubble_subjects) > 0 then '30_hubble_rbac']: hubble_rbac,
}
