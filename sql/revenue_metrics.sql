-- ================================================
-- REVENUE CYCLE ANALYTICS QUERIES
-- Comprehensive SQL for revenue analysis and optimization
-- ================================================

-- ================================================
-- 1. REVENUE CYCLE FUNNEL ANALYSIS
-- ================================================

-- Track claims through complete lifecycle
WITH monthly_funnel AS (
    SELECT 
        DATE_TRUNC('month', submission_date) AS month,
        COUNT(DISTINCT claim_id) AS submitted_claims,
        COUNT(DISTINCT CASE WHEN status IN ('PROCESSED', 'PAID') THEN claim_id END) AS processed_claims,
        COUNT(DISTINCT CASE WHEN status = 'PAID' THEN claim_id END) AS paid_claims,
        COUNT(DISTINCT CASE WHEN status = 'DENIED' THEN claim_id END) AS denied_claims,
        
        SUM(charge_amount) AS total_charges,
        SUM(CASE WHEN status = 'PAID' THEN allowed_amount END) AS total_allowed,
        SUM(CASE WHEN status = 'PAID' THEN paid_amount END) AS total_payments,
        SUM(adjustment_amount) AS total_adjustments
    FROM claims
    WHERE submission_date >= CURRENT_DATE - INTERVAL '12 months'
    GROUP BY DATE_TRUNC('month', submission_date)
)
SELECT 
    month,
    submitted_claims,
    processed_claims,
    paid_claims,
    denied_claims,
    
    -- Conversion rates
    ROUND((processed_claims::NUMERIC / NULLIF(submitted_claims, 0)) * 100, 2) AS process_rate,
    ROUND((paid_claims::NUMERIC / NULLIF(submitted_claims, 0)) * 100, 2) AS clean_claim_rate,
    ROUND((denied_claims::NUMERIC / NULLIF(submitted_claims, 0)) * 100, 2) AS denial_rate,
    
    -- Financial metrics
    total_charges,
    total_allowed,
    total_payments,
    total_adjustments,
    
    ROUND((total_payments / NULLIF(total_charges, 0)) * 100, 2) AS gross_collection_rate,
    ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) AS net_collection_rate
FROM monthly_funnel
ORDER BY month DESC;

-- ================================================
-- 2. DAYS IN AR CALCULATION
-- ================================================

WITH ar_metrics AS (
    SELECT 
        SUM(charge_amount - COALESCE(paid_amount, 0)) AS total_ar,
        (
            SELECT SUM(charge_amount)
            FROM claims
            WHERE submission_date >= CURRENT_DATE - INTERVAL '12 months'
        ) AS annual_charges
    FROM claims
    WHERE status NOT IN ('PAID', 'WRITTEN_OFF')
      AND charge_amount - COALESCE(paid_amount, 0) > 0
)
SELECT 
    total_ar,
    annual_charges,
    ROUND(total_ar / (annual_charges / 365.0), 2) AS days_in_ar
FROM ar_metrics;

-- ================================================
-- 3. AR AGING ANALYSIS
-- ================================================

WITH ar_aging AS (
    SELECT 
        claim_id,
        patient_id,
        payer_id,
        submission_date,
        charge_amount,
        COALESCE(paid_amount, 0) AS paid_amount,
        charge_amount - COALESCE(paid_amount, 0) AS outstanding_amount,
        CURRENT_DATE - submission_date AS days_outstanding,
        
        CASE 
            WHEN CURRENT_DATE - submission_date <= 30 THEN '0-30 days'
            WHEN CURRENT_DATE - submission_date <= 60 THEN '31-60 days'
            WHEN CURRENT_DATE - submission_date <= 90 THEN '61-90 days'
            WHEN CURRENT_DATE - submission_date <= 120 THEN '91-120 days'
            ELSE '120+ days'
        END AS aging_bucket
    FROM claims
    WHERE status NOT IN ('PAID', 'WRITTEN_OFF')
      AND charge_amount - COALESCE(paid_amount, 0) > 0
)
SELECT 
    aging_bucket,
    COUNT(claim_id) AS claim_count,
    SUM(outstanding_amount) AS total_outstanding,
    ROUND(AVG(outstanding_amount), 2) AS avg_outstanding,
    ROUND(AVG(days_outstanding), 1) AS avg_days_outstanding,
    ROUND(
        SUM(outstanding_amount) / 
        (SELECT SUM(outstanding_amount) FROM ar_aging) * 100, 
        2
    ) AS pct_of_total_ar
FROM ar_aging
GROUP BY aging_bucket
ORDER BY 
    CASE aging_bucket
        WHEN '0-30 days' THEN 1
        WHEN '31-60 days' THEN 2
        WHEN '61-90 days' THEN 3
        WHEN '91-120 days' THEN 4
        WHEN '120+ days' THEN 5
    END;

-- ================================================
-- 4. DENIAL ANALYSIS
-- ================================================

-- Top denial reasons by financial impact
SELECT 
    d.denial_category,
    d.denial_reason_code,
    d.denial_reason_description,
    
    COUNT(DISTINCT d.denial_id) AS denial_count,
    COUNT(DISTINCT c.patient_id) AS affected_patients,
    COUNT(DISTINCT c.provider_id) AS affected_providers,
    
    SUM(d.denied_amount) AS total_denied_amount,
    ROUND(AVG(d.denied_amount), 2) AS avg_denied_amount,
    
    COUNT(CASE WHEN d.work_status = 'RESOLVED' THEN 1 END) AS resolved_count,
    COUNT(CASE WHEN d.resolution_type = 'APPEALED_WON' THEN 1 END) AS appeal_wins,
    
    ROUND(
        COUNT(CASE WHEN d.resolution_type = 'APPEALED_WON' THEN 1 END)::NUMERIC / 
        NULLIF(COUNT(CASE WHEN d.resolution_type LIKE 'APPEALED%' THEN 1 END), 0) * 100,
        2
    ) AS appeal_success_rate,
    
    SUM(COALESCE(d.recovered_amount, 0)) AS total_recovered,
    ROUND(
        SUM(COALESCE(d.recovered_amount, 0)) / 
        NULLIF(SUM(d.denied_amount), 0) * 100,
        2
    ) AS recovery_rate
    
FROM denials d
JOIN claims c ON d.claim_id = c.claim_id
WHERE d.denial_date >= CURRENT_DATE - INTERVAL '6 months'
GROUP BY d.denial_category, d.denial_reason_code, d.denial_reason_description
HAVING COUNT(d.denial_id) >= 5
ORDER BY total_denied_amount DESC
LIMIT 20;

-- Denial trends over time
SELECT 
    DATE_TRUNC('month', denial_date) AS month,
    denial_category,
    COUNT(*) AS denial_count,
    SUM(denied_amount) AS denied_amount,
    ROUND(AVG(denied_amount), 2) AS avg_denied_amount
FROM denials
WHERE denial_date >= CURRENT_DATE - INTERVAL '12 months'
GROUP BY DATE_TRUNC('month', denial_date), denial_category
ORDER BY month DESC, denied_amount DESC;

-- ================================================
-- 5. PAYER PERFORMANCE SCORECARD
-- ================================================

WITH payer_performance AS (
    SELECT 
        p.payer_id,
        p.payer_name,
        p.payer_type,
        
        -- Volume metrics
        COUNT(DISTINCT c.claim_id) AS total_claims,
        COUNT(DISTINCT c.patient_id) AS unique_patients,
        
        -- Financial metrics
        SUM(c.charge_amount) AS total_charges,
        SUM(c.allowed_amount) AS total_allowed,
        SUM(c.paid_amount) AS total_payments,
        
        -- Denial metrics
        COUNT(CASE WHEN c.status = 'DENIED' THEN 1 END) AS denied_claims,
        SUM(CASE WHEN c.status = 'DENIED' THEN c.charge_amount END) AS denied_amount,
        
        -- Timing metrics
        ROUND(AVG(CASE 
            WHEN c.payment_date IS NOT NULL AND c.submission_date IS NOT NULL 
            THEN c.payment_date - c.submission_date 
        END), 1) AS avg_days_to_payment,
        
        -- First pass resolution
        COUNT(CASE 
            WHEN c.status = 'PAID' 
            AND c.claim_id NOT IN (SELECT claim_id FROM denials)
            THEN 1 
        END) AS clean_claims
        
    FROM payers p
    JOIN claims c ON p.payer_id = c.payer_id
    WHERE c.submission_date >= CURRENT_DATE - INTERVAL '12 months'
    GROUP BY p.payer_id, p.payer_name, p.payer_type
)
SELECT 
    payer_name,
    payer_type,
    total_claims,
    unique_patients,
    
    total_charges,
    total_payments,
    
    -- Performance rates
    ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) AS reimbursement_rate,
    ROUND((denied_claims::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) AS denial_rate,
    ROUND((clean_claims::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) AS clean_claim_rate,
    
    avg_days_to_payment,
    
    -- Performance rating
    CASE 
        WHEN ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) >= 95 
             AND ROUND((denied_claims::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) <= 5 
             AND avg_days_to_payment <= 30
        THEN 'Excellent'
        WHEN ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) >= 85 
             AND ROUND((denied_claims::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) <= 10
        THEN 'Good'
        WHEN ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) >= 75 
             AND ROUND((denied_claims::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) <= 15
        THEN 'Fair'
        ELSE 'Poor'
    END AS performance_rating
    
FROM payer_performance
WHERE total_claims >= 100  -- Minimum volume for statistical significance
ORDER BY total_payments DESC;

-- ================================================
-- 6. REVENUE LEAKAGE DETECTION
-- ================================================

-- Unbilled encounters
SELECT 
    e.encounter_id,
    e.patient_id,
    e.provider_id,
    e.encounter_date,
    e.encounter_type,
    e.expected_charge,
    
    e.documentation_complete,
    e.coding_complete,
    e.charge_entered,
    e.claim_generated,
    
    CURRENT_DATE - e.encounter_date AS days_since_encounter,
    
    CASE 
        WHEN NOT e.documentation_complete THEN 'Missing Documentation'
        WHEN NOT e.coding_complete THEN 'Coding Incomplete'
        WHEN NOT e.charge_entered THEN 'Charges Not Entered'
        WHEN NOT e.claim_generated THEN 'Claim Not Generated'
    END AS bottleneck,
    
    e.expected_charge AS revenue_at_risk
    
FROM encounters e
WHERE e.encounter_date >= CURRENT_DATE - INTERVAL '90 days'
  AND e.encounter_date <= CURRENT_DATE - INTERVAL '7 days'  -- Allow 7 days for normal processing
  AND NOT e.claim_generated
ORDER BY e.expected_charge DESC, e.encounter_date;

-- Underpaid claims
WITH expected_vs_actual AS (
    SELECT 
        c.claim_id,
        c.patient_id,
        c.payer_id,
        p.payer_name,
        c.submission_date,
        c.charge_amount,
        c.allowed_amount,
        c.paid_amount,
        
        -- Expected payment based on allowed amount
        c.allowed_amount - COALESCE(c.patient_responsibility, 0) AS expected_payment,
        
        -- Actual insurance payment
        c.paid_amount,
        
        -- Variance
        (c.allowed_amount - COALESCE(c.patient_responsibility, 0)) - c.paid_amount AS payment_variance
        
    FROM claims c
    JOIN payers p ON c.payer_id = p.payer_id
    WHERE c.status = 'PAID'
      AND c.payment_date >= CURRENT_DATE - INTERVAL '90 days'
      AND c.allowed_amount IS NOT NULL
)
SELECT 
    claim_id,
    patient_id,
    payer_name,
    submission_date,
    charge_amount,
    allowed_amount,
    expected_payment,
    paid_amount,
    payment_variance,
    ROUND((payment_variance / NULLIF(expected_payment, 0)) * 100, 2) AS variance_pct
FROM expected_vs_actual
WHERE ABS(payment_variance) > 0.01  -- Allow for rounding
  AND ABS(payment_variance) > 10     -- Material amounts only
ORDER BY ABS(payment_variance) DESC;

-- ================================================
-- 7. PROVIDER PERFORMANCE
-- ================================================

SELECT 
    c.provider_id,
    c.billing_provider_npi,
    
    -- Volume
    COUNT(DISTINCT c.claim_id) AS total_claims,
    COUNT(DISTINCT c.patient_id) AS unique_patients,
    
    -- Financial
    SUM(c.charge_amount) AS total_charges,
    SUM(c.paid_amount) AS total_collections,
    
    -- Quality metrics
    ROUND((
        COUNT(CASE WHEN c.status = 'PAID' AND c.claim_id NOT IN (SELECT claim_id FROM denials) THEN 1 END)::NUMERIC /
        NULLIF(COUNT(*), 0) * 100
    ), 2) AS clean_claim_rate,
    
    ROUND((
        COUNT(CASE WHEN c.status = 'DENIED' THEN 1 END)::NUMERIC /
        NULLIF(COUNT(*), 0) * 100
    ), 2) AS denial_rate,
    
    -- Efficiency
    ROUND(AVG(
        CASE 
            WHEN c.claim_generation_date IS NOT NULL 
            THEN c.submission_date - e.encounter_date 
        END
    ), 1) AS avg_days_to_submit,
    
    ROUND(AVG(
        CASE 
            WHEN c.payment_date IS NOT NULL 
            THEN c.payment_date - c.submission_date 
        END
    ), 1) AS avg_days_to_payment
    
FROM claims c
LEFT JOIN encounters e ON c.encounter_id = e.encounter_id
WHERE c.submission_date >= CURRENT_DATE - INTERVAL '6 months'
GROUP BY c.provider_id, c.billing_provider_npi
HAVING COUNT(DISTINCT c.claim_id) >= 50
ORDER BY total_collections DESC;

-- ================================================
-- 8. PAYMENT RECONCILIATION
-- ================================================

-- Unreconciled payments
SELECT 
    p.payment_id,
    p.payment_date,
    p.payment_method,
    p.check_number,
    p.eft_trace_number,
    p.payment_amount,
    p.batch_id,
    
    c.claim_id,
    c.claim_number,
    c.allowed_amount,
    c.patient_responsibility,
    c.allowed_amount - c.patient_responsibility AS expected_insurance_payment,
    
    p.payment_amount - (c.allowed_amount - c.patient_responsibility) AS variance,
    
    CURRENT_DATE - p.payment_date AS days_unreconciled
    
FROM payments p
JOIN claims c ON p.claim_id = c.claim_id
WHERE p.reconciliation_status = 'PENDING'
  AND ABS(p.payment_amount - (c.allowed_amount - c.patient_responsibility)) > 0.01
ORDER BY p.payment_date;

-- ================================================
-- 9. EXECUTIVE DASHBOARD KPIs
-- ================================================

WITH kpi_calc AS (
    SELECT 
        -- Current month
        DATE_TRUNC('month', CURRENT_DATE) AS current_month,
        
        -- Volume metrics
        COUNT(DISTINCT CASE WHEN submission_date >= DATE_TRUNC('month', CURRENT_DATE) THEN claim_id END) AS mtd_claims,
        COUNT(DISTINCT CASE WHEN submission_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month' 
                            AND submission_date < DATE_TRUNC('month', CURRENT_DATE) THEN claim_id END) AS prior_month_claims,
        
        -- Financial metrics
        SUM(CASE WHEN payment_date >= DATE_TRUNC('month', CURRENT_DATE) THEN paid_amount END) AS mtd_collections,
        SUM(CASE WHEN payment_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month' 
                 AND payment_date < DATE_TRUNC('month', CURRENT_DATE) THEN paid_amount END) AS prior_month_collections,
        
        -- Quality metrics
        SUM(CASE WHEN submission_date >= DATE_TRUNC('month', CURRENT_DATE) 
                 AND status = 'DENIED' THEN 1 ELSE 0 END)::NUMERIC /
        NULLIF(COUNT(CASE WHEN submission_date >= DATE_TRUNC('month', CURRENT_DATE) THEN 1 END), 0) * 100 AS mtd_denial_rate,
        
        -- AR metrics
        (SELECT SUM(charge_amount - COALESCE(paid_amount, 0))
         FROM claims 
         WHERE status NOT IN ('PAID', 'WRITTEN_OFF')) AS total_ar
        
    FROM claims
)
SELECT 
    current_month,
    mtd_claims,
    prior_month_claims,
    ROUND(((mtd_claims - prior_month_claims)::NUMERIC / NULLIF(prior_month_claims, 0)) * 100, 2) AS claims_mom_change,
    
    mtd_collections,
    prior_month_collections,
    ROUND(((mtd_collections - prior_month_collections) / NULLIF(prior_month_collections, 0)) * 100, 2) AS collections_mom_change,
    
    ROUND(mtd_denial_rate, 2) AS mtd_denial_rate,
    
    total_ar,
    ROUND(total_ar / ((mtd_collections * 12) / 365.0), 1) AS days_in_ar
    
FROM kpi_calc;
