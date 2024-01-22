// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local olmDir =
  local prefix = '%s/olm/cilium/cilium-olm/' % inv.parameters._base_directory;
  if params.release == 'opensource' then
    prefix + 'olm-for-cilium-main/manifests/cilium.v%s/' % params.olm.full_version
  else if params.release == 'enterprise' then
    local path_variants = [
      // Known releases: 1.11.5, 1.12.6
      '',
      // Known releases: 1.11.17
      'tmp/cilium-ee-olm/manifests/',
      // Known releases: 1.13.2
      'cilium-ee-olm/manifests/',
    ];
    local manifests_dir = 'cilium.v%s/' % params.olm.full_version;
    local dir = std.foldl(
      function(curr, variant)
        local cand = prefix + variant + manifests_dir;
        if kap.file_exists(cand).exists then
          cand
        else
          curr,
      path_variants,
      null
    );
    if dir == null then
      error
        'Unable to find manifests path for Cilium EE %s. ' % params.olm.full_version
        + 'Check structure of .tar.gz and update component.'
    else
      dir
  else
    error "Unknown release '%s'" % [ params.release ];

local olmFiles = std.filterMap(
  function(name)
    // drop hidden files
    !std.startsWith(name, '.'),
  function(name) {
    filename: name,
    contents: std.parseJson(kap.yaml_load(olmDir + name)),
  },
  kap.dir_files_list(olmDir)
);

local patchManifests = function(file)
  local hasK8sHost = std.objectHas(params.cilium_helm_values, 'k8sServiceHost');
  local hasK8sPort = std.objectHas(params.cilium_helm_values, 'k8sServicePort');
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
                env+:
                  if params.release == 'opensource' then
                    (
                      if hasK8sHost then
                        [
                          {
                            name: 'KUBERNETES_SERVICE_HOST',
                            value: params.cilium_helm_values.k8sServiceHost,
                          },
                        ]
                      else []
                    ) + (
                      if hasK8sPort then
                        [
                          {
                            name: 'KUBERNETES_SERVICE_PORT',
                            value: params.cilium_helm_values.k8sServicePort,
                          },
                        ]
                      else []
                    )
                  else [],
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
    params.release == 'enterprise'
    && file.contents.kind == 'ConfigMap'
    && file.contents.metadata.name == 'cilium-ee-olm-overrides'
    && file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: {
        data+: {
          [if hasK8sHost then 'KUBERNETES_SERVICE_HOST']:
            params.cilium_helm_values.k8sServiceHost,
          [if hasK8sPort then 'KUBERNETES_SERVICE_PORT']:
            params.cilium_helm_values.k8sServicePort,
        },
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
