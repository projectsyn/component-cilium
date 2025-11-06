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

// Parse network in CIDR notation. Leading and trailing whitespace is
// stripped. `prefix` is only used for the error message.
//
// This function correctly parses the full network info from arbitrary IPs in
// CIDR notation. We return an object that's inspired by the output of the
// Linux utility `ipcalc`.
//
// The return value contains the network address, broadcast address, count of
// IPs in the CIDR and prefix length. For prefix lengths of less than 32, the
// return value additionally contains the first and last host (in `min_host`
// and `max_host`) and netmask.
local parse_cidr(prefix, cidr) =
  local parts = std.split(std.stripChars(cidr, ' '), '/');
  if std.length(parts) != 2 then
    error 'Expected value for "%s" to be in CIDR notation, got "%s"' % [
      prefix,
      cidr,
    ]
  else
    local prefix_length = std.parseInt(parts[1]);
    if prefix_length < 0 || prefix_length > 32 then
      error 'Invalid CIDR %s: prefix must be between 0 and 32' % cidr
    else
      // We compute count, netmask and network address using bitwise operations.
      // Jsonnet uses 64 bit integers for bitwise ops, so we don't have to worry
      // about overflowing when working with 32 bit values (IPv4 addresses).
      //
      // IPv4 CIDR notation works as follows: <addr>/<prefix> defines a network
      // where the first <prefix> bits of the IP are the "network" and the last
      // 32-<prefix> bits are (mostly) freely selectable for addresses within
      // that network.
      //
      // Bitwise glossary:
      //  - (1 << n) == 2**n
      //  - `&` is bitwise and (setting all bits that are set in either operand)
      //  - `~` is bitwise not (flipping all bits of the operand)
      // Jsonnet operator precedence: binary +- bind higher than shifts

      // count is the number of available addresses (including the network and
      // broadcast address in the network). It's a value which has the
      // 32-<prefix> low bits set to 1 and all other bits set to 0.
      local count = (1 << 32 - prefix_length) - 1;
      // Netmask has the high <prefix> bits set to one and the 32-<prefix> low
      // bits set to 0. We can use `~count` as the mask to set the low
      // 32-<prefix> bits to 0, since count has only these bits set to 1 and
      // bitwise not flips all bits.
      local netmask = ((1 << 32) - 1) & ~count;
      // The network address is the first address in the network. By converting
      // the specified <addr> to an integer and using the netmask to set the low
      // 32-<prefix> bits to 0 we reliably get the network address regardless of
      // which IP in the network that the user specified for a given prefix.
      local net_addr = ipval(parts[0]) & netmask;

      {
        network_address: format_ipval(net_addr),
        broadcast_address: format_ipval(net_addr + count),
        prefix_length: prefix_length,
        count: count,
      } + if prefix_length < 32 then {
        host_min: format_ipval(net_addr + 1),
        host_max: format_ipval(net_addr + count - 1),
        netmask: format_ipval(netmask),
      } else {};

{
  ipval: ipval,
  parse_ip_range: parse_ip_range,
  parse_cidr: parse_cidr,
  format_ipval: format_ipval,
}
