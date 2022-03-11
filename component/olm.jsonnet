// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local olmDir =
  if params.release == 'opensource' then
    'dependencies/cilium/olm/cilium/cilium-olm/cilium-olm-master/manifests/cilium.v%s/' % params.olm.full_version
  else if params.release == 'enterprise' then
    'dependencies/cilium/olm/cilium/cilium-olm/cilium.v%s/' % params.olm.full_version
  else
    error "Unknown release '%s'" % [ params.release ];

local olmFiles = std.map(
  function(name) {
    filename: name,
    contents: std.parseJson(kap.yaml_load(olmDir + name)),
  },
  kap.dir_files_list(olmDir)
);

local patchConfig = function(file)
  local metadata_name_map = {
    opensource: 'cilium',
    enterprise: 'cilium-enterprise',
  };
  if (
    file.contents.kind == 'CiliumConfig'
    && file.contents.metadata.name == metadata_name_map[params.release]
    && file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: {
        spec: params.helm_values,
      },
    }
  else
    file;

std.foldl(
  function(files, file) files { [std.strReplace(file.filename, '.yaml', '')]: file.contents },
  std.map(patchConfig, olmFiles),
  {}
)
