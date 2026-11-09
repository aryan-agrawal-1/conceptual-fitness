from alembic import op
import sqlalchemy as sa

revision = "0031_hrv_measurement_type"
down_revision = "0030_identity_and_connections"
branch_labels = None
depends_on = None

FIELD_TYPES = (
    ("rootMeanSquareOfSuccessiveDifferencesMilliseconds", "rmssd"),
    ("averageHeartRateVariabilityMilliseconds", "rmssd"),
    ("standardDeviationMilliseconds", "sdnn"),
)


def upgrade() -> None:
    op.add_column("metric_samples", sa.Column("measurement_type", sa.String(16), nullable=True))
    op.add_column("daily_summaries", sa.Column("heart_rate_variability_type", sa.String(16), nullable=True))
    op.add_column("daily_summaries", sa.Column("hrv_rmssd", sa.Float(), nullable=True))
    op.add_column("daily_summaries", sa.Column("hrv_sdnn", sa.Float(), nullable=True))

    bind = op.get_bind()
    bind.execute(
        sa.text(
            "UPDATE metric_samples SET measurement_type = 'rmssd' "
            "WHERE metric = 'heart_rate_variability' AND source_platform = 'FITBIT'"
        )
    )
    other_sources = bind.execute(
        sa.text(
            "SELECT s.id, s.value, r.raw_json FROM metric_samples s "
            "JOIN raw_health_records r ON r.id = s.raw_record_id "
            "WHERE s.metric = 'heart_rate_variability' AND s.measurement_type IS NULL"
        )
    ).all()
    for sample_id, value, raw_json in other_sources:
        measurement_type = matching_type(raw_json or {}, value)
        if measurement_type:
            bind.execute(
                sa.text("UPDATE metric_samples SET measurement_type = :type WHERE id = :id"),
                {"type": measurement_type, "id": sample_id},
            )

    bind.execute(
        sa.text(
            """
            UPDATE daily_summaries d
            SET hrv_rmssd = d.heart_rate_variability, heart_rate_variability_type = 'rmssd'
            WHERE d.heart_rate_variability IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM metric_samples s
                WHERE s.user_id = d.user_id
                  AND s.civil_date = d.summary_date
                  AND s.metric = 'heart_rate_variability'
                  AND (s.measurement_type IS DISTINCT FROM 'rmssd' OR s.source_platform IS DISTINCT FROM 'FITBIT')
              )
            """
        )
    )
    bind.execute(
        sa.text(
            "UPDATE daily_summaries SET heart_rate_variability = NULL "
            "WHERE heart_rate_variability IS NOT NULL AND heart_rate_variability_type IS NULL"
        )
    )


def downgrade() -> None:
    op.drop_column("daily_summaries", "hrv_sdnn")
    op.drop_column("daily_summaries", "hrv_rmssd")
    op.drop_column("daily_summaries", "heart_rate_variability_type")
    op.drop_column("metric_samples", "measurement_type")


def matching_type(raw_json, value):
    payload = raw_json.get("heartRateVariability") or raw_json.get("dailyHeartRateVariability") or {}
    for field, measurement_type in FIELD_TYPES:
        try:
            if abs(float(payload[field]) - float(value)) < 1e-9:
                return measurement_type
        except (KeyError, TypeError, ValueError):
            continue
    return None
