-- 032 — Coordinates and approximate distances (spec 032)

-- RF-032-01: coordinates of the company, warehouses and parties (both or none).
ALTER TABLE base.company
    ADD COLUMN latitude  numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
    ADD COLUMN longitude numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    ADD CONSTRAINT company_coordinates CHECK ((latitude IS NULL) = (longitude IS NULL));
ALTER TABLE inventory.warehouse
    ADD COLUMN latitude  numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
    ADD COLUMN longitude numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    ADD CONSTRAINT warehouse_coordinates CHECK ((latitude IS NULL) = (longitude IS NULL));
ALTER TABLE base.party
    ADD COLUMN address   text CHECK (length(address) <= 300),
    ADD COLUMN latitude  numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
    ADD COLUMN longitude numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    ADD CONSTRAINT party_coordinates CHECK ((latitude IS NULL) = (longitude IS NULL));

-- RF-032-02: road distance ≈ straight line × factor; time by average speed. RF-032-04: optional geocoder.
CREATE TABLE base.geo_policy (
    id                 integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    road_factor        numeric(4,2) NOT NULL DEFAULT 1.30 CHECK (road_factor BETWEEN 1 AND 3),
    avg_speed_kmh      numeric(5,1) NOT NULL DEFAULT 50 CHECK (avg_speed_kmh BETWEEN 5 AND 150),
    geocoder_connector text REFERENCES integration.connector(name) ON UPDATE CASCADE ON DELETE SET NULL
);
INSERT INTO base.geo_policy (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Great-circle distance (haversine, mean Earth radius), km; NULL when a point is missing.
CREATE FUNCTION base.distance_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT round((2 * 6371.0088 * asin(sqrt(
             power(sin(radians((lat2 - lat1)::float8) / 2), 2)
           + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lon2 - lon1)::float8) / 2), 2)
           )))::numeric, 2)
$$;

CREATE FUNCTION base.road_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric) RETURNS numeric
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT round(base.distance_km(lat1, lon1, lat2, lon2) * (SELECT road_factor FROM base.geo_policy WHERE id = 1), 1)
$$;

CREATE FUNCTION base.travel_minutes(p_km numeric) RETURNS integer
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT ceil(p_km / (SELECT avg_speed_kmh FROM base.geo_policy WHERE id = 1) * 60)::integer
$$;

-- RF-032-03: freight by distance band (optional; empty = any distance).
ALTER TABLE logistics.freight_rate ADD COLUMN max_km numeric(8,1) CHECK (max_km > 0);
-- The same weight band may now repeat with different distance bands.
ALTER TABLE logistics.freight_rate DROP CONSTRAINT freight_rate_pkey;
CREATE UNIQUE INDEX freight_rate_key ON logistics.freight_rate (carrier_id, region, max_weight_kg, COALESCE(max_km, 0));
