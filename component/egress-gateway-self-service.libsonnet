local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local esp = import 'lib/espejote.libsonnet';

local egw = import 'espejote-templates/egress-gateway.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local sa = kube.ServiceAccount('egress-ip-self-service') {
  metadata+: {
    namespace: params._namespace,
  },
};

local jsonnetlib =
  local config = {
    egress_ranges: [
      params.egress_gateway.egress_ip_ranges[prefix] {
        if_prefix: prefix,
      }
      for prefix in std.objectFields(params.egress_gateway.egress_ip_ranges)
      if params.egress_gateway.egress_ip_ranges[prefix] != null
    ],
  };
  esp.jsonnetLibrary('egress-gateway', params._namespace) {
    spec: {
      data: {
        'egress-gateway.libsonnet': importstr 'espejote-templates/egress-gateway.libsonnet',
        'ipcalc.libsonnet': importstr 'espejote-templates/ipcalc.libsonnet',
        'config.json': std.manifestJson(config),
      },
    },
  };

local clusterrole = kube.ClusterRole('cilium:self-service-egress-ip') {
  rules: [
    {
      apiGroups: [ '' ],
      resources: [ 'namespaces' ],
      verbs: [ 'get', 'list', 'watch', 'patch' ],
    },
    {
      apiGroups: [ 'espejote.io' ],
      resources: [ 'jsonnetlibraries' ],
      verbs: [ 'get', 'list', 'watch' ],
    },
    {
      apiGroups: [ 'isovalent.com' ],
      resources: [ 'isovalentegressgatewaypolicies' ],
      verbs: [ '*' ],
    },
  ],
};

local clusterrolebinding =
  kube.ClusterRoleBinding('cilium:self-service-egress-ip') {
    subjects_: [ sa ],
    roleRef_: clusterrole,
  };

local namespaces_ref = {
  apiVersion: 'v1',
  kind: 'Namespace',
};

local jsonnetlib_ref = {
  apiVersion: jsonnetlib.apiVersion,
  kind: jsonnetlib.kind,
  name: jsonnetlib.metadata.name,
  namespace: jsonnetlib.metadata.namespace,
};

local egress_policies_ref =
  local ep = egw.IsovalentEgressGatewayPolicy('test');
  {
    apiVersion: ep.apiVersion,
    kind: ep.kind,
    labelSelector: {
      matchLabels: egw.espejoteLabel,
    },
  };

local mr = esp.managedResource('namespace-egress-ips', params._namespace) {
  metadata+: {
    annotations: {
      'syn.tools/description': |||
        TODO
      |||,
    },
  },
  spec: {
    serviceAccountRef: { name: sa.metadata.name },
    context: [
      {
        name: 'namespaces',
        resource: namespaces_ref,
      },
      {
        name: 'egress_policies',
        resource: egress_policies_ref,
      },
    ],
    triggers: [
      {
        name: 'namespace',
        watchContextResource: {
          name: 'namespaces',
        },
      },
      {
        name: 'config',
        watchResource: jsonnetlib_ref,
      },
    ],
    template: importstr 'espejote-templates/egress-gateway-self-service.jsonnet',
  },
};

{
  manifests: [ sa, clusterrole, clusterrolebinding, jsonnetlib, mr ],
}
