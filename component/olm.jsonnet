// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local olmDir =
  local prefix = '%s/olm/cilium/cilium-olm/' % inv.parameters._base_directory;
  if params.release == 'opensource' then
    prefix + 'cilium-olm-master/manifests/cilium.v%s/' % params.olm.full_version
  else if params.release == 'enterprise' then
    local newpath = 'tmp/cilium-ee-olm/manifests/';
    local manifests_dir = 'cilium.v%s/' % params.olm.full_version;
    if kap.file_exists(prefix + manifests_dir).exists then
      prefix + manifests_dir
    else if kap.file_exists(prefix + newpath + manifests_dir).exists then
      prefix + newpath + manifests_dir
    else
      error
        'Unable to find manifests path for Cilium EE %s. ' % params.olm.full_version
        + 'Check structure of .tar.gz and update component.'
  else
    error "Unknown release '%s'" % [ params.release ];

local olmFiles = std.map(
  function(name) {
    filename: name,
    contents: std.parseJson(kap.yaml_load(olmDir + name)),
  },
  kap.dir_files_list(olmDir)
);

local patchManifests = function(file)
  local metadata_name_map = {
    opensource: {
      CiliumConfig: 'cilium',
      Deployment: 'cilium-olm',
    },
    enterprise: {
      CiliumConfig: 'cilium-enterprise',
      Deployment: 'cilium-ee-olm',
    },
  };
  local deploymentPatch = {
    spec+: {
      template+: {
        spec+: {
          containers: [
            if c.name == 'operator' then
              c {
                resources+: params.olm.resources,
              }
            else
              c
            for c in super.containers
          ],
        },
      },
    },
  };
  if (
    file.contents.kind == 'CiliumConfig'
    && file.contents.metadata.name == metadata_name_map[params.release].CiliumConfig
    && file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: {
        spec: params.helm_values,
      },
    }
  else if (
    file.contents.kind == 'Deployment'
    && file.contents.metadata.name == metadata_name_map[params.release].Deployment
    && file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: deploymentPatch,
    }
  else if (
    file.contents.kind == 'ClusterServiceVersion' &&
    file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: {
        spec+: {
          install+: {
            spec+: {
              deployments: [
                if d.name == metadata_name_map[params.release].Deployment then
                  d + deploymentPatch
                else
                  d
                for d in super.deployments
              ],
            },
          },
        },
      },
    }
  else if (
    file.contents.kind == 'Subscription' &&
    file.contents.metadata.namespace == 'cilium'
  ) then
    null
  else
    file;

std.foldl(
  function(files, file) files { [std.strReplace(file.filename, '.yaml', '')]: file.contents },
  std.filter(
    function(obj) obj != null,
    std.map(patchManifests, olmFiles),
  ),
  {
    '99_cleanup': (import 'cleanup.libsonnet'),
  }
)
