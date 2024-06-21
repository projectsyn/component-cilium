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
  parse_version: parse_version,
}
