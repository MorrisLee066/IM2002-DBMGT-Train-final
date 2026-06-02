-- ============================================================
--  TransitFlow PostgreSQL Schema
--  Seed data is loaded separately by: python skeleton/seed_postgres.py
--
--  TWO ROLES:
--    1. Relational - dual-network transit data
--    2. Vector     - policy documents for RAG
-- ============================================================

-- ============================================================
--  RELATIONAL SCHEMA
-- ============================================================

-- ----------------------------------------------------------------------------
-- 1. Enumerated types
-- ----------------------------------------------------------------------------
CREATE TYPE direction_enum AS ENUM ('northbound', 'southbound', 'eastbound', 'westbound');
CREATE TYPE service_type_enum AS ENUM ('normal', 'express');
CREATE TYPE ticket_type_enum AS ENUM ('single', 'return', 'day_pass');
CREATE TYPE fare_class_enum AS ENUM ('standard', 'first');
CREATE TYPE booking_status_enum AS ENUM ('confirmed', 'in_transit', 'completed', 'cancelled');
CREATE TYPE payment_method_enum AS ENUM ('credit_card', 'debit_card', 'ewallet');
CREATE TYPE payment_status_enum AS ENUM ('paid', 'refunded', 'failed');

-- ----------------------------------------------------------------------------
-- 2. Users and credentials
-- ----------------------------------------------------------------------------
CREATE TABLE users (
    -- PK justification: application-provided VARCHAR matches mock data IDs such as RU01
    -- and keeps Python seeding/querying simple for this course project.
    user_id       VARCHAR(50) PRIMARY KEY,
    full_name     VARCHAR(200) NOT NULL,
    first_name    VARCHAR(100),
    surname       VARCHAR(100),
    email         VARCHAR(255) UNIQUE NOT NULL,
    phone         VARCHAR(30),
    date_of_birth DATE,
    year_of_birth INTEGER,

    -- Delete strategy: soft delete preserves historical bookings, trips, payments,
    -- and accounting records while allowing the user to be marked inactive.
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_credentials (
    -- PK justification: same user_id as users table enforces a 1:1 credential record.
    user_id            VARCHAR(50) PRIMARY KEY,
    password_hash      VARCHAR(255) NOT NULL,
    secret_question    VARCHAR(255),
    secret_answer_hash VARCHAR(255),

    -- Cascade is appropriate because credentials have no meaning without the user row.
    CONSTRAINT fk_credentials_user
        FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);

-- ----------------------------------------------------------------------------
-- 3. Stations and lines
-- ----------------------------------------------------------------------------
CREATE TABLE metro_stations (
    -- PK justification: station_id is a stable natural key from the mock data, e.g. MS01.
    station_id                   VARCHAR(50) PRIMARY KEY,
    name                         VARCHAR(100) NOT NULL,
    is_interchange_metro         BOOLEAN NOT NULL DEFAULT FALSE,
    is_interchange_national_rail BOOLEAN NOT NULL DEFAULT FALSE,
    interchange_nr_id            VARCHAR(50)
);

CREATE TABLE national_rail_stations (
    -- PK justification: station_id is a stable natural key from the mock data, e.g. NR01.
    station_id                   VARCHAR(50) PRIMARY KEY,
    name                         VARCHAR(100) NOT NULL,
    is_interchange_national_rail BOOLEAN NOT NULL DEFAULT FALSE,
    is_interchange_metro         BOOLEAN NOT NULL DEFAULT FALSE,
    interchange_metro_id         VARCHAR(50),

    -- Set null keeps the station valid if the linked interchange station is removed.
    CONSTRAINT fk_rail_interchange_metro
        FOREIGN KEY (interchange_metro_id) REFERENCES metro_stations(station_id) ON DELETE SET NULL
);

ALTER TABLE metro_stations
    ADD CONSTRAINT fk_metro_interchange_rail
    FOREIGN KEY (interchange_nr_id) REFERENCES national_rail_stations(station_id) ON DELETE SET NULL;

CREATE TABLE metro_lines (
    -- PK justification: line_id is a stable natural key from the mock data, e.g. M1.
    line_id VARCHAR(50) PRIMARY KEY
);

CREATE TABLE metro_station_lines (
    station_id VARCHAR(50) NOT NULL,
    line_id    VARCHAR(50) NOT NULL,

    -- PK justification: a station-line membership is unique by the pair.
    PRIMARY KEY (station_id, line_id),
    CONSTRAINT fk_msl_station FOREIGN KEY (station_id) REFERENCES metro_stations(station_id) ON DELETE CASCADE,
    CONSTRAINT fk_msl_line FOREIGN KEY (line_id) REFERENCES metro_lines(line_id) ON DELETE CASCADE
);

CREATE TABLE national_rail_lines (
    -- PK justification: line_id is a stable natural key from the mock data, e.g. NR1.
    line_id VARCHAR(50) PRIMARY KEY
);

CREATE TABLE national_rail_station_lines (
    station_id VARCHAR(50) NOT NULL,
    line_id    VARCHAR(50) NOT NULL,

    -- PK justification: a station-line membership is unique by the pair.
    PRIMARY KEY (station_id, line_id),
    CONSTRAINT fk_nrsl_station FOREIGN KEY (station_id) REFERENCES national_rail_stations(station_id) ON DELETE CASCADE,
    CONSTRAINT fk_nrsl_line FOREIGN KEY (line_id) REFERENCES national_rail_lines(line_id) ON DELETE CASCADE
);

-- ----------------------------------------------------------------------------
-- 4. Schedules, stops, fares, and seats
-- ----------------------------------------------------------------------------
CREATE TABLE metro_schedules (
    -- PK justification: schedule_id maps directly to mock data IDs such as MS_SCH01.
    schedule_id       VARCHAR(50) PRIMARY KEY,
    line_id           VARCHAR(50) NOT NULL REFERENCES metro_lines(line_id) ON DELETE RESTRICT,
    direction         direction_enum NOT NULL,
    base_fare_usd     NUMERIC(10,2) NOT NULL,
    per_stop_rate_usd NUMERIC(10,2) NOT NULL,
    frequency_min     INTEGER,
    operates_on       TEXT[] NOT NULL,
    CONSTRAINT chk_metro_fares_non_negative CHECK (base_fare_usd >= 0 AND per_stop_rate_usd >= 0)
);

CREATE TABLE national_rail_schedules (
    -- PK justification: schedule_id maps directly to mock data IDs such as NR_SCH01.
    schedule_id   VARCHAR(50) PRIMARY KEY,
    line_id       VARCHAR(50) NOT NULL REFERENCES national_rail_lines(line_id) ON DELETE RESTRICT,
    service_type  service_type_enum NOT NULL,
    direction     direction_enum NOT NULL,
    frequency_min INTEGER,
    operates_on   TEXT[] NOT NULL
);

CREATE TABLE national_rail_fares (
    schedule_id       VARCHAR(50) NOT NULL,
    fare_class        fare_class_enum NOT NULL,
    base_fare_usd     NUMERIC(10,2) NOT NULL,
    per_stop_rate_usd NUMERIC(10,2) NOT NULL,

    -- PK justification: fare is uniquely determined by schedule and fare class.
    PRIMARY KEY (schedule_id, fare_class),
    CONSTRAINT fk_fares_schedule FOREIGN KEY (schedule_id) REFERENCES national_rail_schedules(schedule_id) ON DELETE CASCADE,
    CONSTRAINT chk_rail_fares_non_negative CHECK (base_fare_usd >= 0 AND per_stop_rate_usd >= 0)
);

CREATE TABLE metro_schedule_stops (
    schedule_id                 VARCHAR(50) NOT NULL,
    station_id                  VARCHAR(50) NOT NULL,
    stop_order                  INTEGER NOT NULL,
    travel_time_from_origin_min INTEGER NOT NULL,

    -- PK justification: stop order is unique within each schedule and supports 2NF.
    PRIMARY KEY (schedule_id, stop_order),
    UNIQUE (schedule_id, station_id),
    CONSTRAINT fk_metro_stops_schedule FOREIGN KEY (schedule_id) REFERENCES metro_schedules(schedule_id) ON DELETE CASCADE,
    CONSTRAINT fk_metro_stops_station FOREIGN KEY (station_id) REFERENCES metro_stations(station_id) ON DELETE RESTRICT,
    CONSTRAINT chk_metro_stop_order_positive CHECK (stop_order > 0),
    CONSTRAINT chk_metro_travel_time_non_negative CHECK (travel_time_from_origin_min >= 0)
);

CREATE TABLE national_rail_schedule_stops (
    schedule_id                 VARCHAR(50) NOT NULL,
    station_id                  VARCHAR(50) NOT NULL,
    stop_order                  INTEGER NOT NULL,
    travel_time_from_origin_min INTEGER NOT NULL,

    -- PK justification: stop order is unique within each schedule and supports 2NF.
    PRIMARY KEY (schedule_id, stop_order),
    UNIQUE (schedule_id, station_id),
    CONSTRAINT fk_rail_stops_schedule FOREIGN KEY (schedule_id) REFERENCES national_rail_schedules(schedule_id) ON DELETE CASCADE,
    CONSTRAINT fk_rail_stops_station FOREIGN KEY (station_id) REFERENCES national_rail_stations(station_id) ON DELETE RESTRICT,
    CONSTRAINT chk_rail_stop_order_positive CHECK (stop_order > 0),
    CONSTRAINT chk_rail_travel_time_non_negative CHECK (travel_time_from_origin_min >= 0)
);

CREATE TABLE national_rail_seats (
    schedule_id VARCHAR(50) NOT NULL,
    seat_code   VARCHAR(50) NOT NULL,
    coach       VARCHAR(10) NOT NULL,
    fare_class  fare_class_enum NOT NULL,
    seat_row    INTEGER NOT NULL,
    seat_column VARCHAR(10) NOT NULL,

    -- PK justification: seat codes such as B05 repeat across schedules, so the
    -- composite key uniquely identifies a physical seat on a scheduled service.
    PRIMARY KEY (schedule_id, seat_code),
    CONSTRAINT fk_seats_schedule FOREIGN KEY (schedule_id) REFERENCES national_rail_schedules(schedule_id) ON DELETE CASCADE,
    CONSTRAINT chk_seat_row_positive CHECK (seat_row > 0)
);

-- ----------------------------------------------------------------------------
-- 5. Core transaction tables
-- ----------------------------------------------------------------------------
CREATE TABLE national_rail_bookings (
    -- PK justification: booking_id matches mock data and customer-facing references, e.g. BK001.
    booking_id             VARCHAR(50) PRIMARY KEY,
    user_id                VARCHAR(50) NOT NULL,
    schedule_id            VARCHAR(50) NOT NULL,
    origin_station_id      VARCHAR(50) NOT NULL,
    destination_station_id VARCHAR(50) NOT NULL,
    seat_code              VARCHAR(50) NOT NULL,
    travel_date            DATE NOT NULL,
    departure_time         TIME NOT NULL,
    ticket_type            ticket_type_enum NOT NULL,
    fare_class             fare_class_enum NOT NULL,
    coach                  VARCHAR(10) NOT NULL,

    -- Denormalization justification: cached interval data avoids repeatedly joining
    -- schedule_stops for availability and booking history queries.
    stops_travelled        INTEGER NOT NULL,
    origin_stop_order      INTEGER NOT NULL,
    destination_stop_order INTEGER NOT NULL,

    -- Denormalization justification: amount_usd is a financial snapshot that must
    -- remain stable even if fare rules change later.
    amount_usd             NUMERIC(10,2) NOT NULL,
    refund_amount_usd      NUMERIC(10,2),
    status                 booking_status_enum NOT NULL DEFAULT 'confirmed',
    booked_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    travelled_at           TIMESTAMPTZ,
    cancelled_at           TIMESTAMPTZ,

    CONSTRAINT fk_rail_bookings_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE RESTRICT,
    CONSTRAINT fk_rail_bookings_schedule FOREIGN KEY (schedule_id) REFERENCES national_rail_schedules(schedule_id) ON DELETE RESTRICT,
    CONSTRAINT fk_rail_bookings_origin FOREIGN KEY (origin_station_id) REFERENCES national_rail_stations(station_id) ON DELETE RESTRICT,
    CONSTRAINT fk_rail_bookings_dest FOREIGN KEY (destination_station_id) REFERENCES national_rail_stations(station_id) ON DELETE RESTRICT,
    CONSTRAINT fk_rail_bookings_seat FOREIGN KEY (schedule_id, seat_code) REFERENCES national_rail_seats(schedule_id, seat_code) ON DELETE RESTRICT,
    CONSTRAINT chk_booking_direction CHECK (destination_stop_order > origin_stop_order),
    CONSTRAINT chk_booking_stops_positive CHECK (stops_travelled > 0),
    CONSTRAINT chk_booking_amount_non_negative CHECK (amount_usd >= 0),
    CONSTRAINT chk_booking_refund_non_negative CHECK (refund_amount_usd IS NULL OR refund_amount_usd >= 0)
);

CREATE TABLE metro_trips (
    -- PK justification: trip_id matches mock data and customer-facing references, e.g. MT001.
    trip_id                VARCHAR(50) PRIMARY KEY,
    user_id                VARCHAR(50) NOT NULL,
    schedule_id            VARCHAR(50) REFERENCES metro_schedules(schedule_id) ON DELETE RESTRICT,
    origin_station_id      VARCHAR(50) REFERENCES metro_stations(station_id) ON DELETE RESTRICT,
    destination_station_id VARCHAR(50) REFERENCES metro_stations(station_id) ON DELETE RESTRICT,
    travel_date            DATE NOT NULL,
    ticket_type            ticket_type_enum NOT NULL,

    -- Self-reference justification: later day-pass journeys can point to the original pass purchase.
    day_pass_ref           VARCHAR(50) REFERENCES metro_trips(trip_id) ON DELETE SET NULL,
    stops_travelled        INTEGER,

    -- Denormalization justification: amount_usd is a fare snapshot at purchase time.
    amount_usd             NUMERIC(10,2) NOT NULL,
    status                 booking_status_enum NOT NULL DEFAULT 'in_transit',
    purchased_at           TIMESTAMPTZ,
    travelled_at           TIMESTAMPTZ,

    CONSTRAINT fk_metro_trips_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE RESTRICT,
    CONSTRAINT chk_metro_trip_stops_positive CHECK (stops_travelled IS NULL OR stops_travelled > 0),
    CONSTRAINT chk_metro_trip_amount_non_negative CHECK (amount_usd >= 0)
);

-- ----------------------------------------------------------------------------
-- 6. Payments and feedback
-- ----------------------------------------------------------------------------
CREATE TABLE payments (
    -- PK justification: payment_id matches mock data and support references, e.g. PM001.
    payment_id      VARCHAR(50) PRIMARY KEY,
    rail_booking_id VARCHAR(50) REFERENCES national_rail_bookings(booking_id) ON DELETE RESTRICT,
    metro_trip_id   VARCHAR(50) REFERENCES metro_trips(trip_id) ON DELETE RESTRICT,

    -- Denormalization justification: payment amount is a financial snapshot.
    amount_usd      NUMERIC(10,2) NOT NULL,
    method          payment_method_enum NOT NULL,
    status          payment_status_enum NOT NULL DEFAULT 'paid',
    paid_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Polymorphic association: exactly one target must be present while preserving FK integrity.
    CONSTRAINT chk_payment_polymorphic CHECK (
        (rail_booking_id IS NOT NULL AND metro_trip_id IS NULL) OR
        (rail_booking_id IS NULL AND metro_trip_id IS NOT NULL)
    ),
    CONSTRAINT chk_payment_amount_non_negative CHECK (amount_usd >= 0)
);

CREATE TABLE feedback (
    -- PK justification: feedback_id matches mock data and support references, e.g. FB001.
    feedback_id     VARCHAR(50) PRIMARY KEY,
    user_id         VARCHAR(50) NOT NULL,
    rail_booking_id VARCHAR(50) REFERENCES national_rail_bookings(booking_id) ON DELETE CASCADE,
    metro_trip_id   VARCHAR(50) REFERENCES metro_trips(trip_id) ON DELETE CASCADE,
    rating          INTEGER NOT NULL,
    comment         TEXT,
    submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_feedback_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
    CONSTRAINT chk_feedback_rating_range CHECK (rating >= 1 AND rating <= 5),

    -- Polymorphic association: one feedback row belongs to either one rail booking or one metro trip.
    CONSTRAINT chk_feedback_polymorphic CHECK (
        (rail_booking_id IS NOT NULL AND metro_trip_id IS NULL) OR
        (rail_booking_id IS NULL AND metro_trip_id IS NOT NULL)
    )
);

-- ----------------------------------------------------------------------------
-- 7. Indexes for common lookup paths
-- ----------------------------------------------------------------------------
CREATE INDEX idx_rail_bookings_user ON national_rail_bookings(user_id);
CREATE INDEX idx_rail_bookings_schedule_date ON national_rail_bookings(schedule_id, travel_date);
CREATE INDEX idx_rail_bookings_route ON national_rail_bookings(origin_station_id, destination_station_id);
CREATE INDEX idx_metro_trips_user ON metro_trips(user_id);
CREATE INDEX idx_metro_trips_schedule_date ON metro_trips(schedule_id, travel_date);
CREATE INDEX idx_payments_paid_at ON payments(paid_at);
CREATE INDEX idx_feedback_user ON feedback(user_id);

-- ============================================================
--  VECTOR SCHEMA  (RAG / Help Desk) — do not modify
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS policy_documents (
    id          SERIAL       PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    category    VARCHAR(50)  NOT NULL,  -- 'refund', 'booking', 'conduct'
    content     TEXT         NOT NULL,
    -- 768-dim  → Ollama nomic-embed-text (default)
    -- 3072-dim → Gemini gemini-embedding-001
    -- If you switch LLM_PROVIDER to gemini, change to vector(3072) and reset the database.
    embedding   vector(768),
    source_file VARCHAR(200),
    created_at  TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS policy_documents_embedding_idx
ON policy_documents
USING hnsw (embedding vector_cosine_ops);