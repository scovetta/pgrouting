CREATE DOMAIN wgs84_lat AS double precision CHECK(VALUE >= -180 AND VALUE <= 180);

CREATE DOMAIN wgs84_lon AS double precision CHECK(VALUE >= -90 AND VALUE <= 90);

CREATE DOMAIN gtfstime AS text CHECK(VALUE ~ '^[0-9]?[0-9]:[0-5][0-9]:[0-5][0-9]$');

-- FIXME: Use builtin type Interval to manipulate gtfstime
CREATE FUNCTION gtfstime_to_secs(hms gtfstime) RETURNS INTEGER AS
$$
DECLARE
h INTEGER;
m INTEGER;
s INTEGER;
BEGIN
h = split_part(hms, ':', 1)::INTEGER;
m = split_part(hms, ':', 2)::INTEGER;
s = split_part(hms, ':', 3)::INTEGER;
RETURN 3600 * h + 60 * m + s;
END
$$
LANGUAGE 'plpgsql' IMMUTABLE STRICT;

-- FIXME: Use builtin type Interval to manipulate gtfstime
CREATE FUNCTION secs_to_gtfstime(secs integer) RETURNS gtfstime AS
$$
DECLARE
h INTEGER;
m INTEGER;
s INTEGER;
hms TEXT;
BEGIN
h = secs / 3600;
m = (secs - h * 3600) / 60;
s = secs - h * 3600 - m * 60;
hms = '';
if h < 10 then
    hms = hms || '0';
end if;
hms = hms || h || ':';
if m < 10 then
    hms = hms ||'0';
end if;
hms = hms || m || ':';
if s < 10 then
    hms = hms || '0';
end if;
hms = hms || s;
RETURN hms;
END
$$
LANGUAGE 'plpgsql' IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION prepare_scheduled(gtfs_schema TEXT)
RETURNS VOID
AS
$$
DECLARE
t_id TEXT;
src_id INTEGER;
src_time gtfstime;
dest_id INTEGER;
dest_time gtfstime;
stg_id INTEGER;
old_diff INTEGER;
new_diff INTEGER;
BEGIN
EXECUTE '
  ALTER TABLE ' || gtfs_schema || '.calendar
    ADD COLUMN bitmap bit(7) NULL';
EXECUTE '
  UPDATE ' || gtfs_schema || '.calendar
    SET bitmap = (((((((saturday << 1) + friday << 1) + thursday << 1) +
        wednesday << 1) + tuesday << 1) + monday <<1) + sunday)::bit(7);
  ALTER TABLE ' || gtfs_schema || '.calendar
    ALTER COLUMN bitmap SET NOT NULL';
--TODO: Create a trigger to update calendar bitmap upon insert/update

EXECUTE 'CREATE TABLE ' || gtfs_schema || '.stop_id_map(
    stop_id_int4    SERIAL PRIMARY KEY,
    stop_id_text    TEXT UNIQUE NOT NULL REFERENCES ' || gtfs_schema || '.stops(stop_id)
)';

EXECUTE 'INSERT INTO ' || gtfs_schema || '.stop_id_map(stop_id_text)
    SELECT stop_id FROM ' || gtfs_schema || '.stops';

EXECUTE 'CREATE TABLE ' || gtfs_schema || '.shortest_time_graph(
    id              SERIAL PRIMARY KEY,
    source          INTEGER REFERENCES ' || gtfs_schema || '.stop_id_map(stop_id_int4),
    target          INTEGER REFERENCES ' || gtfs_schema || '.stop_id_map(stop_id_int4),
    travel_time     INTEGER
)';

FOR t_id IN
EXECUTE 'SELECT trip_id FROM ' || gtfs_schema || '.trips'
LOOP
  FOR src_id, src_time IN
  EXECUTE 'SELECT stop_id_int4, departure_time FROM ' ||
           gtfs_schema || '.stop_times JOIN ' ||
           gtfs_schema || '.stop_id_map
           ON stop_id = stop_id_text
           WHERE trip_id = ' || quote_literal(t_id)
  LOOP
    FOR dest_id, dest_time IN
    EXECUTE 'SELECT stop_id_int4, arrival_time FROM ' ||
           gtfs_schema || '.stop_times JOIN ' ||
           gtfs_schema || '.stop_id_map
           ON stop_id = stop_id_text
           WHERE trip_id = ' || quote_literal(t_id) || ' AND
              arrival_time > ' || quote_literal(src_time)
    LOOP
      new_diff := gtfstime_to_secs(dest_time) - gtfstime_to_secs(src_time);
      EXECUTE 'SELECT id, travel_time from ' || gtfs_schema || '.shortest_time_graph
        WHERE source = ' || src_id || ' AND target = ' || dest_id
        INTO stg_id, old_diff;
      IF stg_id IS NULL THEN
        EXECUTE 'INSERT INTO ' || gtfs_schema || '.shortest_time_graph(
          source, target, travel_time) VALUES
          (' ||
            src_id || ',' ||
            dest_id || ',' ||
            new_diff ||
          ')';
      ELSIF old_diff > new_diff THEN
        EXECUTE 'UPDATE ' || gtfs_schema || '.shortest_time_graph
          SET travel_time = ' || new_diff ||
          ' WHERE id = ' || stg_id;
      END IF;
    END LOOP;
  END LOOP;
END LOOP;

END
$$
LANGUAGE 'plpgsql' STRICT;

CREATE OR REPLACE FUNCTION check_service(gtfs_schema TEXT, service_id TEXT, service_timestamp TIMESTAMP, max_wait_time INTERVAL)
RETURNS BOOLEAN
AS
$$
DECLARE
  service_available BOOLEAN;
BEGIN
EXECUTE 'SELECT bitmap & (1<<extract(dow from timestamp ' ||
    quote_literal(service_timestamp) || ')::integer)::bit(7) <> 0::bit(7)
    FROM ' || gtfs_schema || '.calendar
    WHERE service_id = ' || quote_literal(service_id)
  INTO service_available;
RETURN service_timestamp::time < max_wait_time AND service_available;
END
$$
LANGUAGE 'plpgsql' IMMUTABLE STRICT;

CREATE TYPE gtfs_path_result AS (stop_id integer, trip_id TEXT);

CREATE TYPE nonsc_path_result AS (changeover_id TEXT, cost DOUBLE PRECISION);

-----------------------------------------------------------------------
-- Core function for Single Mode Public Transit routing.
-----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION scheduled_route(
        gtfs_schema TEXT,
        source_stop_id INTEGER,
        target_stop_id INTEGER,
        query_time INTEGER 
    )
    RETURNS SETOF gtfs_path_result
    AS '$libdir/libscheduled_route'
    LANGUAGE 'C' IMMUTABLE;
