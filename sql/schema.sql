-- Revenue Cycle Analytics Database Schema
-- Comprehensive schema for tracking healthcare billing and collections

-- ================================================
-- PAYERS TABLE
-- ================================================
CREATE TABLE IF NOT EXISTS payers (
    payer_id VARCHAR(50) PRIMARY KEY,
    payer_name VARCHAR(255) NOT NULL,
    payer_type VARCHAR(50) CHECK (payer_type IN ('COMMERCIAL', 'MEDICARE', 'MEDICAID', 'SELF_PAY', 'OTHER')),
    contract_rate_type VARCHAR(50),
    electronic_payer_id VARCHAR(20),
    contact_phone VARCHAR(20),
    contact_email VARCHAR(255),
    claims_address TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- CLAIMS TABLE
-- ================================================
CREATE TABLE IF NOT EXISTS claims (
    claim_id VARCHAR(50) PRIMARY KEY,
    patient_id VARCHAR(50) NOT NULL,
    provider_id VARCHAR(50) NOT NULL,
    payer_id VARCHAR(50) REFERENCES payers(payer_id),
    encounter_id VARCHAR(50),
    
    -- Claim details
    claim_number VARCHAR(50) UNIQUE,
    claim_type VARCHAR(20) CHECK (claim_type IN ('PROFESSIONAL', 'INSTITUTIONAL', 'DENTAL')),
    
    -- Dates
    service_date_from DATE NOT NULL,
    service_date_to DATE NOT NULL,
    submission_date DATE NOT NULL,
    received_date DATE,
    processed_date DATE,
    payment_date DATE,
    
    -- Financial amounts
    charge_amount DECIMAL(12, 2) NOT NULL,
    allowed_amount DECIMAL(12, 2),
    paid_amount DECIMAL(12, 2),
    patient_responsibility DECIMAL(12, 2),
    adjustment_amount DECIMAL(12, 2) DEFAULT 0,
    contractual_adjustment DECIMAL(12, 2) DEFAULT 0,
    
    -- Status tracking
    status VARCHAR(30) CHECK (status IN (
        'READY_TO_SUBMIT', 'SUBMITTED', 'ACCEPTED', 'PROCESSED', 
        'PAID', 'DENIED', 'APPEALED', 'WRITTEN_OFF'
    )),
    
    -- Denial information
    denial_reason_code VARCHAR(10),
    denial_reason_description TEXT,
    denial_category VARCHAR(50),
    
    -- Appeal tracking
    appeal_status VARCHAR(20),
    appeal_date DATE,
    appeal_level INTEGER,
    
    -- Billing provider
    billing_provider_npi VARCHAR(10),
    billing_provider_tax_id VARCHAR(15),
    
    -- Audit fields
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_worked_date DATE,
    assigned_to VARCHAR(100)
);

-- ================================================
-- CLAIM LINE ITEMS
-- ================================================
CREATE TABLE IF NOT EXISTS claim_line_items (
    line_item_id SERIAL PRIMARY KEY,
    claim_id VARCHAR(50) REFERENCES claims(claim_id) ON DELETE CASCADE,
    line_number INTEGER NOT NULL,
    
    -- Service details
    service_date DATE NOT NULL,
    place_of_service VARCHAR(2),
    procedure_code VARCHAR(10) NOT NULL,
    procedure_modifier_1 VARCHAR(2),
    procedure_modifier_2 VARCHAR(2),
    diagnosis_pointer VARCHAR(10),
    
    -- Financial
    quantity DECIMAL(10, 2) DEFAULT 1,
    charge_amount DECIMAL(10, 2) NOT NULL,
    allowed_amount DECIMAL(10, 2),
    paid_amount DECIMAL(10, 2),
    adjustment_amount DECIMAL(10, 2) DEFAULT 0,
    
    -- Provider
    rendering_provider_npi VARCHAR(10),
    
    -- Status
    line_status VARCHAR(20),
    denial_reason_code VARCHAR(10),
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- PAYMENTS TABLE
-- ================================================
CREATE TABLE IF NOT EXISTS payments (
    payment_id SERIAL PRIMARY KEY,
    claim_id VARCHAR(50) REFERENCES claims(claim_id),
    
    -- Payment details
    payment_date DATE NOT NULL,
    payment_method VARCHAR(30) CHECK (payment_method IN ('EFT', 'CHECK', 'CASH', 'CREDIT_CARD', 'ERA')),
    check_number VARCHAR(50),
    eft_trace_number VARCHAR(50),
    
    -- Amounts
    payment_amount DECIMAL(12, 2) NOT NULL,
    adjustment_amount DECIMAL(12, 2) DEFAULT 0,
    
    -- Payer info
    payer_id VARCHAR(50) REFERENCES payers(payer_id),
    payer_claim_number VARCHAR(50),
    
    -- Reconciliation
    batch_id VARCHAR(50),
    posting_date DATE,
    posted_by VARCHAR(100),
    reconciliation_status VARCHAR(20) DEFAULT 'PENDING',
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- DENIALS TABLE
-- ================================================
CREATE TABLE IF NOT EXISTS denials (
    denial_id SERIAL PRIMARY KEY,
    claim_id VARCHAR(50) REFERENCES claims(claim_id),
    
    -- Denial details
    denial_date DATE NOT NULL,
    denial_reason_code VARCHAR(10),
    denial_reason_description TEXT,
    denial_category VARCHAR(50) CHECK (denial_category IN (
        'ELIGIBILITY', 'AUTHORIZATION', 'CODING', 'MEDICAL_NECESSITY',
        'TIMELY_FILING', 'DUPLICATE', 'BILLING_ERROR', 'OTHER'
    )),
    
    -- Financial impact
    denied_amount DECIMAL(12, 2),
    
    -- Action tracking
    assigned_to VARCHAR(100),
    priority VARCHAR(20) CHECK (priority IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    work_status VARCHAR(30) DEFAULT 'NEW' CHECK (work_status IN (
        'NEW', 'IN_PROGRESS', 'PENDING_INFO', 'READY_TO_APPEAL', 
        'APPEALED', 'RESOLVED', 'WRITTEN_OFF'
    )),
    
    -- Resolution
    resolution_date DATE,
    resolution_type VARCHAR(30) CHECK (resolution_type IN (
        'CORRECTED_RESUBMITTED', 'APPEALED_WON', 'APPEALED_LOST', 
        'PAID_ON_APPEAL', 'WRITTEN_OFF', 'PATIENT_BALANCE'
    )),
    resolution_notes TEXT,
    recovered_amount DECIMAL(12, 2),
    
    -- Root cause tracking
    root_cause VARCHAR(100),
    preventable BOOLEAN,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- ENCOUNTERS TABLE
-- ================================================
CREATE TABLE IF NOT EXISTS encounters (
    encounter_id VARCHAR(50) PRIMARY KEY,
    patient_id VARCHAR(50) NOT NULL,
    provider_id VARCHAR(50) NOT NULL,
    
    -- Encounter details
    encounter_date DATE NOT NULL,
    encounter_type VARCHAR(50),
    department VARCHAR(100),
    
    -- Financial
    expected_charge DECIMAL(12, 2),
    actual_charge DECIMAL(12, 2),
    
    -- Status
    documentation_complete BOOLEAN DEFAULT FALSE,
    coding_complete BOOLEAN DEFAULT FALSE,
    charge_entered BOOLEAN DEFAULT FALSE,
    claim_generated BOOLEAN DEFAULT FALSE,
    
    -- Timestamps
    documentation_complete_date TIMESTAMP,
    coding_complete_date TIMESTAMP,
    charge_entry_date TIMESTAMP,
    claim_generation_date TIMESTAMP,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- AR AGING SNAPSHOT
-- ================================================
CREATE TABLE IF NOT EXISTS ar_aging_snapshot (
    snapshot_id SERIAL PRIMARY KEY,
    snapshot_date DATE NOT NULL,
    claim_id VARCHAR(50) REFERENCES claims(claim_id),
    
    -- Aging details
    days_outstanding INTEGER,
    aging_bucket VARCHAR(20) CHECK (aging_bucket IN (
        '0-30', '31-60', '61-90', '91-120', '120+'
    )),
    
    -- Amounts
    outstanding_amount DECIMAL(12, 2),
    
    -- Classification
    payer_type VARCHAR(50),
    responsible_party VARCHAR(50) CHECK (responsible_party IN ('PAYER', 'PATIENT')),
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- REVENUE METRICS TABLE
-- ================================================
CREATE TABLE IF NOT EXISTS revenue_metrics (
    metric_id SERIAL PRIMARY KEY,
    metric_date DATE NOT NULL,
    metric_period VARCHAR(20) CHECK (metric_period IN ('DAILY', 'WEEKLY', 'MONTHLY', 'QUARTERLY', 'ANNUAL')),
    
    -- Volume metrics
    claims_submitted INTEGER,
    claims_processed INTEGER,
    claims_paid INTEGER,
    claims_denied INTEGER,
    
    -- Financial metrics
    charges_posted DECIMAL(15, 2),
    payments_received DECIMAL(15, 2),
    adjustments DECIMAL(15, 2),
    
    -- Performance metrics
    net_collection_rate DECIMAL(5, 2),
    clean_claim_rate DECIMAL(5, 2),
    denial_rate DECIMAL(5, 2),
    days_in_ar DECIMAL(8, 2),
    
    -- AR metrics
    total_ar DECIMAL(15, 2),
    ar_over_90_days DECIMAL(15, 2),
    ar_over_90_days_pct DECIMAL(5, 2),
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- RECONCILIATION LOG
-- ================================================
CREATE TABLE IF NOT EXISTS reconciliation_log (
    reconciliation_id SERIAL PRIMARY KEY,
    reconciliation_date DATE NOT NULL,
    
    -- Batch info
    batch_id VARCHAR(50),
    payment_id INTEGER REFERENCES payments(payment_id),
    
    -- Expected vs actual
    expected_amount DECIMAL(12, 2),
    actual_amount DECIMAL(12, 2),
    variance_amount DECIMAL(12, 2),
    
    -- Status
    reconciliation_status VARCHAR(30) CHECK (reconciliation_status IN (
        'MATCHED', 'VARIANCE_APPROVED', 'VARIANCE_INVESTIGATING', 'UNMATCHED'
    )),
    
    -- Resolution
    resolution_notes TEXT,
    resolved_by VARCHAR(100),
    resolved_at TIMESTAMP,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ================================================
-- INDEXES FOR PERFORMANCE
-- ================================================

-- Claims indexes
CREATE INDEX idx_claims_patient ON claims(patient_id);
CREATE INDEX idx_claims_provider ON claims(provider_id);
CREATE INDEX idx_claims_payer ON claims(payer_id);
CREATE INDEX idx_claims_status ON claims(status);
CREATE INDEX idx_claims_submission_date ON claims(submission_date);
CREATE INDEX idx_claims_payment_date ON claims(payment_date);
CREATE INDEX idx_claims_service_date_from ON claims(service_date_from);
CREATE INDEX idx_claims_encounter ON claims(encounter_id);

-- Payments indexes
CREATE INDEX idx_payments_claim ON payments(claim_id);
CREATE INDEX idx_payments_date ON payments(payment_date);
CREATE INDEX idx_payments_payer ON payments(payer_id);
CREATE INDEX idx_payments_batch ON payments(batch_id);
CREATE INDEX idx_payments_reconciliation ON payments(reconciliation_status);

-- Denials indexes
CREATE INDEX idx_denials_claim ON denials(claim_id);
CREATE INDEX idx_denials_date ON denials(denial_date);
CREATE INDEX idx_denials_category ON denials(denial_category);
CREATE INDEX idx_denials_status ON denials(work_status);
CREATE INDEX idx_denials_assigned ON denials(assigned_to);

-- Encounters indexes
CREATE INDEX idx_encounters_patient ON encounters(patient_id);
CREATE INDEX idx_encounters_provider ON encounters(provider_id);
CREATE INDEX idx_encounters_date ON encounters(encounter_date);
CREATE INDEX idx_encounters_claim_status ON encounters(claim_generated);

-- AR aging indexes
CREATE INDEX idx_ar_snapshot_date ON ar_aging_snapshot(snapshot_date);
CREATE INDEX idx_ar_claim ON ar_aging_snapshot(claim_id);
CREATE INDEX idx_ar_bucket ON ar_aging_snapshot(aging_bucket);

-- ================================================
-- TRIGGERS
-- ================================================

-- Update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_claims_updated_at
    BEFORE UPDATE ON claims
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_denials_updated_at
    BEFORE UPDATE ON denials
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_encounters_updated_at
    BEFORE UPDATE ON encounters
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
