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
        This managed resource enables users to configure egress IPs for their
        namespaces by setting annotation `cilium.syn.tools/egress-ip` to an
        egress IP that's within a configured egress range for the cluster.

        Egress ranges are configured via Project Syn with component-cilium.
        The managed resource uses the same configuration which the component
        uses to configure the ranges to determine which range an egress IP
        belongs. If users specify an egress IP that doesn't belong to any
        range, or if overlapping ranges are configured, the managed resource
        emits an error as an annotation on the namespace which requests the
        egress IP.

        If the egress IP can be mapped to a range uniquely, the managed
        resource creates an IsovalenEgressGatewayPolicy which sets the desired
        egress IP for all traffic originating in that namespace. The policy
        uses the same logic as the Commodore component to map the egress IP to
        a Linux interface name.

        Users can change egress IPs for namespaces by editing the
        `cilium.syn.tools/egress-ip` annotation.

        Users can remove egress IPs from namespaces by removing the
        `cilium.syn.tools/egress-ip` annotation (note that setting the
        annotation to an empty string is an error). If the annotation doesn't
        exist anymore, and there's an IsovalentEgressGatewayPolicy that's
        managed by us, this policy is deleted.

        To ensure that the egress IP config is cleaned up when a namespace is
        deleted, the namespace requesting the IP is set as an owner reference
        on the IsovalentEgressGatewayPolicy.
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
