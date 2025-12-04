"""
Revenue Cycle Analyzer
Advanced analytics for healthcare revenue cycle management
"""

import psycopg2
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
from typing import Dict, List, Tuple, Any
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


class RevenueCycleAnalyzer:
    """Main class for revenue cycle analytics and optimization"""
    
    def __init__(self, db_config: Dict[str, str]):
        self.db_config = db_config
        self.connection = None
        
    def connect(self):
        """Establish database connection"""
        try:
            self.connection = psycopg2.connect(**self.db_config)
            logger.info("Database connection established")
        except Exception as e:
            logger.error(f"Connection failed: {e}")
            raise
    
    def disconnect(self):
        """Close database connection"""
        if self.connection:
            self.connection.close()
            logger.info("Database connection closed")
    
    def execute_query(self, query: str, params: Tuple = None) -> pd.DataFrame:
        """Execute SQL query and return DataFrame"""
        try:
            return pd.read_sql_query(query, self.connection, params=params)
        except Exception as e:
            logger.error(f"Query execution failed: {e}")
            raise
    
    def calculate_revenue_metrics(self, start_date: str, end_date: str) -> Dict[str, Any]:
        """
        Calculate comprehensive revenue cycle metrics
        
        Args:
            start_date: Start date for analysis (YYYY-MM-DD)
            end_date: End date for analysis (YYYY-MM-DD)
            
        Returns:
            Dictionary containing all calculated metrics
        """
        logger.info(f"Calculating revenue metrics from {start_date} to {end_date}")
        
        query = """
        WITH claim_summary AS (
            SELECT 
                COUNT(DISTINCT claim_id) AS total_claims,
                COUNT(DISTINCT CASE WHEN status = 'PAID' THEN claim_id END) AS paid_claims,
                COUNT(DISTINCT CASE WHEN status = 'DENIED' THEN claim_id END) AS denied_claims,
                SUM(charge_amount) AS total_charges,
                SUM(allowed_amount) AS total_allowed,
                SUM(paid_amount) AS total_payments,
                SUM(adjustment_amount) AS total_adjustments,
                AVG(CASE WHEN payment_date IS NOT NULL 
                    THEN payment_date - submission_date END) AS avg_days_to_payment
            FROM claims
            WHERE submission_date BETWEEN %s AND %s
        ),
        ar_summary AS (
            SELECT 
                SUM(charge_amount - COALESCE(paid_amount, 0)) AS total_ar,
                SUM(CASE WHEN CURRENT_DATE - submission_date > 90 
                    THEN charge_amount - COALESCE(paid_amount, 0) ELSE 0 END) AS ar_over_90
            FROM claims
            WHERE status NOT IN ('PAID', 'WRITTEN_OFF')
        )
        SELECT 
            cs.*,
            ar.total_ar,
            ar.ar_over_90,
            ROUND((cs.paid_claims::NUMERIC / NULLIF(cs.total_claims, 0)) * 100, 2) AS clean_claim_rate,
            ROUND((cs.denied_claims::NUMERIC / NULLIF(cs.total_claims, 0)) * 100, 2) AS denial_rate,
            ROUND((cs.total_payments / NULLIF(cs.total_allowed, 0)) * 100, 2) AS net_collection_rate,
            ROUND((cs.total_payments / NULLIF(cs.total_charges, 0)) * 100, 2) AS gross_collection_rate,
            ROUND((ar.ar_over_90 / NULLIF(ar.total_ar, 0)) * 100, 2) AS ar_over_90_pct,
            ROUND(ar.total_ar / ((cs.total_payments * 365.0) / 
                (DATE %s - DATE %s)), 2) AS days_in_ar
        FROM claim_summary cs, ar_summary ar
        """
        
        result = self.execute_query(query, (start_date, end_date, end_date, start_date))
        
        if result.empty:
            logger.warning("No data found for the specified period")
            return {}
        
        metrics = result.iloc[0].to_dict()
        logger.info(f"Revenue metrics calculated: {len(metrics)} KPIs")
        
        return metrics
    
    def analyze_denial_patterns(self, lookback_months: int = 6) -> pd.DataFrame:
        """
        Analyze denial patterns and identify root causes
        
        Args:
            lookback_months: Number of months to analyze
            
        Returns:
            DataFrame with denial analysis
        """
        logger.info(f"Analyzing denial patterns for last {lookback_months} months")
        
        query = """
        SELECT 
            d.denial_category,
            d.denial_reason_code,
            d.denial_reason_description,
            
            COUNT(DISTINCT d.denial_id) AS denial_count,
            SUM(d.denied_amount) AS total_denied,
            ROUND(AVG(d.denied_amount), 2) AS avg_denied,
            
            -- Resolution metrics
            COUNT(CASE WHEN d.work_status = 'RESOLVED' THEN 1 END) AS resolved,
            COUNT(CASE WHEN d.resolution_type = 'APPEALED_WON' THEN 1 END) AS appeals_won,
            SUM(CASE WHEN d.resolution_type = 'APPEALED_WON' THEN d.recovered_amount ELSE 0 END) AS amount_recovered,
            
            -- Success rates
            ROUND(
                COUNT(CASE WHEN d.resolution_type = 'APPEALED_WON' THEN 1 END)::NUMERIC /
                NULLIF(COUNT(CASE WHEN d.resolution_type LIKE 'APPEALED%%' THEN 1 END), 0) * 100,
                2
            ) AS appeal_success_rate,
            
            -- Preventability
            COUNT(CASE WHEN d.preventable = TRUE THEN 1 END) AS preventable_count,
            ROUND(
                COUNT(CASE WHEN d.preventable = TRUE THEN 1 END)::NUMERIC /
                NULLIF(COUNT(*), 0) * 100,
                2
            ) AS preventable_pct,
            
            -- Top payers
            STRING_AGG(DISTINCT p.payer_name, ', ') AS top_payers
            
        FROM denials d
        JOIN claims c ON d.claim_id = c.claim_id
        JOIN payers p ON c.payer_id = p.payer_id
        WHERE d.denial_date >= CURRENT_DATE - INTERVAL '%s months'
        GROUP BY d.denial_category, d.denial_reason_code, d.denial_reason_description
        HAVING COUNT(d.denial_id) >= 5
        ORDER BY total_denied DESC
        """
        
        result = self.execute_query(query % lookback_months)
        
        logger.info(f"Found {len(result)} denial patterns")
        return result
    
    def identify_revenue_leakage(self) -> Dict[str, pd.DataFrame]:
        """
        Identify sources of revenue leakage
        
        Returns:
            Dictionary of DataFrames for different leakage categories
        """
        logger.info("Identifying revenue leakage opportunities")
        
        leakage = {}
        
        # 1. Unbilled encounters
        unbilled_query = """
        SELECT 
            e.encounter_id,
            e.patient_id,
            e.provider_id,
            e.encounter_date,
            e.expected_charge,
            CURRENT_DATE - e.encounter_date AS days_unbilled,
            CASE 
                WHEN NOT e.documentation_complete THEN 'Missing Documentation'
                WHEN NOT e.coding_complete THEN 'Coding Incomplete'
                WHEN NOT e.charge_entered THEN 'Charges Not Entered'
                WHEN NOT e.claim_generated THEN 'Claim Not Generated'
            END AS bottleneck
        FROM encounters e
        WHERE e.encounter_date >= CURRENT_DATE - INTERVAL '90 days'
          AND e.encounter_date <= CURRENT_DATE - INTERVAL '7 days'
          AND NOT e.claim_generated
        ORDER BY e.expected_charge DESC
        """
        
        leakage['unbilled_encounters'] = self.execute_query(unbilled_query)
        
        # 2. Underpayments
        underpayment_query = """
        WITH payment_variance AS (
            SELECT 
                c.claim_id,
                c.patient_id,
                p.payer_name,
                c.submission_date,
                c.allowed_amount,
                c.patient_responsibility,
                c.paid_amount,
                (c.allowed_amount - COALESCE(c.patient_responsibility, 0)) AS expected_payment,
                (c.allowed_amount - COALESCE(c.patient_responsibility, 0)) - c.paid_amount AS variance
            FROM claims c
            JOIN payers p ON c.payer_id = p.payer_id
            WHERE c.status = 'PAID'
              AND c.payment_date >= CURRENT_DATE - INTERVAL '90 days'
              AND c.allowed_amount IS NOT NULL
        )
        SELECT *,
            ROUND((variance / NULLIF(expected_payment, 0)) * 100, 2) AS variance_pct
        FROM payment_variance
        WHERE ABS(variance) > 10
        ORDER BY ABS(variance) DESC
        """
        
        leakage['underpayments'] = self.execute_query(underpayment_query)
        
        # 3. Old AR
        old_ar_query = """
        SELECT 
            claim_id,
            patient_id,
            payer_id,
            submission_date,
            charge_amount - COALESCE(paid_amount, 0) AS outstanding,
            CURRENT_DATE - submission_date AS days_outstanding,
            status
        FROM claims
        WHERE status NOT IN ('PAID', 'WRITTEN_OFF')
          AND CURRENT_DATE - submission_date > 90
          AND charge_amount - COALESCE(paid_amount, 0) > 0
        ORDER BY charge_amount - COALESCE(paid_amount, 0) DESC
        """
        
        leakage['old_ar'] = self.execute_query(old_ar_query)
        
        # Calculate totals
        total_leakage = (
            leakage['unbilled_encounters']['expected_charge'].sum() +
            leakage['underpayments']['variance'].sum() +
            leakage['old_ar']['outstanding'].sum()
        )
        
        logger.info(f"Total revenue leakage identified: ${total_leakage:,.2f}")
        
        return leakage
    
    def payer_performance_analysis(self) -> pd.DataFrame:
        """
        Analyze and rank payer performance
        
        Returns:
            DataFrame with payer performance metrics
        """
        logger.info("Analyzing payer performance")
        
        query = """
        WITH payer_metrics AS (
            SELECT 
                p.payer_id,
                p.payer_name,
                p.payer_type,
                
                COUNT(DISTINCT c.claim_id) AS total_claims,
                SUM(c.charge_amount) AS total_charges,
                SUM(c.allowed_amount) AS total_allowed,
                SUM(c.paid_amount) AS total_payments,
                
                COUNT(CASE WHEN c.status = 'DENIED' THEN 1 END) AS denials,
                
                ROUND(AVG(CASE WHEN c.payment_date IS NOT NULL 
                    THEN c.payment_date - c.submission_date END), 1) AS avg_days_to_payment,
                
                COUNT(CASE WHEN c.status = 'PAID' 
                    AND c.claim_id NOT IN (SELECT claim_id FROM denials) 
                    THEN 1 END) AS clean_claims
                    
            FROM payers p
            JOIN claims c ON p.payer_id = c.payer_id
            WHERE c.submission_date >= CURRENT_DATE - INTERVAL '12 months'
            GROUP BY p.payer_id, p.payer_name, p.payer_type
        )
        SELECT 
            payer_name,
            payer_type,
            total_claims,
            total_payments,
            
            ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) AS reimbursement_rate,
            ROUND((denials::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) AS denial_rate,
            ROUND((clean_claims::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) AS clean_claim_rate,
            avg_days_to_payment,
            
            CASE 
                WHEN ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) >= 95 
                     AND ROUND((denials::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) <= 5 
                     AND avg_days_to_payment <= 30
                THEN 'Excellent'
                WHEN ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) >= 85 
                     AND ROUND((denials::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) <= 10
                THEN 'Good'
                WHEN ROUND((total_payments / NULLIF(total_allowed, 0)) * 100, 2) >= 75 
                     AND ROUND((denials::NUMERIC / NULLIF(total_claims, 0)) * 100, 2) <= 15
                THEN 'Fair'
                ELSE 'Poor'
            END AS performance_rating
            
        FROM payer_metrics
        WHERE total_claims >= 100
        ORDER BY total_payments DESC
        """
        
        result = self.execute_query(query)
        logger.info(f"Analyzed {len(result)} payers")
        
        return result
    
    def generate_executive_summary(self, start_date: str, end_date: str) -> str:
        """
        Generate executive summary report
        
        Args:
            start_date: Report start date
            end_date: Report end date
            
        Returns:
            Formatted executive summary as string
        """
        logger.info("Generating executive summary")
        
        self.connect()
        
        try:
            # Get metrics
            metrics = self.calculate_revenue_metrics(start_date, end_date)
            denials = self.analyze_denial_patterns()
            leakage = self.identify_revenue_leakage()
            payers = self.payer_performance_analysis()
            
            summary = f"""
REVENUE CYCLE EXECUTIVE SUMMARY
Period: {start_date} to {end_date}
Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

{'='*70}
KEY PERFORMANCE INDICATORS
{'='*70}

Volume Metrics:
  • Total Claims Submitted: {metrics.get('total_claims', 0):,}
  • Claims Paid: {metrics.get('paid_claims', 0):,}
  • Claims Denied: {metrics.get('denied_claims', 0):,}

Financial Performance:
  • Total Charges: ${metrics.get('total_charges', 0):,.2f}
  • Total Collections: ${metrics.get('total_payments', 0):,.2f}
  • Net Collection Rate: {metrics.get('net_collection_rate', 0):.1f}%
  • Gross Collection Rate: {metrics.get('gross_collection_rate', 0):.1f}%

Quality Metrics:
  • Clean Claim Rate: {metrics.get('clean_claim_rate', 0):.1f}%
  • Denial Rate: {metrics.get('denial_rate', 0):.1f}%
  • Average Days to Payment: {metrics.get('avg_days_to_payment', 0):.1f} days

Accounts Receivable:
  • Total AR: ${metrics.get('total_ar', 0):,.2f}
  • AR > 90 Days: ${metrics.get('ar_over_90', 0):,.2f} ({metrics.get('ar_over_90_pct', 0):.1f}%)
  • Days in AR: {metrics.get('days_in_ar', 0):.1f} days

{'='*70}
TOP DENIAL REASONS
{'='*70}

"""
            # Add top 5 denials
            for idx, row in denials.head(5).iterrows():
                summary += f"\n{idx+1}. {row['denial_category']} - {row['denial_reason_description']}\n"
                summary += f"   Count: {row['denial_count']} | Amount: ${row['total_denied']:,.2f}\n"
                summary += f"   Appeal Success: {row['appeal_success_rate']:.1f}% | Preventable: {row['preventable_pct']:.1f}%\n"
            
            summary += f"""
{'='*70}
REVENUE LEAKAGE OPPORTUNITIES
{'='*70}

Unbilled Encounters: {len(leakage['unbilled_encounters'])} encounters
  • Potential Revenue: ${leakage['unbilled_encounters']['expected_charge'].sum():,.2f}

Underpayments: {len(leakage['underpayments'])} claims
  • Variance Amount: ${leakage['underpayments']['variance'].sum():,.2f}

Old AR (>90 days): {len(leakage['old_ar'])} claims
  • Outstanding Amount: ${leakage['old_ar']['outstanding'].sum():,.2f}

TOTAL LEAKAGE: ${(
    leakage['unbilled_encounters']['expected_charge'].sum() +
    leakage['underpayments']['variance'].sum() +
    leakage['old_ar']['outstanding'].sum()
):,.2f}

{'='*70}
TOP PERFORMING PAYERS
{'='*70}

"""
            # Add top 5 payers
            for idx, row in payers.head(5).iterrows():
                summary += f"\n{idx+1}. {row['payer_name']} ({row['payer_type']})\n"
                summary += f"   Collections: ${row['total_payments']:,.2f} | Rating: {row['performance_rating']}\n"
                summary += f"   Denial Rate: {row['denial_rate']:.1f}% | Days to Payment: {row['avg_days_to_payment']:.0f}\n"
            
            summary += f"\n{'='*70}\n"
            
            return summary
            
        finally:
            self.disconnect()


def main():
    """Main execution"""
    
    db_config = {
        'dbname': 'revenue_cycle_db',
        'user': 'postgres',
        'password': 'your_password',
        'host': 'localhost',
        'port': '5432'
    }
    
    analyzer = RevenueCycleAnalyzer(db_config)
    
    # Generate report for last 90 days
    end_date = datetime.now().date()
    start_date = end_date - timedelta(days=90)
    
    summary = analyzer.generate_executive_summary(
        start_date.strftime('%Y-%m-%d'),
        end_date.strftime('%Y-%m-%d')
    )
    
    print(summary)
    
    # Save to file
    with open('outputs/executive_summary.txt', 'w') as f:
        f.write(summary)
    
    logger.info("Analysis complete!")


if __name__ == '__main__':
    main()
