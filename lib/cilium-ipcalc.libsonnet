// NOTE(sg): This file is symlinked to `component/espejote-templates` in
// component-cilium to allow the `espejote-templates/egress-gateway.libsonnet`
// library to work regardless of whether it's used by Espejote or the
// component. We export this as a component library since it might be useful
// for other components on Cilium-enabled clusters.

// Convert an IPv4 address in A.B.C.D format that's already been split into an
// array to decimal format according to the formula `A*256^3 + B*256^2 + C*256
// + D`. The decimal format allows us to make range comparisons and compute
// offsets into a range.
// Parameter ip can either be the IP as a string, or already split into an
// array holding each dotted part.
local ipval(ip) =
  local iparr =
    if std.type(ip) == 'array' then
      ip
    else
      std.split(ip, '.');
  local iparr_int = std.map(std.parseInt, iparr);

  if std.any(std.map(function(v) v > 255, iparr_int)) then
    error 'Error parsing IPv4 address: %s is not a valid address' % [
      ip,
    ]
  else
    std.foldl(
      function(v, p) v * 256 + p,
      iparr_int,
      0
    );

// Extract start and end from the provided range, stripping any
// whitespace. `prefix` is only used for the error message.
local parse_ip_range(prefix, rangespec) =
  local range_parts = std.map(
    function(s) std.stripChars(s, ' '),
    std.split(rangespec, '-')
  );
  if std.length(range_parts) != 2 then
    error 'Expected IP range for "%s" in format "192.0.2.32-192.0.2.63",  got %s' % [
      prefix,
      rangespec,
    ]
  else
    {
      start: range_parts[0],
      end: range_parts[1],
    };

local format_ipval(val) =
  assert
    val >= 0 && val <= ipval('255.255.255.255')
    : '%s not an IPv4 address in decimal' % val;

  local iparr = std.reverse(std.foldl(
    function(st, i)
      local arr = st.arr;
      local rem = st.rem;
      {
        arr: arr + [ rem % 256 ],
        rem: rem / 256,
      },
    [ 0, 0, 0, 0 ],
    { arr: [], rem: val }
  ).arr);

  std.join('.', std.map(function(v) '%d' % v, iparr));

{
  ipval: ipval,
  parse_ip_range: parse_ip_range,
  parse_cidr: parse_cidr,
  format_ipval: format_ipval,
}
