local cm = import 'lib/cert-manager.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local self_signed_issuer = cm.issuer('self-signed') {
  metadata+: {
    namespace: params._namespace,
  },
  spec: {
    selfSigned: {},
  },
};

local ca_cert = cm.cert('cilium-ca') {
  metadata+: {
    namespace: params._namespace,
  },
  spec: {
    isCA: true,
    commonName: 'cilium-ca',
    secretName: 'cilium-ca',
    privateKey: {
      algorithm: 'ECDSA',
      size: 256,
    },
    issuerRef: {
      name: 'self-signed',
      kind: 'Issuer',
      group: 'cert-manager.io',
    },
  },
};

local ca_issuer = cm.issuer('cilium-ca') {
  metadata+: {
    namespace: params._namespace,
  },
  spec: {
    ca: {
      secretName: ca_cert.spec.secretName,
    },
  },
};

{
  [if params.deploy_cert_manager_ca then '20_cilium_ca']: [
    self_signed_issuer,
    ca_cert,
    ca_issuer,
  ],
}
