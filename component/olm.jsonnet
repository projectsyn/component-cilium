// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local olmDir = 'dependencies/cilium/olm/cilium/cilium-olm/cilium-olm-master/manifests/cilium.v%s/' % params.olm.version;

local olmFiles = std.map(
  function(name) {
    filename: name,
    contents: std.parseJson(kap.yaml_load(olmDir + name)),
  },
  kap.dir_files_list(olmDir)
);

local patchConfig = function(file)
  if file.contents.kind == 'CiliumConfig' && file.contents.metadata.name == 'cilium' && file.contents.metadata.namespace == 'cilium' then
    file {
      contents+: {
        spec: params.cilium_helm_values,
      },
    }
  else
    file;

std.foldl(
  function(files, file) files { [std.strReplace(file.filename, '.yaml', '')]: file.contents },
  std.map(patchConfig, olmFiles),
  {}
)
