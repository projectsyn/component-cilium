local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local util = import 'util.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local fullReplacement = std.member(
  [ 'strict', 'true' ],
  params.cilium_helm_values.kubeProxyReplacement
);
local metadataPatch = {
  annotations+: {
    'syn.tools/source': 'https://github.com/projectsyn/component-cilium.git',
  },
  labels+: {
    'app.kubernetes.io/managed-by': 'espejote',
    'app.kubernetes.io/part-of': 'syn',
    'app.kubernetes.io/component': 'cilium',
  },
};

local patch = {
  apiVersion: 'operator.openshift.io/v1',
  kind: 'Network',
  metadata: {
    name: 'cluster',
  },
  spec: {
    deployKubeProxy: !fullReplacement,
  },
};

if util.isOpenshift then
  {
    '99_networkoperator_kube_proxy_patch': [
      obj {
        metadata+: metadataPatch,
      }
      for obj in esp.clusterScopedObject(
        inv.parameters.espejote.namespace,
        patch
      )
    ],
  }
else
  {}
