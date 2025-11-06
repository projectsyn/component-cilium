local kap = import 'lib/kapitan.libjsonnet';

local ipcalc = import 'lib/cilium-ipcalc.libsonnet';

local inv = kap.inventory();

local test_cases = inv.parameters.test_cases;

local test_parse_cidr(cidrspec) =
  local cidr = ipcalc.parse_cidr('test', cidrspec);
  assert
    std.trace('%s' % [ cidr ], cidr) == test_cases.parse_cidr[cidrspec] :
    'parsing returned unexpected data for %s: %s' % [ cidrspec, cidr ];
  cidr;

{
  parse_cidr: [
    test_parse_cidr(cidr)
    for cidr in std.objectFields(test_cases.parse_cidr)
  ],
}
