create table if not exists devices(id text primary key, name text, mac_hash text, phone_hash text,
  last_checkin real, power text, battery int, interval_s int);
create table if not exists requests(id text primary key, device_id text, created real, expires real,
  state text, acked_at real, online_at real);
create index if not exists req_dev on requests(device_id, state);
create table if not exists audit(ts real, device_id text, event text, detail text);
