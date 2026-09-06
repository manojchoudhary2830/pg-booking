-- Migration: 001_extensions_enums_users
-- Created: 2026-01-01
-- Description: Load extensions, create all custom enum types, and core users table

-- ─────────────────────────────────────────────
-- Extensions
-- ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- for fuzzy text search

-- ─────────────────────────────────────────────
-- Custom Enum Types
-- ─────────────────────────────────────────────
CREATE TYPE user_role_enum AS ENUM ('TENANT', 'OWNER', 'SYSTEM_ADMIN');
CREATE TYPE gender_policy_enum AS ENUM ('MALE', 'FEMALE', 'CO_LIVING');
CREATE TYPE bed_status_enum AS ENUM ('VACANT', 'RESERVED', 'OCCUPIED');
CREATE TYPE booking_status_enum AS ENUM ('PENDING', 'CONFIRMED', 'CANCELLED', 'CHECKED_OUT');
CREATE TYPE payment_purpose_enum AS ENUM ('TOKEN_DEPOSIT', 'MONTHLY_RENT', 'SECURITY_DEPOSIT', 'UTILITY_ARREARS', 'REFUND');
CREATE TYPE payment_status_enum AS ENUM ('PENDING', 'PROCESSING', 'SUCCESSFUL', 'FAILED', 'REFUNDED');
CREATE TYPE kyc_status_enum AS ENUM ('UNVERIFIED', 'PENDING_REVIEW', 'VERIFIED', 'REJECTED');
CREATE TYPE kyc_doc_type_enum AS ENUM ('AADHAAR', 'PAN_CARD', 'PASSPORT', 'DRIVING_LICENSE', 'VOTER_ID');
CREATE TYPE maintenance_status_enum AS ENUM ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED');
CREATE TYPE maintenance_category_enum AS ENUM ('PLUMBING', 'ELECTRICAL', 'FURNITURE', 'CLEANING', 'INTERNET', 'APPLIANCE', 'SECURITY', 'OTHER');
CREATE TYPE notification_type_enum AS ENUM ('OTP', 'BOOKING_CREATED', 'BOOKING_CONFIRMED', 'BOOKING_CANCELLED', 'PAYMENT_RECEIVED', 'PAYMENT_DUE', 'PAYMENT_OVERDUE', 'MAINTENANCE_CREATED', 'MAINTENANCE_UPDATED', 'KYC_APPROVED', 'KYC_REJECTED', 'PROPERTY_APPROVED', 'RENT_INVOICE', 'GENERAL');
CREATE TYPE notification_channel_enum AS ENUM ('PUSH', 'EMAIL', 'SMS', 'IN_APP');
CREATE TYPE property_verification_status_enum AS ENUM ('PENDING', 'VERIFIED', 'REJECTED', 'SUSPENDED');

-- ─────────────────────────────────────────────
-- Timestamp trigger function (reusable)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────
-- Table: users
-- ─────────────────────────────────────────────
CREATE TABLE users (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  phone_number          VARCHAR(15)  UNIQUE NOT NULL,
  email_address         VARCHAR(255) UNIQUE,
  legal_full_name       VARCHAR(120) NOT NULL,
  account_role          user_role_enum NOT NULL DEFAULT 'TENANT',
  identity_kyc_status   kyc_status_enum NOT NULL DEFAULT 'UNVERIFIED',
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,
  last_login_at         TIMESTAMPTZ,
  profile_photo_key     VARCHAR(500),
  fcm_token             VARCHAR(500),    -- Firebase Cloud Messaging device token
  device_id             VARCHAR(255),
  record_created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  record_updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at            TIMESTAMPTZ    -- soft delete
);

CREATE TRIGGER users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Indexes
CREATE INDEX idx_users_phone           ON users(phone_number) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_email           ON users(email_address) WHERE email_address IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_users_role            ON users(account_role) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_kyc_status      ON users(identity_kyc_status) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_active          ON users(is_active) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_deleted_at      ON users(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX idx_users_name_trgm       ON users USING GIN(legal_full_name gin_trgm_ops);

COMMENT ON TABLE users IS 'Core user accounts for all roles (TENANT, OWNER, SYSTEM_ADMIN)';
COMMENT ON COLUMN users.deleted_at IS 'Soft-delete timestamp. NULL = active record.';
COMMENT ON COLUMN users.fcm_token IS 'Firebase Cloud Messaging token for push notifications';
-- Migration: 002_auth_tables
-- Description: OTP attempt tracking and refresh token management

-- ─────────────────────────────────────────────
-- Table: otp_logs
-- ─────────────────────────────────────────────
CREATE TABLE otp_logs (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  phone_number     VARCHAR(15) NOT NULL,
  otp_hash         VARCHAR(64) NOT NULL,
  attempts         SMALLINT NOT NULL DEFAULT 0,
  is_used          BOOLEAN NOT NULL DEFAULT FALSE,
  is_locked        BOOLEAN NOT NULL DEFAULT FALSE,
  lock_expires_at  TIMESTAMPTZ,
  ip_address       INET,
  expires_at       TIMESTAMPTZ NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  used_at          TIMESTAMPTZ
);

-- FIX: NOW() is a volatile function — cannot be used in index predicates (ERROR 42P17).
-- The application layer enforces expiry; this index only prevents duplicate active OTPs.
CREATE UNIQUE INDEX idx_otp_logs_phone_active
  ON otp_logs(phone_number)
  WHERE is_used = FALSE;

CREATE INDEX idx_otp_logs_phone      ON otp_logs(phone_number);
CREATE INDEX idx_otp_logs_expires_at ON otp_logs(expires_at);
CREATE INDEX idx_otp_logs_created_at ON otp_logs(created_at DESC);

COMMENT ON TABLE otp_logs IS 'OTP generation, verification attempts, and lockout state per phone number.';
COMMENT ON COLUMN otp_logs.otp_hash IS 'SHA-256(otp). Never stored in plaintext.';

-- ─────────────────────────────────────────────
-- Table: refresh_tokens
-- ─────────────────────────────────────────────
CREATE TABLE refresh_tokens (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash        VARCHAR(64) NOT NULL UNIQUE,
  token_family      UUID NOT NULL,
  expires_at        TIMESTAMPTZ NOT NULL,
  is_revoked        BOOLEAN NOT NULL DEFAULT FALSE,
  revoked_at        TIMESTAMPTZ,
  revocation_reason VARCHAR(100),
  device_info       JSONB,
  ip_address        INET,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_refresh_tokens_user_id     ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_tokens_token_hash  ON refresh_tokens(token_hash);
CREATE INDEX idx_refresh_tokens_family      ON refresh_tokens(token_family);
CREATE INDEX idx_refresh_tokens_expires_at  ON refresh_tokens(expires_at) WHERE is_revoked = FALSE;
CREATE INDEX idx_refresh_tokens_user_active ON refresh_tokens(user_id)    WHERE is_revoked = FALSE;

COMMENT ON TABLE refresh_tokens IS 'Refresh token storage with rotation. token_family enables reuse-attack detection.';
-- Migration: 003_properties
-- Description: Property listings with PostGIS geometry and photo management

-- ─────────────────────────────────────────────
-- Table: properties
-- ─────────────────────────────────────────────
CREATE TABLE properties (
  id                              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  landlord_owner_id               UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  property_display_name           VARCHAR(150) NOT NULL,
  descriptive_summary             TEXT,
  physical_address_line           TEXT NOT NULL,
  municipality_city               VARCHAR(100) NOT NULL,
  state                           VARCHAR(100) NOT NULL DEFAULT 'Karnataka',
  pincode                         VARCHAR(10),
  geo_coordinate_point            GEOMETRY(Point, 4326) NOT NULL,
  gender_segregation_policy       gender_policy_enum NOT NULL,
  structural_amenities            TEXT[] NOT NULL DEFAULT '{}',
  rules_and_policies              TEXT,
  total_floors                    SMALLINT,
  established_year                SMALLINT,
  is_listing_verified_by_admin    BOOLEAN NOT NULL DEFAULT FALSE,
  verification_status             property_verification_status_enum NOT NULL DEFAULT 'PENDING',
  verification_notes              TEXT,
  verified_by_admin_id            UUID REFERENCES users(id) ON DELETE SET NULL,
  verified_at                     TIMESTAMPTZ,
  is_active                       BOOLEAN NOT NULL DEFAULT TRUE,

  -- Denormalized counters (updated via triggers) for fast listing queries
  total_beds                      SMALLINT NOT NULL DEFAULT 0,
  vacant_beds                     SMALLINT NOT NULL DEFAULT 0,
  min_rent                        NUMERIC(12,2),
  max_rent                        NUMERIC(12,2),

  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at                      TIMESTAMPTZ
);

CREATE TRIGGER properties_updated_at
  BEFORE UPDATE ON properties
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─────────────────────────────────────────────
-- Indexes on properties
-- ─────────────────────────────────────────────

-- Primary geospatial index (GiST for ST_DWithin radius searches)
CREATE INDEX idx_properties_geo_gist
  ON properties USING GIST(geo_coordinate_point)
  WHERE deleted_at IS NULL AND is_active = TRUE;

CREATE INDEX idx_properties_owner
  ON properties(landlord_owner_id) WHERE deleted_at IS NULL;

CREATE INDEX idx_properties_city
  ON properties(municipality_city) WHERE deleted_at IS NULL AND is_active = TRUE;

CREATE INDEX idx_properties_gender_policy
  ON properties(gender_segregation_policy) WHERE deleted_at IS NULL;

CREATE INDEX idx_properties_verification
  ON properties(verification_status) WHERE deleted_at IS NULL;

CREATE INDEX idx_properties_vacant_beds
  ON properties(vacant_beds) WHERE deleted_at IS NULL AND is_active = TRUE;

CREATE INDEX idx_properties_rent_range
  ON properties(min_rent, max_rent) WHERE deleted_at IS NULL;

-- Text search on property name and city
CREATE INDEX idx_properties_name_trgm
  ON properties USING GIN(property_display_name gin_trgm_ops);

CREATE INDEX idx_properties_city_trgm
  ON properties USING GIN(municipality_city gin_trgm_ops);

-- Composite for common owner dashboard query
CREATE INDEX idx_properties_owner_status
  ON properties(landlord_owner_id, verification_status) WHERE deleted_at IS NULL;

COMMENT ON TABLE properties IS 'PG / co-living property listings with PostGIS coordinates.';
COMMENT ON COLUMN properties.geo_coordinate_point IS 'PostGIS POINT(longitude latitude) in WGS84 (SRID 4326).';
COMMENT ON COLUMN properties.total_beds IS 'Denormalized. Updated by trigger when beds are created/deleted.';
COMMENT ON COLUMN properties.vacant_beds IS 'Denormalized. Updated by trigger when bed status changes.';

-- ─────────────────────────────────────────────
-- Table: property_photos
-- ─────────────────────────────────────────────
CREATE TABLE property_photos (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  property_id   UUID NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  s3_key        VARCHAR(500) NOT NULL,
  thumbnail_key VARCHAR(500),
  medium_key    VARCHAR(500),
  caption       VARCHAR(200),
  sort_order    SMALLINT NOT NULL DEFAULT 0,
  is_cover      BOOLEAN NOT NULL DEFAULT FALSE,
  uploaded_by   UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enforce only one cover photo per property
CREATE UNIQUE INDEX idx_property_photos_cover
  ON property_photos(property_id)
  WHERE is_cover = TRUE;

CREATE INDEX idx_property_photos_property
  ON property_photos(property_id, sort_order);

COMMENT ON TABLE property_photos IS 'S3-backed property photos with multiple image variants.';

-- NOTE: update_property_bed_counters() is defined in migration 004
-- (after the beds table exists) because it references the beds table.
-- Migration: 004_rooms_beds
-- Description: Room and bed inventory with cascade triggers for property counters

-- ─────────────────────────────────────────────
-- Table: rooms
-- ─────────────────────────────────────────────
CREATE TABLE rooms (
  id                                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  property_parent_id                UUID NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_identifier_code              VARCHAR(30) NOT NULL,
  floor_level_index                 SMALLINT NOT NULL DEFAULT 0,
  max_occupancy_sharing_limit       SMALLINT NOT NULL CHECK (max_occupancy_sharing_limit BETWEEN 1 AND 10),
  standard_monthly_rent_amount      NUMERIC(12,2) NOT NULL CHECK (standard_monthly_rent_amount > 0),
  required_security_deposit_amount  NUMERIC(12,2) NOT NULL CHECK (required_security_deposit_amount >= 0),
  token_deposit_amount              NUMERIC(12,2) GENERATED ALWAYS AS (required_security_deposit_amount * 0.20) STORED,
  room_type                         VARCHAR(50),  -- e.g. 'AC', 'NON_AC', 'DELUXE'
  amenities                         TEXT[] NOT NULL DEFAULT '{}',
  is_active                         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_room_code_per_property UNIQUE (property_parent_id, room_identifier_code)
);

CREATE TRIGGER rooms_updated_at
  BEFORE UPDATE ON rooms
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Update property rent range when room rent changes
CREATE OR REPLACE FUNCTION trigger_update_property_on_room_change()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM update_property_bed_counters(OLD.property_parent_id);
  ELSE
    PERFORM update_property_bed_counters(NEW.property_parent_id);
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER rooms_property_counter_sync
  AFTER INSERT OR UPDATE OF standard_monthly_rent_amount OR DELETE ON rooms
  FOR EACH ROW EXECUTE FUNCTION trigger_update_property_on_room_change();

CREATE INDEX idx_rooms_property       ON rooms(property_parent_id) WHERE is_active = TRUE;
CREATE INDEX idx_rooms_floor          ON rooms(property_parent_id, floor_level_index);
CREATE INDEX idx_rooms_rent           ON rooms(standard_monthly_rent_amount);
CREATE INDEX idx_rooms_sharing        ON rooms(max_occupancy_sharing_limit);

COMMENT ON TABLE rooms IS 'Individual rooms within a property. Token deposit = 20% of security deposit (computed column).';
COMMENT ON COLUMN rooms.token_deposit_amount IS 'Auto-computed: 20% of required_security_deposit_amount per PRD spec.';

-- ─────────────────────────────────────────────
-- Table: beds
-- ─────────────────────────────────────────────
CREATE TABLE beds (
  id                        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  room_parent_id            UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  bed_spatial_code          VARCHAR(30) NOT NULL,
  current_occupancy_status  bed_status_enum NOT NULL DEFAULT 'VACANT',
  last_modified_timestamp   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_bed_code_per_room UNIQUE (room_parent_id, bed_spatial_code)
);

-- ─────────────────────────────────────────────
-- Function: update_property_bed_counters
-- Defined here (not in 003) because it references the beds table.
-- Called by triggers on both beds and rooms tables.
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_property_bed_counters(property_id_arg UUID)
RETURNS VOID AS $$
  UPDATE properties p
  SET
    total_beds  = (SELECT COUNT(*) FROM beds b JOIN rooms r ON r.id = b.room_parent_id WHERE r.property_parent_id = p.id),
    vacant_beds = (SELECT COUNT(*) FROM beds b JOIN rooms r ON r.id = b.room_parent_id WHERE r.property_parent_id = p.id AND b.current_occupancy_status = 'VACANT'),
    min_rent    = (SELECT MIN(r2.standard_monthly_rent_amount) FROM rooms r2 WHERE r2.property_parent_id = p.id),
    max_rent    = (SELECT MAX(r2.standard_monthly_rent_amount) FROM rooms r2 WHERE r2.property_parent_id = p.id),
    updated_at  = NOW()
  WHERE p.id = property_id_arg;
$$ LANGUAGE sql;

-- ─────────────────────────────────────────────
-- Trigger: Sync property bed counters when bed status changes
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trigger_sync_property_bed_counters()
RETURNS TRIGGER AS $$
DECLARE
  v_property_id UUID;
BEGIN
  -- Get the property ID via the room
  SELECT r.property_parent_id INTO v_property_id
  FROM rooms r
  WHERE r.id = COALESCE(NEW.room_parent_id, OLD.room_parent_id);

  -- Update timestamps
  IF TG_OP = 'UPDATE' THEN
    NEW.last_modified_timestamp = NOW();
  END IF;

  PERFORM update_property_bed_counters(v_property_id);
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER beds_sync_property_counters
  AFTER INSERT OR UPDATE OF current_occupancy_status OR DELETE ON beds
  FOR EACH ROW EXECUTE FUNCTION trigger_sync_property_bed_counters();

-- ─────────────────────────────────────────────
-- Indexes on beds
-- ─────────────────────────────────────────────

-- Operational lookup: find vacant beds in a room
CREATE INDEX idx_beds_room_status
  ON beds(room_parent_id, current_occupancy_status);

-- For booking engine: find a specific bed status quickly
CREATE INDEX idx_beds_status
  ON beds(current_occupancy_status);

-- For joining to get property info quickly
CREATE INDEX idx_beds_room
  ON beds(room_parent_id);

COMMENT ON TABLE beds IS 'Individual bed inventory units. Status changes trigger property counter updates.';

-- ─────────────────────────────────────────────
-- View: available_beds_with_room_details
-- Used by search and booking engine
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW available_beds_with_room_details AS
SELECT
  b.id                                  AS bed_id,
  b.bed_spatial_code,
  b.current_occupancy_status,
  r.id                                  AS room_id,
  r.room_identifier_code,
  r.floor_level_index,
  r.max_occupancy_sharing_limit,
  r.standard_monthly_rent_amount        AS monthly_rent,
  r.required_security_deposit_amount    AS security_deposit,
  r.token_deposit_amount,
  r.room_type,
  r.amenities                           AS room_amenities,
  p.id                                  AS property_id,
  p.property_display_name,
  p.municipality_city,
  p.gender_segregation_policy,
  p.structural_amenities,
  ST_Y(p.geo_coordinate_point::geometry) AS latitude,
  ST_X(p.geo_coordinate_point::geometry) AS longitude
FROM beds b
JOIN rooms r ON r.id = b.room_parent_id AND r.is_active = TRUE
JOIN properties p ON p.id = r.property_parent_id
  AND p.is_active = TRUE
  AND p.deleted_at IS NULL
  AND p.verification_status = 'VERIFIED'
WHERE b.current_occupancy_status = 'VACANT';

COMMENT ON VIEW available_beds_with_room_details IS 'Denormalized view of all vacant beds with full room and property context. Used by booking engine and search.';
-- Migration: 005_bookings_payments
-- Description: Bookings ledger and financial transactions with idempotency

-- ─────────────────────────────────────────────
-- Table: bookings
-- ─────────────────────────────────────────────
CREATE TABLE bookings (
  id                              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_user_id                  UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  assigned_bed_id                 UUID NOT NULL REFERENCES beds(id) ON DELETE RESTRICT,
  current_booking_lifecycle_state booking_status_enum NOT NULL DEFAULT 'PENDING',
  scheduled_check_in_date         DATE NOT NULL,
  scheduled_check_out_date        DATE,
  token_fee_amount_paid           NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  security_deposit_amount         NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  monthly_rent_amount             NUMERIC(12,2) NOT NULL,

  -- Reservation lock management
  reservation_lock_expires_at     TIMESTAMPTZ,
  lock_redis_key                  VARCHAR(200),  -- the Redis lock key for cleanup

  -- Idempotency: prevent duplicate booking initiation
  idempotency_key                 VARCHAR(100) UNIQUE,

  -- Cancellation
  cancelled_at                    TIMESTAMPTZ,
  cancellation_reason             TEXT,
  cancelled_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,

  -- Checkout
  actual_check_out_date           DATE,
  checkout_notes                  TEXT,

  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at                      TIMESTAMPTZ
);

CREATE TRIGGER bookings_updated_at
  BEFORE UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─────────────────────────────────────────────
-- Indexes on bookings
-- ─────────────────────────────────────────────

CREATE INDEX idx_bookings_tenant
  ON bookings(tenant_user_id) WHERE deleted_at IS NULL;

CREATE INDEX idx_bookings_bed
  ON bookings(assigned_bed_id) WHERE deleted_at IS NULL;

CREATE INDEX idx_bookings_status
  ON bookings(current_booking_lifecycle_state) WHERE deleted_at IS NULL;

CREATE INDEX idx_bookings_tenant_status
  ON bookings(tenant_user_id, current_booking_lifecycle_state) WHERE deleted_at IS NULL;

CREATE INDEX idx_bookings_lock_expires
  ON bookings(reservation_lock_expires_at)
  WHERE current_booking_lifecycle_state = 'PENDING'
    AND reservation_lock_expires_at IS NOT NULL;

CREATE INDEX idx_bookings_check_in
  ON bookings(scheduled_check_in_date) WHERE deleted_at IS NULL;

CREATE INDEX idx_bookings_idempotency
  ON bookings(idempotency_key) WHERE idempotency_key IS NOT NULL;

COMMENT ON TABLE bookings IS 'Central booking ledger. PENDING = reservation held. CONFIRMED = payment complete.';
COMMENT ON COLUMN bookings.idempotency_key IS 'Client-supplied key to prevent duplicate booking submissions.';
COMMENT ON COLUMN bookings.reservation_lock_expires_at IS '10-minute window. Bed returns to VACANT if payment not completed.';

-- ─────────────────────────────────────────────
-- Table: payments
-- ─────────────────────────────────────────────
CREATE TABLE payments (
  id                              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_context_id              UUID REFERENCES bookings(id) ON DELETE SET NULL,
  payer_user_id                   UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  exact_financial_amount          NUMERIC(12,2) NOT NULL CHECK (exact_financial_amount > 0),
  currency_code                   VARCHAR(3) NOT NULL DEFAULT 'INR',
  transaction_clearance_status    payment_status_enum NOT NULL DEFAULT 'PENDING',
  financial_payment_purpose       payment_purpose_enum NOT NULL,

  -- Razorpay references
  payment_gateway_order_id        VARCHAR(255) UNIQUE,   -- Razorpay order ID (order_xxx)
  payment_gateway_external_id     VARCHAR(255) UNIQUE,   -- Razorpay payment ID (pay_xxx)
  gateway_signature               VARCHAR(500),          -- HMAC signature from Razorpay

  -- Idempotency (prevent duplicate webhook processing)
  idempotency_key                 VARCHAR(100) UNIQUE NOT NULL,

  -- Failure info
  failure_reason                  VARCHAR(300),
  failure_code                    VARCHAR(100),

  -- Refund info
  refunded_at                     TIMESTAMPTZ,
  refund_gateway_id               VARCHAR(255),
  refund_amount                   NUMERIC(12,2),

  -- Raw gateway response for audit
  gateway_response                JSONB,

  transaction_timestamp           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER payments_updated_at
  BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─────────────────────────────────────────────
-- Indexes on payments
-- ─────────────────────────────────────────────

CREATE INDEX idx_payments_booking
  ON payments(booking_context_id);

CREATE INDEX idx_payments_payer
  ON payments(payer_user_id);

CREATE INDEX idx_payments_status
  ON payments(transaction_clearance_status);

CREATE INDEX idx_payments_purpose
  ON payments(financial_payment_purpose);

CREATE INDEX idx_payments_gateway_order
  ON payments(payment_gateway_order_id) WHERE payment_gateway_order_id IS NOT NULL;

CREATE INDEX idx_payments_gateway_external
  ON payments(payment_gateway_external_id) WHERE payment_gateway_external_id IS NOT NULL;

CREATE INDEX idx_payments_timestamp
  ON payments(transaction_timestamp DESC);

CREATE INDEX idx_payments_payer_purpose
  ON payments(payer_user_id, financial_payment_purpose);

COMMENT ON TABLE payments IS 'Immutable financial audit log. Each row represents one payment event.';
COMMENT ON COLUMN payments.idempotency_key IS 'Prevents duplicate processing of Razorpay webhook events.';

-- ─────────────────────────────────────────────
-- View: active_bookings_with_context
-- For owner dashboard and admin panel
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW active_bookings_with_context AS
SELECT
  bk.id                             AS booking_id,
  bk.current_booking_lifecycle_state AS status,
  bk.scheduled_check_in_date,
  bk.scheduled_check_out_date,
  bk.monthly_rent_amount,
  bk.token_fee_amount_paid,
  bk.created_at                     AS booking_date,
  t.id                              AS tenant_id,
  t.legal_full_name                 AS tenant_name,
  t.phone_number                    AS tenant_phone,
  t.email_address                   AS tenant_email,
  b.id                              AS bed_id,
  b.bed_spatial_code,
  r.id                              AS room_id,
  r.room_identifier_code,
  r.floor_level_index,
  p.id                              AS property_id,
  p.property_display_name,
  p.municipality_city,
  p.landlord_owner_id               AS owner_id
FROM bookings bk
JOIN users t     ON t.id = bk.tenant_user_id
JOIN beds b      ON b.id = bk.assigned_bed_id
JOIN rooms r     ON r.id = b.room_parent_id
JOIN properties p ON p.id = r.property_parent_id
WHERE bk.deleted_at IS NULL
  AND bk.current_booking_lifecycle_state NOT IN ('CANCELLED');
-- Migration: 006_supporting_tables
-- Description: KYC, maintenance, notifications, favorites, reviews, audit logs

-- ─────────────────────────────────────────────
-- Table: kyc_documents
-- ─────────────────────────────────────────────
CREATE TABLE kyc_documents (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  document_type     kyc_doc_type_enum NOT NULL,
  s3_key            VARCHAR(500) NOT NULL,   -- encrypted private bucket key
  document_number   VARCHAR(50),             -- stored encrypted
  verification_status kyc_status_enum NOT NULL DEFAULT 'PENDING_REVIEW',
  reviewed_by       UUID REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at       TIMESTAMPTZ,
  rejection_reason  TEXT,
  expires_at        DATE,                    -- for Passport, DL expiry
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER kyc_documents_updated_at
  BEFORE UPDATE ON kyc_documents
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_kyc_user           ON kyc_documents(user_id);
CREATE INDEX idx_kyc_status         ON kyc_documents(verification_status);
CREATE INDEX idx_kyc_user_status    ON kyc_documents(user_id, verification_status);

-- When KYC is approved/rejected, sync to user table
CREATE OR REPLACE FUNCTION trigger_sync_user_kyc_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.verification_status IN ('VERIFIED', 'REJECTED') THEN
    UPDATE users
    SET identity_kyc_status = NEW.verification_status,
        record_updated_at   = NOW()
    WHERE id = NEW.user_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER kyc_sync_user_status
  AFTER UPDATE OF verification_status ON kyc_documents
  FOR EACH ROW EXECUTE FUNCTION trigger_sync_user_kyc_status();

-- ─────────────────────────────────────────────
-- Table: maintenance_tickets
-- ─────────────────────────────────────────────
CREATE TABLE maintenance_tickets (
  id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id              UUID NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  reported_by_user_id     UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  assigned_to_owner_id    UUID REFERENCES users(id) ON DELETE SET NULL,
  title                   VARCHAR(200) NOT NULL,
  description             TEXT NOT NULL,
  category                maintenance_category_enum NOT NULL DEFAULT 'OTHER',
  current_status          maintenance_status_enum NOT NULL DEFAULT 'OPEN',
  photo_s3_keys           TEXT[] NOT NULL DEFAULT '{}',
  resolution_notes        TEXT,
  resolved_at             TIMESTAMPTZ,
  closed_at               TIMESTAMPTZ,
  priority                SMALLINT NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 5),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER maintenance_tickets_updated_at
  BEFORE UPDATE ON maintenance_tickets
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_maintenance_booking     ON maintenance_tickets(booking_id);
CREATE INDEX idx_maintenance_reporter    ON maintenance_tickets(reported_by_user_id);
CREATE INDEX idx_maintenance_owner       ON maintenance_tickets(assigned_to_owner_id) WHERE assigned_to_owner_id IS NOT NULL;
CREATE INDEX idx_maintenance_status      ON maintenance_tickets(current_status);
CREATE INDEX idx_maintenance_category    ON maintenance_tickets(category);

-- ─────────────────────────────────────────────
-- Table: maintenance_comments
-- ─────────────────────────────────────────────
CREATE TABLE maintenance_comments (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ticket_id    UUID NOT NULL REFERENCES maintenance_tickets(id) ON DELETE CASCADE,
  author_id    UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  content      TEXT NOT NULL,
  is_internal  BOOLEAN NOT NULL DEFAULT FALSE,  -- owner-only notes
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_mc_ticket  ON maintenance_comments(ticket_id, created_at DESC);
CREATE INDEX idx_mc_author  ON maintenance_comments(author_id);

-- ─────────────────────────────────────────────
-- Table: notifications
-- ─────────────────────────────────────────────
CREATE TABLE notifications (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type         notification_type_enum NOT NULL,
  channel      notification_channel_enum NOT NULL DEFAULT 'IN_APP',
  title        VARCHAR(200) NOT NULL,
  body         TEXT NOT NULL,
  data         JSONB,                     -- arbitrary payload for deep-linking
  is_read      BOOLEAN NOT NULL DEFAULT FALSE,
  sent_at      TIMESTAMPTZ,
  read_at      TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_user
  ON notifications(user_id, created_at DESC) WHERE is_read = FALSE;

CREATE INDEX idx_notifications_user_all
  ON notifications(user_id, created_at DESC);

CREATE INDEX idx_notifications_type
  ON notifications(type);

-- ─────────────────────────────────────────────
-- Table: favorites
-- ─────────────────────────────────────────────
CREATE TABLE favorites (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  property_id  UUID NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_favorites_user_property UNIQUE (user_id, property_id)
);

CREATE INDEX idx_favorites_user  ON favorites(user_id);
CREATE INDEX idx_favorites_property ON favorites(property_id);

-- ─────────────────────────────────────────────
-- Table: reviews
-- ─────────────────────────────────────────────
CREATE TABLE reviews (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id     UUID NOT NULL UNIQUE REFERENCES bookings(id) ON DELETE RESTRICT,
  reviewer_id    UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  property_id    UUID NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  rating         SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title          VARCHAR(200),
  content        TEXT,
  is_approved    BOOLEAN NOT NULL DEFAULT FALSE,
  approved_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER reviews_updated_at
  BEFORE UPDATE ON reviews
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_reviews_property    ON reviews(property_id) WHERE is_approved = TRUE;
CREATE INDEX idx_reviews_reviewer    ON reviews(reviewer_id);
CREATE INDEX idx_reviews_rating      ON reviews(property_id, rating);

-- Materialized view for property average ratings (refresh periodically)
CREATE MATERIALIZED VIEW property_rating_summary AS
SELECT
  property_id,
  COUNT(*)                AS total_reviews,
  AVG(rating)::NUMERIC(3,2) AS avg_rating,
  SUM(CASE WHEN rating = 5 THEN 1 ELSE 0 END) AS five_star_count
FROM reviews
WHERE is_approved = TRUE
GROUP BY property_id;

CREATE UNIQUE INDEX idx_rating_summary_property ON property_rating_summary(property_id);

-- ─────────────────────────────────────────────
-- Table: audit_logs
-- ─────────────────────────────────────────────
CREATE TABLE audit_logs (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
  action        VARCHAR(200) NOT NULL,
  entity_type   VARCHAR(100) NOT NULL,
  entity_id     UUID,
  old_values    JSONB,
  new_values    JSONB,
  ip_address    INET,
  user_agent    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Partition hint: in production, partition by created_at (monthly)
CREATE INDEX idx_audit_user       ON audit_logs(user_id, created_at DESC);
CREATE INDEX idx_audit_entity     ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_action     ON audit_logs(action);
CREATE INDEX idx_audit_created_at ON audit_logs(created_at DESC);

COMMENT ON TABLE audit_logs IS 'Append-only audit trail for all write operations. Never update or delete rows.';
-- Migration: 007_functions_procedures
-- Description: Stored procedures for booking engine, rent invoicing, and geospatial search

-- ─────────────────────────────────────────────
-- Function: Search properties within radius
-- Returns properties with distance, sorted by proximity
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION search_properties_in_radius(
  p_lat           FLOAT8,
  p_lng           FLOAT8,
  p_radius_km     FLOAT8 DEFAULT 5.0,
  p_gender_policy gender_policy_enum DEFAULT NULL,
  p_min_rent      NUMERIC DEFAULT NULL,
  p_max_rent      NUMERIC DEFAULT NULL,
  p_amenities     TEXT[] DEFAULT NULL,
  p_limit         INT DEFAULT 20,
  p_offset        INT DEFAULT 0
)
RETURNS TABLE (
  id                    UUID,
  property_display_name VARCHAR,
  municipality_city     VARCHAR,
  gender_segregation_policy gender_policy_enum,
  structural_amenities  TEXT[],
  total_beds            SMALLINT,
  vacant_beds           SMALLINT,
  min_rent              NUMERIC,
  max_rent              NUMERIC,
  latitude              FLOAT8,
  longitude             FLOAT8,
  distance_km           FLOAT8,
  cover_photo_key       VARCHAR,
  avg_rating            NUMERIC,
  total_reviews         BIGINT,
  landlord_owner_id     UUID
) AS $$
DECLARE
  v_point GEOMETRY;
BEGIN
  -- Build search point from lat/lng
  v_point := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326);

  RETURN QUERY
  SELECT
    p.id,
    p.property_display_name,
    p.municipality_city,
    p.gender_segregation_policy,
    p.structural_amenities,
    p.total_beds,
    p.vacant_beds,
    p.min_rent,
    p.max_rent,
    ST_Y(p.geo_coordinate_point::geometry)::FLOAT8 AS latitude,
    ST_X(p.geo_coordinate_point::geometry)::FLOAT8 AS longitude,
    ROUND((ST_Distance(
      p.geo_coordinate_point::geography,
      v_point::geography
    ) / 1000.0)::NUMERIC, 2)::FLOAT8 AS distance_km,
    ph.s3_key                     AS cover_photo_key,
    rs.avg_rating,
    rs.total_reviews,
    p.landlord_owner_id
  FROM properties p
  LEFT JOIN property_photos ph
    ON ph.property_id = p.id AND ph.is_cover = TRUE
  LEFT JOIN property_rating_summary rs
    ON rs.property_id = p.id
  WHERE
    p.deleted_at IS NULL
    AND p.is_active = TRUE
    AND p.verification_status = 'VERIFIED'
    AND p.vacant_beds > 0
    -- Spatial: within radius
    AND ST_DWithin(
      p.geo_coordinate_point::geography,
      v_point::geography,
      p_radius_km * 1000  -- convert km to meters
    )
    -- Optional filters
    AND (p_gender_policy IS NULL OR p.gender_segregation_policy = p_gender_policy)
    AND (p_min_rent IS NULL OR p.min_rent >= p_min_rent)
    AND (p_max_rent IS NULL OR p.max_rent <= p_max_rent)
    AND (p_amenities IS NULL OR p.structural_amenities @> p_amenities)
  ORDER BY distance_km ASC, p.vacant_beds DESC
  LIMIT p_limit
  OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION search_properties_in_radius IS 'PostGIS radius search for available properties. Uses ST_DWithin with geographic (meter-accurate) distance calculation. Target: <200ms with GiST index.';

-- ─────────────────────────────────────────────
-- Function: Initialize booking with distributed lock check
-- Called by booking service AFTER Redis lock is acquired
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION initialize_booking_transaction(
  p_bed_id          UUID,
  p_tenant_id       UUID,
  p_check_in_date   DATE,
  p_idempotency_key VARCHAR,
  p_lock_expires_at TIMESTAMPTZ,
  p_lock_redis_key  VARCHAR
)
RETURNS TABLE (
  booking_id            UUID,
  monthly_rent          NUMERIC,
  security_deposit      NUMERIC,
  token_deposit_amount  NUMERIC,
  property_name         VARCHAR,
  room_code             VARCHAR,
  bed_code              VARCHAR
) AS $$
DECLARE
  v_bed            beds%ROWTYPE;
  v_room           rooms%ROWTYPE;
  v_property       properties%ROWTYPE;
  v_booking_id     UUID;
BEGIN
  -- 1. Lock the bed row (SELECT FOR UPDATE)
  SELECT * INTO v_bed
  FROM beds
  WHERE id = p_bed_id
  FOR UPDATE NOWAIT;  -- NOWAIT = fail immediately if row is locked

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BED_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Validate bed is still VACANT
  IF v_bed.current_occupancy_status <> 'VACANT' THEN
    RAISE EXCEPTION 'BED_NOT_VACANT' USING ERRCODE = 'P0002';
  END IF;

  -- 3. Idempotency check
  SELECT id INTO v_booking_id FROM bookings WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_EXISTS:%', v_booking_id USING ERRCODE = 'P0003';
  END IF;

  -- 4. Get room details
  SELECT * INTO v_room FROM rooms WHERE id = v_bed.room_parent_id;
  SELECT * INTO v_property FROM properties WHERE id = v_room.property_parent_id;

  -- 5. Update bed status to RESERVED
  UPDATE beds
  SET current_occupancy_status = 'RESERVED',
      last_modified_timestamp  = NOW()
  WHERE id = p_bed_id;

  -- 6. Create booking record
  v_booking_id := uuid_generate_v4();
  INSERT INTO bookings (
    id, tenant_user_id, assigned_bed_id,
    current_booking_lifecycle_state,
    scheduled_check_in_date,
    monthly_rent_amount, security_deposit_amount,
    reservation_lock_expires_at, lock_redis_key,
    idempotency_key
  ) VALUES (
    v_booking_id, p_tenant_id, p_bed_id,
    'PENDING',
    p_check_in_date,
    v_room.standard_monthly_rent_amount,
    v_room.required_security_deposit_amount,
    p_lock_expires_at,
    p_lock_redis_key,
    p_idempotency_key
  );

  RETURN QUERY
  SELECT
    v_booking_id,
    v_room.standard_monthly_rent_amount,
    v_room.required_security_deposit_amount,
    v_room.token_deposit_amount,
    v_property.property_display_name,
    v_room.room_identifier_code,
    v_bed.bed_spatial_code;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────
-- Function: Confirm booking after successful payment
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION confirm_booking_after_payment(
  p_booking_id UUID,
  p_payment_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking % not found', p_booking_id;
  END IF;

  IF v_booking.current_booking_lifecycle_state NOT IN ('PENDING') THEN
    RAISE EXCEPTION 'Booking % is in invalid state: %', p_booking_id, v_booking.current_booking_lifecycle_state;
  END IF;

  -- Confirm booking
  UPDATE bookings
  SET current_booking_lifecycle_state = 'CONFIRMED',
      token_fee_amount_paid = (
        SELECT exact_financial_amount FROM payments WHERE id = p_payment_id
      ),
      reservation_lock_expires_at = NULL,
      lock_redis_key = NULL,
      updated_at = NOW()
  WHERE id = p_booking_id;

  -- Move bed from RESERVED to OCCUPIED
  UPDATE beds
  SET current_occupancy_status = 'OCCUPIED',
      last_modified_timestamp  = NOW()
  WHERE id = v_booking.assigned_bed_id;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────
-- Function: Release expired reservation
-- Called by BullMQ worker when lock TTL expires
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION release_expired_reservation(p_booking_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND OR v_booking.current_booking_lifecycle_state <> 'PENDING' THEN
    RETURN FALSE;  -- already confirmed or cancelled
  END IF;

  -- Release bed back to VACANT
  UPDATE beds
  SET current_occupancy_status = 'VACANT',
      last_modified_timestamp  = NOW()
  WHERE id = v_booking.assigned_bed_id;

  -- Cancel the booking
  UPDATE bookings
  SET current_booking_lifecycle_state = 'CANCELLED',
      cancellation_reason = 'RESERVATION_EXPIRED',
      cancelled_at = NOW(),
      updated_at   = NOW()
  WHERE id = p_booking_id;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────
-- Function: Cancel booking (by tenant or admin)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cancel_booking(
  p_booking_id    UUID,
  p_cancelled_by  UUID,
  p_reason        TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  IF v_booking.current_booking_lifecycle_state NOT IN ('PENDING', 'CONFIRMED') THEN
    RAISE EXCEPTION 'Cannot cancel booking in state: %', v_booking.current_booking_lifecycle_state;
  END IF;

  -- Return bed to VACANT
  UPDATE beds
  SET current_occupancy_status = 'VACANT',
      last_modified_timestamp  = NOW()
  WHERE id = v_booking.assigned_bed_id;

  -- Update booking
  UPDATE bookings
  SET current_booking_lifecycle_state = 'CANCELLED',
      cancellation_reason  = p_reason,
      cancelled_at         = NOW(),
      cancelled_by_user_id = p_cancelled_by,
      updated_at           = NOW()
  WHERE id = p_booking_id;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
-- ─────────────────────────────────────────────
-- Migration 009: User FCM Tokens
-- Stores per-device Firebase Cloud Messaging tokens for push notifications.
-- Separate table (vs single column on users) because one user can have
-- multiple devices (phone + tablet, or reinstalled app with new token).
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS user_fcm_tokens (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fcm_token         VARCHAR(500) NOT NULL,
  device_platform   VARCHAR(20) CHECK (device_platform IN ('ios', 'android', 'web')),
  device_model      VARCHAR(100),
  app_version       VARCHAR(20),
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  last_used_at      TIMESTAMPTZ DEFAULT NOW(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_user_fcm_token UNIQUE (user_id, fcm_token)
);

-- ─────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────

-- Fetch active tokens for a user (used by sendPushToUser)
CREATE INDEX IF NOT EXISTS idx_user_fcm_tokens_user_active
  ON user_fcm_tokens (user_id)
  WHERE is_active = TRUE;

-- Clean up stale tokens by user
CREATE INDEX IF NOT EXISTS idx_user_fcm_tokens_user_id
  ON user_fcm_tokens (user_id);

-- ─────────────────────────────────────────────
-- Updated_at trigger
-- ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION update_user_fcm_tokens_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_user_fcm_tokens_updated_at ON user_fcm_tokens;
CREATE TRIGGER trg_user_fcm_tokens_updated_at
  BEFORE UPDATE ON user_fcm_tokens
  FOR EACH ROW EXECUTE FUNCTION update_user_fcm_tokens_updated_at();

-- ─────────────────────────────────────────────
-- API: upsert token (insert or update last_used)
-- Called by PUT /api/v1/notifications/fcm-token
-- ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_fcm_token(
  p_user_id        UUID,
  p_fcm_token      VARCHAR(500),
  p_platform       VARCHAR(20),
  p_device_model   VARCHAR(100),
  p_app_version    VARCHAR(20)
)
RETURNS UUID AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO user_fcm_tokens (user_id, fcm_token, device_platform, device_model, app_version, is_active, last_used_at)
  VALUES (p_user_id, p_fcm_token, p_platform, p_device_model, p_app_version, TRUE, NOW())
  ON CONFLICT (user_id, fcm_token)
    DO UPDATE SET
      is_active       = TRUE,
      last_used_at    = NOW(),
      device_platform = COALESCE(EXCLUDED.device_platform, user_fcm_tokens.device_platform),
      device_model    = COALESCE(EXCLUDED.device_model,    user_fcm_tokens.device_model),
      app_version     = COALESCE(EXCLUDED.app_version,     user_fcm_tokens.app_version),
      updated_at      = NOW()
  RETURNING id INTO v_id;

  -- Deactivate old tokens for same user (keep max 5 devices per user)
  WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY last_used_at DESC) AS rn
    FROM user_fcm_tokens WHERE user_id = p_user_id AND is_active = TRUE
  )
  UPDATE user_fcm_tokens SET is_active = FALSE
  WHERE id IN (SELECT id FROM ranked WHERE rn > 5);

  RETURN v_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON TABLE user_fcm_tokens IS
  'Per-device Firebase Cloud Messaging tokens for push notification delivery. Multiple tokens per user (one per device). Stale tokens auto-deactivated after failed delivery or when > 5 devices per user.';
