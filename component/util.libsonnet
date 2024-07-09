local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local isOpenshift = std.member([ 'openshift4', 'oke' ], inv.parameters.facts.distribution);

local parse_version(ver) =
  local verparts = std.split(ver, '.');
  local parseOrError(val, typ) =
    local parsed = std.parseJson(val);
    if std.isNumber(parsed) then
      parsed
    else
      error
        'Failed to parse %s version "%s" as number' % [
          typ,
          val,
        ];
  {
    major: parseOrError(verparts[0], 'major'),
    minor: parseOrError(verparts[1], 'minor'),
  };

{
  isOpenshift: isOpenshift,
  parse_version: parse_version,
}
