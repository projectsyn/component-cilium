// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local olmDir = 'dependencies/cilium/olm/cilium/cilium-olm/cilium-olm-master/manifests/cilium.v%s/' % params.olm.version;

local olmFiles = std.map(
  function(name) std.parseJson(kap.yaml_load(olmDir + name)),
  kap.dir_files_list(olmDir)
);

local patchConfig = function(object)
  if object.kind == 'CiliumConfig' && object.metadata.name == 'cilium' && object.metadata.namespace == 'cilium' then
    object {
      spec: params.cilium_helm_values,
    }
  else
    object;

std.map(patchConfig, olmFiles)
