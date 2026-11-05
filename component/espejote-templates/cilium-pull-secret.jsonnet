local esp = import 'espejote.libsonnet';

local read_context_secret(ctxname) =
  if ctxname in esp.context() then
    local secret = esp.context()[ctxname];
    assert std.length(secret) == 1 : 'Expected %s context to have length 1' % ctxname;
    secret[0]
  else
    null;

local config =
  local secret = read_context_secret('isovalent_registry_config');
  assert secret != null : 'Context isovalent_registry_config missing';
  assert
    std.objectHas(secret.data, 'hostname')
    && std.objectHas(secret.data, 'username')
    && std.objectHas(secret.data, 'pull_secret_name')
    : 'Expected Isovalent registry config secret to have fields `hostname`, `username` and `pull_secret_name`';
  {
    [k]: std.base64Decode(secret.data[k])
    for k in std.objectFields(secret.data)
  };

local access_token =
  local steward_token =
    local secret = read_context_secret('steward_token');
    assert secret != null : 'Context steward_token missing';
    assert std.objectHas(secret.data, 'token') : 'Expected Steward token secret to have field `token`';
    std.base64Decode(secret.data.token);
  // NOTE(sg): This should make the template suitable for both 'static' and
  // 'projectsyn' credentials type. We read the access token from the config
  // secret, if it's present (which it is for credentials type 'static'), and
  // fall back to the steward token otherwise.
  std.get(config, 'access_token', std.sha256(steward_token));

{
  apiVersion: 'v1',
  kind: 'Secret',
  metadata: {
    name: config.pull_secret_name,
    namespace: 'openshift-config',
    labels: {
      'pull-secret.openshift-config.syn.tools/include': '',
      'app.kubernetes.io/managed-by': 'espejote',
    },
  },
  type: 'kubernetes.io/dockerconfigjson',
  stringData: {
    '.dockerconfigjson': std.manifestJsonMinified({
      auths: {
        [config.hostname]: {
          auth: std.base64(
            '%(username)s:%(password)s' % {
              username: config.username,
              password: access_token,
            }
          ),
        },
      },
    }),
  },
}
